# ACM Agent PR Digest

Slack notification listing **open agent PRs** opened by the ACM fix agent
(`jira-agent-pipeline`, `jira-solve`, daily triage auto-fix). Identified by the
`sfa-assisted` label across SF stolostron repos:

- **Draft** — `isDraft == true` (awaiting mark ready)
- **Ready for review** — `isDraft == false` (awaiting review/merge)

## Agent-swarm prompt

For [agent-swarm](https://github.com/stolostron/agent-swarm), use
`prompts/draft-pr-digest.md` instead of this document.

## Trigger Phrases

- `draft PR digest`, `agent draft PRs`, `list sfa-assisted drafts`
- `acm-agent draft PRs`, `agent PR digest`, `notify me about agent PRs`

## Workflow Phases

```
Phase 1: GitHub auth  →  Phase 2: Collect    →  Phase 3: Filter    →  Phase 4: Slack payload    →  Phase 5: Send
App IAT / GH_TOKEN         fetch-prs (all)          jq filter              generate_slack_payload.py      send_to_slack.sh
```

## Bundled Scripts

```
workflows/draft-pr-digest/
├── filter_agent_draft_prs.jq      # Phase 3: sfa-assisted → draft + ready_for_review
└── generate_slack_payload.py      # Phase 4: Slack Block Kit JSON
```

## Phase 1: GitHub auth

Same as **Phase 1 (GitHub auth)** in `prompts/draft-pr-digest.md` — run Tier A/B/C from
`prompts/jira-agent-pipeline.md` Phase 2 before any `gh` calls. Requires
`swarmer-agent-extra-env` (`GH_APP_*`) or `GH_TOKEN`.

If auth fails, stop — do not use sample data.

## Phase 2: Collect open PRs

```bash
mkdir -p .output/draft-pr-digest
bash .claude/skills/sfa-github-fetch-prs/fetch-prs.sh all nocache \
  > .output/draft-pr-digest/raw_prs.json
```

Requires `gh` and `jq` authenticated. `yq` is optional (awk fallback parses
`repos/repos.yaml` when `yq` is absent — typical in agent-swarm pods).

## Phase 3: Filter agent PRs

```bash
jq -f workflows/draft-pr-digest/filter_agent_draft_prs.jq \
  .output/draft-pr-digest/raw_prs.json \
  > .output/draft-pr-digest/agent_prs.json
```

Criteria: label `sfa-assisted` present, then split by `isDraft`.

Output: `{ "draft": [...], "ready_for_review": [...] }` — oldest first in each list.

## Phase 4: Generate Slack payload

```bash
python3 workflows/draft-pr-digest/generate_slack_payload.py \
  .output/draft-pr-digest/agent_prs.json \
  .output/draft-pr-digest/slack_payload.json
```

Slack Block Kit output always includes **two list sections**:

| Section | Source key | Criteria |
|---------|------------|----------|
| Draft PRs | `draft` | `isDraft == true` |
| Ready for review | `ready_for_review` | `isDraft == false` |

Empty sections render as `_none_` — both headers always appear.

## Phase 5: Send Slack notification

```bash
bash .claude/skills/sfa-slack-notify/send_to_slack.sh \
  .output/draft-pr-digest/slack_payload.json
```

Requires `SLACK_WEBHOOK_URL`. Point the webhook at a DM or channel where you want
the digest delivered.

## Schedule (example)

| Session | Cron | Timezone |
|---------|------|----------|
| `acm-agent-draft-pr-digest` | `0 17 * * 1-5` | Asia/Shanghai (weekdays 17:00) |

## Edge Cases

- **Zero agent PRs in both groups:** still send Slack — confirms nothing is waiting
- **Missing `sfa-assisted` label:** PR is excluded (agent should add label per `docs/development-guide.md`)
- **Repo fetch failure:** `fetch-prs.sh` skips failed repos with a warning
