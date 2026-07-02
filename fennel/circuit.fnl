;; Circuit breaker: CLOSED → OPEN → CLOSED
;; State persisted in ladon_circuit shared dict so all workers share it.
;;
;; Keys per service:
;;   cb:<name>:state  — "open" when tripped (nil/absent = closed)
;;   cb:<name>:fails  — consecutive failure count
;;   cb:<name>:opened — unix timestamp when circuit opened
;;
;; Config fields on service.circuit_breaker:
;;   threshold  — consecutive failures before opening (default 5)
;;   open_ttl   — seconds to keep open before retrying (default 30)

(var _dict nil)
(fn get-dict []
  (when (not _dict)
    (set _dict (assert (. ngx.shared :ladon_circuit)
                       "lua_shared_dict 'ladon_circuit' not defined in nginx.conf")))
  _dict)

(fn state-key [n]  (.. "cb:" n ":state"))
(fn fails-key [n]  (.. "cb:" n ":fails"))
(fn opened-key [n] (.. "cb:" n ":opened"))

;; Returns true if the circuit allows this request through.
(fn allow? [service]
  (let [cb (or service.circuit_breaker {})
        ttl (or cb.open_ttl 30)
        name service.name
        d (get-dict)]
    (if (not= (d:get (state-key name)) "open")
      true
      (let [opened-at (d:get (opened-key name))]
        (if (and opened-at (>= (- (ngx.now) opened-at) ttl))
          (do
            ;; TTL expired: reset circuit and let request through as probe.
            (d:delete (state-key name))
            (d:set (fails-key name) 0 0)
            true)
          false)))))

(fn on-success! [service]
  (let [d (get-dict)
        name service.name]
    (d:delete (state-key name))
    (d:set (fails-key name) 0 0)))

(fn on-failure! [service]
  (let [cb (or service.circuit_breaker {})
        threshold (or cb.threshold 5)
        name service.name
        d (get-dict)
        (fails _) (d:incr (fails-key name) 1 0)]
    (when (>= fails threshold)
      (d:set (state-key name) "open" 0)
      (d:set (opened-key name) (ngx.now) 0))))

(fn get-state [service-name]
  (let [d (get-dict)]
    (or (d:get (state-key service-name)) "closed")))

{:allow? allow?
 :on-success! on-success!
 :on-failure! on-failure!
 :get-state get-state}
