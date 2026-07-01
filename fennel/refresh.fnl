;; Background schema refresh using ngx.timer.every.
;; Each service gets its own timer firing at 90% of its effective TTL
;; so schemas are refreshed before they go stale.
;;
;; init-worker must be called from init_worker_by_lua_block.
;;
;; Pre-warm uses a shared dict lock (ngx.shared.dict:add is atomic) so only
;; one worker fetches on startup. Others skip — the shared cache is already
;; populated by the winner.

(local schema-mod (require :schema))
(local cache (require :cache))
(local metrics (require :metrics))

;; NUL prefix makes this key impossible to produce from a service name.
(local nul (string.char 0))
(local warm-lock-key (.. nul "ladon:warming"))
(local warm-lock-ttl 60)  ;; seconds; expires so a crash doesn't block future warms

(fn make-thunk [service]
  (fn []
    (let [schema (schema-mod.process service)
          ttl (or schema.upstream-ttl service.ttl)]
      {:value schema :ttl ttl})))

(fn refresh-callback [premature service]
  (when (not premature)
    (let [ok (cache.force-refresh service.name service.ttl (make-thunk service))]
      (metrics.schema-fetch service.name (if ok :background_ok :background_error)))))

;; Pre-warm: one worker wins the lock and fetches all schemas.
;; Others find the lock present and skip — shared dict already has the data.
(fn warm-callback [premature cfg]
  (when (not premature)
    (let [d (. ngx.shared :ladon_cache)
          (won _) (d:add warm-lock-key true warm-lock-ttl)]
      (when won
        (each [_ service (ipairs cfg.services)]
          (let [ok (cache.force-refresh service.name service.ttl (make-thunk service))]
            (when (not ok)
              (ngx.log ngx.ERR "pre-warm failed for service=" service.name))))))))

;; Start background timers for all services and schedule immediate pre-warm.
;; Timer interval = 90% of service.ttl so refresh happens before stale.
(fn init-worker [cfg]
  (ngx.timer.at 0 warm-callback cfg)
  (each [_ service (ipairs cfg.services)]
    (let [interval (math.max 1 (math.floor (* service.ttl 0.9)))
          (ok err) (ngx.timer.every interval refresh-callback service)]
      (when (not ok)
        (ngx.log ngx.ERR
          "failed to start refresh timer for service=" service.name ": " err)))))

{:init-worker init-worker}
