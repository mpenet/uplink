;; Fetches and processes a single service's OpenAPI 3.x schema.
;;
;; process() is the main entry point:
;;   1. Fetches schema_url via resty.http (JSON or YAML; YAML requires lyaml)
;;   2. Filters paths by service rules (path/method/tag)
;;   3. Rewrites all $refs in paths to use namespaced component names
;;   4. Prefixes all component names with the service name (Foo → svc__Foo)
;;   5. Returns {:openapi :info :paths :components :component-hashes :upstream-ttl}
;;
;; component-hashes carries pre-computed MD5s so aggregator.fnl can deduplicate
;; across services without re-hashing on every merge.
;;
;; upstream-ttl is parsed from Cache-Control/Expires and overrides config ttl when
;; present. nil means no TTL directive was found in the response headers.
;;
;; When service.tls.cert/key are set the schema fetch uses client TLS (mTLS),
;; matching the credentials used for proxied upstream requests.

(local http (require :resty.http))
(local json (require :cjson))
(local rules-mod (require :rules))
(local metrics (require :metrics))

;; lyaml is optional; YAML schema URLs fail gracefully when absent.
(local (lyaml-ok lyaml) (pcall require :lyaml))

(local http-methods
  {:get true :post true :put true :delete true
   :patch true :options true :head true :trace true})

(local schema-fetch-timeout-ms 5000)
(local keepalive-timeout-ms 10000)
(local keepalive-pool-size 10)

;; Parse Cache-Control / Expires headers into a TTL in seconds.
;; Priority: s-maxage > max-age > Expires.
;; no-cache / no-store → 0 (always revalidate; stale fallback still applies).
(fn parse-cache-ttl [headers]
  (let [cc (or (. headers :cache-control) (. headers "Cache-Control"))]
    (if cc
      (let [smaxage (cc:match "s%-maxage=(%d+)")
            maxage (cc:match "max%-age=(%d+)")]
        (if smaxage
          (tonumber smaxage)
          (if maxage
            (tonumber maxage)
            (when (or (cc:find "no-cache" 1 true) (cc:find "no-store" 1 true))
              0))))
      (let [expires (or (. headers :expires) (. headers "Expires"))]
        (when expires
          (let [ts (ngx.parse_http_time expires)]
            (when ts
              (math.max 0 (math.floor (- ts (ngx.now)))))))))))

(fn yaml? [url content-type]
  (or (url:match "%.ya?ml$")
      (and content-type (content-type:find "yaml" 1 true))))

(fn parse-body [url content-type raw]
  (if (yaml? url content-type)
    (if lyaml-ok
      (lyaml.load raw)
      (error (.. "YAML schema at " url " requires lyaml (not installed)")))
    (json.decode raw)))

;; Fetch schema URL. When service.tls.cert/key are set, passes client cert
;; to resty.http so schema endpoints requiring mTLS are reachable.
(fn fetch [service]
  (let [url service.schema_url
        timeout (or service.timeout schema-fetch-timeout-ms)
        tls service.tls
        ssl-verify (and tls tls.verify)
        opts {:method :GET :ssl_verify (or ssl-verify false)}
        _ (when (and tls tls.cert tls.key)
            (tset opts :ssl_client_cert tls.cert)
            (tset opts :ssl_client_priv_key tls.key))
        client (http.new)
        _ (client:set_timeout timeout)
        (res err) (client:request_uri url opts)]
    (if err
      (do (client:close) (error (.. "schema fetch failed: " err)))
      (if (not= res.status 200)
        (do (client:close)
            (error (.. "schema fetch returned HTTP " res.status " for " url)))
        (let [ct (or (. res.headers :content-type) "")
              body (parse-body url ct res.body)
              upstream-ttl (parse-cache-ttl res.headers)]
          (client:set_keepalive keepalive-timeout-ms keepalive-pool-size)
          {:body body :upstream-ttl upstream-ttl})))))

(fn apply-prefix [component-prefix name]
  (if component-prefix
    (.. component-prefix "__" name)
    name))

(fn rewrite-ref-str [component-prefix ref]
  (let [prefix "#/components/"]
    (if (= (ref:sub 1 (# prefix)) prefix)
      (let [rest (ref:sub (+ (# prefix) 1))
            slash (rest:find "/" 1 true)]
        (if slash
          (let [section (rest:sub 1 (- slash 1))
                name (rest:sub (+ slash 1))]
            (.. prefix section "/" (apply-prefix component-prefix name)))
          ref))
      ref)))

(fn rewrite-refs! [component-prefix obj]
  (when (= (type obj) :table)
    (each [k v (pairs obj)]
      (if (and (= k "$ref") (= (type v) :string))
        (tset obj k (rewrite-ref-str component-prefix v))
        (rewrite-refs! component-prefix v))))
  obj)

;; Prefix all component names and compute content hashes.
;; Returns {:components {section {name schema}} :hashes {section {name md5}}}.
(fn prefix-components [component-prefix components]
  (let [out {}
        hashes {}]
    (each [section items (pairs components)]
      (let [new-section {}
            section-hashes {}]
        (each [name schema (pairs items)]
          (rewrite-refs! component-prefix schema)
          (let [new-name (apply-prefix component-prefix name)]
            (tset new-section new-name schema)
            (tset section-hashes new-name (ngx.md5 (json.encode schema)))))
        (tset out section new-section)
        (tset hashes section section-hashes)))
    {:components out :hashes hashes}))

;; Non-method keys (parameters, summary, servers, …) are preserved on any
;; path item that has at least one surviving method operation.
(fn filter-paths [service paths]
  (let [filtered {}]
    (each [path path-item (pairs paths)]
      (let [surviving {}]
        (each [method op (pairs path-item)]
          (when (. http-methods method)
            (when (rules-mod.allow? service.rules path method (or op.tags []))
              (tset surviving method op))))
        (when (next surviving)
          (each [k v (pairs path-item)]
            (when (not (. http-methods k))
              (tset surviving k v)))
          (tset filtered path surviving))))
    filtered))

;; Returns {:openapi :info :paths :components :component-hashes :upstream-ttl}.
(fn process [service]
  (let [(ok result) (pcall fetch service)]
    (if (not ok)
      (do
        (metrics.schema-fetch service.name :error)
        (error result))
      (let [{:body raw :upstream-ttl upstream-ttl} result
            cp service.component_prefix
            paths (filter-paths service (or raw.paths {}))
            _ (rewrite-refs! cp paths)
            {:components components :hashes hashes}
            (prefix-components cp (or raw.components {}))]
        (metrics.schema-fetch service.name :ok)
        {:openapi raw.openapi
         :info raw.info
         :paths paths
         :components components
         :component-hashes hashes
         :upstream-ttl upstream-ttl}))))

{:fetch fetch
 :process process
 :parse-cache-ttl parse-cache-ttl
 :rewrite-ref-str rewrite-ref-str
 :rewrite-refs! rewrite-refs!
 :prefix-components prefix-components
 :filter-paths filter-paths}
