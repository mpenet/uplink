# Uplink Documentation

## Reference

| Page | Description |
|------|-------------|
| [How it works](how-it-works.md) | Request lifecycle, routing, schema aggregation, trace propagation |
| [Configuration](configuration.md) | Top-level config structure and service field reference |
| [Routing](routing.md) | Rules (path/method/tag filters), load balancing, WebSocket |
| [Authentication](auth.md) | JWT validation — HMAC, PEM, JWKS |
| [TLS](tls.md) | Server TLS/mTLS, upstream mTLS |
| [Traffic control](traffic.md) | Rate limiting, adaptive concurrency, keepalive pools |
| [Headers & CORS](headers.md) | Request/response header injection and stripping, CORS |
| [Observability](observability.md) | Prometheus metrics, JSON access log, OpenTelemetry |
| [Deployment](deployment.md) | Docker, Kubernetes, shared dict sizing, troubleshooting |
