# SF Jira solve (single issue)

Implement a fix for **one** groomed ACM issue and open a **draft** PR on the target SF
repository for human review.

Use when the session `instruction_prompt` contains an issue key (e.g. `ACM-12345`)
or when the user names a key explicitly.

## SFA conventions

**Working directory:** `/workspace/server-foundation-agent`

**Jira:** MCP only (`get_issue`, `search_issues`, `add_comment`, `update_issue`,
`transition_issue` or `transitionJiraIssue`). Host `https://redhat.atlassian.net`,
project ACM. No Jira CLI or curl.

**Writable fixes:** `sfa-workspace-clone` worktrees under `workspace/` — never commit
inside `repos/`.

**Session repo required:** add `stolostron/server-foundation-agent` →
`/workspace/server-foundation-agent`. **Prompt Source alone does not clone the repo**
— scripts under `scripts/` and `build/scripts/` exist only when the repo is a session repo.

**GitHub App auth:** when `GH_APP_ID`, `GH_APP_INSTALLATION_ID`, and `GH_APP_PRIVATE_KEY`
are in `swarmer-agent-extra-env`, generate an Installation Access Token (IAT) using
scripts in this repo under `build/scripts/`. Do **not** attach a session GitHub PAT —
Swarmer-injected `GH_TOKEN` overrides App scripts. Run **Phase 2** before any `gh` command.

**Verification:** in the target worktree, run `make check` then `make test` when those
targets exist (read the repo `Makefile` first). Shell timeout **≥ 900000 ms** for
`make check` — lint can be silent for minutes while downloading tools.

**Branch:** `fix-ACM-<digits>` (autonomous mode auto-prefixes to `sfa/fix-ACM-<digits>`).

**Commits:** Conventional Commits + `Signed-off-by` + Co-authored-by trailer:

```
Co-authored-by: server-foundation-agent <sfa-bot@redhat.com>
```

**PR:** draft only (`gh pr create --draft`); then run
`scripts/ensure-sfa-assisted-label.sh <org/repo> <pr-number>` (label is not
pre-defined on most repos); footer:

```
---
*Created with [server-foundation-agent](https://github.com/stolostron/server-foundation-agent)*
```

Grooming reference: `docs/jira-issue-grooming.md`

## Prompt routing (read this first)

| Path | Exists? | Use |
|------|---------|-----|
| `prompts/jira-solve.md` | Yes | This file — issue key + solve entry |
| `prompts/jira-agent-pipeline.md` | Yes | **Phase 2** (GitHub auth) and **Phase 3** (solve steps 4–14) |
| `docs/jira-issue-grooming.md` | Yes | Grooming criteria only |
| `docs/jira-solve.md` | **No** | **Do not read — file does not exist** |
| `docs/jira/` | Yes | Jira API/JQL reference — not solve steps |

## Instructions

1. **Issue key**
   - Parse from `instruction_prompt` or user message
   - Format: `ACM-<digits>`
   - If missing, stop and report that a key is required
   - Record `issue_key` and summary in working notes

2. **GitHub authentication** — follow **Phase 2** in
   `prompts/jira-agent-pipeline.md` (same repository, path
   `/workspace/server-foundation-agent/prompts/jira-agent-pipeline.md`)

3. **Solve** — follow **Phase 3** steps 4–14 in `prompts/jira-agent-pipeline.md` for
   that `issue_key` (fetch issue → eligibility → prior PR check → implement → PR → Jira)

4. **Summary** — issue key, target repo, PR URL (or failure reason), `make check` /
   `make test` status, auth mode (app or pat)

## Do not

- Read `docs/jira-solve.md` — **file does not exist**
- Read `docs/jira/` for solve steps — API reference only
- Use Jira CLI or curl for Jira (GitHub API curl is OK when `GH_TOKEN` is set)
- Process more than one issue in this run
- Commit inside `repos/` or run `./repos/sync-repos.sh`
- Skip `make test` when the target exists
- Mark PR ready for review (draft only — human promotes after review)
- Attach a session GitHub PAT when `GH_APP_*` creds are configured
- Echo, print, or log `GH_TOKEN`, `GITHUB_TOKEN`, or `ghs_*` values
