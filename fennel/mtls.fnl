;; Minimal HTTP/1.1 client over ngx.socket.tcp with mTLS support.
;; Used only when service.tls.cert is configured; otherwise proxy.fnl uses
;; lua-resty-http (which does not expose the socket for pre-handshake setsslctx).
;;
;; Requires OpenResty >= 1.21.4 and lua-resty-openssl >= 0.8.
;;
;; Connection pooling: setkeepalive reuses TCP connections across requests.
;; TLS session resumption: sslhandshake session objects cached per service,
;; eliminating the full TLS key exchange on pooled connections.
;;
;; service.tls fields:
;;   cert                — path to PEM client certificate file
;;   key                 — path to PEM private key file
;;   verify              — verify server certificate (default false)
;;   keepalive_timeout   — pool idle timeout ms (default 60000)
;;   keepalive_pool_size — max idle connections per pool (default 10)

(local ssl-ctx-mod (require "resty.openssl.ssl_ctx"))
(local x509-mod (require "resty.openssl.x509"))
(local pkey-mod (require "resty.openssl.pkey"))

;; Per-worker SSL context cache — expensive to build, reused across requests.
(local ctx-cache {})
;; Per-worker TLS session cache — passed to sslhandshake for session resumption.
(local session-cache {})

(fn read-file [path]
  (let [f (assert (io.open path :r) (.. "cannot open: " path))
        data (f:read :*a)]
    (f:close)
    data))

(fn build-ssl-ctx [tls]
  (let [(ctx err) (ssl-ctx-mod.new)]
    (when err (error (.. "ssl_ctx.new: " err)))
    (when tls.cert
      (let [(cert err2) (x509-mod.new (read-file tls.cert))]
        (when err2 (error (.. "x509.new: " err2)))
        (let [(ok err3) (ctx:set_certificate cert)]
          (when (not ok) (error (.. "set_certificate: " err3))))))
    (when tls.key
      (let [(key err2) (pkey-mod.new (read-file tls.key))]
        (when err2 (error (.. "pkey.new: " err2)))
        (let [(ok err3) (ctx:set_private_key key)]
          (when (not ok) (error (.. "set_private_key: " err3))))))
    ctx))

(fn get-ssl-ctx [service-name tls]
  (when (not (. ctx-cache service-name))
    (tset ctx-cache service-name (build-ssl-ctx tls)))
  (. ctx-cache service-name))

;; ── URL parsing ──────────────────────────────────────────────────────────────

(fn parse-url [url]
  (let [is-https (= (url:sub 1 5) "https")
        _ (assert (or is-https (= (url:sub 1 4) "http"))
                  (.. "unsupported URL: " url))
        scheme (if is-https "https" "http")
        rest (url:sub (if is-https 9 8))
        slash (rest:find "/" 1 true)
        host-port (if slash (rest:sub 1 (- slash 1)) rest)
        path (if slash (rest:sub slash) "/")
        colon (host-port:find ":" 1 true)
        host (if colon (host-port:sub 1 (- colon 1)) host-port)
        port (if colon (tonumber (host-port:sub (+ colon 1)))
                 (if is-https 443 80))]
    {:scheme scheme :host host :port port :path path}))

;; ── HTTP/1.1 response reader ─────────────────────────────────────────────────

(fn recv-line [sock]
  (let [reader (sock:receiveuntil "\r\n")
        (data err) (reader)]
    (if err (error (.. "recv line: " err)) (or data ""))))

(fn recv-headers [sock]
  (let [headers {}]
    (var done false)
    (while (not done)
      (let [line (recv-line sock)]
        (if (= line "")
          (set done true)
          (let [(n v) (line:match "^([^:]+):%s*(.-)%s*$")]
            (when n (tset headers (n:lower) v))))))
    headers))

(fn recv-body [sock headers]
  (let [te (or (. headers "transfer-encoding") "")
        cl (. headers "content-length")]
    (if (te:find "chunked" 1 true)
      (let [parts []]
        (var done false)
        (while (not done)
          (let [size-line (recv-line sock)
                hex (size-line:match "^(%x+)")
                size (if hex (tonumber hex 16) 0)]
            (if (= size 0)
              (do (recv-line sock) (set done true))
              (let [(chunk err) (sock:receive size)]
                (when err (error (.. "chunk recv: " err)))
                (table.insert parts chunk)
                (recv-line sock)))))
        (table.concat parts))
      (if cl
        (let [(data err) (sock:receive (tonumber cl))]
          (if err (error (.. "body recv: " err)) (or data "")))
        (let [(data _) (sock:receive :*a)]
          (or data ""))))))

;; ── Public request function ───────────────────────────────────────────────────

;; opts: {url, method, headers, body, timeout, service-name, tls}
;; Returns {status, headers, body} or raises on error.
(fn request [opts]
  (let [url (parse-url opts.url)
        svc-name (or opts.service-name "__default")
        tls (or opts.tls {})
        sock (ngx.socket.tcp)]
    (sock:settimeout (or opts.timeout 30000))
    (let [(ok err) (sock:connect url.host url.port)]
      (when (not ok)
        (error (.. "connect " url.host ":" url.port ": " (or err "unknown")))))
    (when (= url.scheme "https")
      ;; getreusedtimes > 0 means socket came from the pool already in TLS state.
      ;; Skip setsslctx + sslhandshake entirely — saves one round-trip per reused conn.
      (let [reused (sock:getreusedtimes)]
        (when (= reused 0)
          (let [ctx (get-ssl-ctx svc-name tls)
                (ok err) (sock:setsslctx ctx.ctx)]
            (when (not ok) (error (.. "setsslctx: " (or err "unknown"))))
            (let [verify (if (= tls.verify nil) false tls.verify)
                  prev-session (. session-cache svc-name)
                  (session err2) (sock:sslhandshake prev-session url.host verify)]
              (when (not session) (error (.. "sslhandshake: " (or err2 "unknown"))))
              ;; Cache session for resumption on next fresh connection to this service.
              (tset session-cache svc-name session))))))
    (let [method (or opts.method "GET")
          body (or opts.body "")
          req-headers (or opts.headers {})
          buf [(.. method " " url.path " HTTP/1.1\r\n")
               (.. "Host: " url.host "\r\n")
               "Connection: keep-alive\r\n"
               (.. "Content-Length: " (# body) "\r\n")]]
      (each [k v (pairs req-headers)]
        (table.insert buf (.. k ": " v "\r\n")))
      (table.insert buf "\r\n")
      (table.insert buf body)
      (let [(ok err) (sock:send (table.concat buf))]
        (when (not ok) (error (.. "send: " (or err "unknown"))))))
    (let [status-line (recv-line sock)
          status (tonumber (status-line:match "HTTP/%d%.%d (%d+)"))
          _ (assert status (.. "bad status line: " status-line))
          resp-headers (recv-headers sock)
          body (recv-body sock resp-headers)
          ka-timeout (or tls.keepalive_timeout 60000)
          pool-size (or tls.keepalive_pool_size 10)
          conn-header (or (. resp-headers "connection") "")]
      (if (conn-header:find "close" 1 true)
        (sock:close)
        (sock:setkeepalive ka-timeout pool-size))
      {:status status :headers resp-headers :body body})))

{:request request}
