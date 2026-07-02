;; Circuit breaker: CLOSED → OPEN → HALF-OPEN → CLOSED
;; State persisted in uplink_circuit shared dict so all workers share it.
;;
;; Keys per service:
;;   cb:<name>:state  — "open" when tripped (nil/absent = closed)
;;   cb:<name>:fails  — consecutive failure count
;;   cb:<name>:opened — unix timestamp when circuit opened
;;   cb:<name>:probe  — present while a half-open probe is in flight
;;
;; When open_ttl expires the circuit enters HALF-OPEN: exactly one request
;; (the probe) is admitted via d:add on the probe key; concurrent requests
;; still receive 503. If the probe succeeds the circuit closes; if it fails
;; the circuit reopens and opened_at is reset for another full open_ttl.
;;
;; Config fields on service.circuit_breaker:
;;   threshold  — consecutive failures before opening (default 5)
;;   open_ttl   — seconds to keep open before admitting a probe (default 30)

(var _dict nil)
(fn get-dict []
  (when (not _dict)
    (set _dict (assert (. ngx.shared :uplink_circuit)
                       "lua_shared_dict 'uplink_circuit' not defined in nginx.conf")))
  _dict)

(fn state-key [n]  (.. "cb:" n ":state"))
(fn fails-key [n]  (.. "cb:" n ":fails"))
(fn opened-key [n] (.. "cb:" n ":opened"))
(fn probe-key [n]  (.. "cb:" n ":probe"))

;; Returns true if the circuit allows this request through.
;; Returns "probe" if this specific call won the probe slot.
;; Returns false if rejected.
(fn allow? [service]
  (let [cb (or service.circuit_breaker {})
        ttl (or cb.open_ttl 30)
        name service.name
        d (get-dict)]
    (if (not= (d:get (state-key name)) "open")
      true
      (let [opened-at (d:get (opened-key name))]
        (if (not (and opened-at (>= (- (ngx.now) opened-at) ttl)))
          false
          ;; TTL expired — race to become the probe via atomic add.
          ;; probe key TTL = 2× open_ttl so a crashed probe self-clears.
          (let [(ok _) (d:add (probe-key name) true (* 2 ttl))]
            (if ok "probe" false)))))))

(fn on-success! [service]
  (let [d (get-dict)
        name service.name]
    (d:delete (state-key name))
    (d:delete (probe-key name))
    (d:set (fails-key name) 0 0)))

(fn on-failure! [service]
  (let [cb (or service.circuit_breaker {})
        threshold (or cb.threshold 5)
        name service.name
        d (get-dict)
        (fails _) (d:incr (fails-key name) 1 0)]
    (when (>= fails threshold)
      (d:set (state-key name) "open" 0)
      (d:set (opened-key name) (ngx.now) 0)
      ;; Clear probe flag so the next open_ttl window admits a fresh probe.
      (d:delete (probe-key name)))))

(fn get-state [service-name]
  (let [d (get-dict)]
    (or (d:get (state-key service-name)) "closed")))

{:allow? allow?
 :on-success! on-success!
 :on-failure! on-failure!
 :get-state get-state}
