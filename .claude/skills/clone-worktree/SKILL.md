---
name: clone-worktree
description: "Clone a repository and create a git worktree for a specific PR branch. Use this skill when you need to check out PR code locally for inspection, testing, or fixing. Trigger phrases: 'clone worktree', 'checkout PR', 'clone PR', 'worktree for PR', 'fix PR'."
---

# Clone Worktree Skill

This skill clones a GitHub repository (as a bare repo) and creates a git worktree for a specific PR branch, enabling the agent to inspect, test, or fix PR code locally.

## When to Use This Skill

Use this skill when:

- You need to check out a PR's code locally to inspect, test, or fix it
- The bot PR report workflow identifies a failing PR that needs a fix
- You need to make changes to a PR branch and push them back

## Usage Instructions

### Basic Usage

```bash
.claude/skills/clone-worktree/clone-worktree.sh <org/repo> <pr-number>
```

### Custom Base Directory

```bash
.claude/skills/clone-worktree/clone-worktree.sh <org/repo> <pr-number> /path/to/base
```

### Remove a Worktree After Fixing

```bash
.claude/skills/clone-worktree/clone-worktree.sh --remove <org/repo> <pr-number>
```

## Input

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `org/repo` | Yes | — | Full repository name (e.g., `stolostron/ocm`) |
| `pr-number` | Yes | — | PR number to check out |
| `base-dir` | No | `workspaces/` | Base directory for clones and worktrees |

## Output

On success, prints the **absolute path** to the worktree directory on stdout. All status messages go to stderr.

### Directory Layout

```
workspaces/
  stolostron/
    ocm.git/                     # bare clone (git database only)
    ocm-worktrees/
      pr-1234/                   # working checkout for PR #1234
```

## Prerequisites

- `git` CLI installed
- `gh` CLI installed and authenticated
- `GITHUB_TOKEN` environment variable set (for push access)

## Error Handling

- Exits with code 1 on any failure (missing prerequisites, clone failure, fetch failure)
- All errors logged to stderr with `[ERROR]` prefix
- Fork PRs (cross-repository) are detected and skipped — the agent cannot push to external forks

## Cleanup

Use `--remove` mode to clean up a worktree and its local branch after you're done:

```bash
.claude/skills/clone-worktree/clone-worktree.sh --remove stolostron/ocm 1234
```

This removes the worktree directory and prunes the local branch reference.

## Idempotency

Running the script twice with the same arguments is safe:
- If the bare clone already exists, it fetches instead of re-cloning
- If the worktree already exists, it resets to the latest PR head
