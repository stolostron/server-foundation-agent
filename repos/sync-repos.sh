#!/usr/bin/env bash
# Sync all repos defined in repos.yaml as shallow clones under repos/.
#
# Usage:
#   ./repos/sync-repos.sh [--init] # clone any missing repos
#   ./repos/sync-repos.sh --update # pull latest for all repos
#   ./repos/sync-repos.sh --status # show status of all repos

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOS_YAML="$SCRIPT_DIR/repos.yaml"
REPOS_DIR="$SCRIPT_DIR"

if ! command -v yq &>/dev/null; then
  echo "Error: yq is required but not found. Install with: brew install yq" >&2
  exit 1
fi

ACTION="${1:-"--init"}"

# Parse repos.yaml and yield lines: category org/repo [branch]
parse_repos() {
  # shellcheck disable=SC2016
  yq eval '
    .repos | to_entries[] | .key as $category |
    .value | to_entries[] | .key as $org_key |
    .value[] |
    $category + " " + .repo + " " + (.branch // "")
  ' "$REPOS_YAML"
}

clone_or_update() {
  local category="$1" full_repo="$2" branch="${3:-}"
  local org repo clone_dir

  org="${full_repo%%/*}"
  repo="${full_repo##*/}"

  # Determine org subdirectory name
  local org_dir="$org"
  if [[ "$org" == "open-cluster-management-io" ]]; then
    org_dir="ocm-io"
  fi

  clone_dir="$REPOS_DIR/$category/$org_dir/$repo"

  if [[ -d "$clone_dir/.git" ]]; then
    if [[ "$ACTION" == "--update" ]]; then
      echo "Updating $category/$org_dir/$repo ..."
      git -C "$clone_dir" fetch --depth 1 origin ${branch:+"$branch"} 2>&1 | sed 's/^/  /'
      local target="${branch:-$(git -C "$clone_dir" remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')}"
      git -C "$clone_dir" checkout "origin/$target" --detach -q 2>/dev/null || true
    else
      echo "Already cloned: $category/$org_dir/$repo"
    fi
  else
    echo "Cloning $category/$org_dir/$repo ..."
    mkdir -p "$(dirname "$clone_dir")"
    git clone --depth 1 ${branch:+--branch "$branch"} "https://github.com/$full_repo.git" "$clone_dir" 2>&1 | sed 's/^/  /'
  fi
}

show_status() {
  echo "Repository status under repos/:"
  echo ""
  parse_repos | while read -r category full_repo branch; do
    local org="${full_repo%%/*}" repo="${full_repo##*/}" org_dir
    if [[ "$org" == "open-cluster-management-io" ]]; then
      org_dir="ocm-io"
    else
      org_dir="$org"
    fi
    local clone_dir="$REPOS_DIR/$category/$org_dir/$repo"
    if [[ -d "$clone_dir/.git" ]]; then
      local sha
      sha=$(git -C "$clone_dir" rev-parse --short HEAD 2>/dev/null)
      printf "  %-60s %s\n" "$category/$org_dir/$repo" "$sha"
    else
      printf "  %-60s %s\n" "$category/$org_dir/$repo" "(not cloned)"
    fi
  done
}

case "$ACTION" in
  --status)
    show_status
    ;;
  --update)
    echo "Updating all repos to latest remote commits..."
    parse_repos | while read -r category full_repo branch; do
      clone_or_update "$category" "$full_repo" "$branch"
    done
    echo ""
    echo "Done."
    show_status
    ;;
  --init)
    echo "Cloning missing repos (shallow, depth 1)..."
    parse_repos | while read -r category full_repo branch; do
      clone_or_update "$category" "$full_repo" "$branch"
    done
    echo ""
    echo "Done."
    show_status
    ;;
  *)
    echo "Usage: $0 [--init|--update|--status]"
    exit 1
    ;;
esac
