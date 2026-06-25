# SF fix CVE (agent-swarm)

Monitor Server Foundation ProsSec vulnerability issues, create or update per-CVE
tracking tasks, run deep multi-branch impact analysis, post findings to Jira, open
**draft PRs** for fixable CVEs, and **close** vulnerability issues classified as
Not Applicable.

**Developer guide:** [Automated CVE fix — developer guide](../docs/automated-cve-fix-developer-guide.md)
— human gates, Jira issue types, PR grooming, auto-close rules, and troubleshooting.

Designed for **non-interactive** scheduled or on-demand runs (cron or
`instruction_prompt: CVE-YYYY-NNNNN`). Skill reference:
`.claude/skills/sfa-cve-analysis/SKILL.md`. PR patterns: `prompts/jira-solve.md`.

## SFA conventions

**Working directory:** `/workspace/server-foundation-agent`

| Path | Repository |
|------|------------|
| `/workspace/server-foundation-agent` | `stolostron/server-foundation-agent` (this repo) |

**Jira:** MCP tools only (`search_issues`, `get_issue`, `create_issue`, `add_comment`,
`update_issue`, `transition_issue`). Host `https://redhat.atlassian.net`, project ACM.
Do **not** use Jira CLI. Do **not** use curl for vulnerability issue comments — MCP is
required (REST often returns 404 on ProsSec issues).

**Code access:**

| Location | Use |
|----------|-----|
| `repos/` | Read-only reference (`./repos/sync-repos.sh`) |
| `workspace/` | Writable worktrees for CVE fixes (`sfa-workspace-clone` skill) |

**GitHub:** `gh` for draft PRs. Commits: Conventional Commits + `Signed-off-by` +
`Co-authored-by: server-foundation-agent <sfa-bot@redhat.com>`. Label `sfa-assisted`
after PR create when the label exists (see `prompts/_sfa-conventions.md`).

**Slack:** `SLACK_WEBHOOK_URL` + `workflows/fix-cve/generate_slack_payload.py` +
`.claude/skills/sfa-slack-notify/send_to_slack.sh` (Phase 7 — required when webhook set).

**Output dir:** `.output/cve-analysis/` (under working directory)

Extended conventions: `prompts/_sfa-conventions.md`

## Scope

**Default:** all active ProsSec vulnerability issues for Server Foundation.

**Active vulnerability JQL:**

```
project = ACM AND issuetype = Vulnerability AND component = "Server Foundation" AND labels = Security AND status NOT IN (Closed, Done)
```

**Optional `instruction_prompt` CVE filter:** if the text contains `CVE-YYYY-NNNNN`,
analyze that CVE only (include Closed/Done vulnerability issues for that CVE).

**Exclude:** bulk container-scan tickets without a single CVE in the summary (e.g.
`[Server Foundation] … - N HIGH CVEs`) unless `INCLUDE_BULK_SCANS` is set.

## Tracking task conventions

| Field | Value |
|-------|-------|
| Type | Task |
| Project | ACM |
| Component | Server Foundation |
| Summary | `CVE-{cve_id} ({issue_count} issues, {repo_count} repos)` |
| Work type | `10609` (Security & Compliance) — pass numeric ID to MCP `create_issue` |
| Assignee | Prefer Qing Hao; if assign fails, use `rjung@redhat.com` or leave unassigned |
| Description | From `format-cve-tracking-task.py` (never hand-format tables) |

**Existing tracking task JQL** (per CVE):

```
project = ACM AND issuetype = Task AND component = "Server Foundation" AND summary ~ "CVE-{cve_id}"
```

## Dedup between runs

Skip re-analysis for a CVE when **all** are true:

1. An open tracking task exists (`summary ~ "CVE-{cve_id}"`, not Closed/Done), **and**
2. Every active vulnerability issue for that CVE has a comment containing **both**
   `Deep CVE Impact Analysis` and `_— server-foundation-agent_`

If new vulnerability issues appeared since last run, re-run analysis for that CVE and
post comments only on issues missing the signature (do not duplicate on already-commented
issues).

Override: `FORCE_REANALYSIS` in `instruction_prompt` ignores dedup.

## Branch mapping (Jira → git)

Derive target branch from vulnerability issue summary bracket or `target_version`:

| Jira bracket / version | Git branch |
|------------------------|------------|
| `[mce-2.8]` / MCE 2.8.x | `backplane-2.8` |
| `[mce-2.9]` | `backplane-2.9` |
| `[mce-2.10]` | `backplane-2.10` |
| `[mce-2.11]` | `backplane-2.11` |
| `[mce-2.17]` | `backplane-2.17` |
| `[acm-2.13]` / ACM 2.13.x | `release-2.13` |
| `[acm-2.14]` | `release-2.14` |
| (no bracket, mainline) | `main` |

Repos using `release-*` instead of `backplane-*`: `klusterlet-addon-controller`,
`cluster-permission`.

## Workflow

```
Collect → Group by CVE → Tracking tasks → Deep analysis → Jira comments → Remediation → Slack → Summary
```

## Phase 1: Collect vulnerability issues

1. `mkdir -p .output/cve-analysis`

2. MCP `search_issues` with active vulnerability JQL (`max_results`: `100`). If
   `instruction_prompt` names a CVE, use:

   ```
   project = ACM AND issuetype = Vulnerability AND component = "Server Foundation" AND labels = Security AND summary ~ "CVE-YYYY-NNNNN"
   ```

3. Write `.output/cve-analysis/vulnerabilities.json` — array of `{key, summary, labels,
   status, priority, created, target_version, url}`.

4. **Early exit:** if zero issues, write `.output/cve-analysis/remediation.json` as
   `[]`, then run Phase 7 Slack ("no active SF CVE issues") when `SLACK_WEBHOOK_URL` is
   set, then stop successfully.

## Phase 2: Group by CVE

1. Extract CVE IDs from each issue summary (`CVE-\d{4}-\d+`) or `CVE-*` labels.

2. Build `.output/cve-analysis/cve_groups.json`:

   ```json
   {
     "CVE-2026-39821": ["ACM-35352", "ACM-35353"],
     "CVE-2026-46595": ["ACM-35339"]
   }
   ```

3. Apply dedup (skip CVEs fully analyzed unless `FORCE_REANALYSIS`). Write
   `.output/cve-analysis/cve_to_process.json` — CVE IDs needing work this run.

## Phase 3: Tracking tasks

For each CVE in `cve_to_process.json`:

### 3.1 Check existing tracker

MCP search:

```
project = ACM AND issuetype = Task AND component = "Server Foundation" AND summary ~ "CVE-{cve_id}" AND status NOT IN (Closed, Done)
```

If found → record `tracking_key` in `.output/cve-analysis/tracking/{cve_id}.json`.
Skip creation.

### 3.2 Generate description (required script)

Fetch vulnerability issues for the CVE via MCP, save REST-shaped JSON for the script:

```bash
# Build issues payload from MCP results into .output/cve-analysis/issues-{cve_id}.json
# Must be {"issues": [{"key", "fields": {summary, labels, versions, status, priority, created}}]}

python3 .claude/skills/sfa-cve-analysis/format-cve-tracking-task.py \
  .output/cve-analysis/issues-{cve_id}.json \
  {cve_id} \
  > .output/cve-analysis/description-{cve_id}.txt
```

Parse counts from description header (`Total Related Issues`, repo count from
`**Repository:` lines).

### 3.3 Create tracking task (if missing)

MCP `create_issue`:

- `project_key`: ACM
- `issue_type`: Task
- `components`: ["Server Foundation"]
- `summary`: `CVE-{cve_id} ({issue_count} issues, {repo_count} repos)`
- `description`: contents of `description-{cve_id}.txt`
- `work_type`: `10609`
- `assignee`: try Qing Hao account; on failure use `rjung@redhat.com`

Record new `tracking_key`.

## Phase 4: Deep impact analysis

Run for **every** CVE in `cve_to_process.json` (non-interactive — do not ask the user).

### 4.1 CVE metadata

WebSearch / pkg.go.dev vuln DB for each CVE:

- Affected package and version range
- Fixed version
- Brief description

Save to `.output/cve-analysis/cve-meta-{cve_id}.json`.

### 4.2 Clone and analyze branches

Use temp dir `/tmp/cve-analysis/repos` (or `.output/cve-analysis/repos`).

**Repositories** — derive from vulnerability issues for this CVE (via script output
or pscomponent labels). Common SF repos:

| Repository | Branches |
|------------|----------|
| stolostron/ocm | main, backplane-2.17, backplane-2.11, backplane-2.10, backplane-2.9, backplane-2.8 |
| stolostron/clusterlifecycle-state-metrics | main, backplane-2.17, backplane-2.11, backplane-2.10, backplane-2.9, backplane-2.8 |
| stolostron/multicloud-operators-foundation | main, backplane-2.17, backplane-2.11, backplane-2.10, backplane-2.9, backplane-2.8 |
| stolostron/managed-serviceaccount | main, backplane-2.17, backplane-2.11, backplane-2.10, backplane-2.9, backplane-2.8 |
| stolostron/cluster-proxy-addon | main, backplane-2.17, backplane-2.11, backplane-2.10, backplane-2.9, backplane-2.8 |
| stolostron/cluster-proxy | main, backplane-2.17, backplane-2.11, backplane-2.10, backplane-2.9, backplane-2.8 |
| stolostron/managedcluster-import-controller | main, backplane-2.17, backplane-2.11, backplane-2.10, backplane-2.9, backplane-2.8 |
| stolostron/klusterlet-addon-controller | main, release-2.17, release-2.16, release-2.15, release-2.14, release-2.13 |
| stolostron/cluster-permission | main, release-2.17, release-2.16, release-2.15, release-2.14, release-2.13 |

Per repo/branch:

1. `git fetch origin {branch} --depth 1` and checkout
2. Read `go.mod` for `golang.org/x/net`, `golang.org/x/crypto`, Go version
3. `go mod why` for affected package (e.g. `golang.org/x/net/idna`, `golang.org/x/crypto/ssh`)
4. Grep for direct usage (`idna`, `ssh.NewServerConn`, `ssh.ServerConfig`)
5. Classify impact:
   - ❌ Vulnerable / ⚠️ Potentially Vulnerable / ✅ Not Vulnerable / ➖ Not Applicable

**Older-branch upgrades:** follow `solutions/older-branch-dep-upgrade.md` for fix
recommendations (minimal `go get`, avoid OCM dep tier jumps).

Write report: `.output/cve-analysis/deep-analysis-{cve_id}.md`

## Phase 5: Post Jira comments

Use **Jira wiki markup** (see `docs/jira/formatting.md`). Footer on every comment:

```
----
_— server-foundation-agent_
```

Convert markdown reports with `h2.` / `h3.` headings, `*bold*`, `{{monospace}}`,
`||table||` rows.

### 5.1 Tracking task

MCP `add_comment` on `tracking_key` with **full** deep analysis report from
`deep-analysis-{cve_id}.md`.

### 5.2 Individual vulnerability issues

For each issue key in the CVE group, MCP `add_comment` with a **component-specific**
summary:

- Issue key, repository, branch (from JIRA target version / summary bracket)
- Installed dependency version vs fix version
- Impact assessment (one line)
- Remediation command (`go get …`)
- Link to tracking task: `[ACM-XXXXX|https://redhat.atlassian.net/browse/ACM-XXXXX]`

Skip issues that already have the dedup signature (unless `FORCE_REANALYSIS`).

## Phase 6: Remediation actions

Run after Phase 5 unless `SKIP_REMEDIATION` is set. Non-interactive — do not ask the
user.

**Start each run with an empty** `.output/cve-analysis/remediation.json` (`[]`). Append
rows as actions occur this run — do not carry forward rows from prior runs.

Write `.output/cve-analysis/remediation.json` — array of action records:

```json
{
  "cve_id": "CVE-2026-46595",
  "issue_key": "ACM-35339",
  "repo": "stolostron/ocm",
  "branch": "backplane-2.8",
  "impact": "Not Applicable",
  "action": "closed",
  "pr_url": null,
  "pr_state": null,
  "is_draft": null,
  "merged_at": null,
  "notes": "go mod why shows ssh package not needed",
  "closed_this_run": true
}
```

Set `"closed_this_run": true` **only** on `closed` and `closed_merged_pr` rows when
this run successfully transitions the issue to Closed. Omit or set `false` for all other
actions. Slack *Closed this run* sections include **only** rows with `closed_this_run:
true`.

`action` values: `pr_opened`, `pr_merged`, `pr_closed`, `closed`, `closed_merged_pr`,
`skipped_already_fixed`, `skipped_existing_pr`, `failed`.

When a row has `pr_url`, also record live GitHub fields from `gh pr view` (see PR
state helpers below): `pr_state` (`OPEN` / `MERGED` / `CLOSED`), `is_draft`, `merged_at`.
Phase 7 re-fetches these fields before Slack; stale merged PRs must not appear as drafts.

### 6.1 Build remediation plan

From `deep-analysis-{cve_id}.md`, map each **active** vulnerability issue to:

- Repository (pscomponent label or summary image path → repo name)
- Target branch (branch mapping table above)
- Per-issue impact from deep analysis for that repo/branch

**Group fixes:** one draft PR per `(repo, branch, CVE)` — not one PR per container-image
ticket. Link all related vulnerability issue keys in the PR body and Jira comments.

### 6.2 Not Applicable → close Jira

When deep analysis classifies the issue's repo/branch as **➖ Not Applicable**:

1. MCP `add_comment` on the vulnerability issue (skip if comment already contains
   `CVE Remediation: Not Applicable` and `_— server-foundation-agent_` unless
   `FORCE_REANALYSIS`):
   - Evidence: `go mod why` output, grep results, why the vulnerable API is unused
   - Statement: issue closed as not applicable to this component/branch
2. MCP `transition_issue`:
   - If status is New/To Do → try `In Progress` first when available
   - Then transition to **Closed** (or **Resolve** then **Close** if the workflow
     requires two steps)
   - If transition fails, record `action: failed` with error; do **not** retry blindly
3. **First** record each closed issue in `remediation.json` with `action: closed`,
   `closed_this_run: true`, and a `notes` rationale; mirror in `run_meta.json` →
   `jira_closed_this_run`. **Then** transition.
4. MCP `add_comment` on the tracking task summarizing closed keys for this CVE

**Guardrail:** close **only** when classification is Not Applicable with documented
evidence in the comment. Never close ❌ Vulnerable or ⚠️ Potentially Vulnerable issues.

### 6.3 Already fixed → skip PR

When classification is **✅ Not Vulnerable** (installed version ≥ fix version):

- Ensure Phase 5 comment documents the evidence
- Record `action: skipped_already_fixed` in `remediation.json`
- Do **not** close automatically (human/QE may still want scan ticket cleanup)

### 6.4 Vulnerable / Potentially Vulnerable → draft PR

When classification is **❌ Vulnerable** or **⚠️ Potentially Vulnerable**:

**PR state helpers (required whenever recording `pr_url`):**

```bash
# Dedup — open PRs only (never trust Jira git_pull_requests without verifying)
gh pr list --repo <org/repo> --state open --search "<CVE-ID> in:title" \
  --json number,url,state,isDraft,mergedAt,title

# Verify a specific PR before recording skipped_existing_pr / pr_opened
gh pr view <number> --repo <org/repo> --json state,isDraft,mergedAt,url,title
```

- If `state` is `MERGED` → record `action: pr_merged` (not `skipped_existing_pr`);
  include `merged_at`; do **not** list as needing draft/approval follow-up
- If `state` is `CLOSED` (unmerged) → record `action: pr_closed`; open a new PR if still
  vulnerable
- If `state` is `OPEN` and `isDraft` is `true` → `skipped_existing_pr` or `pr_opened`
- If `state` is `OPEN` and `isDraft` is `false` → same actions; Slack reports as
  *ready for review*, not draft

1. **Dedup PR:** use `gh pr list --state open` on the repo with title containing
   `{cve_id}`; verify with `gh pr view --json state,isDraft,mergedAt`. Do **not** treat
   Jira `git_pull_requests` as authoritative — always verify with `gh`. If an open PR is
   found → record `skipped_existing_pr` with PR state fields, link PR in tracking-task
   comment, ensure each linked issue is **In Progress** (see step 2), then skip new PR
2. **Start work in Jira** — for each linked vulnerability issue (MCP `transition_issue`):
   - If status is already **In Progress** → skip
   - If status is New/To Do/Backlog → transition to **In Progress** (transition name
     may be `Start Progress`)
   - If status is **Review** or later → do **not** change status (human owns workflow
     beyond In Progress); still post PR comment in step 8
   - If transition fails: MCP `add_comment` with the error, record `action: failed`,
     skip PR for this `(repo, branch, CVE)` group
3. **Clone worktree:**
   ```bash
   bash .claude/skills/sfa-workspace-clone/clone-worktree.sh \
     --new <org/repo> cve-<CVE-ID>-<branch-suffix> --base <branch>
   ```
   Example: `--base backplane-2.8` → branch `cve-CVE-2026-39821-backplane-2-8`
4. **Apply minimal fix** per `solutions/older-branch-dep-upgrade.md`:
   - Prefer `go get <module>@<fix-version>` (and `go mod tidy`)
   - Run `go mod vendor` when the repo vendors dependencies
   - Avoid OCM dependency tier jumps; use `replace` only when the SOP requires it
5. **Verify** in the worktree (sequential, allow ≥ 5 min):
   ```bash
   make check
   make test
   ```
   Fix failures from your changes; record failure if tests cannot pass after reasonable
   effort
6. **Commit and push:**
   ```bash
   git commit -s -m "$(cat <<'EOF'
   fix(security): bump <module> for <CVE-ID>

   Co-authored-by: server-foundation-agent <sfa-bot@redhat.com>
   EOF
   )"
   git push origin HEAD
   ```
7. **Draft PR:**
   ```bash
   gh pr create --draft --repo <org/repo> \
     --title "<CVE-ID>: bump <module> on <branch>" \
     --body "$(cat <<'EOF'
   ## CVE
   <CVE-ID> — <one-line description>

   ## Jira
   - https://redhat.atlassian.net/browse/ACM-XXXXX
   (list all linked vulnerability keys)

   ## Summary
   <go get command and version change>

   ## Test plan
   - [x] make check
   - [x] make test

   ---
   *Created with [server-foundation-agent](https://github.com/stolostron/server-foundation-agent)*
   EOF
   )"
   gh pr edit <PR-NUMBER> --repo <org/repo> --add-label "sfa-assisted"
   gh pr view <PR-NUMBER> --repo <org/repo> --json state,isDraft,mergedAt,url,title
   ```
   If the label does not exist on the target repo, note in the run summary; the draft PR
   is still valid.
8. **Jira updates** for each linked vulnerability issue:
   - MCP `add_comment` with PR URL, fix summary, and signature footer
   - MCP `update_issue` — set `git_pull_requests` to the PR URL when the field is
     supported (best effort); re-verify with `gh pr view` on later runs — merged PRs in
     Jira must not block new fixes
   - Leave status at **In Progress** after opening a draft PR — do **not** transition to
     Review (humans move to Review after marking the PR ready for review)
9. MCP `add_comment` on tracking task — PR table for this CVE (include PR state:
   draft / ready / merged)
10. Record `action: pr_opened` with `pr_url`, `pr_state`, `is_draft`, and `merged_at` in
    `remediation.json`

**Limit:** at most **one new PR per repo/branch/CVE** per run. Defer extra branches to
the run summary as human follow-ups.

### 6.5 Close vulnerability issues when fix PR is merged

Run after §6.4. Query **In Progress** vulnerability issues only (tickets with an active
fix in flight). Non-interactive — do not ask the user.

**JQL (MCP `search_issues`):**

```jql
project = ACM AND issuetype = Vulnerability AND component = "Server Foundation" AND labels = Security AND status = "In Progress"
```

If `instruction_prompt` names a CVE, append `AND summary ~ "CVE-YYYY-NNNNN"`.

For each **In Progress** issue:

1. **Skip unless still In Progress** — if MCP `get_issue` status is **Closed** or **Done**,
   do not close or record a closure row.

2. **Skip if already closed this run previously** — agent-signed comment contains
   `CVE Remediation: PR merged` and `_— server-foundation-agent_` unless
   `FORCE_REANALYSIS`.

   > **Note:** A `Fix Merged:` comment alone is **not** a skip — that comment may have
   > been posted when the PR merged without a successful Jira transition (or the issue
   > was reopened). If status is still **In Progress** and `gh` confirms `MERGED`,
   > proceed to close and record `closed_this_run: true`.

3. **Discover linked fix PR(s)** (try in order; verify every URL with `gh`):
   - MCP `get_issue` — development / `git_pull_requests` URLs
   - MCP issue comments — `https://github.com/.../pull/N` from agent-signed comments
   - If no URL: map issue → repo + branch (§Branch mapping), extract CVE from summary;
     ```bash
     gh pr list --repo <org/repo> --state merged \
       --search "<CVE-ID> in:title" \
       --json number,url,state,mergedAt,baseRefName
     ```
     Pick the PR whose `baseRefName` matches the issue target branch

4. **Verify merge** — `gh pr view <url> --json state,mergedAt,url` — proceed **only**
   when `state` is `MERGED`

5. **Record then close (order mandatory):**
   - **First** append to `remediation.json` with `closed_this_run: true` (and mirror in
     `run_meta.json` → `jira_closed_this_run` — see §6.6). Slack *Closed this run*
     reports **only** rows with `closed_this_run: true` from this run.
   - MCP `add_comment` (wiki markup):
     - `CVE Remediation: PR merged`
     - Merged PR URL and `mergedAt`
     - One-line fix summary (repo, branch, version bump)
     - Footer `_— server-foundation-agent_`
   - MCP `transition_issue` toward **Closed** (multi-step OK):
     - Shortest path from **In Progress** through Review / Testing / Resolved to **Closed**
     - If a transition fails, record `action: failed` with error; do **not** retry blindly
     - If transition succeeds, ensure the row has `closed_this_run: true`
   - Example `remediation.json` row:
     ```json
     {
       "cve_id": "CVE-2026-39821",
       "issue_key": "ACM-35352",
       "repo": "stolostron/ocm",
       "branch": "backplane-2.8",
       "action": "closed_merged_pr",
       "closed_this_run": true,
       "pr_url": "https://github.com/stolostron/ocm/pull/767",
       "pr_state": "MERGED",
       "merged_at": "2026-06-22T20:19:32Z",
       "notes": "ocm#767 merged: golang.org/x/net v0.53.0 → v0.56.0 on backplane-2.8"
     }
     ```

6. MCP `add_comment` on the CVE tracking task — table of issues closed via merged PR
   **this run only** (issue key → PR link → reason)

When one merged PR covers multiple vulnerability issues (listed in the PR body), **close
and record `closed_merged_pr` with `closed_this_run: true` for every linked issue still
In Progress** — not only the first. Parse `ACM-xxxxx` keys from the merged PR
description. **Do not** record or close issues already **Closed**/**Done**, or already
bearing a `CVE Remediation: PR merged` agent comment.

**Guardrails:**

- Close **only** when `gh` confirms `MERGED` for a PR that fixes this issue's
  repo/branch/CVE
- Do **not** close on open/draft PRs, unmerged closed PRs, or branch version alone
- Do **not** close ✅ Not Vulnerable issues automatically (§6.3) — only ❌/⚠️ with merged
  fix PR, or §6.2 Not Applicable

### 6.6 Remediation report

Write `.output/cve-analysis/remediation-report.md` with:

- PRs opened (URL, repo, branch, linked JIRA keys)
- Issues closed as Not Applicable (keys + one-line rationale)
- Issues closed because fix PR merged (keys + PR URL)
- Skipped (already fixed, existing PR)
- Failures (PR create, transition, tests)

Post the remediation summary (or link to full report) as MCP `add_comment` on each
tracking task processed this run.

Write `.output/cve-analysis/run_meta.json` before Phase 7 (counts for Slack):

```json
{
  "issues_found": 15,
  "cves_processed": 2,
  "comments_posted": 17,
  "failures": ["sfa-assisted label not found on target repos"],
  "follow_up": "Optional non-PR notes only (e.g. z-stream backport branches)",
  "jira_closed_this_run": [
    {
      "issue_key": "ACM-35352",
      "action": "closed_merged_pr",
      "closed_this_run": true,
      "pr_url": "https://github.com/stolostron/ocm/pull/767",
      "notes": "ocm#767 merged: golang.org/x/net v0.53.0 → v0.56.0 on backplane-2.8"
    }
  ]
}
```

Append every Jira closure **this run** to `jira_closed_this_run` (same shape as
`remediation.json` closure rows, including `closed_this_run: true`). Used as a backup if
`remediation.json` is incomplete. Do **not** list issues that were already Closed before
this run.

`follow_up` is appended after auto-generated PR follow-up (clickable PR links per open
PR). Use only for **non-PR** notes (e.g. z-stream backport branches). Do **not** list PR
approval steps or bare `repo#number` references — Slack links PRs automatically.

## Phase 7: Slack

**Required** when `SLACK_WEBHOOK_URL` is set unless `SKIP_SLACK`. Do not skip silently.

### 7.1 Verify closure records

Before Slack, confirm every Jira transitioned to Closed **this run** has a matching row in
`remediation.json` (`action`: `closed` or `closed_merged_pr`, `closed_this_run: true`).
If any closure is missing, append the row now. Re-read `remediation.json` after edits.
Do **not** add closure rows for issues that were already Closed before this run.

### 7.2 Refresh PR state

```bash
python3 workflows/fix-cve/enrich_remediation_prs.py \
  .output/cve-analysis/remediation.json
```

Re-queries `gh` for every `pr_url` in `remediation.json`, updates `pr_state` /
`is_draft` / `merged_at`, and reclassifies merged or closed PRs (`pr_merged` /
`pr_closed`). If `gh` is unavailable, Phase 7.2 falls back to stored fields.

### 7.3 Generate payload

```bash
python3 workflows/fix-cve/generate_slack_payload.py \
  .output/cve-analysis/ \
  .output/cve-analysis/slack_payload.json
```

Input: `remediation.json`, optional `run_meta.json`, optional `vulnerabilities.json`.
Buckets open PRs into *Draft*, *Ready for review*, and *Merged* using live GitHub state.
Follow-up lists each open PR as a clickable link with the required human action.
Reports `closed_merged_pr` and `closed` rows with `closed_this_run: true` under *Closed
this run (merged PR)* and *Closed as Not Applicable*. Falls back to
`run_meta.jira_closed_this_run` when `remediation.json` is incomplete. Issues closed on
prior runs are **not** re-reported.

### 7.4 Send

```bash
bash .claude/skills/sfa-slack-notify/send_to_slack.sh \
  .output/cve-analysis/slack_payload.json
```

- If `SLACK_WEBHOOK_URL` is unset → skip Phase 7 and log `Slack: skipped (no webhook)`
  in the final summary
- If send fails → record error in final summary; do not fail the whole run
- Record `Slack: sent` or `Slack: failed (<reason>)` in the session output

## Final summary

Report in session output:

- Vulnerability issues found / CVEs grouped / CVEs skipped (dedup)
- Tracking tasks created vs reused
- Deep analyses completed
- Jira comments posted (tracking + per-issue counts)
- **Remediation:** PRs by state (draft / ready / merged; table: PR URL, repo, branch,
  linked keys)
- **Remediation:** vulnerability issues closed as Not Applicable (table: key, rationale)
- **Remediation:** vulnerability issues closed because fix PR merged (table: key, PR URL)
- Remediation skipped / failed counts from `remediation.json`
- **Slack:** sent / skipped / failed (with reason)
- Failures (assignee, MCP, clone, missing branches, PR push, Jira transition)
- Recommended human follow-ups (remaining branches, mark PRs ready, `/ok-to-test`)

## instruction_prompt overrides

| Text | Effect |
|------|--------|
| `CVE-YYYY-NNNNN` | Analyze only that CVE (all statuses) |
| `FORCE_REANALYSIS` | Ignore dedup; repost all comments |
| `SKIP_DEEP_ANALYSIS` | Tracking tasks only (Phases 1–3) |
| `SKIP_REMEDIATION` | Analysis + Jira comments only (skip Phase 6) |
| `SKIP_SLACK` | Skip Phase 7 |
| `INCLUDE_BULK_SCANS` | Include multi-CVE scanner tickets |

## Do not

- Ask the user for confirmation (automated mode)
- Skip Phase 7 when `SLACK_WEBHOOK_URL` is set (unless `SKIP_SLACK`)
- Hand-format tracking task repository tables (always use the script)
- Use curl REST for comments on vulnerability issues
- Create duplicate tracking tasks for the same CVE
- Mark draft PRs ready for review or merge them
- Close vulnerability issues unless: (a) **Not Applicable** with evidence (§6.2), or
  (b) linked fix PR is **MERGED** per `gh` (§6.5)
- Open more than one PR per `(repo, branch, CVE)` per run
- Cascade major dependency upgrades on older branches (follow the older-branch SOP)
