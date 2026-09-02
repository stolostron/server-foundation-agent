# Solve one SF Jira issue (agent-swarm)

Implement a fix for a **single** groomed Server Foundation issue and open a **draft**
PR on the relevant SF repo.

Use when the session `instruction_prompt` contains an issue key (e.g. `ACM-12345`),
when `jira-pipeline.md` delegates to this spec, or when the user names a key explicitly.

## SFA conventions

**Working directory:** `/workspace/server-foundation-agent`

| Path | Repository |
|------|------------|
| `/workspace/server-foundation-agent` | `stolostron/server-foundation-agent` (this repo) |

**Jira:** MCP tools only (`get_issue` / `getJiraIssue`, `search_issues`,
`add_comment` / `addCommentToJiraIssue`, `update_issue` / `editJiraIssue`,
`transition_issue` / `transitionJiraIssue`). Host `https://redhat.atlassian.net`,
project ACM, component `Server Foundation`. No Jira CLI or curl.

**Eligibility labels:** `agent-triaged` + `issue-for-agent`, not `agent-processed`.

**Code access:**

| Location | Use |
|----------|-----|
| `repos/` | Read-only reference (`./repos/sync-repos.sh`) |
| `workspace/` | Writable worktrees for fixes (`sfa-workspace-clone` skill) |

**GitHub:** `gh` for draft PRs. Commits: Conventional Commits + `Signed-off-by` +
`Co-authored-by: server-foundation-agent <sfa-bot@redhat.com>` in commit body.

**SFA footprint** (from `docs/development-guide.md`): after PR create, add label
`sfa-assisted`; PR body footer and Jira comment signature below.

**Branch:** `fix-<KEY>` (e.g. `fix-ACM-12345`). In autonomous mode (`GH_APP_ID` set),
the clone skill auto-prefixes with `sfa/`.

Extended conventions: `prompts/_sfa-conventions.md`

## Instructions

1. **Issue key**
   - Parse from additional instructions / `instruction_prompt`, or from the
     orchestrator when invoked by `jira-pipeline.md`
   - Format: `ACM-<digits>`
   - If missing, stop and report that a key is required

2. **Fetch issue** — MCP `get_issue` with `issue_key`
   - Extract: summary, description, labels, status, components, comments
   - From description: Context, Acceptance criteria (if present); repro steps if present

3. **Load triage context**
   - Find the most recent comment containing `Bug Triage Analysis` and
     `server-foundation-agent`
   - Extract: `Relevant Repo`, root cause, suggested fix, relevant files
   - If no triage comment exists, identify the repo using keyword → repo map in
     `workflows/daily-bug-triage.md` (Repo Identification section) or `docs/repos.md`
   - If `repos/` clones look empty, run once: `./repos/sync-repos.sh`

4. **Eligibility check**
   - Project ACM, component `Server Foundation`, unresolved
   - Issuetype **Bug** only — skip if issuetype is **Embargoed Bug** or security level is
     **Embargoed Security Issue** (explain and stop; no PR)
   - Status New or To Do
   - Has labels `agent-triaged` and `issue-for-agent`, not `agent-processed`
   - If not eligible, explain why and stop (do not open a PR)

5. **Start work in Jira** — transition status to **In Progress** (MCP only):
   - If status is already **In Progress**, skip
   - **jira-mcp-server:** `transition_issue` with `issue_key` and `transition`: `In Progress`
   - **Atlassian MCP:** `getTransitionsForJiraIssue` → find transition named
     `In Progress` → `transitionJiraIssue` with that transition id
   - If transition fails, `add_comment` with the error and stop (do not open a PR)

6. **Clone worktree**
   ```bash
   bash .claude/skills/sfa-workspace-clone/clone-worktree.sh \
     --new <org/repo> fix-<KEY> --base main
   ```
   Use `relevant_repo` from triage (e.g. `stolostron/managedcluster-import-controller`).
   For release-specific fixes, pass `--base release-*` or `--base backplane-*` when
   the Jira description or triage notes specify a target branch.

7. **Plan** — write `.output/jira-solve/spec-<KEY>.md` under working directory
   - Problem, approach, files to change, test plan
   - In scheduled/automated runs, implement immediately (no user prompt)

8. **Implement**
   - Follow triage `suggested_fix` when present; keep changes minimal and single-repo
   - Read relevant files from triage; follow existing code patterns
   - Add or update unit tests when practical
   - Run verification **sequentially** in the worktree:
     ```bash
     cd workspace/<org>/<repo>-worktrees/sfa/fix-<KEY>   # or pr path per clone skill
     make check    # allow ≥ 5 min; lint can be slow on first run
     make test
     ```
   - Fix failures from your changes; skip E2E unless the issue explicitly requires it

9. **Commit**
   - Conventional commit + `Signed-off-by` + `Co-authored-by` trailer in the body:
     ```bash
     git commit -s -m "$(cat <<'EOF'
     fix: <short summary>

     Co-authored-by: server-foundation-agent <sfa-bot@redhat.com>
     EOF
     )"
     ```

10. **Push and draft PR**
    ```bash
    git push origin sfa/fix-<KEY>   # autonomous mode; adjust for local fork mode
    gh pr create --draft --repo <org/repo> \
      --title "ACM-<KEY>: <short summary>" \
      --body "$(cat <<'EOF'
    ## Jira
    https://redhat.atlassian.net/browse/ACM-<KEY>

    ## Summary
    <what changed and why>

    ## Root Cause
    <from triage or your analysis>

    ## Test plan
    - [x] make check
    - [x] make test

    ---
    *Created with [server-foundation-agent](https://github.com/stolostron/server-foundation-agent)*
    EOF
    )"
    ```
    Check target repo for `.github/PULL_REQUEST_TEMPLATE.md` and use it if present
    (keep the SFA footer at the end).

11. **SFA footprint on PR** — after `gh pr create`, capture the PR number and:
    ```bash
    gh pr edit <PR-NUMBER> --repo <org/repo> --add-label "sfa-assisted"
    ```
    If the label does not exist in the target repo, the command fails — report in
    the run summary; the draft PR is still valid. Do not fail the whole run.

12. **Jira follow-up** (MCP only)
    - `add_comment` — link the draft PR URL, brief fix summary, and signature footer:
      ```
      ----
      _— server-foundation-agent_
      ```
    - `update_issue` — add label `agent-processed`

13. **Summary** — issue key, target repo, branch, PR URL, `sfa-assisted` label status,
    verification status

## Do not

- Use Jira CLI or curl
- Skip `make check` / `make test` when the target repo provides those targets
- Mark PR ready for review (draft only)
- Process more than one issue in this run
- Add `agent-processed` if no draft PR was created or tests failed after reasonable fixes
