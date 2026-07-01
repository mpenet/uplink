;; Prometheus-style counters in ngx.shared.dict ladon_metrics.
;; nginx.conf must declare: lua_shared_dict ladon_metrics 1m;
;;
;; Key strings (metric{labels}) are memoized per-worker so repeated calls
;; for the same metric+labels combination never allocate a new string.

(fn get-dict []
  (let [d (. ngx.shared :ladon_metrics)]
    (assert d "lua_shared_dict 'ladon_metrics' not defined in nginx.conf")
    d))

;; Per-worker key memoization: {metric..labels → "metric{labels}"}
(local key-memo {})

(fn make-key [metric labels]
  (let [k (.. metric labels)]
    (or (. key-memo k)
        (let [full (.. metric "{" labels "}")]
          (tset key-memo k full)
          full))))

(fn inc [metric labels]
  (let [key (make-key metric labels)
        d (get-dict)
        (newval err) (d:incr key 1 0)]
    (when (not newval)
      (ngx.log ngx.ERR "metrics inc failed key=" key ": " (or err "unknown")))))

(fn schema-fetch [service status]
  (inc "schema_fetch_total"
       (.. "service=\"" service "\",status=\"" status "\"")))

(fn cache-result [service result]
  (inc "schema_cache_result_total"
       (.. "service=\"" service "\",result=\"" result "\"")))

(fn proxy-request [service]
  (inc "proxy_requests_total"
       (.. "service=\"" service "\"")))

(fn proxy-error [service code]
  (inc "proxy_errors_total"
       (.. "service=\"" service "\",code=\"" (tostring code) "\"")))

(fn render []
  (let [dict (get-dict)
        keys (dict:get_keys 0)
        lines []]
    (each [_ k (ipairs keys)]
      (let [v (dict:get k)]
        (when v
          (table.insert lines (.. k " " v)))))
    (table.concat lines "\n")))

{:schema-fetch schema-fetch
 :cache-result cache-result
 :proxy-request proxy-request
 :proxy-error proxy-error
 :render render}
