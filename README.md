# Ladon

OpenResty + Fennel API gateway that aggregates multiple upstream OpenAPI 3.x services under a single endpoint. Each service is exposed under a `/name` prefix; a merged `/openapi.json` covers all of them.

Proxying runs entirely through native nginx `proxy_pass` — keepalive pools, TLS, body streaming, and retries happen at C speed with no Lua on the hot path. Lua runs only in the access phase (rate limiting, circuit breaker, traceparent injection) and the log phase (metrics, OTel spans).

## How it works

`fennel/generate.fnl` reads `config.json` at startup and emits nginx include files — one `upstream {}` block and one `location` block per service. nginx owns the actual proxying; Lua enforces policy and aggregates OpenAPI schemas.

- **Routing**: `GET /users/v1/profile` → strip `/users` → `GET /v1/profile` to the users upstream, over a keepalive pool
- **Schema aggregation**: each service's OpenAPI schema is fetched, filtered by rules, component names are namespaced (`User` → `users__User`), and paths are prefixed before merging into `/openapi.json`
- **Background refresh**: schemas are refreshed at 90% of their TTL; stale schemas are served on fetch failure

## Requirements

- [OpenResty](https://openresty.org/) ≥ 1.21
- [Fennel](https://fennel-lang.org/) (compile-time only)
- `dkjson` Lua rock (dev only — bundled in Docker via `luarocks`)

## Quick start

```sh
make run
```

Compiles Fennel → Lua, generates nginx include files from `config.json`, and starts OpenResty on `:8080`.

```sh
# Hot-reload rules, rate limits, circuit breaker thresholds
curl -X POST http://127.0.0.1:8080/reload

# After changing upstream/tls/timeout or adding/removing services:
make generate && make reload
```

## Documentation

- [**Configuration**](doc/configuration.md) — service fields, rules, TLS, rate limiting, circuit breaker, load balancing, WebSocket, CORS, headers, nginx directives
- [**Features**](doc/features.md) — routing, schema aggregation, hot reload, endpoints
- [**Observability**](doc/observability.md) — Prometheus metrics, JSON access log, OpenTelemetry
- [**Deployment**](doc/deployment.md) — Docker, Docker Compose, Kubernetes, shared dict sizing, Makefile targets

See [`config.json.sample`](config.json.sample) for a full annotated configuration example.
