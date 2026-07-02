;; Reads config.json and generates two nginx include files:
;;   nginx/upstreams.conf  — upstream{} blocks + CORS maps  (http context)
;;   nginx/locations.conf  — one location block per service  (server context)
;;
;; Run before starting nginx:
;;   luajit generate.lua        (Docker / OpenResty luajit)
;;   lua generate.lua           (dev, requires dkjson)
;;
;; upstream accepts a string or array — arrays generate multiple server lines
;; for nginx round-robin load balancing.
;;
;; CORS: single/wildcard origin → add_header directives; multiple specific
;; origins → a map{} block in upstreams.conf so nginx matches dynamically.
;;
;; Regex locations (~ ^/name(/|$)) enforce slash boundary so /users does not
;; match /userssettings. Longer names emitted first so /users-v2 wins over /users.

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

;; Normalise upstream field — string or array — to an array of URL strings.
(fn upstream-urls [svc]
  (if (= (type svc.upstream) :string) [svc.upstream] svc.upstream))

(fn upstream-addr [url]
  (or (url:match "^https?://([^/]+)") url))

(fn use-https? [svc]
  (let [first (. (upstream-urls svc) 1)]
    (or (not= nil (first:match "^https://"))
        (and svc.tls (or svc.tls.cert svc.tls.key)))))

;; Host header sent to upstream. Explicit field wins; falls back to first URL host.
(fn service-host-hdr [svc]
  (or svc.host_header (upstream-addr (. (upstream-urls svc) 1))))

;; Nginx variable name for per-service CORS origin map (- replaced with _).
(fn cors-var [svc-name]
  (.. "$cors_origin_" (svc-name:gsub "-" "_")))

;; ── Upstream block ────────────────────────────────────────────────────────────

(fn emit-upstream [svc buf]
  (let [ka (or svc.keepalive {})
        pool-size (or ka.pool_size 32)
        requests (or ka.requests 1000)
        timeout (or ka.timeout "60s")]
    (table.insert buf (.. "upstream " svc.name "_upstream {\n"))
    (each [_ url (ipairs (upstream-urls svc))]
      (table.insert buf (.. "    server " (upstream-addr url) ";\n")))
    (table.insert buf (.. "    keepalive " (tostring pool-size) ";\n"))
    (table.insert buf (.. "    keepalive_requests " (tostring requests) ";\n"))
    (table.insert buf (.. "    keepalive_timeout " (tostring timeout) ";\n"))
    (table.insert buf "}\n\n")))

;; CORS map block (http context) — only emitted when service has multiple
;; specific origins. Single/wildcard origins need no map.
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

(fn emit-cors-directives [svc buf]
  (let [cors svc.cors
        origins (or cors.origins ["*"])
        methods (table.concat (or cors.methods ["GET" "POST" "OPTIONS"]) ", ")
        headers (table.concat (or cors.headers ["Authorization" "Content-Type"]) ", ")
        max-age (tostring (or cors.max_age 3600))
        ;; Single wildcard → literal *; single specific → literal origin;
        ;; multiple specific → nginx map variable (set by emit-cors-map).
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
        (table.insert buf (.. "    proxy_ssl_verify          " (if verify "on" "off") ";\n"))))
    (table.insert buf (.. "    proxy_connect_timeout     " timeout-s "s;\n"))
    (table.insert buf (.. "    proxy_read_timeout        " timeout-s "s;\n"))
    (table.insert buf (.. "    proxy_send_timeout        " timeout-s "s;\n"))
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

(let [cfg (json.decode (read-file "config.json"))
      svcs cfg.services
      ;; Longer service names first so overlapping prefixes match correctly.
      _ (table.sort svcs (fn [a b] (> (# a.name) (# b.name))))
      up-buf  ["# Auto-generated by generate.fnl — do not edit\n\n"]
      loc-buf ["# Auto-generated by generate.fnl — do not edit\n\n"]]
  (each [_ svc (ipairs svcs)]
    (validate-name svc.name)
    (emit-cors-map svc up-buf)
    (emit-upstream svc up-buf)
    (emit-location svc loc-buf))
  (let [uf (assert (io.open "nginx/upstreams.conf" "w"))]
    (uf:write (table.concat up-buf))
    (uf:close))
  (let [lf (assert (io.open "nginx/locations.conf" "w"))]
    (lf:write (table.concat loc-buf))
    (lf:close))
  (io.write (.. "generated nginx/upstreams.conf + nginx/locations.conf"
                " for " (# svcs) " service(s)\n")))
