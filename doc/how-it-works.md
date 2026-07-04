# How it works

## Routing

Incoming requests are matched by service name prefix. The prefix is stripped before forwarding:

```
GET /users/v1/profile?foo=bar
  → strip /users
  → GET /v1/profile?foo=bar  to  http://users-svc:8080
```

Longer service names take priority over shorter ones (`/users-v2` wins over `/users`). Requests that match no service return `404 {"error":"no service matched"}`.

nginx owns the proxying — keepalive pool, TLS, body streaming, and retries happen at C speed. Lua only runs policy checks in the access phase and metrics in the log phase.

## Schema aggregation

Each service's OpenAPI schema is fetched from `schema_url` (HTTP or HTTPS, JSON or YAML), filtered by its rules, and merged into `/openapi.json`:

- **Component namespacing** — all component names are prefixed with the service name to prevent collisions (`User` → `users__User`). Identical components across services are deduplicated; the first occurrence is canonical, subsequent ones become `$ref` aliases.
- **Path prefixing** — all paths are prefixed with `/service-name` in the merged schema.
- **TTL priority** — `Cache-Control: s-maxage` > `Cache-Control: max-age` > `Expires` header > config `ttl`.
- **Background refresh** — each service has a timer firing at 90% of its TTL. On failure the last good schema is served and a warning is logged.
- **Degraded mode** — if a service has no usable schema (cold miss and fetch failure), it is excluded from the merged doc and listed in the `X-Uplink-Degraded` response header.
- **Merged schema cache** — the encoded JSON body is cached in the shared dict after the first build. Subsequent workers reuse it without rebuilding until the schema generation counter changes.

## Trace propagation

Every proxied request carries a W3C `traceparent` header upstream:

- If the incoming request has a valid `traceparent`, the trace ID is preserved and the span ID is set to the first 16 hex chars of nginx's `$request_id`.
- If there is no incoming `traceparent`, a new trace is started using `$request_id` as both trace ID and span ID.

The `traceparent` is set as an nginx variable so it appears in the access log and in OTel spans.

## Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /openapi.json` | Merged OpenAPI 3.x schema for all services. Supports `ETag` / `304 Not Modified` |
| `GET /healthz` | Returns `{"status":"ok"}` |
| `GET /metrics` | Prometheus-format metrics |
| `* /{name}/...` | Proxy to the named service |

`X-Uplink-Degraded: svc1,svc2` is set on `/openapi.json` responses when one or more services have no usable schema.

Proxied requests carry: `traceparent` (W3C, propagated or generated), `X-Request-ID`, `X-Forwarded-For`, `X-Forwarded-Proto`.
