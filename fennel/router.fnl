;; access / header_filter / log phase handlers for proxy_pass routing.
;;
;; nginx.conf wires these into each generated location:
;;   access_by_lua_block        { require("router").access() }
;;   header_filter_by_lua_block { require("router").on_response() }
;;   log_by_lua_block           { require("router").log() }
;;
;; nginx owns the actual upstream connection, keepalive pool, TLS,
;; body streaming, and retries. Lua only sets variables and enforces
;; rate-limit / circuit-breaker policy.
;;
;; Variables read from generated location blocks (set by nginx before access):
;;   $svc_name             — service name
;;   $upstream_host_header — host:port to forward as Host header
;;
;; Variables written by access():
;;   $upstream_path  — stripped request URI + query string
;;   $traceparent    — W3C traceparent to forward upstream

(local config-mod (require :config))
(local circuit (require :circuit))
(local ratelimit (require :ratelimit))
(local metrics (require :metrics))
(local otel (require :otel))

;; Evaluated once per worker at module load. If ladon_otel dict is absent from
;; nginx.conf this is nil and the log phase skips otel at zero cost.
(local otel-enabled (not= nil (. ngx.shared :ladon_otel)))

;; Per-worker service lookup table, rebuilt only when config version changes.
(var services-by-name {})
(var services-version 0)
(var last-ver-check 0)

(fn get-services []
  (let [now (ngx.now)]
    (when (>= (- now last-ver-check) 0.1)
      (set last-ver-check now)
      (let [ver (config-mod.get-version)]
        (when (not= ver services-version)
          (let [cfg (config-mod.load-from-shared)
                by-name {}]
            (each [_ svc (ipairs cfg.services)]
              (tset by-name svc.name svc))
            (set services-by-name by-name)
            (set services-version ver))))))
  services-by-name)

(fn get-service [name]
  (. (get-services) name))

;; ── W3C traceparent ───────────────────────────────────────────────────────────

(fn make-traceparent [incoming-headers]
  (let [req-id (or ngx.var.request_id "00000000000000000000000000000000")
        parent-id (req-id:sub 1 16)
        incoming (. incoming-headers :traceparent)
        trace-id (when incoming (incoming:match "^00%-(%x+)%-"))
        valid-id (when (and trace-id (= (# trace-id) 32)) trace-id)]
    (.. "00-" (or valid-id req-id) "-" parent-id "-01")))

;; ── Phase handlers ────────────────────────────────────────────────────────────

(fn access []
  (let [svc-name ngx.var.svc_name
        service (get-service svc-name)]
    (when (not service)
      (set ngx.status 404)
      (ngx.say "{\"error\":\"no service matched\"}")
      (ngx.exit 404))
    ;; Strip /service-name prefix from request_uri (preserves query string).
    (let [prefix (.. "/" svc-name)
          uri ngx.var.request_uri
          stripped (uri:sub (+ (# prefix) 1))]
      (set ngx.var.upstream_path (if (= stripped "") "/" stripped)))
    ;; Traceparent: propagate existing trace or start new one.
    (set ngx.var.traceparent (make-traceparent (ngx.req.get_headers)))
    ;; Rate limit — 429 if exceeded.
    (let [(ok _) (ratelimit.check service)]
      (when (= ok false)
        (set ngx.status 429)
        (ngx.say "{\"error\":\"rate limit exceeded\"}")
        (ngx.exit 429)))
    ;; Circuit breaker — 503 if open.
    (when (not (circuit.allow? service))
      (metrics.circuit-open svc-name)
      (set ngx.status 503)
      (ngx.say "{\"error\":\"service unavailable (circuit open)\"}")
      (ngx.exit 503))
    ;; Request header manipulation — set/strip before forwarding upstream.
    (let [hdrs (and service.headers service.headers.request)]
      (when hdrs
        (when hdrs.set
          (each [k v (pairs hdrs.set)]
            (ngx.req.set_header k v)))
        (when hdrs.strip
          (each [_ k (ipairs hdrs.strip)]
            (ngx.req.clear_header k)))))))

;; Called by header_filter_by_lua_block — ngx.status is the upstream status.
(fn on-response []
  (let [service (get-service ngx.var.svc_name)]
    (when service
      (if (>= ngx.status 500)
        (circuit.on-failure! service)
        (circuit.on-success! service))
      ;; Response header manipulation — set/strip before returning to client.
      (let [hdrs (and service.headers service.headers.response)]
        (when hdrs
          (when hdrs.set
            (each [k v (pairs hdrs.set)]
              (tset ngx.header k v)))
          (when hdrs.strip
            (each [_ k (ipairs hdrs.strip)]
              (tset ngx.header k nil))))))))

;; Called by log_by_lua_block — upstream_response_time available here.
(fn log []
  (let [svc-name ngx.var.svc_name
        service (get-service svc-name)]
    (when service
      (let [duration (tonumber (or ngx.var.upstream_response_time "0"))]
        (metrics.proxy-request svc-name)
        (metrics.observe-latency svc-name duration)
        (when (>= ngx.status 500)
          (metrics.proxy-error svc-name ngx.status))
        (when otel-enabled
          (otel.push! svc-name))))))

{:access access :on_response on-response :log log}
