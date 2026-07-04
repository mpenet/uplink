# Deployment

## Docker

### Prebuilt image

```sh
docker pull ghcr.io/mpenet/uplink:latest
```

Images are published to the GitHub Container Registry on every push to `main`. Use a specific tag (e.g. `ghcr.io/mpenet/uplink:0.1.0`) in production rather than `latest`.

### Build from source

```sh
docker build -t uplink .
```

The Dockerfile uses a two-stage build:

1. **Builder** (`openresty/openresty:alpine-fat`) — installs Fennel and lyaml via LuaRocks, compiles all `fnl/*.fnl` modules to `lib/*.lua`, and compiles `fnl/generate.fnl` to `generate.lua`.
2. **Runtime** (`openresty/openresty:alpine`) — copies compiled Lua from the builder, the nginx config, and the entrypoint. No build tools in the final image.

What is baked into the image:
- Compiled Lua modules (`lib/`)
- `generate.lua` (the nginx config generator)
- `nginx/nginx.conf`

What must be mounted at runtime:
- `config.json` — service definitions (required)
- TLS certificates, if using mTLS upstream or server TLS

### Run

```sh
docker run -p 8080:8080 -v ./config.json:/uplink/config.json uplink
```

On startup the entrypoint:
1. Reads `config.json` (or `$UPLINK_CONFIG`) — exits with an error if missing
2. Runs `luajit generate.lua` — writes `nginx/upstreams.conf`, `nginx/locations.conf`, `nginx/listen.conf`
3. Validates the generated config with `openresty -t`
4. Starts OpenResty in the foreground

### Custom config path

```sh
docker run -p 8080:8080 \
  -e UPLINK_CONFIG=/etc/uplink/config.json \
  -v ./config.json:/etc/uplink/config.json \
  uplink
```

### Upstream mTLS

```sh
docker run -p 8080:8080 \
  -v ./config.json:/uplink/config.json \
  -v ./certs:/certs:ro \
  uplink
```

Cert paths in `config.json` must match the mount point inside the container.

### Server TLS

Expose port 8443 and mount the server certificate:

```sh
docker run -p 8080:8080 -p 8443:8443 \
  -v ./config.json:/uplink/config.json \
  -v ./certs:/certs:ro \
  uplink
```

`server.tls` in `config.json` must reference absolute paths inside the container (e.g. `/certs/server.crt`).

### Custom nginx.conf

To override shared dict sizes or other nginx settings:

```sh
docker run -p 8080:8080 \
  -v ./config.json:/uplink/config.json \
  -v ./nginx/nginx.conf:/uplink/nginx/nginx.conf \
  uplink
```

Use [`nginx/nginx.conf.sample`](../nginx/nginx.conf.sample) as a starting point.

## Docker Compose

```yaml
services:
  uplink:
    build: .
    ports:
      - "8080:8080"
    volumes:
      - ./config.json:/uplink/config.json
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://127.0.0.1:8080/healthz"]
      interval: 10s
      timeout: 3s
      retries: 3
```

## Kubernetes

### Basic deployment

```sh
kubectl create configmap uplink-config --from-file=config.json
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: uplink
spec:
  replicas: 2
  selector:
    matchLabels:
      app: uplink
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: uplink
    spec:
      containers:
        - name: uplink
          image: ghcr.io/mpenet/uplink:latest
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: 1000m
              memory: 256Mi
          volumeMounts:
            - name: config
              mountPath: /uplink/config.json
              subPath: config.json
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 5
      volumes:
        - name: config
          configMap:
            name: uplink-config
---
apiVersion: v1
kind: Service
metadata:
  name: uplink
spec:
  selector:
    app: uplink
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: uplink
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: uplink
```

### DNS resolver

The entrypoint auto-reads the nameserver from `/etc/resolv.conf` at startup, which works correctly in K8s clusters (typically resolves to `kube-dns` or `CoreDNS`). No manual resolver configuration needed.

### Config updates

Config is loaded once at startup. To apply `config.json` changes, update the ConfigMap and roll the Deployment:

```sh
kubectl create configmap uplink-config --from-file=config.json -o yaml --dry-run=client | kubectl apply -f -
kubectl rollout restart deployment/uplink
```

With `maxUnavailable: 0` this is zero-downtime. Use [stakater/Reloader](https://github.com/stakater/Reloader) to automate rollouts whenever the ConfigMap changes.

### TLS with cert-manager

For server TLS, provision a certificate with [cert-manager](https://cert-manager.io) and mount the Secret:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: uplink-tls
spec:
  secretName: uplink-tls
  dnsNames:
    - api.example.com
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
```

Mount the Secret into the pod:
```yaml
volumeMounts:
  - name: tls
    mountPath: /certs
    readOnly: true
volumes:
  - name: tls
    secret:
      secretName: uplink-tls
```

Reference in `config.json`:
```json
"server": {
  "tls": {
    "cert": "/certs/tls.crt",
    "key":  "/certs/tls.key"
  }
}
```

cert-manager writes renewed certificates to the Secret and K8s updates the mounted files in place. To pick up the new cert, roll the Deployment — with `maxUnavailable: 0` this is zero-downtime. Automate this with [stakater/Reloader](https://github.com/stakater/Reloader), which watches Secrets and triggers a rolling restart when they change.

### Horizontal scaling

Uplink is stateless at the routing and proxying level and scales horizontally. Note that shared dict state — rate limiter buckets, adaptive concurrency state, schema cache — is **per pod**. In a multi-replica deployment:

- **Rate limits** are enforced per pod, not globally. A `requests_per_second: 100` limit with 3 replicas effectively allows ~300 rps cluster-wide.
- **Adaptive concurrency** state is per pod — each pod tracks its own inflight count and RTT baseline independently.
- **Schema cache** is populated independently per pod on first request after startup.

For global rate limiting, place a shared rate limiter (e.g. Redis + nginx-lua-resty-limit) in front of Uplink or at the Ingress layer.

## Shared dict sizing

| Dict | Default | Holds |
|------|---------|-------|
| `uplink_cache` | 10m | Schema JSON per service — increase for large or many schemas |
| `uplink_metrics` | 2m | Prometheus counters and histogram buckets |
| `uplink_ratelimit` | 1m | Rate limiter state per service |
| `uplink_adaptive` | 1m | Adaptive concurrency state per service |
| `uplink_otel` | 2m | OTel span ring buffer (optional — see [observability](observability.md)) |

Override by mounting a custom `nginx/nginx.conf`. See [`nginx/nginx.conf.sample`](../nginx/nginx.conf.sample) for a fully annotated starting point.

## Makefile targets

```sh
make            # compile fnl/ → lib/*.lua and generate.lua
make generate   # run generate.lua → nginx/upstreams.conf + nginx/locations.conf + nginx/listen.conf
make run        # compile + generate + start OpenResty
make stop       # stop OpenResty
make check      # syntax-check all .fnl files
make test       # compile + run busted test suite
make clean      # remove compiled files, generated nginx conf, logs
```

## Troubleshooting

**`module 'X' not found` at startup**
Compiled Lua modules are missing. Run `make` to compile `fnl/` → `lib/`, then restart.

**`open() "...nginx/upstreams.conf" failed`**
`generate.lua` has not run yet. The entrypoint runs it automatically; if running nginx directly, run `make generate` first.

**`no resolver defined to resolve "hostname"`**
The container's DNS is not reachable. The entrypoint reads `/etc/resolv.conf` and writes `nginx/resolver.conf` automatically. If running outside Docker, ensure `/etc/resolv.conf` has a valid nameserver entry.

**`SSL handshake failed: wrong version number`**
Upstream is HTTPS but the upstream block is connecting on port 80. Check that the `upstream` URL uses `https://` — Uplink appends `:443` automatically when the port is omitted.

**`SSL handshake failed: alert handshake failure`**
Upstream requires SNI (common with CDN-backed services). Uplink emits `proxy_ssl_server_name on` automatically for all HTTPS upstreams so this should not occur with a correctly configured `upstream` URL. Verify the upstream host resolves correctly.

**`schema fetch returned HTTP 404`**
The `schema_url` for a service is wrong. Check the URL returns a valid OpenAPI 3.x JSON or YAML document.

**`/openapi.json` returns `500`**
Check stderr (error log) for the underlying Lua error. Common causes: shared dict not defined in `nginx.conf`, missing required module, or a schema fetch error on all services simultaneously.

