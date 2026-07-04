;; Reads config.json and generates three nginx include files:
;;   nginx/upstreams.conf  — upstream{} blocks + CORS maps  (http context)
;;   nginx/locations.conf  — one location block per service  (server context)
;;   nginx/listen.conf     — listen + TLS/mTLS directives    (server context)
;;
;; Run before starting nginx:
;;   luajit generate.lua        (Docker / OpenResty luajit)
;;   lua generate.lua           (dev, requires dkjson)
;;
;; upstream: string, array of strings, or array of {url, weight, max_fails,
;; fail_timeout} objects — all forms may be mixed in the same array.
;;
;; balancing: "round_robin" (default), "least_conn", "ip_hash", "random".
;;
;; websocket: true adds Upgrade/Connection headers. Any proxy_set_header in a
;; location overrides ALL server-block proxy_set_header directives, so the
;; full header set is re-emitted in WebSocket locations.
;;
;; CORS: single/wildcard origin → add_header directives; multiple specific
;; origins → a map{} block in upstreams.conf for dynamic matching.
;;
;; Regex locations (~ ^/name(/|$)) enforce slash boundary. Longer names
;; emitted first so /users-v2 wins over /users.
;;
;; server.tls: server-side TLS. cert + key required; client_ca enables mTLS.

(local json
  (let [(ok m) (pcall require :cjson)]
    (if ok m (require :dkjson))))

(fn read-file [path]
  (let [f (assert (io.open path :r) (.. "cannot open: " path))
        data (f:read :*a)]
    (f:close)
    data))

(fn validate-name [name]
  (assert (name:match "^[a-zA-Z0-9_-]+$")
          (.. "invalid service name: '" name "' — only [a-zA-Z0-9_-] allowed")))

;; Normalise upstream field to array of entry objects {url, ?weight, ...}.
(fn upstream-entries [svc]
  (let [raw (if (= (type svc.upstream) :string) [svc.upstream] svc.upstream)]
    (icollect [_ u (ipairs raw)]
      (if (= (type u) :string) {:url u} u))))

(fn upstream-addr [url]
  (let [host (url:match "^https?://([^/]+)")]
    (if (not host)
      url
      ;; No explicit port on an https URL → default to 443 so nginx doesn't
      ;; connect on port 80 and then try SSL on it.
      (if (and (url:match "^https://") (not (host:match ":")))
        (.. host ":443")
        host))))

(fn first-upstream-url [svc]
  (. (upstream-entries svc) 1 :url))

(fn use-https? [svc]
  (let [first (first-upstream-url svc)]
    (or (not= nil (first:match "^https://"))
        (and svc.tls (or svc.tls.cert svc.tls.key)))))

;; Host header sent upstream. Explicit field wins; falls back to first URL host.
(fn service-host-hdr [svc]
  (or svc.host_header (upstream-addr (first-upstream-url svc))))

;; Nginx variable name for per-service CORS origin map (- replaced with _).
(fn cors-var [svc-name]
  (.. "$cors_origin_" (svc-name:gsub "-" "_")))

;; ── Upstream block ────────────────────────────────────────────────────────────

(fn emit-upstream [svc buf]
  (let [ka (or svc.keepalive {})
        pool-size (or ka.pool_size 32)
        requests (or ka.requests 1000)
        timeout (or ka.timeout "60s")
        entries (upstream-entries svc)]
    (table.insert buf (.. "upstream " svc.name "_upstream {\n"))
    (when (and svc.balancing (not= svc.balancing "round_robin"))
      (table.insert buf (.. "    " svc.balancing ";\n")))
    (each [_ entry (ipairs entries)]
      (var params "")
      (when entry.weight
        (set params (.. params " weight=" (tostring entry.weight))))
      (when entry.max_fails
        (set params (.. params " max_fails=" (tostring entry.max_fails))))
      (when entry.fail_timeout
        (set params (.. params " fail_timeout=" (tostring entry.fail_timeout))))
      (table.insert buf (.. "    server " (upstream-addr entry.url) params ";\n")))
    (table.insert buf (.. "    keepalive " (tostring pool-size) ";\n"))
    (table.insert buf (.. "    keepalive_requests " (tostring requests) ";\n"))
    (table.insert buf (.. "    keepalive_timeout " (tostring timeout) ";\n"))
    (table.insert buf "}\n\n")))

;; CORS map block (http context) — only when service has multiple specific origins.
(fn emit-cors-map [svc buf]
  (let [cors svc.cors]
    (when cors
      (let [origins (or cors.origins [])]
        (when (and (> (# origins) 1) (not= (. origins 1) "*"))
          (table.insert buf (.. "map $http_origin " (cors-var svc.name) " {\n"))
          (table.insert buf     "    default \"\";\n")
          (each [_ o (ipairs origins)]
            (table.insert buf (.. "    \"" o "\" \"" o "\";\n")))
          (table.insert buf "}\n\n"))))))

;; ── Location block ────────────────────────────────────────────────────────────

;; Re-emit all server-block proxy_set_header directives. Required when a
;; location adds any proxy_set_header of its own — nginx inherits nothing from
;; the server block once the location has at least one proxy_set_header.
(fn emit-proxy-headers [buf]
  (table.insert buf "    proxy_set_header Host              $upstream_host_header;\n")
  (table.insert buf "    proxy_set_header traceparent       $traceparent;\n")
  (table.insert buf "    proxy_set_header X-Request-ID      $request_id;\n")
  (table.insert buf "    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;\n")
  (table.insert buf "    proxy_set_header X-Forwarded-Proto $scheme;\n"))

(fn emit-cors-directives [svc buf]
  (let [cors svc.cors
        origins (or cors.origins ["*"])
        methods (table.concat (or cors.methods ["GET" "POST" "OPTIONS"]) ", ")
        headers (table.concat (or cors.headers ["Authorization" "Content-Type"]) ", ")
        max-age (tostring (or cors.max_age 3600))
        origin-val (if (= (. origins 1) "*")
                     "'*'"
                     (if (= (# origins) 1)
                       (.. "'" (. origins 1) "'")
                       (cors-var svc.name)))]
    (table.insert buf (.. "    add_header 'Access-Control-Allow-Origin'  " origin-val " always;\n"))
    (table.insert buf (.. "    add_header 'Access-Control-Allow-Methods' '" methods "' always;\n"))
    (table.insert buf (.. "    add_header 'Access-Control-Allow-Headers' '" headers "' always;\n"))
    (table.insert buf (.. "    add_header 'Access-Control-Max-Age'       '" max-age "' always;\n"))
    (when cors.credentials
      (assert (not= (. origins 1) "*")
              (.. "service '" svc.name "': cors.credentials=true is incompatible with origins=[\"*\"] (CORS spec violation)"))
      (table.insert buf "    add_header 'Access-Control-Allow-Credentials' 'true' always;\n"))
    (table.insert buf     "    if ($request_method = OPTIONS) {\n")
    (table.insert buf     "        return 204;\n")
    (table.insert buf     "    }\n")))

(fn emit-location [svc buf]
  (let [https (use-https? svc)
        scheme (if https "https" "http")
        timeout-s (math.max 1 (math.ceil (/ (or svc.timeout 30000) 1000)))
        host-hdr (service-host-hdr svc)]
    (table.insert buf (.. "location ~ ^/" svc.name "(/|$) {\n"))
    (table.insert buf (.. "    set $svc_name             \"" svc.name "\";\n"))
    (table.insert buf (.. "    set $upstream_host_header \"" host-hdr "\";\n"))
    (when https
      (when (and svc.tls svc.tls.cert)
        (table.insert buf (.. "    proxy_ssl_certificate     " svc.tls.cert ";\n")))
      (when (and svc.tls svc.tls.key)
        (table.insert buf (.. "    proxy_ssl_certificate_key " svc.tls.key ";\n")))
      (let [verify (and svc.tls svc.tls.verify)]
        (table.insert buf (.. "    proxy_ssl_verify          " (if verify "on" "off") ";\n")))
      ;; Send SNI so CDN/vhost upstreams can route to the correct certificate.
      (table.insert buf (.. "    proxy_ssl_server_name     on;\n"))
      (table.insert buf (.. "    proxy_ssl_name            \"" host-hdr "\";\n")))
    (table.insert buf (.. "    proxy_connect_timeout     " timeout-s "s;\n"))
    (table.insert buf (.. "    proxy_read_timeout        " timeout-s "s;\n"))
    (table.insert buf (.. "    proxy_send_timeout        " timeout-s "s;\n"))
    (when svc.websocket
      ;; WebSocket: upgrade connection. Re-emit all proxy headers because any
      ;; proxy_set_header in a location blocks server-block inheritance entirely.
      ;; Override proxy_read_timeout to keep long-lived WS connections alive.
      (table.insert buf "    proxy_read_timeout        3600s;\n")
      (table.insert buf "    proxy_set_header Upgrade    $http_upgrade;\n")
      (table.insert buf "    proxy_set_header Connection \"upgrade\";\n")
      (emit-proxy-headers buf))
    (when svc.cors
      (emit-cors-directives svc buf))
    (when svc.nginx_directives
      (each [_ directive (ipairs svc.nginx_directives)]
        (table.insert buf (.. "    " directive ";\n"))))
    (table.insert buf     "    access_by_lua_block        { require(\"router\").access() }\n")
    (table.insert buf     "    header_filter_by_lua_block { require(\"router\").on_response() }\n")
    (table.insert buf     "    log_by_lua_block           { require(\"router\").log() }\n")
    (table.insert buf (.. "    proxy_pass                 " scheme "://" svc.name "_upstream$upstream_path;\n"))
    (table.insert buf "}\n\n")))

;; ── Listen / server TLS block ─────────────────────────────────────────────────

(fn emit-listen [cfg buf]
  (let [stls (and cfg.server cfg.server.tls)]
    (table.insert buf "listen 8080;\n")
    (when stls
      (assert (and stls.cert stls.key)
              "server.tls requires both 'cert' and 'key'")
      (let [port (tostring (or stls.port 8443))
            verify (or stls.verify_client (if stls.client_ca "on" "off"))]
        (table.insert buf (.. "listen " port " ssl;\n"))
        (table.insert buf (.. "ssl_certificate           " stls.cert ";\n"))
        (table.insert buf (.. "ssl_certificate_key       " stls.key ";\n"))
        (table.insert buf     "ssl_protocols             TLSv1.2 TLSv1.3;\n")
        (table.insert buf     "ssl_ciphers               ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;\n")
        (table.insert buf     "ssl_prefer_server_ciphers off;\n")
        (table.insert buf     "ssl_session_timeout       1d;\n")
        (table.insert buf     "ssl_session_cache         shared:SSL:10m;\n")
        (when stls.client_ca
          (table.insert buf (.. "ssl_client_certificate    " stls.client_ca ";\n"))
          (table.insert buf (.. "ssl_verify_client         " verify ";\n")))))))

(let [cfg (json.decode (read-file "config.json"))
      svcs cfg.services
      ;; Longer service names first so overlapping prefixes match correctly.
      _ (table.sort svcs (fn [a b] (> (# a.name) (# b.name))))
      up-buf     ["# Auto-generated by generate.fnl — do not edit\n\n"]
      loc-buf    ["# Auto-generated by generate.fnl — do not edit\n\n"]
      listen-buf ["# Auto-generated by generate.fnl — do not edit\n"]]
  (each [_ svc (ipairs svcs)]
    (validate-name svc.name)
    (emit-cors-map svc up-buf)
    (emit-upstream svc up-buf)
    (emit-location svc loc-buf))
  (emit-listen cfg listen-buf)
  (let [uf (assert (io.open "nginx/upstreams.conf" "w"))]
    (uf:write (table.concat up-buf))
    (uf:close))
  (let [lf (assert (io.open "nginx/locations.conf" "w"))]
    (lf:write (table.concat loc-buf))
    (lf:close))
  (let [ll (assert (io.open "nginx/listen.conf" "w"))]
    (ll:write (table.concat listen-buf))
    (ll:close))
  (io.write (.. "generated nginx/upstreams.conf + nginx/locations.conf"
                " + nginx/listen.conf for " (# svcs) " service(s)\n")))
