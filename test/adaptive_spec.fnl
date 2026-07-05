(var adaptive nil)

(before_each
  (fn []
    (reset_mocks)
    (tset package.loaded :adaptive nil)
    (set adaptive (require :adaptive))))

(describe "adaptive.allow?"
  (fn []
    (local svc {:name "svc" :adaptive_concurrency {}})

    (it "admits first request (under initial limit)"
      (fn []
        (assert.is_true (adaptive.allow? svc))))

    (it "increments inflight on admission"
      (fn []
        (adaptive.allow? svc)
        (assert.equals 1 (_mock_dicts.adaptive:get "ac:svc:if"))))

    (it "rejects when inflight exceeds limit"
      (fn []
        ;; Force limit to 0 so next request is over limit.
        (_mock_dicts.adaptive:set "ac:svc:lim" 0 0)
        (assert.is_false (adaptive.allow? svc))))

    (it "does not increment inflight on rejection"
      (fn []
        (_mock_dicts.adaptive:set "ac:svc:lim" 0 0)
        (adaptive.allow? svc)
        (assert.equals 0 (or (_mock_dicts.adaptive:get "ac:svc:if") 0))))

    (it "respects custom initial_limit"
      (fn []
        (let [big-svc {:name "big" :adaptive_concurrency {:initial_limit 100}}]
          (for [_ 1 50] (adaptive.allow? big-svc))
          (assert.equals 50 (_mock_dicts.adaptive:get "ac:big:if")))))))

(describe "adaptive.on-complete!"
  (fn []
    (local svc {:name "svc" :adaptive_concurrency {}})

    (it "decrements inflight"
      (fn []
        (adaptive.allow? svc)
        (adaptive.allow? svc)
        (adaptive.on-complete! svc 0.01 true)
        (assert.equals 1 (_mock_dicts.adaptive:get "ac:svc:if"))))

    (it "skips gradient update when rtt is 0"
      (fn []
        (adaptive.allow? svc)
        (adaptive.on-complete! svc 0 true)
        ;; No RTT recorded — min-rtt key should be absent.
        (assert.is_nil (_mock_dicts.adaptive:get "ac:svc:mr"))))

    (it "records min RTT on first completion"
      (fn []
        (adaptive.allow? svc)
        (adaptive.on-complete! svc 0.05 true)
        (assert.is_not_nil (_mock_dicts.adaptive:get "ac:svc:mr"))))

    (it "updates RTT EMA on each completion"
      (fn []
        (adaptive.allow? svc)
        (adaptive.on-complete! svc 0.05 true)
        (assert.is_not_nil (_mock_dicts.adaptive:get "ac:svc:re"))))

    (it "backs off limit on upstream error"
      (fn []
        (let [init 20]
          (_mock_dicts.adaptive:set "ac:svc:lim" init 0)
          (adaptive.allow? svc)
          (adaptive.on-complete! svc 0.1 false)
          (let [new-lim (_mock_dicts.adaptive:get "ac:svc:lim")]
            (assert.is_truthy (< new-lim init))))))

    (it "clamps limit to min_limit on repeated failures"
      (fn []
        (let [svc2 {:name "svc2" :adaptive_concurrency {:min_limit 5}}]
          (_mock_dicts.adaptive:set "ac:svc2:lim" 5 0)
          (adaptive.allow? svc2)
          (adaptive.on-complete! svc2 0.5 false)
          (assert.equals 5 (_mock_dicts.adaptive:get "ac:svc2:lim")))))))

(describe "adaptive.get-stats"
  (fn []
    (local svc {:name "svc" :adaptive_concurrency {}})

    (it "returns stats table"
      (fn []
        (let [s (adaptive.get-stats "svc")]
          (assert.is_not_nil s)
          (assert.equals 0 s.inflight))))

    (it "reflects current inflight count"
      (fn []
        (adaptive.allow? svc)
        (adaptive.allow? svc)
        (assert.equals 2 (. (adaptive.get-stats "svc") :inflight))))))
