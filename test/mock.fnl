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
(local otel-dict (make-shared-dict))

;; ── Global ngx mock ───────────────────────────────────────────────────────────

(var _last_exit nil)
(var _req_headers {"content-type" "application/json"})
(var _resp_headers {})

(fn make-req []
  {:get_headers (fn [] _req_headers)
   :get_method (fn [] "GET")
   :read_body (fn [] nil)
   :get_body_data (fn [] nil)
   :set_header (fn [k v] (tset _req_headers k v))
   :clear_header (fn [k] (tset _req_headers k nil))
   :start_time (fn [] (os.time))})

(fn make-resp-header-proxy []
  (setmetatable {}
    {:__newindex (fn [_ k v] (tset _resp_headers k v))
     :__index (fn [_ k] (. _resp_headers k))}))

(set _G.ngx
  {:INFO 6 :WARN 5 :ERR 3
   :shared {:uplink_cache cache-dict
            :uplink_metrics metrics-dict
            :uplink_config config-dict
            :uplink_circuit circuit-dict
            :uplink_ratelimit ratelimit-dict
            :uplink_otel otel-dict}
   :log (fn [& _] nil)
   :now (fn [] (os.time))
   :md5 (fn [s] (string.format "%d:%s:%s" (# s) (s:sub 1 1) (s:sub -1)))
   ;; Encode bytes as lowercase hex — not real base64 but deterministic for tests.
   :encode_base64 (fn [s] (s:gsub "." (fn [c] (string.format "%02x" (string.byte c)))))
   :var {:request_id "abcdef0123456789abcdef0123456789"
         :uri "/users/v1/profile"
         :request_uri "/users/v1/profile"
         :svc_name "users"
         :upstream_path ""
         :upstream_host_header ""
         :upstream_response_time "0.042"
         :traceparent ""}
   :req (make-req)
   :header (make-resp-header-proxy)
   :status 200
   :say (fn [_] nil)
   :print (fn [_] nil)
   ;; ngx.exit: record code then raise so callers can catch with pcall.
   :exit (fn [code]
           (set _last_exit code)
           (error (.. "ngx.exit:" code)))})

(set _G._mock_dicts
  {:cache cache-dict :metrics metrics-dict :config config-dict
   :circuit circuit-dict :ratelimit ratelimit-dict :otel otel-dict})

(fn reset-http []
  (set http-response {:status 200 :headers {"content-type" "application/json"} :body "{}"})
  (set http-error nil))

(set _G.set_http_response (fn [res] (set http-response res) (set http-error nil)))
(set _G.set_http_error (fn [err] (set http-error err) (set http-response nil)))
(set _G.set_rl_delay (fn [d] (set rl-delay d)))

(set _G.get_last_exit (fn [] _last_exit))

(set _G.reset_mocks
  (fn []
    (cache-dict:_reset)
    (metrics-dict:_reset)
    (config-dict:_reset)
    (circuit-dict:_reset)
    (ratelimit-dict:_reset)
    (otel-dict:_reset)
    (reset-http)
    (set rl-delay 0)
    (set _last_exit nil)
    (set _req_headers {"content-type" "application/json"})
    (set _resp_headers {})
    (tset _G.ngx :status 200)
    (tset _G.ngx :header (make-resp-header-proxy))
    (tset _G.ngx :var {:request_id "abcdef0123456789abcdef0123456789"
                       :uri "/users/v1/profile"
                       :request_uri "/users/v1/profile"
                       :svc_name "users"
                       :upstream_path ""
                       :upstream_host_header ""
                       :upstream_response_time "0.042"
                       :traceparent ""})
    (tset _G.ngx :req (make-req))
    (tset _G.ngx :encode_base64
      (fn [s] (s:gsub "." (fn [c] (string.format "%02x" (string.byte c))))))))
