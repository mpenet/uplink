# Configuration

`config.json` at the project root. Override path with the `UPLINK_CONFIG` environment variable.

All configuration changes take effect on restart. See [`config.json.sample`](../config.json.sample) for a full annotated example.

## Top-level structure

```json
{
  "server": { ... },
  "otel":   { ... },
  "services": [ ... ]
}
```

`services` is required. `server` and `otel` are optional.

## Service fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | yes | — | Service identifier and route prefix. Only `[a-zA-Z0-9_-]` allowed |
| `upstream` | yes | — | Upstream URL, array of URLs, or array of server objects. See [Routing](routing.md) |
| `schema_url` | yes | — | URL of the service's OpenAPI 3.x JSON or YAML schema |
| `ttl` | no | `300` | Schema cache TTL in seconds. Upstream `Cache-Control`/`Expires` takes precedence |
| `timeout` | no | `30000` | Connect/send/read timeout in milliseconds |
| `rules` | no | allow all | Route filter rules. See [Routing](routing.md) |
| `balancing` | no | `"round_robin"` | Load balancing algorithm. See [Routing](routing.md) |
| `keepalive` | no | see below | Upstream keepalive pool. See [Traffic control](traffic.md) |
| `websocket` | no | `false` | Set `true` to proxy WebSocket upgrades. See [Routing](routing.md) |
| `host_header` | no | first upstream host | `Host` header sent upstream |
| `tls` | no | — | Upstream mTLS client credentials. See [TLS](tls.md) |
| `cors` | no | — | CORS configuration. See [Headers & CORS](headers.md) |
| `headers` | no | — | Request/response header injection and stripping. See [Headers & CORS](headers.md) |
| `rate_limit` | no | — | Per-service rate limiting. See [Traffic control](traffic.md) |
| `adaptive_concurrency` | no | — | Gradient-based adaptive concurrency limiting. See [Traffic control](traffic.md) |
| `auth` | no | — | JWT authentication. See [Authentication](auth.md) |
| `nginx_directives` | no | — | Extra nginx directives injected into the location block. See [Headers & CORS](headers.md) |

## Server TLS

Top-level `server.tls` configures inbound TLS. See [TLS](tls.md).

## OpenTelemetry

Top-level `otel` configures span export. See [Observability](observability.md).
