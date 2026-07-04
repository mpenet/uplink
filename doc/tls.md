# TLS

## Upstream mTLS

Uplink presents a client certificate to the upstream for both proxied requests and schema fetches:

```json
"tls": {
  "cert": "/certs/client.crt",
  "key":  "/certs/client.key",
  "verify": true
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `cert` | — | Client certificate path |
| `key` | — | Client private key path |
| `verify` | `false` | Verify the upstream server certificate |

Paths must be absolute and accessible inside the container. When `verify: true`, nginx validates the upstream's certificate against the system CA bundle.

Uplink also sends SNI (`proxy_ssl_server_name on`) so CDN-backed or vhost upstreams route to the correct certificate.

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
| `client_ca` | no | — | CA certificate for verifying client certificates. Enables mTLS |
| `verify_client` | no | `"on"` when `client_ca` set | nginx `ssl_verify_client` — `"on"`, `"optional"`, or `"off"` |
| `port` | no | `8443` | HTTPS listen port. Plain HTTP on `8080` is always active |

TLS 1.2/1.3 only, ECDHE + ChaCha20 cipher suite, `ssl_prefer_server_ciphers off`.

Cert paths must be absolute and accessible inside the container. For Kubernetes, see [cert-manager integration](deployment.md#tls-with-cert-manager).
