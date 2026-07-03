# Features

## Routing

Incoming requests are matched by service name prefix and forwarded to the upstream with the prefix stripped:

```
GET /users/v1/profile?foo=bar
  → strip /users
  → GET /v1/profile?foo=bar  to  http://users-svc:8080
```

nginx owns the actual proxying — keepalive pool, TLS, body streaming, retries all happen at C speed. Lua only runs policy checks in the access phase and metrics in the log phase.

## Schema aggregation

Each service's OpenAPI schema is fetched from `schema_url`, filtered by `rules`, and merged into `/openapi.json`:

- **Component namespacing** — all `$ref` names are prefixed with the service name to prevent collisions (`User` → `users__User`). Identical components are deduplicated; the first occurrence is canonical, subsequent ones alias to it.
- **Path prefixing** — all paths are prefixed with `/service-name` in the merged schema.
- **TTL priority** — `Cache-Control: s-maxage` > `Cache-Control: max-age` > `Expires` header > config `ttl`.
- **Background refresh** — each service has a timer firing at 90% of its TTL. On failure, the last good schema is served and a warning is logged.
- **Degraded mode** — if a service has no usable schema (cold miss + fetch failure), it is excluded from the merged doc and listed in `X-Uplink-Degraded`.

## Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /openapi.json` | Merged OpenAPI 3.x schema for all services |
| `GET /healthz` | Returns `{"status":"ok"}` |
| `GET /metrics` | Prometheus-format metrics |
| `* /{name}/...` | Proxy to the named service |

`X-Uplink-Degraded: svc1,svc2` is set on `/openapi.json` responses when one or more services have no usable schema.

Proxied requests carry: `traceparent` (W3C, propagated or generated), `X-Request-ID`, `X-Forwarded-For`, `X-Forwarded-Proto`.
