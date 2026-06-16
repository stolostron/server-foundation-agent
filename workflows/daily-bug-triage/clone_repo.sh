#!/usr/bin/env bash
# Shallow-clone one SF repo under repos/ (no yq, no full sync-repos.sh).
#
# Usage:
#   workflows/daily-bug-triage/clone_repo.sh stolostron/managedcluster-import-controller
#   workflows/daily-bug-triage/clone_repo.sh open-cluster-management-io/ocm
#
# Idempotent: skips if .git already exists.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: clone_repo.sh <org/repo> [branch]" >&2
  exit 1
fi

FULL_REPO="$1"
BRANCH="${2:-}"

ORG="${FULL_REPO%%/*}"
REPO="${FULL_REPO##*/}"

case "$ORG" in
  open-cluster-management-io) ORG_DIR="ocm-io" ;;
  *) ORG_DIR="$ORG" ;;
esac

# Default category layout matches repos/sync-repos.sh server-foundation paths.
CATEGORY="server-foundation"
CLONE_DIR="$(cd "$(dirname "$0")/../.." && pwd)/repos/${CATEGORY}/${ORG_DIR}/${REPO}"

if [[ -d "$CLONE_DIR/.git" ]]; then
  echo "Already cloned: $CLONE_DIR"
  exit 0
fi

mkdir -p "$(dirname "$CLONE_DIR")"
URL="https://github.com/${FULL_REPO}.git"

if [[ -n "$BRANCH" ]]; then
  git clone --depth 1 --branch "$BRANCH" "$URL" "$CLONE_DIR"
else
  git clone --depth 1 "$URL" "$CLONE_DIR"
fi

echo "Cloned: $CLONE_DIR"
