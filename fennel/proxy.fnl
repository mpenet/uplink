(local http (require :resty.http))
(local config-mod (require :config))
(local metrics (require :metrics))
(local circuit (require :circuit))
(local ratelimit (require :ratelimit))
(local mtls (require :mtls))

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

(local body-methods {:POST true :PUT true :PATCH true})

;; Per-worker route table cache.
(var local-version 0)
(var local-routes nil)
;; Debounce: only re-read shared-dict version at most every 100ms per worker.
(var last-ver-check 0)

(fn build-route-table [cfg]
  (let [entries []]
    (each [_ svc (ipairs cfg.services)]
      ;; Pre-compute retry status set for O(1) lookup — kept on the service
      ;; object in the route table, never JSON-encoded.
      (when svc.retry
        (let [statuses (or svc.retry.on_status [502 503 504])
              status-set {}]
          (each [_ s (ipairs statuses)]
            (tset status-set s true))
          (tset svc.retry :on_status_set status-set)))
      (table.insert entries {:prefix (.. "/" svc.name) :service svc}))
    (table.sort entries (fn [a b] (> (# a.prefix) (# b.prefix))))
    entries))

(fn get-routes []
  (let [now (ngx.now)]
    (when (>= (- now last-ver-check) 0.1)
      (set last-ver-check now)
      (let [ver (config-mod.get-version)]
        (when (not= ver local-version)
          (let [cfg (config-mod.load-from-shared)]
            (set local-routes (build-route-table cfg))
            (set local-version ver)
            (ngx.log ngx.INFO "route table rebuilt for config version=" ver))))))
  local-routes)

;; string.find (no allocation) + string.byte for slash check (no allocation).
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

;; ── W3C traceparent ───────────────────────────────────────────────────────────
;; ngx.var.request_id is 32 hex chars (16 bytes) — used directly as trace-id.

(fn make-traceparent [incoming-tp]
  (let [req-id (or ngx.var.request_id "00000000000000000000000000000000")
        parent-id (req-id:sub 1 16)
        trace-id (when incoming-tp (incoming-tp:match "^00%-(%x+)%-"))
        valid-id (when (and trace-id (= (# trace-id) 32)) trace-id)]
    (.. "00-" (or valid-id req-id) "-" parent-id "-01")))

;; ── Header helpers ────────────────────────────────────────────────────────────

(fn copy-req-headers [_method incoming-headers]
  (let [out {}
        tp (make-traceparent (. incoming-headers :traceparent))]
    (each [k v (pairs incoming-headers)]
      (when (not (. hop-by-hop k))
        (tset out k v)))
    (when (not (. out :x-request-id))
      (let [req-id (or (. incoming-headers :x-request-id) ngx.var.request_id)]
        (when req-id (tset out "x-request-id" req-id))))
    (tset out "traceparent" tp)
    (let [ts (. incoming-headers :tracestate)]
      (when ts (tset out "tracestate" ts)))
    out))

(fn copy-res-headers [res-headers]
  (each [k v (pairs res-headers)]
    (when (not (. hop-by-hop k))
      (ngx.header k v))))

;; ── HTTP request execution ────────────────────────────────────────────────────

;; For the resty.http path: uses connect + request (not request_uri) so the
;; response body can be streamed to the client without buffering.
;; Returns:
;;   mTLS path  → {status, headers, body}          (already buffered)
;;   http path  → {status, headers, body-reader, client}  (streaming)
;;   on error   → (nil, err-string)
(fn do-request [target method headers body timeout service]
  (let [tls service.tls
        use-mtls (and tls (or tls.cert tls.key))]
    (if use-mtls
      (let [(ok result) (pcall mtls.request
                          {:url target :method method :headers headers
                           :body (or body "") :timeout timeout
                           :service-name service.name :tls tls})]
        (if ok (values result nil) (values nil result)))
      (let [client (http.new)
            _ (client:set_timeout timeout)
            ssl-verify (and tls tls.verify)
            (parsed err0) (client:parse_uri target true)]
        (if err0
          (do (client:close) (values nil err0))
          (let [scheme (. parsed 1)
                host (. parsed 2)
                port (. parsed 3)
                path (or (. parsed 4) "/")
                (ok err) (client:connect {:scheme scheme :host host :port port
                                          :ssl_verify (or ssl-verify false)
                                          :ssl_server_name host})]
            (if (not ok)
              (do (client:close) (values nil err))
              (let [req-headers (collect [k v (pairs headers)] (values k v))]
                (tset req-headers :host host)
                (let [(res err2) (client:request {:method method :path path
                                                  :headers req-headers :body body})]
                  (if err2
                    (do (client:close) (values nil err2))
                    (values {:status res.status :headers res.headers
                             :body-reader res.body_reader :client client} nil)))))))))))

;; Close a streaming response without sending it (used before retry).
(fn close-res [res]
  (when (and res res.client)
    (res.client:close)))

;; Stream resty.http response or send buffered mTLS body.
(fn send-response [res]
  (if res.body-reader
    (let [reader res.body-reader
          client res.client]
      (var done false)
      (while (not done)
        (let [(chunk err) (reader 8192)]
          (if err
            (do
              (ngx.log ngx.ERR "upstream read error: " err)
              (set done true)
              (client:close))
            (if chunk
              (ngx.print chunk)
              (do
                (set done true)
                (client:set_keepalive keepalive-timeout-ms keepalive-pool-size)))))))
    (ngx.say (or res.body ""))))

;; ── Retry helpers ─────────────────────────────────────────────────────────────

(fn retryable? [service status err]
  (let [retry (or service.retry {})
        count (or retry.count 0)]
    (and (> count 0)
         (or err
             (and status (. (or retry.on_status_set {}) status))))))

;; ── Main proxy ───────────────────────────────────────────────────────────────

(fn proxy [entry]
  (let [service entry.service
        prefix entry.prefix
        upstream service.upstream
        uri ngx.var.request_uri
        rest (uri:sub (+ (# prefix) 1))
        stripped (if (= (uri:sub 1 (# prefix)) prefix)
                   (if (= rest "") "/" rest)
                   uri)
        target (.. upstream stripped)
        method (ngx.req.get_method)
        in-headers (ngx.req.get_headers)
        headers (copy-req-headers method in-headers)
        _ (when (. body-methods method) (ngx.req.read_body))
        body (ngx.req.get_body_data)
        timeout (or service.timeout 30000)
        start (ngx.now)]

    ;; Rate limit check
    (let [(rl-ok _) (ratelimit.check service)]
      (if (= rl-ok false)
        (do
          (ngx.status 429)
          (ngx.say "{\"error\":\"rate limit exceeded\"}"))

        ;; Circuit breaker check
        (if (not (circuit.allow? service))
          (do
            (metrics.circuit-open service.name)
            (ngx.status 503)
            (ngx.say "{\"error\":\"service unavailable (circuit open)\"}"))

          ;; Make request (with one retry on retryable failure)
          (let [(res err) (do-request target method headers body timeout service)
                need-retry (retryable? service (and res res.status) err)]
            (when need-retry (close-res res))
            (let [(final-res final-err)
                  (if need-retry
                    (do-request target method headers body timeout service)
                    (values res err))]
              (metrics.proxy-request service.name)
              (metrics.observe-latency service.name (- (ngx.now) start))

              (if final-err
                (do
                  (close-res final-res)
                  (circuit.on-failure! service)
                  (metrics.proxy-error service.name 502)
                  (ngx.log ngx.ERR "proxy error upstream=" target ": " final-err)
                  (ngx.status 502)
                  (ngx.say "{\"error\":\"bad gateway\"}"))
                (do
                  (if (>= final-res.status 500)
                    (do
                      (circuit.on-failure! service)
                      (metrics.proxy-error service.name final-res.status))
                    (circuit.on-success! service))
                  (ngx.status final-res.status)
                  (copy-res-headers final-res.headers)
                  (send-response final-res))))))))))

(fn handle []
  (let [route-table (get-routes)
        path ngx.var.uri
        entry (match-route route-table path)]
    (if entry
      (proxy entry)
      (do
        (ngx.status 404)
        (ngx.say "{\"error\":\"no service matched\"}")))))

{:build-route-table build-route-table
 :match-route match-route
 :handle handle}
