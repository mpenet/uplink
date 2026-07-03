# Configuration

`config.json` at the project root. Override path with `UPLINK_CONFIG` env var.

See [`config.json.sample`](../config.json.sample) for a full annotated example.

## Top-level structure

```json
{
  "server": { ... },
  "services": [ ... ]
}
```

`server` is optional. `services` is required.

## Service fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | yes | — | Service identifier and route prefix. Only `[a-zA-Z0-9_-]` allowed |
| `upstream` | yes | — | Upstream URL, array of URLs, or array of server objects |
| `schema_url` | yes | — | URL of the service's OpenAPI 3.x JSON or YAML schema |
| `ttl` | no | `300` | Schema cache TTL in seconds. Upstream `Cache-Control`/`Expires` takes precedence |
| `timeout` | no | `30000` | Connect/send/read timeout in milliseconds |
| `rules` | no | allow all | Route filter rules |
| `tls` | no | — | Upstream mTLS client credentials |
| `rate_limit` | no | — | Per-service rate limiting |
| `circuit_breaker` | no | — | Per-service circuit breaker |
| `nginx_directives` | no | — | Extra nginx directives injected into the location block |
| `host_header` | no | first upstream host | Host header sent upstream |
| `keepalive` | no | see below | Upstream keepalive pool settings |
| `balancing` | no | `"round_robin"` | Load balancing algorithm |
| `websocket` | no | — | Set `true` to proxy WebSocket upgrades |
| `cors` | no | — | CORS configuration |
| `headers` | no | — | Request/response header injection and stripping |

## Rules

Controls which operations appear in the merged schema. All fields are optional — omitting `rules` entirely allows everything.

| Field | Default | Description |
|-------|---------|-------------|
| `paths` | all | Path filter patterns |
| `methods` | all | Method filter patterns |
| `tags` | all | Tag filter patterns |

Each field is an array of patterns. Empty or absent means **allow all**. Patterns support `*` as a suffix wildcard (`/v1/*`). Prefix a pattern with `!` to exclude matches — exclusions always win over inclusions.

```json
"rules": {}
```
Allow everything (same as omitting `rules`).

```json
"rules": {
  "methods": ["GET", "POST"]
}
```
Only GET and POST operations.

```json
"rules": {
  "paths": ["!/internal/*"],
  "methods": ["!DELETE"]
}
```
All paths except `/internal/*`, all methods except DELETE.

```json
"rules": {
  "paths": ["/v1/*", "!/v1/admin/*"],
  "tags": ["public"]
}
```
Only `/v1/*` paths (excluding `/v1/admin/*`) that carry the `public` tag.

## Multiple upstreams and load balancing

```json
"upstream": ["http://users-1:8080", "http://users-2:8080"]
```

Server entries may be objects for per-server params:

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
| `max_fails` | Consecutive failures before server is marked down |
| `fail_timeout` | Duration server is skipped after `max_fails` (e.g. `"30s"`) |

String and object entries may be mixed. `balancing` selects the algorithm:

| Value | Algorithm |
|-------|-----------|
| `"round_robin"` | Default. Distribute requests in turn |
| `"least_conn"` | Server with fewest active connections |
| `"ip_hash"` | Consistent hashing by client IP — sticky sessions |
| `"random"` | Random selection |

Requires restart.

## WebSocket

```json
"websocket": true
```

Emits `Upgrade` and `Connection: upgrade` headers and extends `proxy_read_timeout` to 3600s. The full forwarding header set is re-emitted in the location block (nginx does not inherit server-block `proxy_set_header` once a location adds any of its own).

Requires restart.

## Upstream mTLS

Uplink presents a client certificate to the upstream for both proxied requests and schema fetches:

```json
"tls": {
  "cert": "/certs/client.crt",
  "key":  "/certs/client.key",
  "verify": true
}
```

`verify` controls upstream server certificate verification (default `false`). Paths must be absolute and accessible inside the container.

## Server TLS and inbound mTLS

Configure inbound TLS with a top-level `server.tls` block:

```json
{
  "server": {
    "tls": {
      "cert": "/certs/server.crt",
      "key":  "/certs/server.key",
      "client_ca":     "/certs/ca.crt",
      "verify_client": "on",
      "port": 8443
    }
  }
}
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `cert` | yes | — | Server certificate path |
| `key` | yes | — | Server private key path |
| `client_ca` | no | — | CA cert for verifying client certs. Enables mTLS |
| `verify_client` | no | `"on"` when `client_ca` set | nginx `ssl_verify_client`: `"on"`, `"optional"`, `"off"` |
| `port` | no | `8443` | HTTPS listen port. Plain HTTP on `8080` is always active |

TLS 1.2/1.3 only, modern cipher suite. Requires restart.

## Rate limiting

Leaky bucket via `resty.limit.req`. Requests within `burst` are admitted immediately; excess return `429`.

```json
"rate_limit": {
  "requests_per_second": 100,
  "burst": 50
}
```

Takes effect after restart.

## Circuit breaker

After `threshold` consecutive 5xx responses the circuit opens; requests get `503` for `open_ttl` seconds. After the TTL, one probe request is admitted — success closes the circuit (half-open state). A failed probe resets the TTL.

```json
"circuit_breaker": {
  "threshold": 5,
  "open_ttl": 30
}
```

State is shared across all workers. Takes effect after restart.

## Keepalive pool

```json
"keepalive": {
  "pool_size": 32,
  "requests":  1000,
  "timeout":   "60s"
}
```

| Field | Default | nginx directive |
|-------|---------|-----------------|
| `pool_size` | `32` | `keepalive N` — max idle connections per worker |
| `requests` | `1000` | `keepalive_requests N` — max requests per connection |
| `timeout` | `"60s"` | `keepalive_timeout T` — idle connection lifetime |

Requires restart.

## CORS

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
| `origins` | `["*"]` | Allowed origins. `["*"]` = wildcard. Single origin = literal. Multiple = nginx `map {}` for dynamic matching |
| `methods` | `["GET","POST","OPTIONS"]` | `Access-Control-Allow-Methods` |
| `headers` | `["Authorization","Content-Type"]` | `Access-Control-Allow-Headers` |
| `max_age` | `3600` | `Access-Control-Max-Age` in seconds |
| `credentials` | `false` | Emit `Access-Control-Allow-Credentials: true` (incompatible with `origins: ["*"]`) |

OPTIONS preflight is short-circuited with `204`. Requires restart.

## Header injection and stripping

```json
"headers": {
  "request": {
    "set":   {"X-Tenant": "acme"},
    "strip": ["X-Internal-Token"]
  },
  "response": {
    "set":   {"X-Gateway": "uplink"},
    "strip": ["X-Powered-By", "Server"]
  }
}
```

`request.*` runs in the access phase before forwarding. `response.*` runs in the header filter phase before returning to the client. Takes effect after restart.

## Extra nginx directives

```json
"nginx_directives": [
  "proxy_buffer_size 16k",
  "proxy_buffers 4 16k"
]
```

Emitted verbatim after timeout directives and before Lua phase blocks. Use an array so repeatable directives like `add_header` work correctly. Syntax errors are caught by `nginx -t`. Requires restart.
