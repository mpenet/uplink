# Features

## Request lifecycle

For each proxied request:

1. **access phase (Lua)** — service matched by `/$name` prefix, prefix stripped, `traceparent` propagated or generated, rate limit checked (429 if exceeded), circuit breaker checked (503 if open), request headers injected/stripped
2. **proxy phase (nginx)** — `proxy_pass` to upstream over keepalive pool; TLS, body streaming, retries at C speed; no Lua on the hot path
3. **header filter phase (Lua)** — circuit breaker state updated from response status, response headers injected/stripped
4. **log phase (Lua)** — request counted, latency recorded, OTel span written (if enabled)

## Routing

Incoming requests are matched by service name prefix and forwarded with the prefix stripped:

```
GET /users/v1/profile?foo=bar
  → strip /users
  → GET /v1/profile?foo=bar  to  http://users-svc:8080
```

Longer service names take priority over shorter ones (`/users-v2` wins over `/users`). Unmatched requests return `404 {"error":"no service matched"}`.

nginx owns the proxying — keepalive pool, TLS, body streaming, retries happen at C speed. Lua only runs policy checks in the access phase and metrics in the log phase.

## Schema aggregation

Each service's OpenAPI schema is fetched from `schema_url` (HTTP or HTTPS, JSON or YAML), filtered by `rules`, and merged into `/openapi.json`:

- **Component namespacing** — all `$ref` names are prefixed with the service name to prevent collisions (`User` → `users__User`). Identical components are deduplicated; the first occurrence is canonical, subsequent ones alias to it.
- **Path prefixing** — all paths are prefixed with `/service-name` in the merged schema.
- **TTL priority** — `Cache-Control: s-maxage` > `Cache-Control: max-age` > `Expires` header > config `ttl`.
- **Background refresh** — each service has a timer firing at 90% of its TTL. On failure the last good schema is served and a warning is logged.
- **Degraded mode** — if a service has no usable schema (cold miss + fetch failure), it is excluded from the merged doc and listed in `X-Uplink-Degraded`.

## Rate limiting

Leaky bucket per service. When a request exceeds the configured rate, Uplink returns `429 {"error":"rate limit exceeded"}` immediately — the upstream is never contacted. Limit is enforced per worker process; effective cluster-wide limit in multi-replica deployments is `requests_per_second × replicas`.

## Circuit breaker

Three states per service, shared across all workers in a pod:

- **CLOSED** — normal proxying. Failure counter increments on each 5xx response.
- **OPEN** — triggered after `threshold` consecutive failures. All requests get `503 {"error":"service unavailable (circuit open)"}` for `open_ttl` seconds. The upstream is never contacted.
- **HALF-OPEN** — after `open_ttl` expires, exactly one probe request is admitted (atomic shared dict lock). If it succeeds the circuit closes; if it fails the timer resets.

## Trace propagation

Every proxied request carries a W3C `traceparent` header upstream:

- If the incoming request has a valid `traceparent`, the trace ID is preserved and the span ID is set to the first 16 hex chars of nginx's `$request_id`.
- If there is no incoming `traceparent`, a new trace is started using `$request_id` as both trace ID and span ID.

The `traceparent` is also set as a nginx variable so it appears in the access log and in OTel spans.

## Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /openapi.json` | Merged OpenAPI 3.x schema for all services |
| `GET /healthz` | Returns `{"status":"ok"}` |
| `GET /metrics` | Prometheus-format metrics |
| `* /{name}/...` | Proxy to the named service |

`X-Uplink-Degraded: svc1,svc2` is set on `/openapi.json` responses when one or more services have no usable schema.

Proxied requests carry: `traceparent` (W3C, propagated or generated), `X-Request-ID`, `X-Forwarded-For`, `X-Forwarded-Proto`.
