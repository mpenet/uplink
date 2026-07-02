;; Per-service rate limiting using lua-resty-limit-traffic (bundled with OpenResty).
;; nginx.conf must declare: lua_shared_dict ladon_ratelimit 1m;
;;
;; Config on service.rate_limit:
;;   requests_per_second — allowed rate (default 100)
;;   burst               — extra burst capacity before rejection (default 50)
;;
;; Uses leaky-bucket algorithm. Requests within burst are allowed immediately;
;; requests beyond burst are rejected with 429.

(local limit-req (require "resty.limit.req"))

;; Per-worker limiter cache: recreated if service config changes.
(local limiters {})

(fn get-limiter [service]
  (let [name service.name]
    (when (not (. limiters name))
      (let [rl service.rate_limit
            rate (or rl.requests_per_second 100)
            burst (or rl.burst 50)
            (lim err) (limit-req.new :ladon_ratelimit rate burst)]
        (when err (error (.. "rate limiter init failed for " name ": " err)))
        (tset limiters name lim)))
    (. limiters name)))

;; Returns nil when allowed; (false, msg) when the request should be rejected.
(fn check [service]
  (when service.rate_limit
    (let [lim (get-limiter service)
          (delay _) (lim:incoming (.. "rl:" service.name) true)]
      (when (not delay)
        (values false "rate limit exceeded")))))

{:check check}
