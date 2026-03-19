#!/usr/bin/env bash

# Clone a repository (bare) and create a git worktree for a specific PR branch.
# Designed for the agent to check out PR code locally for inspection, testing, or fixing.
#
# Usage:
#   ./clone-worktree.sh <org/repo> <pr-number> [base-dir]
#   ./clone-worktree.sh --remove <org/repo> <pr-number> [base-dir]
#
# Environment Variables:
#   GITHUB_TOKEN - GitHub token for HTTPS push access (required for pushing)
#
# Output:
#   stdout: absolute path to the worktree directory
#   stderr: status/error messages
#
# Examples:
#   ./clone-worktree.sh stolostron/ocm 1234
#   ./clone-worktree.sh stolostron/ocm 1234 /tmp/repos
#   ./clone-worktree.sh --remove stolostron/ocm 1234

# Exit on undefined variables
set -u

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Log functions — all output to stderr so stdout stays clean for data
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Print usage and exit
usage() {
    echo "Usage: $0 <org/repo> <pr-number> [base-dir]" >&2
    echo "       $0 --remove <org/repo> <pr-number> [base-dir]" >&2
    echo "" >&2
    echo "Arguments:" >&2
    echo "  org/repo    - Full repository name (e.g., stolostron/ocm)" >&2
    echo "  pr-number   - PR number to check out" >&2
    echo "  base-dir    - Base directory for clones (default: workspaces/)" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --remove    - Remove a worktree and its local branch" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 stolostron/ocm 1234" >&2
    echo "  $0 --remove stolostron/ocm 1234" >&2
    exit 1
}

# Check that required CLI tools are available
check_prerequisites() {
    if ! command -v git &> /dev/null; then
        log_error "git is not installed"
        exit 1
    fi

    if ! command -v gh &> /dev/null; then
        log_error "gh CLI is not installed. Please install it: https://cli.github.com/"
        exit 1
    fi

    if ! gh auth status &> /dev/null; then
        log_error "Not authenticated with GitHub CLI. Please run: gh auth login"
        exit 1
    fi
}

# Configure git credential helper for HTTPS push using GITHUB_TOKEN
configure_git_credentials() {
    local bare_dir=$1

    if [ -z "${GITHUB_TOKEN:-}" ]; then
        log_warn "GITHUB_TOKEN is not set — push will not work without it"
        return 0
    fi

    # Set credential helper to use the token
    git -C "$bare_dir" config credential.helper \
        "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN}; }; f"
    log_info "Configured git credentials for HTTPS push"
}

# Remove a worktree and its local branch
remove_worktree() {
    local repo_full=$1
    local pr_number=$2
    local base_dir=$3

    local org="${repo_full%%/*}"
    local repo="${repo_full##*/}"
    local bare_dir="${base_dir}/${org}/${repo}.git"
    local worktree_dir="${base_dir}/${org}/${repo}-worktrees/pr-${pr_number}"

    if [ ! -d "$bare_dir" ]; then
        log_error "Bare clone not found: $bare_dir"
        exit 1
    fi

    if [ -d "$worktree_dir" ]; then
        log_info "Removing worktree: $worktree_dir"
        git -C "$bare_dir" worktree remove "$worktree_dir" --force
    else
        log_warn "Worktree directory does not exist: $worktree_dir"
    fi

    # Prune worktree references
    git -C "$bare_dir" worktree prune

    # Delete the local branch
    if git -C "$bare_dir" rev-parse --verify "pr-${pr_number}" &> /dev/null; then
        log_info "Deleting local branch: pr-${pr_number}"
        git -C "$bare_dir" branch -D "pr-${pr_number}"
    fi

    log_info "Cleanup complete for PR #${pr_number}"
}

# Main: clone repo and create worktree for a PR
create_worktree() {
    local repo_full=$1
    local pr_number=$2
    local base_dir=$3

    local org="${repo_full%%/*}"
    local repo="${repo_full##*/}"
    local bare_dir="${base_dir}/${org}/${repo}.git"
    local worktrees_dir="${base_dir}/${org}/${repo}-worktrees"
    local worktree_dir="${worktrees_dir}/pr-${pr_number}"

    # Check if this is a cross-repository (fork) PR
    log_info "Checking PR #${pr_number} in ${repo_full}..."
    local pr_info
    pr_info=$(gh pr view "$pr_number" -R "$repo_full" --json headRefName,isCrossRepository,headRepositoryOwner 2>&1)
    if [ $? -ne 0 ]; then
        log_error "Failed to fetch PR info: $pr_info"
        exit 1
    fi

    local is_fork
    is_fork=$(echo "$pr_info" | jq -r '.isCrossRepository')
    if [ "$is_fork" = "true" ]; then
        local fork_owner
        fork_owner=$(echo "$pr_info" | jq -r '.headRepositoryOwner.login')
        log_error "PR #${pr_number} is from a fork (${fork_owner}). Cannot push to fork PRs — skipping."
        exit 1
    fi

    local head_ref
    head_ref=$(echo "$pr_info" | jq -r '.headRefName')
    log_info "PR #${pr_number} branch: ${head_ref}"

    # Step 1: Bare clone or fetch
    if [ -d "$bare_dir" ]; then
        log_info "Bare clone exists, fetching latest..."
        git -C "$bare_dir" fetch origin --force
    else
        log_info "Creating bare clone: ${bare_dir}"
        mkdir -p "$(dirname "$bare_dir")"
        git clone --bare "https://github.com/${repo_full}.git" "$bare_dir"

        # Configure fetch refspec for all branches
        git -C "$bare_dir" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
    fi

    # Configure credentials for push
    configure_git_credentials "$bare_dir"

    # Step 2: Fetch PR head ref
    log_info "Fetching PR #${pr_number} head ref..."
    git -C "$bare_dir" fetch origin "pull/${pr_number}/head:pr-${pr_number}" --force

    # Step 3: Create or reset worktree
    mkdir -p "$worktrees_dir"

    if [ -d "$worktree_dir" ]; then
        log_info "Worktree already exists, resetting to latest PR head..."
        # Remove and recreate to ensure clean state
        git -C "$bare_dir" worktree remove "$worktree_dir" --force
        git -C "$bare_dir" worktree prune
    fi

    log_info "Creating worktree: ${worktree_dir}"
    git -C "$bare_dir" worktree add "$worktree_dir" "pr-${pr_number}"

    # Step 4: Configure worktree for pushing
    # Set push remote to the actual branch name so `git push` works correctly
    git -C "$worktree_dir" config remote.origin.url "https://github.com/${repo_full}.git"
    git -C "$worktree_dir" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"

    # Set upstream tracking so `git push` pushes to the correct branch
    git -C "$worktree_dir" config "branch.pr-${pr_number}.remote" origin
    git -C "$worktree_dir" config "branch.pr-${pr_number}.merge" "refs/heads/${head_ref}"

    # Configure git identity for commits
    git -C "$worktree_dir" config user.name "server-foundation-agent"
    git -C "$worktree_dir" config user.email "noreply@redhat.com"

    # Print absolute path to stdout
    local abs_path
    abs_path=$(cd "$worktree_dir" && pwd)
    log_info "Worktree ready at: ${abs_path}"
    log_info "PR branch '${head_ref}' checked out as local branch 'pr-${pr_number}'"
    echo "$abs_path"
}

# --- Main ---

# Parse --remove flag
REMOVE_MODE=false
if [ "${1:-}" = "--remove" ]; then
    REMOVE_MODE=true
    shift
fi

# Validate arguments
if [ $# -lt 2 ]; then
    usage
fi

REPO_FULL="$1"
PR_NUMBER="$2"
BASE_DIR="${3:-workspaces}"

# Validate repo format (must contain exactly one slash)
if [[ ! "$REPO_FULL" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
    log_error "Invalid repository format: $REPO_FULL (expected: org/repo)"
    exit 1
fi

# Validate PR number is numeric
if [[ ! "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
    log_error "Invalid PR number: $PR_NUMBER (must be a positive integer)"
    exit 1
fi

check_prerequisites

if [ "$REMOVE_MODE" = "true" ]; then
    remove_worktree "$REPO_FULL" "$PR_NUMBER" "$BASE_DIR"
else
    create_worktree "$REPO_FULL" "$PR_NUMBER" "$BASE_DIR"
fi
