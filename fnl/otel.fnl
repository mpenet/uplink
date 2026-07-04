;; OpenTelemetry span exporter — OTLP/HTTP+JSON.
;;
;; Zero cost when disabled: all code is guarded by the module-level dict check.
;; Enable by adding both:
;;   1. lua_shared_dict uplink_otel 2m;  in nginx.conf
;;   2. "otel": { "endpoint": "..." }   in config.json
;;
;; Without (1), ngx.shared.uplink_otel is nil and every function is a no-op.
;; Without (2), no flush timer starts; written spans expire after 120 s TTL.
;;
;; Each worker flushes independently. Duplicate exports under concurrent flush
;; windows are possible but rare and harmless for traces.
;;
;; Buffer: ring of BUFFER_SIZE slots in uplink_otel. Oldest spans are silently
;; overwritten if the flush timer falls too far behind.
;;
;; Span IDs: traceId and parentSpanId are extracted from the W3C traceparent
;; set by router.fnl. spanId is the first 16 chars of ngx.var.request_id
;; (same value router.fnl forwards upstream in the traceparent it generates).
;; IDs are base64-encoded as required by the OTLP/JSON spec.

(local json (require :cjson))

(local BUFFER_SIZE 1000)

(fn get-dict []
  (. ngx.shared :uplink_otel))

;; Convert hex string (traceId=32 chars, spanId=16 chars) to base64 for OTLP/JSON.
(fn hex->b64 [hex]
  (let [bytes (hex:gsub ".." (fn [h] (string.char (tonumber h 16))))]
    (ngx.encode_base64 bytes)))

;; Parse W3C traceparent → {trace-id-hex, parent-span-id-hex} or nil.
(fn parse-traceparent [tp]
  (when (and tp (> (# tp) 0))
    (let [parts []]
      (tp:gsub "([^%-]+)" (fn [p] (table.insert parts p)))
      (when (and (>= (# parts) 4) (= (. parts 1) "00"))
        {:trace-id (. parts 2) :parent-id (. parts 3)}))))

(fn build-span [svc-name]
  (let [req-id (or ngx.var.request_id "00000000000000000000000000000000")
        tp (parse-traceparent ngx.var.traceparent)
        trace-id (or (and tp tp.trace-id) req-id)
        span-id-hex (req-id:sub 1 16)
        start-ns (tostring (math.floor (* (ngx.req.start_time) 1e9)))
        end-ns (tostring (math.floor (* (ngx.now) 1e9)))
        status ngx.status
        span {:traceId (hex->b64 trace-id)
              :spanId (hex->b64 span-id-hex)
              :name (.. "proxy " svc-name)
              :kind 3
              :startTimeUnixNano start-ns
              :endTimeUnixNano end-ns
              :attributes
              [{:key "http.method" :value {:stringValue (ngx.req.get_method)}}
               {:key "http.target" :value {:stringValue ngx.var.uri}}
               {:key "http.status_code" :value {:intValue status}}
               {:key "uplink.service" :value {:stringValue svc-name}}]
              :status {:code (if (>= status 500) 2 1)}}]
    (when (and tp tp.parent-id)
      (tset span :parentSpanId (hex->b64 tp.parent-id)))
    span))

;; Write one span to the ring buffer. Overwrites oldest slot when full.
(fn push! [svc-name]
  (let [d (get-dict)]
    (when d
      (let [span (build-span svc-name)
            n (d:incr :count 1 0)
            slot (% (- n 1) BUFFER_SIZE)]
        (d:set (.. "s:" slot) (json.encode span) 120)))))

;; Read up to batch_size pending spans and POST to the OTLP collector.
;; Advances the flushed cursor regardless of POST success — traces are
;; best-effort; stalling on a down collector would pile up retries.
(fn flush [cfg]
  (let [d (get-dict)]
    (when d
      (let [count (or (d:get :count) 0)
            flushed (or (d:get :flushed) 0)
            batch (or cfg.batch_size 100)]
        (when (> count flushed)
          (let [spans []
                limit (math.min count (+ flushed batch))]
            (for [i (+ flushed 1) limit]
              (let [slot (% (- i 1) BUFFER_SIZE)
                    raw (d:get (.. "s:" slot))]
                (when raw
                  (let [(ok v) (pcall json.decode raw)]
                    (when ok (table.insert spans v))))))
            (d:set :flushed limit 0)
            (when (> (# spans) 0)
              (let [http (require :resty.http)
                    c (http.new)
                    body (json.encode
                           {:resourceSpans
                            [{:resource
                              {:attributes [{:key "service.name"
                                            :value {:stringValue
                                                    (or cfg.service_name "uplink")}}]}
                              :scopeSpans
                              [{:scope {:name "uplink"}
                                :spans spans}]}]})
                    (res err) (c:request_uri cfg.endpoint
                                {:method "POST"
                                 :body body
                                 :headers {"Content-Type" "application/json"}})]
                (when err
                  (ngx.log ngx.WARN "otel: flush error: " err))
                (when (and res (not= res.status 200))
                  (ngx.log ngx.WARN "otel: collector returned " res.status))))))))))

(fn schedule-flush [cfg]
  (let [interval (or cfg.flush_interval 5)]
    (fn tick []
      (ngx.timer.at interval
        (fn [premature]
          (when (not premature)
            (let [(ok err) (pcall flush cfg)]
              (when (not ok)
                (ngx.log ngx.WARN "otel: flush error: " (tostring err))))
            (tick)))))
    (tick)))

(fn init-worker [cfg]
  (let [d (get-dict)]
    (when d
      (if cfg.otel
        (schedule-flush cfg.otel)
        (ngx.log ngx.WARN
          "otel: uplink_otel dict present but no otel config in config.json")))))

{:push! push! :flush flush :init-worker init-worker}
