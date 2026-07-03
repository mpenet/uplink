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
    (set svc.rules {}))
  svc)

(fn validate [cfg]
  (assert cfg.services "config missing 'services'")
  (each [_ svc (ipairs cfg.services)]
    (validate-service svc))
  cfg)

(fn load [path]
  (set _cfg (validate (load-file path)))
  _cfg)

(fn get [] _cfg)

{:load load :get get}
