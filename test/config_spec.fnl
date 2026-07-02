(var config nil)

(before_each
  (fn []
    (reset_mocks)
    (tset package.loaded :config nil)
    (set config (require :config))))

(describe "config.load"
  (fn []
    (it "loads and validates config.json"
      (fn []
        (let [cfg (config.load "config.json")]
          (assert.is_not_nil cfg.services)
          (assert.is_true (> (# cfg.services) 0)))))

    (it "sets default ttl when missing"
      (fn []
        (let [cfg (config.load "config.json")]
          (each [_ svc (ipairs cfg.services)]
            (assert.is_not_nil svc.ttl)
            (assert.is_truthy (> svc.ttl 0))))))

    (it "sets default rules when missing"
      (fn []
        (let [cfg (config.load "config.json")]
          (each [_ svc (ipairs cfg.services)]
            (assert.is_not_nil svc.rules)))))))

(describe "store-in-shared / load-from-shared"
  (fn []
    (it "round-trips config through shared dict"
      (fn []
        (let [cfg (config.load "config.json")
              _ (config.store-in-shared cfg)
              loaded (config.load-from-shared)]
          (assert.equals (# cfg.services) (# loaded.services))
          (assert.equals (. cfg.services 1 :name) (. loaded.services 1 :name)))))

    (it "increments version on each store"
      (fn []
        (let [cfg (config.load "config.json")
              v1 (config.store-in-shared cfg)
              v2 (config.store-in-shared cfg)]
          (assert.equals (+ v1 1) v2))))))

(describe "get-version"
  (fn []
    (it "returns 0 before any store"
      (fn []
        (assert.equals 0 (config.get-version))))

    (it "returns current version after store"
      (fn []
        (let [cfg (config.load "config.json")
              ver (config.store-in-shared cfg)]
          (assert.equals ver (config.get-version)))))))

(describe "config.reload"
  (fn []
    (it "returns cfg and version"
      (fn []
        (let [r (config.reload "config.json")]
          (assert.is_not_nil r.cfg)
          (assert.is_not_nil r.version)
          (assert.is_truthy (>= r.version 1)))))))
