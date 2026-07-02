(local {:allow? allow :wildcard-match? wildcard :matches-any? matches-any}
  (require :rules))

(describe "wildcard-match?"
  (fn []
    (it "* matches anything"
      (fn []
        (assert.is_true (wildcard "*" "/foo"))
        (assert.is_true (wildcard "*" ""))))

    (it "exact match"
      (fn []
        (assert.is_true (wildcard "/foo" "/foo"))
        (assert.is_false (wildcard "/foo" "/bar"))))

    (it "prefix/* matches paths with that prefix"
      (fn []
        (assert.is_true (wildcard "/v1/*" "/v1/"))
        (assert.is_true (wildcard "/v1/*" "/v1/users"))
        (assert.is_false (wildcard "/v1/*" "/v2/users"))))))

(describe "matches-any?"
  (fn []
    (it "returns true when any pattern matches"
      (fn []
        (assert.is_true (matches-any ["/a" "/b" "/c"] "/b"))))

    (it "returns false when nothing matches"
      (fn []
        (assert.is_false (matches-any ["/a" "/b"] "/c"))))

    (it "returns false for empty list"
      (fn []
        (assert.is_false (matches-any [] "/a"))))))

(describe "allow?"
  (fn []
    (local open {})

    (it "allows everything with empty rules"
      (fn []
        (assert.is_true (allow open "/foo" "GET" []))
        (assert.is_true (allow open "/bar" "POST" ["tag1"]))))

    (it "paths whitelist"
      (fn []
        (local r {:paths ["/v1/*"]})
        (assert.is_true (allow r "/v1/users" "GET" []))
        (assert.is_false (allow r "/v2/users" "GET" []))))

    (it "paths negation excludes matching paths"
      (fn []
        (local r {:paths ["!/internal/*"]})
        (assert.is_false (allow r "/internal/debug" "GET" []))
        (assert.is_true (allow r "/api/users" "GET" []))))

    (it "paths negation wins over positive match"
      (fn []
        (local r {:paths ["*" "!/internal/*"]})
        (assert.is_false (allow r "/internal/debug" "GET" []))
        (assert.is_true (allow r "/api/users" "GET" []))))

    (it "methods whitelist"
      (fn []
        (local r {:methods ["GET" "POST"]})
        (assert.is_true (allow r "/foo" "GET" []))
        (assert.is_false (allow r "/foo" "DELETE" []))))

    (it "methods negation"
      (fn []
        (local r {:methods ["!DELETE"]})
        (assert.is_true (allow r "/foo" "GET" []))
        (assert.is_false (allow r "/foo" "DELETE" []))))

    (it "method match is case-insensitive"
      (fn []
        (local r {:methods ["GET"]})
        (assert.is_true (allow r "/foo" "get" []))))

    (it "tags whitelist when non-empty"
      (fn []
        (local r {:tags ["orders"]})
        (assert.is_true (allow r "/foo" "GET" ["orders" "internal"]))
        (assert.is_false (allow r "/foo" "GET" ["users"]))
        (assert.is_false (allow r "/foo" "GET" []))))

    (it "tags negation"
      (fn []
        (local r {:tags ["!internal"]})
        (assert.is_true (allow r "/foo" "GET" ["orders"]))
        (assert.is_false (allow r "/foo" "GET" ["internal"]))))

    (it "empty tags disables tag filter"
      (fn []
        (assert.is_true (allow open "/foo" "GET" []))
        (assert.is_true (allow open "/foo" "GET" ["anything"]))))))
