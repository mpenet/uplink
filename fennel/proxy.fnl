(local http (require :resty.http))
(local config-mod (require :config))
(local metrics (require :metrics))

(local keepalive-timeout-ms 60000)
(local keepalive-pool-size 100)

(local hop-by-hop
  {:connection true
   :keep-alive true
   "proxy-authenticate" true
   "proxy-authorization" true
   :te true
   :trailers true
   "transfer-encoding" true
   :upgrade true
   :host true})

;; Methods that carry a request body.
(local body-methods {:POST true :PUT true :PATCH true})

;; Per-worker route table cache — rebuilt only when config version changes.
(var local-version 0)
(var local-routes nil)

(fn build-route-table [cfg]
  (let [entries []]
    (each [_ svc (ipairs cfg.services)]
      (table.insert entries {:prefix (.. "/" svc.name) :service svc}))
    (table.sort entries (fn [a b] (> (# a.prefix) (# b.prefix))))
    entries))

(fn get-routes []
  (let [ver (config-mod.get-version)]
    (when (not= ver local-version)
      (let [cfg (config-mod.load-from-shared)]
        (set local-routes (build-route-table cfg))
        (set local-version ver)
        (ngx.log ngx.INFO "route table rebuilt for config version=" ver)))
    local-routes))

;; Uses string.find (no allocation) for prefix check and string.byte for
;; next-char check (no allocation) instead of string.sub comparisons.
(fn match-route [route-table path]
  (let [plen (# path)]
    (var matched nil)
    (each [_ entry (ipairs route-table) &until matched]
      (let [p entry.prefix
            elen (# p)]
        (when (and (<= elen plen)
                   (= (string.find path p 1 true) 1)
                   (or (= plen elen)
                       (= (string.byte path (+ elen 1)) 47)))
          (set matched entry))))
    matched))

;; ngx.req.get_headers() already returns lowercased keys in OpenResty.
;; No :lower() call needed.
(fn copy-req-headers [method]
  (let [out {}
        headers (ngx.req.get_headers)]
    (each [k v (pairs headers)]
      (when (not (. hop-by-hop k))
        (tset out k v)))
    (when (not (. out :x-request-id))
      (let [req-id (or (. headers :x-request-id) ngx.var.request_id)]
        (when req-id (tset out "x-request-id" req-id))))
    out))

;; lua-resty-http also returns lowercased response header keys.
(fn copy-res-headers [res-headers]
  (each [k v (pairs res-headers)]
    (when (not (. hop-by-hop k))
      (ngx.header k v))))

(fn proxy [entry]
  (let [prefix   entry.prefix
        upstream entry.service.upstream
        uri      ngx.var.request_uri
        stripped (if (= (uri:sub 1 (# prefix)) prefix)
                   (let [rest (uri:sub (+ (# prefix) 1))]
                     (if (= rest "") "/" rest))
                   uri)
        target   (.. upstream stripped)
        method   (ngx.req.get_method)
        headers  (copy-req-headers method)
        _        (when (. body-methods method) (ngx.req.read_body))
        body     (ngx.req.get_body_data)
        client   (http.new)
        _        (client:set_timeout 30000)
        (res err) (client:request_uri target
                    {:method  method
                     :headers headers
                     :body    body
                     :ssl_verify false})]
    (metrics.proxy-request entry.service.name)
    (if err
      (do
        (client:close)
        (metrics.proxy-error entry.service.name 502)
        (ngx.log ngx.ERR "proxy error upstream=" target ": " err)
        (ngx.status 502)
        (ngx.say "{\"error\":\"bad gateway\"}"))
      (do
        (client:set_keepalive keepalive-timeout-ms keepalive-pool-size)
        (when (>= res.status 500)
          (metrics.proxy-error entry.service.name res.status))
        (ngx.status res.status)
        (copy-res-headers res.headers)
        (ngx.say res.body)))))

(fn handle []
  (let [route-table (get-routes)
        path        ngx.var.uri
        entry       (match-route route-table path)]
    (if entry
      (proxy entry)
      (do
        (ngx.status 404)
        (ngx.say "{\"error\":\"no service matched\"}")))))

{:build-route-table build-route-table
 :match-route match-route
 :handle handle}
