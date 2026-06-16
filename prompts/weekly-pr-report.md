# SF weekly PR report (agent-swarm)

Generate the **Server Foundation Weekly PR Report**: classify all open **human**
PRs across SF stolostron repos, write a Markdown report, and post a Slack summary.
Designed for **non-interactive** scheduled runs (Monday morning cron).

Detailed reference: `workflows/weekly-pr-report.md`.

## SFA conventions

**Working directory:** `/workspace/server-foundation-agent`

| Path | Repository |
|------|------------|
| `/workspace/server-foundation-agent` | `stolostron/server-foundation-agent` (**session repo required**) |

**Session repo required** — bundled scripts live under `workflows/weekly-pr-report/`.
Prompt Source alone does not clone them.

**GitHub App creds:** secret `swarmer-agent-extra-env` (`GH_APP_ID`,
`GH_APP_INSTALLATION_ID`, `GH_APP_PRIVATE_KEY`). Do **not** attach a session PAT when
App creds are configured.

**Slack:** `SLACK_WEBHOOK_URL` + `bash .claude/skills/sfa-slack-notify/send_to_slack.sh`

**Output dir:** `.output/weekly-pr-report/`

## Scope

- **Repos:** all `repos/repos.yaml` → `server-foundation.stolostron` (via `fetch-prs.sh`)
- **PRs included:** open, **human** authors (bots/Konflux/dependabot excluded — see
  `process_prs.jq`)
- **Categories:** Ready to Merge, Needs Review, Approved/Needs LGTM, WIP, On Hold,
  Needs Rebase, plus staleness and conflict alerts

## Workflow

```
GitHub auth → Collect → Classify → Markdown report → Slack payload → Send
```

### Phase 1: GitHub auth (required — run before fetch)

Same shell as `fetch-prs.sh`. Full steps: **Phase 2** in
`prompts/jira-agent-pipeline.md` (Tier A → B → C, then verify).

```bash
cd /workspace/server-foundation-agent

if [ -f scripts/setup-github-app-auth.sh ]; then
  # shellcheck source=/dev/null
  source "$(bash scripts/setup-github-app-auth.sh --export)"
fi
if [ -z "${GH_TOKEN:-}" ] && [ -f build/scripts/github-token-manager.sh ]; then
  # shellcheck source=/dev/null
  source "$(bash build/scripts/github-token-manager.sh --env-file)"
fi
export GITHUB_TOKEN="${GH_TOKEN:-}"
```

Verify (App token 403 on `GET /user` is expected):

```bash
if [ -n "${GH_APP_ID:-}" ]; then
  gh api repos/stolostron/server-foundation-agent -q .full_name
elif gh api user -q .login; then
  true
else
  echo "github-auth: FAILED" >&2
  exit 1
fi
```

If auth fails: stop. Do **not** fabricate PR data.

### Phase 2: Collect open PRs

```bash
mkdir -p .output/weekly-pr-report

# Default: use fetch-prs cache (5 min). Add nocache only when instruction_prompt has FORCE_REFRESH.
bash .claude/skills/sfa-github-fetch-prs/fetch-prs.sh all \
  > .output/weekly-pr-report/raw_prs.json
# With FORCE_REFRESH: append "nocache" as second arg

jq -e 'type == "array"' .output/weekly-pr-report/raw_prs.json >/dev/null
```

**`yq` is not required** — `fetch-prs.sh` uses awk fallback when `yq` is missing.

### Phase 3: Classify

Use the **bundled** jq script — do not hand-classify or write custom filters:

```bash
jq --argjson today_sec "$(date +%s)" \
  -f workflows/weekly-pr-report/process_prs.jq \
  .output/weekly-pr-report/raw_prs.json \
  > .output/weekly-pr-report/processed_prs.json
```

### Phase 4: Markdown report

```bash
python3 workflows/weekly-pr-report/generate_report.py \
  .output/weekly-pr-report/processed_prs.json \
  .output/weekly-pr-report/weekly_pr_report.md
```

Do **not** rewrite the report by hand — use the script output as the deliverable.

### Phase 5: Slack payload

```bash
python3 workflows/weekly-pr-report/generate_slack_payload.py \
  .output/weekly-pr-report/processed_prs.json \
  .output/weekly-pr-report/slack_payload.json
```

### Phase 6: Send Slack

```bash
bash .claude/skills/sfa-slack-notify/send_to_slack.sh \
  .output/weekly-pr-report/slack_payload.json
```

Skip Phase 6 when `instruction_prompt` contains `SKIP_SLACK` or `SLACK_WEBHOOK_URL`
is unset — log a warning in the final summary.

**Always send** Slack when the webhook is set and auth succeeded (even if zero open
human PRs).

## Final summary

Report to session logs:

- GitHub auth method (App IAT vs PAT)
- Total open PRs fetched vs open human PRs after filter
- Counts by category (Ready, Review, LGTM, WIP, Hold, Rebase)
- Health score / stale / conflict highlights from the report
- Paths: `weekly_pr_report.md`, Slack send status

## instruction_prompt overrides

| Text | Effect |
|------|--------|
| `SKIP_SLACK` | Generate Markdown only; skip Phase 6 |
| `FORCE_REFRESH` | Pass `nocache` to `fetch-prs.sh` |

## Schedule (example)

| Agent-swarm session | Cron | Timezone |
|---------------------|------|----------|
| `sfa-weekly-pr-report` | `0 6 * * 1` | Asia/Shanghai (Mon 06:00) |

## Do not

- Ask the user for confirmation (automated mode)
- Run `gh auth login` interactively
- Install packages — `yq` is **not** required
- Hand-build classification, Markdown tables, or Slack Block Kit JSON
- Use mock or sample PR data when auth or fetch fails
- Modify PRs, labels, or merge anything
