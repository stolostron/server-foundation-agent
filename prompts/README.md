# Agent-swarm prompts

Model-agnostic workflow prompts for [agent-swarm](https://github.com/stolostron/agent-swarm)
(OpenCode/Crush). Sync this folder as a **Prompt Source** in a Swarmer workspace.

These are the runnable, self-contained specs for scheduled SFA automation.
Detailed phase docs and scripts live under `workflows/` — prompts embed what the
agent needs in a single injected file per run.

## Prompt map

| File | Workflow reference | Agent-swarm session | Schedule (example) |
|------|-------------------|---------------------|-------------------|
| `daily-bug-triage.md` | `workflows/daily-bug-triage.md` | `sfa-daily-bug-triage` | `0 9 * * 1-5` (weekdays 09:00 Asia/Shanghai) |
| `daily-bug-triage-analyze.md` | `workflows/daily-bug-triage/analyze_bug.md` | spawned by triage orchestrator | — |
| `draft-pr-digest.md` | `workflows/draft-pr-digest.md` | `acm-agent-draft-pr-digest` | `0 17 * * 1-5` (weekdays 17:00 Asia/Shanghai) |
| `jira-agent-pipeline.md` | `docs/jira-issue-grooming.md` | `sfa-jira-agent` | `30 10 * * 1` (Mon 10:30 Asia/Shanghai) |
| `jira-solve.md` | `docs/jira-issue-grooming.md` | `sfa-jira-solve` | On-demand + `instruction_prompt: ACM-12345` |
| `weekly-pr-report.md` | `workflows/weekly-pr-report.md` | `sfa-weekly-pr-report` | `0 6 * * 1` (Mon 06:00 Asia/Shanghai) |

## Conventions

Each orchestrator prompt embeds an **SFA conventions** section (self-contained for
agent-swarm). Extended reference: `prompts/_sfa-conventions.md`.

## Workspace layout

| Clone path | Repository |
|------------|------------|
| `/workspace/server-foundation-agent` | `stolostron/server-foundation-agent` |

**Required for jira-agent-pipeline / jira-solve / draft-pr-digest / weekly-pr-report:** add the SFA repo as a
**session repo** (not Prompt Source only). Prompt Source injects markdown; it does not
clone `scripts/` or `build/scripts/` onto disk.

**GitHub App creds:** secret `swarmer-agent-extra-env` in the **workspace namespace**
(keys: `GH_APP_ID`, `GH_APP_INSTALLATION_ID`, `GH_APP_PRIVATE_KEY`). Swarmer mounts it
via `envFrom` on agent pods. Do not attach a session PAT when using App auth.

**Working directory:** `/workspace/server-foundation-agent`

Optional: pre-sync `repos/` in the workspace PVC or run `./repos/sync-repos.sh` at
the start of triage.

## MCP

Enable workspace **Jira MCP** (`jira-mcp-server` / Atlassian catalog). Prefer MCP
for search and comments; Python scripts under `workflows/daily-bug-triage/` are
fallbacks when MCP cannot post or read comments.

### GitHub App auth (jira-agent-pipeline / jira-solve / draft-pr-digest / weekly-pr-report)

| Requirement | Notes |
|-------------|--------|
| Workspace repo | `stolostron/server-foundation-agent` → `/workspace/server-foundation-agent` |
| `swarmer-agent-extra-env` | `GH_APP_ID`, `GH_APP_INSTALLATION_ID`, `GH_APP_PRIVATE_KEY` |
| Session PAT | **Leave unset** — PAT `GH_TOKEN` overrides App IAT scripts |
| Pod tools | `openssl`, `jq`, `gh`, `git` |

IAT generation uses `build/scripts/github-token-manager.sh` from the workspace
clone (same JWT→IAT flow as HyperShift Prow). Custom SFA container image optional.

## KubeOpenCode parity

CronTasks under `deploy/crontasks/` may reference `workflows/*.md` for the
always-on agent. Agent-swarm sessions should use these `prompts/` files instead.

Setup: [deploy/README.md](../deploy/README.md)

## MCIC parity

The SF fix-agent prompts mirror [mcic-ai-helpers `prompts/`](https://github.com/rokej/mcic-ai-helpers/tree/main/prompts)
(`jira-agent-pipeline`, `jira-solve`) but target **any SF repo**
via `sfa-workspace-clone` and scope the queue with component **Server Foundation**.

Groom issues per [docs/jira-issue-grooming.md](../docs/jira-issue-grooming.md).

## Claude Code parity

| Agent-swarm prompt | Claude Code / KubeOpenCode |
|--------------------|---------------------------|
| `daily-bug-triage.md` | `workflows/daily-bug-triage.md`, CronTask `daily-bug-triage` |
| `daily-bug-triage-analyze.md` | `workflows/daily-bug-triage/analyze_bug.md` |
| `draft-pr-digest.md` | `workflows/draft-pr-digest.md` |
| `jira-agent-pipeline.md` | `docs/jira-issue-grooming.md` |
| `jira-solve.md` | — (on-demand; pass issue key in `instruction_prompt`) |
| `weekly-pr-report.md` | `workflows/weekly-pr-report.md`, CronTask `weekly-pr-report` |
