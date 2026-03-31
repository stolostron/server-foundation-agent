---
name: sfa-cluster-pools
description: "Manage server foundation OCP cluster pools, cluster claims, and AWS resource cleanup. Use this skill when you need to claim/destroy clusters, check pool status, manage hibernation, track cluster ownership, or identify AWS resources for cleanup. For example: `Claim a cluster from sno-lite pool` or `Who owns cluster xyz?` or `Prevent my cluster from hibernating` or `What AWS resources need cleanup?`"
---

# OCP Cluster Pools Management Skill

This skill helps manage OpenShift cluster pools in the server foundation namespace and AWS resource cleanup.

## Overview

ACM has a collective OCP cluster where each squad has a dedicated namespace for managing their OCP clusters. The server foundation team uses the `server-foundation` namespace with several cluster pools powered by [OpenShift Hive](https://github.com/openshift/hive).

## Cluster Pools

### Server Foundation Cluster Pools

The server foundation team maintains the following cluster pools:

| Pool Name | Purpose | Type | Namespace |
|-----------|---------|------|-----------|
| `server-foundation-sno-lite` | Team members to claim single node OpenShift clusters | SNO (Single Node OpenShift) | server-foundation |
| `server-foundation-ha` | Team members to claim HA OpenShift clusters | HA (High Availability) | server-foundation |
| `sf-prow-aws-ocp4-sno-us-east-1` | CI (Prow) to claim OCP4 clusters for running tests | SNO for CI | server-foundation |

**IMPORTANT**:
- **DO NOT** claim HA clusters (`server-foundation-ha`) unless explicitly instructed
- HA clusters consume significantly more resources and cost ~3x more than SNO clusters
- Use SNO clusters (`server-foundation-sno-lite`) for development and testing
- Only use HA clusters when you specifically need high availability features

### How Cluster Pools Work

1. **Pool Size**: Each pool maintains a configured number of hibernating clusters ready to be claimed
   - Example: If pool size is 2, there will be 2 hibernating clusters available

2. **Claiming Process**:
   - When a user claims a cluster, it activates from hibernating -> active state
   - The pool automatically provisions a new cluster to maintain the pool size
   - The new cluster is hibernated to keep it ready for the next claim

3. **Resource Usage**:
   - Each cluster uses the team's AWS resource quota
   - Active clusters consume more resources than hibernating ones
   - When clusters are destroyed, AWS infrastructure resources (instances, VPCs, etc.) may be left behind

## Automated Cost Savings with CronJobs

To minimize AWS costs, the server-foundation namespace uses 5 automated cronjobs that manage cluster pools and claimed clusters:

### CronJob Schedule Overview

All times are in **Asia/Shanghai (UTC+8)** timezone:

| CronJob Name | Schedule | What It Does | Purpose |
|--------------|----------|--------------|---------|
| `startup-clusters` | 00:30 Mon-Fri | Wakes up all claimed clusters (sets powerState to Running) | Ensure clusters are ready before work hours |
| `scale-up-clusterpool` | 00:35 Mon-Fri | Scales up pools: sno-lite=1, sf-prow=2 | Pre-provision clusters for the workday |
| `shutdown-clusters` | 11:00 Sun,Mon,Wed-Sat | Hibernates all claimed clusters (except `do-not-hibernate=true`) | Save costs during lunch/evening |
| `shutdown-clusters-tues` | 15:30 Tuesday | Hibernates all claimed clusters (except `do-not-hibernate=true`) | Tuesday-specific shutdown schedule |
| `scale-down-clusterpool` | 15:30 Daily | Scales all pools to 0 (except `do-not-scale=true`) | Delete unused hibernating clusters to save costs |

### How the CronJobs Save Costs

1. **Morning Automation (00:30-00:35 Mon-Fri)**:
   - `startup-clusters` wakes up all claimed clusters before work hours
   - `scale-up-clusterpool` ensures fresh hibernating clusters are ready in the pool
   - This provides a seamless experience for team members starting their workday

2. **Evening/Night Automation**:
   - `shutdown-clusters` (11:00) and `shutdown-clusters-tues` (15:30) hibernate claimed clusters when not in use
   - Hibernated clusters cost ~10% of running clusters
   - `scale-down-clusterpool` (15:30 daily) removes all standby hibernating clusters from pools
   - This significantly reduces AWS costs during non-work hours

3. **Opt-Out Mechanism**:
   - Clusters with label `do-not-hibernate=true` will NOT be hibernated by cronjobs
   - Pools with label `do-not-scale=true` will NOT be scaled down to 0
   - Use these labels for critical clusters that must remain running 24/7

### Cost Savings Impact

- **Running cluster**: 100% cost (active EC2 instances, load balancers, etc.)
- **Hibernating cluster**: ~10% cost (only storage volumes remain)
- **Deleted cluster**: 0% cost (all resources removed)

By automatically hibernating claimed clusters and scaling down pools daily, the team saves approximately:
- **60-70% of AWS costs** compared to running clusters 24/7
- Significant reduction in orphaned resources through regular pool scaling

### Example: Check CronJob Status

```bash
# List all cronjobs
oc get cronjob -n server-foundation

# Check last execution time
oc get cronjob scale-down-clusterpool -n server-foundation -o yaml | grep lastScheduleTime

# View recent job history
oc get jobs -n server-foundation -l job-name=scale-down-clusterpool
```

## Prerequisites

Before using this skill, ensure you have:

1. **Kubeconfig Access**:
   - Access to the collective ACM cluster
   - Permissions to view resources in the `server-foundation` namespace
   - Context set to the collective cluster

   **Login to the collective cluster** (only call this if not already authenticated):
   ```bash
   oc login --web https://api.collective.aws.red-chesterfield.com:6443 --kubeconfig=/tmp/kube/collective.kubeconfig
   ```

   This uses GitHub OIDC authentication. Without `--kubeconfig` flag, it defaults to `$HOME/.kube/config`.

   **IMPORTANT NOTICE**:
   - The collective kubeconfig (`/tmp/kube/collective.kubeconfig`) should **ONLY** be used for this cluster-pools skill
   - **DO NOT** use it for other purposes unless explicitly instructed
   - This restriction helps prevent accidental operations on the collective cluster

2. **AWS Credentials** (for cleanup tasks):
   - AWS CLI configured with appropriate credentials
   - Access to the team's AWS account

3. **Environment Variables**:
   ```bash
   # Unset proxy variables before kubectl commands
   unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
   ```

## Common Tasks

### 1. List All Cluster Pools

```bash
oc get clusterpool.hive -n server-foundation
```

This shows:
- Pool names
- Current size (number of hibernating clusters)
- Number of ready clusters
- Number of claimed clusters

### 2. Get Detailed Pool Information

```bash
oc get clusterpool.hive <pool-name> -n server-foundation -o yaml
```

Key fields to check:
- `spec.size`: Desired pool size
- `status.ready`: Number of ready (hibernating) clusters
- `status.standby`: Number of standby clusters
- `spec.imageSetRef`: OCP version being used

Example:
```bash
oc get clusterpool.hive server-foundation-sno-lite -n server-foundation -o yaml
```

### 3. List All Cluster Deployments

**Important**: Each cluster deployment is in its own individual namespace. The cluster deployment name and its namespace have the same value.

```bash
# List all cluster deployments across all namespaces
oc get clusterdeployment.hive --all-namespaces

# Filter by pool (requires both labels)
oc get clusterdeployment.hive --all-namespaces -l hive.openshift.io/clusterpool-name=server-foundation-sno-lite,hive.openshift.io/clusterpool-namespace=server-foundation
```

Status meanings:
- **Hibernating**: Cluster is paused and ready to be claimed
- **Running**: Cluster is active (claimed or being provisioned)
- **Provisioning**: Cluster is being provisioned

### 4. Claim a Cluster from a Pool

**Best Practice**: Use your **GitHub username** in the claim name since the collective cluster uses GitHub as the OIDC provider.

**IMPORTANT**: Always use `server-foundation-sno-lite` pool. **DO NOT** use `server-foundation-ha` unless explicitly instructed.

```bash
# Find your GitHub username (your authenticated identity)
oc whoami
# Output: zhujian7

# Create a claim YAML file (use your GitHub username from above)
cat <<EOF > my-cluster-claim.yaml
apiVersion: hive.openshift.io/v1
kind: ClusterClaim
metadata:
  name: <username>-sno  # e.g., zhujian7-sno, xuezhaojun-dev
  namespace: server-foundation
  annotations:
    cluster.open-cluster-management.io/createmanagedcluster: "false"  # Prevent auto-import
spec:
  clusterPoolName: server-foundation-sno-lite  # Use SNO pool, NOT server-foundation-ha
EOF

# Apply the claim
oc apply -f my-cluster-claim.yaml

# Check claim status
oc get clusterclaim.hive <username>-sno -n server-foundation

# Get the cluster namespace (once claim is fulfilled)
oc get clusterclaim.hive <username>-sno -n server-foundation -o jsonpath='{.spec.namespace}'
```

**Naming Convention**: Use your GitHub username for easy identification (e.g., `zhujian7-sno`, `xuezhaojun-testing`).

**Note**: The claim name is just a convention. The **authoritative source** for ownership is the `open-cluster-management.io/user-identity` annotation (see Cluster Ownership Tracking below).

The claim will:
1. Pull a hibernating cluster from the specified pool
2. Wake it up (set powerState to Running)
3. Assign it to your claim name
4. The pool will automatically provision a new cluster to maintain pool size

#### Auto-Import Prevention

The annotation `cluster.open-cluster-management.io/createmanagedcluster: "false"` is included in the claim YAML above by default. This prevents the claimed cluster from being auto-imported as a ManagedCluster on the collective cluster. **Always include this annotation** when claiming clusters unless you explicitly need the cluster to be managed by the collective.

### 5. List Claimed Clusters

```bash
# List all claims
oc get clusterclaim.hive -n server-foundation

# List only your clusters (replace <username> with your GitHub username from oc whoami)
oc get clusterclaim.hive -n server-foundation | grep <username>
```

This shows:
- Claim name (should include GitHub username)
- POOL: Which pool it's from
- CLUSTERNAMESPACE: The namespace where the cluster deployment is located (also the cluster name)

#### Cluster Ownership Tracking

**IMPORTANT**: To determine who claimed a cluster, use the `open-cluster-management.io/user-identity` annotation, which is the **authoritative source of ownership**. The claim name is just a convention and is not reliable for tracking ownership.

When you create a ClusterClaim, the system automatically adds annotations to track who created it:

```yaml
annotations:
  open-cluster-management.io/user-identity: eHVlemhhb2p1bg==
  open-cluster-management.io/user-group: U2VydmVyIEZvdW5kYXRpb24sVGVhbSBSZWQgSGF0LFplbkh1YiBUcmlhZ2VyLHN5c3RlbTphdXRoZW50aWNhdGVkOm9hdXRoLHN5c3RlbTphdXRoZW50aWNhdGVk
```

**What these annotations contain**:
- `open-cluster-management.io/user-identity`: **Source of truth** - Base64-encoded GitHub username of the user who created the claim
- `open-cluster-management.io/user-group`: Base64-encoded list of groups the user belongs to

**Viewing the decoded values**:

```bash
# Decode the user identity to see the actual GitHub username
oc get clusterclaim.hive <username>-sno -n server-foundation -o jsonpath='{.metadata.annotations.open-cluster-management\.io/user-identity}' | base64 -d
# Output: xuezhaojun
```

**Use cases**:
- Verify who created a cluster claim
- Audit cluster resource usage by team members
- Identify clusters that may be orphaned if the owner has left
- Track which team members are actively using cluster pools

**Note**: These annotations cannot be manually edited or removed.

### 6. Prevent Cluster from Being Hibernated

To keep a cluster running 24/7 (opt-out of automated hibernation cronjobs):

```bash
# Add label to prevent hibernation (replace <username>-sno with your actual claim name)
oc label clusterclaim.hive <username>-sno -n server-foundation do-not-hibernate=true

# Example
oc label clusterclaim.hive zhujian7-sno -n server-foundation do-not-hibernate=true

# Verify label was added
oc get clusterclaim.hive <username>-sno -n server-foundation --show-labels

# Remove label to re-enable hibernation
oc label clusterclaim.hive <username>-sno -n server-foundation do-not-hibernate-
```

**Important**: Use this sparingly as it increases AWS costs. Clusters with this label will:
- NOT be hibernated by `shutdown-clusters` cronjob
- Continue running 24/7 at full cost (~10x hibernating cost)
- Still be woken up by `startup-clusters` (no-op if already running)

### 7. Destroy a Cluster (Delete Claim)

When you're done with a cluster, delete the claim to release it:

```bash
# Delete the cluster claim (replace <username>-sno with your actual claim name)
oc delete clusterclaim.hive <username>-sno -n server-foundation

# Example
oc delete clusterclaim.hive zhujian7-sno -n server-foundation

# Verify deletion
oc get clusterclaim.hive -n server-foundation | grep zhujian7
```

What happens when you delete a claim:
1. The cluster deployment is marked for deletion
2. Hive deprovisions the cluster (deletes AWS resources)
3. The pool will provision a new cluster to maintain pool size
4. **Note**: Sometimes AWS resources are not fully cleaned up, leaving orphaned VPCs/subnets (see AWS Cleanup section)

**Alternative**: Temporarily hibernate instead of destroying:

```bash
# Hibernate the cluster (saves costs but keeps the cluster)
CLUSTER_NS=$(oc get clusterclaim.hive <username>-sno -n server-foundation -ojsonpath='{.spec.namespace}')
oc patch clusterdeployment.hive $CLUSTER_NS -n $CLUSTER_NS \
  --type=merge --patch '{"spec":{"powerState":"Hibernating"}}'

# Wake it back up later
oc patch clusterdeployment.hive $CLUSTER_NS -n $CLUSTER_NS \
  --type=merge --patch '{"spec":{"powerState":"Running"}}'
```

### 8. Check Cluster Details

To access a cluster deployment, first get the namespace from the cluster claim:

```bash
# Get the namespace (which is also the cluster deployment name)
CLUSTER_NS=$(oc get clusterclaim.hive -n server-foundation <claim-name> -ojsonpath='{.spec.namespace}')

# Get the cluster deployment (namespace and name are the same)
oc get clusterdeployment.hive -n $CLUSTER_NS $CLUSTER_NS -o yaml
```

Or directly if you know the cluster namespace:
```bash
oc get clusterdeployment.hive -n <cluster-namespace> <cluster-namespace> -o yaml
```

Important fields:
- `spec.installed`: Whether cluster installation is complete
- `spec.powerState`: Hibernating, Running, or Unknown
- `spec.platform.aws.region`: AWS region
- `metadata.labels.hive.openshift.io/clusterpool-name`: Parent pool name
- `metadata.labels.hive.openshift.io/clusterpool-namespace`: Parent pool namespace

### 9. Check Pool Events

```bash
oc get events -n server-foundation --field-selector involvedObject.kind=ClusterPool,involvedObject.name=<pool-name> --sort-by='.lastTimestamp'
```

### 10. AWS Resource Cleanup

When clusters are destroyed, some AWS resources may remain. Common resources to check:

**IMPORTANT**: All AWS infrastructure resources related to a cluster have a Kubernetes ownership tag:
```
kubernetes.io/cluster/<infraID>: owned
```

Where `<infraID>` is the cluster's infrastructure ID (found in `.spec.clusterMetadata.infraID` of the cluster deployment).

This tag is present on all cluster resources including EC2 instances, VPCs, subnets, security groups, load balancers, and volumes. Use this tag for precise filtering when identifying cluster resources.

#### List EC2 Instances

```bash
# List all instances with server-foundation tag
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*server-foundation*" \
  --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name]' \
  --output table

# List instances for a specific cluster using infraID
aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/<infraID>,Values=owned" \
  --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name,InstanceType]' \
  --output table
```

#### List VPCs

```bash
# List VPCs with server-foundation tag
aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=*server-foundation*" \
  --query 'Vpcs[*].[VpcId,Tags[?Key==`Name`].Value|[0],State]' \
  --output table

# List VPC for a specific cluster using infraID
aws ec2 describe-vpcs \
  --filters "Name=tag:kubernetes.io/cluster/<infraID>,Values=owned" \
  --query 'Vpcs[*].[VpcId,Tags[?Key==`Name`].Value|[0],CidrBlock,State]' \
  --output table
```

#### List Volumes

```bash
# List volumes with server-foundation tag
aws ec2 describe-volumes \
  --filters "Name=tag:Name,Values=*server-foundation*" \
  --query 'Volumes[*].[VolumeId,Tags[?Key==`Name`].Value|[0],State,Size]' \
  --output table

# List volumes for a specific cluster using infraID
aws ec2 describe-volumes \
  --filters "Name=tag:kubernetes.io/cluster/<infraID>,Values=owned" \
  --query 'Volumes[*].[VolumeId,Tags[?Key==`Name`].Value|[0],State,Size,Attachments[0].InstanceId]' \
  --output table
```

#### List Load Balancers

```bash
# Classic load balancers
aws elb describe-load-balancers \
  --query 'LoadBalancerDescriptions[?contains(LoadBalancerName, `server-foundation`)].LoadBalancerName' \
  --output table

# Application/Network load balancers
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[?contains(LoadBalancerName, `server-foundation`)].LoadBalancerArn' \
  --output table
```

#### List S3 Buckets

```bash
# List buckets (then filter manually)
aws s3 ls | grep server-foundation
```

### 11. Identify Orphaned Resources

**Automated Script** (Recommended): Use the provided script for easier identification and cleanup:

```bash
# Run from the skill directory
cd .claude/skills/sfa-cluster-pools

# Find orphaned resources
./manage-orphaned-resources.sh

# Find and cleanup orphaned resources (with confirmation prompt)
./manage-orphaned-resources.sh --cleanup

# Specify a different region
./manage-orphaned-resources.sh --region us-east-1 --cleanup
```

The script automatically:
- Queries all active cluster infraIDs from the collective cluster
- Checks AWS VPCs, EC2 instances, and EBS volumes
- Compares and identifies orphaned resources
- Shows detailed information and cleanup commands for each orphaned infraID
- **With `--cleanup` flag**: Executes `hiveutil aws-tag-deprovision` for each orphaned infraID (requires confirmation)

**Manual Method** - To identify AWS resources that may need cleanup manually:

1. **Get list of active infraIDs from server-foundation pools**:
   ```bash
   oc get clusterdeployment.hive --all-namespaces -l hive.openshift.io/clusterpool-namespace=server-foundation -o jsonpath='{range .items[*]}{.spec.clusterMetadata.infraID}{"\n"}{end}'
   ```

2. **Compare with AWS resources**:
   - All cluster resources have the tag `kubernetes.io/cluster/<infraID>: owned`
   - Resources with infraIDs not in the active list are candidates for cleanup
   - Look for resources with timestamps indicating they're from deleted clusters

3. **Find all resources for a specific cluster**:
   ```bash
   # Get infraID from cluster deployment
   CLUSTER_NS=$(oc get clusterclaim.hive -n server-foundation <claim-name> -ojsonpath='{.spec.namespace}')
   INFRA_ID=$(oc get clusterdeployment.hive -n $CLUSTER_NS $CLUSTER_NS -o jsonpath='{.spec.clusterMetadata.infraID}')
   REGION=$(oc get clusterdeployment.hive -n $CLUSTER_NS $CLUSTER_NS -o jsonpath='{.spec.platform.aws.region}')

   # List all EC2 instances
   aws ec2 describe-instances --region $REGION \
     --filters "Name=tag:kubernetes.io/cluster/$INFRA_ID,Values=owned" \
     --query 'Reservations[*].Instances[*].[InstanceId,State.Name]'

   # List VPC
   aws ec2 describe-vpcs --region $REGION \
     --filters "Name=tag:kubernetes.io/cluster/$INFRA_ID,Values=owned" \
     --query 'Vpcs[*].[VpcId,CidrBlock]'

   # List volumes
   aws ec2 describe-volumes --region $REGION \
     --filters "Name=tag:kubernetes.io/cluster/$INFRA_ID,Values=owned" \
     --query 'Volumes[*].[VolumeId,State,Size]'
   ```

4. **Complete example workflow**:
   ```bash
   # Example: Check if resources exist for a deleted cluster
   DELETED_INFRA_ID="server-foundation-sno-xyz123"

   # Check for any remaining resources
   aws ec2 describe-instances --region us-east-1 \
     --filters "Name=tag:kubernetes.io/cluster/$DELETED_INFRA_ID,Values=owned" \
     --query 'Reservations[*].Instances[*].[InstanceId,State.Name]'

   # If this returns resources, they are orphaned and can be cleaned up
   ```

### 12. Cleanup Orphaned Resources Using Hiveutil

**Recommended Method**: Use the `hiveutil` tool to automatically clean up all AWS resources for a deleted cluster.

`hiveutil` is a utility from the [OpenShift Hive project](https://github.com/openshift/hive) that can deprovision AWS assets created by the openshift-installer using resource tags.

#### Prerequisites

1. **Install hiveutil** (if not already installed):

   Check if hiveutil is available:
   ```bash
   which hiveutil
   hiveutil version
   ```

   If not installed, you can download it from the [OpenShift Hive releases](https://github.com/openshift/hive/releases) or build from source.

2. **Set AWS credentials** as environment variables:
   ```bash
   export AWS_ACCESS_KEY_ID=<your-access-key>
   export AWS_SECRET_ACCESS_KEY=<your-secret-key>
   ```

   Alternatively, use a credentials directory with the `--creds-dir` flag.

#### Cleanup Command

The command uses key=value tag pairs to identify resources:

```bash
hiveutil aws-tag-deprovision kubernetes.io/cluster/<infraID>=owned --region=<region>
```

**Available Flags**:
- `--region string`: AWS region to use (default: "us-east-1")
- `--creds-dir string`: Directory of AWS credentials (alternative to environment variables)
- `--cluster-domain string`: Parent DNS domain of the cluster (e.g., the domain after `api.`)
- `--hosted-zone-role string`: Role to assume for operations on hosted zones in other accounts
- `--loglevel string`: Log level (debug, info, warn, error, fatal, panic; default: "info")

This command will:
- Find all AWS resources tagged with the specified key=value pairs
- Deprovision resources in the correct order (instances -> load balancers -> subnets -> VPCs)
- Handle dependencies automatically
- A resource matches if ANY of the key/value pairs are in its tags

#### Example Workflow

```bash
# 1. Set AWS credentials
export AWS_ACCESS_KEY_ID=<your-access-key>
export AWS_SECRET_ACCESS_KEY=<your-secret-key>

# 2. Get infraID and region from cluster deployment (if still available)
CLUSTER_NS=$(oc get clusterclaim.hive -n server-foundation <claim-name> -ojsonpath='{.spec.namespace}')
INFRA_ID=$(oc get clusterdeployment.hive -n $CLUSTER_NS $CLUSTER_NS -o jsonpath='{.spec.clusterMetadata.infraID}')
REGION=$(oc get clusterdeployment.hive -n $CLUSTER_NS $CLUSTER_NS -o jsonpath='{.spec.platform.aws.region}')

# 3. Run cleanup (note: use = not : in the tag specification)
hiveutil aws-tag-deprovision kubernetes.io/cluster/$INFRA_ID=owned --region=$REGION

# Or if you already know the infraID and region
hiveutil aws-tag-deprovision kubernetes.io/cluster/server-foundation-sno-xyz123=owned --region=us-east-1

# For verbose output (useful for debugging)
hiveutil aws-tag-deprovision kubernetes.io/cluster/server-foundation-sno-xyz123=owned --region=us-east-1 --loglevel=debug
```

#### Cleanup Multiple Orphaned Resources

```bash
# Set AWS credentials
export AWS_ACCESS_KEY_ID=<your-access-key>
export AWS_SECRET_ACCESS_KEY=<your-secret-key>

# Get all active infraIDs
oc get clusterdeployment.hive --all-namespaces -l hive.openshift.io/clusterpool-namespace=server-foundation \
  -o jsonpath='{range .items[*]}{.spec.clusterMetadata.infraID}{"\n"}{end}' > /tmp/active-infra-ids.txt

# Get all VPCs and extract infraIDs
aws ec2 describe-vpcs --region us-east-1 \
  --filters "Name=tag:Name,Values=*server-foundation*,*sf-prow*" \
  --query 'Vpcs[*].Tags[?Key==`Name`].Value | []' \
  --output text | tr '\t' '\n' | sed 's/-vpc$//' | sort > /tmp/vpc-infra-ids.txt

# Find orphaned ones
comm -13 <(sort /tmp/active-infra-ids.txt) /tmp/vpc-infra-ids.txt > /tmp/orphaned-infra-ids.txt

# Review orphaned list
echo "=== Orphaned infraIDs ==="
cat /tmp/orphaned-infra-ids.txt

# Cleanup each orphaned infraID
while read infra_id; do
  echo "Cleaning up $infra_id"
  hiveutil aws-tag-deprovision kubernetes.io/cluster/$infra_id=owned --region=us-east-1
  echo "Completed cleanup for $infra_id"
  echo "---"
done < /tmp/orphaned-infra-ids.txt
```

**Important Notes**:
- Always verify the cluster is truly deleted before running cleanup
- The `hiveutil` tool handles the cleanup order automatically
- Check for running instances before cleanup to avoid accidentally terminating active resources
- Wait at least 1 hour after cluster deletion to allow Hive's automatic cleanup to complete

## Troubleshooting

### Pool Not Provisioning New Clusters

Check:
1. AWS quota limits (EC2 instances, VPCs)
2. Pool events: `oc get events -n server-foundation`
3. Hive operator logs (Hive operator runs in the `multicluster-engine` namespace):
   ```bash
   # Check hive operator pods
   oc get pods -n multicluster-engine | grep hive

   # Check hive operator logs
   oc logs -n multicluster-engine deployment/hive-operator
   ```

### Cluster Stuck in Installing State or Deletion Failing

When provisioning or destroying a cluster, Hive creates a pod in the cluster deployment namespace to perform the operation.

```bash
# Get namespace from claim first
CLUSTER_NS=$(oc get clusterclaim.hive -n server-foundation <claim-name> -ojsonpath='{.spec.namespace}')

# Get cluster deployment status
oc get clusterdeployment.hive -n $CLUSTER_NS $CLUSTER_NS -o yaml

# Check the provision/destroy pod logs
oc get pods -n $CLUSTER_NS
oc logs -n $CLUSTER_NS <install-pod-name> -c hive
```

Check:
- `.status.conditions`: Look for error messages
- `.status.installRestarts`: Number of installation retries
- **Pod logs**: The install/uninstall pod shows detailed progress and error messages
- AWS console for actual resource status

**Common pod patterns**:
- `<cluster-name>-<random>-provision`: Cluster provisioning pod
- `<cluster-name>-<random>-deprovision`: Cluster deletion pod

**Example**:
```bash
# Get the cluster namespace
CLUSTER_NS=$(oc get clusterclaim.hive -n server-foundation zhujian7-sno -ojsonpath='{.spec.namespace}')

# List all pods in the cluster namespace
oc get pods -n $CLUSTER_NS

# Check provision pod logs
oc logs -n $CLUSTER_NS server-foundation-sno-lite-abc123-xyz-provision -c hive

# If the pod has multiple containers, you can check all
oc logs -n $CLUSTER_NS server-foundation-sno-lite-abc123-xyz-provision --all-containers
```

### Hibernation Not Working

```bash
# Get namespace from claim first
CLUSTER_NS=$(oc get clusterclaim.hive -n server-foundation <claim-name> -ojsonpath='{.spec.namespace}')

# Describe cluster deployment
oc describe clusterdeployment.hive -n $CLUSTER_NS $CLUSTER_NS
```

Look for:
- Hibernation controller events
- AWS API errors
- Resource state mismatches

### CronJob Issues

If clusters aren't being hibernated or pools aren't scaling down automatically:

```bash
# Check cronjob status
oc get cronjob -n server-foundation

# View recent job executions
oc get jobs -n server-foundation --sort-by=.status.startTime

# Check specific cronjob logs
oc logs -n server-foundation -l job-name=scale-down-clusterpool --tail=100

# Check if cluster has opt-out label
oc get clusterclaim.hive -n server-foundation <claim-name> -o yaml | grep do-not-hibernate

# Check if pool has opt-out label
oc get clusterpool.hive -n server-foundation <pool-name> -o yaml | grep do-not-scale
```

Common issues:
- Check if the cluster has `do-not-hibernate=true` label (prevents hibernation)
- Check if the pool has `do-not-scale=true` label (prevents scaling down)
- Verify cronjob schedule timezone (Asia/Shanghai UTC+8)
- Check job execution history for failures: `oc describe cronjob -n server-foundation <cronjob-name>`

## Best Practices

1. **Regular Cleanup**:
   - Weekly check for orphaned AWS resources
   - Monthly review of cluster pool sizes vs. actual usage
   - Use `hiveutil aws-tag-deprovision` for cleanup instead of manual resource deletion

2. **Monitoring**:
   - Set alerts for pool depletion (all clusters claimed)
   - Monitor AWS quota usage
   - Check cronjob execution status regularly: `oc get cronjob -n server-foundation`

3. **Cost Optimization**:
   - Right-size pool sizes based on actual claim patterns
   - Ensure hibernation is working properly (hibernating clusters cost ~10% of running clusters)
   - Clean up orphaned resources promptly to avoid unnecessary AWS costs
   - Let automated cronjobs handle pool scaling and cluster hibernation
   - The cronjobs save 60-70% of AWS costs compared to 24/7 running clusters

4. **Working with Automated CronJobs**:
   - Label clusters with `do-not-hibernate=true` if they must run 24/7
   - Label pools with `do-not-scale=true` if they should maintain standby clusters
   - Be aware of the schedule: clusters hibernate at 11:00 daily (except Tuesday at 15:30)
   - Clusters automatically wake up at 00:30 Mon-Fri before work hours
   - If you need a cluster during off-hours, manually set powerState to Running

5. **Documentation**:
   - Keep track of which clusters are for what purpose
   - Document cleanup operations with infraID and timestamp
   - Document any clusters that should skip automated hibernation

## Safety Checks

Before deleting AWS resources:

1. **Verify cluster is truly deleted**:
   ```bash
   # Try to get the cluster deployment (use the cluster namespace as both namespace and name)
   oc get clusterdeployment.hive -n <cluster-namespace> <cluster-namespace>
   ```
   Should return "NotFound"

2. **Check cluster claim status**:
   ```bash
   oc get clusterclaim.hive -n server-foundation | grep <cluster-name>
   ```
   Should return nothing

3. **Verify infraID is not in active clusters**:
   ```bash
   # Get list of all active infraIDs
   oc get clusterdeployment.hive --all-namespaces -l hive.openshift.io/clusterpool-namespace=server-foundation \
     -o jsonpath='{range .items[*]}{.spec.clusterMetadata.infraID}{"\n"}{end}' | grep <infraID>
   ```
   Should return nothing if the cluster is deleted

4. **Check AWS resources using the infraID tag**:
   ```bash
   # Verify resources exist for this infraID before cleanup
   aws ec2 describe-instances --region <region> \
     --filters "Name=tag:kubernetes.io/cluster/<infraID>,Values=owned" \
     --query 'Reservations[*].Instances[*].[InstanceId,State.Name]'
   ```

5. **Wait period**: Wait at least 1 hour after cluster deletion before cleaning up AWS resources
   - Hive cleanup process may still be running

6. **Double-check tags**: Only delete resources with the `kubernetes.io/cluster/<infraID>: owned` tag matching the deleted cluster's infraID

## Usage Examples

**IMPORTANT**: When executing `oc` commands for cluster pool operations, ALWAYS prepend:
```bash
export KUBECONFIG=/tmp/kube/collective.kubeconfig &&
```

This ensures all cluster pool operations use the fixed kubeconfig path and work correctly in the user's environment.

When asked about cluster pools, you should:

1. **Status queries**: Use `oc` commands to get pool and cluster deployment status
2. **AWS cleanup**: Help identify orphaned resources by comparing `oc` output with AWS CLI results
3. **Cleanup operations**: Use `hiveutil aws-tag-deprovision` for automated resource cleanup
4. **Troubleshooting**: Check events, logs, and status conditions
5. **Cost analysis**: Calculate costs based on running vs hibernating clusters

Example workflow for "What AWS resources need cleanup?":
1. Get all current cluster deployment infraIDs using `oc get clusterdeployment.hive --all-namespaces -l hive.openshift.io/clusterpool-namespace=server-foundation -o jsonpath='{range .items[*]}{.spec.clusterMetadata.infraID}{"\n"}{end}'`
2. Query AWS for resources tagged with "server-foundation"
3. Compare the lists to identify orphaned infraIDs
4. Use `hiveutil aws-tag-deprovision kubernetes.io/cluster/<infraID>=owned --region=<region>` to clean up orphaned resources
