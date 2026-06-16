# Weekly PR Report Workflow

Generate a categorized weekly report of all open human PRs on the Server Foundation project board.
The report helps the team identify merge-ready PRs, stale PRs, conflicts, and bottlenecks.

## Agent-swarm prompt

For [agent-swarm](https://github.com/stolostron/agent-swarm), use
`prompts/weekly-pr-report.md` instead of this document.

## Trigger Phrases

- `weekly PR report`, `PR health report`, `PR status report`
- `generate PR report`, `how are our PRs doing`

## Workflow Phases

```
Phase 1: Collect    →  Phase 2: Process    →  Phase 3: Report    →  Phase 4: Distribute
sfa-github-fetch-prs skill        filter & classify       generate Markdown       sfa-slack-notify
```

---

## Bundled Scripts

This workflow includes ready-to-use scripts. **Do NOT write your own processing scripts** — use the bundled ones:

```
workflows/weekly-pr-report/
├── process_prs.jq              # Phase 2: filter & classify
├── generate_report.py          # Phase 3: generate Markdown
└── generate_slack_payload.py   # Phase 4: generate Slack payload
```

---

## Phase 1: Collect PR Data

Use the `sfa-github-fetch-prs` skill with `all` detail level to get full PR lifecycle data.

This returns a JSON array. Save it to a temp file for Phase 2.

**Dependency**: `.claude/skills/sfa-github-fetch-prs/SKILL.md`

---

## Phase 2: Process & Classify

Run the bundled jq script to filter and classify PRs in a single pass:

```bash
mkdir -p .output
jq --argjson today_sec $(date +%s) -f workflows/weekly-pr-report/process_prs.jq <raw_prs.json> > .output/processed_prs.json
```

The script implements all the rules documented below. The reference rules are kept here for maintainability — if you need to change classification logic, update both the documentation below AND the `process_prs.jq` script.

### 2.1 Filter to Open Human PRs

From the JSON output, keep only PRs where:

- `content.state == "OPEN"`
- Author is NOT a bot

**Bot filter** — exclude PRs where `content.author.login` matches any of:

| Pattern | Match type |
|---------|------------|
| `red-hat-konflux` | exact |
| `dependabot` | exact |
| `renovate` | exact |
| any login ending with `[bot]` | suffix |
| any login ending with `-bot` | suffix |

### 2.2 Classify Each PR

Assign each open human PR to **exactly one** primary category. Evaluate rules **in order** — first match wins.

Extract these fields from each PR:

- **labels**: `[.labels[].name]` — array of label name strings
- **isDraft**: `.isDraft` — boolean
- **mergeable**: `.mergeable` — enum: `MERGEABLE`, `CONFLICTING`, or `UNKNOWN`
- **reviewDecision**: `.reviewDecision` — enum: `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or `null`
- **comments**: `.comments` — first 20 issue comments with author login (used for feedback detection)
- **updatedAt**: `.updatedAt` — ISO 8601 timestamp

Helper definitions for rules:

- **has label X**: the labels array contains the string X
- **has `approved`**: `reviewDecision == "APPROVED"` OR labels contain `approved`
- **has `lgtm`**: labels contain `lgtm`
- **has `do-not-merge/*`**: any label starts with `do-not-merge/`

#### Classification Rules (first match wins)

| # | Category | Criteria |
|---|----------|----------|
| 1 | **Ready to Merge** | has `approved` AND has `lgtm` AND NO `do-not-merge/*` labels AND `isDraft == false` AND `mergeable == "MERGEABLE"` |
| 2 | **Work In Progress** | `isDraft == true` OR has label `do-not-merge/work-in-progress` |
| 3 | **On Hold** | has label `do-not-merge/hold` |
| 4 | **Needs Rebase** | has label `needs-rebase` OR `mergeable == "CONFLICTING"` |
| 5 | **Approved, Needs LGTM** | has `approved` AND NOT has `lgtm` AND NO `do-not-merge/*` labels |
| 6 | **Needs Review** | catch-all for everything else |

### 2.3 Feedback Detection

For PRs classified as "Needs Review", detect whether non-author comments exist. This helps distinguish PRs that have received informal review feedback (via comments) from PRs that have had no reviewer engagement at all.

- **`feedback_count`**: Number of comments from users other than the PR author (from first 20 comments)
- **`has_feedback`**: `true` if `feedback_count > 0`

Reviewers sometimes leave feedback as regular PR comments instead of formal GitHub reviews. This indicator surfaces that activity so "Needs Review" PRs with existing discussion can be prioritized differently from completely unreviewed ones.

### 2.4 Compute Staleness

For every PR, compute days since `updatedAt` relative to today's date and assign a staleness bucket:

| Bucket | Days since last update |
|--------|------------------------|
| Fresh | 0–2 |
| Normal | 3–7 |
| Aging | 8–14 |
| Stale | 15–30 |
| Very Stale | 31–90 |
| Abandoned | 91+ |

---

## Phase 3: Generate Report

Run the bundled script to generate the Markdown report:

```bash
python3 workflows/weekly-pr-report/generate_report.py .output/processed_prs.json .output/weekly_pr_report.md
```

The script produces the report using the exact section order and format documented below.

### Report Template

```
# Server Foundation Weekly PR Report — {YYYY-MM-DD}

## Executive Summary

- **Total open human PRs:** {N}
- **By category:** Ready to Merge ({n}), Needs Review ({n}), Approved/Needs LGTM ({n}), WIP ({n}), On Hold ({n}), Needs Rebase ({n})
- **Staleness:** Fresh ({n}), Normal ({n}), Aging ({n}), Stale ({n}), Very Stale ({n}), Abandoned ({n})
- **Health score:** {percentage}% of PRs are Fresh or Normal

---

## Action Required: Ready to Merge

These PRs are approved, have LGTM, and are mergeable. They should be merged promptly.

| PR | Repository | Author | Title | Age (days) |
|----|------------|--------|-------|------------|
| [#123](url) | repo-name | @author | Title text | 5 |

> If empty: "No PRs are currently ready to merge."

---

## Action Required: Needs Review

These PRs have no approval or LGTM yet and need reviewer attention. The Feedback column shows 💬N if non-author comments exist, indicating informal review activity.

| PR | Repository | Author | Title | Days since update | Staleness | Feedback |
|----|------------|--------|-------|--------------------|-----------|----------|
| [#123](url) | repo-name | @author | Title text | 12 | Aging | 💬3 |
| [#456](url) | repo-name | @author | Title text | 5 | Normal | |

> Sort by days since update descending (stalest first).
> If empty: "All PRs have been reviewed."

---

## Approved, Needs LGTM

These PRs are approved but still need an LGTM label before they can merge.

| PR | Repository | Author | Title | Days since update |
|----|------------|--------|-------|--------------------|
| [#123](url) | repo-name | @author | Title text | 3 |

> If empty: "No PRs in this state."

---

## Work In Progress

Draft PRs or PRs with `do-not-merge/work-in-progress` label.

| PR | Repository | Author | Title | Days since update | Staleness |
|----|------------|--------|-------|--------------------|-----------|

> If empty: "No WIP PRs."

---

## On Hold

PRs with `do-not-merge/hold` label. These are intentionally paused.

| PR | Repository | Author | Title | Days since update |
|----|------------|--------|-------|--------------------|

> If empty: "No PRs on hold."

---

## Stale PR Alert

PRs that have not been updated in 15+ days, grouped by severity.

### Abandoned (91+ days)

| PR | Repository | Author | Title | Days since update |
|----|------------|--------|-------|--------------------|

### Very Stale (31–90 days)

| PR | Repository | Author | Title | Days since update |
|----|------------|--------|-------|--------------------|

### Stale (15–30 days)

| PR | Repository | Author | Title | Days since update |
|----|------------|--------|-------|--------------------|

> Only show sub-sections that have PRs. If no PRs are 15+ days stale: "No stale PRs — great job!"

---

## Conflict Alert

PRs with `mergeable == "CONFLICTING"` across ALL categories.

| PR | Repository | Author | Title | Category | Days since update |
|----|------------|--------|-------|----------|-------------------|

> If empty: "No PRs have merge conflicts."

---

## Per-Author Summary

| Author | Total | Ready | Needs Review | Approved/LGTM | WIP | On Hold | Rebase | Avg Days |
|--------|-------|-------|--------------|----------------|-----|---------|--------|----------|
| @author | 5 | 1 | 2 | 1 | 1 | 0 | 0 | 12 |

> Sort by Total descending.

---

## Per-Repository Summary

| Repository | Total | Ready | Needs Review | Approved/LGTM | WIP | On Hold | Rebase |
|------------|-------|-------|--------------|----------------|-----|---------|--------|
| org/repo | 8 | 2 | 3 | 1 | 1 | 0 | 1 |

> Sort by Total descending.
```

### Formatting Rules

1. **PR links**: Always format as `[#number](url)` — clickable Markdown links
2. **Author names**: Prefix with `@` (e.g., `@username`)
3. **Repository names**: Use short form `org/repo` from `repository.nameWithOwner`
4. **Dates**: Report date is today's date in `YYYY-MM-DD` format
5. **Days since update**: Integer, computed as `floor((today - updatedAt) / 86400)`
6. **Empty sections**: Always show the section header with the "If empty" message — never omit sections
7. **Sorting within tables**: Sort by days since update descending (stalest first) unless otherwise noted
8. **Health score**: `floor(100 * (fresh_count + normal_count) / total_count)`

---

## Phase 4: Distribute

Run the bundled script to generate the Slack payload, then send it:

```bash
python3 workflows/weekly-pr-report/generate_slack_payload.py .output/processed_prs.json .output/slack_payload.json
bash .claude/skills/sfa-slack-notify/send_to_slack.sh .output/slack_payload.json
```

**Dependencies**:
- `workflows/weekly-pr-report/generate_slack_payload.py`
- `.claude/skills/sfa-slack-notify/send_to_slack.sh`

### Slack Message Design Principles

1. **Concise** — Slack is for notifications, not full documents. Show highlights only.
2. **Scannable** — Use bold text for labels, emojis only for section headings.
3. **Actionable** — Prioritize PRs that need immediate attention.
4. **Limited** — Show at most **3 example PRs per category**. For each category, show the total count and representative examples.
5. **Clickable** — PR links must be in mrkdwn (`<url|#number>`) outside code blocks so they render as clickable links.

### PR Display Limits

| Category | Max PRs shown | Selection rule |
|----------|---------------|----------------|
| Ready to Merge | 3 | Show all if ≤3, otherwise newest first |
| Needs Review | 3 | Stalest first (most urgent) |
| Approved/LGTM | 3 | Stalest first |
| WIP | 0 | Count only |
| On Hold | 0 | Count only |
| Stale Alert | 3 | Oldest abandoned/very stale PRs |
| Conflict Alert | 3 | Stalest first |

If a category has more PRs than the display limit, append: `_...and {N} more_`

### Slack Message Template

The `generate_slack_payload.py` script builds the following Block Kit structure.

#### Emoji Conventions

Emojis are used **only** on section headings, not on summary line labels:

| Purpose | Emoji |
|---------|-------|
| Report title | 📊 |
| Ready to Merge heading | 🟢 |
| Needs Review heading | 👀 |
| Approved/Needs LGTM heading | ✅ |
| Stale Alert heading | 🕸️ |
| Conflict Alert heading | ⚠️ |
| Health score | ❤️ (<40%) or 💛 (40-59%) or 💚 (≥60%) |
| Abandoned PR marker | 💀 |
| Stale PR marker | 🕸️ |
| Has feedback (non-author comments) | 💬 |

Summary labels (Ready, Review, LGTM needed, WIP, Hold, Rebase) use **bold** text only, no emojis.

#### Message Structure

**Block 1 — Header** (`header` block, `plain_text`):
```
📊 Server Foundation Weekly PR Report — {YYYY-MM-DD}
```

**Block 2 — Executive Summary** (`section` block, `mrkdwn`):
```
*Summary:* {N} open PRs · {health_emoji} {pct}% healthy
*Ready:* {n}  ·  *Review:* {n}  ·  *LGTM needed:* {n}
*WIP:* {n}  ·  *Hold:* {n}  ·  *Rebase:* {n}
```

**Block 3 — Divider**

**Block 4 — Ready to Merge** (`section` block, `mrkdwn`):
```
*🟢 Ready to Merge ({n})*
• <url|#123> *repo* — Title · @author · _5d_
• <url|#456> *repo* — Title · @author · _2d_
• <url|#789> *repo* — Title · @author · _1d_
```
Or if empty: `*🟢 Ready to Merge (0)* — None right now`

**Block 5 — Divider**

**Block 6 — Needs Review** (`section` block, `mrkdwn`):
```
*👀 Needs Review ({n} · {m} has feedback)*
• <url|#789> *repo* — Title · @author · _12d_ 🕸️ 💬3
• <url|#101> *repo* — Title · @author · _8d_
• <url|#102> *repo* — Title · @author · _5d_ 💬1
_...and {remaining} more_
```

The heading shows how many PRs have non-author comment feedback. Each PR with feedback shows 💬N where N is the non-author comment count.

**Block 7 — Divider**

**Block 8 — Approved/Needs LGTM** (`section` block, `mrkdwn`):
```
*✅ Approved, Needs LGTM ({n})*
• <url|#111> *repo* — Title · @author · _3d_
_...and {remaining} more_
```

**Block 9 — Divider**

**Block 10 — Stale PR Alert** (`section` block, `mrkdwn`, only if stale PRs exist):
```
*🕸️ Stale PR Alert*
_{n1} abandoned · {n2} very stale · {n3} stale_
• <url|#222> *repo* — Title · @author · _934d_ 💀
• <url|#333> *repo* — Title · @author · _66d_ 🕸️
• <url|#444> *repo* — Title · @author · _20d_ 🕸️
```

**Block 11 — Divider** (only if conflicts exist)

**Block 12 — Conflict Alert** (`section` block, `mrkdwn`, only if conflicts exist):
```
*⚠️ Merge Conflicts ({n})*
• <url|#444> *repo* — Title · @author
_...and {remaining} more_
```

**Block 13 — Context** (`context` block):
```
Generated by server-foundation-agent · {YYYY-MM-DD}
```

#### PR Line Format

Each PR line follows this pattern:
```
• <{pr_url}|#{number}> *{short_repo}* — {title} · @{author} · _{days}d_
```

Where:
- `{short_repo}` — short repository name, e.g. `ocm`, `api`, `cluster-proxy` (drop the org prefix)
- `{title}` — truncate to 50 characters if longer, append `…`
- `_{days}d_` — days since last update, in italic

---

## Edge Cases

- **PR with null author**: Use `"unknown"` as author login. Treat as human (do not filter out).
- **PR with null `mergeable`**: Treat `UNKNOWN` or `null` as non-conflicting, non-mergeable. Such PRs cannot be "Ready to Merge" (rule 1 requires `MERGEABLE`) and will not trigger "Needs Rebase" (rule 4 requires `CONFLICTING`).
- **PR with null `reviewDecision`**: Treat as not approved — the PR has no review yet.
- **PR with null `updatedAt`**: Fall back to `createdAt` for staleness calculation.
- **Labels with 10+ labels**: The API returns at most 10 labels. Classification uses only what is returned.
- **PR matching multiple `do-not-merge/*` labels**: First-match-wins handles this — rule 2 (WIP) takes priority over rule 3 (Hold).
- **PR with null `comments`**: Treat as no comments — `feedback_count = 0`, `has_feedback = false`.
- **PR with 20+ comments**: Only the first 20 comments are fetched. Feedback count may be lower than actual, but presence detection is still accurate.

## Performance Notes

- The `sfa-github-fetch-prs` skill call may take a few seconds for the initial API call; subsequent calls use the 5-minute cache
- All filtering, classification, and aggregation should be done with `jq` in a single pass when possible
- Do NOT use `nocache` unless the user explicitly requests fresh data
