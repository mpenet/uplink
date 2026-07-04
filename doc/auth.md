# Authentication

JWT validation in the access phase via `service.auth.jwt`. Tokens must be presented as `Authorization: Bearer <token>`. Returns `401` on missing, malformed, algorithm-rejected, or signature-invalid tokens — the upstream is never contacted.

Rate limiting runs before authentication, so flooded requests are rejected cheaply before JWT validation begins.

## Key sources

Exactly one of `secret`, `public_key`, or `jwks_url` must be set.

### HMAC secret (HS256 / HS384 / HS512)

```json
"auth": {
  "jwt": {
    "secret": "my-shared-secret",
    "algorithms": ["HS256"]
  }
}
```

### Static PEM public key (RS256 / RS384 / RS512 / ES256 / ES384 / ES512)

```json
"auth": {
  "jwt": {
    "public_key": "-----BEGIN PUBLIC KEY-----\n...\n-----END PUBLIC KEY-----",
    "algorithms": ["RS256"]
  }
}
```

### JWKS endpoint (RS256 and family — Auth0, Keycloak, Google, etc.)

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

## Options

| Field | Default | Description |
|-------|---------|-------------|
| `secret` | — | HMAC secret for HS* |
| `public_key` | — | PEM public key string for RS*/ES* |
| `jwks_url` | — | JWKS endpoint URL (RSA only) |
| `algorithms` | `["RS256"]` | Allowed `alg` values. The token's `alg` header is validated against this list **before** the signature check to prevent algorithm confusion attacks |
| `claims` | — | Required claim key-value pairs. `aud` accepts string or array |
| `header` | `"Authorization"` | Request header to read the Bearer token from |
| `strip` | `false` | Remove the auth header before forwarding upstream |
| `forward` | — | Claim names to inject upstream as `X-JWT-<Name>` headers. Non-string values are JSON-encoded |

Standard claims (`exp`, `nbf`) are validated automatically by the JWT library.

## Claim validation

Extra claims can be required in config. `aud` follows RFC 7519 §4.1.3 — it may be a string or an array in the token; the config value is matched against either form.

```json
"claims": {
  "iss": "https://auth.example.com/",
  "aud": "orders-api"
}
```

## Claim forwarding

Selected claims can be injected upstream as `X-JWT-<Name>` headers. The `Authorization` header can be stripped so the upstream never sees the raw token.

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

The upstream receives `X-JWT-sub` and `X-JWT-email`. String claim values are forwarded as-is; non-string values (arrays, objects, numbers) are JSON-encoded.

## Services with no `auth` field

Receive all requests without authentication.
