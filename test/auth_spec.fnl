(set package.path (.. "./lib/?.lua;" package.path))

;; resty.jwt stub — behaviour controlled per-test via set_jwt_load / set_jwt_verify.
(var jwt-load-result nil)
(var jwt-verify-result nil)

(tset package.preload "resty.jwt"
  (fn []
    {:load_jwt
     (fn [_ _token]
       (or jwt-load-result
           {:valid true
            :header {:alg "HS256"}
            :payload {:sub "user123" :exp 9999999999}}))
     :verify_jwt_obj
     (fn [_ _key obj]
       (or jwt-verify-result
           {:verified true :payload obj.payload}))}))

(var auth nil)

(fn make-svc [jwt-cfg]
  {:name "test" :auth (when jwt-cfg {:jwt jwt-cfg})})

(fn with-bearer [token]
  (tset _G.ngx :req
    (let [h {:authorization (.. "Bearer " token)}]
      {:get_headers (fn [] h)
       :set_header  (fn [k v] (tset h k v))
       :clear_header (fn [k] (tset h k nil))
       :start_time  (fn [] (os.time))})))

(before_each
  (fn []
    (reset_mocks)
    (set jwt-load-result nil)
    (set jwt-verify-result nil)
    (tset package.loaded :auth nil)
    (set auth (require :auth))))

(describe "auth.check — no auth"
  (fn []
    (it "passes through when service has no auth config"
      (fn []
        (auth.check {:name "test"})
        (assert.is_nil (get_last_exit))))))

(describe "auth.check — token extraction"
  (fn []
    (it "returns 401 when Authorization header is absent"
      (fn []
        (let [(ok _) (pcall auth.check (make-svc {:secret "s" :algorithms ["HS256"]}))]
          (assert.is_false ok)
          (assert.equals 401 (get_last_exit)))))

    (it "returns 401 when header value is not a Bearer token"
      (fn []
        (tset _G.ngx :req
          {:get_headers (fn [] {:authorization "Basic dXNlcjpwYXNz"})
           :set_header (fn [] nil) :clear_header (fn [] nil)
           :start_time (fn [] (os.time))})
        (let [(ok _) (pcall auth.check (make-svc {:secret "s" :algorithms ["HS256"]}))]
          (assert.is_false ok)
          (assert.equals 401 (get_last_exit)))))))

(describe "auth.check — JWT validation"
  (fn []
    (it "passes on valid HS256 token"
      (fn []
        (with-bearer "valid.token.here")
        (auth.check (make-svc {:secret "my-secret" :algorithms ["HS256"]}))
        (assert.is_nil (get_last_exit))))

    (it "returns 401 when alg not in allowed list"
      (fn []
        (with-bearer "valid.token.here")
        (set jwt-load-result {:valid true :header {:alg "none"} :payload {}})
        (let [(ok _) (pcall auth.check (make-svc {:secret "s" :algorithms ["HS256"]}))]
          (assert.is_false ok)
          (assert.equals 401 (get_last_exit)))))

    (it "returns 401 when JWT is malformed"
      (fn []
        (with-bearer "bad")
        (set jwt-load-result {:valid false :reason "invalid format"})
        (let [(ok _) (pcall auth.check (make-svc {:secret "s" :algorithms ["HS256"]}))]
          (assert.is_false ok)
          (assert.equals 401 (get_last_exit)))))

    (it "returns 401 when signature is invalid"
      (fn []
        (with-bearer "valid.token.here")
        (set jwt-verify-result {:verified false :reason "bad signature"})
        (let [(ok _) (pcall auth.check (make-svc {:secret "s" :algorithms ["HS256"]}))]
          (assert.is_false ok)
          (assert.equals 401 (get_last_exit)))))))

(describe "auth.check — claim validation"
  (fn []
    (it "returns 401 when iss claim does not match"
      (fn []
        (with-bearer "valid.token.here")
        (set jwt-verify-result {:verified true
                                :payload {:iss "https://wrong.example.com" :sub "u1"}})
        (let [(ok _) (pcall auth.check
                            (make-svc {:secret "s" :algorithms ["HS256"]
                                       :claims {:iss "https://right.example.com"}}))]
          (assert.is_false ok)
          (assert.equals 401 (get_last_exit)))))

    (it "passes when required claims match"
      (fn []
        (with-bearer "valid.token.here")
        (set jwt-verify-result {:verified true
                                :payload {:iss "https://auth.example.com" :sub "u1"}})
        (auth.check (make-svc {:secret "s" :algorithms ["HS256"]
                                :claims {:iss "https://auth.example.com"}}))
        (assert.is_nil (get_last_exit))))

    (it "passes when aud matches as string"
      (fn []
        (with-bearer "valid.token.here")
        (set jwt-verify-result {:verified true :payload {:aud "my-api" :sub "u1"}})
        (auth.check (make-svc {:secret "s" :algorithms ["HS256"]
                                :claims {:aud "my-api"}}))
        (assert.is_nil (get_last_exit))))

    (it "passes when aud matches inside array"
      (fn []
        (with-bearer "valid.token.here")
        (set jwt-verify-result {:verified true
                                :payload {:aud ["other-api" "my-api"] :sub "u1"}})
        (auth.check (make-svc {:secret "s" :algorithms ["HS256"]
                                :claims {:aud "my-api"}}))
        (assert.is_nil (get_last_exit))))

    (it "returns 401 when aud not in array"
      (fn []
        (with-bearer "valid.token.here")
        (set jwt-verify-result {:verified true
                                :payload {:aud ["other-api"] :sub "u1"}})
        (let [(ok _) (pcall auth.check
                            (make-svc {:secret "s" :algorithms ["HS256"]
                                       :claims {:aud "my-api"}}))]
          (assert.is_false ok)
          (assert.equals 401 (get_last_exit)))))))

(describe "auth.check — post-auth header handling"
  (fn []
    (it "injects X-JWT-* headers for forwarded claims"
      (fn []
        (with-bearer "valid.token.here")
        (set jwt-verify-result {:verified true
                                :payload {:sub "user42" :email "u@example.com"}})
        (var injected {})
        (tset _G.ngx.req :set_header (fn [k v] (tset injected k v)))
        (auth.check (make-svc {:secret "s" :algorithms ["HS256"]
                                :forward ["sub" "email"]}))
        (assert.equals "user42"         (. injected "X-JWT-sub"))
        (assert.equals "u@example.com"  (. injected "X-JWT-email"))))

    (it "strips the auth header when strip is true"
      (fn []
        (with-bearer "valid.token.here")
        (var cleared [])
        (tset _G.ngx.req :clear_header (fn [k] (table.insert cleared k)))
        (auth.check (make-svc {:secret "s" :algorithms ["HS256"] :strip true}))
        (assert.equals "Authorization" (. cleared 1))))))
