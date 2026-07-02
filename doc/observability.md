# Observability

## Prometheus metrics

`GET /metrics` — Prometheus text format:

| Metric | Labels | Description |
|--------|--------|-------------|
| `proxy_requests_total` | `service` | Proxied requests |
| `proxy_errors_total` | `service`, `code` | 5xx responses by status code |
| `proxy_request_duration_seconds` | `service`, `le` | Upstream response time histogram |
| `circuit_open_total` | `service` | Requests rejected due to open circuit |
| `schema_fetch_total` | `service`, `status` | Schema fetches (`ok`, `error`, `background_ok`, `background_error`) |
| `schema_cache_result_total` | `service`, `result` | Aggregation cache outcomes (`ok`, `error`) |

## Access log

Every request is logged to `logs/access.log` as a JSON line:

```json
{"time":"2026-07-02T10:00:00+00:00","service":"users","method":"GET","path":"/users/v1/profile","query":"","status":200,"upstream_time":"0.042","bytes":312,"traceparent":"00-abc...","request_id":"abcdef01...","remote_addr":"10.0.0.1","upstream_addr":"10.0.0.2:8080"}
```

| Field | Description |
|-------|-------------|
| `service` | Service name (`""` for `/healthz`, `/openapi.json`, etc.) |
| `upstream_time` | Upstream response time in seconds (`""` for non-proxied locations) |
| `traceparent` | W3C traceparent, propagated or generated in the access phase |
| `request_id` | nginx `$request_id` — 32 hex characters, unique per request |
| `upstream_addr` | Actual upstream server used (`""` for non-proxied locations) |

Override the log path or format by mounting a custom `nginx/nginx.conf`.

## OpenTelemetry

Uplink exports spans via OTLP/HTTP+JSON. Disabled at zero cost by default — if `uplink_otel` is absent from `nginx.conf`, the check is a single nil comparison per request and no shared dict is touched.

### Enabling

**1. Uncomment the shared dict in `nginx/nginx.conf`:**

```nginx
lua_shared_dict uplink_otel 2m;
```

**2. Add `otel` to `config.json`:**

```json
"otel": {
  "endpoint":       "http://otel-collector:4318/v1/traces",
  "service_name":   "uplink",
  "batch_size":     100,
  "flush_interval": 5
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `endpoint` | — | OTLP/HTTP collector URL (required) |
| `service_name` | `"uplink"` | `service.name` resource attribute |
| `batch_size` | `100` | Max spans per HTTP POST |
| `flush_interval` | `5` | Flush timer interval in seconds |

Both must be set. If the dict is present but `otel` is absent from config, a warning is logged and no spans are exported.

### How it works

Each proxied request produces one span in the log phase. Spans are written to the `uplink_otel` shared dict (ring buffer, 1000 slots). A per-worker timer fires every `flush_interval` seconds and POSTs pending spans as OTLP/HTTP+JSON to the collector.

**Span fields:**

| Field | Source |
|-------|--------|
| `traceId` | Incoming `traceparent` trace ID, or `$request_id` if none |
| `spanId` | First 16 chars of `$request_id` — same value forwarded upstream |
| `parentSpanId` | Parent span ID from incoming `traceparent`, absent if no upstream trace context |
| `name` | `"proxy <service-name>"` |
| `kind` | `3` (SERVER) |
| `startTimeUnixNano` | `ngx.req.start_time()` |
| `endTimeUnixNano` | `ngx.now()` at log phase |

Attributes: `http.method`, `http.target`, `http.status_code`, `uplink.service`.

Trace continuity relies on upstream services propagating `traceparent`. Uplink always injects or generates one in the access phase regardless of whether OTel is enabled.

### Delivery guarantees

Span export is best-effort. If the collector is unreachable, spans are dropped after filling the ring buffer. The flushed cursor advances even on POST failure to avoid stacking retries when the collector is down. Increase `uplink_otel` dict size to buffer more spans during outages.

### Shared dict sizing

`2m` holds approximately 1000 spans. Increase if `flush_interval` is long or traffic is high:

```nginx
lua_shared_dict uplink_otel 8m;  # ~4000 spans
```
