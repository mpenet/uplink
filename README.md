# Ladon

OpenResty + Fennel reverse proxy that aggregates multiple upstream OpenAPI 3.x services under a single gateway. Each service is exposed under a `/name` prefix; a merged `/openapi.json` is served covering all configured services.

## How it works

1. On startup, `config.json` is loaded and each service's OpenAPI schema is fetched
2. Schemas are filtered by per-service rules (paths, methods, tags), `$ref` components are namespaced, and paths are prefixed with the service name
3. Incoming requests are matched to a service by prefix, the prefix is stripped, and the request is forwarded to the upstream
4. `/openapi.json` serves the merged schema of all services
5. Schemas refresh in the background before their TTL expires; stale schemas are served if a refresh fails

## Requirements

- [OpenResty](https://openresty.org/) ≥ 1.21
- [Fennel](https://fennel-lang.org/) (for compilation)

## Quick start

```sh
# Compile Fennel → Lua
make

# Start OpenResty with the project as prefix
make run

# Reload config without restart
curl -X POST http://127.0.0.1:8080/reload
```

The server listens on `:8080` by default.

## Configuration

`config.json` at the project root:

```json
{
  "services": [
    {
      "name": "users",
      "upstream": "http://users-svc:8080",
      "schema_url": "http://users-svc:8080/openapi.json",
      "ttl": 300,
      "rules": {
        "include_paths": ["*"],
        "include_tags": [],
        "include_methods": ["GET", "POST", "PUT", "DELETE", "PATCH"],
        "exclude_paths": ["/internal/*", "/debug/*"]
      }
    },
    {
      "name": "orders",
      "upstream": "http://orders-svc:9090",
      "schema_url": "http://orders-svc:9090/openapi.json",
      "ttl": 60,
      "rules": {
        "include_paths": ["/v2/*"],
        "include_tags": ["orders"],
        "include_methods": ["GET", "POST"],
        "exclude_paths": []
      }
    }
  ]
}
```

### Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | yes | — | Service identifier. Used as route prefix (`/name/...`) and component namespace |
| `upstream` | yes | — | Base URL requests are forwarded to |
| `schema_url` | yes | — | URL of the service's OpenAPI 3.x JSON schema |
| `ttl` | no | `300` | Schema cache TTL in seconds. Upstream `Cache-Control`/`Expires` headers take precedence when present |
| `rules` | no | allow all | Route filter rules (see below) |

### Rules

Rules are evaluated as: **include\_paths ∩ include\_methods ∩ include\_tags − exclude\_paths**. An operation must pass all active filters to be included.

| Rule | Default | Behaviour |
|------|---------|-----------|
| `include_paths` | `["*"]` | Glob whitelist. `*` = all paths. `/v1/*` = prefix match |
| `include_methods` | all | Method whitelist. Empty list = all methods |
| `include_tags` | `[]` | Tag whitelist. Empty list = tag filter disabled |
| `exclude_paths` | `[]` | Glob blacklist applied after includes |

Wildcards: `*` matches anything; `/foo/*` matches any path starting with `/foo/`.

## Proxy routing

```
GET /users/v1/profile
  → strip /users
  → GET /v1/profile → http://users-svc:8080
```

The prefix is the service `name`. Everything after it is forwarded verbatim, including query strings. `X-Request-ID` is propagated (or generated from nginx's built-in request ID if absent).

## Component namespacing

All `$ref` component names are prefixed with the service name before merge:

```
#/components/schemas/User  →  #/components/schemas/users__User
```

This prevents name collisions across services. Structurally identical components are deduplicated: the first occurrence is canonical and subsequent occurrences alias to it.

## Schema TTL and caching

- TTL is sourced from (in priority order): `Cache-Control: s-maxage`, `Cache-Control: max-age`, `Expires` header, config `ttl` field
- Background timers refresh each service schema at 90% of its TTL to avoid ever serving stale data on hot paths
- If a refresh fails, the last known good schema is served and a warning is logged
- The merged `/openapi.json` is cached per worker and only rebuilt when a service schema changes

## Hot reload

```sh
curl -X POST http://127.0.0.1:8080/reload
# {"ok":true,"version":2}
```

Re-reads `config.json`, validates it, and bumps the config version. Workers pick up the new config lazily on their next request. Background refresh timers continue using the original service config until restart.

The `/reload` endpoint is restricted to loopback (`127.0.0.1` / `::1`).

## Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /openapi.json` | Merged OpenAPI 3.x schema for all configured services |
| `GET /healthz` | Health check — returns `{"status":"ok"}` |
| `GET /metrics` | Prometheus-format counters (see below) |
| `POST /reload` | Hot-reload `config.json` (loopback only) |
| `* /{name}/...` | Proxy to the named service |

### Response headers

- `X-Ladon-Degraded: users,orders` — present on `/openapi.json` when one or more services had no usable schema (cold miss + fetch failure). Services served from stale cache do not appear here.

## Metrics

Scraped at `GET /metrics` in Prometheus text format:

| Metric | Labels | Description |
|--------|--------|-------------|
| `schema_fetch_total` | `service`, `status` | Schema fetch attempts. `status`: `ok`, `error`, `background_ok`, `background_error` |
| `schema_cache_result_total` | `service`, `result` | Aggregation cache outcomes: `ok`, `error` |
| `proxy_requests_total` | `service` | Proxied requests per service |
| `proxy_errors_total` | `service`, `code` | Proxy errors by HTTP status code |

## Project layout

```
config.json          — service definitions
Makefile             — compile, run, reload, stop
conf/
  nginx.conf         — OpenResty entry point
fennel/
  config.fnl         — load and validate config.json; shared-dict persistence for hot-reload
  rules.fnl          — path/method/tag filter predicates
  schema.fnl         — fetch schemas, resolve $refs, prefix and hash components
  aggregator.fnl     — merge schemas, dedup components, serve /openapi.json
  proxy.fnl          — route matching, upstream proxying, request-ID propagation
  cache.fnl          — TTL cache with per-worker value cache, semaphore, stale fallback
  refresh.fnl        — background refresh timers, startup pre-warming
  metrics.fnl        — Prometheus counters
lib/                 — compiled Lua (output of make)
logs/                — nginx logs
```

## Makefile targets

```sh
make          # compile all fennel → lib/*.lua
make run      # compile + start OpenResty
make reload   # send nginx reload signal
make stop     # stop OpenResty
make check    # syntax-check all .fnl files without compiling
make clean    # remove lib/*.lua and logs
```
