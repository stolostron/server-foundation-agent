# Agent-swarm prompts

Model-agnostic workflow prompts for [agent-swarm](https://github.com/stolostron/agent-swarm)
(OpenCode/Crush). Sync this folder as a **Prompt Source** in a Swarmer workspace.

These are the runnable, self-contained specs for scheduled SFA automation.
Detailed phase docs and scripts live under `workflows/` — prompts embed what the
agent needs in a single injected file per run.

## Jira automation model

**Developer guides:**

- [Automated bug fix — developer guide](../docs/automated-bug-fix-developer-guide.md)
  — human gates, labels, schedules, and end-to-end flow from New bug to merged PR.
- [Automated CVE fix — developer guide](../docs/automated-cve-fix-developer-guide.md)
  — ProsSec vulnerability issues, tracking tasks, dependency PRs, auto-close rules.

Two-stage SF Jira automation:

![SF Jira automation model](../docs/assets/jira-automation-model.png)

- **[daily-bug-triage.md](daily-bug-triage.md)**: triage New bugs; merged fix PRs on In Progress bugs → **Review** (Phase 0). Auto-fix stays **off** unless `ENABLE_AUTO_FIX` is set.
- **[jira-pipeline.md](jira-pipeline.md)**: the **only** scheduled auto-fix path; runs only when a human has added `issue-for-agent` after triage.

### Details

| Stage | Schedule | Auto-fix |
|-------|----------|----------|
| Triage | Weekdays 09:00 | **Off** unless `ENABLE_AUTO_FIX` |
| Fix | Weekdays 09:00 and 17:00 | **On** for `issue-for-agent` issues only |

**Labels:** `agent-triaged` (triage done) · `issue-for-agent` (human opt-in) · `agent-processed` (pipeline completed)

**Grooming:** triage → human adds `issue-for-agent` → pipeline fixes one issue → `agent-processed`. To retry: remove `agent-processed`, keep `issue-for-agent`.

### Human PR gate (after pipeline)

`jira-pipeline` opens **draft** PRs via `acm-agent[bot]` with `sfa-assisted` (and usually
`needs-ok-to-test` on stolostron repos). CI and review do not proceed until a developer:

1. Marks the PR **Ready for review**
2. Comments **`/ok-to-test`** when `needs-ok-to-test` is present
3. **Approves** once review looks good

**[agent-pr-action-needed.md](agent-pr-action-needed.md)** runs on a schedule, lists open
agent PRs in those states, and posts a digest to Slack (`SLACK_WEBHOOK_URL`). Full flow:
[workflows/agent-pr-action-needed.md](../workflows/agent-pr-action-needed.md).

**[jira-pipeline-pr-review.md](jira-pipeline-pr-review.md)** runs on a schedule, picks one
open `acm-agent` pipeline PR (`sfa-assisted`, `ACM-*` title) with review feedback, addresses
CodeRabbit and human review comments, squashes to one commit, and force-pushes. Full flow:
[workflows/jira-pipeline-pr-review.md](../workflows/jira-pipeline-pr-review.md).

Agent queue JQL and extended docs: [`_sfa-conventions.md`](_sfa-conventions.md)

## Prompt map

| File | Agent-swarm session | Schedule (example) |
|------|---------------------|-------------------|
| `daily-bug-triage.md` | `sfa-daily-bug-triage` | `0 9 * * 1-5` (weekdays 09:00 Asia/Shanghai) |
| `daily-bug-triage-analyze.md` | spawned by triage orchestrator | — |
| `jira-pipeline.md` | `sfa-jira-pipeline` | `0 9,17 * * 1-5` (weekdays 09:00 and 17:00 Asia/Shanghai) |
| `agent-pr-action-needed.md` | `sfa-agent-pr-action-needed` | `30 9,17 * * 1-5` (30 min after pipeline) |
| `jira-pipeline-pr-review.md` | `sfa-jira-pipeline-pr-review` | `0 10,18 * * 1-5` (after pipeline; address review feedback) |
| `jira-solve.md` | `sfa-jira-solve` | On-demand + `instruction_prompt: ACM-12345` |
| `fix-cve.md` | `sfa-fix-cve` | On-demand or cron (e.g. `0 9 * * 1-5` weekdays 09:00 Asia/Shanghai) |

Triage also references helper scripts under `workflows/daily-bug-triage/` and optional
long-form docs in `workflows/daily-bug-triage.md`.

**CVE fix:** `fix-cve.md` groups ProsSec vulnerability issues by CVE,
creates tracking tasks via `format-cve-tracking-task.py`, runs deep branch impact
analysis, posts Jira comments, opens **draft PRs** for fixable CVEs, and **closes**
vulnerability issues classified as Not Applicable. Skill:
`.claude/skills/sfa-cve-analysis/`.

**Developer guide:** [Automated CVE fix — developer guide](../docs/automated-cve-fix-developer-guide.md)
— human gates, Jira issue types, PR grooming, auto-close rules, and troubleshooting.

## Conventions

Each orchestrator prompt embeds an **SFA conventions** section (self-contained for
agent-swarm). Extended reference: `prompts/_sfa-conventions.md`.

## Workspace layout

| Clone path | Repository |
|------------|------------|
| `/workspace/server-foundation-agent` | `stolostron/server-foundation-agent` |

**Working directory:** `/workspace/server-foundation-agent`

Optional: pre-sync `repos/` in the workspace PVC or run `./repos/sync-repos.sh` at
the start of triage.

## MCP

Enable workspace **Jira MCP** (`jira-mcp-server` / Atlassian catalog). Prefer MCP
for search and comments; Python scripts under `workflows/daily-bug-triage/` are
fallbacks when MCP cannot post or read comments.

Setup: sync this folder as a **Prompt Source** in a Swarmer workspace — see
[agent-swarm](https://github.com/stolostron/agent-swarm).
