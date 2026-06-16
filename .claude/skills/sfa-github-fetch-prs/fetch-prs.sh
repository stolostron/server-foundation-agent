#!/usr/bin/env bash

# Fetch open PRs from Server Foundation stolostron downstream repos.
#
# Data source: repos/repos.yaml → repos.server-foundation.stolostron
# Fetches PRs per-repo using `gh pr list` — no GitHub Project Board needed.
#
# Usage:
#   ./fetch-prs.sh [detail_level] [nocache]
#
# Arguments:
#   detail_level - basic (default), detailed, or all
#   nocache      - skip cache and force fresh fetch
#
# Environment Variables:
#   CACHE_DIR  - Cache directory path (default: /tmp/sf-fetch-prs-$USER)
#   CACHE_TTL  - Cache TTL in seconds (default: 300)
#
# Example:
#   ./fetch-prs.sh
#   ./fetch-prs.sh detailed
#   ./fetch-prs.sh all nocache
#   CACHE_TTL=120 ./fetch-prs.sh all

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Colors for stderr logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Cache configuration
CACHE_DIR="${CACHE_DIR:-${TMPDIR:-/tmp}/sf-fetch-prs-${USER:-root}}"
CACHE_TTL="${CACHE_TTL:-300}"

get_cache_file() {
    local detail_level=$1
    echo "$CACHE_DIR/prs_sf_${detail_level}.json"
}

is_cache_valid() {
    local cache_file=$1
    [ -f "$cache_file" ] || return 1
    local file_mtime
    file_mtime=$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null)
    [ -n "$file_mtime" ] || return 1
    local age=$(( $(date +%s) - file_mtime ))
    if [ "$age" -lt "$CACHE_TTL" ]; then
        log_info "Cache valid (age: ${age}s, TTL: ${CACHE_TTL}s)"
        return 0
    fi
    log_info "Cache expired (age: ${age}s, TTL: ${CACHE_TTL}s)"
    return 1
}

save_to_cache() {
    local cache_file=$1
    local data=$2
    mkdir -p "$CACHE_DIR"
    echo "$data" > "$cache_file"
    log_info "Saved to cache: $cache_file"
}

load_from_cache() {
    local cache_file=$1
    cat "$cache_file"
    log_info "Loaded from cache: $cache_file"
}

# Get list of SF stolostron downstream repos from repos.yaml
get_sf_repos() {
    local repos_yaml="$REPO_ROOT/repos/repos.yaml"
    if [ ! -f "$repos_yaml" ]; then
        log_error "repos.yaml not found at $repos_yaml"
        return 1
    fi
    if command -v yq &>/dev/null; then
        yq eval '.repos.server-foundation.stolostron[].repo' "$repos_yaml"
        return 0
    fi
    log_warn "yq not found — parsing repos.yaml with awk fallback"
    awk '
      /^  deps:/ { exit }
      /^    stolostron:/ { in_sf_stolostron=1; next }
      in_sf_stolostron && /^    [a-z#]/ && !/^    stolostron:/ { in_sf_stolostron=0 }
      in_sf_stolostron && /- repo: stolostron\// { sub(/.*repo: /, ""); print }
    ' "$repos_yaml"
}

# Fetch open PRs from all SF stolostron downstream repos.
#
# Args:
#   $1 - Detail level: "basic" (default), "detailed", or "all"
#   $2 - "nocache" to skip cache
#
# Output: JSON array of PR objects to stdout.
#         Each PR has a .repository.nameWithOwner field added.
fetch_sf_prs() {
    local detail_level=${1:-"basic"}
    local skip_cache=${2:-""}
    local cache_file
    cache_file=$(get_cache_file "$detail_level")

    if [ "$skip_cache" != "nocache" ] && is_cache_valid "$cache_file"; then
        load_from_cache "$cache_file"
        return 0
    fi

    local fields
    case "$detail_level" in
        basic)
            fields="url,number,state,author,headRefName"
            ;;
        detailed)
            fields="url,number,title,state,createdAt,updatedAt,author,labels,headRefName"
            ;;
        all)
            fields="url,number,title,state,createdAt,updatedAt,mergedAt,closedAt,author,assignees,labels,comments,reviewDecision,isDraft,mergeable,headRefName,isCrossRepository"
            ;;
        *)
            log_error "Invalid detail level: $detail_level (use: basic, detailed, or all)"
            return 1
            ;;
    esac

    local repos
    repos=$(get_sf_repos) || return 1
    local repo_count
    repo_count=$(echo "$repos" | wc -l | tr -d ' ')
    log_info "Fetching open PRs from $repo_count SF stolostron repos..."

    local all_prs="[]"
    local i=0

    while IFS= read -r repo; do
        i=$((i + 1))
        log_info "[$i/$repo_count] $repo"
        local prs
        prs=$(gh pr list -R "$repo" --state open --limit 200 --json "$fields" 2>/dev/null) || {
            log_warn "Failed to fetch $repo, skipping"
            continue
        }

        # Add repository.nameWithOwner to each PR
        prs=$(echo "$prs" | jq --arg repo "$repo" \
            '[.[] | . + {repository: {nameWithOwner: $repo}}]')

        all_prs=$(echo "$all_prs" "$prs" | jq -s 'add')
    done <<< "$repos"

    local total
    total=$(echo "$all_prs" | jq 'length')
    log_info "Fetched $total open PRs from $repo_count repos"

    save_to_cache "$cache_file" "$all_prs"
    echo "$all_prs"
}

# Backward-compatible wrapper (old callers pass org + project_number)
fetch_project_prs() {
    fetch_sf_prs "${3:-basic}" "${4:-}"
}

# Filter PRs by state
filter_prs_by_state() {
    local prs=$1
    local state=$2
    echo "$prs" | jq --arg state "$state" '[.[] | select(.state == $state)]'
}

# Filter PRs by repository
filter_prs_by_repo() {
    local prs=$1
    local repo=$2
    echo "$prs" | jq --arg repo "$repo" '[.[] | select(.repository.nameWithOwner == $repo)]'
}

# Export variables and functions for sourcing
export REPO_ROOT CACHE_DIR CACHE_TTL
export -f fetch_sf_prs
export -f fetch_project_prs
export -f filter_prs_by_state
export -f filter_prs_by_repo
export -f get_cache_file
export -f is_cache_valid
export -f save_to_cache
export -f load_from_cache
export -f log_info
export -f log_warn
export -f log_error

# Main execution (only when run as script, not sourced)
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    log_info "Starting fetch-prs script..."

    if ! command -v gh &>/dev/null; then
        log_error "gh CLI is not installed. Please install it first: https://cli.github.com/"
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        log_error "jq is not installed. Please install it first."
        exit 1
    fi

    if ! gh auth status &>/dev/null; then
        log_error "Not authenticated with GitHub CLI. Please run: gh auth login"
        exit 1
    fi

    # Parse arguments
    DETAIL_LEVEL=${1:-"basic"}
    SKIP_CACHE=${2:-""}

    # Handle case where first arg is "nocache"
    if [ "$DETAIL_LEVEL" = "nocache" ]; then
        DETAIL_LEVEL="basic"
        SKIP_CACHE="nocache"
    fi

    if [[ ! "$DETAIL_LEVEL" =~ ^(basic|detailed|all)$ ]]; then
        echo "Usage: $0 [basic|detailed|all] [nocache]" >&2
        exit 1
    fi

    fetch_sf_prs "$DETAIL_LEVEL" "$SKIP_CACHE"
fi
