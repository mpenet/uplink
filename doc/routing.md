# Routing

## Rules

Rules control which operations from a service's OpenAPI schema are included in the merged `/openapi.json`. All fields are optional — omitting `rules` entirely allows everything.

| Field | Default | Description |
|-------|---------|-------------|
| `paths` | all | Path filter patterns |
| `methods` | all | Method filter patterns |
| `tags` | all | Tag filter patterns |

Each field is an array of patterns. Empty or absent means **allow all**. Patterns support `*` as a trailing wildcard (`/v1/*`). Prefix a pattern with `!` to negate it.

### Evaluation rules

- **Empty list** → allow all (not deny all)
- **Inclusions only** → allow matching values, reject everything else
- **Negations only** → allow everything except matching values
- **Mixed** → allow values that match an inclusion AND do not match any negation
- **Negations always win** — if a value matches both an inclusion and a negation, it is rejected
- **Multiple negations are ORed** — a value is rejected if it matches any negation pattern

### Examples

**Allow everything:**
```json
"rules": {}
```

**Only GET and POST:**
```json
"rules": {
  "methods": ["GET", "POST"]
}
```

**Everything except DELETE:**
```json
"rules": {
  "methods": ["!DELETE"]
}
```

**Exclude multiple paths (both negations apply):**
```json
"rules": {
  "paths": ["!/internal/*", "!/admin/*"]
}
```
Rejects `/internal/anything` and `/admin/anything`; all other paths pass.

**Include range, exclude sub-path:**
```json
"rules": {
  "paths": ["/v1/*", "!/v1/admin/*"]
}
```
Only `/v1/*` paths, but not `/v1/admin/*`. `/v2/anything` is also rejected (no inclusion match).

**Multiple exclusions within an included range:**
```json
"rules": {
  "paths": ["/api/*", "!/api/internal/*", "!/api/debug/*"]
}
```
Allows `/api/*` except `/api/internal/*` and `/api/debug/*`.

**Full combination:**
```json
"rules": {
  "paths": ["/v1/*", "!/v1/admin/*"],
  "methods": ["GET", "POST"],
  "tags": ["public"]
}
```

Rules are AND'd across fields: a path must pass all three filters (path ∩ method ∩ tag) to be included. Filtering applies to the OpenAPI schema — it does not block proxied traffic, only controls which operations appear in `/openapi.json`.

## Multiple upstreams and load balancing

Single upstream:
```json
"upstream": "http://users-svc:8080"
```

Multiple upstreams:
```json
"upstream": ["http://users-1:8080", "http://users-2:8080"]
```

Server objects for per-server parameters:
```json
"upstream": [
  {"url": "http://users-1:8080", "weight": 3},
  {"url": "http://users-2:8080", "weight": 1, "max_fails": 3, "fail_timeout": "30s"}
]
```

| Field | Description |
|-------|-------------|
| `url` | Upstream server URL |
| `weight` | Relative request weight (default: `1`) |
| `max_fails` | Consecutive failures before server is marked down |
| `fail_timeout` | Duration server is skipped after `max_fails` (e.g. `"30s"`) |

String and object entries may be mixed in the same array.

`balancing` selects the load balancing algorithm:

| Value | Algorithm |
|-------|-----------|
| `"round_robin"` | Default — distribute requests in turn |
| `"least_conn"` | Server with fewest active connections |
| `"ip_hash"` | Consistent hashing by client IP (sticky sessions) |
| `"random"` | Random selection |

nginx retries failed requests on the next upstream server (`proxy_next_upstream error timeout`, max 2 tries). Only connection-level failures trigger retries — HTTP errors do not.

## Host header

By default Uplink forwards the first upstream's `host:port` as the `Host` header. Override with:

```json
"host_header": "api.internal"
```

## WebSocket

```json
"websocket": true
```

Adds `Upgrade` and `Connection: upgrade` headers and extends `proxy_read_timeout` to `3600s` to keep long-lived connections alive. The full forwarding header set is re-emitted in the location block — nginx does not inherit server-block `proxy_set_header` directives once a location adds any of its own.
