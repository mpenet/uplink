(set package.path (.. "./lib/?.lua;" package.path))

;; cjson stub using dkjson (pure Lua, available everywhere)
(tset package.preload :cjson
  (fn []
    (let [dk (require :dkjson)]
      {:encode dk.encode :decode dk.decode})))

;; lyaml stub: decode YAML by falling back to JSON decode (tests use JSON input)
(tset package.preload :lyaml
  (fn []
    (let [dk (require :dkjson)]
      {:load dk.decode})))

;; resty.limit.req stub: always allows (delay = 0)
(var rl-delay 0)
(tset package.preload "resty.limit.req"
  (fn []
    {:new (fn [_ _ _]
            (values {:incoming (fn [_ _ _] (values rl-delay nil))} nil))}))

;; lua-resty-openssl stubs (mtls.fnl loads these at module level)
(tset package.preload "resty.openssl.ssl_ctx"
  (fn []
    {:new (fn []
            (values {:ctx {}
                     :set_certificate (fn [] (values true nil))
                     :set_private_key (fn [] (values true nil))} nil))}))

(tset package.preload "resty.openssl.x509"
  (fn []
    {:new (fn [_] (values {} nil))}))

(tset package.preload "resty.openssl.pkey"
  (fn []
    {:new (fn [_] (values {} nil))}))

;; ngx.semaphore stub: always acquires immediately
(tset package.preload "ngx.semaphore"
  (fn []
    {:new (fn [n]
            (var count (or n 0))
            {:wait (fn [_ _t] (set count (- count 1)) true)
             :post (fn [_ n2] (set count (+ count (or n2 1))))})}))

;; resty.http stub: configurable per-test
(var http-response {:status 200 :headers {"content-type" "application/json"} :body "{}"})
(var http-error nil)

(tset package.preload "resty.http"
  (fn []
    {:new (fn []
            {:set_timeout (fn [] nil)
             :set_keepalive (fn [] nil)
             :close (fn [] nil)
             ;; Streaming API (used by proxy.fnl)
             :parse_uri (fn [_ url _qip]
                          (let [scheme (or (url:match "^(https?)://") "http")
                                rest (or (url:match "^https?://(.+)$") "localhost/")
                                host (or (rest:match "^([^:/]+)") "localhost")
                                port-str (rest:match "^[^:]+:(%d+)")
                                port (if port-str (tonumber port-str)
                                         (if (= scheme "https") 443 80))
                                path (or (rest:match "^[^/]+(/.+)$")
                                         (rest:match "^[^/]+(/[^?]*)") "/")]
                            (values [scheme host port path] nil)))
             :connect (fn [_ _opts] (values true nil))
             :request (fn [_ _opts]
                        (if http-error
                          (values nil http-error)
                          (let [body-str (or (and http-response http-response.body) "")]
                            (var sent false)
                            (values {:status (or (and http-response http-response.status) 200)
                                     :headers (or (and http-response http-response.headers) {})
                                     :body_reader (fn [_size]
                                                    (if sent
                                                      (values nil nil)
                                                      (do (set sent true)
                                                          (values body-str nil))))} nil))))
             ;; Buffered API (used by schema.fnl)
             :request_uri (fn [_ _url _opts]
                            (if http-error
                              (values nil http-error)
                              (values http-response nil)))})}))

;; ── In-memory shared dict ─────────────────────────────────────────────────────

(fn make-shared-dict []
  (var store {})
  {:get (fn [_ key] (. store key))
   :set (fn [_ key val _ttl] (tset store key val) true)
   :add (fn [_ key val _ttl]
          (if (~= (. store key) nil)
            (values false "exists")
            (do (tset store key val) true)))
   :delete (fn [_ key] (tset store key nil))
   :incr (fn [_ key delta init]
           (let [cur (or (. store key) (or init 0))]
             (tset store key (+ cur delta))
             (. store key)))
   :get_keys (fn [_ _n]
               (let [keys []]
                 (each [k _ (pairs store)]
                   (table.insert keys k))
                 keys))
   :_reset (fn [] (set store {}))
   :_store (fn [] store)})

(local cache-dict (make-shared-dict))
(local metrics-dict (make-shared-dict))
(local config-dict (make-shared-dict))
(local circuit-dict (make-shared-dict))
(local ratelimit-dict (make-shared-dict))

;; ── Global ngx mock ───────────────────────────────────────────────────────────

(set _G.ngx
  {:INFO 6 :WARN 5 :ERR 3
   :shared {:ladon_cache cache-dict
            :ladon_metrics metrics-dict
            :ladon_config config-dict
            :ladon_circuit circuit-dict
            :ladon_ratelimit ratelimit-dict}
   :log (fn [& _] nil)
   :now (fn [] (os.time))
   :md5 (fn [s] (string.format "%d:%s:%s" (# s) (s:sub 1 1) (s:sub -1)))
   :var {:request_id "abcdef0123456789abcdef0123456789"
         :uri "/users/v1/profile"
         :request_uri "/users/v1/profile"}
   :req {:get_headers (fn [] {"content-type" "application/json"})
         :get_method (fn [] "GET")
         :read_body (fn [] nil)
         :get_body_data (fn [] nil)}
   :header (setmetatable {} {:__newindex (fn [] nil)})
   :status (fn [_] nil)
   :say (fn [_] nil)
   :socket {:tcp (fn []
                   {:settimeout (fn [] nil)
                    :connect (fn [] (values true nil))
                    :getreusedtimes (fn [] 0)
                    :setsslctx (fn [] (values true nil))
                    :sslhandshake (fn [_ _sess _host _verify] (values {} nil))
                    :send (fn [] (values true nil))
                    :receiveuntil (fn [] (fn [] (values "" nil)))
                    :receive (fn [] (values "" nil))
                    :setkeepalive (fn [] true)
                    :close (fn [] true)})}})

(set _G._mock_dicts
  {:cache cache-dict :metrics metrics-dict :config config-dict
   :circuit circuit-dict :ratelimit ratelimit-dict})

(fn reset-http []
  (set http-response {:status 200 :headers {"content-type" "application/json"} :body "{}"})
  (set http-error nil))

(set _G.set_http_response (fn [res] (set http-response res) (set http-error nil)))
(set _G.set_http_error (fn [err] (set http-error err) (set http-response nil)))
(set _G.set_rl_delay (fn [d] (set rl-delay d)))

(set _G.reset_mocks
  (fn []
    (cache-dict:_reset)
    (metrics-dict:_reset)
    (config-dict:_reset)
    (circuit-dict:_reset)
    (ratelimit-dict:_reset)
    (reset-http)
    (set rl-delay 0)
    (tset _G.ngx :var {:request_id "abcdef0123456789abcdef0123456789"
                       :uri "/users/v1/profile"
                       :request_uri "/users/v1/profile"})
    (tset _G.ngx :req
      {:get_headers (fn [] {"content-type" "application/json"})
       :get_method (fn [] "GET")
       :read_body (fn [] nil)
       :get_body_data (fn [] nil)})))
