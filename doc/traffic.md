# Traffic control

## Rate limiting

Leaky bucket via `resty.limit.req`. Requests within `burst` are admitted immediately; excess return `429 {"error":"rate limit exceeded"}` before the upstream is contacted.

```json
"rate_limit": {
  "requests_per_second": 100,
  "burst": 50
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `requests_per_second` | `100` | Allowed sustained rate |
| `burst` | `50` | Extra capacity above the sustained rate before rejection |

Rate limiting runs before JWT authentication. Burst capacity is consumed and replenished at `requests_per_second`. State lives in the `uplink_ratelimit` shared dict, scoped per service name. In a multi-replica deployment the effective cluster-wide limit is `requests_per_second × replicas` — for global rate limiting, use a shared store (Redis, Ingress layer) in front of Uplink.

## Adaptive concurrency

Dynamically adjusts the in-flight request limit using a gradient algorithm. When upstream latency rises above the observed minimum RTT baseline, the limit shrinks proportionally; when latency is stable it probes upward. On upstream 5xx the limit backs off by 10%. Requests that exceed the current limit return `429 {"error":"concurrency limit exceeded"}`.

Disabled by default — opt in per service:

```json
"adaptive_concurrency": {
  "initial_limit": 20,
  "min_limit": 5,
  "max_limit": 200,
  "min_rtt_reset": 60
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `initial_limit` | `20` | Starting limit before observations accumulate |
| `min_limit` | `5` | Floor — limit never drops below this |
| `max_limit` | `200` | Ceiling — limit never rises above this |
| `min_rtt_reset` | `60` | Seconds before the minimum-RTT baseline is re-sampled, allowing the limit to grow after upstream latency genuinely improves |

The gradient update runs per-request in the log phase:

```
new_limit = floor(current_limit × (min_rtt / rtt_ema) + sqrt(current_limit))   # success
new_limit = floor(current_limit × 0.9)                                           # 5xx
```

`rtt_ema` is an exponential moving average (α = 0.1) of upstream response time. `min_rtt` is the minimum observed RTT since the last reset.

Based on Netflix's [concurrency-limits](https://github.com/Netflix/concurrency-limits) library.

State lives in the `uplink_adaptive` shared dict and is scoped per service, per worker. In a multi-replica deployment each pod tracks its own inflight count and RTT baseline independently.

`adaptive_concurrency` and `rate_limit` can coexist on the same service — rate limiting is checked first.

## Keepalive pool

Controls the upstream connection pool per service:

```json
"keepalive": {
  "pool_size": 32,
  "requests":  1000,
  "timeout":   "60s"
}
```

| Field | Default | nginx directive |
|-------|---------|-----------------|
| `pool_size` | `32` | `keepalive N` — max idle connections per worker |
| `requests` | `1000` | `keepalive_requests N` — max requests per connection |
| `timeout` | `"60s"` | `keepalive_timeout T` — idle connection lifetime |
