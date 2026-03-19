---
name: cleanup-workspace
description: "Clean up workspace/ by removing cloned repos whose PRs are already merged or closed. Use this skill when workspace gets cluttered with old worktrees. Trigger phrases: 'clean workspace', 'cleanup workspace', 'remove old worktrees', 'prune workspace'."
---

# Cleanup Workspace Skill

Scans the `workspace/` directory for cloned repos with branches tied to merged or closed PRs, and removes them.

## When to Use This Skill

- Workspace directory is cluttered with old clones from finished PRs
- Periodic maintenance to free disk space
- Before starting new work to keep the workspace clean

## Usage

### Dry Run (preview what would be removed)

```bash
.claude/skills/cleanup-workspace/cleanup-workspace.sh --dry-run workspace
```

### Actual Cleanup

```bash
.claude/skills/cleanup-workspace/cleanup-workspace.sh workspace
```

## How It Works

For each subdirectory in `workspace/`:

1. Detect the current git branch
2. Find the upstream repo from git remotes (`upstream` preferred, falls back to `origin`)
3. Search for a PR matching that branch via `gh pr list`
4. If the PR is **MERGED** or **CLOSED** → remove the directory
5. If the PR is **OPEN** or no PR is found → skip

## Safety

- Directories on `main`/`master` branch are always skipped
- Directories with no matching PR are skipped (not removed)
- Use `--dry-run` to preview before deleting
- Only removes directories whose PRs are confirmed closed/merged via GitHub API

## Prerequisites

- `gh` CLI installed and authenticated
- `jq` installed
