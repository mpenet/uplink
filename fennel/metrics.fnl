;; Prometheus-style metrics in ngx.shared.dict uplink_metrics.
;; nginx.conf must declare: lua_shared_dict uplink_metrics 2m;
;;
;; Per-worker key memoization: repeated calls for the same metric+labels
;; combination never allocate a new string.
;;
;; Per-worker dict reference cached after first access — avoids repeated
;; table index + assert on every inc call.

(var _dict nil)
(fn get-dict []
  (when (not _dict)
    (set _dict (assert (. ngx.shared :uplink_metrics)
                       "lua_shared_dict 'uplink_metrics' not defined in nginx.conf")))
  _dict)

(local key-memo {})

(fn make-key [metric labels]
  (let [k (.. metric labels)]
    (or (. key-memo k)
        (let [full (if (= labels "") metric (.. metric "{" labels "}"))]
          (tset key-memo k full)
          full))))

(fn inc [metric labels]
  (let [key (make-key metric labels)
        d (get-dict)
        (newval err) (d:incr key 1 0)]
    (when (not newval)
      (ngx.log ngx.ERR "metrics inc failed key=" key ": " (or err "unknown")))))

;; ── Counters ─────────────────────────────────────────────────────────────────

(fn schema-fetch [service status]
  (inc "schema_fetch_total"
       (.. "service=\"" service "\",status=\"" status "\"")))

(fn cache-result [service result]
  (inc "schema_cache_result_total"
       (.. "service=\"" service "\",result=\"" result "\"")))

(fn proxy-request [service]
  (inc "proxy_requests_total" (.. "service=\"" service "\"")))

(fn proxy-error [service code]
  (inc "proxy_errors_total"
       (.. "service=\"" service "\",code=\"" (tostring code) "\"")))

(fn circuit-open [service]
  (inc "circuit_open_total" (.. "service=\"" service "\"")))

;; ── Histogram ────────────────────────────────────────────────────────────────
;; Standard Prometheus latency buckets in seconds.

(local hist-buckets [0.005 0.01 0.025 0.05 0.1 0.25 0.5 1 2.5 5 10])
(local hist-n (# hist-buckets))

;; Binary search: find first bucket index where bucket >= duration,
;; then increment that bucket and all higher ones (cumulative semantics).
;; For a typical sub-100ms request this roughly halves shared-dict incr calls
;; vs the naive linear scan.
(fn observe-latency [service duration]
  (let [d (get-dict)
        svc (.. "service=\"" service "\"")]
    (var lo 1)
    (var hi hist-n)
    (while (<= lo hi)
      (let [mid (math.floor (/ (+ lo hi) 2))]
        (if (<= duration (. hist-buckets mid))
          (set hi (- mid 1))
          (set lo (+ mid 1)))))
    (for [i lo hist-n]
      (d:incr (make-key "proxy_request_duration_seconds_bucket"
                        (.. svc ",le=\"" (. hist-buckets i) "\"")) 1 0))
    (d:incr (make-key "proxy_request_duration_seconds_bucket"
                      (.. svc ",le=\"+Inf\"")) 1 0)
    (d:incr (make-key "proxy_request_duration_seconds_sum" svc) duration 0)
    (d:incr (make-key "proxy_request_duration_seconds_count" svc) 1 0)))

;; ── Render ───────────────────────────────────────────────────────────────────

(local type-header
  (.. "# TYPE schema_fetch_total counter\n"
      "# TYPE schema_cache_result_total counter\n"
      "# TYPE proxy_requests_total counter\n"
      "# TYPE proxy_errors_total counter\n"
      "# TYPE circuit_open_total counter\n"
      "# TYPE proxy_request_duration_seconds histogram\n"))

(fn render []
  (let [dict (get-dict)
        keys (dict:get_keys 0)
        lines []]
    (table.sort keys)
    (each [_ k (ipairs keys)]
      (let [v (dict:get k)]
        (when v
          (table.insert lines (.. k " " v)))))
    (.. type-header (table.concat lines "\n"))))

{:schema-fetch schema-fetch
 :cache-result cache-result
 :proxy-request proxy-request
 :proxy-error proxy-error
 :circuit-open circuit-open
 :observe-latency observe-latency
 :render render}
