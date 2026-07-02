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

1. **Builder** (`openresty/openresty:alpine-fat`) — installs Fennel and lyaml via LuaRocks, compiles all `fennel/*.fnl` modules to `lib/*.lua`, and compiles `fennel/generate.fnl` to `generate.lua`.
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

### Hot reload

```sh
docker exec <container> curl -s -X POST http://127.0.0.1:8080/reload
```

This re-reads `config.json` and applies rate limits, circuit breaker thresholds, schema rules, and header config without restarting nginx. For upstream or TLS changes, rebuild the image or re-run the container (the entrypoint re-generates nginx config on every start).

### Custom nginx.conf

To override shared dict sizes, log format, or other nginx settings:

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
  template:
    metadata:
      labels:
        app: uplink
    spec:
      containers:
        - name: uplink
          image: uplink:latest
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: config
              mountPath: /uplink/config.json
              subPath: config.json
          livenessProbe:
            httpGet: { path: /healthz, port: 8080 }
            initialDelaySeconds: 5
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
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
```

To update rules/rate limits/circuit breaker thresholds without restarting: update the ConfigMap, then exec `/reload` into each pod. For upstream or TLS changes, roll the deployment.

## Shared dict sizing

| Dict | Default | Holds |
|------|---------|-------|
| `uplink_cache` | 10m | Schema JSON per service — increase for large or many schemas |
| `uplink_metrics` | 2m | Prometheus counters and histogram buckets |
| `uplink_config` | 1m | Active config + version counter |
| `uplink_circuit` | 1m | Circuit breaker state per service |
| `uplink_ratelimit` | 1m | Rate limiter state per service |
| `uplink_otel` | 2m | OTel span ring buffer (optional — see [observability](observability.md)) |

Override by mounting a custom `nginx/nginx.conf`. See [`nginx/nginx.conf.sample`](../nginx/nginx.conf.sample) for a fully annotated starting point.

## Makefile targets

```sh
make            # compile fennel/ → lib/*.lua and generate.lua
make generate   # run generate.lua → nginx/upstreams.conf + nginx/locations.conf + nginx/listen.conf
make run        # compile + generate + start OpenResty
make reload     # send nginx reload signal
make stop       # stop OpenResty
make check      # syntax-check all .fnl files
make test       # compile + run busted test suite
make clean      # remove compiled files, generated nginx conf, logs
```
