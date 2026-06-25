# Daily Bug Triage Workflow

Automatically triage all Server Foundation Jira bugs in "New" status by analyzing the codebase to find root causes,
then send a summary Slack notification every weekday morning. **Also transitions In Progress bugs to Review when a linked fix PR is merged** (Phase 0). **Draft PR auto-fix (Phase 2.5) is off by default.**

## Agent-swarm prompt

For [agent-swarm](https://github.com/stolostron/agent-swarm) (OpenCode/Crush), use the
self-contained prompt files instead of this document:

| Role | File |
|------|------|
| Orchestrator | `prompts/daily-bug-triage.md` |
| Per-bug sub-agent | `prompts/daily-bug-triage-analyze.md` |

Index: [prompts/README.md](../prompts/README.md). This workflow doc remains the
detailed reference (scripts, Slack format, edge cases).

## Trigger Phrases

- `daily bug triage`, `bug triage report`, `triage new bugs`
- `analyze new bugs`, `check new bugs`

## Workflow Phases

```
Phase 0: PR merge   →  Phase 1: Collect    →  Phase 1.5: Dedup     →  Phase 2: Analyze        →  Phase 2.5: Auto-Fix (opt-in)  →  Phase 3: Report    →  Phase 3.5: Jira     →  Phase 4: Distribute
merged PR → Review     sfa-jira-search           check Jira comments      sub-agents per bug          draft PR only if ENABLE_AUTO_FIX   generate Slack         post full analysis      sfa-slack-notify
(In Progress bugs)     (status=New, type=Bug)    for prior agent           (codebase deep-dive)        (skipped by default)             payload                as Jira comments
```

---

## Phase 0: Merged PR → Review (In Progress bugs)

Runs at the **start** of every triage run (including days with zero New bugs).
Mirrors `fix-cve.md` §6.5 (merged PR detection) but transitions SF **Bug** issues to
**Review** instead of closing them.

Skip when `SKIP_PR_MERGE_REVIEW` is in `instruction_prompt`.

### 0.1 Query In Progress bugs

```jql
project = ACM AND component = "Server Foundation" AND issuetype = Bug AND status = "In Progress"
```

### 0.2 For each issue

1. Re-fetch status — skip if already Review, Testing, Resolved, Closed, or Done
2. Find linked PR URLs from Jira development field, agent comments, or
   `gh pr list --state merged --search "ACM-XXXXX in:title"` across candidate SF repos
3. `gh pr view --json state,mergedAt` — proceed only when `state` is `MERGED`
4. Post Jira comment (`Bug Fix: PR merged` + `server-foundation-agent` footer)
5. MCP `transition_issue` → **Review**
6. Record in `.output/bug-triage/pr_merge_review.json`

If a prior `Bug Fix: PR merged` comment exists but status is still In Progress, retry
the transition (same retry rule as `fix-cve.md` §6.5).

---

## Phase 1: Collect New Bugs from Jira

Use the `sfa-jira-search` skill to fetch all bugs with status "New" for the SF team.

### 1.1 Query Jira

```bash
mkdir -p .output/bug-triage

curl -s -X POST \
  -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "jql": "project = ACM AND component = \"Server Foundation\" AND issuetype = Bug AND status = New ORDER BY priority ASC",
    "fields": ["issuetype", "key", "summary", "status", "priority", "assignee", "description", "components", "created", "updated", "customfield_10020"],
    "maxResults": 50
  }' \
  "https://redhat.atlassian.net/rest/api/3/search/jql" > .output/bug-triage/new_bugs_raw.json
```

### 1.2 Parse Bug Data

Extract structured bug info from the raw JSON:

```python
import json, sys

data = json.load(open('.output/bug-triage/new_bugs_raw.json'))
issues = data.get('issues', [])

bugs = []
for issue in issues:
    f = issue['fields']

    # Extract description text from ADF (Atlassian Document Format)
    desc = ''
    if f.get('description'):
        # ADF is nested JSON; extract text content recursively
        def extract_text(node):
            if isinstance(node, dict):
                text = node.get('text', '')
                children = node.get('content', [])
                return text + ''.join(extract_text(c) for c in children)
            elif isinstance(node, list):
                return ''.join(extract_text(c) for c in node)
            return ''
        desc = extract_text(f['description'])

    assignee = f.get('assignee')
    assignee_name = assignee.get('displayName', 'Unassigned') if assignee else 'Unassigned'
    assignee_email = assignee.get('emailAddress', '') if assignee else ''

    # Sprint info
    sprint_field = f.get('customfield_10020')
    sprint_name = ''
    if sprint_field and isinstance(sprint_field, list) and len(sprint_field) > 0:
        last = sprint_field[-1]
        sprint_name = last.get('name', '') if isinstance(last, dict) else ''

    # Components
    components = [c['name'] for c in f.get('components', [])]

    bugs.append({
        'key': issue['key'],
        'summary': f['summary'],
        'description': desc[:2000],  # Truncate long descriptions
        'priority': f['priority']['name'],
        'assignee': assignee_name,
        'assignee_email': assignee_email,
        'components': components,
        'sprint': sprint_name,
        'created': f.get('created', ''),
        'updated': f.get('updated', ''),
        'url': f'https://redhat.atlassian.net/browse/{issue["key"]}'
    })

json.dump(bugs, open('.output/bug-triage/new_bugs.json', 'w'), indent=2)
print(f"Found {len(bugs)} new bugs")
```

### 1.3 Early Exit

If no bugs are found (`len(bugs) == 0`), skip Phases 2-3 and send a simple "no new bugs" Slack notification, then exit.

---

## Phase 1.5: Dedup — Skip Previously Analyzed Bugs

Bugs can stay in "New" status for days (PTO, meetings, etc.). Before spawning analysis sub-agents, check whether each bug was already triaged (label or comment). This avoids redundant work and API calls.

### 1.5.1 Check Prior Analysis

```bash
python3 workflows/daily-bug-triage/check_prior_analysis.py \
  .output/bug-triage/new_bugs.json \
  .output/bug-triage/bugs_to_analyze.json \
  .output/bug-triage/bugs_previously_analyzed.json
```

The script treats a bug as previously analyzed when **either**:

- Issue has label **`agent-triaged`**, or
- A comment contains both `"server-foundation-agent"` and `"Bug Triage Analysis"`

It splits bugs into two lists:

- **`bugs_to_analyze.json`** — no prior triage found → proceed to Phase 2
- **`bugs_previously_analyzed.json`** — already triaged → skip to report

### 1.5.2 Use Filtered List

From this point forward, Phase 2 and Phase 2.5 operate on `bugs_to_analyze.json` (NOT the original `new_bugs.json`).

Previously analyzed bugs are included in the Slack report (Phase 3) under a separate "Previously Analyzed" section so the team is aware they are still in "New" status and may need attention.

### 1.5.3 Skip Conditions

Skip this phase (treat all bugs as new) if:
- `JIRA_EMAIL` or `JIRA_API_TOKEN` are not set (cannot fetch comments)
- Environment variable `SKIP_DEDUP=1` is set (manual override)

---

## Phase 2: Analyze Each Bug (Sub-Agents)

For each bug, spawn a **sub-agent** to perform a deep-dive analysis against the codebase. This prevents context window exhaustion when analyzing multiple bugs.

### Sub-Agent Architecture

Each sub-agent:
1. Receives a single bug object (from Phase 1)
2. Reads `prompts/daily-bug-triage-analyze.md` (or `workflows/daily-bug-triage/analyze_bug.md`) for its instructions
3. Identifies the relevant repository based on bug summary, description, and components
4. Searches `repos/` (read-only clones) for relevant code
5. Analyzes the root cause based on code and bug description
6. Writes result to `.output/bug-triage/analyses/bug-<KEY>.json`

### Spawning Sub-Agents

Use the Agent tool to spawn each sub-agent:

```
For each bug in bugs_to_analyze.json (filtered by Phase 1.5):
  Agent(
    subagent_type: "general-purpose",
    description: "Analyze bug <KEY>",
    prompt: "Read prompts/daily-bug-triage-analyze.md for instructions.
             Here is the bug data: <BUG_JSON>.
             Analyze this bug and write the result to .output/bug-triage/analyses/bug-<KEY>.json"
  )
```

**Parallelism**: Spawn up to 3-5 sub-agents concurrently. Each operates independently on its own bug.

### Analysis Result Schema

Each sub-agent writes a JSON file to `.output/bug-triage/analyses/bug-<KEY>.json`:

```json
{
  "key": "ACM-12345",
  "summary": "MCA will not update hosting-cluster-name annotation",
  "priority": "Major",
  "assignee": "Le Yang",
  "url": "https://redhat.atlassian.net/browse/ACM-12345",
  "analysis_status": "root-cause-found | partial-analysis | insufficient-info | error",
  "relevant_repo": "stolostron/multicloud-operators-foundation",
  "relevant_files": ["pkg/controllers/addon/addon_controller.go:125"],
  "root_cause": "Human-readable explanation of the root cause",
  "suggested_fix": "Brief description of how to fix it",
  "confidence": "high | medium | low",
  "auto_fix_eligible": true,
  "draft_pr_url": "",
  "notes": "Any additional context or caveats"
}
```

- `auto_fix_eligible`: Set by the analysis sub-agent. `true` when all three conditions are met: `analysis_status == "root-cause-found"` AND `confidence == "high"` AND `suggested_fix` is non-empty.
- `draft_pr_url`: Populated by Phase 2.5 after a draft PR is created. Empty string if no PR was created.

### Analysis Status Values

| Status | Meaning |
|--------|---------|
| `root-cause-found` | Agent identified the root cause with confidence |
| `partial-analysis` | Agent found relevant code but could not pinpoint exact cause |
| `insufficient-info` | Bug description lacks enough detail for analysis |
| `error` | Agent encountered an error during analysis |

---

## Phase 2.5: Auto-Fix for High-Confidence Bugs (opt-in)

**Default: skip this phase.** Phase 2.5 runs only when explicitly enabled via
`ENABLE_AUTO_FIX` in the task description / `instruction_prompt`, or env `AUTO_FIX=1`.

When enabled, after all analysis sub-agents complete, check for bugs eligible for
automatic fix. For each eligible bug, spawn a **fix sub-agent** that implements the
fix and submits a draft PR for human review.

### Eligibility Gate

A bug qualifies for auto-fix only when **all three conditions** are met:

| Condition | Field | Required Value |
|-----------|-------|----------------|
| Root cause identified | `analysis_status` | `root-cause-found` |
| High confidence | `confidence` | `high` |
| Fix described | `suggested_fix` | non-empty string |

The analysis sub-agent sets `auto_fix_eligible: true` in its output when all conditions are met. Phase 2.5 reads this field — it does NOT re-evaluate eligibility.

### Fix Sub-Agent Flow

For each eligible bug, spawn a fix sub-agent:

```
Agent(
  subagent_type: "general-purpose",
  description: "Fix bug <KEY> and submit draft PR",
  prompt: "You are a fix sub-agent for the daily bug triage workflow.

    ## Bug Info
    <BUG_ANALYSIS_JSON>

    ## Instructions

    1. Clone the repo using the workspace clone skill:
       bash .claude/skills/sfa-workspace-clone/clone-worktree.sh --new <relevant_repo> fix/<KEY> --base main

    2. Read the relevant files listed in the analysis to understand the current code.

    3. Implement the fix described in `suggested_fix`. Keep changes minimal and focused:
       - Only modify files directly related to the fix
       - Follow existing code style and patterns
       - Add or update unit tests if the fix is testable

    4. Commit with sign-off:
       git commit -s -m 'fix: <summary based on bug>'

    5. Push and create a DRAFT PR:
       gh pr create --draft --repo <relevant_repo> --title 'fix: <bug summary>' \
         --body '## Bug
       <bug_url>

       ## Root Cause
       <root_cause from analysis>

       ## Fix
       <description of changes made>

       ## Auto-generated
       This draft PR was automatically generated by server-foundation-agent based on bug triage analysis.
       **Human review is required before merging.**

       Co-Authored-By: server-foundation-agent <noreply@redhat.com>'

    6. Write the draft PR URL to the analysis file:
       Update .output/bug-triage/analyses/bug-<KEY>.json — set draft_pr_url to the PR URL.

    7. If ANY step fails (tests fail, code won't compile, PR creation fails):
       - Do NOT force through — leave draft_pr_url empty
       - Add failure details to the 'notes' field in the analysis JSON
       - Exit cleanly
  "
)
```

### Parallelism & Safety

- Spawn up to **2** fix sub-agents concurrently (less than analysis to avoid race conditions)
- Each fix sub-agent operates in its own worktree — no conflicts between concurrent fixes
- If a fix sub-agent fails, it does NOT block the workflow — the bug simply won't have a draft PR

### Skip Conditions

Skip Phase 2.5 entirely by default, or when:

- `ENABLE_AUTO_FIX` is **not** in the task description / `instruction_prompt` and `AUTO_FIX=1` is not set
- No bugs have `auto_fix_eligible: true`

---

## Phase 3: Generate Report & Slack Payload

After all sub-agents complete, generate the Slack payload from collected analysis results.

### 3.1 Collect Results

Read all `bug-*.json` files from `.output/bug-triage/analyses/` directory.

### 3.2 Generate Slack Payload

```bash
python3 workflows/daily-bug-triage/generate_slack_payload.py \
  .output/bug-triage/analyses/ \
  .output/bug-triage/slack_payload.json \
  --previously-analyzed .output/bug-triage/bugs_previously_analyzed.json
```

---

## Phase 3.5: Post Full Analysis to Jira

After generating the Slack payload, post the complete (non-truncated) analysis as a Jira comment on each bug. This ensures the full root cause, suggested fix, and relevant files are available directly on the Jira issue — the Slack notification only contains a concise summary.

### 3.5.1 Post Comments

```bash
python3 workflows/daily-bug-triage/post_jira_comments.py \
  .output/bug-triage/analyses/
```

The script:
- Reads each `bug-*.json` from the analyses directory
- Builds a Jira wiki markup comment with the full root cause, suggested fix, relevant files, and draft PR link
- Posts the comment via Jira REST API v2
- Adds label **`agent-triaged`** to the issue after a successful comment
- Skips bugs with `analysis_status == "error"`

### 3.5.2 Add Triage Label (MCP)

When using Jira MCP instead of the script, after each successful `add_comment`, call
**`update_issue`** / **`editJiraIssue`** to add label **`agent-triaged`** (skip if
already present). Do not change status or other fields.

### 3.5.3 Skip Conditions

Skip this phase if:
- `JIRA_EMAIL` or `JIRA_API_TOKEN` are not set
- No analysis files exist

---

## Phase 4: Distribute

Send the Slack payload:

```bash
bash .claude/skills/sfa-slack-notify/send_to_slack.sh .output/bug-triage/slack_payload.json
```

**Dependencies**:
- `workflows/daily-bug-triage/check_prior_analysis.py`
- `workflows/daily-bug-triage/generate_slack_payload.py`
- `workflows/daily-bug-triage/post_jira_comments.py`
- `.claude/skills/sfa-slack-notify/send_to_slack.sh`

---

## Slack Message Structure

### Header
```
🐛 SF Daily Bug Triage — YYYY-MM-DD
```

### Summary
```
*Summary:* {N} new bugs analyzed · {n} draft PRs submitted · {n} still in New (previously analyzed)
*Root cause found:* {n}  ·  *Partial:* {n}  ·  *Needs info:* {n}
```

### Per-Bug Sections

For each bug, grouped by `analysis_status`:

**Root Cause Found (with draft PR):**
```
*🟢 Root Cause Identified ({n})*
• <url|ACM-12345> *Major* — MCA will not update hosting-cluster-name annotation
  _Repo:_ multicloud-operators-foundation · _Files:_ addon_controller.go:125
  _Cause:_ The reconciler does not watch for annotation changes on MCA objects
  _Fix:_ Add annotation predicate to the controller watch
  🔧 _Draft PR:_ <pr_url|#123> — ready for review
```

**Root Cause Found (no auto-fix):**
```
• <url|ACM-12346> *Major* — Some other bug
  _Repo:_ cluster-proxy · _Files:_ proxy.go:42
  _Cause:_ Connection pool not cleaned up on timeout
  _Fix:_ Add defer cleanup in handleConnection
```

**Partial Analysis:**
```
*🟡 Partial Analysis ({n})*
• <url|ACM-12346> *Critical* — Cluster import fails silently
  _Repo:_ managedcluster-import-controller
  _Notes:_ Found relevant error handling code but could not reproduce exact scenario described
```

**Insufficient Info:**
```
*🔴 Needs More Info ({n})*
• <url|ACM-12347> *Normal* — Random cluster proxy disconnections
  _Reason:_ Bug description lacks reproduction steps and environment details
```

**Previously Analyzed (still in New):**
```
*⏳ Still in New — Previously Analyzed ({n})*
_These bugs were analyzed in a prior triage run but remain in New status. They may need assignee attention._
• <url|ACM-12348> *Major* — Addon install fails on SNO
  _Assignee:_ Le Yang · _Created:_ 2026-03-18 · _Still in New_
```

### Context Footer
```
Generated by server-foundation-agent · YYYY-MM-DD
```

---

## Repo Identification Strategy

The sub-agent maps bugs to repos using these signals (in priority order):

1. **Component field** — Jira components often map directly to repos (e.g., "cluster-proxy" → cluster-proxy repo)
2. **Keywords in summary/description** — Look for repo names, controller names, CRD names (e.g., "MCA" → ManagedClusterAddon → multicloud-operators-foundation or addon-framework)
3. **Assignee ownership** — Cross-reference with `team-members/team-members.md`
4. **Repo inventory** — Use `docs/repos.md` as the full list of SF repos

### Keyword → Repo Mapping (Common Patterns)

| Keyword | Likely Repo |
|---------|-------------|
| MCA, ManagedClusterAddon, addon | multicloud-operators-foundation or addon-framework |
| import, klusterlet, ManagedCluster import | managedcluster-import-controller |
| proxy, konnectivity, tunnel | cluster-proxy or cluster-proxy-addon |
| ServiceAccount, managed-sa | managed-serviceaccount |
| permission, ClusterPermission, RBAC | cluster-permission |
| foundation, clusterinfo, ManagedClusterInfo | multicloud-operators-foundation |
| metrics, state-metrics | clusterlifecycle-state-metrics |
| klusterlet-addon | klusterlet-addon-controller |
| OCM, registration, work | ocm |

---

## Edge Cases

- **Bug with empty description**: Mark as `insufficient-info` with note "No description provided"
- **Bug referencing multiple repos**: Analyze the most likely repo based on keyword density; mention others in `notes`
- **Bug about infrastructure/CI (not code)**: Mark as `partial-analysis` with note about non-code issue
- **Repos not in clones**: If the relevant repo is not under `repos/`, note this limitation
- **Analysis timeout**: If a sub-agent takes too long, it should write a partial result and exit

## Performance Notes

- Phase 1 makes one Jira API call — very fast
- Phase 2 sub-agents run in parallel (up to 3-5 concurrent)
- Sub-agents only read code from `repos/` (local clones) — no git clone needed
- Total workflow should complete within 10-15 minutes for typical bug counts (1-10 bugs)
