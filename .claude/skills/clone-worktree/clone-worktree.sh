#!/usr/bin/env bash

# Clone a repository (bare) and create a git worktree for a specific PR branch
# or a new development branch using the fork workflow.
#
# Usage:
#   ./clone-worktree.sh <org/repo> <pr-number> [base-dir]
#   ./clone-worktree.sh --new <org/repo> <branch-name> [--base <base-branch>] [base-dir]
#   ./clone-worktree.sh --remove <org/repo> <pr-number|branch-name> [base-dir]
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
#   ./clone-worktree.sh --new stolostron/cluster-proxy upgrade-anp
#   ./clone-worktree.sh --new stolostron/cluster-proxy upgrade-anp --base main
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
    echo "       $0 --new <org/repo> <branch-name> [--base <base-branch>] [base-dir]" >&2
    echo "       $0 --remove <org/repo> <pr-number|branch-name> [base-dir]" >&2
    echo "" >&2
    echo "Modes:" >&2
    echo "  (default)   Check out an existing PR into a worktree" >&2
    echo "  --new       Create a new branch for development (uses fork workflow)" >&2
    echo "  --remove    Remove a worktree and its local branch" >&2
    echo "" >&2
    echo "Arguments:" >&2
    echo "  org/repo      - Full upstream repository name (e.g., stolostron/ocm)" >&2
    echo "  pr-number     - PR number to check out" >&2
    echo "  branch-name   - New branch name for --new mode" >&2
    echo "  --base        - Base branch to branch from (default: main)" >&2
    echo "  base-dir      - Base directory for clones (default: workspace)" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 stolostron/ocm 1234" >&2
    echo "  $0 --new stolostron/cluster-proxy upgrade-anp" >&2
    echo "  $0 --new open-cluster-management-io/cluster-proxy add-feature --base main" >&2
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

# Ensure bare clone exists, fetch if it does
# Args: bare_dir, clone_url
ensure_bare_clone() {
    local bare_dir=$1
    local clone_url=$2

    if [ -d "$bare_dir" ]; then
        log_info "Bare clone exists, fetching latest..."
        git -C "$bare_dir" fetch origin --force --prune
    else
        log_info "Creating bare clone: ${bare_dir}"
        mkdir -p "$(dirname "$bare_dir")"
        git clone --bare "$clone_url" "$bare_dir"

        # Configure fetch refspec for all branches
        git -C "$bare_dir" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
    fi
}

# Remove a worktree and its local branch
remove_worktree() {
    local repo_full=$1
    local ref_name=$2
    local base_dir=$3

    local org="${repo_full%%/*}"
    local repo="${repo_full##*/}"
    local bare_dir="${base_dir}/${org}/${repo}.git"
    local worktree_dir="${base_dir}/${org}/${repo}-worktrees/${ref_name}"

    # Also check pr-<number> naming for backward compatibility
    if [ ! -d "$worktree_dir" ]; then
        worktree_dir="${base_dir}/${org}/${repo}-worktrees/pr-${ref_name}"
    fi

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

    # Delete the local branch (try both pr-<number> and direct name)
    local branch_name="$ref_name"
    if git -C "$bare_dir" rev-parse --verify "$branch_name" &> /dev/null; then
        log_info "Deleting local branch: $branch_name"
        git -C "$bare_dir" branch -D "$branch_name"
    elif git -C "$bare_dir" rev-parse --verify "pr-${branch_name}" &> /dev/null; then
        log_info "Deleting local branch: pr-${branch_name}"
        git -C "$bare_dir" branch -D "pr-${branch_name}"
    fi

    log_info "Cleanup complete for: ${ref_name}"
}

# Create worktree for an existing PR
create_worktree_pr() {
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
    ensure_bare_clone "$bare_dir" "https://github.com/${repo_full}.git"

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

# Create worktree for a new development branch using fork workflow
create_worktree_new() {
    local repo_full=$1
    local branch_name=$2
    local base_branch=$3
    local base_dir=$4

    local org="${repo_full%%/*}"
    local repo="${repo_full##*/}"
    local bare_dir="${base_dir}/${org}/${repo}.git"
    local worktrees_dir="${base_dir}/${org}/${repo}-worktrees"
    local worktree_dir="${worktrees_dir}/${branch_name}"

    # Step 1: Ensure fork exists
    log_info "Ensuring fork exists for ${repo_full}..."
    gh repo fork "${repo_full}" --clone=false 2>&1 | grep -v "already exists" >&2 || true

    # Get current user's GitHub username
    local gh_user
    gh_user=$(gh api user -q '.login')
    if [ -z "$gh_user" ]; then
        log_error "Failed to get GitHub username"
        exit 1
    fi
    log_info "GitHub user: ${gh_user}"

    local fork_url="https://github.com/${gh_user}/${repo}.git"
    local upstream_url="https://github.com/${repo_full}.git"

    # Step 2: Bare clone from upstream (or reuse existing)
    ensure_bare_clone "$bare_dir" "$upstream_url"

    # Configure credentials for push
    configure_git_credentials "$bare_dir"

    # Step 3: Add fork as remote (for pushing)
    if git -C "$bare_dir" remote get-url fork &> /dev/null; then
        log_info "Fork remote already configured"
    else
        log_info "Adding fork remote: ${fork_url}"
        git -C "$bare_dir" remote add fork "$fork_url"
    fi

    # Step 4: Fetch upstream to get the latest base branch
    log_info "Fetching upstream ${base_branch}..."
    git -C "$bare_dir" fetch origin "${base_branch}" --force

    # Step 5: Create worktree with new branch from upstream base
    mkdir -p "$worktrees_dir"

    if [ -d "$worktree_dir" ]; then
        log_info "Worktree already exists, resetting..."
        git -C "$bare_dir" worktree remove "$worktree_dir" --force
        git -C "$bare_dir" worktree prune
        # Delete old local branch if exists
        git -C "$bare_dir" branch -D "$branch_name" 2>/dev/null || true
    fi

    log_info "Creating worktree: ${worktree_dir}"
    log_info "Branching '${branch_name}' from origin/${base_branch}"
    git -C "$bare_dir" worktree add -b "$branch_name" "$worktree_dir" "origin/${base_branch}"

    # Step 6: Configure worktree for fork workflow
    # origin = upstream (for fetching)
    git -C "$worktree_dir" config remote.origin.url "$upstream_url"
    git -C "$worktree_dir" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"

    # fork = user's fork (for pushing)
    if ! git -C "$worktree_dir" remote get-url fork &> /dev/null; then
        git -C "$worktree_dir" remote add fork "$fork_url"
    else
        git -C "$worktree_dir" remote set-url fork "$fork_url"
    fi

    # Set push to fork by default
    git -C "$worktree_dir" config "branch.${branch_name}.remote" fork
    git -C "$worktree_dir" config "branch.${branch_name}.merge" "refs/heads/${branch_name}"

    # Configure git identity for commits
    local git_name git_email
    git_name=$(git config --global user.name 2>/dev/null || echo "")
    git_email=$(git config --global user.email 2>/dev/null || echo "")
    if [ -n "$git_name" ]; then
        git -C "$worktree_dir" config user.name "$git_name"
    fi
    if [ -n "$git_email" ]; then
        git -C "$worktree_dir" config user.email "$git_email"
    fi

    # Print absolute path to stdout
    local abs_path
    abs_path=$(cd "$worktree_dir" && pwd)
    log_info "Worktree ready at: ${abs_path}"
    log_info "Branch '${branch_name}' created from origin/${base_branch}"
    log_info "Push target: fork (${gh_user}/${repo})"
    log_info ""
    log_info "Workflow:"
    log_info "  cd ${abs_path}"
    log_info "  # make changes, commit..."
    log_info "  git push fork ${branch_name}"
    log_info "  gh pr create --repo ${repo_full} --head ${gh_user}:${branch_name}"
    echo "$abs_path"
}

# --- Main ---

# Parse mode flag
MODE="pr"
if [ "${1:-}" = "--remove" ]; then
    MODE="remove"
    shift
elif [ "${1:-}" = "--new" ]; then
    MODE="new"
    shift
fi

# Validate minimum arguments
if [ $# -lt 2 ]; then
    usage
fi

REPO_FULL="$1"
shift
REF_NAME="$1"
shift

# Validate repo format (must contain exactly one slash)
if [[ ! "$REPO_FULL" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
    log_error "Invalid repository format: $REPO_FULL (expected: org/repo)"
    exit 1
fi

check_prerequisites

case "$MODE" in
    pr)
        # Validate PR number is numeric
        if [[ ! "$REF_NAME" =~ ^[0-9]+$ ]]; then
            log_error "Invalid PR number: $REF_NAME (must be a positive integer)"
            exit 1
        fi
        BASE_DIR="${1:-workspace}"
        create_worktree_pr "$REPO_FULL" "$REF_NAME" "$BASE_DIR"
        ;;
    new)
        # Parse optional --base flag and base-dir
        BASE_BRANCH="main"
        BASE_DIR="workspace"
        while [ $# -gt 0 ]; do
            case "$1" in
                --base)
                    shift
                    BASE_BRANCH="${1:-main}"
                    shift
                    ;;
                *)
                    BASE_DIR="$1"
                    shift
                    ;;
            esac
        done
        create_worktree_new "$REPO_FULL" "$REF_NAME" "$BASE_BRANCH" "$BASE_DIR"
        ;;
    remove)
        BASE_DIR="${1:-workspace}"
        remove_worktree "$REPO_FULL" "$REF_NAME" "$BASE_DIR"
        ;;
esac
