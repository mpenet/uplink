(local json (require :cjson))

(fn load-file [path]
  (let [f (assert (io.open path :r))
        raw (f:read :*a)]
    (f:close)
    (json.decode raw)))

(fn validate-service [svc]
  (assert svc.name "service missing 'name'")
  (assert svc.upstream "service missing 'upstream'")
  (assert svc.schema_url "service missing 'schema_url'")
  (when (not svc.ttl)
    (set svc.ttl 300))
  (when (not svc.rules)
    (set svc.rules {}))
  svc)

(fn validate [cfg]
  (assert cfg.services "config missing 'services'")
  (each [_ svc (ipairs cfg.services)]
    (validate-service svc))
  cfg)

(fn load [path]
  (validate (load-file path)))

;; -- Shared-dict persistence for hot-reload --

(fn get-shared-dict []
  (let [d (. ngx.shared :uplink_config)]
    (assert d "lua_shared_dict 'uplink_config' not defined in nginx.conf")
    d))

(fn store-in-shared [cfg]
  (let [d (get-shared-dict)]
    ;; Write config first, then atomically bump version.
    ;; Workers use version as the reload signal — they see new config only after bump.
    (d:set :config (json.encode cfg) 0)
    (let [(ver err) (d:incr :version 1 0)]
      (when (not ver)
        (error (.. "failed to bump config version: " (or err "unknown"))))
      ver)))

(fn load-from-shared []
  (let [d (get-shared-dict)
        raw (d:get :config)]
    (assert raw "no config stored in shared dict — was init_by_lua_block run?")
    (json.decode raw)))

(fn get-version []
  (let [d (. ngx.shared :uplink_config)]
    (or (and d (d:get :version)) 0)))

;; Reload from file, validate, store in shared dict.
;; Returns {:cfg :version}.
(fn reload [path]
  (let [cfg (load path)
        ver (store-in-shared cfg)]
    {:cfg cfg :version ver}))

{:load load
 :store-in-shared store-in-shared
 :load-from-shared load-from-shared
 :get-version get-version
 :reload reload}
