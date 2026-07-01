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

    (it "counters for different services are independent"
      (fn []
        (metrics.proxy-request "users")
        (metrics.proxy-request "orders")
        (metrics.proxy-request "orders")
        (assert.equals 1 (_mock_dicts.metrics:get "proxy_requests_total{service=\"users\"}"))
        (assert.equals 2 (_mock_dicts.metrics:get "proxy_requests_total{service=\"orders\"}"))))))
