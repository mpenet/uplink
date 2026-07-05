(local json (require :cjson))

(local {:rewrite-ref-str rewrite-ref
        :rewrite-refs! rewrite-refs!
        :prefix-components prefix-components
        :filter-paths filter-paths
        :parse-cache-ttl parse-cache-ttl
        :process process}
  (require :schema))

;; Shallow-merge two tables into a new table.
(fn merge [base extra]
  (let [out {}]
    (each [k v (pairs base)] (tset out k v))
    (each [k v (pairs extra)] (tset out k v))
    out))

;; Stub ngx.parse_http_time for Expires header tests.
(tset _G.ngx :parse_http_time
  (fn [s]
    (let [months {:Jan 1 :Feb 2 :Mar 3 :Apr 4 :May 5 :Jun 6
                  :Jul 7 :Aug 8 :Sep 9 :Oct 10 :Nov 11 :Dec 12}
          (d mon y h m sec) (s:match "(%d+) (%a+) (%d+) (%d+):(%d+):(%d+)")]
      (when d
        (+ (* (- (tonumber y) 1970) 31536000)
           (* (- (or (. months mon) 1) 1) 2592000)
           (* (tonumber d) 86400)
           (* (tonumber h) 3600)
           (* (tonumber m) 60)
           (tonumber sec))))))

;; ── rewrite-ref-str ─────────────────────────────────────────────────────────

(describe "rewrite-ref-str"
  (fn []
    (it "prefixes component name"
      (fn []
        (assert.equals "#/components/schemas/users__User"
          (rewrite-ref "users" "#/components/schemas/User"))))

    (it "uses custom prefix"
      (fn []
        (assert.equals "#/components/schemas/acme__User"
          (rewrite-ref "acme" "#/components/schemas/User"))))

    (it "leaves ref unchanged when prefix is false"
      (fn []
        (assert.equals "#/components/schemas/User"
          (rewrite-ref false "#/components/schemas/User"))))

    (it "handles requestBodies section"
      (fn []
        (assert.equals "#/components/requestBodies/svc__Body"
          (rewrite-ref "svc" "#/components/requestBodies/Body"))))

    (it "handles parameters section"
      (fn []
        (assert.equals "#/components/parameters/svc__Limit"
          (rewrite-ref "svc" "#/components/parameters/Limit"))))

    (it "leaves external refs unchanged"
      (fn []
        (assert.equals "other.json#/foo"
          (rewrite-ref "users" "other.json#/foo"))))

    (it "leaves non-component fragment refs unchanged"
      (fn []
        (assert.equals "#/foo/bar"
          (rewrite-ref "users" "#/foo/bar"))))))

;; ── rewrite-refs! ────────────────────────────────────────────────────────────

(describe "rewrite-refs!"
  (fn []
    (it "rewrites $ref at top level"
      (fn []
        (let [obj {"$ref" "#/components/schemas/User"}]
          (rewrite-refs! "svc" obj)
          (assert.equals "#/components/schemas/svc__User" (. obj "$ref")))))

    (it "rewrites deeply nested $ref"
      (fn []
        (let [obj {:a {:b {:c {"$ref" "#/components/schemas/Deep"}}}}]
          (rewrite-refs! "svc" obj)
          (assert.equals "#/components/schemas/svc__Deep"
            (. obj :a :b :c "$ref")))))

    (it "rewrites $refs inside arrays"
      (fn []
        (let [obj {:items [{"$ref" "#/components/schemas/Item"}]}]
          (rewrite-refs! "svc" obj)
          (assert.equals "#/components/schemas/svc__Item"
            (. obj :items 1 "$ref")))))

    (it "rewrites multiple $refs in same object"
      (fn []
        (let [obj {:a {"$ref" "#/components/schemas/A"}
                   :b {"$ref" "#/components/schemas/B"}}]
          (rewrite-refs! "svc" obj)
          (assert.equals "#/components/schemas/svc__A" (. obj :a "$ref"))
          (assert.equals "#/components/schemas/svc__B" (. obj :b "$ref")))))

    (it "does not rewrite non-ref string values"
      (fn []
        (let [obj {:description "some text"}]
          (rewrite-refs! "svc" obj)
          (assert.equals "some text" obj.description))))

    (it "is a no-op for non-table values"
      (fn []
        (assert.equals "hello" (rewrite-refs! "svc" "hello"))))))

;; ── prefix-components ────────────────────────────────────────────────────────

(describe "prefix-components"
  (fn []
    (it "prefixes names in schemas section"
      (fn []
        (let [r (prefix-components "svc" {:schemas {:User {:type "object"}}})]
          (assert.is_not_nil (. r.components.schemas "svc__User"))
          (assert.is_nil     (. r.components.schemas "User")))))

    (it "prefixes names across multiple sections"
      (fn []
        (let [r (prefix-components "svc"
                  {:schemas {:User {:type "object"}}
                   :requestBodies {:CreateUser {:content {}}}})]
          (assert.is_not_nil (. r.components.schemas "svc__User"))
          (assert.is_not_nil (. r.components.requestBodies "svc__CreateUser")))))

    (it "keeps original names when prefix is false"
      (fn []
        (let [r (prefix-components false {:schemas {:User {:type "object"}}})]
          (assert.is_not_nil (. r.components.schemas "User"))
          (assert.is_nil     (. r.components.schemas "false__User")))))

    (it "rewrites $refs inside components when prefix given"
      (fn []
        (let [schema {:properties {:a {"$ref" "#/components/schemas/Address"}}}
              r (prefix-components "svc" {:schemas {:User schema}})]
          (assert.equals "#/components/schemas/svc__Address"
            (. r.components.schemas "svc__User" :properties :a "$ref")))))

    (it "does not rewrite $refs when prefix is false"
      (fn []
        (let [schema {:properties {:a {"$ref" "#/components/schemas/Address"}}}
              r (prefix-components false {:schemas {:User schema}})]
          (assert.equals "#/components/schemas/Address"
            (. r.components.schemas "User" :properties :a "$ref")))))

    (it "populates hashes for each component"
      (fn []
        (let [r (prefix-components "svc" {:schemas {:User {:type "object"}}})]
          (assert.is_not_nil (. r.hashes.schemas "svc__User")))))

    (it "returns empty components and hashes for empty input"
      (fn []
        (let [r (prefix-components "svc" {})]
          (assert.same {} r.components)
          (assert.same {} r.hashes))))

    (it "handles multiple items in same section"
      (fn []
        (let [r (prefix-components "svc"
                  {:schemas {:A {:type "string"} :B {:type "integer"}}})]
          (assert.is_not_nil (. r.components.schemas "svc__A"))
          (assert.is_not_nil (. r.components.schemas "svc__B")))))))

;; ── parse-cache-ttl ──────────────────────────────────────────────────────────

(describe "parse-cache-ttl"
  (fn []
    (it "returns nil when no cache headers"
      (fn []
        (assert.is_nil (parse-cache-ttl {}))))

    (it "parses max-age"
      (fn []
        (assert.equals 300 (parse-cache-ttl {:cache-control "max-age=300"}))))

    (it "parses s-maxage"
      (fn []
        (assert.equals 600 (parse-cache-ttl {:cache-control "s-maxage=600"}))))

    (it "s-maxage takes priority over max-age"
      (fn []
        (assert.equals 600
          (parse-cache-ttl {:cache-control "s-maxage=600, max-age=300"}))))

    (it "no-cache returns 0"
      (fn []
        (assert.equals 0 (parse-cache-ttl {:cache-control "no-cache"}))))

    (it "no-store returns 0"
      (fn []
        (assert.equals 0 (parse-cache-ttl {:cache-control "no-store"}))))

    (it "accepts capitalized Cache-Control header"
      (fn []
        (assert.equals 120 (parse-cache-ttl {"Cache-Control" "max-age=120"}))))

    (it "Expires in the past returns 0"
      (fn []
        ;; Override parse_http_time to return a timestamp before ngx.now()
        (tset _G.ngx :parse_http_time (fn [] 0))
        (assert.equals 0
          (parse-cache-ttl {:expires "Thu, 01 Jan 1970 00:00:00 GMT"}))))

    (it "Expires in the future returns positive TTL"
      (fn []
        (tset _G.ngx :parse_http_time (fn [] (+ (ngx.now) 120)))
        (let [ttl (parse-cache-ttl {:expires "some future date"})]
          (assert.is_truthy (and ttl (> ttl 0))))))))

;; ── filter-paths ─────────────────────────────────────────────────────────────

(local open-svc {:name "svc" :upstream "http://x" :schema_url "http://x" :rules []})

(describe "filter-paths"
  (fn []
    (it "includes all ops when rules are empty"
      (fn []
        (let [paths {"/foo" {:get {:tags []} :post {:tags []}}}
              r (filter-paths open-svc paths)]
          (assert.is_not_nil (. r "/foo" :get))
          (assert.is_not_nil (. r "/foo" :post)))))

    (it "excludes ops that fail rules"
      (fn []
        (let [svc (merge open-svc {:rules [{:methods ["GET"]}]})
              paths {"/foo" {:get {:tags []} :delete {:tags []}}}
              r (filter-paths svc paths)]
          (assert.is_not_nil (. r "/foo" :get))
          (assert.is_nil     (. r "/foo" :delete)))))

    (it "drops entire path when all ops filtered out"
      (fn []
        (let [svc (merge open-svc {:rules [{:methods ["GET"]}]})
              paths {"/foo" {:delete {:tags []}}}
              r (filter-paths svc paths)]
          (assert.is_nil (. r "/foo")))))

    (it "preserves non-method keys on surviving path"
      (fn []
        (let [paths {"/foo" {:get {:tags []} :parameters [{:name "id"}]}}
              r (filter-paths open-svc paths)]
          (assert.is_not_nil (. r "/foo" :parameters)))))

    (it "drops non-method keys when all ops filtered out"
      (fn []
        (let [svc (merge open-svc {:rules [{:methods ["GET"]}]})
              paths {"/foo" {:delete {:tags []} :parameters [{:name "id"}]}}
              r (filter-paths svc paths)]
          (assert.is_nil (. r "/foo")))))

    (it "filters by path pattern"
      (fn []
        (let [svc (merge open-svc {:rules [{:paths ["/v1/*"]}]})
              paths {"/v1/users" {:get {:tags []}}
                     "/v2/users" {:get {:tags []}}}
              r (filter-paths svc paths)]
          (assert.is_not_nil (. r "/v1/users"))
          (assert.is_nil     (. r "/v2/users")))))

    (it "filters by tag"
      (fn []
        (let [svc (merge open-svc {:rules [{:tags ["public"]}]})
              paths {"/a" {:get {:tags ["public"]}}
                     "/b" {:get {:tags ["internal"]}}}
              r (filter-paths svc paths)]
          (assert.is_not_nil (. r "/a"))
          (assert.is_nil     (. r "/b")))))

    (it "returns empty table for empty paths input"
      (fn []
        (assert.same {} (filter-paths open-svc {}))))))

;; ── process (end-to-end with mock HTTP) ─────────────────────────────────────

(local base-svc
  {:name "svc" :upstream "http://svc:8080"
   :schema_url "http://svc:8080/openapi.json"
   :rules [] :component_prefix "svc"})

(fn json-response [body-tbl]
  {:status 200 :headers {"content-type" "application/json"}
   :body (json.encode body-tbl)})

(before_each (fn [] (reset_mocks)))

(describe "process"
  (fn []
    (it "returns openapi/info/paths/components/hashes on success"
      (fn []
        (set_http_response
          (json-response {:openapi "3.0.0"
                          :info {:title "T" :version "1"}
                          :paths {"/foo" {:get {:tags [] :responses {}}}}
                          :components {:schemas {:Foo {:type "object"}}}}))
        (let [r (process base-svc)]
          (assert.equals "3.0.0" r.openapi)
          (assert.is_not_nil r.paths)
          (assert.is_not_nil r.components)
          (assert.is_not_nil r.component-hashes))))

    (it "prefixes component names in output"
      (fn []
        (set_http_response
          (json-response {:openapi "3.0.0" :info {} :paths {}
                          :components {:schemas {:User {:type "object"}}}}))
        (let [r (process base-svc)]
          (assert.is_not_nil (. r.components.schemas "svc__User"))
          (assert.is_nil     (. r.components.schemas "User")))))

    (it "rewrites $refs in paths"
      (fn []
        (set_http_response
          (json-response {:openapi "3.0.0" :info {}
                          :paths {"/foo" {:get {:tags []
                                                :requestBody {"$ref" "#/components/requestBodies/Req"}}}}
                          :components {}}))
        (let [r (process base-svc)]
          (assert.equals "#/components/requestBodies/svc__Req"
            (. r.paths "/foo" :get :requestBody "$ref")))))

    (it "applies rules filtering to paths"
      (fn []
        (set_http_response
          (json-response {:openapi "3.0.0" :info {}
                          :paths {"/pub"  {:get    {:tags []}}
                                  "/priv" {:delete {:tags []}}}
                          :components {}}))
        (let [svc (merge base-svc {:rules [{:methods ["GET"]}]})
              r (process svc)]
          (assert.is_not_nil (. r.paths "/pub"))
          (assert.is_nil     (. r.paths "/priv")))))

    (it "parses upstream TTL from Cache-Control"
      (fn []
        (set_http_response
          {:status 200
           :headers {"content-type" "application/json" "cache-control" "max-age=60"}
           :body "{\"openapi\":\"3.0.0\",\"info\":{},\"paths\":{},\"components\":{}}"})
        (let [r (process base-svc)]
          (assert.equals 60 r.upstream-ttl))))

    (it "upstream-ttl is nil when no cache headers"
      (fn []
        (set_http_response
          (json-response {:openapi "3.0.0" :info {} :paths {} :components {}}))
        (let [r (process base-svc)]
          (assert.is_nil r.upstream-ttl))))

    (it "raises on HTTP connection error"
      (fn []
        (set_http_error "connection refused")
        (let [(ok err) (pcall process base-svc)]
          (assert.is_false ok)
          (assert.is_truthy (err:find "schema fetch failed")))))

    (it "raises on non-200 status"
      (fn []
        (set_http_response {:status 404 :headers {} :body ""})
        (let [(ok err) (pcall process base-svc)]
          (assert.is_false ok)
          (assert.is_truthy (err:find "404")))))))
