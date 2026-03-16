# Weekly Bot PR Report Workflow

Analyze all open bot-submitted PRs on the Server Foundation project board, diagnose CI failures using
failure pattern matching, attempt auto-fixes via sub-agents, and generate an actionable report.

## Trigger Phrases

- `weekly bot PR report`, `bot PR report`, `konflux PR report`
- `analyze bot PRs`, `check bot PR CI status`

## Workflow Phases

```
Phase 1: Collect    →  Phase 2: Classify     →  Phase 3: Diagnose      →  Phase 4: Report    →  Phase 5: Distribute
fetch-prs skill        jq + collect_checks      sub-agents per PR          generate Markdown       slack-notify
```

---

## Bundled Scripts

This workflow includes ready-to-use scripts. **Do NOT write your own processing scripts** — use the bundled ones:

```
workflows/weekly-bot-pr-report/
├── process_bot_prs.jq              # Phase 2: filter raw PRs to open bot PRs
├── collect_checks.py               # Phase 2: collect CI check results per PR
├── diagnose_pr.md                  # Phase 3: sub-agent instructions template
├── failure-patterns/
│   ├── 01-go-version-mismatch.md   # FP-01: Go version upgrade detection & fix
│   ├── 02-e2e-cluster-pool.md      # FP-02: E2E cluster pool claim failure
│   ├── 03-build-failure.md         # FP-03: Build compilation failure
│   └── 04-sonarcloud.md            # FP-04: SonarCloud code analysis failure
├── generate_report.py              # Phase 4: generate Markdown report
└── generate_slack_payload.py       # Phase 5: generate Slack payload
```

---

## Phase 1: Collect PR Data

Use the `fetch-prs` skill with `all` detail level to get full PR lifecycle data.

This returns a JSON array. Save it to a temp file for Phase 2.

**Dependency**: `.claude/skills/fetch-prs/SKILL.md`

---

## Phase 2: Classify

Run the bundled scripts to filter bot PRs and collect their CI check status.

### 2.1 Filter to Open Bot PRs

```bash
mkdir -p .output
jq --argjson today_sec $(date +%s) -f workflows/weekly-bot-pr-report/process_bot_prs.jq <raw_prs.json> > .output/bot_prs.json
```

The jq script keeps only open PRs authored by bots (red-hat-konflux, dependabot, renovate, `*[bot]`, `*-bot`) and produces flat fields: `.author`, `.repo`, `.short_repo`, `.title`, `.url`, `.number`, `.age_days`, `.branch`, `.is_fork`.

### 2.2 Collect CI Check Results

```bash
python3 workflows/weekly-bot-pr-report/collect_checks.py .output/bot_prs.json .output/bot_prs_with_checks.json
```

For each PR, runs `gh pr checks --json name,bucket,link` and augments the PR object with:

- `.check_status`: `"all_passed"` | `"has_failures"` | `"all_pending"` | `"mixed"` | `"no_checks"`
- `.failed_checks`: `["ci/prow/images", "ci/prow/e2e", ...]`
- `.all_checks`: `[{name, bucket, link}, ...]`

**Excluded from classification**: `tide` (always pending until merge labels), `SonarCloud Code Analysis` (code quality, not build).

### 2.3 Pre-Diagnosis Filtering

Before spawning sub-agents, separate PRs by check status:

| check_status | Category | Sub-agent needed? |
|--------------|----------|-------------------|
| `all_passed` | Recommend Merge | No — write result directly |
| `has_failures` | Needs diagnosis | **Yes** |
| `all_pending` | Pending | No — write result directly |
| `mixed` | Pending | No — write result directly |
| `no_checks` | Pending | No — write result directly |

For PRs that do NOT need a sub-agent, write their diagnosis result JSON directly to `.output/diagnoses/pr-<NUMBER>.json`.

---

## Phase 3: Diagnose (Sub-Agents)

For each PR with `check_status == "has_failures"`, spawn a **sub-agent** to diagnose and optionally fix it. This prevents context window exhaustion when processing many failing PRs.

### Sub-Agent Architecture

Each sub-agent:
1. Receives the PR metadata (from Phase 2 output)
2. Reads `workflows/weekly-bot-pr-report/diagnose_pr.md` for its instructions
3. Applies failure patterns from `workflows/weekly-bot-pr-report/failure-patterns/` **in order** (FP-01 → FP-02 → FP-03 → FP-04)
4. First match wins — stops checking after a pattern matches
5. For patterns requiring clone (FP-01, FP-03): uses the `clone-worktree` skill to check out code, attempt fix, push patch
6. Writes result to `.output/diagnoses/pr-<NUMBER>.json`

### Spawning Sub-Agents

Use the Task tool to spawn each sub-agent:

```
For each PR with has_failures:
  Task(
    subagent_type: "general-purpose",
    description: "Diagnose PR <repo>#<number>",
    prompt: "Read workflows/weekly-bot-pr-report/diagnose_pr.md for instructions.
             Here is the PR data: <PR_JSON>.
             Diagnose this PR and write the result to .output/diagnoses/pr-<NUMBER>.json"
  )
```

**Parallelism**: Spawn up to 3-5 sub-agents concurrently to speed up diagnosis. Each operates independently on its own PR.

**Fork detection**: Sub-agents check `is_fork` before cloning. If true, skip with `skipped-fork`.

### Diagnosis Result Schema

Each sub-agent writes a JSON file to `.output/diagnoses/pr-<NUMBER>.json`:

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

### Report Categories

| Category | Meaning | Source |
|----------|---------|--------|
| **Recommend Merge** | All checks passed | Pre-diagnosis filter |
| **Auto-Patched** | Agent found and pushed a fix | Sub-agent, FP-01, FP-03, or FP-04 |
| **Recommend Retest** | Infra issue, just needs `/retest` | Sub-agent, FP-02 |
| **Needs Manual** | Agent could not fix automatically | Sub-agent, default |
| **Skipped (Fork)** | Cross-repo PR, can't push | Sub-agent, fork detection |
| **Pending** | Checks still running | Pre-diagnosis filter |

---

## Phase 4: Generate Report

After all sub-agents complete, generate the Markdown report from collected diagnosis results:

```bash
python3 workflows/weekly-bot-pr-report/generate_report.py .output/diagnoses/ .output/bot_pr_report.md
```

The script reads all `pr-*.json` files from the diagnoses directory and produces a report with these sections:

1. Executive Summary (total, by category, by bot author)
2. Recommend Merge
3. Auto-Patched (with pattern matched and details)
4. Recommend Retest
5. Needs Manual Intervention (with failed checks and details)
6. Skipped (Fork PRs)
7. Pending
8. Per-Repository Summary
9. Per-Branch Summary

---

## Phase 5: Distribute

Generate the Slack payload and send it:

```bash
python3 workflows/weekly-bot-pr-report/generate_slack_payload.py .output/diagnoses/ .output/bot_slack_payload.json
bash .claude/skills/slack-notify/send_to_slack.sh .output/bot_slack_payload.json
```

**Dependencies**:
- `workflows/weekly-bot-pr-report/generate_slack_payload.py`
- `.claude/skills/slack-notify/send_to_slack.sh`

### Slack Message Structure

- **Header**: Robot emoji + "Bot PR Report — YYYY-MM-DD"
- **Summary**: Total PRs, health percentage (resolved/total), counts per category
- **Sections**: Recommend Merge, Auto-Patched, Recommend Retest, Needs Manual (show ALL PRs, no truncation)
- **Context footer**: Generation timestamp

### Health Score

Health = percentage of PRs resolved (merge + patched + retest) vs total:
- 60%+ = green heart
- 40-59% = yellow heart
- <40% = red heart

---

## Failure Patterns

Failure patterns are defined in `workflows/weekly-bot-pr-report/failure-patterns/` and applied in numeric order. Each pattern has a structured format with Detection, Fix Procedure, and Verification sections.

| ID | Pattern | Action on Match | Requires Clone |
|----|---------|-----------------|----------------|
| FP-01 | [Go Version Mismatch](weekly-bot-pr-report/failure-patterns/01-go-version-mismatch.md) | `patched` | Yes |
| FP-02 | [E2E Cluster Pool Claim](weekly-bot-pr-report/failure-patterns/02-e2e-cluster-pool.md) | `retest` | No |
| FP-03 | [Build Failure](weekly-bot-pr-report/failure-patterns/03-build-failure.md) | `patched` | Yes |
| FP-04 | [SonarCloud Code Analysis](weekly-bot-pr-report/failure-patterns/04-sonarcloud.md) | `patched` | Yes |

To add a new failure pattern:
1. Create `workflows/weekly-bot-pr-report/failure-patterns/NN-pattern-name.md`
2. Follow the frontmatter format (`id`, `name`, `action_on_match`, `requires_clone`)
3. Include Detection, Fix Procedure, and Verification sections
4. Add the pattern to the table above and to `diagnose_pr.md`

---

## Edge Cases

- **PR with no checks reported**: `gh pr checks` returns empty — treat as "Pending" (no_checks).
- **PR with only `tide` pending**: If the only non-pass check is `tide`, treat as "All pass".
- **`renovate/artifacts` check**: Note but do not treat as build failure — indicates Renovate could not auto-update lock files.
- **`SonarCloud Code Analysis`**: Now included in classification. FP-04 handles it when it's the only failing check.
- **Monorepo PRs (e.g., stolostron/ocm)**: A single PR may trigger checks for multiple components. All must pass.
- **Fork PRs (`isCrossRepository`)**: Sub-agent detects and skips — cannot push to external forks.
- **Checks still running**: If `check_status` is `mixed` (some pass, some pending, no failures), classify as Pending.

## Performance Notes

- Phase 2 makes one `gh pr checks` call per PR — runs sequentially to avoid GitHub API rate limiting
- Phase 3 sub-agents run in parallel (up to 3-5 concurrent) for faster diagnosis
- Use `gh pr diff --name-only` (not full diff) to minimize API data transfer in sub-agents
- Cache from `fetch-prs` skill is reused if within TTL — do NOT use `nocache` unless user requests it
