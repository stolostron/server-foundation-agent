#!/usr/bin/env bash
# MCE/ACM Release Verification Script
#
# Helper functions for finding which MCE/ACM release contains a specific commit.
# Usage: Source this script and call the functions as needed.

set -euo pipefail

# Get catalog bundle and save to temp file
# Args:
#   $1: OCP version (e.g., "4.18")
#   $2: Output file path
# Returns: 0 on success, 1 on error
get_catalog_bundle() {
  local ocp_version="$1"
  local output_file="$2"

  echo "Fetching MCE/ACM catalog for OCP ${ocp_version}..." >&2

  podman run --rm --entrypoint opm \
    "registry.redhat.io/redhat/redhat-operator-index:v${ocp_version}" \
    render /configs/multicluster-engine/ /configs/advanced-cluster-management/ \
    -o=yaml > "${output_file}"

  if [[ $? -ne 0 || ! -s "${output_file}" ]]; then
    echo "Error: Failed to fetch catalog bundle" >&2
    return 1
  fi

  echo "Catalog saved to ${output_file}" >&2
  return 0
}

# Get component image for a specific MCE/ACM version
# Args:
#   $1: Catalog file path
#   $2: Product (mce or acm)
#   $3: Version (e.g., "2.8.5")
#   $4: Component name (e.g., "managedcluster_import_controller")
# Returns: Image URL on stdout, empty if not found
get_component_image() {
  local catalog_file="$1"
  local product="$2"
  local version="$3"
  local component="$4"

  local bundle_name
  if [[ "${product}" == "mce" ]]; then
    bundle_name="multicluster-engine.v${version}"
  elif [[ "${product}" == "acm" ]]; then
    bundle_name="advanced-cluster-management.v${version}"
  else
    echo "Error: Invalid product '${product}'. Must be 'mce' or 'acm'" >&2
    return 1
  fi

  yq "select(.schema == \"olm.bundle\" and .name == \"${bundle_name}\") | \
      .relatedImages[] | \
      select(.name == \"${component}\") | \
      .image" "${catalog_file}"
}

# Get git commit from container image
# Args:
#   $1: Image URL (with SHA)
# Returns: Git commit hash on stdout
get_image_commit() {
  local image_url="$1"

  skopeo inspect --no-tags --override-os linux --override-arch amd64 \
    "docker://${image_url}" | \
    jq -r '.Labels["vcs-ref"] // .Labels["org.opencontainers.image.revision"] // .Labels["io.openshift.build.commit.id"] // ""'
}

# Find first release containing a commit
# Args:
#   $1: Catalog file path
#   $2: Product (mce or acm)
#   $3: Component name (e.g., "managedcluster_import_controller")
#   $4: Fix commit hash
#   $5: Repo path (for git merge-base check)
#   $6: Version pattern (e.g., "2.8" to check only 2.8.x versions)
# Returns: First version containing commit, empty if not found
find_first_release_with_commit() {
  local catalog_file="$1"
  local product="$2"
  local component="$3"
  local fix_commit="$4"
  local repo_path="$5"
  local version_pattern="${6:-}"

  local bundle_prefix
  if [[ "${product}" == "mce" ]]; then
    bundle_prefix="multicluster-engine.v"
  elif [[ "${product}" == "acm" ]]; then
    bundle_prefix="advanced-cluster-management.v"
  else
    echo "Error: Invalid product '${product}'" >&2
    return 1
  fi

  # List all versions
  local versions
  if [[ -n "${version_pattern}" ]]; then
    versions=$(yq 'select(.schema == "olm.bundle") | .name' "${catalog_file}" | \
      grep "^${bundle_prefix}${version_pattern}" | \
      sed "s/^${bundle_prefix}//" | \
      sort -V)
  else
    versions=$(yq 'select(.schema == "olm.bundle") | .name' "${catalog_file}" | \
      grep "^${bundle_prefix}" | \
      sed "s/^${bundle_prefix}//" | \
      sort -V)
  fi

  if [[ -z "${versions}" ]]; then
    echo "Error: No versions found for ${product} ${version_pattern:+matching ${version_pattern}}" >&2
    return 1
  fi

  # Check each version
  for version in ${versions}; do
    echo "Checking ${product} ${version}..." >&2

    local image
    image=$(get_component_image "${catalog_file}" "${product}" "${version}" "${component}")

    if [[ -z "${image}" ]]; then
      echo "  Component '${component}' not found in ${version}" >&2
      continue
    fi

    local release_commit
    release_commit=$(get_image_commit "${image}")

    if [[ -z "${release_commit}" ]]; then
      echo "  Warning: Could not extract commit from image" >&2
      continue
    fi

    echo "  Release commit: ${release_commit}" >&2

    # Check if fix commit is ancestor of release commit
    if (cd "${repo_path}" && git merge-base --is-ancestor "${fix_commit}" "${release_commit}" 2>/dev/null); then
      echo "  ✓ Fix is included!" >&2
      echo "${version}"
      return 0
    else
      echo "  ✗ Fix not yet included" >&2
    fi
  done

  echo "Error: Fix commit not found in any ${product} ${version_pattern:+${version_pattern}.x }release" >&2
  return 1
}

# Convert repo name to component name(s)
# Args:
#   $1: Repository name (e.g., "managedcluster-import-controller")
# Returns: Component name(s) on stdout (one per line)
repo_to_component() {
  local repo_name="$1"
  local exceptions_file="${EXCEPTIONS_FILE:-docs/build-release/repo-component-exceptions.yaml}"

  # Check multi-component repos
  local components
  components=$(yq ".multi_component_repos.\"${repo_name}\".components[]" "${exceptions_file}" 2>/dev/null || true)

  if [[ -n "${components}" ]]; then
    echo "${components}"
    return 0
  fi

  # Check naming exceptions
  local exception
  exception=$(yq ".naming_exceptions.\"${repo_name}\".component_name" "${exceptions_file}" 2>/dev/null || true)

  if [[ -n "${exception}" && "${exception}" != "null" ]]; then
    echo "${exception}"
    return 0
  fi

  # Check deprecated (still return name, but could warn)
  local deprecated
  deprecated=$(yq ".deprecated.\"${repo_name}\".component_name" "${exceptions_file}" 2>/dev/null || true)

  if [[ -n "${deprecated}" && "${deprecated}" != "null" ]]; then
    echo "${deprecated}"
    return 0
  fi

  # Default: replace hyphens with underscores
  echo "${repo_name//-/_}"
}

# Main CLI (when script is executed directly, not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    get_catalog_bundle|get_component_image|get_image_commit|find_first_release_with_commit|repo_to_component)
      "$@"
      ;;
    *)
      cat <<EOF
MCE/ACM Release Verification Script

Available functions:
  get_catalog_bundle <ocp_version> <output_file>
  get_component_image <catalog_file> <product> <version> <component>
  get_image_commit <image_url>
  find_first_release_with_commit <catalog_file> <product> <component> <fix_commit> <repo_path> [version_pattern]
  repo_to_component <repo_name>

Example:
  $0 get_catalog_bundle 4.18 /tmp/catalog.yaml
  $0 get_component_image /tmp/catalog.yaml mce 2.8.5 managedcluster_import_controller
  $0 repo_to_component managedcluster-import-controller
EOF
      exit 1
      ;;
  esac
fi
