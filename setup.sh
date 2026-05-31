#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# DRscale Setup — Creates S3 bucket, test file, discovers VPC, ensures
#                 S3 Gateway endpoint for in-region backbone traffic
#
# Usage: ./setup.sh --region us-west-2 [--vpc vpc-xxx] [--gz-size 10]
###############################################################################

REGION=""
VPC_ID=""
BUCKET_PREFIX="drscale-testdata"
S3_KEY="drscale/testdata.gz"
GZ_SIZE_GB=10

usage() {
  cat <<EOF
Usage: $0 --region REGION [OPTIONS]

Required:
  --region    DR target region (e.g. us-west-2, eu-west-1)

Optional:
  --vpc       VPC ID (default: auto-detect default VPC)
  --gz-size   Test file size in GB (default: 10)
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --region)   REGION="$2"; shift 2;;
    --vpc)      VPC_ID="$2"; shift 2;;
    --gz-size)  GZ_SIZE_GB="$2"; shift 2;;
    *)          echo "Unknown: $1"; usage;;
  esac
done

[[ -z "$REGION" ]] && { echo "ERROR: --region is required"; usage; }

log() { echo "[$(date +%H:%M:%S)] $*"; }
err() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
BUCKET_NAME="${BUCKET_PREFIX}-${ACCOUNT_ID}-${REGION}"

log "Region:  $REGION"
log "Account: $ACCOUNT_ID"
log "Bucket:  $BUCKET_NAME"
SETUP_START=$SECONDS

# Step timing tracker
declare -a STEP_NAMES STEP_TIMES STEP_APIS STEP_STATUS
step_done() {
  local idx=$1 name=$2 secs=$3 apis=$4 status=${5:-"✅ OK"}
  STEP_NAMES[$idx]="$name"
  STEP_TIMES[$idx]="$secs"
  STEP_APIS[$idx]="$apis"
  STEP_STATUS[$idx]="$status"
}

###############################################################################
# 1. Create S3 bucket (in DR region)
###############################################################################
log "[Step 1/9] S3 bucket..."
t0=$SECONDS
SETUP_API_CALLS=0
if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" 2>/dev/null; then
  log "Bucket $BUCKET_NAME already exists"
else
  log "Creating bucket $BUCKET_NAME in $REGION..."
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  aws s3api put-public-access-block --bucket "$BUCKET_NAME" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  log "Bucket created with public access blocked ($(( SECONDS - t0 ))s)"
fi
step_done 1 "S3 bucket" $(( SECONDS - t0 )) 3

###############################################################################
# 2. Discover VPC
###############################################################################
log "[Step 2/9] VPC discovery..."
if [[ -z "$VPC_ID" ]]; then
  VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=isDefault,Values=true" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
  [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]] && \
    VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --query 'Vpcs[0].VpcId' --output text)
fi
log "VPC: $VPC_ID"
step_done 2 "VPC discovery" $(( SECONDS - t0 )) 2

###############################################################################
# 3. Ensure S3 Gateway Endpoint (free, backbone-routed, same-region)
###############################################################################
log "[Step 3/9] S3 Gateway endpoint..."
S3_SERVICE="com.amazonaws.${REGION}.s3"

VPCE_ID=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=$S3_SERVICE" "Name=vpc-endpoint-type,Values=Gateway" \
  --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>/dev/null)

if [[ "$VPCE_ID" == "None" || -z "$VPCE_ID" ]]; then
  log "Creating S3 Gateway endpoint in VPC $VPC_ID..."
  # Get all route tables for this VPC so all subnets route S3 through the endpoint
  RTB_IDS=$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'RouteTables[].RouteTableId' --output text)
  RTB_ARRAY=($RTB_IDS)

  VPCE_ID=$(aws ec2 create-vpc-endpoint --region "$REGION" \
    --vpc-id "$VPC_ID" \
    --service-name "$S3_SERVICE" \
    --route-table-ids "${RTB_ARRAY[@]}" \
    --query 'VpcEndpoint.VpcEndpointId' --output text)
  log "Created S3 Gateway endpoint: $VPCE_ID (associated with ${#RTB_ARRAY[@]} route tables)"
else
  # Verify it covers all route tables
  CURRENT_RTBS=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
    --vpc-endpoint-ids "$VPCE_ID" \
    --query 'VpcEndpoints[0].RouteTableIds' --output text)
  ALL_RTBS=$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'RouteTables[].RouteTableId' --output text)

  MISSING_RTBS=()
  for rtb in $ALL_RTBS; do
    echo "$CURRENT_RTBS" | grep -q "$rtb" || MISSING_RTBS+=("$rtb")
  done

  if (( ${#MISSING_RTBS[@]} > 0 )); then
    log "Adding ${#MISSING_RTBS[@]} missing route tables to S3 Gateway endpoint $VPCE_ID..."
    aws ec2 modify-vpc-endpoint --region "$REGION" \
      --vpc-endpoint-id "$VPCE_ID" \
      --add-route-table-ids "${MISSING_RTBS[@]}"
    log "Updated endpoint with route tables: ${MISSING_RTBS[*]}"
  fi
  log "S3 Gateway endpoint: $VPCE_ID (all route tables covered)"
fi

# Verify: show the prefix list route in route tables
log "S3 traffic path: EC2 → VPC route table → Gateway endpoint $VPCE_ID → S3 ($REGION backbone)"
log "  Cost: \$0 data processing (Gateway endpoints are free)"
step_done 3 "S3 Gateway endpoint" $(( SECONDS - t0 )) 4

###############################################################################
# 4. Discover subnets (3 AZs)
###############################################################################
log "[Step 4/9] Subnets..."
t0=$SECONDS
SUBNETS_JSON=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets | sort_by(@, &AvailabilityZone) | [].{id:SubnetId,az:AvailabilityZone}' \
  --output json)

AZS=($(echo "$SUBNETS_JSON" | jq -r '.[].az' | sort -u | head -3))
SUBNET_IDS=()
for az in "${AZS[@]}"; do
  sid=$(echo "$SUBNETS_JSON" | jq -r --arg az "$az" '[.[] | select(.az==$az)][0].id')
  SUBNET_IDS+=("$sid")
  log "  AZ $az → Subnet $sid"
done
step_done 4 "Subnets (3 AZs)" $(( SECONDS - t0 )) 1

###############################################################################
# 5. AMI (latest Amazon Linux 2023 in target region)
###############################################################################
log "[Step 5/9] AMI lookup..."
t0=$SECONDS
AMI_ID=$(aws ec2 describe-images --region "$REGION" \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text)
log "AMI: $AMI_ID (Amazon Linux 2023)"
step_done 5 "AMI lookup" $(( SECONDS - t0 )) 1

###############################################################################
# 6. Security group
###############################################################################
log "[Step 6/9] Security group..."
t0=$SECONDS
SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=drscale-sg" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
  SG_ID=$(aws ec2 create-security-group --region "$REGION" \
    --group-name drscale-sg \
    --description "DRscale test - $REGION" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 2>/dev/null || true
  log "Created security group: $SG_ID"
else
  log "Security group: $SG_ID"
fi
step_done 6 "Security group" $(( SECONDS - t0 )) 3

###############################################################################
# 7. Key pair
###############################################################################
log "[Step 7/9] Key pair..."
t0=$SECONDS
KEY_NAME="drscale-key-${REGION}"
if aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" 2>/dev/null; then
  log "Key pair: $KEY_NAME (exists)"
else
  aws ec2 create-key-pair --region "$REGION" --key-name "$KEY_NAME" \
    --query 'KeyMaterial' --output text > "DRscale/${KEY_NAME}.pem"
  chmod 600 "DRscale/${KEY_NAME}.pem"
  log "Created key pair: $KEY_NAME"
fi
step_done 7 "Key pair" $(( SECONDS - t0 )) 1

###############################################################################
# 8. IAM instance profile (global, not region-specific)
###############################################################################
log "[Step 8/9] IAM profile..."
t0=$SECONDS
PROFILE_NAME="drscale-s3-reader"
if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" 2>/dev/null; then
  log "IAM profile: $PROFILE_NAME (exists)"
else
  log "Creating IAM role + instance profile..."
  aws iam create-role --role-name "$PROFILE_NAME" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
    }' > /dev/null
  aws iam put-role-policy --role-name "$PROFILE_NAME" --policy-name s3-read \
    --policy-document "{
      \"Version\":\"2012-10-17\",
      \"Statement\":[
        {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::${BUCKET_NAME}/*\"},
        {\"Effect\":\"Allow\",\"Action\":[\"ec2:CreateTags\"],\"Resource\":\"*\"}
      ]
    }"
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" > /dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$PROFILE_NAME"
  log "Created IAM profile (waiting 10s for propagation)"
  sleep 10
fi
step_done 8 "IAM profile" $(( SECONDS - t0 )) 5

###############################################################################
# 9. Generate gzip test file and upload to same-region bucket (last step)
###############################################################################
log "[Step 9/9] Test data file (${GZ_SIZE_GB}GB gz)..."
t0=$SECONDS
gz_t0=$SECONDS
if aws s3api head-object --bucket "$BUCKET_NAME" --key "$S3_KEY" --region "$REGION" 2>/dev/null; then
  log "Test file s3://$BUCKET_NAME/$S3_KEY already exists — skipping"
else
  local_gz="/tmp/drscale-testdata.gz"
  log "  Generating ${GZ_SIZE_GB}GB gzip locally → $local_gz (~3-5 min)..."
  t0=$SECONDS
  dd if=/dev/urandom bs=1M count=$((GZ_SIZE_GB * 1024)) status=progress 2>&1 | gzip -1 > "$local_gz"
  log "  Generated in $(( SECONDS - t0 ))s — size: $(du -h "$local_gz" | cut -f1)"

  log "  Uploading to s3://$BUCKET_NAME/$S3_KEY ..."
  t0=$SECONDS
  aws s3 cp "$local_gz" "s3://$BUCKET_NAME/$S3_KEY" --region "$REGION"
  log "  Uploaded in $(( SECONDS - t0 ))s"
  rm -f "$local_gz"
fi
step_done 9 "10GB gz file (generate+upload)" $(( SECONDS - gz_t0 )) 2

###############################################################################
# 10. Output
###############################################################################
TOTAL_SETUP_SEC=$(( SECONDS - SETUP_START ))
SUBNET_CSV=$(IFS=,; echo "${SUBNET_IDS[*]}")

# Sum API calls
TOTAL_SETUP_APIS=0
for a in "${STEP_APIS[@]}"; do TOTAL_SETUP_APIS=$((TOTAL_SETUP_APIS + a)); done

# Setup cost: S3 storage + bucket (no EC2 yet)
GZ_STORAGE_COST=$(echo "scale=4; $GZ_SIZE_GB * 0.023" | bc)  # S3 standard $/GB-month

cat <<EOF

==========================================
DRscale Setup Summary — $REGION
==========================================

Step Summary:
$(printf "  %-4s %-35s %6s  %5s  %s\n" "#" "Step" "Time" "APIs" "Status")
$(printf "  %-4s %-35s %6s  %5s  %s\n" "---" "---" "------" "-----" "------")
$(for i in $(seq 1 9); do
  printf "  %-4s %-35s %5ss  %5s  %s\n" "$i." "${STEP_NAMES[$i]:-—}" "${STEP_TIMES[$i]:-0}" "${STEP_APIS[$i]:-0}" "${STEP_STATUS[$i]:-—}"
done)
  ---- ----------------------------------- ------  -----
  Total                                    ${TOTAL_SETUP_SEC}s     ${TOTAL_SETUP_APIS}

Setup Cost (monthly if retained):
  S3 storage (${GZ_SIZE_GB}GB gz):  ~\$${GZ_STORAGE_COST}/month
  S3 Gateway endpoint:    \$0 (free)
  IAM role/profile:       \$0
  Security group:         \$0
  Key pair:               \$0

Run the test:

  ./DRscale/drscale.sh \\
    --region "$REGION" \\
    --bucket "$BUCKET_NAME" \\
    --key-name "$KEY_NAME" \\
    --sg "$SG_ID" \\
    --subnets "$SUBNET_CSV" \\
    --ami "$AMI_ID" \\
    --iam-profile "$PROFILE_NAME"

  Add --dry-run for validation only.

Resources:
  Region:         $REGION
  S3 bucket:      $BUCKET_NAME (same region)
  S3 GW endpoint: $VPCE_ID (free, backbone-routed)
  Security grp:   $SG_ID
  Key pair:       $KEY_NAME
  IAM profile:    $PROFILE_NAME
  VPC:            $VPC_ID
  Subnets:        ${SUBNET_IDS[*]}
  AZs:            ${AZS[*]}
  AMI:            $AMI_ID

Data path: EC2 → route table → S3 Gateway endpoint → S3 (in-region, \$0 transfer)
==========================================
EOF
