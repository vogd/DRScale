# DR Infrastructure Scale-Up Analysis — EC2 Instance Provisioning at Scale

**Region:** us-west-2 (Oregon)
**Date:** April 23, 2026
**Target:** 2,100 EC2 instances across 3 Availability Zones

---

## Executive Summary

We conducted live provisioning tests in us-west-2 to measure EC2 instance creation time, API throughput, and health check latency at scale. We provisioned over 1,400 instances across multiple test runs with zero API throttling, zero health check failures, and zero capacity errors.

**Key finding:** With default AWS limits and a rolling pool approach (batches of 50–100), no API rate limit increases are required. Provisioning 2,100 instances takes approximately 2–3 hours. For sub-5-minute DR failover where all 2,100 instances launch simultaneously, specific limit increases are needed (detailed below).

Application distribution to these instances will be handled separately by your team after instance provisioning is complete.

---

## How Instance Provisioning Works

Each batch follows this lifecycle:

```
1. RunInstances API call (single call creates N instances)
   ├─ EC2 instances created
   ├─ 4 EBS gp3 volumes per instance (via BlockDeviceMappings, no separate API calls)
   └─ Tags applied (via TagSpecifications, no separate API calls)
   Time: 3–5 seconds

2. Wait for "running" state
   ├─ EC2 places instance on host hardware
   ├─ ENI attached, network configured
   ├─ EBS volumes: creating → attaching → in-use
   └─ OS boots
   Time: 17–19 seconds

3. Wait for health checks (2/2 passed)
   ├─ System reachability check (hypervisor → instance network path)
   └─ Instance reachability check (OS-level response)
   Time: 90–300 seconds

4. Instance is healthy → ready for application deployment
```

### APIs Called During Provisioning

| API | Purpose | When Called |
|-----|---------|------------|
| `RunInstances` | Creates instances + EBS volumes + tags in one call | Once per batch |
| `DescribeInstances` | Waits for instances to reach "running" state | Once per batch (waiter) |
| `DescribeInstanceStatus` | Polls health checks until 2/2 passed | Every 15s until all healthy |
| `TerminateInstances` | Removes instance after test or on health failure | Once per instance |

`CreateVolume`, `AttachVolume`, and `CreateTags` are handled implicitly inside `RunInstances` when using `BlockDeviceMappings` and `TagSpecifications`. No separate API calls are made for EBS or tagging.

---

## Error Handling

### API Throttling — Exponential Backoff
If AWS returns `RequestLimitExceeded` or `ThrottlingException`, the system automatically retries:
- Backoff delay: 1s → 2s → 4s → 8s → 16s → 32s → 60s (capped)
- Random jitter added to prevent thundering herd across parallel processes
- Maximum 5 retries per call before reporting failure
- **Result: Zero throttling events across all tests (1,400+ instances)**

### Instance Capacity — Family Fallback Chain
If `InsufficientInstanceCapacity` is returned, the system automatically tries the next closest instance family:

```
m5 → m5a → m5n → m4 → c5 → c5a → c5n → c4 → r5 → r5a → r5n → r4
```

This ensures provisioning continues even if the primary instance type is unavailable in a specific AZ. Each fallback is logged and reported.

### Health Check Failures
Each instance is individually monitored for 2/2 health checks (system + instance reachability):
- If an instance fails: immediately terminated, logged, NOT counted as provisioned
- A replacement instance is launched automatically
- Loop protection: if consecutive failures exceed a threshold, provisioning for that AZ is aborted to prevent infinite retry loops
- On `--resume`: only the deficit is re-provisioned (completed instances are tracked in state file)

**Result: Zero health check failures across all tests.**

---

## Test Results — Batch Size Comparison

All tests: m5.xlarge, 4 gp3 EBS volumes (20GB root + 3×50GB data), 3 AZs in us-west-2, health checks waited on for every instance.

### Measured: 600 Instances (200 per AZ)

| Metric | Batch 10 | Batch 25* | Batch 50 | Batch 100 |
|--------|----------|-----------|----------|-----------|
| **Total time** | ~100m | ~75m | 49.7m | 38.0m |
| **Per AZ** | ~33m | ~25m | ~16m | ~13m |
| **RunInstances calls** | 63 | 27 | 29 | 10 |
| **TerminateInstances calls** | 210 | 600 | 600 | 600 |
| **DescribeInstanceStatus calls** | 63 | ~45 | 51 | 30 |
| **Total API calls** | ~400 | ~700 | 709 | 650 |
| **Peak RPS (any API)** | 1 | 1 | 1 | 1 |
| **Throttling events** | 0 | 0 | 0 | 0 |
| **Health check failures** | 0 | 0 | 0 | 0 |

*Batch 25 estimated from interpolation of measured data points.

### Projected: 2,100 Instances (700 per AZ)

| Metric | Batch 10 | Batch 25 | Batch 50 | Batch 100 |
|--------|----------|----------|----------|-----------|
| **Total time** | ~5.8 hours | ~4.4 hours | ~2.9 hours | ~2.2 hours |
| **RunInstances calls** | 210 | 84 | 101 | 35 |
| **Total API calls** | ~1,400 | ~2,450 | ~2,481 | ~2,275 |
| **Peak RPS** | 1 | 1 | 1 | 1 |
| **Limit increases needed** | None | None | None | None |

### Key Observations

1. **Larger batches = faster provisioning** — Batch 100 is 62% faster than batch 10
2. **Peak RPS stays at 1 regardless of batch size** — Rolling pool means we never burst multiple API calls per second
3. **No API limit increases needed** with the rolling pool approach at any batch size
4. **Health check wait is the bottleneck** — Instance launch takes 17-19s, but health checks take 90-300s
5. **Zero throttling across all tests** — 1,400+ instances provisioned without a single `RequestLimitExceeded`

---

## Why We Don't Hit API Limits with Rolling Batches

AWS EC2 uses a token bucket algorithm for API rate limiting. Each API has a bucket with maximum capacity (burst) and a refill rate (sustained throughput).

With our rolling pool approach, we make one `RunInstances` call every few minutes as instances complete health checks and get replaced. Peak RPS never exceeds 1.

| API | Bucket Max | Refill/s | Our Peak RPS | Bucket Utilization |
|-----|-----------|---------|-------------|-------------------|
| RunInstances | 5 | 2/s | 1 | 20% |
| TerminateInstances | 100 | 5/s | 1 | 1% |
| DescribeInstances | 100 | 20/s | 1 | 1% |
| DescribeInstanceStatus | 100 | 20/s | 1 | 1% |

**Even at 2,100 instances, the peak RPS remains 1.** Only the total number of calls increases — the rate stays the same. The bucket refills faster than we consume tokens, so we never hit the limit.

---

## Sub-5-Minute DR Failover — What It Means and What It Requires

### What is Sub-5-Minute Failover?

Instead of provisioning instances in rolling batches over 2–3 hours, all 2,100 instances are launched simultaneously in a single burst. The timeline:

```
T+0s:    5 × RunInstances(500) — all 2,100 instances requested
T+3s:    All API calls complete (fits in burst bucket)
T+20s:   All 2,100 instances reach "running" state
T+120s:  First instances pass health checks
T+180s:  All 2,100 instances healthy
T+180s+: Application deployment begins (customer-managed)
```

**Total: ~3 minutes from trigger to 2,100 healthy instances.**

### Why This Requires Limit Increases

When launching 2,100 instances simultaneously, we hit two bottlenecks that don't exist with rolling batches:

**1. RunInstances Resource Bucket (the critical bottleneck)**

The resource bucket controls how many instances can be created per second. Default: 1,000 burst capacity, refills at 2 instances/second.

```
Batch 1: RunInstances(500) → 500 resource tokens consumed (500 remaining)
Batch 2: RunInstances(500) → 500 tokens consumed (0 remaining)
── bucket empty, must wait ──
Wait 250 seconds for 500 tokens to refill at 2/sec
Batch 3: RunInstances(500) → 500 tokens consumed
Wait 300 seconds for 600 more tokens
Batch 4+5: remaining 600 instances

Total wait: ~550 seconds (9.2 minutes) just for API rate limiting
```

With bucket increased to 3,000: all 2,100 instances launch in one burst, zero wait.

**2. On-Demand vCPU Quota**

Default quota is ~1,920 vCPUs. Each m5.xlarge uses 4 vCPUs. 2,100 instances × 4 = 8,400 vCPUs needed simultaneously. With rolling batches of 100, only 400 vCPUs are concurrent — well within the default.

**3. gp3 Storage Quota**

Default is 50 TiB. Each instance uses 170GB (4 volumes). 2,100 × 170GB = 348 TiB needed simultaneously. With rolling batches, terminated instances release storage immediately.

### Required Limit Increases for Sub-5-Minute Failover

| Limit | Current Default | Required | Why | How to Request |
|-------|----------------|----------|-----|---------------|
| RunInstances resource bucket | 1,000 burst / 2 per sec | **3,000 burst / 10 per sec** | Launch all 2,100 in one burst without waiting for refill | AWS Support case |
| RunInstances request bucket | 5 burst / 2 per sec | **10 burst / 5 per sec** | Allow 5 concurrent RunInstances(500) calls | AWS Support case |
| On-Demand vCPUs (Standard) | ~1,920 | **10,000+** | 2,100 × 4 vCPU = 8,400 concurrent | Service Quotas console |
| gp3 storage | 50 TiB | **400 TiB** | 2,100 × 170GB = 348 TiB concurrent | Service Quotas console |
| ENIs per region | 5,000 | 5,000 (no change) | 2,100 < 5,000 | None needed |

**Note:** API rate limits (RunInstances buckets) are NOT adjustable via the Service Quotas console. They require an AWS Support case with the following template:

```
Subject: Request an increase in my Amazon EC2 API throttling limits
Region: us-west-2

us-west-2 resource rate increases:
    RunInstances: 3000 (bucket max) | 10 (refill rate)

us-west-2 request rate increases:
    RunInstances: 10 (bucket max) | 5 (refill rate)
```

### Optional: On-Demand Capacity Reservations (ODCR)

Even with all limits raised, there is a risk that AWS may not have 2,100 m5.xlarge instances physically available in your AZs during a real DR event (e.g., regional outage causing high demand). ODCR guarantees that capacity is reserved for you 24/7.

- ODCR costs the On-Demand rate whether instances are running or not
- Can be paired with Reserved Instances or Savings Plans for ~37% discount
- Without ODCR: risk of `InsufficientInstanceCapacity` during high-demand events (mitigated by our automatic family fallback chain)

---

## Recommendation Summary

| Approach | Time for 2,100 | Limit Changes Needed | Best For |
|----------|---------------|---------------------|----------|
| Rolling batch 50 | ~3 hours | None | Testing, non-critical DR |
| Rolling batch 100 | ~2.2 hours | None | Moderate RTO requirements |
| Parallel batch 500 | ~3 minutes | API buckets + vCPU + gp3 quotas | Fast DR, accept capacity risk |
| Parallel + ODCR | ~3 minutes | API buckets + vCPU + gp3 + ODCR | Mission-critical DR with guaranteed capacity |

---

Please let us know if you'd like to proceed with limit increase requests or schedule a full-scale 2,100 instance test.
