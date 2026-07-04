;; Adaptive concurrency limiting — gradient algorithm.
;; Based on Netflix's concurrency-limits library (https://github.com/Netflix/concurrency-limits).
;;
;; Tracks minimum observed RTT as a no-load baseline. When RTT rises above
;; baseline the limit decreases proportionally. When RTT is stable the limit
;; probes upward by sqrt(limit). On upstream error it backs off by 10%.
;;
;; State in uplink_adaptive shared dict (µs integers for atomic ops):
;;   ac:<n>:if  — in-flight request count
;;   ac:<n>:lim — current concurrency limit
;;   ac:<n>:mr  — minimum observed RTT (µs)
;;   ac:<n>:re  — RTT exponential moving average (µs)
;;   ac:<n>:ma  — unix timestamp of last min-RTT reset
;;
;; Per-service config fields (all optional):
;;   initial_limit (20)  — starting limit before observations accumulate
;;   min_limit     (5)   — floor
;;   max_limit     (200) — ceiling
;;   min_rtt_reset (60)  — seconds before min-RTT baseline is re-sampled

(local ALPHA 0.1)

(fn get-dict []
  (. ngx.shared :uplink_adaptive))

(fn if-key  [n] (.. "ac:" n ":if"))
(fn lim-key [n] (.. "ac:" n ":lim"))
(fn mr-key  [n] (.. "ac:" n ":mr"))
(fn re-key  [n] (.. "ac:" n ":re"))
(fn ma-key  [n] (.. "ac:" n ":ma"))

(fn get-limit [d name init]
  (or (d:get (lim-key name)) init))

;; Returns true if admitted, false if limit exceeded, nil if dict absent.
;; On rejection, atomically undoes the inflight increment before returning.
(fn allow? [service]
  (let [d (get-dict)]
    (when d
      (let [cfg (or service.adaptive_concurrency {})
            name service.name
            lim (get-limit d name (or cfg.initial_limit 20))
            (n _) (d:incr (if-key name) 1 0)]
        (if (> n lim)
          (do (d:incr (if-key name) -1 0) false)
          true)))))

;; Called in log phase. Always decrements inflight.
;; Skips gradient update when rtt-s is 0 (upstream not contacted —
;; circuit-breaker or rate-limit rejection happened before proxy_pass).
(fn on-complete! [service rtt-s success]
  (let [d (get-dict)]
    (when d
      (let [cfg (or service.adaptive_concurrency {})
            name service.name
            min-lim (or cfg.min_limit 5)
            max-lim (or cfg.max_limit 200)
            init (or cfg.initial_limit 20)
            reset-sec (or cfg.min_rtt_reset 60)]
        (d:incr (if-key name) -1 0)
        (when (> rtt-s 0)
          (let [rtt-us (math.floor (* rtt-s 1e6))
                ema (or (d:get (re-key name)) rtt-us)
                new-ema (math.floor (+ (* ALPHA rtt-us) (* (- 1 ALPHA) ema)))]
            (d:set (re-key name) new-ema 0)
            (let [now (ngx.now)
                  age (or (d:get (ma-key name)) 0)
                  cur-min (d:get (mr-key name))
                  min-rtt (math.min (or cur-min rtt-us) rtt-us)]
              (when (or (not cur-min) (> (- now age) reset-sec))
                (d:set (mr-key name) rtt-us 0)
                (d:set (ma-key name) now 0))
              (let [cur-lim (get-limit d name init)
                    new-lim (if success
                              (let [gradient (/ min-rtt (math.max new-ema 1))
                                    probe (math.sqrt cur-lim)]
                                (math.floor (+ (* gradient cur-lim) probe)))
                              (math.floor (* cur-lim 0.9)))
                    clamped (math.max min-lim (math.min max-lim new-lim))]
                (d:set (lim-key name) clamped 0)))))))))

(fn get-stats [service-name]
  (let [d (get-dict)]
    (when d
      {:inflight (or (d:get (if-key service-name)) 0)
       :limit (d:get (lim-key service-name))
       :min_rtt_ms (let [v (d:get (mr-key service-name))]
                     (when v (/ v 1000)))
       :rtt_ema_ms (let [v (d:get (re-key service-name))]
                     (when v (/ v 1000)))})))

{:allow? allow? :on-complete! on-complete! :get-stats get-stats}
