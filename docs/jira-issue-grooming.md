# Jira issue grooming (Server Foundation agent)

How to prepare ACM issues for the SF agent-swarm fix workflow (`jira-agent-pipeline`).

## Eligibility

| Field | Required value |
|-------|----------------|
| Project | ACM |
| Component | Server Foundation |
| Status | New or To Do |
| Resolution | Unresolved |
| Label | `issue-for-agent` |
| Security | None |

The **Server Foundation** component scopes the queue so MCIC-only groomed issues
(component differs) are not picked up by this agent.

## While processing

When the agent picks up an issue, it transitions status to **In Progress** via MCP
(`transition_issue` / `transitionJiraIssue`) before implementing.

## After processing

Add label `agent-processed` via Jira MCP tool `update_issue`, or manually in Jira.

To reprocess: remove `agent-processed` and ensure `issue-for-agent` is present.

**Closed PR without merge:** If a prior agent PR was closed but not merged, the
fix agent should **try again** — open a new draft PR. Triage analysis comments alone do
not block re-fix. Remove `agent-processed` if it was applied erroneously while the PR
was still open or after a closed PR.

## JQL: agent queue

```
project = ACM
AND resolution = Unresolved
AND status in (New, "To Do")
AND component = "Server Foundation"
AND labels = issue-for-agent
AND labels != agent-processed
ORDER BY created ASC
```

List the queue with agent-swarm prompt `prompts/jira-agent-pipeline.md` (Phase 1) or MCP
`search_issues`.

## Description template

Name the **target repository** in Context so the agent does not guess wrong among
SF repos.

```markdown
## Context
The klusterlet import controller in `stolostron/managedcluster-import-controller`
(pkg/controller/autoimport/...) fails when ...

## Acceptance criteria
- [ ] Root cause fixed in managedcluster-import-controller
- [ ] Unit test added or updated
- [ ] make check passes
- [ ] make test passes

## Steps to reproduce
1. Create ManagedCluster with ...
2. Observe ...

## Expected behavior
Import completes and klusterlet becomes available.

## Actual behavior
ManagedCluster stays in Unknown state with condition ...
```

## Scope guidance

Good candidates:

- Unit-testable controller or operator bugs
- Clear acceptance criteria naming one SF repo
- Changes confined to a single repository

Poor candidates (defer to humans):

- Multi-repo changes across OCM + stolostron + addon-framework
- Requires live cluster reproduction only (use `sfa-bug-reproduce` first)
- CRD/API breaking changes
- Security-sensitive credential handling

## Agent-swarm prompts

| Prompt | Purpose |
|--------|---------|
| `prompts/jira-agent-pipeline.md` | List queue, pick oldest (or `instruction_prompt` key), fix, draft PR |
| `prompts/jira-solve.md` | On-demand: fix one key from `instruction_prompt` (delegates auth/solve steps to pipeline Phase 2–3) |

There is **no** `docs/jira-solve.md`. Do not reference that path — solve specs are
only under `prompts/`.

Optional: pass `instruction_prompt: ACM-12345` to either prompt to fix a specific key
instead of the oldest queue item (`jira-agent-pipeline` only).

Setup: [prompts/README.md](../prompts/README.md)

## Relationship to daily bug triage

| Workflow | Picks bugs by | Default action |
|----------|---------------|----------------|
| [daily-bug-triage](../workflows/daily-bug-triage.md) | Status **New**, SF component | Analyze + Jira comment (`agent-triaged`) |
| Jira agent pipeline | Label **`issue-for-agent`**, groomed | Implement fix + draft PR (`agent-processed`) |

Use daily triage for discovery and RCA on all new bugs. Groom promising,
single-repo fixes with `issue-for-agent` when ready for automated implementation.
