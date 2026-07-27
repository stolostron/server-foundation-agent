---
name: sfa-slack-notify
description: "Send a Slack notification via Incoming Webhook. General-purpose skill for posting formatted messages to Slack channels. Trigger phrases: 'send to slack', 'notify slack', 'post to slack', 'slack notification', 'send slack message'. Converts Markdown content to Slack Block Kit format automatically."
---

# Slack Notification Skill

A general-purpose skill for sending formatted notifications to Slack via Incoming Webhooks. Converts Markdown content to Slack's Block Kit + mrkdwn format for readable, well-structured messages.

## When to Use This Skill

Use this skill when the user wants to:

- Send a report, summary, or notification to a Slack channel
- Post task completion results to Slack
- Share PR reports, build results, or other structured data on Slack
- Send any Markdown-formatted content to Slack

## Configuration

### Webhook URL

The webhook URL is read from the environment variable:

```
SLACK_WEBHOOK_URL
```

Before sending, always verify it is set:

```bash
[ -z "$SLACK_WEBHOOK_URL" ] && echo "ERROR: SLACK_WEBHOOK_URL is not set" && exit 1
```

If not set, ask the user to provide it or set the environment variable.

## Bundled Script

This skill includes a ready-to-use send script. **Do NOT write your own send script** — use the bundled one:

```
.claude/skills/sfa-slack-notify/send_to_slack.sh
```

Usage:
```bash
# From a JSON file:
bash .claude/skills/sfa-slack-notify/send_to_slack.sh payload.json

# From stdin:
echo "$payload_json" | bash .claude/skills/sfa-slack-notify/send_to_slack.sh
```

The script handles single payloads, arrays of payloads (multi-part), rate limiting, and retries.

## Execution Steps

### Step 1: Prepare the Content

Receive content from the caller (another skill, the user, or a task output).

### Step 2: Build Slack Block Kit JSON

Build the Block Kit JSON payload directly using `jq`. Follow the conversion rules and formatting guidelines below. **Do NOT generate intermediate Python/shell scripts** — construct the JSON in-place with `jq`.

### Step 3: Enforce Slack Limits

Check the generated blocks against Slack's limits. If they exceed limits, split into multiple payloads.

### Step 4: Send via Bundled Script

Save the JSON payload to a file and use the bundled `send_to_slack.sh` to send it:

```bash
bash .claude/skills/sfa-slack-notify/send_to_slack.sh payload.json
```

---

## Markdown → Slack Block Kit Conversion Rules

### Block-Level Mapping

Convert each Markdown structural element to the appropriate Slack block type:

| Markdown Element | Slack Block | Notes |
|-----------------|-------------|-------|
| `# Heading 1` | `header` block | Max 150 chars, `plain_text` only, strip formatting |
| `## Heading 2` – `###### Heading 6` | `section` block with bold text | `*Heading Text*` in mrkdwn |
| `---` (horizontal rule) | `divider` block | `{"type": "divider"}` |
| Paragraph text | `section` block | mrkdwn type |
| Code block (`` ``` ``) | `section` block | Wrap in `` ``` `` (no syntax highlighting in mrkdwn) |
| Blockquote (`>`) | `section` block | Prefix each line with `>` (same syntax) |
| Table | `section` block with code block | Convert to monospace ASCII table (see below) |

### Inline mrkdwn Conversion

Apply these transformations to all text content within blocks. **Order matters** — process in this sequence to avoid conflicts:

```
1. Escape special chars:  & → &amp;   < → &lt;   > → &gt;
   (skip > at line start for blockquotes, skip < > in link syntax)

2. Links:                 [text](url)        → <url|text>
3. Images:                ![alt](url)        → <url|alt>
4. Bold+Italic:           ***text***         → *_text_*
5. Bold:                  **text** or __text__ → *text*
6. Italic:                *text* or _text_    → _text_
   (careful: only convert *text* to _text_ if not already bold)
7. Strikethrough:         ~~text~~           → ~text~
8. Inline code:           `text`             → `text`  (same, no change)
```

**Important**: Process bold (`**`) before italic (`*`) to avoid misinterpreting `**bold**` as nested italics.

### Table Conversion

Slack mrkdwn does NOT support Markdown tables. Choose the right conversion based on content:

**CRITICAL**: Code blocks (`` ``` ``) in Slack render as **plain monospace text**. All mrkdwn formatting is disabled inside code blocks — links (`<url|text>`), bold (`*text*`), and emoji shortcodes do NOT render. Never put clickable links inside code blocks.

#### Option A: Bullet lists (preferred for content with links)

When table rows contain links, authors, or other content that needs mrkdwn formatting, convert to bullet lists:

**Input (Markdown):**
```
| PR | Repository | Author | Title | Age |
|----|------------|--------|-------|-----|
| [#123](url) | ocm | @alice | Fix bug | 5d |
| [#456](url) | api | @bob | Add feature | 2d |
```

**Output (Slack mrkdwn):**
```
• <url|#123> *ocm* — Fix bug · @alice · _5d_
• <url|#456> *api* — Add feature · @bob · _2d_
```

#### Option B: Code block table (only for plain text data)

When table content is purely plain text with no links or formatting, use a compact ASCII table:

```
Name   Status   Age
────   ──────   ───
PR-1   Open     5d
PR-2   Merged   2d
```

Rules for code block tables:
- Remove pipe (`|`) delimiters, use spacing for alignment
- Replace the separator row (`|------|`) with `────` Unicode box-drawing characters
- Keep total width under 60 characters for mobile readability

### Lists

Slack renders list prefixes (`-`, `*`, `1.`) as plain text. Keep them as-is:

```
- Item one
- Item two
  - Nested item (use 2-space indent)

1. First
2. Second
```

This renders acceptably in Slack even though they're not structured list elements.

---

## Slack Limits & Splitting Strategy

### Hard Limits

| Constraint | Limit |
|------------|-------|
| Blocks per message | **50** |
| Section block `text` | **3,000 chars** |
| Header block `text` | **150 chars** |
| Total blocks content | **~12,000 chars** (practical safe limit) |
| Rate limit | **1 message per second** per channel |
| Payload size | **~1 MB** |

### Pre-Send Validation

Before sending, validate every payload:

1. Count blocks — must be ≤ 50
2. Check each section block text — must be ≤ 3,000 chars
3. Check each header block text — must be ≤ 150 chars
4. Sum all text content across blocks — should be ≤ 10,000 chars (safe margin under ~12K practical limit)

### Splitting Strategy

If content exceeds limits, split into multiple messages:

1. **Split by sections**: Use `# Heading 1` boundaries as natural split points
2. **Each message is self-contained**: Start each split message with a header indicating continuation
3. **Add sequence indicator**: `(1/3)`, `(2/3)`, `(3/3)` appended to the first header
4. **Rate limit compliance**: Sleep 1 second between messages

**Splitting algorithm:**

```
blocks = convert_all_markdown_to_blocks(content)
payloads = []
current_payload = []
current_char_count = 0

for block in blocks:
    block_chars = count_chars(block)
    would_exceed = (
        len(current_payload) + 1 > 45  OR          # leave room for header
        current_char_count + block_chars > 9000     # safe margin
    )
    if would_exceed AND current_payload is not empty:
        payloads.append(current_payload)
        current_payload = []
        current_char_count = 0
    current_payload.append(block)
    current_char_count += block_chars

if current_payload:
    payloads.append(current_payload)
```

### Oversized Section Blocks

If a single section block exceeds 3,000 chars (e.g., a very long code block or table):

1. Split the text at a line boundary near the 2,800-char mark
2. Create multiple section blocks from the split content
3. If it's a code block, close the ``` before the split and reopen after

---

## Sending the Message

Use the bundled script — do NOT write your own curl logic:

```bash
# Single or multi-part payload:
bash .claude/skills/sfa-slack-notify/send_to_slack.sh payload.json
```

The script handles HTTP status codes, rate limiting (429), retries, and multi-part splitting automatically.

### Payload Construction

Build the JSON payload using `jq` to ensure proper escaping:

```bash
payload=$(jq -n \
  --arg text "$fallback_text" \
  --argjson blocks "$blocks_json" \
  '{text: $text, blocks: $blocks}')

echo "$payload" > payload.json
bash .claude/skills/sfa-slack-notify/send_to_slack.sh payload.json
```

**Critical**: Always use `jq` for JSON construction — never build JSON with string concatenation or `echo`. This prevents broken payloads from special characters in the content.

---

## Payload Structure Template

### Single Message

```json
{
  "text": "Plain-text fallback for notifications and accessibility",
  "blocks": [
    {
      "type": "header",
      "text": {
        "type": "plain_text",
        "text": "Report Title"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*Summary:* 35 open PRs\n*Health:* 20% fresh"
      }
    },
    {
      "type": "divider"
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*Section Heading*\n\nBody content with <https://github.com/org/repo/pull/1|#1> links..."
      }
    },
    {
      "type": "context",
      "elements": [
        {
          "type": "mrkdwn",
          "text": "Generated by server-foundation-agent | 2026-03-14"
        }
      ]
    }
  ]
}
```

### Block Type Quick Reference

| Block | When to Use | Key Constraint |
|-------|------------|----------------|
| `header` | `# H1` headings, report titles | 150 chars, plain_text only |
| `section` | Body text, lists, converted tables | 3,000 chars, mrkdwn |
| `divider` | `---` horizontal rules, visual separation | No text |
| `context` | Footers, timestamps, metadata | 10 elements max, small text |

---

## Fallback Text

Always include a meaningful top-level `text` field. This is the **only** thing shown in:
- Push notifications on mobile
- Desktop notification banners
- Screen readers

Generate it by extracting the report title and a one-line summary:

```
"Server Foundation Weekly PR Report — 2026-03-14: 35 open PRs, 7 ready to merge, 12 stale"
```

---

## Error Handling

| Scenario | Action |
|----------|--------|
| `SLACK_WEBHOOK_URL` not set | Stop, ask user to set the env var |
| HTTP 200 + body "ok" | Success |
| HTTP 400 `invalid_payload` | Log the payload, fix JSON structure, retry |
| HTTP 400 `invalid_blocks` | `send_to_slack.sh` strips `<!subteam^...>` mentions and retries once (Incoming Webhooks often reject user-group pings). If still failing, fix block structure / length — never replace with a hand-crafted text-only digest that drops PR URLs |
| HTTP 400 `msg_blocks_too_long` | Content too long — split and retry |
| HTTP 429 (rate limited) | Sleep for `Retry-After` seconds (default 2s), retry once |
| HTTP 403 | Webhook revoked or channel restricted — notify user |
| HTTP 404 `no_team` | Webhook URL is invalid — ask user to re-check |
| HTTP 5xx | Slack server error — retry once after 3 seconds |
| `curl` fails (no network) | Report network error to user |

---

## Integration with Other Skills

This skill is designed to be called **after** another skill generates content. Common patterns:

### Called by `weekly-pr-report`

```
User: "Generate weekly PR report and send to Slack"

1. weekly-pr-report skill generates the Markdown report
2. This skill converts it to Block Kit and sends it
```

### Called by any task

```
User: "Run X and notify Slack when done"

1. Execute task X
2. Format the result as Markdown
3. Call this skill to send the notification
```

### Standalone

```
User: "Send this message to Slack: ..."

1. Take the user's message
2. Convert and send
```

## Usage Notes

- The webhook URL is tied to a single Slack channel (configured in the Slack app)
- Messages cannot be edited or deleted after sending via webhook
- Webhooks do not return a message timestamp, so threading is not available
- Keep messages concise — Slack is for notifications, not full documents
- For very long reports, send a summary to Slack with a link to the full report
