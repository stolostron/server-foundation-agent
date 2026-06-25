# Workflows

Workflows are **user-triggered or scheduled** multi-phase processes. The user knows the workflow exists and invokes it by name (e.g., "run daily bug triage"), or a cron job triggers it on a schedule.

**Key trait:** The human (or scheduler) initiates. The agent follows the defined phases in order.

> Compare with [Solutions](../solutions/README.md): solutions are **agent-discovered** — the agent searches `solutions/` when it encounters a specific problem during work and needs a known fix.

| Workflow | Description | Trigger |
|----------|-------------|---------|
| [daily-bug-triage](daily-bug-triage.md) | Triage all new SF Jira bugs with codebase analysis and Slack report | Daily cron / user request ([prompt](../prompts/daily-bug-triage.md); [developer guide](../docs/automated-bug-fix-developer-guide.md)) |
| [daily-scrum-prep](daily-scrum-prep.md) | Generate standup summaries from Jira activity | Daily cron / user request |
| [weekly-bot-pr-hygiene](weekly-bot-pr-hygiene.md) | Diagnose and fix failing bot PRs across SF repos | Weekly cron / user request |
| [weekly-pr-report](weekly-pr-report.md) | Generate weekly PR activity report for the team | Weekly / user request |
| [agent-pr-action-needed](agent-pr-action-needed.md) | Slack digest of `acm-agent` draft/approval-blocked PRs after jira-pipeline | Weekday cron / user request ([prompt](../prompts/agent-pr-action-needed.md)) |
| [jira-pipeline-pr-review](jira-pipeline-pr-review.md) | Address CodeRabbit/human review feedback on jira-pipeline PRs; squash + force-push | Weekday cron / user request ([prompt](../prompts/jira-pipeline-pr-review.md)) |
| [bug-analyze](bug-analyze.md) | Analyze Jira bugs for SF relevance and reproducibility scoring | On demand |

## Adding a New Workflow

1. Create `workflows/<workflow-name>.md` with the workflow phases
2. Update this table
3. Update the Documentation Index in `README.md`
4. Open a PR
