# Build & Release

Server Foundation components ship in two products: **MCE** (Multicluster Engine) and **ACM** (Advanced Cluster Management). MCE is a subset of ACM.

## Reference Materials

Load these on-demand based on the task:

| Reference | Path | When to Load |
|-----------|------|-------------|
| [Branch Tables](build-release/branch-tables.md) | `docs/build-release/branch-tables.md` | Looking up active branches, maintenance ranges, fast-forward targets |
| [MCE vs ACM Builds](build-release/mce-vs-acm-builds.md) | `docs/build-release/mce-vs-acm-builds.md` | Tekton, Dockerfile, publish job differences between MCE and ACM |

## Skills

For finding which release contains a commit, see:
- [`sfa-find-commit-release`](../../.claude/skills/sfa-find-commit-release/SKILL.md) - Find which MCE/ACM release contains a commit (CVE verification)
- [`sfa-jira-to-repo`](../../.claude/skills/sfa-jira-to-repo/SKILL.md) - Map Jira issue to GitHub repository

## Version Unification (2.17+)

Starting from **2.17**, MCE and ACM version numbers are unified — both use 2.17 instead of separate numbering. However, branch **prefixes** remain distinct: MCE repos still use `backplane-*` and ACM repos still use `release-*`.

## Fast-Forward Mechanism

Changes are committed **only to `main`** for current development. The `main` branch is then **automatically fast-forwarded** to the latest branch of each type:

- MCE repos: `main` → `backplane-2.17`
- ACM repos: `main` → `release-2.17`

**Never commit directly** to the latest release/backplane branch — it receives updates from `main` automatically.

## Build Path Summary

```
MCE path: main → backplane-2.17 → multicluster-engine/* images → MCE product
ACM path: main → release-2.17  → rhacm2/* images              → ACM product
```

The build infrastructure (Tekton pipelines, CI workflows, cluster pools, registries) is shared. The MCE/ACM distinction is primarily a naming and labeling difference.
