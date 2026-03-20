#!/usr/bin/env bash

# Scan workspace/ for worktrees and plain clones tied to closed/merged PRs, and remove them.
# Supports both worktree layout (bare repo + worktrees) and legacy plain clones.
#
# Usage:
#   ./cleanup-workspace.sh [workspace-dir]
#   ./cleanup-workspace.sh --dry-run [workspace-dir]
#
# How it works:
#   1. Scan for worktree directories (org/repo-worktrees/branch/) and plain clones
#   2. Detect the upstream repo and current branch
#   3. Search for a PR matching that branch in the upstream repo
#   4. If the PR is MERGED or CLOSED, remove the directory (and worktree ref)
#   5. If no PR is found or PR is still OPEN, skip it
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

# Check a single directory and clean if its PR is merged/closed
# Args: dir, bare_dir (optional, for worktree cleanup)
check_and_clean() {
    local dir=$1
    local bare_dir=${2:-}
    local name

    name=$(basename "$dir")
    log_info "Checking: $dir"

    # Get current branch
    local branch
    branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -z "$branch" ]; then
        log_warn "  Skipping — cannot detect branch"
        skipped=$((skipped + 1))
        return
    fi

    # Strip pr- prefix for PR number lookup
    local lookup_branch="$branch"
    local pr_number=""
    if [[ "$branch" =~ ^pr-([0-9]+)$ ]]; then
        pr_number="${BASH_REMATCH[1]}"
    fi

    if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
        log_warn "  Skipping — on default branch ($branch)"
        skipped=$((skipped + 1))
        return
    fi

    # Determine upstream repo from remotes
    # Prefer "upstream" remote, then "origin"
    local upstream_url
    upstream_url=$(git -C "$dir" remote get-url upstream 2>/dev/null || git -C "$dir" remote get-url origin 2>/dev/null)
    if [ -z "$upstream_url" ]; then
        log_warn "  Skipping — no remote found"
        skipped=$((skipped + 1))
        return
    fi

    # Extract org/repo from URL (handles both HTTPS and SSH)
    local repo_full
    repo_full=$(echo "$upstream_url" | sed -E 's|.*github\.com[:/]||; s|\.git$||')
    if [ -z "$repo_full" ]; then
        log_warn "  Skipping — cannot parse repo from URL: $upstream_url"
        skipped=$((skipped + 1))
        return
    fi

    log_info "  Repo: $repo_full, Branch: $branch"

    # Search for PR — by number if available, otherwise by head branch
    local pr_info
    if [ -n "$pr_number" ]; then
        pr_info=$(gh pr view "$pr_number" -R "$repo_full" --json number,state,title 2>/dev/null)
        if [ $? -ne 0 ] || [ -z "$pr_info" ]; then
            pr_info=""
        fi
    fi

    if [ -z "$pr_info" ]; then
        pr_info=$(gh pr list -R "$repo_full" --head "$lookup_branch" --state all --json number,state,title --limit 1 2>/dev/null)
        if [ $? -ne 0 ] || [ -z "$pr_info" ] || [ "$pr_info" = "[]" ]; then
            log_warn "  No PR found for branch '$lookup_branch' in $repo_full — skipping"
            skipped=$((skipped + 1))
            return
        fi
        # Extract from array
        pr_info=$(echo "$pr_info" | jq '.[0]')
    fi

    local pr_num pr_state pr_title
    pr_num=$(echo "$pr_info" | jq -r '.number')
    pr_state=$(echo "$pr_info" | jq -r '.state')
    pr_title=$(echo "$pr_info" | jq -r '.title')

    log_info "  PR #${pr_num}: ${pr_title} [${pr_state}]"

    if [ "$pr_state" = "OPEN" ]; then
        log_info "  PR is still OPEN — keeping"
        skipped=$((skipped + 1))
        return
    fi

    # PR is MERGED or CLOSED — clean up
    if [ "$DRY_RUN" = "true" ]; then
        log_action "[DRY-RUN] Would remove: $dir (PR #${pr_num} is ${pr_state})"
    else
        # If this is a worktree, remove via git worktree command first
        if [ -n "$bare_dir" ] && [ -d "$bare_dir" ]; then
            log_action "Removing worktree: $dir (PR #${pr_num} is ${pr_state})"
            git -C "$bare_dir" worktree remove "$dir" --force 2>/dev/null
            git -C "$bare_dir" worktree prune 2>/dev/null
            # Delete the local branch
            git -C "$bare_dir" branch -D "$branch" 2>/dev/null || true
        else
            log_action "Removing: $dir (PR #${pr_num} is ${pr_state})"
            rm -rf "$dir"
        fi

        if [ $? -eq 0 ]; then
            log_info "  Removed successfully"
        else
            log_error "  Failed to remove $dir"
            errors=$((errors + 1))
            return
        fi
    fi
    cleaned=$((cleaned + 1))
}

# --- Scan worktree layout: workspace/<org>/<repo>-worktrees/<branch>/ ---
for org_dir in "$WORKSPACE_DIR"/*/; do
    [ -d "$org_dir" ] || continue

    for worktrees_dir in "$org_dir"*-worktrees/; do
        [ -d "$worktrees_dir" ] || continue

        # Find the corresponding bare repo
        local_name=$(basename "$worktrees_dir" | sed 's/-worktrees$//')
        bare_dir="${org_dir}${local_name}.git"

        for wt_dir in "$worktrees_dir"/*/; do
            [ -d "$wt_dir" ] || continue
            # Verify it's a worktree (has .git file, not .git directory)
            if [ -f "$wt_dir/.git" ] || [ -d "$wt_dir/.git" ]; then
                check_and_clean "$wt_dir" "$bare_dir"
            fi
        done
    done
done

# --- Scan legacy plain clones: workspace/<name>/ ---
for dir in "$WORKSPACE_DIR"/*/; do
    [ -d "$dir/.git" ] || continue
    # Skip org directories (they contain worktrees, not plain clones)
    # An org dir won't have .git itself
    # Skip if it's already been handled as a worktree parent
    if ls "$dir"*-worktrees/ &>/dev/null 2>&1 || ls "$dir"*.git/ &>/dev/null 2>&1; then
        continue
    fi
    check_and_clean "$dir" ""
done

echo ""
echo "=== Cleanup Summary ==="
if [ "$DRY_RUN" = "true" ]; then
    echo "Mode: DRY-RUN (no changes made)"
fi
echo "Cleaned: $cleaned"
echo "Skipped: $skipped"
echo "Errors:  $errors"
