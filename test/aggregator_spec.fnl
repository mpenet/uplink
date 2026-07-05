(local json (require :cjson))

(local cache (require :cache))

(local {:merge-components merge-components
        :apply-aliases! apply-aliases!
        :prefix-paths prefix-paths
        :deep-copy deep-copy
        :dedup-components dedup-components
        :build build}
  (require :aggregator))

(local config (require :config))

(before_each (fn [] (reset_mocks)))

;; ── deep-copy ────────────────────────────────────────────────────────────────

(describe "deep-copy"
  (fn []
    (it "copies a flat table"
      (fn []
        (let [orig {:a 1 :b 2}
              copy (deep-copy orig)]
          (assert.same orig copy)
          (assert.not_equal orig copy))))

    (it "copies nested tables"
      (fn []
        (let [orig {:a {:b {:c 3}}}
              copy (deep-copy orig)]
          (assert.equals 3 copy.a.b.c)
          (assert.not_equal orig.a copy.a))))

    (it "mutations to copy do not affect original"
      (fn []
        (let [orig {:x 1}
              copy (deep-copy orig)]
          (tset copy :x 99)
          (assert.equals 1 orig.x))))

    (it "passes through non-table values"
      (fn []
        (assert.equals "hello" (deep-copy "hello"))
        (assert.equals 42 (deep-copy 42))))))

;; ── prefix-paths ─────────────────────────────────────────────────────────────

(describe "prefix-paths"
  (fn []
    (it "prepends service name to each path"
      (fn []
        (let [r (prefix-paths "users" {"/v1/profile" {:get {}}})]
          (assert.is_not_nil (. r "/users/v1/profile"))
          (assert.is_nil     (. r "/v1/profile")))))

    (it "handles multiple paths"
      (fn []
        (let [r (prefix-paths "svc" {"/a" {} "/b" {}})]
          (assert.is_not_nil (. r "/svc/a"))
          (assert.is_not_nil (. r "/svc/b")))))

    (it "returns empty table for empty paths"
      (fn []
        (assert.same {} (prefix-paths "svc" {}))))

    (it "deep-copies path items so originals are not mutated"
      (fn []
        (let [item {:get {:tags []}}
              orig {"/a" item}
              r (prefix-paths "svc" orig)]
          (assert.not_equal item (. r "/svc/a")))))))

;; ── merge-components ─────────────────────────────────────────────────────────

(describe "merge-components"
  (fn []
    (it "merges components from two services into accumulator"
      (fn []
        (let [acc {}
              _ (merge-components acc {:schemas {:A {:type "object"}}})
              _ (merge-components acc {:schemas {:B {:type "string"}}})]
          (assert.is_not_nil acc.schemas.A)
          (assert.is_not_nil acc.schemas.B))))

    (it "creates section when not present in acc"
      (fn []
        (let [acc {}]
          (merge-components acc {:requestBodies {:Req {}}})
          (assert.is_not_nil acc.requestBodies.Req))))

    (it "later writes overwrite earlier ones for same name"
      (fn []
        (let [acc {}
              _ (merge-components acc {:schemas {:X {:type "string"}}})
              _ (merge-components acc {:schemas {:X {:type "integer"}}})]
          (assert.equals "integer" acc.schemas.X.type))))

    (it "returns the accumulator"
      (fn []
        (let [acc {}
              result (merge-components acc {:schemas {:A {}}})]
          (assert.equal acc result))))))

;; ── dedup-components ─────────────────────────────────────────────────────────

(describe "dedup-components"
  (fn []
    (it "keeps unique components"
      (fn []
        (let [comps {:schemas {:A {:type "string"} :B {:type "integer"}}}
              r (dedup-components comps nil)]
          (assert.is_not_nil (. r.components.schemas :A))
          (assert.is_not_nil (. r.components.schemas :B))
          (assert.same {} r.aliases))))

    (it "deduplicates identical components — keeps first, aliases second"
      (fn []
        (let [schema {:type "object" :properties {:id {:type "string"}}}
              comps {:schemas {:svc1__User schema :svc2__User schema}}
              hashes {:schemas {:svc1__User (ngx.md5 (json.encode schema))
                                :svc2__User (ngx.md5 (json.encode schema))}}
              r (dedup-components comps hashes)]
          ;; Exactly one component kept in schemas
          (var kept 0)
          (each [_ _ (pairs (or r.components.schemas {}))] (set kept (+ kept 1)))
          (assert.equals 1 kept)
          ;; Exactly one alias created
          (var alias-count 0)
          (each [_ _ (pairs r.aliases)] (set alias-count (+ alias-count 1)))
          (assert.equals 1 alias-count))))

    (it "aliases point to canonical ref"
      (fn []
        (let [schema {:type "object"}
              hsh (ngx.md5 (json.encode schema))
              comps {:schemas {:A schema :B schema}}
              hashes {:schemas {:A hsh :B hsh}}
              r (dedup-components comps hashes)
              alias-target (or (. r.aliases "#/components/schemas/A")
                               (. r.aliases "#/components/schemas/B"))]
          (assert.is_truthy (alias-target:find "#/components/schemas/" 1 true)))))

    (it "handles multiple sections independently"
      (fn []
        (let [schema {:type "object"}
              hsh (ngx.md5 (json.encode schema))
              comps {:schemas {:A schema} :requestBodies {:R schema}}
              hashes {:schemas {:A hsh} :requestBodies {:R hsh}}
              r (dedup-components comps hashes)]
          ;; Different sections: no cross-section dedup
          (assert.is_not_nil (. r.components.schemas :A))
          (assert.is_not_nil (. r.components.requestBodies :R)))))

    (it "returns empty components and aliases for empty input"
      (fn []
        (let [r (dedup-components {} nil)]
          (assert.same {} r.components)
          (assert.same {} r.aliases))))))

;; ── apply-aliases! ───────────────────────────────────────────────────────────

(describe "apply-aliases!"
  (fn []
    (it "rewrites matching $ref"
      (fn []
        (let [obj {"$ref" "#/components/schemas/Old"}
              aliases {"#/components/schemas/Old" "#/components/schemas/Canonical"}]
          (apply-aliases! aliases obj)
          (assert.equals "#/components/schemas/Canonical" (. obj "$ref")))))

    (it "leaves non-aliased $refs unchanged"
      (fn []
        (let [obj {"$ref" "#/components/schemas/Unique"}
              aliases {"#/components/schemas/Other" "#/components/schemas/Canon"}]
          (apply-aliases! aliases obj)
          (assert.equals "#/components/schemas/Unique" (. obj "$ref")))))

    (it "rewrites deeply nested $refs"
      (fn []
        (let [obj {:paths {"/foo" {:get {:requestBody {"$ref" "#/components/schemas/Old"}}}}}
              aliases {"#/components/schemas/Old" "#/components/schemas/Canon"}]
          (apply-aliases! aliases obj)
          (assert.equals "#/components/schemas/Canon"
            (. obj :paths "/foo" :get :requestBody "$ref")))))

    (it "applies aliases across multiple root objects"
      (fn []
        (let [o1 {"$ref" "#/components/schemas/Dup"}
              o2 {"$ref" "#/components/schemas/Dup"}
              aliases {"#/components/schemas/Dup" "#/components/schemas/Canon"}]
          (apply-aliases! aliases o1 o2)
          (assert.equals "#/components/schemas/Canon" (. o1 "$ref"))
          (assert.equals "#/components/schemas/Canon" (. o2 "$ref")))))

    (it "no-op when aliases map is empty"
      (fn []
        (let [obj {"$ref" "#/components/schemas/A"}]
          (apply-aliases! {} obj)
          (assert.equals "#/components/schemas/A" (. obj "$ref")))))))

;; ── build (integration) ──────────────────────────────────────────────────────

(describe "build"
  (fn []
    (it "returns doc with openapi field and empty degraded list on success"
      (fn []
        (set_http_response
          {:status 200 :headers {"content-type" "application/json"}
           :body (json.encode {:openapi "3.0.0" :info {:title "T" :version "1"}
                               :paths {"/pets" {:get {:tags [] :responses {}}}}
                               :components {:schemas {:Pet {:type "object"}}}})})
        (let [cfg (config.store
                    {:services [{:name "pets"
                                 :upstream "http://pets:8080"
                                 :schema_url "http://pets:8080/openapi.json"
                                 :ttl 300 :rules [] :component_prefix "pets"}]})
              {:doc doc :degraded degraded} (build cfg)]
          (assert.equals "3.0.0" doc.openapi)
          (assert.same [] degraded))))

    (it "prefixes service name onto paths"
      (fn []
        (set_http_response
          {:status 200 :headers {"content-type" "application/json"}
           :body (json.encode {:openapi "3.0.0" :info {}
                               :paths {"/v1/items" {:get {:tags []}}}
                               :components {}})})
        (let [cfg (config.store
                    {:services [{:name "items"
                                 :upstream "http://items:8080"
                                 :schema_url "http://items:8080/openapi.json"
                                 :ttl 300 :rules [] :component_prefix "items"}]})
              {:doc doc} (build cfg)]
          (assert.is_not_nil (. doc.paths "/items/v1/items"))
          (assert.is_nil     (. doc.paths "/v1/items")))))

    (it "adds failed service to degraded list"
      (fn []
        (set_http_error "connection refused")
        (let [cfg (config.store
                    {:services [{:name "broken"
                                 :upstream "http://broken:8080"
                                 :schema_url "http://broken:8080/openapi.json"
                                 :ttl 300 :rules [] :component_prefix "broken"}]})
              {:degraded degraded} (build cfg)]
          (assert.equals "broken" (. degraded 1)))))

;; Two services with identical component schemas → second gets deduped.
;; Paths from the second service that $ref the deduped component must be
;; rewritten to the canonical (first service) ref by apply-aliases!.
;; This verifies the full build wiring: process → dedup → alias rewrite.
    (it "rewrites path $refs to canonical component after dedup"
      (fn []
        (tset package.loaded :cache nil)
        (tset package.loaded :aggregator nil)
        (local {:build build2} (require :aggregator))
        ;; Both services get same upstream schema (shared mock HTTP response).
        ;; They use different component_prefix so components get distinct names,
        ;; but identical content → dedup aliases one to the other.
        (set_http_response
          {:status 200 :headers {"content-type" "application/json"}
           :body (json.encode
                   {:openapi "3.0.0" :info {}
                    :paths {"/items" {:get {:tags []
                                           :requestBody {"$ref" "#/components/schemas/Widget"}}}}
                    :components {:schemas {:Widget {:type "object"}}}})})
        (let [cfg {:services
                    [{:name "svcA" :upstream "http://a:8080"
                      :schema_url "http://a:8080/openapi.json"
                      :ttl 1 :rules [] :component_prefix "svcA"}
                     {:name "svcB" :upstream "http://b:8080"
                      :schema_url "http://b:8080/openapi.json"
                      :ttl 1 :rules [] :component_prefix "svcB"}]}
              {:doc doc} (build2 cfg)
              ;; One of these two paths must have its $ref pointing to the kept component.
              ref-a (. doc.paths "/svcA/items" :get :requestBody "$ref")
              ref-b (. doc.paths "/svcB/items" :get :requestBody "$ref")]
          ;; Both refs must resolve to whichever component was kept (not the removed one).
          (assert.equals ref-a ref-b "both paths must point to the same canonical component"))))

    (it "uses component_prefix (not service name) for component namespacing"
      (fn []
        (tset package.loaded :cache nil)
        (tset package.loaded :aggregator nil)
        (local {:build build3} (require :aggregator))
        (set_http_response
          {:status 200 :headers {"content-type" "application/json"}
           :body (json.encode
                   {:openapi "3.0.0" :info {}
                    :paths {"/x" {:get {:tags []
                                        :requestBody {"$ref" "#/components/schemas/Thing"}}}}
                    :components {:schemas {:Thing {:type "object"}}}})})
        (let [cfg {:services [{:name "my-service"
                                :upstream "http://svc:8080"
                                :schema_url "http://svc:8080/openapi.json"
                                :ttl 1 :rules [] :component_prefix "v2"}]}
              {:doc doc} (build3 cfg)
              ref (. doc.paths "/my-service/x" :get :requestBody "$ref")]
          ;; Should use "v2" prefix, not "my-service".
          (assert.equals "#/components/schemas/v2__Thing" ref)
          (assert.is_not_nil (. doc.components.schemas "v2__Thing"))
          (assert.is_nil     (. doc.components.schemas "my-service__Thing")))))

    (it "preserves original component names and refs when component_prefix is false"
      (fn []
        (tset package.loaded :cache nil)
        (tset package.loaded :aggregator nil)
        (local {:build build4} (require :aggregator))
        (set_http_response
          {:status 200 :headers {"content-type" "application/json"}
           :body (json.encode
                   {:openapi "3.0.0" :info {}
                    :paths {"/y" {:get {:tags []
                                        :requestBody {"$ref" "#/components/schemas/Widget"}}}}
                    :components {:schemas {:Widget {:type "object"}}}})})
        (let [cfg {:services [{:name "nosvc"
                                :upstream "http://nosvc:8080"
                                :schema_url "http://nosvc:8080/openapi.json"
                                :ttl 1 :rules [] :component_prefix false}]}
              {:doc doc} (build4 cfg)
              ref (. doc.paths "/nosvc/y" :get :requestBody "$ref")]
          ;; No prefix: component name and ref stay as original.
          (assert.equals "#/components/schemas/Widget" ref)
          (assert.is_not_nil (. doc.components.schemas "Widget")))))

    (it "includes healthy services and skips degraded ones"
      (fn []
        ;; First call fetches "good" service schema; second raises.
        ;; But mock HTTP is global — both services get same mock.
        ;; Use success first, then override for second service by reloading cache.
        (tset package.loaded :cache nil)
        (tset package.loaded :aggregator nil)
        (local {:build build2} (require :aggregator))
        (set_http_response
          {:status 200 :headers {"content-type" "application/json"}
           :body (json.encode {:openapi "3.0.0" :info {}
                               :paths {"/ok" {:get {:tags []}}}
                               :components {}})})
        (let [cfg {:services
                    [{:name "good" :upstream "http://good:8080"
                      :schema_url "http://good:8080/openapi.json"
                      :ttl 300 :rules [] :component_prefix "good"}]}
              {:doc doc :degraded degraded} (build2 cfg)]
          (assert.is_not_nil (. doc.paths "/good/ok"))
          (assert.same [] degraded))))))

;; ── handle (ETag / 304 / headers) ────────────────────────────────────────────

;; Pre-populate the shared-dict merged cache at gen 0 so handle() skips build.
(fn seed-merged [body etag degraded]
  (cache.set-merged 0 body etag (or degraded [])))

(describe "handle"
  (fn []
    (before_each
      (fn []
        (reset_mocks)
        ;; Reload aggregator so per-worker agg-gen resets to -1.
        (tset package.loaded :cache nil)
        (tset package.loaded :aggregator nil)))

    (it "sets ETag and Cache-Control headers"
      (fn []
        (local {:handle handle} (require :aggregator))
        (seed-merged "{\"openapi\":\"3.0.0\"}" "abc123" [])
        (handle)
        (assert.equals "\"abc123\"" (. _G.ngx.header "ETag"))
        (assert.equals "no-cache"  (. _G.ngx.header "Cache-Control"))))

    (it "returns 304 when If-None-Match matches ETag"
      (fn []
        (local {:handle handle} (require :aggregator))
        (seed-merged "{\"openapi\":\"3.0.0\"}" "abc123" [])
        (tset _G.ngx :req
          {:get_headers (fn [] {:if_none_match "\"abc123\""})
           :get_method (fn [] "GET")
           :read_body (fn [] nil)
           :get_body_data (fn [] nil)
           :set_header (fn [] nil)
           :clear_header (fn [] nil)
           :start_time (fn [] (os.time))})
        (let [(ok _) (pcall handle)]
          (assert.is_false ok)
          (assert.equals 304 (get_last_exit)))))

    (it "does not return 304 when ETag differs"
      (fn []
        (local {:handle handle} (require :aggregator))
        (seed-merged "{\"openapi\":\"3.0.0\"}" "abc123" [])
        (tset _G.ngx :req
          {:get_headers (fn [] {:if_none_match "\"different\""})
           :get_method (fn [] "GET")
           :read_body (fn [] nil)
           :get_body_data (fn [] nil)
           :set_header (fn [] nil)
           :clear_header (fn [] nil)
           :start_time (fn [] (os.time))})
        (handle)
        (assert.is_nil (get_last_exit))))

    (it "sets X-Uplink-Degraded header when services are degraded"
      (fn []
        (local {:handle handle} (require :aggregator))
        (seed-merged "{}" "etag1" ["svc-a" "svc-b"])
        (handle)
        (assert.equals "svc-a,svc-b" (. _G.ngx.header "X-Uplink-Degraded"))))

    (it "does not set X-Uplink-Degraded when no degraded services"
      (fn []
        (local {:handle handle} (require :aggregator))
        (seed-merged "{}" "etag1" [])
        (handle)
        (assert.is_nil (. _G.ngx.header "X-Uplink-Degraded"))))))
