(set package.path (.. "./lib/?.lua;" package.path))

;; Substitute dkjson for the OpenResty-only cjson C module.
(tset package.preload :cjson
  (fn []
    (let [dk (require :dkjson)]
      {:encode dk.encode :decode dk.decode})))

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

(set _G.ngx
  {:INFO 6
   :WARN 5
   :ERR 3
   :shared {:ladon_cache cache-dict
            :ladon_metrics metrics-dict
            :ladon_config config-dict}
   :log (fn [& _] nil)
   :now (fn [] (os.time))
   :md5 (fn [s] (string.format "%d:%s:%s" (# s) (s:sub 1 1) (s:sub -1)))
   :var {:request_id "test-req-id"
         :uri "/users/v1/profile"
         :request_uri "/users/v1/profile"}
   :req {:get_headers (fn [] {"content-type" "application/json"})
         :get_method (fn [] "GET")
         :read_body (fn [] nil)
         :get_body_data (fn [] nil)}
   :header (setmetatable {} {:__newindex (fn [] nil)})
   :status (fn [_] nil)
   :say (fn [_] nil)})

(set _G._mock_dicts {:cache cache-dict :metrics metrics-dict :config config-dict})

;; ngx.semaphore mock — always acquires immediately.
(tset package.preload "ngx.semaphore"
  (fn []
    {:new (fn [n]
            (var count (or n 0))
            {:wait (fn [_ _t] (set count (- count 1)) true)
             :post (fn [_ n2] (set count (+ count (or n2 1))))})}))

;; resty.http mock — configurable per-test via set_http_response / set_http_error.
(var http-response {:status 200 :headers {"content-type" "application/json"} :body "{}"})
(var http-error nil)

(tset package.preload "resty.http"
  (fn []
    {:new (fn []
            {:set_timeout (fn [] nil)
             :set_keepalive (fn [] nil)
             :close (fn [] nil)
             :request_uri (fn [_ _url _opts]
                            (if http-error
                              (values nil http-error)
                              (values http-response nil)))})}))

(fn reset-http []
  (set http-response {:status 200 :headers {"content-type" "application/json"} :body "{}"})
  (set http-error nil))

(set _G.set_http_response (fn [res] (set http-response res) (set http-error nil)))
(set _G.set_http_error (fn [err] (set http-error err) (set http-response nil)))

(set _G.reset_mocks
  (fn []
    (cache-dict:_reset)
    (metrics-dict:_reset)
    (config-dict:_reset)
    (reset-http)
    (tset _G.ngx :var {:request_id "test-req-id"
                       :uri "/users/v1/profile"
                       :request_uri "/users/v1/profile"})
    (tset _G.ngx :req
      {:get_headers (fn [] {"content-type" "application/json"})
       :get_method (fn [] "GET")
       :read_body (fn [] nil)
       :get_body_data (fn [] nil)})))
