(local config (require :config))
(var router nil)

(fn make-svc [overrides]
  (let [base {:name "users" :upstream "http://users-svc:8080"
              :schema_url "http://users-svc:8080/openapi.json" :ttl 300
              :rules {:include_paths ["*"] :include_tags []
                      :include_methods ["GET" "POST" "PUT" "DELETE" "PATCH"]
                      :exclude_paths []}}]
    (each [k v (pairs (or overrides {}))]
      (tset base k v))
    base))

(fn load-service [svc]
  (config.store-in-shared {:services [svc]}))

(before_each
  (fn []
    (reset_mocks)
    (tset package.loaded :router nil)
    (load-service (make-svc {}))
    (set router (require :router))))

(describe "router.access"
  (fn []
    (it "sets upstream_path stripping service prefix"
      (fn []
        (tset _G.ngx.var :request_uri "/users/v1/profile?foo=bar")
        (router.access)
        (assert.equals "/v1/profile?foo=bar" _G.ngx.var.upstream_path)))

    (it "sets upstream_path to / for exact prefix match"
      (fn []
        (tset _G.ngx.var :request_uri "/users")
        (router.access)
        (assert.equals "/" _G.ngx.var.upstream_path)))

    (it "sets traceparent variable"
      (fn []
        (router.access)
        (assert.is_truthy (_G.ngx.var.traceparent:match "^00%-"))))

    (it "propagates existing valid traceparent trace-id"
      (fn []
        (tset _G.ngx :req
          {:get_headers (fn []
                          {:traceparent "00-aabbccddeeff00112233445566778899-0011223344556677-01"})
           :get_method (fn [] "GET")
           :read_body (fn [] nil)
           :get_body_data (fn [] nil)})
        (router.access)
        (assert.is_truthy
          (_G.ngx.var.traceparent:match "^00%-aabbccddeeff00112233445566778899%-"))))

    (it "exits 503 when circuit is open"
      (fn []
        (let [d _mock_dicts.circuit]
          (d:set "cb:users:state" "open" 0)
          (d:set "cb:users:opened" (- (os.time) 1) 0))
        (let [(ok _) (pcall router.access)]
          (assert.is_false ok)
          (assert.equals 503 (get_last_exit)))))

    (it "exits 429 when rate limited"
      (fn []
        (set_rl_delay false)
        (load-service (make-svc {:rate_limit {:requests_per_second 1 :burst 0}}))
        (tset package.loaded :router nil)
        (set router (require :router))
        (let [(ok _) (pcall router.access)]
          (assert.is_false ok)
          (assert.equals 429 (get_last_exit)))))

    (it "exits 404 for unknown service name"
      (fn []
        (tset _G.ngx.var :svc_name "nonexistent")
        (let [(ok _) (pcall router.access)]
          (assert.is_false ok)
          (assert.equals 404 (get_last_exit)))))))

(describe "router.on_response"
  (fn []
    (it "calls circuit on-failure for 5xx"
      (fn []
        (load-service (make-svc {:circuit_breaker {:threshold 1 :open_ttl 30}}))
        (tset package.loaded :router nil)
        (set router (require :router))
        (tset _G.ngx :status 502)
        (router.on_response)
        (assert.equals "open"
          (_mock_dicts.circuit:get "cb:users:state"))))

    (it "calls circuit on-success for 2xx"
      (fn []
        (let [d _mock_dicts.circuit]
          (d:set "cb:users:state" "open" 0)
          (d:set "cb:users:fails" 5 0))
        (tset _G.ngx :status 200)
        (router.on_response)
        (assert.is_nil (_mock_dicts.circuit:get "cb:users:state"))))))

(describe "router.access header manipulation"
  (fn []
    (it "injects request headers upstream"
      (fn []
        (load-service (make-svc {:headers {:request {:set {"X-Tenant" "acme"}}}}))
        (tset package.loaded :router nil)
        (set router (require :router))
        (router.access)
        (assert.equals "acme" (. (_G.ngx.req.get_headers) "X-Tenant"))))

    (it "strips request headers before forwarding"
      (fn []
        (load-service (make-svc {:headers {:request {:strip ["content-type"]}}}))
        (tset package.loaded :router nil)
        (set router (require :router))
        (router.access)
        (assert.is_nil (. (_G.ngx.req.get_headers) "content-type"))))))

(describe "router.on_response header manipulation"
  (fn []
    (it "injects response headers"
      (fn []
        (load-service (make-svc {:headers {:response {:set {"X-Gateway" "ladon"}}}}))
        (tset package.loaded :router nil)
        (set router (require :router))
        (tset _G.ngx :status 200)
        (router.on_response)
        (assert.equals "ladon" (. _G.ngx.header "X-Gateway"))))

    (it "strips response headers"
      (fn []
        (tset _G.ngx.header "X-Powered-By" "OpenResty")
        (load-service (make-svc {:headers {:response {:strip ["X-Powered-By"]}}}))
        (tset package.loaded :router nil)
        (set router (require :router))
        (tset _G.ngx :status 200)
        (router.on_response)
        (assert.is_nil (. _G.ngx.header "X-Powered-By"))))))

(describe "router.log"
  (fn []
    (it "records proxy_requests_total"
      (fn []
        (tset _G.ngx :status 200)
        (router.log)
        (assert.equals 1
          (_mock_dicts.metrics:get "proxy_requests_total{service=\"users\"}"))))

    (it "records proxy_errors_total on 5xx"
      (fn []
        (tset _G.ngx :status 500)
        (router.log)
        (assert.equals 1
          (_mock_dicts.metrics:get "proxy_errors_total{service=\"users\",code=\"500\"}"))))))
