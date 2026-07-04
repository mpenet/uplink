<img width="200" height="200" src="https://github.com/user-attachments/assets/b9419850-2195-4138-9938-ba2347daece3" />

<br>

OpenResty API gateway that aggregates multiple upstream OpenAPI 3.x services under a single endpoint. Each service is exposed under a `/<name>` prefix; a merged `/openapi.json` covers all of them.

Proxying runs through native nginx `proxy_pass` — keepalive pools, TLS, body streaming, and retries at C speed with no Lua on the hot path. Lua runs only in the access phase and log phase.

**Proxy** — multi-upstream load balancing · keepalive pools · WebSocket · server TLS/mTLS · upstream mTLS  
**Policy** — per-service JWT auth (HS*/RS*/ES*, JWKS) · rate limiting · adaptive concurrency limiting · CORS · header injection/stripping  
**Observability** — Prometheus metrics · JSON access log · OpenTelemetry OTLP/HTTP · W3C trace propagation

## Quick start

```sh
docker pull ghcr.io/mpenet/uplink:latest
docker run -p 8080:8080 -v ./config.json:/uplink/config.json ghcr.io/mpenet/uplink:latest
```

Minimal `config.json`:

```json
{
  "services": [
    {
      "name": "users",
      "upstream": "http://users-svc:8080",
      "schema_url": "http://users-svc:8080/openapi.json"
    },
    {
      "name": "orders",
      "upstream": "http://orders-svc:9090",
      "schema_url": "http://orders-svc:9090/openapi.json",
      "auth": {
        "jwt": {
          "jwks_url": "https://auth.example.com/.well-known/jwks.json",
          "algorithms": ["RS256"]
        }
      }
    }
  ]
}
```

`GET /users/v1/profile` → strips `/users` → proxied to `http://users-svc:8080/v1/profile`.  
`GET /openapi.json` → merged schema for all services.

See [`config.json.sample`](config.json.sample) for a full annotated example.

## Documentation

| Page | Description |
|------|-------------|
| [How it works](doc/how-it-works.md) | Request lifecycle, routing, schema aggregation, trace propagation |
| [Configuration](doc/configuration.md) | Config structure and service field reference |
| [Routing](doc/routing.md) | Rules, load balancing, WebSocket |
| [Authentication](doc/auth.md) | JWT — HMAC, PEM, JWKS |
| [TLS](doc/tls.md) | Server TLS/mTLS, upstream mTLS |
| [Traffic control](doc/traffic.md) | Rate limiting, adaptive concurrency, keepalive pools |
| [Headers & CORS](doc/headers.md) | Header injection/stripping, CORS |
| [Observability](doc/observability.md) | Prometheus metrics, JSON access log, OpenTelemetry |
| [Deployment](doc/deployment.md) | Docker, Kubernetes, shared dict sizing, troubleshooting |

## License

Copyright © 2026 Max Penet

Distributed under the [Mozilla Public License 2.0](LICENSE)
