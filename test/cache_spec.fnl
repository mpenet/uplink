(var cache nil)

(before_each
  (fn []
    (reset_mocks)
    (tset package.loaded :cache nil)
    (set cache (require :cache))))

(describe "cache set/get"
  (fn []
    (it "returns nil for unknown key"
      (fn []
        (assert.is_nil (cache.get "missing"))))

    (it "stores and retrieves a value"
      (fn []
        (cache.set "k1" {:name "alice"} 300)
        (let [v (cache.get "k1")]
          (assert.is_not_nil v)
          (assert.equals "alice" v.name))))

    (it "delete removes value"
      (fn []
        (cache.set "k2" {:x 1} 300)
        (cache.delete "k2")
        (assert.is_nil (cache.get "k2"))))))

(describe "get-or-fetch"
  (fn []
    (it "calls thunk on cold miss and caches result"
      (fn []
        (var calls 0)
        (fn thunk [] (set calls (+ calls 1)) {:value {:n calls} :ttl 300})
        (let [v (cache.get-or-fetch "mykey" 300 thunk)]
          (assert.equals 1 calls)
          (assert.equals 1 v.n))
        (let [v2 (cache.get-or-fetch "mykey" 300 thunk)]
          (assert.equals 1 calls)
          (assert.equals 1 v2.n))))

    (it "re-fetches when entry is stale"
      (fn []
        (let [json (require :cjson)
              d _mock_dicts.cache
              nul (string.char 0)]
          (d:set "stale" (json.encode {:ttl 10 :fetched_at (- (ngx.now) 999) :gen 1}) 0)
          (d:set (.. "stale" nul "v") (json.encode {:msg "old"}) 0)
          (d:set (.. "stale" nul "g") 1 0))
        (var calls 0)
        (fn thunk [] (set calls (+ calls 1)) {:value {:msg "new"} :ttl 300})
        (let [v (cache.get-or-fetch "stale" 300 thunk)]
          (assert.equals 1 calls)
          (assert.equals "new" v.msg))))))

(describe "force-refresh"
  (fn []
    (it "returns true on success and bumps schema-gen"
      (fn []
        (let [gen0 (cache.get-schema-gen)
              ok (cache.force-refresh "k" 300 (fn [] {:value {:x 1} :ttl 300}))]
          (assert.is_true ok)
          (assert.equals (+ gen0 1) (cache.get-schema-gen)))))

    (it "returns false on thunk error"
      (fn []
        (let [ok (cache.force-refresh "k" 300 (fn [] (error "upstream down")))]
          (assert.is_false ok))))

    (it "updates cached value on success"
      (fn []
        (cache.force-refresh "k2" 300 (fn [] {:value {:n 42} :ttl 300}))
        (assert.equals 42 (. (cache.get "k2") :n))))))

(describe "get-merged / set-merged"
  (fn []
    (it "returns nil before any set"
      (fn []
        (assert.is_nil (cache.get-merged))))

    (it "round-trips body, etag, gen, and degraded"
      (fn []
        (cache.set-merged 7 "{\"openapi\":\"3.0.0\"}" "abc123" ["svc-a"])
        (let [m (cache.get-merged)]
          (assert.equals 7 m.gen)
          (assert.equals "{\"openapi\":\"3.0.0\"}" m.body)
          (assert.equals "abc123" m.etag)
          (assert.same ["svc-a"] m.degraded))))

    (it "overwrites previous merged entry"
      (fn []
        (cache.set-merged 1 "old" "etag1" [])
        (cache.set-merged 2 "new" "etag2" [])
        (let [m (cache.get-merged)]
          (assert.equals 2 m.gen)
          (assert.equals "new" m.body))))

    (it "returns empty degraded list when none set"
      (fn []
        (cache.set-merged 1 "body" "etag" [])
        (assert.same [] (. (cache.get-merged) :degraded))))))

(describe "stale fallback"
  (fn []
    (it "serves stale value when refresh fails"
      (fn []
        (let [json (require :cjson)
              d _mock_dicts.cache
              nul (string.char 0)]
          ;; Plant a stale entry.
          (d:set "svc" (json.encode {:ttl 10 :fetched_at (- (ngx.now) 999) :gen 1}) 0)
          (d:set (.. "svc" nul "v") (json.encode {:msg "stale-value"}) 0)
          (d:set (.. "svc" nul "g") 1 0))
        (let [v (cache.get-or-fetch "svc" 300 (fn [] (error "upstream down")))]
          (assert.equals "stale-value" v.msg))))))

(describe "get-schema-gen"
  (fn []
    (it "starts at 0"
      (fn []
        (assert.equals 0 (cache.get-schema-gen))))

    (it "increments with each force-refresh"
      (fn []
        (cache.force-refresh "a" 300 (fn [] {:value {} :ttl 300}))
        (cache.force-refresh "b" 300 (fn [] {:value {} :ttl 300}))
        (assert.equals 2 (cache.get-schema-gen))))))
