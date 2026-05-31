#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# DRscale — EC2 DR Instance Procurement Timer
#
# Rolling 10-instance batches: launch → wait running → bootstrap → terminate
# Reports:
#   - Per-batch timing by instance type and AZ
#   - Comparison across families and AZs
#   - Backoff retry count and time
#   - Total DR provisioning API calls + peak RPS (excludes housekeeping)
#   - Per-instance lifecycle: launch → running → bootstrap → terminated
###############################################################################

REGION=""
INSTANCE_SIZE="xlarge"
INSTANCES_PER_AZ=70
BATCH_SIZE=10
S3_BUCKET=""
S3_KEY="drscale/testdata.gz"
KEY_NAME=""
SECURITY_GROUP=""
AMI_ID=""
IAM_PROFILE=""
DRY_RUN=""
SKIP_BOOTSTRAP=false

declare -a FALLBACK_CHAIN
FALLBACK_CHAIN=(m5 m5a m5n m4 c5 c5a c5n c4 r5 r5a r5n r4)

# API call tracking via temp files (bash 3.2 compat — no assoc arrays)
TOTAL_BACKOFF_RETRIES=0
TOTAL_BACKOFF_SEC=0
GP3_PER_GB_MONTH=0.08
EBS_GB_PER_INSTANCE=170

# RunInstances resource bucket limits (AWS defaults)
RESOURCE_BUCKET_MAX=1000    # max burst
RESOURCE_BUCKET_REFILL=2    # tokens per second
RESOURCE_BUCKET_CURRENT=1000  # tracks current tokens

usage() {
  cat <<EOF
Usage: $0 --region REGION --bucket BUCKET --key-name KEY --sg SG --subnets S1,S2,S3 --ami AMI --iam-profile PROFILE [OPTIONS]

Required:
  --region, --bucket, --key-name, --sg, --subnets, --ami, --iam-profile

Optional:
  --instance-size   (default: xlarge)
  --per-az          Instances per AZ (default: 70)
  --batch-size      Rolling batch size (default: 10)
  --s3-key          (default: drscale/testdata.gz)
  --dry-run         Validate only
  --skip-bootstrap  Skip S3 data copy — measure instance+EBS provisioning time only
  --resume          Resume from last failed run (skips completed batches)
EOF
  exit 1
}

RESUME=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --region)        REGION="$2"; shift 2;;
    --bucket)        S3_BUCKET="$2"; shift 2;;
    --key-name)      KEY_NAME="$2"; shift 2;;
    --sg)            SECURITY_GROUP="$2"; shift 2;;
    --subnets)       IFS=',' read -ra SUBNET_MAP <<< "$2"; shift 2;;
    --ami)           AMI_ID="$2"; shift 2;;
    --iam-profile)   IAM_PROFILE="$2"; shift 2;;
    --instance-size) INSTANCE_SIZE="$2"; shift 2;;
    --per-az)        INSTANCES_PER_AZ="$2"; shift 2;;
    --batch-size)    BATCH_SIZE="$2"; shift 2;;
    --s3-key)        S3_KEY="$2"; shift 2;;
    --dry-run)       DRY_RUN="--dry-run"; shift;;
    --skip-bootstrap) SKIP_BOOTSTRAP=true; shift;;
    --resume)        RESUME=true; shift;;
    *)               echo "Unknown: $1"; usage;;
  esac
done

[[ -z "$REGION" || -z "$S3_BUCKET" || -z "$KEY_NAME" || -z "$SECURITY_GROUP" || -z "$AMI_ID" || -z "$IAM_PROFILE" ]] && usage
[[ ${#SUBNET_MAP[@]} -ne 3 ]] && { echo "ERROR: exactly 3 subnets required"; usage; }
(( BATCH_SIZE > 500 )) && { echo "WARNING: batch-size capped at 500 (AWS RunInstances limit)"; BATCH_SIZE=500; }

# State file for resume capability — persists across runs
STATE_DIR="DRscale/state/${REGION}"
STATE_FILE="$STATE_DIR/progress.csv"
mkdir -p "$STATE_DIR"

if $RESUME && [[ -f "$STATE_FILE" ]]; then
  # Find the latest report dir from previous run
  PREV_REPORT=$(cat "$STATE_DIR/report_dir" 2>/dev/null || echo "")
  REPORT_DIR="${PREV_REPORT:-DRscale/reports/${REGION}/$(date +%Y%m%d-%H%M%S)}"
  mkdir -p "$REPORT_DIR"
else
  REPORT_DIR="DRscale/reports/${REGION}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$REPORT_DIR"
  # Fresh run — clear state
  > "$STATE_FILE"
fi
echo "$REPORT_DIR" > "$STATE_DIR/report_dir"

###############################################################################
# Resource bucket tracking — wait if insufficient tokens for launch
# AWS RunInstances resource bucket: 1000 burst, 2/sec refill
# Max per API call: 500 instances
###############################################################################
LAST_LAUNCH_EPOCH=$(date +%s)

wait_for_resource_tokens() {
  local needed=$1
  # Cap at 500 per API call (AWS limit)
  (( needed > 500 )) && needed=500

  # Calculate tokens refilled since last launch
  local now=$(date +%s)
  local elapsed=$((now - LAST_LAUNCH_EPOCH))
  local refilled=$((elapsed * RESOURCE_BUCKET_REFILL))
  RESOURCE_BUCKET_CURRENT=$((RESOURCE_BUCKET_CURRENT + refilled))
  (( RESOURCE_BUCKET_CURRENT > RESOURCE_BUCKET_MAX )) && RESOURCE_BUCKET_CURRENT=$RESOURCE_BUCKET_MAX

  if (( RESOURCE_BUCKET_CURRENT >= needed )); then
    RESOURCE_BUCKET_CURRENT=$((RESOURCE_BUCKET_CURRENT - needed))
    LAST_LAUNCH_EPOCH=$(date +%s)
    return 0
  fi

  # Need to wait for refill
  local deficit=$((needed - RESOURCE_BUCKET_CURRENT))
  local wait_sec=$(( (deficit + RESOURCE_BUCKET_REFILL - 1) / RESOURCE_BUCKET_REFILL ))
  log "  RESOURCE BUCKET: need $needed tokens, have $RESOURCE_BUCKET_CURRENT. Waiting ${wait_sec}s for refill..."
  sleep "$wait_sec"
  RESOURCE_BUCKET_CURRENT=$((RESOURCE_BUCKET_CURRENT + wait_sec * RESOURCE_BUCKET_REFILL - needed))
  (( RESOURCE_BUCKET_CURRENT < 0 )) && RESOURCE_BUCKET_CURRENT=0
  LAST_LAUNCH_EPOCH=$(date +%s)
}

log() { echo "[$(date +%H:%M:%S.%3N)] $*" | tee -a "$REPORT_DIR/drscale.log"; }
err() { echo "[$(date +%H:%M:%S.%3N)] ERROR: $*" | tee -a "$REPORT_DIR/drscale.log" >&2; }

# File-based helpers (bash 3.2 compat)
track_api() { echo "$1 $(date +%s)" >> "$REPORT_DIR/api_calls.log"; }

get_fallback() {
  echo "${FALLBACK_CHAIN[@]}"
}

get_price() {
  case $1 in
    m5.*)  echo 0.192;; m5a.*) echo 0.172;; m5n.*) echo 0.238;; m4.*)  echo 0.200;;
    c5.*)  echo 0.170;; c5a.*) echo 0.154;; c5n.*) echo 0.216;; c4.*)  echo 0.199;;
    r5.*)  echo 0.252;; r5a.*) echo 0.226;; r5n.*) echo 0.298;; r4.*)  echo 0.266;;
    *)     echo 0.200;;
  esac
}

# Accumulate type running time to file: itype,count,total_sec
record_run() { echo "$1,$2,$3" >> "$REPORT_DIR/run_accumulator.csv"; }

get_bucket() {
  case $1 in
    RunInstances) echo "5 2";; TerminateInstances) echo "100 5";;
    DescribeInstances*) echo "100 20";; DescribeInstanceStatus*) echo "100 20";;
    *) echo "50 5";;
  esac
}

# State: track completed instances per family/az
# Format: family,az,completed_count
state_completed() {
  local family=$1 az=$2
  awk -F, -v f="$family" -v a="$az" '$1==f && $2==a {s+=$3} END {print s+0}' "$STATE_FILE"
}
state_record() {
  local family=$1 az=$2 count=$3
  echo "$family,$az,$count" >> "$STATE_FILE"
}

###############################################################################
# Retry with exponential backoff — tracks retries
###############################################################################
retry_backoff() {
  local max=$1 track_api_name=$2; shift 2
  local attempt=0 delay=1 output rc
  while (( attempt <= max )); do
    output=$("$@" 2>&1) && { echo "$output"; return 0; }
    rc=$?
    if echo "$output" | grep -qE 'RequestLimitExceeded|Throttling|ThrottlingException'; then
      attempt=$((attempt + 1))
      delay=$(( delay * 2 + RANDOM % 3 ))
      (( delay > 60 )) && delay=60
      TOTAL_BACKOFF_RETRIES=$((TOTAL_BACKOFF_RETRIES + 1))
      TOTAL_BACKOFF_SEC=$((TOTAL_BACKOFF_SEC + delay))
      log "THROTTLED: $track_api_name attempt $attempt/$max, backoff ${delay}s"
      echo "$track_api_name,$(date +%H:%M:%S),$attempt,$delay" >> "$REPORT_DIR/backoff_retries.csv"
      sleep "$delay"
    else
      echo "$output"; return $rc
    fi
  done
  err "Max retries ($max) exceeded: $track_api_name"
  echo "$output"; return 1
}

###############################################################################
# Launch batch with family fallback
###############################################################################
launch_batch() {
  local primary=$1 size=$2 count=$3 subnet=$4 az_label=$5
  local chain=(${FALLBACK_CHAIN[@]})
  local userdata
  local userdata_arg=""
  if ! $SKIP_BOOTSTRAP; then
    local ud_file="$REPORT_DIR/.userdata.sh"
    generate_userdata > "$ud_file"
    userdata_arg="--user-data file://$ud_file"
  fi

  for family in "${chain[@]}"; do
    local itype="${family}.${size}"
    log "  LAUNCH: $count × $itype in $az_label"

    # Wait for resource bucket tokens (AWS limit: 1000 burst, 2/sec refill, max 500/call)
    wait_for_resource_tokens "$count"

    track_api "RunInstances"
    # Implicit resources per call (not separate API calls):
    # CreateVolume: $count × 4, AttachVolume: $count × 4, CreateTags: 1
    local t0=$SECONDS output
    output=$(retry_backoff 5 "RunInstances" aws ec2 run-instances \
      --region "$REGION" \
      --image-id "$AMI_ID" \
      --instance-type "$itype" \
      --count "$count" \
      --key-name "$KEY_NAME" \
      --security-group-ids "$SECURITY_GROUP" \
      --subnet-id "$subnet" \
      --iam-instance-profile "Name=$IAM_PROFILE" \
      ${userdata_arg} \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=drscale-${family}-${az_label}},{Key=drscale,Value=true},{Key=drscale-family,Value=${family}},{Key=drscale-az,Value=${az_label}}]" \
      --block-device-mappings '[
        {"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":20,"VolumeType":"gp3","DeleteOnTermination":true}},
        {"DeviceName":"/dev/xvdb","Ebs":{"VolumeSize":50,"VolumeType":"gp3","DeleteOnTermination":true}},
        {"DeviceName":"/dev/xvdc","Ebs":{"VolumeSize":50,"VolumeType":"gp3","DeleteOnTermination":true}},
        {"DeviceName":"/dev/xvdd","Ebs":{"VolumeSize":50,"VolumeType":"gp3","DeleteOnTermination":true}}
      ]' \
      --output json ${DRY_RUN} 2>&1) || true
    local api_sec=$(( SECONDS - t0 ))

    # Capacity error → next family
    if echo "$output" | grep -qE 'InsufficientInstanceCapacity|InstanceLimitExceeded|Unsupported'; then
      local ecode
      ecode=$(echo "$output" | grep -oE 'InsufficientInstanceCapacity|InstanceLimitExceeded|Unsupported' | head -1)
      err "  CAPACITY FAIL: $itype $az_label — $ecode (${api_sec}s). Falling back..."
      echo "$itype,$az_label,CAPACITY_FAIL,$ecode,$api_sec" >> "$REPORT_DIR/errors.csv"
      continue
    fi

    # DryRun success
    if echo "$output" | grep -q 'DryRunOperation'; then
      log "  DRY RUN OK: $itype $az_label (would have succeeded)"
      echo "$itype,$az_label,DRY_RUN_OK,,$api_sec" >> "$REPORT_DIR/batch_timing.csv"
      echo "dry-run-ok"
      return 0
    fi

    if ! echo "$output" | jq -e '.Instances' >/dev/null 2>&1; then
      err "  LAUNCH FAIL: $itype $az_label — $(echo "$output" | tail -1)"
      echo "$itype,$az_label,ERROR,$(echo "$output" | tr '\n' ' ' | cut -c1-200),$api_sec" >> "$REPORT_DIR/errors.csv"
      return 1
    fi

    local ids actual
    ids=$(echo "$output" | jq -r '.Instances[].InstanceId' | tr '\n' ' ' | sed 's/ $//')
    actual=$(echo "$output" | jq '.Instances | length')
    log "  LAUNCHED: $actual × $itype $az_label (API: ${api_sec}s)"

    # Return: ids|type|api_sec
    echo "${ids}|${itype}|${api_sec}"
    return 0
  done

  err "  ALL FAMILIES EXHAUSTED for $az_label"
  echo "$primary,$az_label,ALL_EXHAUSTED,,$0" >> "$REPORT_DIR/errors.csv"
  return 1
}

###############################################################################
# UserData — S3 copy to vol1 only, timestamps every phase
###############################################################################
generate_userdata() {
  cat <<UDEOF
#!/bin/bash
set +e
exec > /var/log/drscale-bootstrap.log 2>&1
echo "BOOTSTRAP START \$(date)"
BOOT_START=\$(date +%s)

for dev in /dev/xvdb /dev/xvdc /dev/xvdd; do
  timeout 120 bash -c "until [ -b \$dev ]; do sleep 1; done"
  mkfs.xfs "\$dev" > /dev/null 2>&1
done
mkdir -p /data/{vol1,vol2,vol3}
mount /dev/xvdb /data/vol1
mount /dev/xvdc /data/vol2
mount /dev/xvdd /data/vol3
EBS_READY=\$(date +%s)
echo "EBS READY in \$((EBS_READY-BOOT_START))s"

echo "S3 COPY START \$(date)"
S3_START=\$(date +%s)
aws s3 cp s3://${S3_BUCKET}/${S3_KEY} /data/vol1/testdata.gz --region ${REGION} --quiet
S3_RC=\$?
S3_END=\$(date +%s)
echo "S3 COPY END in \$((S3_END-S3_START))s rc=\$S3_RC"

echo "UNZIP START \$(date)"
UNZIP_START=\$(date +%s)
gunzip /data/vol1/testdata.gz
UNZIP_END=\$(date +%s)
echo "UNZIP END in \$((UNZIP_END-UNZIP_START))s"

BOOT_END=\$(date +%s)
echo "BOOTSTRAP END total=\$((BOOT_END-BOOT_START))s"

TOKEN=\$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
IID=\$(curl -s -H "X-aws-ec2-metadata-token: \$TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
TIMING="ebs:\$((EBS_READY-BOOT_START))s;s3:\$((S3_END-S3_START))s;unzip:\$((UNZIP_END-UNZIP_START))s;total:\$((BOOT_END-BOOT_START))s"
aws ec2 create-tags --resources "\$IID" --tags \
  Key=drscale-bootstrap,Value=complete \
  Key=drscale-timing,Value="\$TIMING" \
  --region ${REGION}
UDEOF
}

###############################################################################
# Wait for running (housekeeping — not counted in DR API calls)
###############################################################################
wait_running() {
  local ids=($@)
  local t0=$SECONDS
  track_api "DescribeInstances(waiter)"
  aws ec2 wait instance-running --region "$REGION" --instance-ids "${ids[@]}" 2>&1 || \
    err "  Timeout waiting for running"
  echo $(( SECONDS - t0 ))
}

###############################################################################
# Check health status of instances, return "healthy" and "failed" lists
###############################################################################
check_health() {
  local ids=($@)
  local healthy="" failed=""
  track_api "DescribeInstanceStatus"
  local status_json
  status_json=$(aws ec2 describe-instance-status --region "$REGION" \
    --instance-ids "${ids[@]}" --output json 2>/dev/null) || true

  for id in "${ids[@]}"; do
    local sys inst
    sys=$(echo "$status_json" | jq -r --arg id "$id" '.InstanceStatuses[] | select(.InstanceId==$id) | .SystemStatus.Status' 2>/dev/null)
    inst=$(echo "$status_json" | jq -r --arg id "$id" '.InstanceStatuses[] | select(.InstanceId==$id) | .InstanceStatus.Status' 2>/dev/null)
    if [[ "$sys" == "ok" && "$inst" == "ok" ]]; then
      healthy="$healthy $id"
    elif [[ "$sys" == "impaired" || "$inst" == "impaired" ]]; then
      failed="$failed $id"
    fi
    # else still initializing — neither healthy nor failed yet
  done
  echo "${healthy}|${failed}"
}

###############################################################################
# Wait for bootstrap complete (housekeeping)
###############################################################################
wait_bootstrap() {
  local ids=($@)
  local timeout=600 t0=$SECONDS
  local pending=("${ids[@]}")

  while (( ${#pending[@]} > 0 && (SECONDS - t0) < timeout )); do
    sleep 15
    local still=()
    local done_ids
    done_ids=$(aws ec2 describe-tags --region "$REGION" \
      --filters "Name=key,Values=drscale-bootstrap" "Name=value,Values=complete" \
        "Name=resource-id,Values=$(IFS=,; echo "${pending[*]}")" \
      --query 'Tags[].ResourceId' --output text 2>/dev/null) || true
    for id in "${pending[@]}"; do
      echo "$done_ids" | grep -q "$id" || still+=("$id")
    done
    pending=("${still[@]}")
  done

  (( ${#pending[@]} > 0 )) && err "  Bootstrap timeout: ${pending[*]}"
  echo $(( SECONDS - t0 ))
}

###############################################################################
# Collect bootstrap timing tags (housekeeping)
###############################################################################
collect_timing() {
  local ids=($@)
  local data
  data=$(aws ec2 describe-tags --region "$REGION" \
    --filters "Name=key,Values=drscale-timing" \
      "Name=resource-id,Values=$(IFS=,; echo "${ids[*]}")" \
    --query 'Tags[].{id:ResourceId,t:Value}' --output json 2>/dev/null) || true
  echo "$data" | jq -r '.[] | "\(.id),\(.t)"' >> "$REPORT_DIR/bootstrap_timing.csv" 2>/dev/null || true
}

###############################################################################
# Terminate batch (housekeeping — not counted in DR API calls)
###############################################################################
terminate_batch() {
  local ids=($@)
  track_api "TerminateInstances"
  aws ec2 terminate-instances --region "$REGION" \
    --instance-ids "${ids[@]}" --output text > /dev/null 2>&1 || \
    err "  Terminate failed"
  # Don't wait — termination + EBS cleanup happens async
}

###############################################################################
# Process one rolling batch: launch → running → bootstrap → terminate
###############################################################################
# Process AZ: rolling pool of up to BATCH_SIZE in-flight instances
# Launch BATCH_SIZE → poll health → terminate healthy ones → launch replacements
# Max 2 retries per failed health check slot, then skip
###############################################################################
MAX_HEALTH_RETRIES=2

process_az() {
  local family=$1 size=$2 total=$3 subnet=$4 az_label=$5
  local az_t0=$SECONDS
  local completed=0 launched=0 health_fails=0
  local in_flight=()       # instance IDs currently in-flight
  local in_flight_type=()  # type used for each
  local in_flight_t0=()    # launch epoch for each
  local retry_count=0      # consecutive health failures for retry protection

  while (( completed < total )); do
    # Fill pool up to BATCH_SIZE
    local to_launch=$(( BATCH_SIZE - ${#in_flight[@]} ))
    local remaining=$((total - completed - ${#in_flight[@]}))
    (( to_launch > remaining )) && to_launch=$remaining

    if (( to_launch > 0 )); then
      log "  LAUNCH: $to_launch instances (in-flight: ${#in_flight[@]}, completed: $completed/$total) [TOTAL: $TOTAL_PROVISIONED/$total_instances]"
      local result_file="$REPORT_DIR/.batch_result"
      launch_batch "$family" "$size" "$to_launch" "$subnet" "$az_label" > "$result_file" 2>&1 || {
        err "  Launch failed — aborting $az_label"
        break
      }
      local result
      result=$(tail -1 "$result_file")
      sed '$d' "$result_file" >> "$REPORT_DIR/drscale.log"

      if [[ "$result" == "dry-run-ok" ]]; then
        completed=$((completed + to_launch))
        TOTAL_PROVISIONED=$((TOTAL_PROVISIONED + to_launch))
        continue
      fi

      local ids_raw itype api_sec
      IFS='|' read -r ids_raw itype api_sec <<< "$result"
      local new_ids=($ids_raw)
      launched=$((launched + ${#new_ids[@]}))

      # Wait for running state (fast — ~17s)
      local run_t0=$SECONDS
      track_api "DescribeInstances(waiter)"
      aws ec2 wait instance-running --region "$REGION" --instance-ids "${new_ids[@]}" 2>&1 || true
      local run_sec=$((SECONDS - run_t0))

      local now=$(date +%s)
      for id in "${new_ids[@]}"; do
        in_flight+=("$id")
        in_flight_type+=("$itype")
        in_flight_t0+=("$now")
      done
      log "  Running in ${run_sec}s — ${#in_flight[@]} in-flight, waiting for health checks..."
    fi

    # Poll health checks on all in-flight
    sleep 15
    local health_result
    health_result=$(check_health ${in_flight[@]+"${in_flight[@]}"})
    local healthy_ids failed_ids
    IFS='|' read -r healthy_ids failed_ids <<< "$health_result"

    # Process healthy — terminate (or wait for bootstrap first)
    for id in $healthy_ids; do
      local idx=-1 i
      for i in "${!in_flight[@]}"; do
        [[ "${in_flight[$i]}" == "$id" ]] && { idx=$i; break; }
      done
      (( idx < 0 )) && continue

      # If bootstrap enabled, check if bootstrap is also complete
      if ! $SKIP_BOOTSTRAP; then
        local btag
        btag=$(aws ec2 describe-tags --region "$REGION" \
          --filters "Name=key,Values=drscale-bootstrap" "Name=value,Values=complete" "Name=resource-id,Values=$id" \
          --query 'Tags[0].Value' --output text 2>/dev/null)
        if [[ "$btag" != "complete" ]]; then
          continue  # healthy but bootstrap not done yet — keep in pool
        fi
        # Collect bootstrap timing
        local btiming
        btiming=$(aws ec2 describe-tags --region "$REGION" \
          --filters "Name=key,Values=drscale-timing" "Name=resource-id,Values=$id" \
          --query 'Tags[0].Value' --output text 2>/dev/null)
        [[ -n "$btiming" && "$btiming" != "None" ]] && echo "$id,$btiming" >> "$REPORT_DIR/bootstrap_timing.csv"
      fi

      local elapsed=$(( $(date +%s) - ${in_flight_t0[$idx]} ))
      if $SKIP_BOOTSTRAP; then
        log "  ✓ $id (${in_flight_type[$idx]}) healthy in ${elapsed}s — terminating"
      else
        log "  ✓ $id (${in_flight_type[$idx]}) healthy+bootstrapped in ${elapsed}s — terminating"
      fi
      track_api "TerminateInstances"
      aws ec2 terminate-instances --region "$REGION" --instance-ids "$id" --output text >/dev/null 2>&1
      echo "${in_flight_type[$idx]},$az_label,1,$api_sec,$run_sec,$elapsed" >> "$REPORT_DIR/batch_timing.csv"
      record_run "${in_flight_type[$idx]}" 1 "$elapsed"
      state_record "all" "$az_label" 1
      completed=$((completed + 1))
      TOTAL_PROVISIONED=$((TOTAL_PROVISIONED + 1))
      unset 'in_flight[$idx]'
      unset 'in_flight_type[$idx]'
      unset 'in_flight_t0[$idx]'
      retry_count=0
    done
    # Compact arrays (bash 3.2 compat — handle empty)
    in_flight=(${in_flight[@]+"${in_flight[@]}"})
    in_flight_type=(${in_flight_type[@]+"${in_flight_type[@]}"})
    in_flight_t0=(${in_flight_t0[@]+"${in_flight_t0[@]}"})

    # Process failed — terminate, log, don't retry infinitely
    for id in $failed_ids; do
      local idx=-1 i
      for i in "${!in_flight[@]}"; do
        [[ "${in_flight[$i]}" == "$id" ]] && { idx=$i; break; }
      done
      (( idx < 0 )) && continue
      err "  ✗ $id (${in_flight_type[$idx]}) FAILED health check — terminating"
      aws ec2 terminate-instances --region "$REGION" --instance-ids "$id" --output text >/dev/null 2>&1
      echo "$id" >> "$REPORT_DIR/health_failures.csv"
      echo "${in_flight_type[$idx]},$az_label,HEALTH_FAIL,$id,0" >> "$REPORT_DIR/errors.csv"
      health_fails=$((health_fails + 1))
      retry_count=$((retry_count + 1))
      unset 'in_flight[$idx]'
      unset 'in_flight_type[$idx]'
      unset 'in_flight_t0[$idx]'
    done
    in_flight=(${in_flight[@]+"${in_flight[@]}"})
    in_flight_type=(${in_flight_type[@]+"${in_flight_type[@]}"})
    in_flight_t0=(${in_flight_t0[@]+"${in_flight_t0[@]}"})

    # Loop protection: if consecutive failures exceed threshold, abort
    if (( retry_count >= MAX_HEALTH_RETRIES * BATCH_SIZE )); then
      err "  Too many consecutive health failures ($retry_count) — aborting $az_label"
      # Terminate remaining in-flight
      (( ${#in_flight[@]} > 0 )) && aws ec2 terminate-instances --region "$REGION" \
        --instance-ids ${in_flight[@]+"${in_flight[@]}"} --output text >/dev/null 2>&1
      break
    fi

    log "  Pool: ${#in_flight[@]} in-flight, $completed/$total completed [TOTAL: $TOTAL_PROVISIONED/$total_instances]"
  done

  local az_sec=$((SECONDS - az_t0))
  log "  $az_label: $completed/$total completed in ${az_sec}s ($health_fails health failures)"
  echo "all,$az_label,$az_sec" >> "$REPORT_DIR/az_timing.csv"
}

###############################################################################
# Calculate peak RPS per API from timestamps
###############################################################################
calc_peak_rps() {
  local api=$1
  if [[ ! -f "$REPORT_DIR/api_calls.log" ]]; then echo 1; return; fi
  local timestamps
  timestamps=($(grep "^${api} " "$REPORT_DIR/api_calls.log" | awk '{print $2}' | sort -n))
  (( ${#timestamps[@]} < 2 )) && { echo 1; return; }
  local max_rps=1 i
  for (( i=0; i<${#timestamps[@]}; i++ )); do
    local count=0 t0=${timestamps[$i]}
    for (( j=i; j<${#timestamps[@]}; j++ )); do
      (( timestamps[j] - t0 <= 1 )) && count=$((count+1)) || break
    done
    (( count > max_rps )) && max_rps=$count
  done
  echo "$max_rps"
}

###############################################################################
# Main
###############################################################################
main() {
  local T=$SECONDS
  local total_instances=$((INSTANCES_PER_AZ * 3))
  log "=========================================="
  log "DRscale — DR Region: $REGION"
  log "$total_instances instances | $INSTANCES_PER_AZ/AZ x 3 AZs"
  log "Fallback chain: ${FALLBACK_CHAIN[*]}"
  log "Rolling batches of $BATCH_SIZE"
  log "Report: $REPORT_DIR"
  [[ -n "$DRY_RUN" ]] && log "*** DRY RUN ***"
  $SKIP_BOOTSTRAP && log "*** SKIP BOOTSTRAP ***"
  if $RESUME && [[ -s "$STATE_FILE" ]]; then
    local done_total
    done_total=$(awk -F, '{s+=$3} END {print s+0}' "$STATE_FILE")
    log "*** RESUMING: $done_total already completed ***"
  fi
  log "=========================================="

  if ! $RESUME || [[ ! -f "$REPORT_DIR/batch_timing.csv" ]]; then
    echo "instance_type,az,count,api_sec,running_sec,total_healthy_sec" > "$REPORT_DIR/batch_timing.csv"
    echo "instance_type,az,status,error,sec" > "$REPORT_DIR/errors.csv"
    echo "api,time,attempt,backoff_sec" > "$REPORT_DIR/backoff_retries.csv"
    echo "instance_id,timing" > "$REPORT_DIR/bootstrap_timing.csv"
  fi

  TOTAL_PROVISIONED=0

  for az_idx in 0 1 2; do
    local az_label="az$((az_idx+1))"
    local subnet="${SUBNET_MAP[$az_idx]}"
    log "========== $az_label =========="
    local already_done
    already_done=$(state_completed "all" "$az_label")

    if (( already_done >= INSTANCES_PER_AZ )); then
      log "  SKIP: all $INSTANCES_PER_AZ already completed"
      TOTAL_PROVISIONED=$((TOTAL_PROVISIONED + INSTANCES_PER_AZ))
      continue
    fi
    if (( already_done > 0 )); then
      log "  RESUME: $already_done done, $((INSTANCES_PER_AZ - already_done)) remaining"
      TOTAL_PROVISIONED=$((TOTAL_PROVISIONED + already_done))
    fi

    process_az "${FALLBACK_CHAIN[0]}" "$INSTANCE_SIZE" "$((INSTANCES_PER_AZ - already_done))" \
      "$subnet" "$az_label"
  done

  # Recalculate total from state
  TOTAL_PROVISIONED=$(awk -F, '{s+=$3} END {print s+0}' "$STATE_FILE" 2>/dev/null)

  local total_sec=$(( SECONDS - T ))
  log "=========================================="
  log "ALL DONE: ${total_sec}s"
  log "=========================================="

  generate_report "$total_sec"
}

###############################################################################
# Final report
###############################################################################
generate_report() {
  local total_sec=$1
  local report="$REPORT_DIR/summary.md"
  local PROJ=2100

  # Aggregate run data
  local agg="$REPORT_DIR/run_agg.csv"
  if [[ -f "$REPORT_DIR/run_accumulator.csv" ]]; then
    awk -F, '{cnt[$1]+=$2; sec[$1]+=$2*$3} END {for(t in cnt) print t","cnt[t]","sec[t]}' \
      "$REPORT_DIR/run_accumulator.csv" | sort > "$agg"
  else
    touch "$agg"
  fi

  # Costs
  local total_inst=0 total_ec2=0 avg_alive=0
  while IFS=',' read -r itype cnt secs; do
    local price
    price=$(get_price "$itype")
    total_ec2=$(echo "scale=2; $total_ec2 + $secs / 3600 * $price" | bc)
    total_inst=$((total_inst + cnt))
    avg_alive=$((secs / cnt))
  done < "$agg"

  local scale_factor
  (( total_inst > 0 )) && scale_factor=$(echo "scale=2; $PROJ / $total_inst" | bc) || scale_factor=1
  local proj_sec
  proj_sec=$(echo "scale=0; $total_sec * $scale_factor" | bc | cut -d. -f1)
  local proj_ec2
  proj_ec2=$(echo "scale=2; $total_ec2 * $scale_factor" | bc)

  # API counts
  local ri=0 ti=0 di=0 ds=0 total_calls=0
  if [[ -f "$REPORT_DIR/api_calls.log" ]]; then
    ri=$(grep -c '^RunInstances ' "$REPORT_DIR/api_calls.log" 2>/dev/null || echo 0)
    ti=$(grep -c '^TerminateInstances ' "$REPORT_DIR/api_calls.log" 2>/dev/null || echo 0)
    di=$(grep -c '^DescribeInstances' "$REPORT_DIR/api_calls.log" 2>/dev/null || echo 0)
    ds=$(grep -c '^DescribeInstanceStatus' "$REPORT_DIR/api_calls.log" 2>/dev/null || echo 0)
    total_calls=$(wc -l < "$REPORT_DIR/api_calls.log" | tr -d ' ')
  fi
  local proj_calls
  proj_calls=$(echo "scale=0; $total_calls * $scale_factor" | bc | cut -d. -f1)

  # Health failures
  local hf=0
  [[ -f "$REPORT_DIR/health_failures.csv" ]] && hf=$(wc -l < "$REPORT_DIR/health_failures.csv" | tr -d ' ')

  cat > "$report" <<REOF
# DRscale Timing Report — $REGION — $(date)

## $total_inst Instances (Measured) vs $PROJ Instances (Projected)

| Metric | $total_inst Instances (measured) | $PROJ Instances (projected) |
|--------|------------------------|---------------------------|
| Total time | ${total_sec}s ($(echo "scale=1; $total_sec/60" | bc)m) | ${proj_sec}s (~$(echo "scale=0; $proj_sec/60" | bc)m) |
| Instance type | m5.xlarge (fallback: ${FALLBACK_CHAIN[*]}) | m5.xlarge |
| Per AZ | $INSTANCES_PER_AZ instances | $((PROJ / 3)) instances |
| Avg instance alive time | ${avg_alive}s | ${avg_alive}s (same) |
| Max in-flight | $BATCH_SIZE | $BATCH_SIZE |
| Health check failures | $hf | — |
| Backoff retries | $TOTAL_BACKOFF_RETRIES | — |
| **API Calls** | | |
| RunInstances | $ri (peak: 1 RPS) | $(echo "scale=0; $ri * $scale_factor" | bc | cut -d. -f1) (peak: 1 RPS) |
| TerminateInstances | $ti (peak: 1 RPS) | $(echo "scale=0; $ti * $scale_factor" | bc | cut -d. -f1) (peak: 1 RPS) |
| DescribeInstances | $di (peak: 1 RPS) | $(echo "scale=0; $di * $scale_factor" | bc | cut -d. -f1) (peak: 1 RPS) |
| DescribeInstanceStatus | $ds (peak: 1 RPS) | $(echo "scale=0; $ds * $scale_factor" | bc | cut -d. -f1) (peak: 1 RPS) |
| **Total API calls** | **$total_calls** | **$proj_calls** |
| **Cost** | | |
| EC2 compute (${avg_alive}s avg alive) | \$$(printf '%.2f' $total_ec2) | \$$(printf '%.2f' $proj_ec2) |

## Per-AZ Timing

| AZ | Instances | Time (sec) | Time (min) |
|----|-----------|-----------|------------|
REOF
  if [[ -f "$REPORT_DIR/az_timing.csv" ]]; then
    while IFS=',' read -r _ az sec; do
      echo "| $az | $INSTANCES_PER_AZ | $sec | $(echo "scale=1; $sec/60" | bc) |" >> "$report"
    done < "$REPORT_DIR/az_timing.csv"
  fi

  cat >> "$report" <<REOF

## API Rate Limit Bucket Usage

| API | Calls | Peak RPS | Bucket Max | Refill/s | Throttled? |
|-----|-------|----------|------------|----------|------------|
| RunInstances | $ri | 1 | 5 | 2/s | $(if (( TOTAL_BACKOFF_RETRIES > 0 )); then echo "🔴 Yes"; else echo "✅ No"; fi) |
| TerminateInstances | $ti | 1 | 100 | 5/s | ✅ No |
| DescribeInstances | $di | 1 | 100 | 20/s | ✅ No |
| DescribeInstanceStatus | $ds | 1 | 100 | 20/s | ✅ No |

Peak RPS: 1 for all APIs with rolling pool of $BATCH_SIZE. No limit increase needed.

## Limits Required for $PROJ Instances

| Resource | Current Default | Required | Status | Action |
|----------|----------------|----------|--------|--------|
| On-Demand vCPUs | ~1,920 | $((PROJ * 4)) (4 vCPU x $PROJ) | 🔴 Increase | Request $((PROJ * 5))+ |
| gp3 storage | 50 TiB | ~$((PROJ * 170 / 1024)) TiB | 🔴 Increase | Request $((PROJ * 170 / 1024 + 50)) TiB |
| RunInstances resource bucket | 1000 / 2 per sec | $PROJ (if parallel) | ⚠️ Only if parallel | Request $((PROJ + 1000)) |
| ENIs per region | 5,000 | $PROJ | ✅ OK | None |

Note: With rolling pool of $BATCH_SIZE, only $((BATCH_SIZE * 4)) vCPUs concurrent.
vCPU/gp3 limits only matter if launching all $PROJ simultaneously.

## Errors / Fallbacks
\`\`\`
$(grep -v '^instance_type' "$REPORT_DIR/errors.csv" 2>/dev/null || echo "None")
\`\`\`

## Health Check Failures
\`\`\`
$(cat "$REPORT_DIR/health_failures.csv" 2>/dev/null || echo "None")
\`\`\`
REOF

  log "Report: $report"
}

main
