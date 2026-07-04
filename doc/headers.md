# Headers & CORS

## Request and response headers

Inject or strip headers on requests before they reach the upstream and on responses before they reach the client:

```json
"headers": {
  "request": {
    "set":   {"X-Tenant": "acme", "X-Service-Version": "2"},
    "strip": ["X-Internal-Token", "X-Debug"]
  },
  "response": {
    "set":   {"X-Gateway": "uplink"},
    "strip": ["X-Powered-By", "Server"]
  }
}
```

`request.set` and `request.strip` run in the access phase before `proxy_pass`. `response.set` and `response.strip` run in the header filter phase before the response is returned to the client.

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
| `origins` | `["*"]` | Allowed origins. `["*"]` = wildcard. Single specific origin = literal `add_header`. Multiple specific origins = nginx `map {}` block for dynamic matching |
| `methods` | `["GET","POST","OPTIONS"]` | `Access-Control-Allow-Methods` |
| `headers` | `["Authorization","Content-Type"]` | `Access-Control-Allow-Headers` |
| `max_age` | `3600` | `Access-Control-Max-Age` in seconds |
| `credentials` | `false` | Emit `Access-Control-Allow-Credentials: true`. Incompatible with `origins: ["*"]` — Uplink rejects this combination at startup |

OPTIONS preflight requests are short-circuited with `204 No Content`.

## Extra nginx directives

Arbitrary nginx directives can be injected into the generated location block:

```json
"nginx_directives": [
  "proxy_buffer_size 16k",
  "proxy_buffers 4 16k"
]
```

Directives are emitted verbatim after timeout directives and before Lua phase blocks. Use an array so repeatable directives like `add_header` work correctly. Syntax errors are caught by `nginx -t` at startup.
