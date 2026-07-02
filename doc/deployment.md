# Deployment

## Docker

```sh
docker build -t ladon .
docker run -p 8080:8080 -v ./config.json:/ladon/config.json ladon
```

The entrypoint runs `generate.lua`, validates with `nginx -t`, then starts OpenResty. Override the config path with `LADON_CONFIG`:

```sh
docker run -p 8080:8080 \
  -e LADON_CONFIG=/etc/ladon/config.json \
  -v ./config.json:/etc/ladon/config.json \
  ladon
```

Mount certs for mTLS:

```sh
docker run -p 8080:8080 \
  -v ./config.json:/ladon/config.json \
  -v ./certs:/certs:ro \
  ladon
```

Hot-reload inside a running container:

```sh
docker exec <container> curl -s -X POST http://127.0.0.1:8080/reload
```

## Docker Compose

```yaml
services:
  ladon:
    build: .
    ports:
      - "8080:8080"
    volumes:
      - ./config.json:/ladon/config.json
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://127.0.0.1:8080/healthz"]
      interval: 10s
      timeout: 3s
      retries: 3
```

## Kubernetes

```sh
kubectl create configmap ladon-config --from-file=config.json
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ladon
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ladon
  template:
    metadata:
      labels:
        app: ladon
    spec:
      containers:
        - name: ladon
          image: ladon:latest
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: config
              mountPath: /ladon/config.json
              subPath: config.json
          livenessProbe:
            httpGet: { path: /healthz, port: 8080 }
            initialDelaySeconds: 5
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
      volumes:
        - name: config
          configMap:
            name: ladon-config
---
apiVersion: v1
kind: Service
metadata:
  name: ladon
spec:
  selector:
    app: ladon
  ports:
    - port: 80
      targetPort: 8080
```

To update rules/rate limits/circuit breaker thresholds without restarting: update the ConfigMap, then exec `/reload` into each pod. For upstream or TLS changes, roll the deployment.

## Shared dict sizing

| Dict | Default | Holds |
|------|---------|-------|
| `ladon_cache` | 10m | Schema JSON per service — increase for large or many schemas |
| `ladon_metrics` | 2m | Prometheus counters and histogram buckets |
| `ladon_config` | 1m | Active config + version counter |
| `ladon_circuit` | 1m | Circuit breaker state per service |
| `ladon_ratelimit` | 1m | Rate limiter state per service |
| `ladon_otel` | 2m | OTel span ring buffer (optional — see [observability](observability.md)) |

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
