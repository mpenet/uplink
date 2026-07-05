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

(local json (require :cjson))

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

;; Minimal JWKS with one RSA key. n/e are dummy base64url values —
;; rsa-jwk-to-pem will run but produce a garbage PEM; verify_jwt_obj
;; is stubbed to ignore the key so the test still passes.
(fn make-jwks [& kids]
  (let [keys []]
    (each [_ kid (ipairs kids)]
      (table.insert keys {:kty "RSA" :kid kid :n "AQAB" :e "AQAB"}))
    (json.encode {:keys keys})))

(fn jwks-response [& kids]
  {:status 200 :headers {"content-type" "application/json"}
   :body (make-jwks (table.unpack kids))})

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
          (assert.equals 401 (get_last_exit))
          (assert.is_truthy (. _G.ngx.header :www_authenticate)))))

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
          (assert.equals 401 (get_last_exit))
          (assert.is_truthy (. _G.ngx.header :www_authenticate)))))))

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
        (assert.equals "Authorization" (. cleared 1))))

    (it "reads token from custom header field"
      (fn []
        (let [h {:x-api-token "Bearer custom.token.here"}]
          (tset _G.ngx :req
            {:get_headers (fn [] h)
             :set_header  (fn [k v] (tset h k v))
             :clear_header (fn [k] (tset h k nil))
             :start_time  (fn [] (os.time))})
          (auth.check (make-svc {:secret "s" :algorithms ["HS256"]
                                  :header "X-Api-Token"}))
          (assert.is_nil (get_last_exit)))))

    (it "returns 401 when custom header is absent"
      (fn []
        (tset _G.ngx :req
          {:get_headers (fn [] {})
           :set_header (fn [] nil) :clear_header (fn [] nil)
           :start_time (fn [] (os.time))})
        (let [(ok _) (pcall auth.check
                            (make-svc {:secret "s" :algorithms ["HS256"]
                                       :header "X-Api-Token"}))]
          (assert.is_false ok)
          (assert.equals 401 (get_last_exit)))))

    (it "JSON-encodes non-string claim values when forwarding"
      (fn []
        (with-bearer "valid.token.here")
        (set jwt-verify-result {:verified true
                                :payload {:sub "u1" :roles ["admin" "user"]}})
        (var injected {})
        (tset _G.ngx.req :set_header (fn [k v] (tset injected k v)))
        (auth.check (make-svc {:secret "s" :algorithms ["HS256"]
                                :forward ["roles"]}))
        ;; roles is an array — should be JSON-encoded, not raw tostring
        (let [v (. injected "X-JWT-roles")]
          (assert.is_truthy (v:find "admin" 1 true)))))

    (it "does not inject X-JWT-* header when claim is absent from payload"
      (fn []
        (with-bearer "valid.token.here")
        (set jwt-verify-result {:verified true :payload {:sub "u1"}})
        (var injected {})
        (tset _G.ngx.req :set_header (fn [k v] (tset injected k v)))
        (auth.check (make-svc {:secret "s" :algorithms ["HS256"]
                                :forward ["email"]}))
        (assert.is_nil (. injected "X-JWT-email"))))))

(describe "auth.check — claim validation (additional)"
  (fn []
    (it "returns 401 when required claim is absent from payload"
      (fn []
        (with-bearer "valid.token.here")
        (set jwt-verify-result {:verified true :payload {:sub "u1"}})
        (let [(ok _) (pcall auth.check
                            (make-svc {:secret "s" :algorithms ["HS256"]
                                       :claims {:iss "https://required.example.com"}}))]
          (assert.is_false ok)
          (assert.equals 401 (get_last_exit)))))

    (it "returns 401 on generic claim mismatch"
      (fn []
        (with-bearer "valid.token.here")
        (set jwt-verify-result {:verified true :payload {:sub "u1" :scope "read"}})
        (let [(ok _) (pcall auth.check
                            (make-svc {:secret "s" :algorithms ["HS256"]
                                       :claims {:scope "write"}}))]
          (assert.is_false ok)
          (assert.equals 401 (get_last_exit)))))

    (it "passes when generic claim matches"
      (fn []
        (with-bearer "valid.token.here")
        (set jwt-verify-result {:verified true :payload {:sub "u1" :scope "write"}})
        (auth.check (make-svc {:secret "s" :algorithms ["HS256"]
                                :claims {:scope "write"}}))
        (assert.is_nil (get_last_exit))))))

(describe "auth.check — key source"
  (fn []
    (it "returns 401 when no key source is configured"
      (fn []
        (with-bearer "valid.token.here")
        (let [(ok _) (pcall auth.check
                            (make-svc {:algorithms ["HS256"]}))]
          (assert.is_false ok)
          (assert.equals 401 (get_last_exit)))))

    (it "passes using public_key PEM source"
      (fn []
        (with-bearer "valid.token.here")
        (set jwt-load-result {:valid true :header {:alg "RS256"} :payload {:sub "u1"}})
        (auth.check (make-svc {:public_key "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----"
                                :algorithms ["RS256"]}))
        (assert.is_nil (get_last_exit))))))

(describe "auth — JWKS"
  (fn []
    (it "fetches JWKS on first use and passes with jwks_url"
      (fn []
        (with-bearer "valid.token.here")
        (set jwt-load-result {:valid true :header {:alg "RS256" :kid "k1"} :payload {:sub "u1"}})
        (set_http_response (jwks-response "k1"))
        (auth.check (make-svc {:jwks_url "https://auth.example.com/.well-known/jwks.json"
                                :algorithms ["RS256"]}))
        (assert.is_nil (get_last_exit))))

    (it "uses cached JWKS on second call (no re-fetch)"
      (fn []
        (with-bearer "valid.token.here")
        (set jwt-load-result {:valid true :header {:alg "RS256" :kid "k1"} :payload {:sub "u1"}})
        (set_http_response (jwks-response "k1"))
        (let [url "https://auth.example.com/.well-known/jwks.json"
              cfg (make-svc {:jwks_url url :algorithms ["RS256"]})]
          ;; First call fetches.
          (auth.check cfg)
          ;; Break HTTP so a second fetch would error.
          (set_http_error "should not be called")
          ;; Second call must succeed using cache.
          (auth.check cfg)
          (assert.is_nil (get_last_exit)))))

    (it "returns 401 on JWKS fetch HTTP error"
      (fn []
        (with-bearer "valid.token.here")
        (set jwt-load-result {:valid true :header {:alg "RS256" :kid "k1"} :payload {:sub "u1"}})
        (set_http_error "connection refused")
        (let [(ok _) (pcall auth.check
                            (make-svc {:jwks_url "https://auth.example.com/.well-known/jwks.json"
                                       :algorithms ["RS256"]}))]
          (assert.is_false ok)
          (assert.equals 401 (get_last_exit)))))

    (it "returns 401 on JWKS fetch non-200 response"
      (fn []
        (with-bearer "valid.token.here")
        (set jwt-load-result {:valid true :header {:alg "RS256" :kid "k1"} :payload {:sub "u1"}})
        (set_http_response {:status 503 :headers {} :body ""})
        (let [(ok _) (pcall auth.check
                            (make-svc {:jwks_url "https://auth.example.com/.well-known/jwks.json"
                                       :algorithms ["RS256"]}))]
          (assert.is_false ok)
          (assert.equals 401 (get_last_exit)))))

    (it "selects correct key by kid"
      (fn []
        (let [url "https://auth.example.com/.well-known/jwks.json"
              {:get-jwks-pems get-pems} auth]
          ;; Populate cache with two keys.
          (set_http_response (jwks-response "kid-a" "kid-b"))
          (let [pems (get-pems url)]
            (assert.is_not_nil (. pems "kid-a"))
            (assert.is_not_nil (. pems "kid-b"))))))

    (it "invalidates cache and retries when kid not found"
      (fn []
        (with-bearer "valid.token.here")
        (let [url "https://auth.example.com/.well-known/jwks.json"
              {:resolve-jwks-key resolve} auth]
          ;; First fetch returns key "old-kid".
          (set_http_response (jwks-response "old-kid"))
          (resolve url "old-kid")
          ;; Now keys have rotated — "new-kid" available, "old-kid" gone.
          (set_http_response (jwks-response "new-kid"))
          ;; Resolving unknown kid triggers cache invalidation + retry.
          (let [pem (resolve url "new-kid")]
            (assert.is_not_nil pem)))))))

