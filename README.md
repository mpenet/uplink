# Ladon

OpenResty + Fennel API gateway that aggregates multiple upstream OpenAPI 3.x services under a single endpoint. Each service is exposed under a `/name` prefix; a merged `/openapi.json` covers all of them.

Proxying runs entirely through native nginx `proxy_pass` — keepalive pools, TLS, body streaming, and retries happen at C speed with no Lua on the hot path. Lua runs only in the access phase (rate limiting, circuit breaker, traceparent injection) and the log phase (metrics).

## How it works

`fennel/generate.fnl` reads `config.json` at startup and emits two nginx include files — one `upstream {}` block and one `location` block per service. nginx owns the actual proxying; Lua enforces policy (rate limits, circuit breaker) and aggregates OpenAPI schemas.

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

This compiles Fennel → Lua, generates `nginx/upstreams.conf` + `nginx/locations.conf` from `config.json`, and starts OpenResty on `:8080`.

```sh
# Reload application config (rules, rate limits, circuit breaker) without restarting nginx
curl -X POST http://127.0.0.1:8080/reload

# After changing upstream/tls/timeout or adding/removing services:
make generate && make reload
```

## Configuration

`config.json` at the project root (override path with `LADON_CONFIG` env var):

```json
{
  "services": [
    {
      "name": "users",
      "upstream": "http://users-svc:8080",
      "schema_url": "http://users-svc:8080/openapi.json",
      "ttl": 300,
      "timeout": 10000,
      "rules": {
        "include_paths": ["*"],
        "include_tags": [],
        "include_methods": ["GET", "POST", "PUT", "DELETE", "PATCH"],
        "exclude_paths": ["/internal/*", "/debug/*"]
      },
      "rate_limit": {
        "requests_per_second": 500,
        "burst": 100
      },
      "circuit_breaker": {
        "threshold": 5,
        "open_ttl": 30
      }
    },
    {
      "name": "orders",
      "upstream": "https://orders-svc:9090",
      "schema_url": "https://orders-svc:9090/openapi.json",
      "ttl": 60,
      "rules": {
        "include_paths": ["/v2/*"],
        "include_tags": ["orders"],
        "include_methods": ["GET", "POST"],
        "exclude_paths": []
      },
      "tls": {
        "cert": "/certs/orders-client.crt",
        "key": "/certs/orders-client.key",
        "verify": true
      }
    }
  ]
}
```

### Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | yes | — | Service identifier and route prefix. Only `[a-zA-Z0-9_-]` allowed |
| `upstream` | yes | — | Upstream URL or array of URLs. Arrays enable nginx round-robin load balancing |
| `schema_url` | yes | — | URL of the service's OpenAPI 3.x JSON or YAML schema |
| `ttl` | no | `300` | Schema cache TTL in seconds. Upstream `Cache-Control`/`Expires` takes precedence |
| `timeout` | no | `30000` | Connect/send/read timeout in milliseconds |
| `rules` | no | allow all | Route filter rules (see below) |
| `tls` | no | — | mTLS client credentials (see below) |
| `rate_limit` | no | — | Per-service rate limiting (see below) |
| `circuit_breaker` | no | — | Per-service circuit breaker (see below) |
| `nginx_directives` | no | — | Extra nginx directives in the generated location block (see below) |
| `host_header` | no | first upstream host | Host header value sent to upstreams (useful with multiple upstreams) |
| `keepalive` | no | see below | Upstream keepalive pool settings |
| `balancing` | no | `"round_robin"` | Load balancing algorithm: `"round_robin"`, `"least_conn"`, `"ip_hash"`, `"random"` |
| `websocket` | no | — | Set `true` to proxy WebSocket upgrades |
| `cors` | no | — | CORS configuration (see below) |
| `headers` | no | — | Request/response header injection and stripping (see below) |

### Rules

Applied as **include\_paths ∩ include\_methods ∩ include\_tags − exclude\_paths**. An operation must pass all active filters to appear in the merged schema and be routable.

| Rule | Default | Behaviour |
|------|---------|-----------|
| `include_paths` | `["*"]` | Path whitelist. `*` = all, `/v1/*` = prefix match |
| `include_methods` | all | Method whitelist. Empty = all methods |
| `include_tags` | `[]` | Tag whitelist. Empty = tag filter disabled |
| `exclude_paths` | `[]` | Blacklist applied after includes |

### Server TLS and mTLS

Configure inbound TLS (and optionally client-certificate verification) with a top-level `server.tls` block:

```json
{
  "server": {
    "tls": {
      "cert": "/certs/server.crt",
      "key":  "/certs/server.key",
      "client_ca":     "/certs/ca.crt",
      "verify_client": "on"
    }
  },
  "services": [...]
}
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `cert` | yes | — | Server certificate path |
| `key` | yes | — | Server private key path |
| `client_ca` | no | — | CA certificate for verifying client certs. Setting this enables mTLS |
| `verify_client` | no | `"on"` when `client_ca` set | nginx `ssl_verify_client` value: `"on"`, `"optional"`, `"off"` |
| `port` | no | `8443` | HTTPS listen port. Plain HTTP on `8080` is always active |

`make generate && make reload` is required after any change. TLS uses TLS 1.2/1.3 with a modern cipher suite. Paths must be absolute and accessible inside the container.

### mTLS upstream

When `tls.cert` and `tls.key` are set on a service, Ladon presents the client certificate for both proxied requests and schema fetches:

```json
"tls": {
  "cert": "/certs/client.crt",
  "key":  "/certs/client.key",
  "verify": true
}
```

`verify` controls upstream server certificate verification (default `false`). Paths must be absolute and accessible inside the container.

### Rate limiting

Leaky bucket via `resty.limit.req`. Requests within `burst` are admitted immediately; excess requests return `429`.

```json
"rate_limit": {
  "requests_per_second": 100,
  "burst": 50
}
```

Takes effect immediately after `/reload`.

### Circuit breaker

After `threshold` consecutive 5xx responses the circuit opens; all requests get `503` for `open_ttl` seconds. After the TTL, one probe is let through — success closes the circuit.

```json
"circuit_breaker": {
  "threshold": 5,
  "open_ttl": 30
}
```

State is shared across all workers. Thresholds take effect immediately after `/reload`.

### Keepalive pool

Controls the nginx upstream keepalive pool per service. All three fields are optional.

```json
"keepalive": {
  "pool_size": 32,
  "requests":  1000,
  "timeout":   "60s"
}
```

| Field | Default | nginx directive |
|-------|---------|-----------------|
| `pool_size` | `32` | `keepalive N` — max idle connections held open per worker |
| `requests` | `1000` | `keepalive_requests N` — max requests per connection before it is closed |
| `timeout` | `"60s"` | `keepalive_timeout T` — how long an idle connection is kept alive |

Changes require `make generate && make reload`.

### Multiple upstreams and load balancing

Pass an array to `upstream` for load balancing across multiple servers:

```json
"upstream": ["http://users-1:8080", "http://users-2:8080", "http://users-3:8080"]
```

Server entries may also be objects to control per-server parameters:

```json
"upstream": [
  {"url": "http://users-1:8080", "weight": 3},
  {"url": "http://users-2:8080", "weight": 1, "max_fails": 3, "fail_timeout": "30s"}
]
```

| Field | Description |
|-------|-------------|
| `url` | Upstream server URL |
| `weight` | Relative request weight (default: 1) |
| `max_fails` | Consecutive failures before server is marked down (nginx passive health) |
| `fail_timeout` | Duration server is skipped after `max_fails` (e.g. `"30s"`) |

String entries and object entries may be mixed in the same array.

Set `balancing` to select the load-balancing algorithm:

```json
"balancing": "least_conn"
```

| Value | Algorithm |
|-------|-----------|
| `"round_robin"` | Default. Distribute requests in turn |
| `"least_conn"` | Route to the server with the fewest active connections |
| `"ip_hash"` | Consistent hashing by client IP — sticky sessions |
| `"random"` | Random server selection |

All servers share one keepalive pool. The `Host` header is set to the first upstream's host by default; override with `host_header` if your servers have different hostnames.

Changes require `make generate && make reload`.

### WebSocket

Set `websocket: true` to proxy WebSocket connections:

```json
{
  "name": "chat",
  "upstream": "http://chat-svc:8080",
  "websocket": true
}
```

This emits `Upgrade` and `Connection: upgrade` headers and extends `proxy_read_timeout` to 3600s to keep long-lived connections alive. The full set of forwarding headers (`Host`, `traceparent`, `X-Request-ID`, `X-Forwarded-For`, `X-Forwarded-Proto`) is re-emitted in the location block because nginx does not inherit server-block `proxy_set_header` directives once a location adds any of its own.

Changes require `make generate && make reload`.

### CORS

Per-service CORS configuration emitted as nginx `add_header` directives:

```json
"cors": {
  "origins": ["https://app.example.com", "https://admin.example.com"],
  "methods": ["GET", "POST", "PUT", "DELETE"],
  "headers": ["Authorization", "Content-Type"],
  "max_age": 3600,
  "credentials": false
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `origins` | `["*"]` | Allowed origins. `["*"]` emits a literal wildcard. Single origin emits it literally. Multiple specific origins use a nginx `map {}` block for dynamic matching |
| `methods` | `["GET","POST","OPTIONS"]` | `Access-Control-Allow-Methods` value |
| `headers` | `["Authorization","Content-Type"]` | `Access-Control-Allow-Headers` value |
| `max_age` | `3600` | `Access-Control-Max-Age` in seconds |
| `credentials` | `false` | Emit `Access-Control-Allow-Credentials: true` (incompatible with `origins: ["*"]`) |

OPTIONS preflight requests are short-circuited with a `204` response inside the location block. Changes require `make generate && make reload`.

### Header injection and stripping

Set or remove headers on requests forwarded upstream and on responses returned to clients. Takes effect immediately after `/reload`.

```json
"headers": {
  "request": {
    "set":   {"X-Tenant": "acme", "X-Service-Version": "2"},
    "strip": ["X-Internal-Token", "X-Debug"]
  },
  "response": {
    "set":   {"X-Gateway": "ladon"},
    "strip": ["X-Powered-By", "Server"]
  }
}
```

`request.set` / `request.strip` run in the access phase before the request is forwarded. `response.set` / `response.strip` run in the header filter phase before the response is returned to the client.

### Extra nginx directives

Inject arbitrary directives into a service's location block:

```json
"nginx_directives": [
  "proxy_buffer_size 16k",
  "proxy_buffers 4 16k",
  "add_header X-Service users always"
]
```

Strings are emitted verbatim after the timeout directives and before the Lua phase blocks. Use an array (not a map) so repeatable directives like `add_header` work correctly. Syntax errors are caught by `nginx -t` at startup. Requires `make generate && make reload`.

## Schema aggregation

Each service's OpenAPI schema is fetched from `schema_url`, filtered by `rules`, and merged:

- **Component namespacing**: all `$ref` names are prefixed with the service name to prevent collisions (`User` → `users__User`). Identical components are deduplicated — the first occurrence is canonical, subsequent ones alias to it.
- **Path prefixing**: all paths are prefixed with `/service-name` in the merged schema.
- **TTL priority**: `Cache-Control: s-maxage` > `Cache-Control: max-age` > `Expires` header > config `ttl`.
- **Background refresh**: each service has a timer firing at 90% of its TTL. On failure, the last good schema is served and a warning is logged.
- **Degraded mode**: if a service has no usable schema at all (cold miss + fetch failure), it is excluded from the merged doc and listed in `X-Ladon-Degraded`.

## Hot reload

```sh
curl -X POST http://127.0.0.1:8080/reload
# {"ok":true,"version":2}
```

Re-reads and validates `config.json`, bumps the config version. Workers pick up changes lazily on their next request.

**Takes effect immediately** (no nginx restart):
- Schema filter rules
- Rate limit parameters
- Circuit breaker parameters
- Schema TTL
- Header injection/stripping (`headers.request.*`, `headers.response.*`)

**Requires `make generate && make reload`**:
- `upstream`, `balancing`, `tls`, `timeout`, `host_header`, `keepalive`, `websocket` changes
- `server.tls` changes
- Adding or removing services
- `nginx_directives` changes
- `cors` changes

The `/reload` endpoint is restricted to loopback (`127.0.0.1` / `::1`).

## Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /openapi.json` | Merged OpenAPI 3.x schema for all services |
| `GET /healthz` | Returns `{"status":"ok"}` |
| `GET /metrics` | Prometheus-format metrics |
| `POST /reload` | Hot-reload `config.json` (loopback only) |
| `* /{name}/...` | Proxy to the named service |

`X-Ladon-Degraded: svc1,svc2` is set on `/openapi.json` responses when one or more services have no usable schema.

Proxied requests carry: `traceparent` (W3C, propagated or generated), `X-Request-ID`, `X-Forwarded-For`, `X-Forwarded-Proto`.

## OpenTelemetry

Ladon exports spans via OTLP/HTTP+JSON. Disabled at zero cost by default — no overhead unless both prerequisites are present.

### Enabling

**1. Add the shared dict to `nginx/nginx.conf`:**

```nginx
lua_shared_dict ladon_otel 2m;
```

**2. Add `otel` to `config.json`:**

```json
"otel": {
  "endpoint":     "http://otel-collector:4318/v1/traces",
  "service_name": "ladon",
  "batch_size":   100,
  "flush_interval": 5
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `endpoint` | — | OTLP/HTTP collector URL (required) |
| `service_name` | `"ladon"` | `service.name` resource attribute |
| `batch_size` | `100` | Max spans per HTTP POST |
| `flush_interval` | `5` | Flush timer interval in seconds |

### How it works

Each proxied request produces one span in the log phase. Spans are written to `ladon_otel` shared dict (ring buffer, 1000 slots). A per-worker timer fires every `flush_interval` seconds and POSTs pending spans as OTLP/HTTP+JSON.

- **traceId** — taken from the incoming W3C `traceparent` if valid, otherwise `$request_id`
- **spanId** — first 16 chars of `$request_id` (same value forwarded upstream in traceparent)
- **parentSpanId** — parent span from incoming `traceparent`, absent if no upstream trace context

Trace continuity relies on upstream services propagating `traceparent`. Ladon always injects or generates one in the access phase.

Span export is best-effort: if the collector is down, spans are dropped after `batch_size` slots fill the buffer. `ladon_otel` size controls buffer capacity (default `2m` holds ~1000 spans).

## Access log

Every request is logged to `logs/access.log` as a JSON line:

```json
{"time":"2026-07-02T10:00:00+00:00","service":"users","method":"GET","path":"/users/v1/profile","query":"","status":200,"upstream_time":"0.042","bytes":312,"traceparent":"00-abc...","request_id":"abcdef01...","remote_addr":"10.0.0.1","upstream_addr":"10.0.0.2:8080"}
```

| Field | Description |
|-------|-------------|
| `service` | Service name from `$svc_name` (`""` for `/healthz`, `/openapi.json`, etc.) |
| `upstream_time` | `proxy_upstream_response_time` in seconds (`""` for non-proxied locations) |
| `traceparent` | W3C traceparent, propagated or generated in the access phase |
| `request_id` | nginx `$request_id` — 32 hex characters, unique per request |
| `upstream_addr` | Actual upstream server used (`""` for non-proxied locations) |

Override the log path by mounting a custom `nginx/nginx.conf`.

## Metrics

`GET /metrics` — Prometheus text format:

| Metric | Labels | Description |
|--------|--------|-------------|
| `proxy_requests_total` | `service` | Proxied requests |
| `proxy_errors_total` | `service`, `code` | 5xx responses by status code |
| `proxy_request_duration_seconds` | `service`, `le` | Upstream response time histogram |
| `circuit_open_total` | `service` | Requests rejected due to open circuit |
| `schema_fetch_total` | `service`, `status` | Schema fetches (`ok`, `error`, `background_ok`, `background_error`) |
| `schema_cache_result_total` | `service`, `result` | Aggregation cache outcomes (`ok`, `error`) |

## Deployment

### Docker

```sh
docker build -t ladon .
docker run -p 8080:8080 -v ./config.json:/ladon/config.json ladon
```

The entrypoint runs `generate.lua`, validates with `nginx -t`, then starts OpenResty. Override the config path with `LADON_CONFIG`:

```sh
docker run -p 8080:8080 \
  -e LADON_CONFIG=/etc/ladon/config.json \
  -v ./config.json:/etc/ladon/config.json \
  ladon
```

Mount certs for mTLS:

```sh
docker run -p 8080:8080 \
  -v ./config.json:/ladon/config.json \
  -v ./certs:/certs:ro \
  ladon
```

Hot-reload inside a running container:

```sh
docker exec <container> curl -s -X POST http://127.0.0.1:8080/reload
```

### Docker Compose

```yaml
services:
  ladon:
    build: .
    ports:
      - "8080:8080"
    volumes:
      - ./config.json:/ladon/config.json
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://127.0.0.1:8080/healthz"]
      interval: 10s
      timeout: 3s
      retries: 3
```

### Kubernetes

```sh
kubectl create configmap ladon-config --from-file=config.json
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ladon
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ladon
  template:
    metadata:
      labels:
        app: ladon
    spec:
      containers:
        - name: ladon
          image: ladon:latest
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: config
              mountPath: /ladon/config.json
              subPath: config.json
          livenessProbe:
            httpGet: { path: /healthz, port: 8080 }
            initialDelaySeconds: 5
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
      volumes:
        - name: config
          configMap:
            name: ladon-config
---
apiVersion: v1
kind: Service
metadata:
  name: ladon
spec:
  selector:
    app: ladon
  ports:
    - port: 80
      targetPort: 8080
```

To update rules/rate limits/circuit breaker without restarting: update the ConfigMap, then exec `/reload` into each pod. For upstream/TLS changes, roll the deployment.

### Shared dict sizing

| Dict | Default | Holds |
|------|---------|-------|
| `ladon_cache` | 10m | Schema JSON per service — increase for large or many schemas |
| `ladon_metrics` | 2m | Prometheus counters and histogram buckets |
| `ladon_config` | 1m | Active config + version counter |
| `ladon_circuit` | 1m | Circuit breaker state per service |
| `ladon_ratelimit` | 1m | Rate limiter state per service |

Override by mounting a custom `nginx/nginx.conf`.

## Makefile targets

```sh
make            # compile fennel/ → lib/*.lua and generate.lua
make generate   # run generate.lua → nginx/upstreams.conf + nginx/locations.conf
make run        # compile + generate + start OpenResty
make reload     # send nginx reload signal
make stop       # stop OpenResty
make check      # syntax-check all .fnl files
make test       # compile + run busted test suite
make clean      # remove compiled files, generated nginx conf, logs
```
