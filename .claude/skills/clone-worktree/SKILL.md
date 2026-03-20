---
name: clone-worktree
description: "Clone a repository and create a git worktree for a specific PR branch or a new development branch. MUST be used for ALL workspace operations — never use plain 'git clone' into workspace/. Use this skill when you need to check out PR code locally, or start new development on any SF repo. Trigger phrases: 'clone worktree', 'checkout PR', 'clone PR', 'worktree for PR', 'fix PR', 'new branch', 'start development'."
---

# Clone Worktree Skill

This skill clones a GitHub repository (as a bare repo) and creates a git worktree, enabling concurrent development on the same repo with multiple branches.

**IMPORTANT:** This skill MUST be used for ALL code checkouts into `workspace/`. Never use plain `git clone` — it prevents concurrent development and breaks cleanup automation.

## Modes

### 1. PR Mode (default) — Check out an existing PR

```bash
.claude/skills/clone-worktree/clone-worktree.sh <org/repo> <pr-number>
```

### 2. New Branch Mode — Start new development

Uses the fork workflow automatically: ensures fork exists, branches from upstream, pushes to fork.

```bash
# Branch from main (default)
.claude/skills/clone-worktree/clone-worktree.sh --new <org/repo> <branch-name>

# Branch from a specific base branch
.claude/skills/clone-worktree/clone-worktree.sh --new <org/repo> <branch-name> --base release-2.14
```

### 3. Remove Mode — Clean up a worktree

```bash
.claude/skills/clone-worktree/clone-worktree.sh --remove <org/repo> <pr-number|branch-name>
```

## Directory Layout

All modes produce the same consistent layout under `workspace/`:

```
workspace/
  stolostron/
    cluster-proxy.git/                  # bare clone (shared git database)
    cluster-proxy-worktrees/
      pr-1234/                          # PR checkout (PR mode)
      upgrade-anp/                      # new branch (new mode)
      fix-tls/                          # another new branch (concurrent!)
```

This layout enables **concurrent development** — multiple worktrees share one bare clone, so you can work on several branches of the same repo simultaneously.

## Fork Workflow (New Branch Mode)

The `--new` mode automates the full fork workflow:

1. `gh repo fork <upstream> --clone=false` — ensures your fork exists
2. Bare clone from **upstream** (reuse if exists)
3. Add your fork as the `fork` remote
4. Create new branch from `origin/<base-branch>` (upstream)
5. Configure `git push` to push to your **fork** by default

After making changes:

```bash
cd workspace/<org>/<repo>-worktrees/<branch>/
# make changes, commit...
git push fork <branch-name>
gh pr create --repo <org/repo> --head <your-user>:<branch-name>
```

## Input

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `org/repo` | Yes | — | Full upstream repository name (e.g., `stolostron/ocm`) |
| `pr-number` | Yes (PR mode) | — | PR number to check out |
| `branch-name` | Yes (new mode) | — | New branch name |
| `--base` | No | `main` | Base branch to branch from (new mode only) |
| `base-dir` | No | `workspace` | Base directory for clones and worktrees |

## Output

On success, prints the **absolute path** to the worktree directory on stdout. All status messages go to stderr.

## Prerequisites

- `git` CLI installed
- `gh` CLI installed and authenticated
- `GITHUB_TOKEN` environment variable set (for push access)
- `jq` installed (PR mode only)

## Error Handling

- Exits with code 1 on any failure
- All errors logged to stderr with `[ERROR]` prefix
- Fork PRs (cross-repository) are detected and skipped in PR mode

## Idempotency

Running the script twice with the same arguments is safe:
- If the bare clone already exists, it fetches instead of re-cloning
- If the worktree already exists, it resets to the latest state
