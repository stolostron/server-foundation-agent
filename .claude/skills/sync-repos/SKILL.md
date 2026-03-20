---
name: sync-repos
description: "Sync submodule repos under repos/ to latest remote commits. Use this skill to initialize or update all SF repo submodules. Trigger phrases: 'sync repos', 'update repos', 'update submodules', 'fetch repos', 'init repos', 'refresh repos'."
---

# Sync Repos Skill

Initializes or updates all git submodules under `repos/` to their latest remote commits.

## When to Use This Skill

- First time setup: initialize all submodules after cloning the agent repo
- Before searching/reading repo code: ensure submodules have the latest content
- Periodic refresh to keep reference copies up to date

## Usage

### Initialize submodules (first time)

```bash
./scripts/sync-repos.sh
```

### Update to latest remote commits

```bash
./scripts/sync-repos.sh --update
```

## How It Works

- Uses `git submodule update --init --depth 1` for initialization (shallow clone)
- Uses `git submodule update --remote --depth 1` for updates (fetches latest from remote)
- All submodules are shallow clones (depth 1) to save disk space
- Prints submodule status after completion

## Important

- `repos/` is **READ-ONLY** — submodules are reference copies for reading/searching only
- NEVER modify, branch, or commit inside `repos/`
- For code changes, use the [clone-worktree](../clone-worktree/SKILL.md) skill instead
