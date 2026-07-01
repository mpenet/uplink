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
    (local open {:include_paths ["*"] :include_tags [] :include_methods [] :exclude_paths []})

    (it "allows everything with open rules"
      (fn []
        (assert.is_true (allow open "/foo" "GET" []))
        (assert.is_true (allow open "/bar" "POST" ["tag1"]))))

    (it "respects include_paths"
      (fn []
        (local r {:include_paths ["/v1/*"] :include_tags [] :include_methods [] :exclude_paths []})
        (assert.is_true (allow r "/v1/users" "GET" []))
        (assert.is_false (allow r "/v2/users" "GET" []))))

    (it "respects exclude_paths"
      (fn []
        (local r {:include_paths ["*"] :include_tags [] :include_methods [] :exclude_paths ["/internal/*"]})
        (assert.is_false (allow r "/internal/debug" "GET" []))
        (assert.is_true (allow r "/api/users" "GET" []))))

    (it "respects include_methods"
      (fn []
        (local r {:include_paths ["*"] :include_tags [] :include_methods ["GET" "POST"] :exclude_paths []})
        (assert.is_true (allow r "/foo" "GET" []))
        (assert.is_false (allow r "/foo" "DELETE" []))))

    (it "method match is case-insensitive"
      (fn []
        (local r {:include_paths ["*"] :include_tags [] :include_methods ["GET"] :exclude_paths []})
        (assert.is_true (allow r "/foo" "get" []))))

    (it "respects include_tags when non-empty"
      (fn []
        (local r {:include_paths ["*"] :include_tags ["orders"] :include_methods [] :exclude_paths []})
        (assert.is_true (allow r "/foo" "GET" ["orders" "internal"]))
        (assert.is_false (allow r "/foo" "GET" ["users"]))
        (assert.is_false (allow r "/foo" "GET" []))))

    (it "empty include_tags disables tag filter"
      (fn []
        (assert.is_true (allow open "/foo" "GET" []))
        (assert.is_true (allow open "/foo" "GET" ["anything"]))))

    (it "exclude overrides include"
      (fn []
        (local r {:include_paths ["*"] :include_tags [] :include_methods [] :exclude_paths ["*"]})
        (assert.is_false (allow r "/foo" "GET" []))))))
