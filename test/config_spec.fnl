(set package.path (.. "./lib/?.lua;" package.path))

(var config nil)

(local valid-cfg
  {:services [{:name "svc"
               :upstream "http://svc:8080"
               :schema_url "http://svc:8080/openapi.json"}]})

(local valid-cfg-no-defaults
  {:services [{:name "svc"
               :upstream "http://svc:8080"
               :schema_url "http://svc:8080/openapi.json"}]})

(before_each
  (fn []
    (reset_mocks)
    (tset package.loaded :config nil)
    (set config (require :config))))

(describe "config.store"
  (fn []
    (it "validates and stores config"
      (fn []
        (let [cfg (config.store valid-cfg)]
          (assert.is_not_nil cfg.services)
          (assert.equals 1 (# cfg.services)))))

    (it "fills default ttl when missing"
      (fn []
        (let [cfg (config.store valid-cfg-no-defaults)]
          (assert.equals 300 (. cfg.services 1 :ttl)))))

    (it "fills default rules when missing"
      (fn []
        (let [cfg (config.store valid-cfg-no-defaults)]
          (assert.is_not_nil (. cfg.services 1 :rules)))))

    (it "raises on missing name"
      (fn []
        (let [(ok err) (pcall config.store
                              {:services [{:upstream "http://x" :schema_url "http://x"}]})]
          (assert.is_false ok)
          (assert.is_truthy (err:find "name")))))

    (it "raises on missing upstream"
      (fn []
        (let [(ok err) (pcall config.store
                              {:services [{:name "x" :schema_url "http://x"}]})]
          (assert.is_false ok)
          (assert.is_truthy (err:find "upstream")))))

    (it "raises on missing schema_url"
      (fn []
        (let [(ok err) (pcall config.store
                              {:services [{:name "x" :upstream "http://x"}]})]
          (assert.is_false ok)
          (assert.is_truthy (err:find "schema_url")))))

    (it "raises on missing services"
      (fn []
        (let [(ok err) (pcall config.store {})]
          (assert.is_false ok)
          (assert.is_truthy (err:find "services")))))))

(describe "config.get"
  (fn []
    (it "returns nil before load"
      (fn []
        (assert.is_nil (config.get))))

    (it "returns stored cfg"
      (fn []
        (config.store valid-cfg)
        (let [cfg (config.get)]
          (assert.is_not_nil cfg.services)
          (assert.equals cfg (config.get)))))))

(describe "config.load"
  (fn []
    (it "reads and validates a JSON file"
      (fn []
        (let [path "/tmp/uplink-test-config.json"
              f (io.open path :w)]
          (f:write "{\"services\":[{\"name\":\"t\",\"upstream\":\"http://t\",\"schema_url\":\"http://t\"}]}")
          (f:close)
          (let [cfg (config.load path)]
            (assert.equals "t" (. cfg.services 1 :name)))
          (os.remove path))))))
