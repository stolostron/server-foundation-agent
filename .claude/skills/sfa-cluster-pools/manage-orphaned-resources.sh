#!/bin/bash

# Script to identify and cleanup orphaned AWS resources from deleted clusters
# Usage: ./manage-orphaned-resources.sh [--region REGION] [--cleanup]

set -o pipefail

REGION="${AWS_REGION:-us-east-1}"
KUBECONFIG_PATH="/tmp/kube/collective.kubeconfig"
CLEANUP=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --region) REGION="$2"; shift 2 ;;
    --cleanup) CLEANUP=true; shift ;;
    --help)
      echo "Usage: $0 [--region REGION] [--cleanup]"
      echo ""
      echo "Find orphaned AWS resources from deleted clusters"
      echo ""
      echo "Options:"
      echo "  --region REGION  AWS region (default: us-east-1)"
      echo "  --cleanup        Actually cleanup orphaned resources using hiveutil"
      echo "                   (requires user confirmation)"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "=== Finding Orphaned AWS Resources ==="
echo "Region: $REGION"
echo "Kubeconfig: $KUBECONFIG_PATH"
echo ""

# Check if kubeconfig file exists
if [ ! -f "$KUBECONFIG_PATH" ]; then
  echo "Error: Kubeconfig file not found: $KUBECONFIG_PATH"
  echo ""
  echo "Please login to the collective cluster first:"
  echo "  oc login --web https://api.collective.aws.red-chesterfield.com:6443 --kubeconfig=$KUBECONFIG_PATH"
  exit 1
fi

# Check if hiveutil is available when cleanup is requested
if [ "$CLEANUP" = true ]; then
  if ! command -v hiveutil &> /dev/null; then
    echo "Error: hiveutil not found. Install from https://github.com/openshift/hive/releases"
    exit 1
  fi
  echo "Cleanup mode: ENABLED"
  echo ""
fi

# Temp files
ACTIVE_IDS=$(mktemp)
AWS_IDS=$(mktemp)
ORPHANED_IDS=$(mktemp)
trap "rm -f $ACTIVE_IDS $AWS_IDS $ORPHANED_IDS" EXIT

# Get active cluster infraIDs
echo "Step 1: Getting active infraIDs from cluster deployments..."
if ! KUBECONFIG="$KUBECONFIG_PATH" oc get clusterdeployment.hive --all-namespaces \
  -l hive.openshift.io/clusterpool-namespace=server-foundation \
  -o jsonpath='{range .items[*]}{.spec.clusterMetadata.infraID}{"\n"}{end}' \
  2>/dev/null | sort > "$ACTIVE_IDS"; then
  echo "Error: Failed to get cluster deployments"
  exit 1
fi

ACTIVE_COUNT=$(wc -l < "$ACTIVE_IDS" | tr -d ' ')
echo "Found $ACTIVE_COUNT active cluster(s)"
echo ""

# Get AWS VPCs with server-foundation tags
echo "Step 2: Querying AWS VPCs..."
aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=*server-foundation*,*sf-prow*" \
  --query 'Vpcs[*].Tags[?Key==`Name`].Value | []' \
  --output text 2>/dev/null | \
  tr '\t' '\n' | grep -E '(server-foundation|sf-prow)' | \
  sed 's/-vpc$//' | sort > "$AWS_IDS" || true

AWS_COUNT=$(wc -l < "$AWS_IDS" | tr -d ' ')
echo "Found $AWS_COUNT VPC(s) in AWS"
echo ""

# Find orphaned infraIDs
echo "Step 3: Comparing active vs AWS resources..."
comm -13 "$ACTIVE_IDS" "$AWS_IDS" > "$ORPHANED_IDS"
ORPHANED_COUNT=$(wc -l < "$ORPHANED_IDS" | tr -d ' ')

echo ""
echo "=== Results ==="
echo "Active clusters: $ACTIVE_COUNT"
echo "AWS VPCs: $AWS_COUNT"
echo "Orphaned infraIDs: $ORPHANED_COUNT"
echo ""

if [ "$ORPHANED_COUNT" -eq 0 ]; then
  echo "No orphaned resources found!"
  exit 0
fi

echo "Orphaned infraIDs:"
cat "$ORPHANED_IDS"
echo ""

# Show details for each orphaned infraID
while read -r infra_id; do
  echo "=========================================="
  echo "InfraID: $infra_id"

  # Check VPC
  VPC=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$infra_id,Values=owned" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")

  if [ "$VPC" != "None" ] && [ -n "$VPC" ]; then
    echo "  VPC: $VPC"
  fi

  # Check EC2 instances
  INSTANCES=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$infra_id,Values=owned" \
    --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' \
    --output text 2>/dev/null | wc -l | tr -d ' ')
  echo "  EC2 Instances: $INSTANCES"

  # Check Volumes
  VOLUMES=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$infra_id,Values=owned" \
    --query 'Volumes[*].VolumeId' \
    --output text 2>/dev/null | wc -w | tr -d ' ')
  echo "  EBS Volumes: $VOLUMES"

  echo "  Cleanup: hiveutil aws-tag-deprovision kubernetes.io/cluster/$infra_id=owned --region=$REGION"
  echo ""
done < "$ORPHANED_IDS"

# Cleanup if requested
if [ "$CLEANUP" = true ]; then
  echo "=========================================="
  echo ""
  echo "WARNING: About to clean up $ORPHANED_COUNT orphaned cluster(s)"
  echo ""
  echo "This will DELETE all AWS resources for these infraIDs:"
  cat "$ORPHANED_IDS" | sed 's/^/  - /'
  echo ""
  read -p "Are you sure you want to proceed? (yes/no): " confirm

  if [ "$confirm" != "yes" ]; then
    echo "Cleanup cancelled."
    exit 0
  fi

  echo ""
  echo "Starting cleanup..."
  echo ""

  # Cleanup each orphaned infraID
  SUCCESS_COUNT=0
  FAIL_COUNT=0

  while read -r infra_id; do
    echo "=========================================="
    echo "Cleaning up: $infra_id"

    if hiveutil aws-tag-deprovision "kubernetes.io/cluster/$infra_id=owned" --region="$REGION"; then
      echo "Successfully cleaned up $infra_id"
      ((SUCCESS_COUNT++))
    else
      echo "Failed to clean up $infra_id"
      ((FAIL_COUNT++))
    fi
    echo ""
  done < "$ORPHANED_IDS"

  echo "=========================================="
  echo ""
  echo "=== Cleanup Summary ==="
  echo "Successful: $SUCCESS_COUNT"
  echo "Failed: $FAIL_COUNT"
  echo "Total: $ORPHANED_COUNT"
fi
