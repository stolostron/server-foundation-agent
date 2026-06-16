# ACM agent PR digest (agent-swarm)

Send a **Slack notification** listing open **agent PRs** across SF stolostron repos:
**drafts** awaiting mark-ready and **ready-for-review** (non-draft) PRs the ACM fix
agent opened. Designed for **non-interactive** scheduled runs.

Detailed reference: `workflows/draft-pr-digest.md`.

## SFA conventions

**Working directory:** `/workspace/server-foundation-agent`

| Path | Repository |
|------|------------|
| `/workspace/server-foundation-agent` | `stolostron/server-foundation-agent` (**session repo required**) |

**Session repo required** — Prompt Source alone does not clone `build/scripts/` or
`scripts/setup-github-app-auth.sh`.

**GitHub App creds:** secret `swarmer-agent-extra-env` in the workspace namespace
(`GH_APP_ID`, `GH_APP_INSTALLATION_ID`, `GH_APP_PRIVATE_KEY`). Swarmer mounts via
`envFrom`. Do **not** attach a session GitHub PAT unless App creds are unavailable —
Swarmer-injected `GH_TOKEN` from a PAT overrides App scripts.

**Slack:** `SLACK_WEBHOOK_URL` + `bash .claude/skills/sfa-slack-notify/send_to_slack.sh`

**Output dir:** `.output/draft-pr-digest/`

## What counts as an agent PR

Open PRs with label `sfa-assisted` **or** author `acm-agent` / `app/acm-agent` (SFA /
ACM agent footprint per `docs/development-guide.md`), split into two groups:

| Group | Criteria |
|-------|----------|
| **Draft** | `isDraft == true` — agent opened as draft; needs mark-ready + review |
| **Ready for review** | `isDraft == false` — marked ready (or never draft); needs human review/merge |

Queried across all `repos/repos.yaml` → `server-foundation.stolostron` repos via
`fetch-prs.sh`.

## Workflow

```
GitHub auth → Collect → Filter → Slack payload → Send
```

### Phase 1: GitHub auth (required — run before fetch)

Run in the **same shell** used for `fetch-prs.sh`. Full steps: **Phase 2** in
`prompts/jira-agent-pipeline.md` (Tier A → B → C, then verify).

Quick path when session repo is at `/workspace/server-foundation-agent`:

```bash
cd /workspace/server-foundation-agent

# Tier A — setup script
if [ -f scripts/setup-github-app-auth.sh ]; then
  # shellcheck source=/dev/null
  source "$(bash scripts/setup-github-app-auth.sh --export)"
fi

# Tier B — token manager
if [ -z "${GH_TOKEN:-}" ] && [ -f build/scripts/github-token-manager.sh ]; then
  # shellcheck source=/dev/null
  source "$(bash build/scripts/github-token-manager.sh --env-file)"
fi

# Tier C + verify — see jira-agent-pipeline.md Phase 2 if still no GH_TOKEN
```

**Verify** (App tokens cannot call `GET /user` — that 403 is expected):

```bash
if [ -n "${GH_APP_ID:-}" ]; then
  gh api repos/stolostron/server-foundation-agent -q .full_name
elif gh api user -q .login; then
  true
else
  echo "github-auth: FAILED" >&2
  exit 1
fi
export GITHUB_TOKEN="${GH_TOKEN:-}"
```

**If auth fails:** stop immediately. Report which tiers were tried and which env vars
are missing (`GH_APP_*` or `GH_TOKEN`). Do **not** continue with unauthenticated `gh`.
Do **not** invent, mock, or sample PR data.

Optional: if `SLACK_WEBHOOK_URL` is set and not `SKIP_SLACK`, send a one-line Slack
error (Block Kit) stating GitHub auth failed — then exit.

### Phase 2: Collect open PRs

```bash
mkdir -p .output/draft-pr-digest
bash .claude/skills/sfa-github-fetch-prs/fetch-prs.sh all nocache \
  > .output/draft-pr-digest/raw_prs.json
```

Requires authenticated `gh` in the same shell. **`yq` is not required** — awk
fallback parses `repos/repos.yaml` when `yq` is missing.

Validate output is a JSON array (not an error string):

```bash
jq -e 'type == "array"' .output/draft-pr-digest/raw_prs.json >/dev/null
```

### Phase 3: Filter agent PRs

```bash
jq -f workflows/draft-pr-digest/filter_agent_draft_prs.jq \
  .output/draft-pr-digest/raw_prs.json \
  > .output/draft-pr-digest/agent_prs.json
```

Output shape: `{ "draft": [...], "ready_for_review": [...] }` (oldest first in each).

### Phase 4: Generate Slack payload

```bash
python3 workflows/draft-pr-digest/generate_slack_payload.py \
  .output/draft-pr-digest/agent_prs.json \
  .output/draft-pr-digest/slack_payload.json
```

The Slack message **must have two separate lists** (always both sections):

1. **Draft PRs** — `isDraft == true`, label `sfa-assisted`
2. **Ready for review** — `isDraft == false`, label `sfa-assisted`

Use the bundled script above — do not hand-build a single combined list. Empty
sections show `_none_`.

### Phase 5: Send Slack

```bash
bash .claude/skills/sfa-slack-notify/send_to_slack.sh \
  .output/draft-pr-digest/slack_payload.json
```

Skip Phase 5 only when `instruction_prompt` contains `SKIP_SLACK` or
`SLACK_WEBHOOK_URL` is unset — log a warning in the final summary.

**Always send** when the webhook is set and GitHub auth succeeded, even when both
lists are empty (confirms nothing is waiting).

## Final summary

Report to session logs:

- GitHub auth method used (App IAT vs PAT)
- Total open PRs fetched vs agent draft count vs ready-for-review count
- URLs for each group (or "none")
- Slack send status

## instruction_prompt overrides

| Text | Effect |
|------|--------|
| `SKIP_SLACK` | Build payload but do not post to Slack |

## Schedule (example)

| Agent-swarm session | Cron | Timezone |
|---------------------|------|----------|
| `acm-agent-draft-pr-digest` | `0 17 * * 1-5` | Asia/Shanghai |

## Do not

- Ask the user for confirmation (automated mode)
- Run `gh auth login` interactively
- Install packages (`apt-get`, `yum`, curl binaries) — `yq` is **not** required
- Use mock, sample, or fabricated PR data when auth or fetch fails
- Merge PRs or remove draft status
- Modify PR labels or Jira issues
