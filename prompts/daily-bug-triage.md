# SF daily bug triage (agent-swarm)

Triage all Server Foundation Jira bugs in **New** status: codebase root-cause
analysis, Jira comments, and Slack summary. **Auto-fix (draft PRs) is off by
default** — enable only with `ENABLE_AUTO_FIX` in `instruction_prompt`.

Designed for **non-interactive** scheduled runs (weekday cron). Detailed reference:
`workflows/daily-bug-triage.md`.

## SFA conventions

**Working directory:** `/workspace/server-foundation-agent`

| Path | Repository |
|------|------------|
| `/workspace/server-foundation-agent` | `stolostron/server-foundation-agent` (this repo) |

**Jira:** MCP tools only (`search_issues` / `searchJiraIssuesUsingJql`, `get_issue` /
`getJiraIssue`, `add_comment` / `addCommentToJiraIssue`, `update_issue` /
`editJiraIssue`). Host `https://redhat.atlassian.net`, project ACM. No Jira CLI or
curl except script fallbacks.

**New-bugs JQL:**

```
project = ACM AND component = "Server Foundation" AND issuetype = Bug AND status = New ORDER BY priority ASC
```

**Dedup** — skip re-analysis when **either**:

- Issue has label `agent-triaged`, or
- A comment contains both `Bug Triage Analysis` and `server-foundation-agent`

**Triage label:** `agent-triaged` — add via MCP `update_issue` after each successful
analysis comment (Phase 3.5). Do not remove other labels.

**GitHub:** `gh` for draft PRs (Phase 2.5 only when `ENABLE_AUTO_FIX`). **Slack:** `SLACK_WEBHOOK_URL` + helper script (Phase 4).

**Output dir:** `.output/bug-triage/` (under working directory)

Sub-agent instructions: `daily-bug-triage-analyze.md` (same prompt source).

Extended conventions: `prompts/_sfa-conventions.md`

## Memory limits (agent-swarm)

Agent pods are memory-constrained. OOM commonly happens when:

- Running `./repos/sync-repos.sh` (needs **Go** `mikefarah/yq`, not Python `yq`; clones 20+ repos)
- Spawning **multiple analysis sub-agents in parallel**
- Cloning many repos at once

**Defaults:** sequential analysis, on-demand clone of **one repo per bug**, max **3** bugs analyzed per run.

## Workflow

```
Collect → Dedup → Analyze (sub-agents) → [Auto-fix if ENABLE_AUTO_FIX] → Report → Jira comments → Slack
```

## Phase 1: Collect new bugs

1. `mkdir -p .output/bug-triage`

2. MCP search with new-bugs JQL, `max_results`: `50`

3. Build `.output/bug-triage/new_bugs.json` — array of objects:

   | Field | Source |
   |-------|--------|
   | `key`, `summary`, `priority`, `created`, `updated` | Issue fields |
   | `description` | Plain text from description (truncate to 2000 chars) |
   | `assignee`, `assignee_email` | Assignee display name / email, or `Unassigned` |
   | `components` | Component names |
   | `sprint` | Last sprint name if present |
   | `url` | `https://redhat.atlassian.net/browse/<KEY>` |

4. **Early exit:** if zero bugs, send a minimal Slack message ("no new SF bugs") if
   `SLACK_WEBHOOK_URL` is set, then stop successfully.

## Phase 1.5: Dedup — skip previously analyzed

Skip this phase if `instruction_prompt` contains `SKIP_DEDUP` or dedup is impossible.

For each bug in `new_bugs.json`:

1. MCP `get_issue` (include `labels` and comments if supported)
2. If issue has label **`agent-triaged`**, or any comment contains **both** dedup
   markers → add to `bugs_previously_analyzed.json`
3. Else → add to `bugs_to_analyze.json`

Write both JSON files under `.output/bug-triage/`. Phases 2–2.5 use
`bugs_to_analyze.json` only.

Fallback when MCP cannot read comments:

```bash
python3 workflows/daily-bug-triage/check_prior_analysis.py \
  .output/bug-triage/new_bugs.json \
  .output/bug-triage/bugs_to_analyze.json \
  .output/bug-triage/bugs_previously_analyzed.json
```

(requires `JIRA_EMAIL` and `JIRA_API_TOKEN`)

## Phase 2: Analyze each bug (sequential, memory-safe)

**Do not** run `./repos/sync-repos.sh` in agent-swarm pods.

For each bug in `bugs_to_analyze.json`, process **one at a time** (no parallel
sub-agents unless `instruction_prompt` contains `PARALLEL_ANALYZE` — then max **2**
concurrent).

**Per-run cap:** analyze at most **3** bugs. If more remain, list deferred keys in
the final summary (they stay in `bugs_to_analyze.json` for the next run).

For each bug (in order):

1. **Pick likely repo(s)** from summary/description (see keyword table in
   `daily-bug-triage-analyze.md`). Clone **only** the primary repo:
   ```bash
   bash workflows/daily-bug-triage/clone_repo.sh stolostron/managedcluster-import-controller
   ```
   Use `open-cluster-management-io/...` org when the bug maps to upstream OCM repos.
   Skip clone if that repo directory already has `.git`.

2. **Spawn one sub-agent** with:
   - Read `prompts/daily-bug-triage-analyze.md`
   - Pass the bug JSON and the cloned repo path(s)
   - Expect output at `.output/bug-triage/analyses/bug-<KEY>.json`

3. **Wait for completion** before starting the next bug.

If a sub-agent fails or times out, write a minimal `bug-<KEY>.json` with
`analysis_status: error` and continue — do not block later phases.

Do not analyze bugs in `bugs_previously_analyzed.json`.

## Phase 2.5: Auto-fix (opt-in, skipped by default)

**Default: skip this phase entirely.** Auto-fix is disabled unless explicitly enabled.

Run Phase 2.5 only when **both** are true:

1. `instruction_prompt` contains `ENABLE_AUTO_FIX` (or env `AUTO_FIX=1`)
2. At least one analysis has `auto_fix_eligible: true`

Otherwise skip — leave all `draft_pr_url` fields empty and proceed to Phase 3.

For each eligible analysis (max **2** concurrent fix sub-agents):

1. Clone worktree:
   ```bash
   bash .claude/skills/sfa-workspace-clone/clone-worktree.sh \
     --new <relevant_repo> fix/<KEY> --base main
   ```
2. Implement minimal fix per `suggested_fix`; add tests when practical
3. `git commit -s -m 'fix: <summary>'` → push → `gh pr create --draft`
4. PR body: bug link, root cause, fix summary, footer
   `Auto-generated by server-foundation-agent daily bug triage. Human review required.`
5. Update `bug-<KEY>.json` — set `draft_pr_url`; on failure, leave empty and add to `notes`

## Phase 3: Generate Slack payload

```bash
python3 workflows/daily-bug-triage/generate_slack_payload.py \
  .output/bug-triage/analyses/ \
  .output/bug-triage/slack_payload.json \
  --previously-analyzed .output/bug-triage/bugs_previously_analyzed.json
```

## Phase 3.5: Post analysis to Jira (MCP)

For each `bug-*.json` in `.output/bug-triage/analyses/` where `analysis_status` is not
`error`, MCP `add_comment` with wiki-style body:

```
h3. Bug Triage Analysis

*Analysis Status:* <status>
*Confidence:* <confidence>
*Relevant Repo:* <relevant_repo>

*Relevant Files:*
- <file paths>

h4. Root Cause
<root_cause>

h4. Suggested Fix
<suggested_fix>

h4. Draft PR
[View Draft PR|<draft_pr_url>]   (if non-empty)

h4. Notes
<notes>

----
_— server-foundation-agent (daily bug triage)_
```

Use the exact footer above so Phase 1.5 dedup continues to work.

After each successful comment, MCP **`update_issue`** — add label **`agent-triaged`**
(skip if already present). Do not change status or other fields.

Fallback if MCP comment formatting fails:

```bash
python3 workflows/daily-bug-triage/post_jira_comments.py .output/bug-triage/analyses/
```

(requires `JIRA_EMAIL` and `JIRA_API_TOKEN`)

## Phase 4: Slack

```bash
bash .claude/skills/sfa-slack-notify/send_to_slack.sh .output/bug-triage/slack_payload.json
```

Skip if `SLACK_WEBHOOK_URL` is unset — log warning in final summary.

## Final summary

Report:

- Bugs found / analyzed / skipped (previously analyzed)
- Counts by `analysis_status` and draft PRs created
- Slack, Jira comment, and **`agent-triaged` label** status
- Any failures or skipped phases

## instruction_prompt overrides

| Text | Effect |
|------|--------|
| `SKIP_DEDUP` | Analyze all New bugs (ignore prior comments) |
| `ENABLE_AUTO_FIX` | Run Phase 2.5 draft PRs for eligible bugs (off by default) |
| `SKIP_SLACK` | Skip Phase 4 |
| `PARALLEL_ANALYZE` | Allow up to 2 concurrent analysis sub-agents (default: sequential) |

## Do not

- Ask the user for confirmation (automated mode)
- Use Jira CLI or curl for search/comment (except script fallbacks)
- Modify issues beyond triage comments and the `agent-triaged` label (no status transitions)
- Run Phase 2.5 auto-fix unless `ENABLE_AUTO_FIX` is set (default is skip)
- Mark draft PRs ready for review or merge them
- Run `./repos/sync-repos.sh` or clone more than **2 repos per bug**
- Spawn more than **2** analysis sub-agents in parallel
