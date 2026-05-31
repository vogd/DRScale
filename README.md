# DRscale — EC2 DR Instance Provisioning Benchmark

Measures EC2 instance creation time, API throughput, health check latency, and S3 bootstrap speed across multiple AZs. Tests instance family fallback, API throttle handling, and generates reports comparing measured results against a 2,100-instance DR projection.

## Prerequisites

- AWS CLI v2 with valid credentials (`aws sts get-caller-identity`)
- bash 3.2+ (macOS default works)
- `jq` installed
- `python3` with `markdown` module (`pip3 install markdown`) — for HTML reports
- IAM permissions: EC2, S3, IAM, VPC

## Quick Start

```bash
# 1. Set AWS profile
export AWS_PROFILE=your-profile

# 2. Setup infrastructure
#    Creates: S3 bucket, S3 Gateway endpoint, SG, key pair, IAM role, 10GB test file
#    Prints the exact drscale.sh command with all parameters at the end
bash DRscale/setup.sh --region us-west-2

# 3. Run test (copy the command printed by setup.sh)
bash DRscale/drscale.sh \
  --region us-west-2 \
  --bucket <BUCKET> --key-name <KEY> --sg <SG_ID> \
  --subnets <SUB1,SUB2,SUB3> --ami <AMI_ID> \
  --iam-profile drscale-s3-reader \
  --per-az 70 --batch-size 50

# 4. View report
cat DRscale/reports/us-west-2/<timestamp>/summary.md

# 5. Generate HTML report
python3 -c "
import markdown
with open('DRscale/reports/us-west-2/<timestamp>/summary.md') as f: md=f.read()
html=markdown.markdown(md, extensions=['tables','fenced_code'])
open('DRscale/reports/us-west-2/<timestamp>/summary.html','w').write('''<!DOCTYPE html>
<html><head><meta charset=\"utf-8\"><title>DRscale Report</title>
<style>
body{font-family:-apple-system,Arial,sans-serif;max-width:960px;margin:40px auto;padding:0 20px;line-height:1.6;color:#333}
h1{border-bottom:2px solid #232f3e;padding-bottom:10px;color:#232f3e}
h2{color:#232f3e;margin-top:40px;border-bottom:1px solid #ddd;padding-bottom:5px}
table{border-collapse:collapse;width:100%;margin:20px 0}
th{background:#232f3e;color:white;padding:10px 12px;text-align:left}
td{padding:8px 12px;border-bottom:1px solid #ddd}
tr:hover{background:#f5f5f5}
pre{background:#1a1a2e;color:#e0e0e0;padding:16px;border-radius:6px}
code{background:#f4f4f4;padding:2px 6px;border-radius:3px}
strong{color:#232f3e}
hr{border:none;border-top:2px solid #ff9900;margin:30px 0}
</style></head><body>''' + html + '</body></html>')
"

# 6. Open HTML in browser (macOS)
open DRscale/reports/us-west-2/<timestamp>/summary.html

# 7. Cleanup
bash DRscale/cleanup.sh --region us-west-2              # terminate instances only
bash DRscale/cleanup.sh --region us-west-2 --remove-infra  # + delete S3, SG, IAM, key
```

## Scripts

| Script | Purpose |
|--------|---------|
| `setup.sh` | Creates S3 bucket, S3 Gateway endpoint, SG, key pair, IAM profile, 10GB test file |
| `drscale.sh` | Main provisioning benchmark with timing, health checks, bootstrap, and reporting |
| `cleanup.sh` | Terminates instances, optionally removes all infrastructure |

## drscale.sh Options

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `--region` | Yes | — | DR target region (e.g. us-west-2) |
| `--bucket` | Yes | — | S3 bucket name (same region) |
| `--key-name` | Yes | — | EC2 key pair name |
| `--sg` | Yes | — | Security group ID |
| `--subnets` | Yes | — | 3 subnet IDs, comma-separated (one per AZ) |
| `--ami` | Yes | — | AMI ID |
| `--iam-profile` | Yes | — | IAM instance profile name |
| `--per-az` | No | 70 | Instances per AZ |
| `--batch-size` | No | 10 | Max concurrent in-flight instances |
| `--skip-bootstrap` | No | — | Skip S3 data copy, measure instance+EBS only |
| `--resume` | No | — | Resume from last failed run |
| `--dry-run` | No | — | Validate without launching |

## Examples

```bash
# Quick validation — 3 instances, no S3 copy
bash DRscale/drscale.sh ... --per-az 1 --batch-size 1 --skip-bootstrap

# 3 instances with full bootstrap (S3 copy + unzip)
bash DRscale/drscale.sh ... --per-az 1 --batch-size 1

# 210 instances, batches of 50, skip S3 copy
bash DRscale/drscale.sh ... --per-az 70 --batch-size 50 --skip-bootstrap

# 600 instances, batches of 100, with S3 bootstrap
bash DRscale/drscale.sh ... --per-az 200 --batch-size 100

# Resume a failed run
bash DRscale/drscale.sh ... --per-az 200 --batch-size 100 --resume
```

## How It Works

### Instance Lifecycle (Rolling Pool)
1. `RunInstances` — fills pool to `--batch-size` instances + 4 EBS gp3 volumes + tags (single API call)
2. Wait for "running" state (~17-19s)
3. Poll health checks every 15s until 2/2 passed (~90-150s)
4. If bootstrap enabled: wait for `drscale-bootstrap=complete` tag (~150s for 10GB S3 copy + unzip)
5. Terminate each healthy instance as it completes, refill pool to `--batch-size` on next iteration
6. Resource bucket tracking: auto-waits if RunInstances token bucket would be exhausted (1000 burst, 2/sec refill)

### Bootstrap (UserData)
When `--skip-bootstrap` is NOT set, each instance runs a UserData script that:
- Formats and mounts 3 EBS data volumes
- Copies 10GB test file from S3 via Gateway endpoint (~68s at ~150 MB/s)
- Unzips the file (~81s)
- Tags itself with `drscale-bootstrap=complete` and timing breakdown
- Total: ~152s

### Error Handling
- **API throttling**: exponential backoff (1s→60s cap, max 5 retries)
- **Capacity errors**: fallback chain m5→m5a→m5n→m4→c5→c5a→c5n→c4→r5→r5a→r5n→r4
- **Health check failures**: instance terminated, replacement launched, loop protection prevents infinite retries
- **Resume**: `--resume` skips completed AZ instances, re-provisions only the deficit

## Output

Reports saved to `DRscale/reports/<region>/<timestamp>/`:

| File | Content |
|------|---------|
| `summary.md` | Full report: measured vs projected, API calls, bucket usage, limits |
| `summary.html` | HTML version (generated separately, see Quick Start step 5) |
| `bootstrap_timing.csv` | Per-instance bootstrap breakdown (ebs/s3/unzip/total) |
| `api_calls.log` | Every API call with timestamp |
| `az_timing.csv` | Per-AZ completion time |
| `batch_timing.csv` | Per-instance timing detail |
| `errors.csv` | Capacity errors, fallback events |
| `health_failures.csv` | Instances that failed health checks |
| `backoff_retries.csv` | API throttle retry events |
| `drscale.log` | Full execution log |

## State & Resume

State tracked in `DRscale/state/<region>/progress.csv`. On `--resume`, completed instances are skipped. To reset: run without `--resume` (state auto-clears).

## Measured Results Summary

| Batch Size | 600 inst time | Per AZ | Projected 2100 | Throttling |
|-----------|--------------|--------|---------------|------------|
| 50 (skip bootstrap) | 49.7m | ~16m | ~174m | Zero |
| 100 (skip bootstrap) | 38.0m | ~13m | ~133m | Zero |
| 100 (with bootstrap) | 38.0m | ~13m | ~133m | Zero |

Bootstrap adds zero overhead — S3 copy (68s) + unzip (81s) runs in parallel with health checks (~150s).

S3 copy speed: **~150 MB/s** via Gateway endpoint (in-region backbone, $0 transfer cost).

## Files

```
DRscale/
├── README.md                              # This file
├── setup.sh                               # Infrastructure setup
├── drscale.sh                             # Main provisioning benchmark
├── cleanup.sh                             # Terminate + optional infra removal
├── api-limits-analysis.md                 # API rate limit deep dive
├── customer-email-dr-scale-analysis.md    # Customer-facing report
├── customer-email-dr-scale-analysis.html  # HTML version (styled)
├── reports/                               # Per-run reports
└── state/                                 # Resume state files
```
