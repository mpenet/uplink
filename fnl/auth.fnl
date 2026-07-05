;; JWT authentication in the access phase.
;; Based on lua-resty-jwt (https://github.com/cdbattags/lua-resty-jwt).
;;
;; Supported key sources (mutually exclusive; checked in order):
;;   secret     — HMAC secret string (HS256/HS384/HS512)
;;   public_key — PEM public key (RS*/ES* static key)
;;   jwks_url   — JWKS endpoint URL (RSA keys; cached per worker for 1 h)
;;
;; Per-service config (service.auth.jwt):
;;   secret     — HMAC secret for HS*
;;   public_key — PEM string for RS*/ES*
;;   jwks_url   — JWKS endpoint URL (RSA only; fetched lazily, cached 1 h)
;;   algorithms — allowed alg values, default ["RS256"]
;;   claims     — required claim values e.g. {"iss":"https://...","aud":"api"}
;;   header     — request header carrying the token, default "Authorization"
;;   strip      — remove auth header before forwarding, default false
;;   forward    — claim names to inject upstream as X-JWT-<Name> headers
;;
;; Algorithm is validated against the allowed list BEFORE signature check to
;; prevent algorithm confusion attacks (e.g. RS256 key used as HS256 secret).

(local jwt-mod (require :resty.jwt))
(local http-mod (require :resty.http))
(local json (require :cjson))

(local jwks-ttl 3600)

;; Per-worker JWKS cache: {url -> {pems: {kid->pem}, fetched_at: N}}
(local jwks-cache {})

;; ── RSA JWK → PEM (pure-Lua DER encoding, covers RSA 1024–8192 bit) ─────────

(fn b64url-decode [s]
  (let [s1 (s:gsub "-" "+")
        s2 (s1:gsub "_" "/")
        pad (% (- 4 (% (# s2) 4)) 4)]
    (ngx.decode_base64 (.. s2 (string.rep "=" pad)))))

(fn der-len [n]
  (if (< n 128)
    (string.char n)
    (if (< n 256)
      (.. (string.char 0x81) (string.char n))
      (.. (string.char 0x82)
          (string.char (math.floor (/ n 256)))
          (string.char (% n 256))))))

(fn der-int [bytes]
  (let [b (if (> (bytes:byte 1) 127) (.. (string.char 0) bytes) bytes)]
    (.. (string.char 0x02) (der-len (# b)) b)))

;; AlgorithmIdentifier: SEQUENCE { OID(rsaEncryption 1.2.840.113549.1.1.1) NULL }
(local rsa-algo-id
  (string.char 0x30 0x0d
               0x06 0x09 0x2a 0x86 0x48 0x86 0xf7 0x0d 0x01 0x01 0x01
               0x05 0x00))

(fn rsa-jwk-to-pem [n-b64 e-b64]
  (let [n (b64url-decode n-b64)
        e (b64url-decode e-b64)
        rsa-seq (.. (der-int n) (der-int e))
        rsa-key (.. (string.char 0x30) (der-len (# rsa-seq)) rsa-seq)
        bit-str (.. (string.char 0x03) (der-len (+ (# rsa-key) 1))
                    (string.char 0x00) rsa-key)
        spki-body (.. rsa-algo-id bit-str)
        spki (.. (string.char 0x30) (der-len (# spki-body)) spki-body)
        b64 (ngx.encode_base64 spki)
        lines []]
    (for [i 1 (# b64) 64]
      (table.insert lines (b64:sub i (math.min (+ i 63) (# b64)))))
    (.. "-----BEGIN PUBLIC KEY-----\n"
        (table.concat lines "\n")
        "\n-----END PUBLIC KEY-----")))

;; ── JWKS fetching ─────────────────────────────────────────────────────────────

(fn parse-jwks [jwks]
  (let [pems {}]
    (each [_ k (ipairs (or jwks.keys []))]
      (when (= k.kty "RSA")
        (let [(ok pem) (pcall rsa-jwk-to-pem k.n k.e)]
          (if ok
            (tset pems (or k.kid "__default__") pem)
            (ngx.log ngx.WARN "auth: JWK->PEM failed kid=" (or k.kid "?") " " pem)))))
    pems))

(fn fetch-jwks [url]
  (let [c (http-mod.new)]
    (c:set_timeout 5000)
    (let [(res err) (c:request_uri url {:method "GET"})]
      (when err (error (.. "JWKS fetch error: " err)))
      (when (not= res.status 200)
        (error (.. "JWKS fetch HTTP " res.status " from " url)))
      (let [pems (parse-jwks (json.decode res.body))]
        (tset jwks-cache url {:pems pems :fetched_at (ngx.now)})
        pems))))

(fn get-jwks-pems [url]
  (let [cached (. jwks-cache url)]
    (if (and cached (< (- (ngx.now) cached.fetched_at) jwks-ttl))
      cached.pems
      (fetch-jwks url))))

(fn resolve-jwks-key [url kid]
  (let [k (or kid "__default__")
        pems (get-jwks-pems url)
        pem (. pems k)]
    (if pem
      pem
      ;; Kid not found — keys may have rotated; invalidate and retry once.
      (do
        (tset jwks-cache url nil)
        (let [fresh (get-jwks-pems url)
              found (. fresh k)]
          (if found
            found
            (do
              (var first-pem nil)
              (each [_ v (pairs fresh)]
                (when (not first-pem) (set first-pem v)))
              (or first-pem (error (.. "no usable key in JWKS " url))))))))))

;; ── Claim validation ──────────────────────────────────────────────────────────

(fn check-claims [payload required]
  (each [k v (pairs required)]
    (let [actual (. payload k)]
      (if (= k "aud")
        ;; aud may be string or array per RFC 7519 §4.1.3
        (let [aud-ok (if (= (type actual) "string")
                       (= actual v)
                       (do (var found false)
                           (each [_ a (ipairs (or actual []))]
                             (when (= a v) (set found true)))
                           found))]
          (when (not aud-ok)
            (error (.. "claim aud mismatch: expected " v))))
        (when (not= actual v)
          (error (.. "claim " k " mismatch")))))))

;; ── Signature verification ────────────────────────────────────────────────────

(fn alg-allowed? [allowed alg]
  (var ok false)
  (each [_ a (ipairs allowed)]
    (when (= a alg) (set ok true)))
  ok)

(fn verify [token cfg]
  (let [obj (jwt-mod:load_jwt token)]
    (when (not obj.valid)
      (error (or obj.reason "malformed JWT")))
    (let [alg (and obj.header (. obj.header :alg))
          algs (or cfg.algorithms ["RS256"])]
      (when (not (alg-allowed? algs alg))
        (error (.. "algorithm " (or alg "nil") " not in allowed list")))
      (let [kid (and obj.header (. obj.header :kid))
            key (if cfg.secret     cfg.secret
                    cfg.public_key cfg.public_key
                    cfg.jwks_url   (resolve-jwks-key cfg.jwks_url kid)
                    (error "auth.jwt: secret, public_key, or jwks_url required"))
            result (jwt-mod:verify_jwt_obj key obj)]
        (when (not result.verified)
          (error (or result.reason "JWT signature invalid")))
        (when cfg.claims
          (check-claims result.payload cfg.claims))
        result.payload))))

;; ── Access phase entry point ──────────────────────────────────────────────────

(fn check [service]
  (let [cfg (and service.auth service.auth.jwt)]
    (when cfg
      (let [hdr (or cfg.header "Authorization")
            val (. (ngx.req.get_headers) (hdr:lower))
            token (and val (val:match "^[Bb]earer%s+(.+)$"))]
        (when (not token)
          (set ngx.status 401)
          (tset ngx.header :www_authenticate "Bearer")
          (ngx.say "{\"error\":\"missing or invalid Authorization header\"}")
          (ngx.exit 401))
        (let [(ok payload) (pcall verify token cfg)]
          (if (not ok)
            (do
              (ngx.log ngx.WARN "auth: JWT rejected: " payload)
              (set ngx.status 401)
              (tset ngx.header :www_authenticate "Bearer error=\"invalid_token\"")
              (ngx.say "{\"error\":\"unauthorized\"}")
              (ngx.exit 401))
            (do
              (when cfg.strip
                (ngx.req.clear_header hdr))
              (when cfg.forward
                (each [_ claim (ipairs cfg.forward)]
                  (let [v (. payload claim)]
                    (when v
                      (ngx.req.set_header
                        (.. "X-JWT-" claim)
                        (if (= (type v) "string") v (json.encode v))))))))))))))

{:check check
 :get-jwks-pems get-jwks-pems
 :resolve-jwks-key resolve-jwks-key
 :parse-jwks parse-jwks}
