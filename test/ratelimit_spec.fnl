(var ratelimit nil)

(before_each
  (fn []
    (reset_mocks)
    (tset package.loaded :ratelimit nil)
    (set ratelimit (require :ratelimit))))

(describe "ratelimit.check"
  (fn []
    (it "returns nil when service has no rate_limit config"
      (fn []
        (assert.is_nil (ratelimit.check {:name "svc"}))))

    (it "returns nil when request is allowed"
      (fn []
        (set_rl_delay 0)
        (assert.is_nil (ratelimit.check {:name "svc" :rate_limit {:requests_per_second 100 :burst 50}}))))

    (it "returns false and message when rate limited"
      (fn []
        (set_rl_delay false)
        (let [(ok msg) (ratelimit.check {:name "svc" :rate_limit {:requests_per_second 1 :burst 0}})]
          (assert.is_false ok)
          (assert.is_truthy msg))))

    (it "uses default rate and burst when not specified"
      (fn []
        ;; Should not error — defaults applied internally.
        (set_rl_delay 0)
        (assert.is_nil (ratelimit.check {:name "svc" :rate_limit {}}))))

    (it "independent limiters per service name"
      (fn []
        (set_rl_delay false)
        (let [(ok _) (ratelimit.check {:name "a" :rate_limit {:requests_per_second 1 :burst 0}})]
          (assert.is_false ok))
        ;; Service "b" has its own limiter — allowed status depends on mock.
        (set_rl_delay 0)
        (assert.is_nil (ratelimit.check {:name "b" :rate_limit {:requests_per_second 100 :burst 50}}))))))
