# Configuration

`config.json` at the project root. Override path with `UPLINK_CONFIG` env var.

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
| `upstream` | yes | — | Upstream URL, array of URLs, or array of server objects |
| `schema_url` | yes | — | URL of the service's OpenAPI 3.x JSON or YAML schema |
| `ttl` | no | `300` | Schema cache TTL in seconds. Upstream `Cache-Control`/`Expires` takes precedence |
| `timeout` | no | `30000` | Connect/send/read timeout in milliseconds |
| `rules` | no | allow all | Route filter rules |
| `tls` | no | — | Upstream mTLS client credentials |
| `rate_limit` | no | — | Per-service rate limiting |
| `nginx_directives` | no | — | Extra nginx directives injected into the location block |
| `host_header` | no | first upstream host | Host header sent upstream |
| `keepalive` | no | see below | Upstream keepalive pool settings |
| `balancing` | no | `"round_robin"` | Load balancing algorithm |
| `websocket` | no | — | Set `true` to proxy WebSocket upgrades |
| `cors` | no | — | CORS configuration |
| `headers` | no | — | Request/response header injection and stripping |
| `adaptive_concurrency` | no | — | Gradient-based adaptive concurrency limiting |
| `auth` | no | — | Authentication — JWT validation |
| `otel` | no | — | OpenTelemetry export config (see [Observability](observability.md)) |

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


## WebSocket

```json
"websocket": true
```

Emits `Upgrade` and `Connection: upgrade` headers and extends `proxy_read_timeout` to 3600s. The full forwarding header set is re-emitted in the location block (nginx does not inherit server-block `proxy_set_header` once a location adds any of its own).


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

TLS 1.2/1.3 only, modern cipher suite. 
## Rate limiting

Leaky bucket via `resty.limit.req`. Requests within `burst` are admitted immediately; excess return `429`.

```json
"rate_limit": {
  "requests_per_second": 100,
  "burst": 50
}
```


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

OPTIONS preflight is short-circuited with `204`. 
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

`request.*` runs in the access phase before forwarding. `response.*` runs in the header filter phase before returning to the client. 
## Authentication

JWT validation in the access phase via `service.auth.jwt`. Tokens must be presented as `Authorization: Bearer <token>`. Returns `401` on missing, malformed, or invalid tokens.

### Key sources (mutually exclusive)

**HMAC secret (HS256/HS384/HS512):**
```json
"auth": {
  "jwt": {
    "secret": "my-shared-secret",
    "algorithms": ["HS256"]
  }
}
```

**Static PEM public key (RS256/RS384/RS512/ES256/ES384/ES512):**
```json
"auth": {
  "jwt": {
    "public_key": "-----BEGIN PUBLIC KEY-----\n...\n-----END PUBLIC KEY-----",
    "algorithms": ["RS256"]
  }
}
```

**JWKS endpoint (RS256 — Auth0, Keycloak, Google, etc.):**
```json
"auth": {
  "jwt": {
    "jwks_url": "https://auth.example.com/.well-known/jwks.json",
    "algorithms": ["RS256"],
    "claims": {
      "iss": "https://auth.example.com/",
      "aud": "my-api"
    }
  }
}
```

JWKS keys are fetched lazily on first request and cached per worker for 1 hour. On a cache miss for a `kid`, the JWKS is re-fetched once to handle key rotation.

### Options

| Field | Default | Description |
|-------|---------|-------------|
| `secret` | — | HMAC secret for HS* |
| `public_key` | — | PEM public key string for RS*/ES* |
| `jwks_url` | — | JWKS endpoint URL (RSA only) |
| `algorithms` | `["RS256"]` | Allowed algorithm values. The token's `alg` header must match. Validated before signature to prevent algorithm confusion attacks |
| `claims` | — | Required claim values. `aud` accepts string or array |
| `header` | `"Authorization"` | Header to read the Bearer token from |
| `strip` | `false` | Remove the auth header before forwarding upstream |
| `forward` | — | Claim names to inject upstream as `X-JWT-<Name>` headers. Non-string values are JSON-encoded |

### Example with claim forwarding

```json
"auth": {
  "jwt": {
    "jwks_url": "https://accounts.google.com/.well-known/openid-configuration",
    "algorithms": ["RS256"],
    "claims": {"iss": "https://accounts.google.com"},
    "strip": true,
    "forward": ["sub", "email"]
  }
}
```

Upstream receives `X-JWT-sub` and `X-JWT-email` headers; the original `Authorization` header is stripped.

## Adaptive concurrency

Dynamically adjusts the in-flight request limit using a gradient algorithm. When upstream latency rises above the observed minimum, the limit shrinks; when latency is stable it probes upward. On upstream error it backs off by 10%. Requests that exceed the current limit get `429`.

```json
"adaptive_concurrency": {
  "initial_limit": 20,
  "min_limit": 5,
  "max_limit": 200,
  "min_rtt_reset": 60
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `initial_limit` | `20` | Starting concurrency limit before observations accumulate |
| `min_limit` | `5` | Floor — limit never drops below this |
| `max_limit` | `200` | Ceiling — limit never rises above this |
| `min_rtt_reset` | `60` | Seconds before the minimum-RTT baseline is re-sampled. Allows the limit to grow after upstream latency genuinely improves |

The gradient update runs per-request in the log phase:

```
new_limit = floor(current_limit × (min_rtt / rtt_ema) + sqrt(current_limit))   # success
new_limit = floor(current_limit × 0.9)                                           # 5xx
```

Where `rtt_ema` is an exponential moving average (α = 0.1) of upstream response time and `min_rtt` is the minimum observed RTT since the last reset.

`adaptive_concurrency` and `rate_limit` can coexist — the rate limiter is checked first.

State lives in `uplink_adaptive` shared dict. Requires the dict to be declared in `nginx.conf` (enabled by default).

## Extra nginx directives

```json
"nginx_directives": [
  "proxy_buffer_size 16k",
  "proxy_buffers 4 16k"
]
```

Emitted verbatim after timeout directives and before Lua phase blocks. Use an array so repeatable directives like `add_header` work correctly. Syntax errors are caught by `nginx -t`. 