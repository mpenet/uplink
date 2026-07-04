;; Merges all service schemas into a single OpenAPI 3.0 document at /openapi.json.
;;
;; build() fetches each service's processed schema from the cache (triggering a
;; network fetch on cold miss), prefixes paths (/svc/...) and component names
;; (Foo → svc__Foo), deduplicates identical components across services, and
;; rewrites $refs. Services whose schema is unavailable are excluded from the
;; document and collected in the degraded list.
;;
;; handle() serves /openapi.json with ETag/304 support. After building, the
;; encoded body is written to the shared dict keyed by schema generation counter.
;; Subsequent workers that see the same gen reuse the shared dict body without
;; rebuilding. Per-worker vars (agg-*) skip the shared dict read entirely when
;; the gen has not changed since the last request on this worker.

(local json (require :cjson))
(local config-mod (require :config))
(local schema-mod (require :schema))
(local cache (require :cache))
(local metrics (require :metrics))

;; Per-worker merged schema cache. Rebuilt only when schema gen changes.
(var agg-gen -1)
(var agg-body nil)
(var agg-etag nil)
(var agg-degraded [])

(fn get-cfg [] (config-mod.get))

(fn merge-components [acc components]
  (each [section items (pairs components)]
    (when (not (. acc section))
      (tset acc section {}))
    (each [name schema (pairs items)]
      (tset (. acc section) name schema)))
  acc)

(fn merge-hashes [acc hashes]
  (each [section names (pairs hashes)]
    (when (not (. acc section))
      (tset acc section {}))
    (each [name h (pairs names)]
      (tset (. acc section) name h)))
  acc)

;; Deep-copy a plain table (no cycles, no metatables — safe for JSON-derived data).
(fn deep-copy [obj]
  (if (not= (type obj) :table)
    obj
    (let [copy {}]
      (each [k v (pairs obj)]
        (tset copy k (deep-copy v)))
      copy)))

(fn prefix-paths [service-name paths]
  (let [out {}]
    (each [path item (pairs paths)]
      ;; Copy each path-item so apply-aliases! does not mutate the worker cache.
      (tset out (.. "/" service-name path) (deep-copy item)))
    out))

;; Deduplicate identical components using pre-computed hashes where available.
;; Falls back to computing hash only when pre-computed hash is absent.
;; Returns {:components <deduped> :aliases {dup-ref → canonical-ref}}.
;;
;; Note: dedup is best-effort. cjson key ordering is unspecified, so two
;; semantically identical schemas may hash differently (false negatives only).
(fn dedup-components [components hashes]
  (let [seen {}
        aliases {}
        clean {}]
    (each [section items (pairs components)]
      (tset seen section {})
      (each [name schema (pairs items)]
        (let [h (or (and hashes (. hashes section) (. (. hashes section) name))
                    (ngx.md5 (json.encode schema)))
              ref (.. "#/components/" section "/" name)]
          (if (. seen section h)
            (tset aliases ref (.. "#/components/" section "/" (. seen section h)))
            (do
              (tset (. seen section) h name)
              (when (not (. clean section))
                (tset clean section {}))
              (tset (. clean section) name schema))))))
    {:components clean :aliases aliases}))

;; Walk all root objects in a single pass, rewriting $ref via aliases.
(fn apply-aliases! [aliases ...]
  (fn walk [obj]
    (when (= (type obj) :table)
      (each [k v (pairs obj)]
        (if (and (= k "$ref") (. aliases v))
          (tset obj k (. aliases v))
          (walk v)))))
  (each [_ obj (ipairs [...])]
    (walk obj)))

(fn get-service-schema [service]
  (cache.get-or-fetch
    service.name
    service.ttl
    (fn []
      (let [schema (schema-mod.process service)
            ttl (or schema.upstream-ttl service.ttl)]
        (when schema.upstream-ttl
          (ngx.log ngx.DEBUG
            "upstream TTL=" schema.upstream-ttl "s service=" service.name))
        {:value schema :ttl ttl}))))

(fn build [cfg]
  (let [all-paths {}
        all-components {}
        all-hashes {}
        degraded []]
    (each [_ service (ipairs cfg.services)]
      (let [(ok result) (pcall get-service-schema service)]
        (if ok
          (do
            (metrics.cache-result service.name :ok)
            (each [path item (pairs (prefix-paths service.name result.paths))]
              (tset all-paths path item))
            (merge-components all-components (or result.components {}))
            (merge-hashes all-hashes (or result.component-hashes {})))
          (do
            (metrics.cache-result service.name :error)
            (ngx.log ngx.ERR
              "service schema unavailable, skipping. service=" service.name
              " error=" result)
            (table.insert degraded service.name)))))
    (let [{:components deduped :aliases aliases} (dedup-components all-components all-hashes)]
      (apply-aliases! aliases all-paths deduped)
      {:doc {:openapi    "3.0.0"
             :info       {:title "Uplink API Gateway" :version "1.0.0"}
             :paths      all-paths
             :components deduped}
       :degraded degraded})))

;; Serve aggregated schema.
;; On gen change: check shared dict first (another worker may have already built
;; this gen). If not found, build, encode, store in shared dict for other workers.
;; Supports ETag / 304 to skip retransmission when schema is unchanged.
(fn handle []
  (let [gen (cache.get-schema-gen)]
    (when (not= gen agg-gen)
      (let [merged (cache.get-merged)]
        (if (and merged (= merged.gen gen))
          (do
            (set agg-body     merged.body)
            (set agg-etag     merged.etag)
            (set agg-degraded merged.degraded)
            (set agg-gen      gen))
          (let [cfg (get-cfg)
                {:doc doc :degraded degraded} (build cfg)
                body (json.encode doc)
                etag (ngx.md5 body)]
            (set agg-body     body)
            (set agg-etag     etag)
            (set agg-degraded degraded)
            (set agg-gen      gen)
            (cache.set-merged gen body etag degraded)))))
    (tset ngx.header :etag (.. "\"" agg-etag "\""))
    (tset ngx.header :cache_control "no-cache")
    (when (> (# agg-degraded) 0)
      (tset ngx.header :x_uplink_degraded (table.concat agg-degraded ",")))
    (let [inm (. (ngx.req.get_headers) :if_none_match)]
      (if (and inm (= inm (.. "\"" agg-etag "\"")))
        (ngx.exit 304)
        (do
          (tset ngx.header :content_type "application/json; charset=utf-8")
          (ngx.say agg-body))))))

{:build build
 :handle handle
 :get-service-schema get-service-schema
 :dedup-components dedup-components}
