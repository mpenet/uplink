;; TTL cache backed by ngx.shared.dict.
;; nginx.conf must declare: lua_shared_dict ladon_cache <size>;
;;
;; Split storage per key:
;;   key        → small metadata JSON {ttl, fetched_at, gen}
;;   key..NUL.."v" → large value JSON (schema)
;;   key..NUL.."g" → atomic generation counter (integer, via incr)
;;
;; Per-worker value cache: on fresh hit, metadata is decoded (small, cheap)
;; and gen is compared against the worker-local cache. If gen matches, the
;; decoded Lua table is returned directly — no large JSON decode.
;;
;; Thundering herd: per-key ngx.semaphore serializes refresh within a worker.
;; Schema generation counter (NUL.."schema_gen") is bumped on every
;; force-refresh so the aggregator knows when to rebuild the merged doc.
;;
;; Thunks must return {:value <any> :ttl <seconds>}.

(local json (require :cjson))
(local semaphore-mod (require :ngx.semaphore))

(fn get-dict []
  (let [d (. ngx.shared :ladon_cache)]
    (assert d "lua_shared_dict 'ladon_cache' not defined in nginx.conf")
    d))

;; NUL byte via string.char avoids Fennel lexer issues with \0 escapes.
;; Keys containing NUL cannot be produced from service names (valid URL segments).
(local nul (string.char 0))
(local val-suffix (.. nul "v"))
(local gen-suffix (.. nul "g"))
(local schema-gen-key (.. nul "schema_gen"))

;; Per-worker decoded value cache: {key -> {gen: N, value: table}}
(local value-cache {})
;; Per-worker semaphore table: {key -> semaphore}
(local semas {})

(fn get-sema [key]
  (when (not (. semas key))
    (tset semas key (semaphore-mod.new 1)))
  (. semas key))

;; Read small metadata entry. Cheap — metadata JSON is ~50 bytes.
(fn raw-get-meta [key]
  (let [d (get-dict)
        raw (d:get key)]
    (when raw (json.decode raw))))

;; Read value using per-worker cache. Only decodes large JSON when gen changes.
(fn raw-get-value [key gen]
  (let [cached (. value-cache key)]
    (if (and cached (= cached.gen gen))
      cached.value
      (let [d (get-dict)
            raw (d:get (.. key val-suffix))]
        (when raw
          (let [decoded (json.decode raw)]
            (tset value-cache key {:gen gen :value decoded})
            decoded))))))

;; Write value + metadata (gen incremented atomically first).
;; Returns the new generation number.
(fn raw-set [key value ttl]
  (let [d (get-dict)
        (gen _) (d:incr (.. key gen-suffix) 1 0)
        meta (json.encode {:ttl (or ttl 300) :fetched_at (ngx.now) :gen gen})]
    (d:set key meta 0)
    (d:set (.. key val-suffix) (json.encode value) 0)
    gen))

(fn cache-get [key]
  (let [meta (raw-get-meta key)]
    (when meta (raw-get-value key meta.gen))))

(fn cache-set [key value ttl]
  (raw-set key value ttl))

(fn cache-delete [key]
  (let [d (get-dict)]
    (d:delete key)
    (d:delete (.. key val-suffix))
    (d:delete (.. key gen-suffix))
    (tset value-cache key nil)))

(fn fresh? [meta]
  (and meta (< (- (ngx.now) meta.fetched_at) meta.ttl)))

(fn get-schema-gen []
  (let [d (get-dict)]
    (or (d:get schema-gen-key) 0)))

(fn bump-schema-gen []
  (let [d (get-dict)]
    (d:incr schema-gen-key 1 0)))

(fn do-refresh [key default-ttl thunk meta-entry]
  (let [(ok result) (pcall thunk)]
    (if ok
      (let [{:value v :ttl ttl} result
            new-gen (raw-set key v (or ttl default-ttl))]
        (tset value-cache key {:gen new-gen :value v})
        v)
      (do
        (if meta-entry
          (do
            (ngx.log ngx.WARN
              "schema refresh failed for key=" key
              ", serving stale (age=" (math.floor (- (ngx.now) meta-entry.fetched_at)) "s"
              ", ttl=" meta-entry.ttl "s). error: " result)
            (raw-get-value key meta-entry.gen))
          (error result))))))

(fn get-or-fetch [key default-ttl thunk]
  (let [meta (raw-get-meta key)]
    (if (fresh? meta)
      (raw-get-value key meta.gen)
      (let [sema (get-sema key)
            (waited _) (sema:wait 5)]
        (if (not waited)
          (do
            (ngx.log ngx.WARN "semaphore wait timed out for key=" key)
            (let [current (raw-get-meta key)]
              (if current
                (raw-get-value key current.gen)
                (error (.. "semaphore timeout with no cached value for key=" key)))))
          (let [fresh (raw-get-meta key)]
            (if (fresh? fresh)
              (do (sema:post 1) (raw-get-value key fresh.gen))
              (let [v (do-refresh key default-ttl thunk fresh)]
                (sema:post 1)
                v))))))))

;; Force-refresh regardless of TTL — used by background timer.
;; Bumps global schema generation so aggregator knows to rebuild.
;; Never raises: logs and returns false on failure.
(fn force-refresh [key default-ttl thunk]
  (let [(ok result) (pcall thunk)]
    (if ok
      (let [{:value v :ttl ttl} result
            new-gen (raw-set key v (or ttl default-ttl))]
        (tset value-cache key {:gen new-gen :value v})
        (bump-schema-gen)
        true)
      (do
        (ngx.log ngx.WARN "background refresh failed for key=" key ": " result)
        false))))

{:get cache-get
 :set cache-set
 :delete cache-delete
 :get-or-fetch get-or-fetch
 :force-refresh force-refresh
 :get-schema-gen get-schema-gen}
