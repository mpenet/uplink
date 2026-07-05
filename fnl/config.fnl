;; Configuration loader — reads config.json, validates it, and exposes a singleton.
;;
;; load() is called once in init_by_lua_block; all workers inherit the result
;; via fork so get() is a pure table lookup on every subsequent call.
;; store() bypasses the filesystem for tests.
;;
;; validate-service fills in defaults (ttl=300, rules=[]) in place so all
;; downstream callers can assume these fields are always present.

(local json (require :cjson))

(var _cfg nil)

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
    (set svc.rules []))
  ;; nil → default to name; false → no prefix
  (when (= svc.component_prefix nil)
    (set svc.component_prefix svc.name))
  svc)

(fn validate [cfg]
  (assert cfg.services "config missing 'services'")
  (each [_ svc (ipairs cfg.services)]
    (validate-service svc))
  cfg)

(fn load [path]
  (set _cfg (validate (load-file path)))
  _cfg)

(fn store [cfg]
  (set _cfg (validate cfg))
  _cfg)

(fn get [] _cfg)

{:load load :store store :get get}
