# Jira Integration

Server Foundation team uses Red Hat Jira Cloud (https://redhat.atlassian.net) for issue tracking under the **ACM** (Advanced Cluster Management) project.

## Quick Reference

- **Project key**: `ACM`
- **Default component**: `Server Foundation`
- **Browse URL**: `https://redhat.atlassian.net/browse/<ISSUE-KEY>`
- **Auth**: Basic Auth with `$JIRA_EMAIL` + `$JIRA_API_TOKEN`

## Reference Materials

Load these on-demand based on the task at hand:

| Reference | Path | When to Load |
|-----------|------|-------------|
| [Custom Fields](jira/custom-fields.md) | `docs/jira/custom-fields.md` | Creating/updating issues with custom fields (severity, activity type, versions) |
| [Workflows](jira/workflows.md) | `docs/jira/workflows.md` | Status transitions, understanding workflow states |
| [Formatting](jira/formatting.md) | `docs/jira/formatting.md` | Writing comments/descriptions with Jira wiki markup |
| [JQL Reference](jira/jql-reference.md) | `docs/jira/jql-reference.md` | Building search queries, JQL syntax and functions |
| [API Reference](jira/api-reference.md) | `docs/jira/api-reference.md` | REST API endpoints, authentication, curl examples |
| [Templates](jira/templates.md) | `docs/jira/templates.md` | Issue creation templates (Bug, Epic, Story, Task, Vulnerability) |

## Bootstrap Sequence

At session start, verify Jira connectivity before executing any Jira operation:

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "https://redhat.atlassian.net/rest/api/2/myself" \
  | jq '{name: .displayName, email: .emailAddress, accountId: .accountId}'
```

If auth fails (missing env vars or invalid token), stop and report clearly.

## Skills

### CRUD and action items

| Skill | Purpose | Trigger |
|-------|---------|---------|
| [sfa-jira-search](../.claude/skills/sfa-jira-search/SKILL.md) | Search/list issues (team-wide or per-member) | "show jiras", "what bugs does X have" |
| [sfa-jira-create](../.claude/skills/sfa-jira-create/SKILL.md) | Create issues with SF defaults | "create a jira bug" |
| [sfa-jira-update](../.claude/skills/sfa-jira-update/SKILL.md) | Status transitions and field updates | "move ACM-12345 to review" |
| [sfa-jira-comment](../.claude/skills/sfa-jira-comment/SKILL.md) | Add comments (PR links, progress notes) | "post PR to ACM-12345" |
| [sfa-jira-inbox](../.claude/skills/sfa-jira-inbox/SKILL.md) | Inbox and action items (assigned, reported, mentioned) | "jira inbox", "what needs my attention" |

### Reports and triage

| Skill | Purpose | Trigger |
|-------|---------|---------|
| [sfa-jira-standup](../.claude/skills/sfa-jira-standup/SKILL.md) | Daily standup report (per assignee) | "standup", "daily update" |
| [sfa-jira-triage](../.claude/skills/sfa-jira-triage/SKILL.md) | Bug triage summary by severity (lightweight list) | "bug triage summary", "unassigned bugs" |
| [sfa-jira-sprint-report](../.claude/skills/sfa-jira-sprint-report/SKILL.md) | Sprint health report (quick team overview) | "sprint status", "sprint report" |

For automated daily team coaching (burndown, cycle time, Slack), use the [daily-scrum-prep](../workflows/daily-scrum-prep.md) workflow instead of `sfa-jira-sprint-report`.

### Bug and security analysis

| Skill | Purpose | Trigger |
|-------|---------|---------|
| [sfa-bug-analyze](../.claude/skills/sfa-bug-analyze/SKILL.md) | SF relevance and reproducibility scoring for one bug | "analyze bug ACM-12345", "check reproducibility" |
| [sfa-bug-reproduce](../.claude/skills/sfa-bug-reproduce/SKILL.md) | End-to-end reproduction (cluster, test, Jira update) | "reproduce bug ACM-12345" |
| [sfa-cve-analysis](../.claude/skills/sfa-cve-analysis/SKILL.md) | CVE grouping, tracking tasks, branch impact analysis | CVE monitoring, security triage |

For deep triage of **New** bugs with codebase RCA and Slack, use [daily-bug-triage](../workflows/daily-bug-triage.md) instead of `sfa-jira-triage`.

CVE dependency upgrade procedures: see [older-branch-dep-upgrade](../solutions/older-branch-dep-upgrade.md) in `solutions/`.

## Lifecycle Integration

```text
1. Create issue         →  sfa-jira-create
2. Start development    →  sfa-jira-update --status "In Progress"
3. Create PR            →  sfa-jira-comment --pr-url <URL>
4. Submit for review    →  sfa-jira-update --status Review
5. PR merged            →  sfa-jira-comment "PR merged" + sfa-jira-update --status Resolved
```
