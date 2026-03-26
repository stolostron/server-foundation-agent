#!/bin/bash
set -euo pipefail

# =============================================================================
# ACM Uninstaller for OpenShift
# =============================================================================

# Defaults
KUBECONFIG_PATH="${KUBECONFIG:-}"
SKIP_CLUSTER_CHECK=false
DEPROVISION_ALL=false
FORCE=false

ACM_NAMESPACE="open-cluster-management"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# =============================================================================
# Argument Parsing
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kubeconfig)         KUBECONFIG_PATH="$2"; shift 2 ;;
            --skip-cluster-check) SKIP_CLUSTER_CHECK=true; shift ;;
            --deprovision-all)    DEPROVISION_ALL=true; shift ;;
            --force|--yes|-y)     FORCE=true; shift ;;
            -h|--help)            usage; exit 0 ;;
            *)                    error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Uninstall ACM from an OpenShift cluster.

Options:
  --kubeconfig PATH       Path to kubeconfig file
  --skip-cluster-check    Skip managed cluster check
  --deprovision-all       Deprovision all Hive clusters without prompting
  --force, --yes, -y      Skip all confirmation prompts (for automation)
  -h, --help              Show this help message

Examples:
  $(basename "$0")
  $(basename "$0") --force
  $(basename "$0") --yes
  $(basename "$0") --deprovision-all
EOF
}

confirm() {
    local msg="$1"
    if [[ "$FORCE" == true ]]; then
        return 0
    fi
    read -rp "$msg [y/N]: " answer
    [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]]
}

# =============================================================================
# Cluster Connectivity
# =============================================================================
check_cluster() {
    info "Checking OCP cluster connectivity..."

    if [[ -n "$KUBECONFIG_PATH" ]]; then
        export KUBECONFIG="$KUBECONFIG_PATH"
        info "Using kubeconfig: $KUBECONFIG_PATH"
    fi

    if oc cluster-info &>/dev/null; then
        ok "Connected to OCP cluster"
        oc cluster-info 2>/dev/null | head -2
        echo ""
    else
        error "Not connected to any OCP cluster"
        exit 1
    fi
}

# =============================================================================
# Step 1: Check Managed Clusters
# =============================================================================
check_managed_clusters() {
    if [[ "$SKIP_CLUSTER_CHECK" == true ]]; then
        info "Skipping managed cluster check (--skip-cluster-check)"
        return
    fi

    info "Checking managed clusters..."

    local clusters
    clusters=$(oc get managedclusters --no-headers 2>/dev/null | grep -v "local-cluster" || true)

    if [[ -z "$clusters" ]]; then
        ok "No managed clusters found (excluding local-cluster)"
        return
    fi

    echo ""
    warn "Found managed clusters (excluding local-cluster):"
    echo "$clusters"
    echo ""

    # Check for Hive-provisioned clusters (those with a matching ClusterDeployment)
    local hive_clusters=""
    while read -r line; do
        local cluster_name
        cluster_name=$(echo "$line" | awk '{print $1}')
        if oc get clusterdeployment "$cluster_name" -n "$cluster_name" &>/dev/null; then
            hive_clusters="${hive_clusters}${cluster_name}"$'\n'
        fi
    done <<< "$clusters"

    if [[ -n "$hive_clusters" ]]; then
        hive_clusters=$(echo "$hive_clusters" | sed '/^$/d')
        echo ""
        warn "Hive-provisioned clusters detected:"
        echo "$hive_clusters"
        echo ""

        local do_deprovision=false
        if [[ "$DEPROVISION_ALL" == true ]]; then
            do_deprovision=true
        elif confirm "Do you want to deprovision these Hive clusters? This will destroy the clusters"; then
            do_deprovision=true
        fi

        if [[ "$do_deprovision" == true ]]; then
            while read -r cluster_name; do
                [[ -z "$cluster_name" ]] && continue
                deprovision_hive_cluster "$cluster_name"
            done <<< "$hive_clusters"
        else
            warn "Skipping Hive cluster deprovisioning"
            warn "These clusters will become orphaned after ACM uninstall"
        fi
    fi

    # Detach non-Hive managed clusters
    local non_hive_clusters=""
    while read -r line; do
        local cluster_name
        cluster_name=$(echo "$line" | awk '{print $1}')
        if ! oc get clusterdeployment "$cluster_name" -n "$cluster_name" &>/dev/null; then
            non_hive_clusters="${non_hive_clusters}${cluster_name}"$'\n'
        fi
    done <<< "$clusters"

    if [[ -n "$non_hive_clusters" ]]; then
        non_hive_clusters=$(echo "$non_hive_clusters" | sed '/^$/d')
        warn "Non-Hive managed clusters (imported):"
        echo "$non_hive_clusters"
        echo ""
        info "These clusters will be detached during MCH deletion"
    fi
}

deprovision_hive_cluster() {
    local cluster_name="$1"
    info "Deprovisioning Hive cluster: $cluster_name ..."

    # Delete the ClusterDeployment (triggers deprovision)
    oc delete clusterdeployment "$cluster_name" -n "$cluster_name" --wait=false 2>/dev/null || true

    ok "Deprovision initiated for $cluster_name"
    info "Waiting for cluster $cluster_name to be deprovisioned..."

    local retries=0
    while [[ $retries -lt 60 ]]; do
        if ! oc get clusterdeployment "$cluster_name" -n "$cluster_name" &>/dev/null; then
            ok "Cluster $cluster_name deprovisioned successfully"
            # Clean up the managed cluster resource
            oc delete managedcluster "$cluster_name" --wait=false 2>/dev/null || true
            return
        fi
        sleep 30
        retries=$((retries + 1))
        info "Still waiting for $cluster_name deprovision... (${retries}/60)"
    done

    warn "Cluster $cluster_name deprovision is still in progress. Continuing with uninstall..."
}

# =============================================================================
# Step 2: Delete MultiClusterHub
# =============================================================================
delete_mch() {
    info "Checking for MultiClusterHub..."

    local mch_name
    mch_name=$(oc get multiclusterhub -n "$ACM_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$mch_name" ]]; then
        warn "No MultiClusterHub found in namespace $ACM_NAMESPACE"
        return
    fi

    info "Found MultiClusterHub: $mch_name"

    if ! confirm "Delete MultiClusterHub '$mch_name'?"; then
        error "Uninstall cancelled by user"
        exit 0
    fi

    info "Deleting MultiClusterHub $mch_name ..."
    oc delete multiclusterhub "$mch_name" -n "$ACM_NAMESPACE" --wait=false

    info "Waiting for MultiClusterHub to be fully removed..."
    local retries=0
    while [[ $retries -lt 60 ]]; do
        if ! oc get multiclusterhub "$mch_name" -n "$ACM_NAMESPACE" &>/dev/null; then
            ok "MultiClusterHub $mch_name deleted successfully"
            return
        fi
        local phase
        phase=$(oc get multiclusterhub "$mch_name" -n "$ACM_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        info "MCH phase: $phase (waiting... ${retries}/60)"
        sleep 15
        retries=$((retries + 1))
    done

    warn "MultiClusterHub deletion is taking longer than expected"
    warn "Check status: oc get multiclusterhub -n $ACM_NAMESPACE"
}

# =============================================================================
# Step 3: Delete Subscription and CSV
# =============================================================================
delete_subscription_and_csv() {
    info "Cleaning up ACM Subscription and CSV..."

    # Delete Subscription
    local sub_name
    sub_name=$(oc get subscription -n "$ACM_NAMESPACE" -o jsonpath='{.items[?(@.spec.name=="advanced-cluster-management")].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "$sub_name" ]]; then
        info "Deleting Subscription: $sub_name"
        oc delete subscription "$sub_name" -n "$ACM_NAMESPACE"
        ok "Subscription $sub_name deleted"
    else
        warn "No ACM Subscription found"
    fi

    # Delete CSV
    local csv_name
    csv_name=$(oc get csv -n "$ACM_NAMESPACE" -o name 2>/dev/null | grep "advanced-cluster-management" | head -1 || echo "")

    if [[ -n "$csv_name" ]]; then
        info "Deleting CSV: $csv_name"
        oc delete "$csv_name" -n "$ACM_NAMESPACE"
        ok "CSV deleted"
    else
        warn "No ACM ClusterServiceVersion found"
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo "============================================"
    echo "  ACM Uninstaller for OpenShift"
    echo "============================================"
    echo ""

    parse_args "$@"

    # Step 0: Check cluster connectivity
    check_cluster

    # Verify ACM is installed
    if ! oc get multiclusterhub -n "$ACM_NAMESPACE" &>/dev/null && \
       ! oc get subscription -n "$ACM_NAMESPACE" &>/dev/null; then
        warn "ACM does not appear to be installed in namespace $ACM_NAMESPACE"
        if ! confirm "Continue anyway?"; then
            exit 0
        fi
    fi

    if ! confirm "Proceed with ACM uninstall?"; then
        info "Uninstall cancelled."
        exit 0
    fi

    # Step 1: Check managed clusters
    check_managed_clusters

    # Step 2: Delete MultiClusterHub
    delete_mch

    # Step 3: Delete Subscription and CSV
    delete_subscription_and_csv

    echo ""
    echo "============================================"
    ok "ACM uninstall complete!"
    echo "============================================"
    echo ""
    echo "Note: The following resources may still exist and can be cleaned up manually:"
    echo "  - Namespace: $ACM_NAMESPACE"
    echo "  - CatalogSources in openshift-marketplace (acm-custom-registry, mce-custom-registry)"
    echo "  - ImageContentSourcePolicy: rhacm-repo"
}

main "$@"
