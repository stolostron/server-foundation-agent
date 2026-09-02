# SF periodic Jira agent pipeline

Query the groomed SF agent queue → pick **one** issue → solve → draft PR → Jira updates.

Designed for **non-interactive** scheduled runs (twice daily on weekdays).
Single-issue steps: `jira-solve.md`. Overview: `prompts/README.md`.

This is the **only** scheduled auto-fix path for SF Jira. Issues enter the queue
when a human adds `issue-for-agent` after daily triage (`agent-triaged`).

## SFA conventions

**Working directory:** `/workspace/server-foundation-agent`

**Jira:** MCP only (`search_issues`, `get_issue`, `add_comment`, `update_issue`,
`transition_issue` or `transitionJiraIssue`). Host `https://redhat.atlassian.net`,
project ACM. No Jira CLI or curl.

**Verify:** `make check`, `make test` in the target repo worktree (see `jira-solve.md`).

**Agent queue JQL:**

```
project = ACM AND component = "Server Foundation" AND issuetype = Bug AND issuetype != "Embargoed Bug" AND security != "Embargoed Security Issue" AND resolution = Unresolved AND status in (New, "To Do") AND labels = agent-triaged AND labels = issue-for-agent AND labels != agent-processed ORDER BY created ASC
```

Extended conventions: `prompts/_sfa-conventions.md`

## Instructions

1. **Query queue** — MCP `search_issues`:
   - `jql`: agent queue JQL above
   - `max_results`: `1`

2. **Empty queue**
   - If no issues: report "agent queue empty" and stop successfully
   - Do not open PRs or modify Jira

3. **Pick issue**
   - Use the single returned issue (oldest by `created`)
   - Record `issue_key` and summary in your working notes

4. **Solve** — follow the same steps as `jira-solve.md` for that `issue_key`:
   - `get_issue` → load triage context → eligibility → **transition to In Progress**
   - Clone worktree → implement per triage `suggested_fix`
   - `make check` + `make test`; branch `fix-<KEY>`, conventional commits, draft PR
   - Jira: `add_comment` (PR link) + `update_issue` (label `agent-processed`)

5. **Limits**
   - Process **exactly one** issue per run (`MAX_ISSUES = 1`)
   - Do not start a second issue even if time remains

6. **Failure handling**
   - If implementation or tests fail after reasonable fixes: do **not** add `agent-processed`
   - `add_comment` on the issue with failure summary and any branch name (no PR if none created)
   - Report failure in final summary for operators

7. **Final summary**
   - Issue key, outcome (PR URL or failure reason), target repo, `make check` / `make test` status

## Do not

- Ask the user for confirmation (automated mode)
- Use Jira CLI or curl
- Process multiple issues per run
- Fix issues that lack both `agent-triaged` and `issue-for-agent` labels
- Process embargoed issues (**Embargoed Bug** issuetype or **Embargoed Security Issue**
  security level)
