#!/usr/bin/env python3
"""Phase 5: Generate Slack Block Kit payload from diagnosis results.

Usage:
    python3 workflows/weekly-bot-pr-report/generate_slack_payload.py <diagnoses_dir> <output_payload.json>

Input:  Directory containing pr-*.json diagnosis result files
Output: Slack Block Kit JSON payload file
"""
import json
import glob
import os
import sys
import datetime

# Max example PRs to show per category in Slack
MAX_EXAMPLES = 3

# Slack user group mention for Server Foundation team
SF_GROUP_MENTION = "<!subteam^S04N59L7UPR|acm-server-foundation>"


def escape_mrkdwn(text):
    """Escape Slack mrkdwn special characters."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def format_pr_line(d):
    """Format a single PR as a Slack mrkdwn bullet line."""
    title = escape_mrkdwn(d['title'])
    if len(title) > 50:
        title = title[:49] + "\u2026"
    short_repo = d.get('short_repo', d['repo'].split('/')[-1])
    return f"\u2022 <{d['url']}|#{d['pr_number']}> *{short_repo}* \u2014 {title} \u00b7 @{d['author']} \u00b7 _{d['age_days']}d_"


def load_diagnoses(diagnoses_dir):
    """Load all pr-*.json files from the diagnoses directory."""
    pattern = os.path.join(diagnoses_dir, "pr-*.json")
    results = []
    for path in sorted(glob.glob(pattern)):
        with open(path, 'r') as f:
            results.append(json.load(f))
    return results


def main():
    if len(sys.argv) < 3:
        print("Usage: generate_slack_payload.py <diagnoses_dir> <output.json>", file=sys.stderr)
        sys.exit(1)

    diagnoses_dir = sys.argv[1]
    output_file = sys.argv[2]

    diagnoses = load_diagnoses(diagnoses_dir)
    today = datetime.date.today().isoformat()
    total = len(diagnoses)

    # Group by action
    by_action = {}
    for d in diagnoses:
        by_action.setdefault(d["action"], []).append(d)

    n_merge = len(by_action.get("recommend-merge", []))
    n_patched = len(by_action.get("patched", []))
    n_retest = len(by_action.get("retest", []))
    n_manual = len(by_action.get("needs-manual", []))
    n_fork = len(by_action.get("skipped-fork", []))
    n_pending = len(by_action.get("pending", []))

    # Health: PRs that are resolved (merge + patched + retest) vs total
    n_resolved = n_merge + n_patched + n_retest
    health_pct = int((n_resolved / total) * 100) if total > 0 else 100

    if health_pct >= 60:
        health_emoji = "\U0001f49a"  # green heart
    elif health_pct >= 40:
        health_emoji = "\U0001f49b"  # yellow heart
    else:
        health_emoji = "\u2764\ufe0f"  # red heart

    fallback_text = (
        f"Server Foundation Weekly Bot PR Report \u2014 {today}: "
        f"{total} bot PRs, {n_merge} ready to merge, {n_patched} auto-patched, "
        f"{n_manual} needs manual"
    )

    blocks = [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": f"\U0001f916 Bot PR Report \u2014 {today}"
            }
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": (
                    f"{SF_GROUP_MENTION}\n"
                    f"*Summary:* {total} bot PRs \u00b7 {health_emoji} {health_pct}% resolved\n"
                    f"*Merge:* {n_merge}  \u00b7  *Patched:* {n_patched}  \u00b7  *Retest:* {n_retest}\n"
                    f"*Manual:* {n_manual}  \u00b7  *Fork:* {n_fork}  \u00b7  *Pending:* {n_pending}"
                )
            }
        },
        {"type": "divider"}
    ]

    # --- Recommend Merge ---
    merge_prs = sorted(by_action.get("recommend-merge", []), key=lambda x: x["age_days"])
    if merge_prs:
        text = f"*\U0001f7e2 Recommend Merge ({n_merge})*\n"
        text += "\n".join(format_pr_line(d) for d in merge_prs[:MAX_EXAMPLES])
        if n_merge > MAX_EXAMPLES:
            text += f"\n_...and {n_merge - MAX_EXAMPLES} more_"
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})
    else:
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": "*\U0001f7e2 Recommend Merge (0)* \u2014 None right now"}})

    blocks.append({"type": "divider"})

    # --- Auto-Patched ---
    patched_prs = sorted(by_action.get("patched", []), key=lambda x: x["repo"])
    if patched_prs:
        text = f"*\U0001f527 Auto-Patched ({n_patched})*\n"
        text += "\n".join(format_pr_line(d) for d in patched_prs[:MAX_EXAMPLES])
        if n_patched > MAX_EXAMPLES:
            text += f"\n_...and {n_patched - MAX_EXAMPLES} more_"
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})
        blocks.append({"type": "divider"})

    # --- Recommend Retest ---
    retest_prs = sorted(by_action.get("retest", []), key=lambda x: x["repo"])
    if retest_prs:
        text = f"*\U0001f504 Recommend Retest ({n_retest})*\n"
        text += "\n".join(format_pr_line(d) for d in retest_prs[:MAX_EXAMPLES])
        if n_retest > MAX_EXAMPLES:
            text += f"\n_...and {n_retest - MAX_EXAMPLES} more_"
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})
        blocks.append({"type": "divider"})

    # --- Needs Manual ---
    manual_prs = sorted(by_action.get("needs-manual", []), key=lambda x: x["repo"])
    if manual_prs:
        text = f"*\u26a0\ufe0f Needs Manual ({n_manual})*\n"
        text += "\n".join(format_pr_line(d) for d in manual_prs[:MAX_EXAMPLES])
        if n_manual > MAX_EXAMPLES:
            text += f"\n_...and {n_manual - MAX_EXAMPLES} more_"
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})

    # --- Context footer ---
    blocks.append({
        "type": "context",
        "elements": [
            {
                "type": "mrkdwn",
                "text": f"Generated by server-foundation-agent \u00b7 {today}"
            }
        ]
    })

    payload = {"text": fallback_text, "blocks": blocks}

    with open(output_file, 'w') as f:
        json.dump(payload, f, ensure_ascii=False)

    print(f"Slack payload written to {output_file}", file=sys.stderr)


if __name__ == '__main__':
    main()
