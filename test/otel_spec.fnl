(set package.path (.. "./lib/?.lua;" package.path))
(var otel nil)
(local dk (require :dkjson))

(fn decode-span [slot]
  (let [raw (_mock_dicts.otel:get (.. "s:" slot))]
    (assert raw (.. "no span at slot " slot))
    (dk.decode raw)))

(before_each
  (fn []
    (reset_mocks)
    (tset package.loaded :otel nil)
    (set otel (require :otel))))

(describe "otel.push!"
  (fn []
    (it "writes a span to the shared dict"
      (fn []
        (otel.push! "users")
        (assert.equals 1 (_mock_dicts.otel:get :count))
        (assert.is_truthy (_mock_dicts.otel:get "s:0"))))

    (it "increments count on successive pushes"
      (fn []
        (otel.push! "users")
        (otel.push! "users")
        (otel.push! "orders")
        (assert.equals 3 (_mock_dicts.otel:get :count))))

    (it "wraps slot index at BUFFER_SIZE"
      (fn []
        (_mock_dicts.otel:set :count 999 0)
        (otel.push! "users")
        (assert.is_truthy (_mock_dicts.otel:get "s:999"))
        (_mock_dicts.otel:set :count 1000 0)
        (otel.push! "users")
        (assert.is_truthy (_mock_dicts.otel:get "s:0"))))

    (it "includes service name in span"
      (fn []
        (otel.push! "payments")
        (assert.equals "proxy payments" (. (decode-span 0) :name))))

    (it "includes http.status_code attribute"
      (fn []
        (tset _G.ngx :status 404)
        (otel.push! "users")
        (let [attrs {}]
          (each [_ a (ipairs (. (decode-span 0) :attributes))]
            (tset attrs a.key a.value))
          (assert.equals 404 (. attrs "http.status_code" :intValue)))))

    (it "sets error status for 5xx"
      (fn []
        (tset _G.ngx :status 502)
        (otel.push! "users")
        (assert.equals 2 (. (decode-span 0) :status :code))))

    (it "sets ok status for 2xx"
      (fn []
        (tset _G.ngx :status 200)
        (otel.push! "users")
        (assert.equals 1 (. (decode-span 0) :status :code))))

    (it "sets parentSpanId when traceparent is present"
      (fn []
        (tset _G.ngx.var :traceparent
          "00-aabbccddeeff00112233445566778899-0011223344556677-01")
        (otel.push! "users")
        (assert.is_truthy (. (decode-span 0) :parentSpanId))))

    (it "omits parentSpanId when traceparent absent"
      (fn []
        (tset _G.ngx.var :traceparent "")
        (otel.push! "users")
        (assert.is_nil (. (decode-span 0) :parentSpanId))))))

(describe "otel.flush"
  (fn []
    (it "posts spans to collector and advances flushed cursor"
      (fn []
        (otel.push! "users")
        (otel.push! "orders")
        (otel.flush {:endpoint "http://collector:4318/v1/traces"
                     :service_name "ladon"
                     :batch_size 100})
        (assert.equals 2 (_mock_dicts.otel:get :flushed))))

    (it "does not repost already-flushed spans"
      (fn []
        (let [cfg {:endpoint "http://collector:4318/v1/traces" :batch_size 100}]
          (otel.push! "users")
          (otel.flush cfg)
          (assert.equals 1 (_mock_dicts.otel:get :flushed))
          (otel.push! "orders")
          (otel.flush cfg)
          (assert.equals 2 (_mock_dicts.otel:get :flushed)))))

    (it "skips flush when nothing pending"
      (fn []
        (otel.flush {:endpoint "http://collector:4318/v1/traces" :batch_size 100})
        (assert.is_nil (_mock_dicts.otel:get :flushed))))))
