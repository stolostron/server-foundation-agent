# JQL Reference

JQL (Jira Query Language) syntax reference for querying the ACM project.

## Basic Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `=` | Equals | `project = ACM` |
| `!=` | Not equals | `status != Closed` |
| `~` | Contains (text) | `summary ~ "cluster-proxy"` |
| `!~` | Does not contain | `summary !~ "test"` |
| `IN` | In list | `status IN ("New", "In Progress")` |
| `NOT IN` | Not in list | `status NOT IN (Closed, Resolved)` |
| `IS EMPTY` | Field is empty | `fixVersion IS EMPTY` |
| `IS NOT EMPTY` | Field has value | `assignee IS NOT EMPTY` |
| `>`, `<`, `>=`, `<=` | Comparison | `priority >= Major` |

## Functions

| Function | Description | Example |
|----------|-------------|---------|
| `currentUser()` | Logged-in user | `assignee = currentUser()` |
| `openSprints()` | Active sprints | `sprint IN openSprints()` |
| `startOfDay()` | Start of today | `created >= startOfDay()` |
| `startOfWeek()` | Start of this week | `updated >= startOfWeek()` |
| `endOfDay()` | End of today | `due <= endOfDay()` |
| `-Nd` / `+Nd` | Relative days | `created >= -7d` (last 7 days) |

## SF Team Common Queries

### Default Query (current user, open issues)

```
project = ACM AND assignee = currentUser() AND component = "Server Foundation" AND status NOT IN (Closed)
```

### Specific Team Member

```
project = ACM AND assignee = "email@redhat.com" AND component = "Server Foundation" AND status NOT IN (Closed)
```

### All SF Team Members

```
project = ACM AND assignee IN ("email1@redhat.com", "email2@redhat.com", ...) AND component = "Server Foundation" AND status NOT IN (Closed)
```

### Current Sprint

```
... AND sprint IN openSprints()
```

### Named Sprint

```
... AND sprint = "SF Sprint 2026-Q1-S3"
```

### Bugs by Severity

```
project = ACM AND component = "Server Foundation" AND issuetype = Bug AND issuetype != "Embargoed Bug" AND security != "Embargoed Security Issue" AND status NOT IN (Closed, Resolved) ORDER BY cf[10840] ASC
```

> Embargoed issues: skip when issuetype is **Embargoed Bug** or security level is **Embargoed Security Issue** (Jira API field `security`).

### Recently Created (last 7 days)

```
project = ACM AND component = "Server Foundation" AND created >= -7d ORDER BY created DESC
```

### Issues Updated Today

```
project = ACM AND component = "Server Foundation" AND assignee = currentUser() AND updated >= startOfDay()
```

### Issues Updated Yesterday (for standup)

```
project = ACM AND component = "Server Foundation" AND assignee = currentUser() AND updated >= startOfDay(-1d) AND updated < startOfDay()
```

## Custom Field References in JQL

| Field | JQL Reference |
|-------|--------------|
| Severity | `cf[10840]` |
| Activity Type | `cf[10464]` |
| Epic Name | `cf[10011]` |
| Sprint | `sprint` (built-in) |

## Query Construction Tips

1. Always include `project = ACM` and `component = "Server Foundation"`
2. Use `status NOT IN (Closed)` instead of listing all open statuses
3. Use `statusCategory` for cross-project queries: `"To Do"`, `"In Progress"`, `"Done"`
4. Quote string values with spaces: `"In Progress"`, `"Server Foundation"`
5. Use `ORDER BY` for consistent results: `ORDER BY priority ASC, updated DESC`
