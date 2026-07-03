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

(describe "config.get"
  (fn []
    (it "returns nil before load"
      (fn []
        (assert.is_nil (config.get))))

    (it "returns cfg after load"
      (fn []
        (config.load "config.json")
        (let [cfg (config.get)]
          (assert.is_not_nil cfg.services)
          (assert.equals cfg (config.get)))))))
