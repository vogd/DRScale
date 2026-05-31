# DRscale: EC2 API Limits Analysis for 1500 Simultaneous Instances

**Region:** us-west-2 (Oregon)
**Spec per instance:** 1 EC2 instance + 3 EBS gp3 volumes (50GB each) + bootstrap from S3

---

## 1. API Calls Per Single Instance Provisioning

| # | API Call | Category | Calls per Instance | Purpose |
|---|---------|----------|-------------------|---------|
| 1 | `RunInstances` | Uncategorized | 1 | Launch the EC2 instance (root vol created automatically) |
| 2 | `CreateVolume` | Uncategorized | 3 | Create 3 additional EBS gp3 volumes (50GB each) |
| 3 | `AttachVolume` | Mutating | 3 | Attach each volume to the instance |
| 4 | `CreateTags` | Uncategorized | 4 | Tag instance + 3 volumes (can batch, min 1 call) |
| 5 | `DescribeInstances` | Non-mutating | 2 | Poll for instance running state |
| 6 | `DescribeVolumes` | Non-mutating | 3 | Poll for volume available/in-use state |
| 7 | `StopInstances` | Uncategorized | 1 | Stop instance after bootstrap completes |
| 8 | `DescribeInstanceStatus` | Non-mutating | 1 | Verify instance status checks passed |
| | **TOTAL** | | **18** | |

**Note:** RunInstances with `BlockDeviceMappings` can include all 3 additional EBS volumes inline, reducing CreateVolume + AttachVolume to 0 separate calls. This is the **recommended approach** — it drops per-instance calls from 18 to **8**.

### Optimized API Calls (Using BlockDeviceMappings in RunInstances)

| # | API Call | Category | Calls per Instance | Purpose |
|---|---------|----------|-------------------|---------|
| 1 | `RunInstances` | Uncategorized | 1 | Launch instance + all 4 volumes (root + 3 data) |
| 2 | `CreateTags` | Uncategorized | 1 | Tag all resources in one call |
| 3 | `DescribeInstances` | Non-mutating | 2 | Poll for running state |
| 4 | `DescribeInstanceStatus` | Non-mutating | 1 | Verify status checks |
| 5 | `StopInstances` | Uncategorized | 1 | Stop after bootstrap |
| | **TOTAL** | | **6** | |

---

## 2. API Rate Limits (Token Bucket) — From AWS Documentation

| API Call | Bucket Max (burst) | Refill Rate (TPS) | Type |
|---------|-------------------|-------------------|------|
| `RunInstances` (request) | 5 | 2 | Uncategorized |
| `RunInstances` (resource) | 1,000 | 2 instances/sec | Resource rate |
| `CreateVolume` | 100 | 5 | Uncategorized |
| `AttachVolume` | 50 | 5 | Mutating |
| `CreateTags` | 100 | 10 | Uncategorized |
| `DescribeInstances` (filtered) | 100 | 20 | Non-mutating |
| `DescribeVolumes` (filtered) | 100 | 20 | Non-mutating |
| `DescribeInstanceStatus` (filtered) | 100 | 20 | Non-mutating |
| `StopInstances` (request) | 5 | 2 | Uncategorized |
| `StopInstances` (resource) | 1,000 | 20 instances/sec | Resource rate |

---

## 3. Scaling to 1500 Instances — The Bottleneck Analysis

### Scenario A: Separate CreateVolume + AttachVolume (18 calls/instance)

| API Call | Calls for 1500 | Bucket Max | Refill TPS | Time to Complete | BOTTLENECK? |
|---------|---------------|------------|-----------|-----------------|-------------|
| `RunInstances` (request) | 1,500 | 5 | 2/sec | **~750 sec (12.5 min)** | **🔴 CRITICAL** |
| `RunInstances` (resource) | 1,500 resources | 1,000 | 2/sec | **~250 sec (4.2 min)** | **🔴 CRITICAL** |
| `CreateVolume` | 4,500 | 100 | 5/sec | **~880 sec (14.7 min)** | **🔴 CRITICAL** |
| `AttachVolume` | 4,500 | 50 | 5/sec | **~890 sec (14.8 min)** | **🔴 CRITICAL** |
| `CreateTags` | 1,500 | 100 | 10/sec | ~140 sec (2.3 min) | 🟡 Moderate |
| `DescribeInstances` | 3,000 | 100 | 20/sec | ~145 sec (2.4 min) | 🟡 Moderate |
| `DescribeVolumes` | 4,500 | 100 | 20/sec | ~220 sec (3.7 min) | 🟡 Moderate |
| `StopInstances` (request) | 1,500 | 5 | 2/sec | **~750 sec (12.5 min)** | **🔴 CRITICAL** |
| **Total API calls** | **~27,000** | | | | |

### Scenario B: Optimized with BlockDeviceMappings (6 calls/instance)

| API Call | Calls for 1500 | Bucket Max | Refill TPS | Time to Complete | BOTTLENECK? |
|---------|---------------|------------|-----------|-----------------|-------------|
| `RunInstances` (request) | 1,500 | 5 | 2/sec | **~750 sec (12.5 min)** | **🔴 CRITICAL** |
| `RunInstances` (resource) | 1,500 resources | 1,000 | 2/sec | **~250 sec (4.2 min)** | **🔴 CRITICAL** |
| `CreateTags` | 1,500 | 100 | 10/sec | ~140 sec (2.3 min) | 🟡 Moderate |
| `DescribeInstances` | 3,000 | 100 | 20/sec | ~145 sec (2.4 min) | 🟡 Moderate |
| `DescribeInstanceStatus` | 1,500 | 100 | 20/sec | ~70 sec (1.2 min) | 🟢 OK |
| `StopInstances` (request) | 1,500 | 5 | 2/sec | **~750 sec (12.5 min)** | **🔴 CRITICAL** |
| **Total API calls** | **~9,000** | | | | |

---

## 4. The Real Bottleneck: RunInstances

`RunInstances` has **two independent rate limits** that both apply:

1. **Request rate:** bucket=5, refill=2/sec → max 2 RunInstances API calls per second sustained
2. **Resource rate:** bucket=1,000, refill=2 instances/sec → first 1,000 instances burst, then 2/sec

**Key insight:** You can batch up to 500 instances per single RunInstances call (AWS limit). So:
- 1,500 instances = 3 RunInstances calls (500 each) → fits in request bucket of 5
- BUT resource bucket = 1,000 burst + 2/sec refill → 1,000 instant + 250 sec for remaining 500
- **Minimum time for RunInstances alone: ~250 seconds (4.2 min)**

### Optimal Strategy: 3 calls × 500 instances each
- Call 1: 500 instances → uses 500 resource tokens (500 remaining)
- Call 2: 500 instances → uses 500 resource tokens (0 remaining)
- Call 3: 500 instances → needs 500 tokens, refill at 2/sec → **250 sec wait**

---

## 5. Resource Quotas (us-west-2 defaults)

| Resource | Default Quota | Required for 1500 instances | Status |
|---------|--------------|---------------------------|--------|
| Standard On-Demand vCPUs | Varies (typically 1,920) | m5.xlarge=6,000 / c5.xlarge=6,000 / r5.xlarge=6,000 | **🔴 Increase needed** |
| gp3 storage (TiB) | 50 TiB | 1,500 × 4 × 50GB = 292 TiB | **🔴 Increase needed** |
| EBS volumes per launch | 2,500 (us-west-2) | 2,000 per call (500 inst × 4 vols) | 🟢 OK |
| ENIs per region | 5,000 | 1,500 | 🟢 OK |
| Instances per region | No hard limit (vCPU-based) | 1,500 | Depends on vCPU quota |

**For your 210-instance test (m5/c5/r5 × 70 each):**

| Resource | Required | Default Quota | Status |
|---------|---------|--------------|--------|
| vCPUs (assuming .xlarge = 4 vCPU) | 840 | ~1,920 | 🟢 Likely OK |
| gp3 storage | 210 × 4 × 50GB = 41 TiB | 50 TiB | 🟡 Tight |
| EBS volumes | 210 × 4 = 840 | No per-count limit | 🟢 OK |

---

## 6. Batch Size Recommendation

### For 210 instances (your test):

| Batch Size | RunInstances Calls | Time for RunInstances | Throttling Risk | Recommendation |
|-----------|-------------------|----------------------|----------------|----------------|
| 35 | 6 calls | ~3 sec (burst) | 🟢 None | Conservative, safe |
| 70 | 3 calls | ~2 sec (burst) | 🟢 None | **✅ RECOMMENDED** |
| 210 | 1 call | ~1 sec (burst) | 🟢 None | Aggressive but works |

**210 instances fit entirely within the resource burst bucket (1,000).** All batch sizes work fine for your test. I recommend **70 per batch** (1 per AZ) because:
- Matches your AZ distribution (70 per AZ)
- Stays well within burst limits
- Gives you per-AZ timing measurements
- Easy to parallelize 3 batches simultaneously

### For 1500 instances (customer scenario):

| Batch Size | RunInstances Calls | Time for RunInstances | Throttling Risk | Recommendation |
|-----------|-------------------|----------------------|----------------|----------------|
| 35 | 43 calls | ~22 sec (request limit) | 🟡 Request throttle | Too many API calls |
| 70 | 22 calls | ~11 sec (request limit) | 🟡 Request throttle | Moderate |
| 500 | 3 calls | ~250 sec (resource limit) | 🟢 Minimal | **✅ RECOMMENDED** |

**For 1500 instances, use 3 calls of 500 each.** The bottleneck shifts from request rate to resource rate. You'll wait ~4 min for the resource bucket to refill, but you minimize API call overhead.

### With API limit increase (recommended for production):

Request these increases for 1500 simultaneous instances:
```
us-west-2 request rate increases:
    RunInstances: 10 (bucket max) | 5 (refill rate)
    StopInstances: 10 (bucket max) | 5 (refill rate)
us-west-2 resource rate increases:
    RunInstances: 2000 (bucket max) | 10 (refill rate)
    StopInstances: 2000 (bucket max) | 40 (refill rate)
```

---

## 7. StopInstances — The Other Bottleneck for 1500

| Approach | Calls | Time | Notes |
|---------|-------|------|-------|
| 1 call per instance | 1,500 calls | ~750 sec (12.5 min) | Request rate limited |
| Batch 500 per call | 3 calls | ~25 sec | Resource bucket=1,000, refill=20/sec |

**StopInstances is much better** — resource refill is 20/sec vs RunInstances' 2/sec. Batch 500 per call.

---

## 8. Summary: Time Estimates for 1500 Instances

| Phase | Optimized Approach | Estimated Time |
|-------|-------------------|---------------|
| RunInstances (3 × 500) | BlockDeviceMappings for all volumes | ~4.2 min (resource rate) |
| Wait for running state | Parallel DescribeInstances polling | ~2-3 min |
| Bootstrap (S3 copy + unzip 10GB) | UserData script, parallel on instances | ~5-10 min |
| StopInstances (3 × 500) | Batch stop | ~25 sec |
| CreateTags | Batch tag | ~2.3 min |
| **Total estimated** | | **~15-20 min** |

---

## 9. Error Handling Strategy

### Instance Capacity Fallback Chains
When `InsufficientInstanceCapacity` or `InstanceLimitExceeded` is returned, automatically try the next family:

| Primary | Fallback 1 | Fallback 2 | Fallback 3 |
|---------|-----------|-----------|-----------|
| m5 | m5a | m5n | m4 |
| c5 | c5a | c5n | c4 |
| r5 | r5a | r5n | r4 |

### API Throttling Retries
- Exponential backoff: 1s → 2s → 4s → 8s → 16s → 32s → 60s (cap)
- Jitter: random 0-2s added to prevent thundering herd
- Max retries: 5 for launch, 10 for describe/wait operations
- Triggers: `RequestLimitExceeded`, `Throttling`, `ThrottlingException`

### Error Reporting
All errors logged to `reports/<timestamp>/`:
- `launch_results.csv` — successful launches with timing
- `launch_errors.csv` — capacity failures, API errors
- `bootstrap_timeout.txt` — instances that didn't complete bootstrap
- `summary.md` — human-readable report
- `drscale.log` — full execution log

---

## 10. Files

| File | Purpose |
|------|---------|
| `setup.sh` | Creates S3 bucket, 10GB test file, discovers VPC, creates SG/key/IAM |
| `drscale.sh` | Main deployment script with fallback + retries + timing |
| `cleanup.sh` | Terminates all drscale instances, optionally removes infra |
| `api-limits-analysis.md` | This document |

---

## 11. Next Steps

1. ✅ API limits analysis (this document)
2. ✅ Deployment scripts built (setup.sh, drscale.sh, cleanup.sh)
3. ⬜ Refresh AWS credentials
4. ⬜ Run `./DRscale/setup.sh` to create S3 bucket + 10GB test file + discover VPC
5. ⬜ Run `./DRscale/drscale.sh --dry-run` to validate
6. ⬜ Run `./DRscale/drscale.sh` for real test (210 instances)
7. ⬜ Review reports, build measured-vs-calculated comparison table
