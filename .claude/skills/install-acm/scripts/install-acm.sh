#!/bin/bash
set -euo pipefail

# =============================================================================
# ACM/MCE Installer for OpenShift
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
PRODUCT=""
INSTALL_TYPE=""
CATALOG_IMAGE=""
MCE_CATALOG_IMAGE=""
PULL_SECRET=""
CHANNEL=""
VERSION=""
MCE_VERSION=""
USE_LATEST=false
AUTO_CONFIRM=false
KUBECONFIG_PATH="${KUBECONFIG:-}"

# Quay.io registry settings
QUAY_REGISTRY="quay.io:443"
ACM_CATALOG_REPO="acm-d/acm-dev-catalog"
MCE_CATALOG_REPO="acm-d/mce-dev-catalog"

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
            --kubeconfig)    KUBECONFIG_PATH="$2"; shift 2 ;;
            --product)       PRODUCT="$2"; shift 2 ;;
            --type)          INSTALL_TYPE="$2"; shift 2 ;;
            --version)       VERSION="$2"; shift 2 ;;
            --catalog-image) CATALOG_IMAGE="$2"; shift 2 ;;
            --mce-catalog-image) MCE_CATALOG_IMAGE="$2"; shift 2 ;;
            --pull-secret)   PULL_SECRET="$2"; shift 2 ;;
            --channel)       CHANNEL="$2"; shift 2 ;;
            --latest)        USE_LATEST=true; shift ;;
            --yes|-y)        AUTO_CONFIRM=true; shift ;;
            -h|--help)       usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Install ACM or MCE on an OpenShift cluster.

Options:
  --kubeconfig PATH      Path to kubeconfig file
  --product PRODUCT      Product to install: acm or mce
  --type TYPE            Install type: downstream or release
  --version VERSION      Product version (e.g., 2.13, 2.17)
  --catalog-image IMAGE  Catalog image for downstream install (overrides --version/--latest)
  --pull-secret PATH     Path to pull-secret file for private registries
  --channel CHANNEL      Subscription channel (e.g., release-2.13)
  --latest               Use the latest downstream image for the given version
  --yes, -y              Skip interactive confirmation (for automation)
  -h, --help             Show this help message

Version Mapping (ACM -> MCE):
  ACM 2.17+  -> MCE 2.17+ (same minor version)
  ACM 2.16   -> MCE 2.11  (minor - 5)
  ACM 2.15   -> MCE 2.10  (minor - 5)

Examples:
  $(basename "$0")
  $(basename "$0") --product acm --type release --version 2.13
  $(basename "$0") --product acm --type downstream --version 2.13 --latest --pull-secret ~/pull-secret.json
  $(basename "$0") --product mce --type downstream --catalog-image quay.io:443/acm-d/mce-dev-catalog:2.8.0-DOWNSTREAM-2025-03-15
EOF
}

# =============================================================================
# ACM <-> MCE Version Mapping
# =============================================================================
acm_to_mce_version() {
    local acm_version="$1"
    local acm_minor
    acm_minor=$(echo "$acm_version" | cut -d. -f2)

    if [[ "$acm_minor" -ge 17 ]]; then
        echo "$acm_version"
    else
        local mce_minor=$((acm_minor - 5))
        echo "2.${mce_minor}"
    fi
}

mce_to_acm_version() {
    local mce_version="$1"
    local mce_minor
    mce_minor=$(echo "$mce_version" | cut -d. -f2)

    if [[ "$mce_minor" -ge 17 ]]; then
        echo "$mce_version"
    else
        local acm_minor=$((mce_minor + 5))
        echo "2.${acm_minor}"
    fi
}

# =============================================================================
# Quay.io API - Query Latest Tags
# =============================================================================
get_quay_token() {
    local repo="$1"

    if [[ -z "$PULL_SECRET" ]]; then
        return 1
    fi

    # Extract credentials from pull-secret for quay.io:443 or quay.io
    local auth_b64=""
    if command -v jq &>/dev/null; then
        auth_b64=$(jq -r '.auths["quay.io:443"].auth // .auths["quay.io"].auth // empty' "$PULL_SECRET" 2>/dev/null || echo "")
    elif command -v python3 &>/dev/null; then
        auth_b64=$(python3 -c "
import json
with open('$PULL_SECRET') as f:
    data = json.load(f)
auths = data.get('auths', {})
auth = auths.get('quay.io:443', auths.get('quay.io', {})).get('auth', '')
print(auth)
" 2>/dev/null || echo "")
    fi

    if [[ -z "$auth_b64" ]]; then
        return 1
    fi

    local creds
    creds=$(echo "$auth_b64" | base64 -d 2>/dev/null || echo "")
    if [[ -z "$creds" ]]; then
        return 1
    fi

    local username password
    username=$(echo "$creds" | cut -d: -f1)
    password=$(echo "$creds" | cut -d: -f2-)

    # Get bearer token from Quay.io Docker v2 auth endpoint
    local token
    token=$(curl -s -u "${username}:${password}" \
        "https://quay.io/v2/auth?service=quay.io&scope=repository:${repo}:pull" 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")

    if [[ -z "$token" ]]; then
        return 1
    fi

    echo "$token"
}

query_latest_tag() {
    local repo="$1"
    local version_prefix="$2"

    info "Querying latest DOWNSTREAM tag for ${version_prefix} from ${repo}..."

    local token
    token=$(get_quay_token "$repo") || true

    local tags_json=""
    if [[ -n "$token" ]]; then
        tags_json=$(curl -s -H "Authorization: Bearer $token" \
            "https://quay.io/v2/${repo}/tags/list" 2>/dev/null || echo "")
    else
        # Try without auth (works for public repos)
        tags_json=$(curl -s "https://quay.io/v2/${repo}/tags/list" 2>/dev/null || echo "")
    fi

    if [[ -z "$tags_json" ]]; then
        error "Failed to query tags from Quay.io"
        return 1
    fi

    # Filter DOWNSTREAM tags matching version prefix and pick the latest
    local latest_tag
    latest_tag=$(echo "$tags_json" | python3 -c "
import json, sys, re

data = json.load(sys.stdin)
tags = data.get('tags', [])

# Filter tags: match version_prefix and DOWNSTREAM pattern
prefix = '${version_prefix}'
downstream_tags = []
for tag in tags:
    if tag.startswith(prefix) and 'DOWNSTREAM' in tag:
        downstream_tags.append(tag)

if not downstream_tags:
    sys.exit(1)

# Sort by the timestamp embedded in the tag name (YYYY-MM-DD-HH-MM-SS)
# Format: 2.13.4-DOWNSTREAM-2025-08-27-16-20-05
downstream_tags.sort(reverse=True)
print(downstream_tags[0])
" 2>/dev/null) || true

    if [[ -z "$latest_tag" ]]; then
        error "No DOWNSTREAM tags found for version ${version_prefix}"
        return 1
    fi

    echo "$latest_tag"
}

list_available_versions() {
    local repo="$1"

    local token
    token=$(get_quay_token "$repo") || true

    local tags_json=""
    if [[ -n "$token" ]]; then
        tags_json=$(curl -s -H "Authorization: Bearer $token" \
            "https://quay.io/v2/${repo}/tags/list" 2>/dev/null || echo "")
    else
        tags_json=$(curl -s "https://quay.io/v2/${repo}/tags/list" 2>/dev/null || echo "")
    fi

    if [[ -z "$tags_json" ]]; then
        return 1
    fi

    echo "$tags_json" | python3 -c "
import json, sys, re

data = json.load(sys.stdin)
tags = data.get('tags', [])

versions = set()
for tag in tags:
    m = re.match(r'^(\d+\.\d+)\.\d+-DOWNSTREAM', tag)
    if m:
        versions.add(m.group(1))

for v in sorted(versions, key=lambda x: [int(p) for p in x.split('.')]):
    print(v)
" 2>/dev/null || true
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
        return 0
    fi

    warn "Not connected to any OCP cluster."
    echo ""
    echo "How would you like to connect?"
    echo "  1) Provide kubeconfig file path"
    echo "  2) Provide OCP API server URL and credentials"
    echo ""
    read -rp "Select [1/2]: " choice

    case "$choice" in
        1)
            read -rp "Enter kubeconfig path: " kc_path
            if [[ ! -f "$kc_path" ]]; then
                error "File not found: $kc_path"
                exit 1
            fi
            export KUBECONFIG="$kc_path"
            KUBECONFIG_PATH="$kc_path"
            ;;
        2)
            read -rp "OCP API server URL (e.g., https://api.mycluster.com:6443): " api_url
            read -rp "Username: " username
            read -rsp "Password: " password
            echo ""
            if ! oc login "$api_url" -u "$username" -p "$password" --insecure-skip-tls-verify=true; then
                error "Failed to login to OCP cluster"
                exit 1
            fi
            ;;
        *)
            error "Invalid choice"
            exit 1
            ;;
    esac

    if oc cluster-info &>/dev/null; then
        ok "Connected to OCP cluster"
        oc cluster-info 2>/dev/null | head -2
        echo ""
    else
        error "Failed to connect to OCP cluster"
        exit 1
    fi
}

# =============================================================================
# Interactive Prompts
# =============================================================================
prompt_product() {
    if [[ -n "$PRODUCT" ]]; then
        return
    fi
    echo "What would you like to install?"
    echo "  1) ACM (Advanced Cluster Management)"
    echo "  2) MCE (Multicluster Engine)"
    echo ""
    read -rp "Select [1/2]: " choice
    case "$choice" in
        1) PRODUCT="acm" ;;
        2) PRODUCT="mce" ;;
        *) error "Invalid choice"; exit 1 ;;
    esac
}

prompt_install_type() {
    if [[ -n "$INSTALL_TYPE" ]]; then
        return
    fi
    echo ""
    echo "Install type:"
    echo "  1) downstream (dev/pre-release build)"
    echo "  2) release (GA version from OperatorHub)"
    echo ""
    read -rp "Select [1/2]: " choice
    case "$choice" in
        1) INSTALL_TYPE="downstream" ;;
        2) INSTALL_TYPE="release" ;;
        *) error "Invalid choice"; exit 1 ;;
    esac
}

prompt_pull_secret() {
    if [[ "$INSTALL_TYPE" != "downstream" ]]; then
        return
    fi

    # If catalog image is already provided and not from acm-d, skip
    if [[ -n "$CATALOG_IMAGE" && "$CATALOG_IMAGE" != *"acm-d/"* ]]; then
        return
    fi

    if [[ -n "$PULL_SECRET" ]]; then
        if [[ ! -f "$PULL_SECRET" ]]; then
            error "Pull-secret file not found: $PULL_SECRET"
            exit 1
        fi
        return
    fi

    echo ""
    warn "Downstream installation requires a pull-secret for quay.io:443/acm-d/."
    echo "The pull-secret is used to:"
    echo "  - Query available image tags from Quay.io"
    echo "  - Configure the OCP cluster to pull downstream images"
    echo ""
    read -rp "Pull-secret file path: " input

    if [[ -z "$input" ]]; then
        error "Pull-secret is required for downstream installation"
        exit 1
    fi

    if [[ ! -f "$input" ]]; then
        error "File not found: $input"
        exit 1
    fi

    PULL_SECRET="$input"
}

prompt_version() {
    if [[ -n "$VERSION" ]]; then
        return
    fi

    # If catalog image is already provided, extract version from it
    if [[ -n "$CATALOG_IMAGE" ]]; then
        if [[ "$CATALOG_IMAGE" =~ :([0-9]+\.[0-9]+) ]]; then
            VERSION="${BASH_REMATCH[1]}"
            info "Auto-detected version from catalog image: $VERSION"
        fi
        return
    fi

    echo ""

    # Try to list available versions from Quay.io
    local repo
    if [[ "$PRODUCT" == "acm" ]]; then
        repo="$ACM_CATALOG_REPO"
    else
        repo="$MCE_CATALOG_REPO"
    fi

    info "Querying available versions from Quay.io..."
    local versions
    versions=$(list_available_versions "$repo" 2>/dev/null || echo "")

    if [[ -n "$versions" ]]; then
        echo ""
        echo "Available $(echo "$PRODUCT" | tr '[:lower:]' '[:upper:]') versions:"
        echo "$versions" | while read -r v; do
            if [[ "$PRODUCT" == "acm" ]]; then
                local mce_v
                mce_v=$(acm_to_mce_version "$v")
                echo "  $v  (MCE $mce_v)"
            else
                local acm_v
                acm_v=$(mce_to_acm_version "$v")
                echo "  $v  (ACM $acm_v)"
            fi
        done
        echo ""
    fi

    read -rp "Enter $(echo "$PRODUCT" | tr '[:lower:]' '[:upper:]') version (e.g., 2.13): " VERSION

    if [[ -z "$VERSION" ]]; then
        error "Version is required"
        exit 1
    fi

    # Show version mapping info
    if [[ "$PRODUCT" == "acm" ]]; then
        local mce_v
        mce_v=$(acm_to_mce_version "$VERSION")
        info "ACM $VERSION corresponds to MCE $mce_v"
    else
        local acm_v
        acm_v=$(mce_to_acm_version "$VERSION")
        info "MCE $VERSION corresponds to ACM $acm_v"
    fi
}

resolve_latest_image() {
    local repo="$1"
    local ver="$2"
    local label="$3"

    local tag="latest-${ver}"
    local image="${QUAY_REGISTRY}/${repo}:${tag}"
    ok "Using latest ${label} image: ${image}"
    echo "${image}"
}

resolve_mce_catalog_image() {
    # When installing ACM downstream, also resolve the MCE catalog image
    if [[ "$PRODUCT" != "acm" || "$INSTALL_TYPE" != "downstream" ]]; then
        return
    fi

    if [[ -n "$MCE_CATALOG_IMAGE" ]]; then
        return
    fi

    MCE_VERSION=$(acm_to_mce_version "$VERSION")
    info "Resolving MCE $MCE_VERSION catalog image (required by ACM)..."

    MCE_CATALOG_IMAGE=$(resolve_latest_image "$MCE_CATALOG_REPO" "$MCE_VERSION" "MCE") || {
        echo ""
        warn "Could not auto-detect MCE catalog image."
        read -rp "Enter MCE catalog image manually: " MCE_CATALOG_IMAGE
        if [[ -z "$MCE_CATALOG_IMAGE" ]]; then
            error "MCE catalog image is required for ACM downstream installation"
            exit 1
        fi
    }
}

prompt_catalog_image() {
    if [[ "$INSTALL_TYPE" != "downstream" ]]; then
        return
    fi

    if [[ -n "$CATALOG_IMAGE" ]]; then
        # Still need to resolve MCE image for ACM installs
        resolve_mce_catalog_image
        return
    fi

    local repo
    if [[ "$PRODUCT" == "acm" ]]; then
        repo="$ACM_CATALOG_REPO"
    else
        repo="$MCE_CATALOG_REPO"
    fi

    if [[ "$USE_LATEST" == true ]]; then
        CATALOG_IMAGE=$(resolve_latest_image "$repo" "$VERSION" "$(echo "$PRODUCT" | tr '[:lower:]' '[:upper:]')") || {
            error "Could not resolve latest image for $(echo "$PRODUCT" | tr '[:lower:]' '[:upper:]') $VERSION"
            exit 1
        }
        resolve_mce_catalog_image
        return
    fi

    echo ""
    echo "Catalog image options:"
    echo "  1) Use the latest build for $(echo "$PRODUCT" | tr '[:lower:]' '[:upper:]') $VERSION (latest-${VERSION} tag)"
    echo "  2) Provide a specific catalog image"
    echo ""
    read -rp "Select [1/2]: " choice

    case "$choice" in
        1)
            CATALOG_IMAGE=$(resolve_latest_image "$repo" "$VERSION" "$(echo "$PRODUCT" | tr '[:lower:]' '[:upper:]')") || {
                error "Could not resolve latest image for $(echo "$PRODUCT" | tr '[:lower:]' '[:upper:]') $VERSION"
                exit 1
            }
            ;;
        2)
            echo ""
            echo "Example: ${QUAY_REGISTRY}/${repo}:latest-${VERSION}"
            read -rp "Catalog image: " CATALOG_IMAGE
            if [[ -z "$CATALOG_IMAGE" ]]; then
                error "Catalog image is required"
                exit 1
            fi
            ;;
        *)
            error "Invalid choice"
            exit 1
            ;;
    esac

    resolve_mce_catalog_image
}

prompt_channel() {
    if [[ -n "$CHANNEL" ]]; then
        return
    fi

    if [[ -n "$VERSION" ]]; then
        if [[ "$PRODUCT" == "mce" ]]; then
            CHANNEL="stable-${VERSION}"
        else
            CHANNEL="release-${VERSION}"
        fi
        info "Auto-detected channel: $CHANNEL"
    else
        echo ""
        local example_channel
        if [[ "$PRODUCT" == "mce" ]]; then
            example_channel="stable-2.17"
        else
            example_channel="release-2.17"
        fi
        read -rp "Subscription channel (e.g., $example_channel): " CHANNEL
        if [[ -z "$CHANNEL" ]]; then
            error "Channel is required"
            exit 1
        fi
    fi
}

# =============================================================================
# Confirm Installation Details
# =============================================================================
confirm_installation_details() {
    local product_upper
    product_upper=$(echo "$PRODUCT" | tr '[:lower:]' '[:upper:]')

    echo ""
    echo "--------------------------------------------"
    echo "  Please confirm the installation details"
    echo "--------------------------------------------"
    echo ""
    echo "  Product:      $product_upper"
    echo "  Version:      $VERSION"
    echo "  Install Type: $INSTALL_TYPE"
    echo "  Channel:      $CHANNEL"
    if [[ "$INSTALL_TYPE" == "downstream" ]]; then
        if [[ "$PRODUCT" == "acm" ]]; then
            echo "  ACM Catalog:  $CATALOG_IMAGE"
            local mce_v
            mce_v=$(acm_to_mce_version "$VERSION")
            echo "  MCE Version:  $mce_v"
            echo "  MCE Catalog:  $MCE_CATALOG_IMAGE"
        else
            echo "  MCE Catalog:  $CATALOG_IMAGE"
        fi
    fi
    echo ""

    # Skip confirmation if auto-confirm is enabled
    if [[ "$AUTO_CONFIRM" == "true" ]]; then
        return 0
    fi

    read -rp "Are these details correct? [y/N]: " answer
    if [[ "$answer" != [yY] && "$answer" != [yY][eE][sS] ]]; then
        echo ""
        warn "Let's update the details."

        # Allow user to change version
        read -rp "Enter $product_upper version (current: $VERSION, press Enter to keep): " new_version
        if [[ -n "$new_version" ]]; then
            VERSION="$new_version"
            if [[ "$PRODUCT" == "mce" ]]; then
                CHANNEL="stable-${VERSION}"
            else
                CHANNEL="release-${VERSION}"
            fi

            # Re-resolve catalog images for downstream
            if [[ "$INSTALL_TYPE" == "downstream" ]]; then
                if [[ "$PRODUCT" == "acm" ]]; then
                    CATALOG_IMAGE="${QUAY_REGISTRY}/${ACM_CATALOG_REPO}:latest-${VERSION}"
                    local mce_v
                    mce_v=$(acm_to_mce_version "$VERSION")
                    MCE_CATALOG_IMAGE="${QUAY_REGISTRY}/${MCE_CATALOG_REPO}:latest-${mce_v}"
                    info "Updated ACM catalog: $CATALOG_IMAGE"
                    info "Updated MCE catalog: $MCE_CATALOG_IMAGE"
                else
                    CATALOG_IMAGE="${QUAY_REGISTRY}/${MCE_CATALOG_REPO}:latest-${VERSION}"
                    info "Updated MCE catalog: $CATALOG_IMAGE"
                fi
            fi
        fi

        # Allow user to change catalog image (downstream only)
        if [[ "$INSTALL_TYPE" == "downstream" ]]; then
            if [[ "$PRODUCT" == "acm" ]]; then
                read -rp "ACM catalog image (current: $CATALOG_IMAGE, press Enter to keep): " new_image
                if [[ -n "$new_image" ]]; then
                    CATALOG_IMAGE="$new_image"
                fi
                read -rp "MCE catalog image (current: $MCE_CATALOG_IMAGE, press Enter to keep): " new_mce_image
                if [[ -n "$new_mce_image" ]]; then
                    MCE_CATALOG_IMAGE="$new_mce_image"
                fi
            else
                read -rp "MCE catalog image (current: $CATALOG_IMAGE, press Enter to keep): " new_image
                if [[ -n "$new_image" ]]; then
                    CATALOG_IMAGE="$new_image"
                fi
            fi
        fi

        # Show updated details
        echo ""
        info "Updated installation details:"
        confirm_installation_details
    fi
}

display_summary() {
    local product_upper
    product_upper=$(echo "$PRODUCT" | tr '[:lower:]' '[:upper:]')

    echo ""
    echo "============================================"
    echo "  Installation Summary"
    echo "============================================"
    echo "  Product:       $product_upper"
    echo "  Version:       $VERSION"
    echo "  Install Type:  $INSTALL_TYPE"
    echo "  Channel:       $CHANNEL"
    if [[ "$INSTALL_TYPE" == "downstream" ]]; then
        if [[ "$PRODUCT" == "acm" ]]; then
            echo "  ACM Catalog:   $CATALOG_IMAGE"
            echo "  MCE Catalog:   $MCE_CATALOG_IMAGE"
            echo "  MCE Version:   $(acm_to_mce_version "$VERSION")"
        else
            echo "  MCE Catalog:   $CATALOG_IMAGE"
        fi
        if [[ -n "$PULL_SECRET" ]]; then
            echo "  Pull Secret:   $PULL_SECRET"
        fi
    fi
    if [[ "$PRODUCT" == "acm" ]]; then
        echo "  MCE Version:   $(acm_to_mce_version "$VERSION")"
    else
        echo "  ACM Version:   $(mce_to_acm_version "$VERSION")"
    fi
    echo "============================================"
}

# =============================================================================
# Installation Steps
# =============================================================================

configure_pull_secret() {
    if [[ -z "$PULL_SECRET" ]]; then
        return
    fi

    info "Configuring cluster pull-secret..."

    # Extract quay.io:443 credentials from the user's pull-secret file
    local creds=""
    if command -v jq &>/dev/null; then
        creds=$(jq -r '.auths["quay.io:443"].auth // .auths["quay.io"].auth // empty' "$PULL_SECRET" 2>/dev/null | base64 -d 2>/dev/null || echo "")
    elif command -v python3 &>/dev/null; then
        creds=$(python3 -c "
import json, base64
with open('$PULL_SECRET') as f:
    data = json.load(f)
auths = data.get('auths', {})
auth_b64 = auths.get('quay.io:443', auths.get('quay.io', {})).get('auth', '')
if auth_b64:
    print(base64.b64decode(auth_b64).decode())
" 2>/dev/null || echo "")
    fi

    if [[ -z "$creds" ]]; then
        error "Could not extract quay.io credentials from pull-secret file"
        exit 1
    fi

    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT

    # Export current cluster pull-secret
    oc get secret/pull-secret -n openshift-config --template='{{index .data ".dockerconfigjson" | base64decode}}' > "$temp_dir/pull_secret.yaml"

    # Merge quay.io:443 credentials using oc registry login
    oc registry login --registry="quay.io:443" --auth-basic="$creds" --to="$temp_dir/pull_secret.yaml"

    # Apply merged pull-secret back to cluster
    oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="$temp_dir/pull_secret.yaml"

    ok "Cluster pull-secret updated with quay.io:443 credentials"
}

create_image_content_source_policy() {
    if [[ "$INSTALL_TYPE" != "downstream" ]]; then
        return
    fi

    if oc get imagecontentsourcepolicy rhacm-repo &>/dev/null; then
        ok "ImageContentSourcePolicy rhacm-repo already exists"
        return
    fi

    info "Creating ImageContentSourcePolicy rhacm-repo..."
    cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: rhacm-repo
spec:
  repositoryDigestMirrors:
  - mirrors:
    - quay.io:443/acm-d
    source: registry.redhat.io/rhacm2
  - mirrors:
    - quay.io:443/acm-d
    source: registry.redhat.io/multicluster-engine
  - mirrors:
    - registry.redhat.io/openshift4/ose-oauth-proxy
    source: registry.access.redhat.com/openshift4/ose-oauth-proxy
EOF
    ok "ImageContentSourcePolicy rhacm-repo created"

    warn "ImageContentSourcePolicy may trigger node restarts. Waiting for nodes to be ready..."
    local retries=0
    while [[ $retries -lt 60 ]]; do
        local not_ready
        not_ready=$(oc get nodes --no-headers 2>/dev/null | grep -c "NotReady\|SchedulingDisabled" || true)
        not_ready=${not_ready:-0}
        if [[ "$not_ready" -eq 0 ]]; then
            ok "All nodes are ready"
            return
        fi
        info "Nodes not ready: $not_ready (waiting...)"
        sleep 30
        retries=$((retries + 1))
    done
    warn "Some nodes may still be restarting. Proceeding anyway..."
}

create_namespace() {
    local ns="$1"
    if oc get namespace "$ns" &>/dev/null; then
        ok "Namespace $ns already exists"
    else
        info "Creating namespace $ns..."
        oc create namespace "$ns"
        ok "Namespace $ns created"
    fi
}

create_operator_group() {
    local ns="$1"
    local og_name="$2"

    if oc get operatorgroup "$og_name" -n "$ns" &>/dev/null; then
        ok "OperatorGroup $og_name already exists"
        return
    fi

    info "Creating OperatorGroup $og_name..."
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${og_name}
  namespace: ${ns}
spec:
  targetNamespaces:
  - ${ns}
EOF
    ok "OperatorGroup $og_name created"
}

create_catalog_source() {
    local cs_name="$1"
    local image="$2"
    local display_name="$3"

    if oc get catalogsource "$cs_name" -n openshift-marketplace &>/dev/null; then
        warn "CatalogSource $cs_name already exists, updating..."
    fi

    info "Creating CatalogSource $cs_name..."
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${cs_name}
  namespace: openshift-marketplace
spec:
  displayName: ${display_name}
  image: ${image}
  publisher: Red Hat
  sourceType: grpc
EOF
    ok "CatalogSource $cs_name created"

    info "Waiting for CatalogSource to be ready..."
    local retries=0
    while [[ $retries -lt 30 ]]; do
        local state
        state=$(oc get catalogsource "$cs_name" -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
        if [[ "$state" == "READY" ]]; then
            ok "CatalogSource $cs_name is ready"
            return
        fi
        sleep 10
        retries=$((retries + 1))
    done
    warn "CatalogSource may not be ready yet. Proceeding anyway..."
}

create_subscription() {
    local ns="$1"
    local sub_name="$2"
    local package="$3"
    local channel="$4"
    local source="$5"

    if oc get subscription "$sub_name" -n "$ns" &>/dev/null; then
        warn "Subscription $sub_name already exists"
        return
    fi

    info "Creating Subscription $sub_name..."
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${sub_name}
  namespace: ${ns}
spec:
  channel: ${channel}
  installPlanApproval: Automatic
  name: ${package}
  source: ${source}
  sourceNamespace: openshift-marketplace
EOF
    ok "Subscription $sub_name created"
}

wait_for_csv() {
    local ns="$1"
    local prefix="$2"

    info "Waiting for ClusterServiceVersion to be ready..."
    local retries=0
    while [[ $retries -lt 60 ]]; do
        local csv
        csv=$(oc get csv -n "$ns" -o name 2>/dev/null | grep "$prefix" | head -1 || echo "")
        if [[ -n "$csv" ]]; then
            local phase
            phase=$(oc get "$csv" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [[ "$phase" == "Succeeded" ]]; then
                ok "$(echo "$csv" | sed 's|clusterserviceversion.operators.coreos.com/||') installed successfully"
                return
            fi
            info "CSV phase: $phase (waiting...)"
        fi
        sleep 15
        retries=$((retries + 1))
    done
    warn "CSV may not be fully ready. Check with: oc get csv -n $ns"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo "============================================"
    echo "  ACM/MCE Installer for OpenShift"
    echo "============================================"
    echo ""

    parse_args "$@"

    # Step 1: Check cluster connectivity
    check_cluster

    # Step 2: Gather configuration
    prompt_product
    prompt_install_type

    # For downstream: get pull-secret first (needed for Quay.io API queries)
    if [[ "$INSTALL_TYPE" == "downstream" ]]; then
        prompt_pull_secret
    fi

    prompt_version
    prompt_catalog_image
    prompt_channel

    # Confirm version details with user before proceeding
    confirm_installation_details

    # Display final summary and confirm
    display_summary
    echo ""

    # Skip final confirmation if auto-confirm is enabled
    if [[ "$AUTO_CONFIRM" != "true" ]]; then
        read -rp "Proceed with installation? [y/N]: " confirm
        if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
            info "Installation cancelled."
            exit 0
        fi
    fi

    # Step 3: Configure pull-secret (if needed)
    configure_pull_secret

    # Step 4: Create ImageContentSourcePolicy (downstream only)
    create_image_content_source_policy

    # Step 5: Set up variables based on product
    local namespace package sub_name og_name catalog_source csv_prefix
    if [[ "$PRODUCT" == "acm" ]]; then
        namespace="open-cluster-management"
        package="advanced-cluster-management"
        sub_name="acm-operator-subscription"
        og_name="open-cluster-management"
        catalog_source="acm-custom-registry"
        csv_prefix="advanced-cluster-management"
    else
        namespace="multicluster-engine"
        package="multicluster-engine"
        sub_name="mce-operator-subscription"
        og_name="multicluster-engine"
        catalog_source="mce-custom-registry"
        csv_prefix="multicluster-engine"
    fi

    # Step 6: Create namespace and operator group
    create_namespace "$namespace"
    create_operator_group "$namespace" "$og_name"

    # Step 7: Create CatalogSource(s) (downstream only)
    local source="redhat-operators"
    if [[ "$INSTALL_TYPE" == "downstream" ]]; then
        # Always create CatalogSource for the main product
        create_catalog_source "$catalog_source" "$CATALOG_IMAGE" "$(echo "$PRODUCT" | tr '[:lower:]' '[:upper:]') Custom Registry"
        source="$catalog_source"

        # For ACM, also create MCE CatalogSource
        if [[ "$PRODUCT" == "acm" && -n "$MCE_CATALOG_IMAGE" ]]; then
            create_catalog_source "mce-custom-registry" "$MCE_CATALOG_IMAGE" "MCE Custom Registry"
        fi
    fi

    # Step 8: Create Subscription
    create_subscription "$namespace" "$sub_name" "$package" "$CHANNEL" "$source"

    # Step 9: Wait for CSV
    wait_for_csv "$namespace" "$csv_prefix"

    # Step 10: Create MCH/MCE CR and wait for it to be ready
    echo ""
    if [[ "$PRODUCT" == "acm" ]]; then
        info "Creating MultiClusterHub CR..."
        cat <<EOF | oc apply -f -
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
spec: {}
EOF
        ok "MultiClusterHub CR created"

        info "Waiting for MultiClusterHub to be ready..."
        local retries=0
        while [[ $retries -lt 60 ]]; do
            local phase
            phase=$(oc get mch multiclusterhub -n open-cluster-management -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [[ "$phase" == "Running" ]]; then
                ok "MultiClusterHub is ready"
                break
            fi
            sleep 10
            retries=$((retries + 1))
            if [[ $((retries % 6)) -eq 0 ]]; then
                info "MCH phase: $phase (waiting...)"
            fi
        done
    else
        info "Creating MultiClusterEngine CR..."
        cat <<EOF | oc apply -f -
apiVersion: multicluster.openshift.io/v1
kind: MultiClusterEngine
metadata:
  name: multiclusterengine
spec: {}
EOF
        ok "MultiClusterEngine CR created"

        info "Waiting for MultiClusterEngine to be ready..."
        local retries=0
        while [[ $retries -lt 60 ]]; do
            local phase
            phase=$(oc get mce multiclusterengine -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [[ "$phase" == "Available" ]]; then
                ok "MultiClusterEngine is ready"
                break
            fi
            sleep 10
            retries=$((retries + 1))
            if [[ $((retries % 6)) -eq 0 ]]; then
                info "MCE phase: $phase (waiting...)"
            fi
        done
    fi

    echo ""
    echo "============================================"
    ok "$(echo "$PRODUCT" | tr '[:lower:]' '[:upper:]') $VERSION installation complete!"
    echo "============================================"
}

main "$@"
