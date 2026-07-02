(set package.path (.. "./lib/?.lua;" package.path))
(var circuit nil)

(fn make-svc [overrides]
  (let [base {:name "users" :circuit_breaker {:threshold 3 :open_ttl 10}}]
    (each [k v (pairs (or overrides {}))]
      (tset base k v))
    base))

(before_each
  (fn []
    (reset_mocks)
    (tset package.loaded :circuit nil)
    (set circuit (require :circuit))))

(describe "circuit.allow?"
  (fn []
    (it "allows when closed"
      (fn []
        (assert.is_truthy (circuit.allow? (make-svc {})))))

    (it "rejects when open and ttl not expired"
      (fn []
        (let [d _mock_dicts.circuit]
          (d:set "cb:users:state" "open" 0)
          (d:set "cb:users:opened" (ngx.now) 0))
        (assert.is_false (circuit.allow? (make-svc {})))))

    (it "admits exactly one probe when ttl expired"
      (fn []
        (let [d _mock_dicts.circuit]
          (d:set "cb:users:state" "open" 0)
          (d:set "cb:users:opened" (- (ngx.now) 20) 0))
        (let [svc (make-svc {})
              r1 (circuit.allow? svc)
              r2 (circuit.allow? svc)]
          (assert.equals "probe" r1)
          (assert.is_false r2))))

    (it "allows normally after circuit closes"
      (fn []
        (assert.is_truthy (circuit.allow? (make-svc {})))))))

(describe "circuit.on-failure!"
  (fn []
    (it "opens circuit after threshold failures"
      (fn []
        (let [svc (make-svc {})]
          (circuit.on-failure! svc)
          (circuit.on-failure! svc)
          (circuit.on-failure! svc)
          (assert.equals "open" (_mock_dicts.circuit:get "cb:users:state")))))

    (it "clears probe key when reopening"
      (fn []
        (let [svc (make-svc {})
              d _mock_dicts.circuit]
          (d:set "cb:users:probe" true 0)
          (circuit.on-failure! svc)
          (circuit.on-failure! svc)
          (circuit.on-failure! svc)
          (assert.is_nil (d:get "cb:users:probe")))))))

(describe "circuit.on-success!"
  (fn []
    (it "closes circuit and clears probe"
      (fn []
        (let [svc (make-svc {})
              d _mock_dicts.circuit]
          (d:set "cb:users:state" "open" 0)
          (d:set "cb:users:probe" true 0)
          (d:set "cb:users:fails" 3 0)
          (circuit.on-success! svc)
          (assert.is_nil (d:get "cb:users:state"))
          (assert.is_nil (d:get "cb:users:probe"))
          (assert.equals 0 (d:get "cb:users:fails")))))))
