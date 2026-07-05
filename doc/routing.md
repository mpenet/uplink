# Routing

## Rules

Rules control which operations from a service's OpenAPI schema are included in the merged `/openapi.json`. All fields are optional — omitting `rules` entirely allows everything.

| Field | Default | Description |
|-------|---------|-------------|
| `paths` | all | Path filter patterns |
| `methods` | all | Method filter patterns |
| `tags` | all | Tag filter patterns |

`rules` is an **array of rule objects**. An operation is included when it satisfies all filters within **any single rule** — rules are OR'd, filters within a rule are AND'd.

```
included = rule[0].paths ∩ rule[0].methods ∩ rule[0].tags
         OR rule[1].paths ∩ rule[1].methods ∩ rule[1].tags
         OR ...
```

Each rule field is optional. Absent or empty `rules` array → allow all.

### Pattern syntax

Each filter field is an array of patterns:

- `*` — matches any string
- `/v1/*` — prefix match (only trailing `*` is supported)
- `!pat` — negation: if the value matches, the operation is excluded even if it also matches an inclusion pattern
- Multiple negations are ORed — the value is excluded if it matches **any** negation

Semantics for a single pattern list:

| Patterns | Meaning |
|----------|---------|
| `[]` / absent | Allow all |
| `["GET", "POST"]` | Allow only GET and POST |
| `["!DELETE"]` | Allow everything except DELETE |
| `["/v1/*", "!/v1/admin/*"]` | `/v1/*` minus `/v1/admin/*` |
| `["!/internal/*", "!/admin/*"]` | Everything except `/internal/*` and `/admin/*` |

### Examples

**Single rule — allow everything:**
```json
"rules": []
```

**Single rule — GET and POST, excluding internal paths:**
```json
"rules": [
  {
    "paths": ["!/internal/*", "!/debug/*"],
    "methods": ["GET", "POST"]
  }
]
```

**Two rules — POST with tag `orders` OR any GET:**
```json
"rules": [
  {"methods": ["POST"], "tags": ["orders"]},
  {"methods": ["GET"]}
]
```
A DELETE request matches neither rule and is excluded. A POST without the `orders` tag also matches neither.

**Path-scoped rules — different method sets per version:**
```json
"rules": [
  {"paths": ["/v1/*"], "methods": ["GET"]},
  {"paths": ["/v2/*"], "methods": ["GET", "POST", "PUT", "DELETE"]}
]
```

**Full combination:**
```json
"rules": [
  {
    "paths": ["/v1/*", "!/v1/admin/*"],
    "methods": ["GET", "POST"],
    "tags": ["public"]
  },
  {
    "tags": ["internal"],
    "methods": ["GET"]
  }
]
```

Filtering applies to the OpenAPI schema — it controls which operations appear in `/openapi.json`. It does not block proxied traffic.

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
