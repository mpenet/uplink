(var metrics nil)

(before_each
  (fn []
    (reset_mocks)
    (tset package.loaded :metrics nil)
    (set metrics (require :metrics))))

(describe "metrics"
  (fn []
    (it "proxy-request increments proxy_requests_total"
      (fn []
        (metrics.proxy-request "users")
        (assert.equals 1 (_mock_dicts.metrics:get "proxy_requests_total{service=\"users\"}"))))

    (it "proxy-request accumulates on repeated calls"
      (fn []
        (metrics.proxy-request "orders")
        (metrics.proxy-request "orders")
        (assert.equals 2 (_mock_dicts.metrics:get "proxy_requests_total{service=\"orders\"}"))))

    (it "proxy-error increments proxy_errors_total"
      (fn []
        (metrics.proxy-error "users" 502)
        (assert.equals 1 (_mock_dicts.metrics:get "proxy_errors_total{service=\"users\",code=\"502\"}"))))

    (it "schema-fetch increments schema_fetch_total"
      (fn []
        (metrics.schema-fetch "users" "ok")
        (assert.equals 1 (_mock_dicts.metrics:get "schema_fetch_total{service=\"users\",status=\"ok\"}"))))

    (it "cache-result increments schema_cache_result_total"
      (fn []
        (metrics.cache-result "users" "ok")
        (assert.equals 1 (_mock_dicts.metrics:get "schema_cache_result_total{service=\"users\",result=\"ok\"}"))))

    (it "render returns prometheus-style text"
      (fn []
        (metrics.proxy-request "svc")
        (metrics.proxy-error "svc" 500)
        (let [out (metrics.render)]
          (assert.is_truthy (out:find "proxy_requests_total"))
          (assert.is_truthy (out:find "proxy_errors_total")))))

    (it "render output starts with # HELP and # TYPE lines"
      (fn []
        (let [out (metrics.render)]
          (assert.is_truthy (out:find "# HELP proxy_requests_total" 1 true))
          (assert.is_truthy (out:find "# TYPE proxy_requests_total counter" 1 true))
          (assert.is_truthy (out:find "# HELP proxy_request_duration_seconds" 1 true))
          (assert.is_truthy (out:find "# TYPE proxy_request_duration_seconds histogram" 1 true)))))

    (it "counters for different services are independent"
      (fn []
        (metrics.proxy-request "users")
        (metrics.proxy-request "orders")
        (metrics.proxy-request "orders")
        (assert.equals 1 (_mock_dicts.metrics:get "proxy_requests_total{service=\"users\"}"))
        (assert.equals 2 (_mock_dicts.metrics:get "proxy_requests_total{service=\"orders\"}"))))

    (it "observe-latency increments +Inf bucket and count"
      (fn []
        (metrics.observe-latency "svc" 0.042)
        (assert.equals 1 (_mock_dicts.metrics:get "proxy_request_duration_seconds_bucket{service=\"svc\",le=\"+Inf\"}"))
        (assert.equals 1 (_mock_dicts.metrics:get "proxy_request_duration_seconds_count{service=\"svc\"}"))))

    (it "observe-latency increments only buckets >= duration (cumulative)"
      (fn []
        ;; 0.042s falls between 0.025 and 0.05 buckets.
        ;; Buckets at 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 and +Inf should be incremented.
        ;; Buckets at 0.005, 0.01, 0.025 should NOT be.
        (metrics.observe-latency "svc" 0.042)
        (assert.is_nil    (_mock_dicts.metrics:get "proxy_request_duration_seconds_bucket{service=\"svc\",le=\"0.025\"}"))
        (assert.equals 1  (_mock_dicts.metrics:get "proxy_request_duration_seconds_bucket{service=\"svc\",le=\"0.05\"}"))))

    (it "observe-latency with duration=0 increments all buckets"
      (fn []
        (metrics.observe-latency "svc" 0)
        (assert.equals 1 (_mock_dicts.metrics:get "proxy_request_duration_seconds_bucket{service=\"svc\",le=\"0.005\"}"))))

    (it "observe-latency accumulates sum"
      (fn []
        (metrics.observe-latency "svc" 0.1)
        (metrics.observe-latency "svc" 0.2)
        (let [s (_mock_dicts.metrics:get "proxy_request_duration_seconds_sum{service=\"svc\"}")]
          (assert.is_truthy (< (math.abs (- s 0.3)) 1e-9)))))

    (it "observe-latency appears in render output"
      (fn []
        (metrics.observe-latency "svc" 0.1)
        (let [out (metrics.render)]
          (assert.is_truthy (out:find "proxy_request_duration_seconds_bucket" 1 true)))))))
