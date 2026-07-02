# Uplink

OpenResty + Fennel API gateway that aggregates multiple upstream OpenAPI 3.x services under a single endpoint. Each service is exposed under a `/name` prefix; a merged `/openapi.json` covers all of them.

Proxying runs entirely through native nginx `proxy_pass` — keepalive pools, TLS, body streaming, and retries happen at C speed with no Lua on the hot path. Lua runs only in the access phase (rate limiting, circuit breaker, traceparent injection) and the log phase (metrics, OTel spans).

## How it works

`config.json` describes your upstream services. At startup, Uplink generates nginx upstream and location blocks from it, then proxies requests under each service's `/name` prefix.

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

```sh
# Hot-reload rules, rate limits, circuit breaker thresholds — no restart needed
curl -X POST http://127.0.0.1:8080/reload
```

## Documentation

- [**Configuration**](doc/configuration.md) — service fields, rules, TLS, rate limiting, circuit breaker, load balancing, WebSocket, CORS, headers, nginx directives
- [**Features**](doc/features.md) — routing, schema aggregation, hot reload, endpoints
- [**Observability**](doc/observability.md) — Prometheus metrics, JSON access log, OpenTelemetry
- [**Deployment**](doc/deployment.md) — Docker, Docker Compose, Kubernetes, shared dict sizing
