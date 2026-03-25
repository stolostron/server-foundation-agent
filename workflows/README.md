# Workflows

Workflows are **user-triggered or scheduled** multi-phase processes. The user knows the workflow exists and invokes it by name (e.g., "run daily bug triage"), or a cron job triggers it on a schedule.

**Key trait:** The human (or scheduler) initiates. The agent follows the defined phases in order.

> Compare with [Solutions](../solutions/README.md): solutions are **agent-discovered** — the agent searches `solutions/` when it encounters a specific problem during work and needs a known fix.

| Workflow | Description | Trigger |
|----------|-------------|---------|
| [daily-bug-triage](daily-bug-triage.md) | Triage all new SF Jira bugs with codebase analysis and Slack report | Daily cron / user request |
| [daily-scrum-prep](daily-scrum-prep.md) | Generate standup summaries from Jira activity | Daily cron / user request |
| [weekly-bot-pr-hygiene](weekly-bot-pr-hygiene.md) | Diagnose and fix failing bot PRs across SF repos | Weekly cron / user request |
| [weekly-pr-report](weekly-pr-report.md) | Generate weekly PR activity report for the team | Weekly / user request |
| [bug-analyze](bug-analyze.md) | Analyze Jira bugs for SF relevance and reproducibility scoring | On demand |

## Adding a New Workflow

1. Create `workflows/<workflow-name>.md` with the workflow phases
2. Update this table
3. Update the Documentation Index in `README.md`
4. Open a PR
