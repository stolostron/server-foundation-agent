#!/usr/bin/env python3
"""Generate Slack Block Kit payload for ACM agent PR digest (draft + ready).

Usage:
    python3 workflows/draft-pr-digest/generate_slack_payload.py <agent_prs.json> <output_payload.json>

Input:  Filtered PR JSON (output of filter_agent_draft_prs.jq)
Output: Slack Block Kit JSON payload file
"""
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from slack_blocks import (
    JIRA_BROWSE_BASE,
    SF_GROUP_MENTION,
    agent_footer_block,
    divider_block,
    escape_mrkdwn,
    header_block,
    section_mrkdwn,
    today_iso,
    truncate,
)


def _days_since(iso_ts: str) -> int:
    if not iso_ts:
        return 0
    ts = iso_ts.replace("Z", "+00:00")
    updated = datetime.fromisoformat(ts)
    if updated.tzinfo is None:
        updated = updated.replace(tzinfo=timezone.utc)
    delta = datetime.now(timezone.utc) - updated
    return max(0, delta.days)


def _jira_key(pr: dict) -> str | None:
    for text in (pr.get("title", ""), pr.get("branch", "")):
        match = re.search(r"ACM-\d+", text)
        if match:
            return match.group(0)
    return None


def _format_pr_line(pr: dict) -> str:
    title = truncate(escape_mrkdwn(pr.get("title", "")), 55)
    repo = escape_mrkdwn(pr.get("repo", "unknown"))
    days = _days_since(pr.get("updatedAt", ""))
    author = escape_mrkdwn(pr.get("author", "unknown"))
    jira = _jira_key(pr)
    jira_part = f" · <{JIRA_BROWSE_BASE}/{jira}|{jira}>" if jira else ""
    return (
        f"\u2022 <{pr['url']}|#{pr['number']}> *{repo}* \u2014 {title}"
        f"{jira_part} \u00b7 @{author} \u00b7 _{days}d since update_"
    )


def _section_body(title: str, count: int, prs: list[dict]) -> str:
    """Always emit a named list section (use _none_ when empty)."""
    header = f"*{title}* ({count})"
    if not prs:
        return f"{header}\n_none_"
    return header + "\n" + "\n".join(_format_pr_line(pr) for pr in prs)


def _load_prs(path: str) -> tuple[list[dict], list[dict]]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, list):
        # Legacy single-list format (draft only)
        return data, []
    return data.get("draft", []), data.get("ready_for_review", [])


def main() -> None:
    if len(sys.argv) < 3:
        print(
            "Usage: generate_slack_payload.py <agent_prs.json> <output.json>",
            file=sys.stderr,
        )
        sys.exit(1)

    draft_prs, ready_prs = _load_prs(sys.argv[1])
    today = today_iso()
    n_draft = len(draft_prs)
    n_ready = len(ready_prs)
    n_total = n_draft + n_ready
    mention = SF_GROUP_MENTION

    if n_total == 0:
        summary = "*No open agent PRs* with label `sfa-assisted` (draft or ready for review)."
    else:
        parts = []
        if n_draft:
            parts.append(f"{n_draft} draft")
        if n_ready:
            parts.append(f"{n_ready} ready for review")
        summary = f"*{n_total} open agent PR{'s' if n_total != 1 else ''}* (`sfa-assisted`): " + ", ".join(parts) + "."

    blocks: list[dict] = [
        header_block(f"ACM Agent PRs \u2014 {today}"),
        section_mrkdwn(f"{mention}\n{summary}"),
        divider_block(),
        section_mrkdwn(_section_body("Draft PRs", n_draft, draft_prs)),
        divider_block(),
        section_mrkdwn(_section_body("Ready for review", n_ready, ready_prs)),
    ]

    if n_total:
        blocks.append(
            section_mrkdwn(
                "_Draft: mark ready after validation. Ready: review and merge. "
                "Search: `label:sfa-assisted is:open org:stolostron`_"
            )
        )

    blocks.append(agent_footer_block(today))

    payload = {"blocks": blocks}
    with open(sys.argv[2], "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)

    print(
        f"Wrote Slack payload ({n_draft} draft, {n_ready} ready) to {sys.argv[2]}"
    )


if __name__ == "__main__":
    main()
