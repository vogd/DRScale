#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# DRscale Cleanup — Terminate instances and optionally remove all infra
#
# Usage: ./cleanup.sh --region us-west-2 [--remove-infra]
###############################################################################

REGION=""
REMOVE_INFRA=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --region)        REGION="$2"; shift 2;;
    --remove-infra)  REMOVE_INFRA=true; shift;;
    *)               echo "Usage: $0 --region REGION [--remove-infra]"; exit 1;;
  esac
done

[[ -z "$REGION" ]] && { echo "ERROR: --region required"; exit 1; }

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Terminate all drscale-tagged instances in the specified region
IDS=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag-key,Values=drscale" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

if [[ -n "$IDS" ]]; then
  COUNT=$(echo "$IDS" | wc -w | tr -d ' ')
  log "Terminating $COUNT drscale instances in $REGION..."
  aws ec2 terminate-instances --region "$REGION" --instance-ids $IDS --output text > /dev/null
  log "Termination initiated (EBS volumes auto-delete)"
else
  log "No drscale instances in $REGION"
fi

if $REMOVE_INFRA; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  BUCKET="drscale-testdata-${ACCOUNT_ID}-${REGION}"

  log "Removing infra in $REGION..."

  # S3 bucket
  aws s3 rm "s3://$BUCKET" --recursive --region "$REGION" 2>/dev/null && \
    aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null && \
    log "Deleted bucket $BUCKET" || log "Bucket skip"

  # Security group
  aws ec2 delete-security-group --region "$REGION" --group-name drscale-sg 2>/dev/null && \
    log "Deleted SG" || log "SG skip"

  # Key pair (region-specific name)
  aws ec2 delete-key-pair --region "$REGION" --key-name "drscale-key-${REGION}" 2>/dev/null && \
    log "Deleted key pair" || log "Key skip"

  # S3 Gateway endpoint
  VPCE_ID=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
    --filters "Name=tag:drscale,Values=*" "Name=vpc-endpoint-type,Values=Gateway" \
    --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>/dev/null)
  # Only delete if we tagged it (don't delete pre-existing endpoints)
  # Since we don't tag it, skip — Gateway endpoints are free and shared

  # IAM (global)
  aws iam remove-role-from-instance-profile --instance-profile-name drscale-s3-reader --role-name drscale-s3-reader 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name drscale-s3-reader 2>/dev/null || true
  aws iam delete-role-policy --role-name drscale-s3-reader --policy-name s3-read 2>/dev/null || true
  aws iam delete-role --role-name drscale-s3-reader 2>/dev/null || true
  log "Deleted IAM role/profile"
fi

log "Cleanup complete for $REGION"
