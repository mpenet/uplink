<img width="200" height="200" src="https://github.com/user-attachments/assets/b9419850-2195-4138-9938-ba2347daece3" />

<br>

OpenResty based API gateway that aggregates multiple upstream OpenAPI 3.x services under a single endpoint. Each service is exposed under a `/<name>` prefix; a merged `/openapi.json` covers all of them.

Proxying runs entirely through native nginx `proxy_pass` — keepalive pools, TLS, body streaming, and retries happen at C speed with no Lua on the hot path. Lua runs only in the access phase (JWT auth, rate limiting, adaptive concurrency, traceparent injection) and the log phase (metrics, OTel spans).

**Features:** multi-upstream load balancing · per-service rate limiting · adaptive concurrency limiting · JWT authentication (HS*/RS*/ES*, JWKS) · W3C trace propagation · OpenTelemetry OTLP/HTTP · Prometheus metrics · JSON access log · server TLS/mTLS · WebSocket · CORS · header injection/stripping

## How it works

`config.json` describes your upstream services. At startup, Uplink generates nginx upstream and location blocks from it, then proxies requests under each service's `/<name>` prefix.

- **Routing**: `GET /users/v1/profile` → strip `/users` → `GET /v1/profile` to the users upstream, over a keepalive pool
- **Schema aggregation**: each service's OpenAPI schema is fetched, filtered by rules, component names are namespaced (`User` → `users__User`), and paths are prefixed before merging into `/openapi.json`
- **Background refresh**: schemas are refreshed at 90% of their TTL; stale schemas are served on fetch failure

## Quick start

Pull the prebuilt image from the GitHub Container Registry:

```sh
docker pull ghcr.io/mpenet/uplink:latest
docker run -p 8080:8080 -v ./config.json:/uplink/config.json ghcr.io/mpenet/uplink:latest
```

Or build from source:

```sh
docker build -t uplink .
docker run -p 8080:8080 -v ./config.json:/uplink/config.json uplink
```

Copy [`config.json.sample`](config.json.sample) to `config.json`, point it at your upstreams, and you're done.

## Documentation

See the **[documentation index](doc/index.md)** for all pages.

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

