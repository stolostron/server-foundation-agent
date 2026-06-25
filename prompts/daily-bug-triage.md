# SF daily bug triage (agent-swarm)

Triage all Server Foundation Jira bugs in **New** status: codebase root-cause
analysis, Jira comments, and Slack summary. Also detect **merged** fix PRs for
**In Progress** bugs and transition the corresponding Jira to **Review** (same
pattern as `fix-cve.md` §6.5, but Review instead of Closed). **Auto-fix (draft
PRs) is off by default** — enable only with `ENABLE_AUTO_FIX` in
`instruction_prompt`. Issues labeled `issue-for-agent` are handled by
`jira-pipeline.md`, not this workflow.

Designed for **non-interactive** scheduled runs (weekday cron). Detailed reference:
`workflows/daily-bug-triage.md`.

## SFA conventions

**Working directory:** `/workspace/server-foundation-agent`

| Path | Repository |
|------|------------|
| `/workspace/server-foundation-agent` | `stolostron/server-foundation-agent` (this repo) |

**Jira:** MCP tools only (`search_issues` / `searchJiraIssuesUsingJql`, `get_issue` /
`getJiraIssue`, `add_comment` / `addCommentToJiraIssue`, `update_issue` /
`editJiraIssue`, `transition_issue` / `transitionJiraIssue`). Host
`https://redhat.atlassian.net`, project ACM. No Jira CLI or curl except script
fallbacks.

**New-bugs JQL:**

```
project = ACM AND component = "Server Foundation" AND issuetype = Bug AND status = New ORDER BY priority ASC
```

**Dedup** — skip re-analysis when **either**:

- Issue has label `agent-triaged`, or
- A comment contains both `Bug Triage Analysis` and `server-foundation-agent`

**Triage label:** `agent-triaged` — add via MCP `update_issue` after each successful
analysis comment (Phase 3.5). Do not remove other labels.

**GitHub:** `gh` for PR state checks (Phase 0) and draft PRs (Phase 2.5 only when
`ENABLE_AUTO_FIX`). **Slack:** `SLACK_WEBHOOK_URL` + helper script (Phase 4).

**Output dir:** `.output/bug-triage/` (under working directory)

Sub-agent instructions: `daily-bug-triage-analyze.md` (same prompt source).

Extended conventions: `prompts/_sfa-conventions.md`

## Workflow

```
PR merge → Review → Collect → Dedup → Analyze (sub-agents) → [Auto-fix if ENABLE_AUTO_FIX] → Report → Jira comments → Slack
```

## Phase 0: Transition to Review when fix PR is merged

Run at the **start** of every run (even when there are zero New bugs). Non-interactive
— do not ask the user. Skip this phase when `instruction_prompt` contains
`SKIP_PR_MERGE_REVIEW`.

**JQL (MCP `search_issues`):**

```jql
project = ACM AND component = "Server Foundation" AND issuetype = Bug AND status = "In Progress"
```

1. `mkdir -p .output/bug-triage`
2. MCP search with JQL above (`max_results`: `50`)
3. Initialize `.output/bug-triage/pr_merge_review.json` as `[]` — append one row per
   action this run

For each **In Progress** issue:

1. **Skip unless still In Progress** — MCP `get_issue`; if status is **Review**,
   **Testing**, **Resolved**, **Closed**, or **Done**, do not transition.

2. **Skip if already transitioned this run previously** — agent-signed comment contains
   `Bug Fix: PR merged` and `_— server-foundation-agent_` **and** status is already
   **Review** or later.

   > **Note:** A `Bug Fix: PR merged` comment alone is **not** a skip when status is
   > still **In Progress** — the comment may have been posted without a successful Jira
   > transition (or the issue was reopened). If status is still **In Progress** and
   > `gh` confirms `MERGED`, proceed to transition and record `reviewed_this_run: true`.

3. **Discover linked fix PR(s)** (try in order; verify every URL with `gh`):
   - MCP `get_issue` — development / `git_pull_requests` URLs
   - MCP issue comments — `https://github.com/.../pull/N` from agent-signed comments
     (`server-foundation-agent` footer)
   - If no URL, search merged PRs by issue key:
     ```bash
     gh pr list --repo <org/repo> --state merged \
       --search "<KEY> in:title" \
       --json number,url,state,mergedAt,title
     ```
     Try SF repos from triage `Relevant Repo` comment, `git_pull_requests`, or
     `docs/repos.md` until a merged PR is found or all candidates are exhausted.

4. **Verify merge** — `gh pr view <url> --json state,mergedAt,url,title` — proceed
   **only** when `state` is `MERGED`.

5. **Record then transition (order mandatory):**
   - **First** append to `pr_merge_review.json`:
     ```json
     {
       "issue_key": "ACM-12345",
       "action": "review_merged_pr",
       "reviewed_this_run": true,
       "pr_url": "https://github.com/stolostron/ocm/pull/123",
       "pr_state": "MERGED",
       "merged_at": "2026-06-22T20:19:32Z",
       "notes": "ocm#123 merged — fix for hosting-cluster-name annotation"
     }
     ```
   - MCP `add_comment` (wiki markup):
     - `Bug Fix: PR merged`
     - Merged PR URL and `mergedAt`
     - One-line fix summary (repo, what changed)
     - Footer `_— server-foundation-agent_`
   - MCP `transition_issue` to **Review** (transition name may be `Request Review` or
     `Review` per `docs/jira/workflows.md`). If transition fails, record
     `action: failed` with error; do **not** retry blindly.
   - On success, ensure the row has `reviewed_this_run: true`.

`action` values: `review_merged_pr`, `skipped_no_pr`, `skipped_not_merged`,
`skipped_already_review`, `failed`.

**Guardrails:**

- Transition **only** when `gh` confirms `MERGED` for a PR linked to this issue
- Do **not** transition on open/draft PRs or unmerged closed PRs
- Do **not** transition issues already in **Review** or later
- Do **not** use Jira `git_pull_requests` without verifying with `gh`

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

## Phase 2: Analyze each bug (sub-agents)

If `repos/` clones look empty, run once:

```bash
./repos/sync-repos.sh
```

For each bug in `bugs_to_analyze.json`, spawn a sub-agent (up to **5** concurrent):

- Read `daily-bug-triage-analyze.md` for instructions
- Pass the bug JSON in the prompt
- Expect output at `.output/bug-triage/analyses/bug-<KEY>.json`

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

- **PR merge → Review:** issues checked, transitioned to Review this run (from
  `pr_merge_review.json` where `reviewed_this_run: true`), skipped, failed
- Bugs found / analyzed / skipped (previously analyzed)
- Counts by `analysis_status` and draft PRs created
- Slack, Jira comment, and **`agent-triaged` label** status
- Any failures or skipped phases

## instruction_prompt overrides

| Text | Effect |
|------|--------|
| `SKIP_PR_MERGE_REVIEW` | Skip Phase 0 (no merged-PR → Review transitions) |
| `SKIP_DEDUP` | Analyze all New bugs (ignore prior comments) |
| `ENABLE_AUTO_FIX` | Run Phase 2.5 draft PRs for eligible bugs (off by default) |
| `SKIP_SLACK` | Skip Phase 4 |

## Do not

- Ask the user for confirmation (automated mode)
- Use Jira CLI or curl for search/comment (except script fallbacks)
- Transition Jira status except Phase 0 (**Review** when `gh` confirms PR **MERGED**)
- Change status or labels in Phases 3.5+ beyond triage comments and `agent-triaged`
- Run Phase 2.5 auto-fix unless `ENABLE_AUTO_FIX` is set (default is skip)
- Mark draft PRs ready for review or merge them
