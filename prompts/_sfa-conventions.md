# SFA conventions (shared reference)

Embedded in workflow prompts under `prompts/`. **Agents should use inline
conventions in the active prompt** — not a separate read step.

If reading from disk (optional):

- `/workspace/server-foundation-agent/prompts/_sfa-conventions.md` (this file)

## Repository

| Path | GitHub |
|------|--------|
| `/workspace/server-foundation-agent` | `stolostron/server-foundation-agent` |

**Working directory:** repo root before `./repos/sync-repos.sh`, workflow scripts, or
`.output/` writes.

Agent-swarm default clone path: `/workspace/server-foundation-agent`.

### GitHub App auth (jira-agent-pipeline)

When `GH_APP_ID`, `GH_APP_INSTALLATION_ID`, and `GH_APP_PRIVATE_KEY` are in
`swarmer-agent-extra-env`, the agent generates IATs from scripts in the workspace
clone — no custom agent image required:

```bash
bash /workspace/server-foundation-agent/build/scripts/github-token-manager.sh
```

Requires `openssl`, `jq`, and `curl` in the agent pod. Build from
`agent-swarm/Containerfile.opencode` (OpenCode) or `Containerfile.crush` (Crush).
Do **not** attach a session GitHub PAT — Swarmer-injected `GH_TOKEN` overrides App auth.

See `prompts/jira-agent-pipeline.md` Phase 2.

## Jira (MCP preferred)

Use **Jira MCP tools** when available (`search_issues`, `get_issue`, `add_comment`,
`update_issue`). Do **not** use Jira CLI.

Script fallbacks (when MCP lacks comment access or posting fails) may use REST via
`JIRA_EMAIL` + `JIRA_API_TOKEN` — see `workflows/daily-bug-triage/*.py`.

**Host:** `https://redhat.atlassian.net`
**Project:** ACM
**Team component:** `Server Foundation`

### Daily bug triage label

After posting triage analysis, add label **`agent-triaged`** via MCP `update_issue` (or
REST fallback in `post_jira_comments.py`). Used for dedup in Phase 1.5 alongside
the triage comment signature.

### Jira fix-agent queue

Groomed issues for `jira-agent-pipeline`:

| Label | Meaning |
|-------|---------|
| `issue-for-agent` | Ready for automated fix (human-groomed) |
| `agent-processed` | Agent finished (success or abandoned after comment) |

**Queue JQL:**

```
project = ACM AND resolution = Unresolved AND status in (New, "To Do") AND component = "Server Foundation" AND labels = issue-for-agent AND labels != agent-processed ORDER BY created ASC
```

See `docs/jira-issue-grooming.md`.

**Solve prompts** (not under `docs/`): `prompts/jira-agent-pipeline.md`,
`prompts/jira-solve.md`. There is no `docs/jira-solve.md`.

## Code access

| Location | Use |
|----------|-----|
| `repos/` | Read-only reference clones (`./repos/sync-repos.sh`) |
| `workspace/` | Writable worktrees for fixes (`sfa-workspace-clone` skill) |

Never commit inside `repos/`.

## GitHub

- Use `gh` for PRs
- Draft PRs until a human marks ready
- Commits: conventional + `Signed-off-by`

## Slack

- `SLACK_WEBHOOK_URL` for notifications
- Helper: `.claude/skills/sfa-slack-notify/send_to_slack.sh`

## Automation footer

Daily bug triage Jira comments must end with:

```
_— server-foundation-agent (daily bug triage)_
```

and include `h3. Bug Triage Analysis` so dedup scripts recognize prior runs.
