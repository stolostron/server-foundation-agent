#!/usr/bin/env python3
"""Phase 4: Generate Slack Block Kit payload for the PR report.

Usage:
    python3 workflows/weekly-pr-report/generate_slack_payload.py <processed_prs.json> <output_payload.json>

Input:  Processed PR JSON (output of process_prs.jq)
Output: Slack Block Kit JSON payload file
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from slack_blocks import (
    SF_GROUP_MENTION,
    agent_footer_block,
    escape_mrkdwn,
    health_emoji,
    today_iso,
    truncate,
)

# Max example PRs to show per category
MAX_EXAMPLES = 3


def format_pr_line(pr, show_stale_emoji=False, show_feedback=False):
    """Format a single PR as a Slack mrkdwn bullet line."""
    title = truncate(escape_mrkdwn(pr['title']), 50)
    stale_emoji = ""
    if show_stale_emoji:
        if pr['staleness'] == 'Abandoned':
            stale_emoji = " \U0001f480"
        elif pr['staleness'] in ['Stale', 'Very Stale', 'Aging']:
            stale_emoji = " \U0001f578\ufe0f"
    feedback_marker = ""
    if show_feedback and pr.get('has_feedback'):
        feedback_marker = f" \U0001f4ac{pr.get('feedback_count', 0)}"
    return f"\u2022 <{pr['url']}|#{pr['number']}> *{pr['repo']}* \u2014 {title} \u00b7 @{pr['author']} \u00b7 _{pr['days']}d_{stale_emoji}{feedback_marker}"


def main():
    if len(sys.argv) < 3:
        print("Usage: generate_slack_payload.py <processed_prs.json> <output.json>", file=sys.stderr)
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2]

    with open(input_file, 'r') as f:
        prs = json.load(f)

    today = today_iso()
    total = len(prs)

    categories = {
        "Ready to Merge": [],
        "Needs Review": [],
        "Approved, Needs LGTM": [],
        "Work In Progress": [],
        "On Hold": [],
        "Needs Rebase": []
    }

    staleness = {
        "Fresh": [], "Normal": [], "Aging": [],
        "Stale": [], "Very Stale": [], "Abandoned": []
    }

    conflicts = []

    for pr in prs:
        categories[pr["category"]].append(pr)
        staleness[pr["staleness"]].append(pr)
        if pr["mergeable"] == "CONFLICTING":
            conflicts.append(pr)

    fresh_normal = len(staleness["Fresh"]) + len(staleness["Normal"])
    health_pct = int((fresh_normal / total) * 100) if total > 0 else 100

    health_icon = health_emoji(health_pct)

    n_ready = len(categories['Ready to Merge'])
    n_review = len(categories['Needs Review'])
    n_lgtm = len(categories['Approved, Needs LGTM'])
    n_wip = len(categories['Work In Progress'])
    n_hold = len(categories['On Hold'])
    n_rebase = len(categories['Needs Rebase'])
    n_stale = len(staleness['Stale']) + len(staleness['Very Stale']) + len(staleness['Abandoned'])

    fallback_text = f"Server Foundation Weekly PR Report \u2014 {today}: {total} open PRs, {n_ready} ready to merge, {n_stale} stale"

    blocks = [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": f"\U0001f4ca Server Foundation Weekly PR Report \u2014 {today}"
            }
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": (
                    f"{SF_GROUP_MENTION}\n"
                    f"*Summary:* {total} open PRs \u00b7 {health_icon} {health_pct}% healthy\n"
                    f"*Ready:* {n_ready}  \u00b7  *Review:* {n_review}  \u00b7  *LGTM needed:* {n_lgtm}\n"
                    f"*WIP:* {n_wip}  \u00b7  *Hold:* {n_hold}  \u00b7  *Rebase:* {n_rebase}"
                )
            }
        },
        {"type": "divider"}
    ]

    # Ready to Merge
    ready_prs = sorted(categories['Ready to Merge'], key=lambda x: x['days'])
    if ready_prs:
        text = f"*\U0001f7e2 Ready to Merge ({n_ready})*\n"
        text += "\n".join([format_pr_line(pr) for pr in ready_prs[:MAX_EXAMPLES]])
        if n_ready > MAX_EXAMPLES:
            text += f"\n_...and {n_ready - MAX_EXAMPLES} more_"
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})
    else:
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": "*\U0001f7e2 Ready to Merge (0)* \u2014 None right now"}})

    blocks.append({"type": "divider"})

    # Needs Review (stalest first)
    review_prs = sorted(categories['Needs Review'], key=lambda x: x['days'], reverse=True)
    if review_prs:
        n_with_feedback = sum(1 for pr in review_prs if pr.get('has_feedback'))
        feedback_note = f" · {n_with_feedback} has feedback" if n_with_feedback > 0 else ""
        text = f"*\U0001f440 Needs Review ({n_review}{feedback_note})*\n"
        text += "\n".join([format_pr_line(pr, True, True) for pr in review_prs[:MAX_EXAMPLES]])
        if n_review > MAX_EXAMPLES:
            text += f"\n_...and {n_review - MAX_EXAMPLES} more_"
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})
        blocks.append({"type": "divider"})

    # Approved, Needs LGTM (stalest first)
    lgtm_prs = sorted(categories['Approved, Needs LGTM'], key=lambda x: x['days'], reverse=True)
    if lgtm_prs:
        text = f"*\u2705 Approved, Needs LGTM ({n_lgtm})*\n"
        text += "\n".join([format_pr_line(pr, True) for pr in lgtm_prs[:MAX_EXAMPLES]])
        if n_lgtm > MAX_EXAMPLES:
            text += f"\n_...and {n_lgtm - MAX_EXAMPLES} more_"
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})
        blocks.append({"type": "divider"})

    # Stale Alert (oldest first)
    stale_prs = sorted(
        staleness['Abandoned'] + staleness['Very Stale'] + staleness['Stale'],
        key=lambda x: x['days'], reverse=True
    )
    if stale_prs:
        text = (
            f"*\U0001f578\ufe0f Stale PR Alert*\n"
            f"_{len(staleness['Abandoned'])} abandoned \u00b7 {len(staleness['Very Stale'])} very stale \u00b7 {len(staleness['Stale'])} stale_\n"
        )
        text += "\n".join([format_pr_line(pr, True) for pr in stale_prs[:MAX_EXAMPLES]])
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})
        if conflicts:
            blocks.append({"type": "divider"})

    # Conflict Alert (stalest first)
    if conflicts:
        conflict_prs = sorted(conflicts, key=lambda x: x['days'], reverse=True)
        text = f"*\u26a0\ufe0f Merge Conflicts ({len(conflicts)})*\n"
        text += "\n".join([format_pr_line(pr) for pr in conflict_prs[:MAX_EXAMPLES]])
        if len(conflict_prs) > MAX_EXAMPLES:
            text += f"\n_...and {len(conflict_prs) - MAX_EXAMPLES} more_"
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})

    blocks.append(agent_footer_block(today))

    payload = {"text": fallback_text, "blocks": blocks}

    with open(output_file, 'w') as f:
        json.dump(payload, f, ensure_ascii=False)

    print(f"Slack payload written to {output_file}")


if __name__ == '__main__':
    main()
