[![CI](https://github.com/mpenet/uplink/actions/workflows/test.yml/badge.svg)](https://github.com/mpenet/uplink/actions/workflows/test.yml)
[![ghcr.io](https://img.shields.io/badge/ghcr.io-mpenet%2Fuplink-blue)](https://github.com/mpenet/uplink/pkgs/container/uplink)
<br><br>
<img width="200" height="200" src="https://github.com/user-attachments/assets/b9419850-2195-4138-9938-ba2347daece3" />
<br>


OpenResty based API gateway that aggregates multiple upstream OpenAPI 3.x
services under a single endpoint. Each service is exposed under a `/<name>`
prefix; a merged `/openapi.json` schema covers all of them.

Proxying runs through **native nginx** `proxy_pass` — keepalive pools, TLS, body
streaming, and retries at **C speed** with no Lua on the hot path.

Built on [OpenResty](https://openresty.org) + Alpine: the Docker image is ~62 MB
and idle memory sits in the low single-digit MB range.

- **Proxy**
  - Multi-upstream load balancing
  - Keepalive pools
  - WebSocket
  - Server TLS/mTLS
  - Upstream mTLS
- **Policy**
  - Per-service JWT auth (HS*/RS*/ES*, JWKS)
  - Rate limiting
  - Adaptive concurrency limiting
  - CORS
  - Header injection/stripping
  - Fine-grained route filtering (path, method, tag — with wildcard and negation patterns)
- **Observability**
  - Prometheus metrics
  - JSON access log
  - OpenTelemetry OTLP/HTTP
  - W3C trace propagation
  
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
      "name": "petstore",
      "upstream": "https://petstore3.swagger.io",
      "schema_url": "https://petstore3.swagger.io/api/v3/openapi.json",
      "ttl": 300,
      "rules": [
        {
          "paths": ["/api/v3/*", "!/api/v3/admin/*"],
          "methods": ["GET", "POST", "PUT", "DELETE"],
          "tags": ["pet", "store"]
        }
      ]
    },
    {
      "name": "apisguru",
      "upstream": "https://api.apis.guru",
      "schema_url": "https://api.apis.guru/v2/openapi.yaml",
      "ttl": 300,
      "rules": [
        {
          "paths": ["!/v2/private/*"],
          "methods": ["GET"]
        }
      ]
    }
  ]
}
```

`GET /petstore/api/v3/pet/1` → strips `/petstore` → proxied to `https://petstore3.swagger.io/api/v3/pet/1`.  
`GET /openapi.json` → merged schema for all services.

`rules` is an array — each element is a rule object whose fields are AND'd; rules are OR'd. Rule patterns support `*` as a trailing wildcard and `!` for negation:

```json
"rules": [{"paths": ["!/internal/*", "!/admin/*"]}]
```
Everything except `/internal/*` and `/admin/*` — multiple negations are ORed.

```json
"rules": [{"paths": ["/api/*", "!/api/internal/*", "!/api/debug/*"]}]
```
Only `/api/*`, but not `/api/internal/*` or `/api/debug/*`.

```json
"rules": [
  {"paths": ["/v1/*", "!/v1/admin/*"], "methods": ["GET", "POST"], "tags": ["public"]},
  {"methods": ["GET"], "tags": ["internal"]}
]
```
POST on public `/v1/*` paths OR any GET tagged `internal`. Within each rule fields are AND'd; rules are OR'd. See [Routing](doc/routing.md) for full semantics.

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
