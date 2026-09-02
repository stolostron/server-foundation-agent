---
name: sfa-jira-triage
description: "Generate a bug triage report for the Server Foundation team. Use this skill when the user wants to triage bugs, review new issues, check for unassigned bugs, or says 'triage bugs', 'new bugs', 'bug review', 'unassigned bugs', 'vulnerability review'. Queries Jira for recently created or unresolved bugs and formats a triage summary. Excludes Embargoed Bug issuetype and Embargoed Security Issue security level."
---

# Jira Bug Triage

Generate a triage report for SF bugs and vulnerabilities.

## Reference Loading

- **For JQL syntax**: Read `docs/jira/jql-reference.md`
- **For custom fields (severity)**: Read `docs/jira/custom-fields.md`
- **For API details**: Read `docs/jira/api-reference.md`

## Parameters

| Parameter | Required | Default | Notes |
|-----------|----------|---------|-------|
| days | No | 7 | How many days back to look for new issues |
| type | No | Bug, Vulnerability | Issue types to include |
| unassigned-only | No | false | Only show unassigned issues |

## Workflow

### Step 1: Query new/open bugs

> **Exclusions** (handled outside agent scope or human-only):
> - **Konflux auto-created bugs** (`labels = "konflux"` AND `labels = "auto-created"`) — separate system
> - **Embargoed issues** — issuetype **Embargoed Bug** or security level **Embargoed Security Issue**; **never triage**

**Query — New bugs in last N days:**

```
project = ACM AND component = "Server Foundation" AND issuetype IN (Bug, Vulnerability) AND issuetype != "Embargoed Bug" AND security != "Embargoed Security Issue" AND created >= -<days>d AND NOT (labels = "konflux" AND labels = "auto-created") ORDER BY priority ASC, created DESC
```

**Query — All unresolved bugs (if team overview needed):**

```
project = ACM AND component = "Server Foundation" AND issuetype IN (Bug, Vulnerability) AND issuetype != "Embargoed Bug" AND security != "Embargoed Security Issue" AND status NOT IN (Resolved, Closed) AND NOT (labels = "konflux" AND labels = "auto-created") ORDER BY priority ASC, cf[10840] ASC
```

Request fields: `["issuetype", "summary", "status", "priority", "assignee", "customfield_10840", "created", "updated"]`.

### Step 2: Categorize results

Group by severity (from `customfield_10840`):

1. **Critical** — needs immediate attention
2. **Important** — should be addressed this sprint
3. **Moderate** — plan for next sprint
4. **Low / Informational** — backlog

### Step 3: Format triage report

```markdown
## Bug Triage Report — <date>

**Period**: Last <N> days | **Total**: <count> issues

### Critical (<count>)
| Key | Summary | Status | Assignee | Created |
|-----|---------|--------|----------|---------|
| [ACM-XXX](...) | ... | New | Unassigned | 2026-03-22 |

### Important (<count>)
| Key | Summary | Status | Assignee | Created |
|-----|---------|--------|----------|---------|
| ... | ... | ... | ... | ... |

### Moderate (<count>)
...

### Summary
- **Unassigned**: <count> issues need owners
- **New (untouched)**: <count> issues still in New status
- **Oldest open**: ACM-XXX (created <date>)
```

### Step 4: Suggest actions

For unassigned issues, suggest assignees based on component keywords and team member expertise from `team-members/team-members.md`.

## Examples

```
/sfa-jira-triage
/sfa-jira-triage --days 14
Triage new bugs
Show unassigned SF bugs
Review vulnerabilities
```
