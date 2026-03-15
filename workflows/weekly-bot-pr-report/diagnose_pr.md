# Sub-Agent Instructions: Diagnose a Single Bot PR

You are a diagnosis sub-agent for the weekly bot PR report workflow. Your job is to diagnose **one** failing bot PR by applying failure patterns in order, and optionally attempt an auto-fix.

## Input

You receive a single PR object with these fields:

```json
{
  "number": 123,
  "repo": "stolostron/ocm",
  "short_repo": "ocm",
  "url": "https://github.com/stolostron/ocm/pull/123",
  "title": "Update golang.org/x/crypto",
  "author": "red-hat-konflux",
  "branch": "backplane-2.9",
  "age_days": 5,
  "is_fork": false,
  "check_status": "has_failures",
  "failed_checks": ["ci/prow/images", "ci/prow/e2e"],
  "all_checks": [{"name": "...", "bucket": "...", "link": "..."}]
}
```

## Pre-Checks

Before applying failure patterns, handle these cases:

### Fork Detection
If `is_fork` is `true`, the agent cannot push to external forks.
Write the result immediately:
```json
{
  "pattern_matched": "none",
  "action": "skipped-fork",
  "action_details": "Cross-repository PR — cannot push fixes to external fork"
}
```

### All Checks Passed
If `check_status` is `all_passed`, no diagnosis needed:
```json
{
  "pattern_matched": "none",
  "action": "recommend-merge",
  "action_details": "All CI checks passed"
}
```

### Pending Checks
If `check_status` is `all_pending` or `mixed` (has pending but no failures):
```json
{
  "pattern_matched": "none",
  "action": "pending",
  "action_details": "Checks still running"
}
```

## Failure Pattern Application

For PRs with `check_status == "has_failures"`, apply failure patterns **in order**. First match wins.

Read each failure pattern file from the `failure-patterns/` directory:

1. `workflows/weekly-bot-pr-report/failure-patterns/01-go-version-mismatch.md` (FP-01)
2. `workflows/weekly-bot-pr-report/failure-patterns/02-e2e-cluster-pool.md` (FP-02)
3. `workflows/weekly-bot-pr-report/failure-patterns/03-build-failure.md` (FP-03)

For each pattern:
1. Follow the **Detection** section to check if the pattern matches.
2. If matched, follow the **Fix Procedure** section to attempt a fix.
3. Follow the **Verification** section to confirm the fix.
4. **Stop** after the first matching pattern — do not check remaining patterns.

### Default (No Pattern Matched)

If no failure pattern matches:
```json
{
  "pattern_matched": "unknown",
  "action": "needs-manual",
  "action_details": "No known failure pattern matched. Failed checks: [list them]"
}
```

## Output

Write a diagnosis result JSON file to `.output/diagnoses/pr-<NUMBER>.json`:

```bash
mkdir -p .output/diagnoses
```

### Result Schema

```json
{
  "pr_number": 123,
  "repo": "stolostron/ocm",
  "url": "https://github.com/stolostron/ocm/pull/123",
  "title": "Update golang.org/x/crypto",
  "author": "red-hat-konflux",
  "branch": "backplane-2.9",
  "age_days": 5,
  "pattern_matched": "go-version-mismatch | e2e-cluster-pool | build-failure | none | unknown",
  "action": "recommend-merge | patched | retest | needs-manual | skipped-fork | pending",
  "action_details": "Human-readable description of what was found/done",
  "failed_checks": ["ci/prow/images", "ci/prow/e2e"],
  "is_fork": false
}
```

### Action Values

| Action | Meaning |
|--------|---------|
| `recommend-merge` | All checks passed — safe to merge |
| `patched` | Agent found and pushed a fix (FP-01 or FP-03) |
| `retest` | Infrastructure issue — recommend `/retest` (FP-02) |
| `needs-manual` | Agent could not fix automatically |
| `skipped-fork` | Cross-repo PR — cannot push to fork |
| `pending` | Checks still running |

## Skills Available

- **clone-worktree**: `.claude/skills/clone-worktree/SKILL.md` — Clone repo and create worktree for PR branch
- **fetch-prs**: `.claude/skills/fetch-prs/SKILL.md` — Fetch PR data (already done by main workflow)

## Important Notes

- Always clean up worktrees after use (even on failure).
- Do NOT push partial or broken code. If a fix attempt fails, record as `needs-manual`.
- Use `git commit -s` for all commits (signed-off-by).
- Write the result JSON even if diagnosis fails — the main workflow needs it.
