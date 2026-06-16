#!/usr/bin/env bash
# Ensure the sfa-assisted label exists on a repo and optionally apply it to a PR.
#
# GitHub rejects --add-label when the label is not defined on that repository
# (common on SF repos — the label is not org-wide). Always run this after gh pr create.
#
# Label create/add failures are NON-FATAL (exit 0) — the PR is already the deliverable.
# The GitHub App may lack admin:issues / label-create permission on some repos.
#
# Usage:
#   bash scripts/ensure-sfa-assisted-label.sh stolostron/managedcluster-import-controller 1131
#   bash scripts/ensure-sfa-assisted-label.sh stolostron/ocm   # create label only
set -uo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: ensure-sfa-assisted-label.sh <org/repo> [pr-number]" >&2
  exit 1
fi

REPO="$1"
PR="${2:-}"

if ! command -v gh &>/dev/null; then
  echo "Error: gh CLI required" >&2
  exit 1
fi

_label_exists() {
  gh label list --repo "$REPO" --limit 500 --json name -q '.[].name' 2>/dev/null \
    | grep -qx 'sfa-assisted'
}

_create_label() {
  if _label_exists; then
    return 0
  fi
  if gh label create sfa-assisted --repo "$REPO" \
    --description "Pull request created by server-foundation-agent (acm-agent)" \
    --color "0052CC" 2>/dev/null; then
    echo "Created label sfa-assisted on $REPO" >&2
    return 0
  fi
  echo "WARN: could not create sfa-assisted on $REPO (App may lack label admin permission)" >&2
  return 1
}

_apply_label() {
  if gh pr edit "$PR" --repo "$REPO" --add-label "sfa-assisted" 2>/dev/null; then
    echo "Applied sfa-assisted to $REPO#$PR" >&2
    return 0
  fi
  echo "WARN: could not add sfa-assisted to $REPO#$PR (label missing or insufficient permission)" >&2
  return 1
}

_create_label || true

if [[ -n "$PR" ]]; then
  if ! _apply_label; then
    echo "NOTE: PR was created; label is optional for merge. Pre-create sfa-assisted on $REPO or grant the App issues write access." >&2
  fi
fi

exit 0
