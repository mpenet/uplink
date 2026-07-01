(local {:build-route-table build :match-route match-route} (require :proxy))

(fn make-cfg [names]
  (let [services []]
    (each [_ name (ipairs names)]
      (table.insert services {:name name :upstream (.. "http://" name ":8080")}))
    {:services services}))

(describe "build-route-table"
  (fn []
    (it "builds prefix entries from services"
      (fn []
        (let [rt (build (make-cfg ["users" "orders"]))
              prefixes {}]
          (assert.equals 2 (# rt))
          (each [_ e (ipairs rt)] (tset prefixes e.prefix true))
          (assert.is_true (. prefixes "/users"))
          (assert.is_true (. prefixes "/orders")))))

    (it "sorts longer prefixes first"
      (fn []
        (let [rt (build (make-cfg ["a" "ab" "abc"]))]
          (assert.equals "/abc" (. rt 1 :prefix))
          (assert.equals "/ab" (. rt 2 :prefix))
          (assert.equals "/a" (. rt 3 :prefix)))))))

(describe "match-route"
  (fn []
    (var rt nil)

    (before_each
      (fn []
        (set rt (build (make-cfg ["users" "orders"])))))

    (it "matches exact prefix"
      (fn []
        (let [e (match-route rt "/users")]
          (assert.is_not_nil e)
          (assert.equals "/users" e.prefix))))

    (it "matches prefix with trailing path"
      (fn []
        (let [e (match-route rt "/users/v1/profile")]
          (assert.is_not_nil e)
          (assert.equals "/users" e.prefix))))

    (it "does not match partial prefix (no slash boundary)"
      (fn []
        (assert.is_nil (match-route rt "/userssettings"))))

    (it "returns nil for unknown prefix"
      (fn []
        (assert.is_nil (match-route rt "/unknown/path"))))

    (it "returns nil for root path"
      (fn []
        (assert.is_nil (match-route rt "/"))))

    (it "picks longer match when prefixes overlap"
      (fn []
        (let [rt2 (build (make-cfg ["users" "users-v2"]))
              e (match-route rt2 "/users-v2/profile")]
          (assert.equals "/users-v2" e.prefix))))))
