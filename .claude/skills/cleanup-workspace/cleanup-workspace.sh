#!/usr/bin/env bash

# Scan workspace/ for cloned repos with branches tied to closed/merged PRs, and remove them.
#
# Usage:
#   ./cleanup-workspace.sh [workspace-dir]
#   ./cleanup-workspace.sh --dry-run [workspace-dir]
#
# How it works:
#   1. For each subdirectory in workspace/, detect the upstream repo and current branch
#   2. Search for a PR matching that branch in the upstream repo
#   3. If the PR is MERGED or CLOSED, remove the directory
#   4. If no PR is found or PR is still OPEN, skip it
#
# Output:
#   stdout: summary of actions taken
#   stderr: status messages

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_action(){ echo -e "${CYAN}[ACTION]${NC} $1" >&2; }

# Parse flags
DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=true
    shift
fi

WORKSPACE_DIR="${1:-workspace}"

if [ ! -d "$WORKSPACE_DIR" ]; then
    log_error "Workspace directory not found: $WORKSPACE_DIR"
    exit 1
fi

# Check prerequisites
if ! command -v gh &> /dev/null; then
    log_error "gh CLI is not installed"
    exit 1
fi

cleaned=0
skipped=0
errors=0

for dir in "$WORKSPACE_DIR"/*/; do
    [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || continue

    name=$(basename "$dir")
    log_info "Checking: $name"

    # Get current branch
    branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -z "$branch" ] || [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
        log_warn "  Skipping $name — on default branch ($branch)"
        skipped=$((skipped + 1))
        continue
    fi

    # Determine upstream repo from remotes
    # Prefer "upstream" remote, fall back to "origin"
    upstream_url=$(git -C "$dir" remote get-url upstream 2>/dev/null || git -C "$dir" remote get-url origin 2>/dev/null)
    if [ -z "$upstream_url" ]; then
        log_warn "  Skipping $name — no remote found"
        skipped=$((skipped + 1))
        continue
    fi

    # Extract org/repo from URL (handles both HTTPS and SSH)
    repo_full=$(echo "$upstream_url" | sed -E 's|.*github\.com[:/]||; s|\.git$||')
    if [ -z "$repo_full" ]; then
        log_warn "  Skipping $name — cannot parse repo from URL: $upstream_url"
        skipped=$((skipped + 1))
        continue
    fi

    log_info "  Repo: $repo_full, Branch: $branch"

    # Search for PR with this head branch
    pr_info=$(gh pr list -R "$repo_full" --head "$branch" --state all --json number,state,title --limit 1 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$pr_info" ] || [ "$pr_info" = "[]" ]; then
        log_warn "  No PR found for branch '$branch' in $repo_full — skipping"
        skipped=$((skipped + 1))
        continue
    fi

    pr_number=$(echo "$pr_info" | jq -r '.[0].number')
    pr_state=$(echo "$pr_info" | jq -r '.[0].state')
    pr_title=$(echo "$pr_info" | jq -r '.[0].title')

    log_info "  PR #${pr_number}: ${pr_title} [${pr_state}]"

    if [ "$pr_state" = "OPEN" ]; then
        log_info "  PR is still OPEN — keeping"
        skipped=$((skipped + 1))
        continue
    fi

    # PR is MERGED or CLOSED — clean up
    if [ "$DRY_RUN" = "true" ]; then
        log_action "[DRY-RUN] Would remove: $dir (PR #${pr_number} is ${pr_state})"
    else
        log_action "Removing: $dir (PR #${pr_number} is ${pr_state})"
        rm -rf "$dir"
        if [ $? -eq 0 ]; then
            log_info "  Removed successfully"
        else
            log_error "  Failed to remove $dir"
            errors=$((errors + 1))
            continue
        fi
    fi
    cleaned=$((cleaned + 1))
done

echo ""
echo "=== Cleanup Summary ==="
if [ "$DRY_RUN" = "true" ]; then
    echo "Mode: DRY-RUN (no changes made)"
fi
echo "Cleaned: $cleaned"
echo "Skipped: $skipped"
echo "Errors:  $errors"
