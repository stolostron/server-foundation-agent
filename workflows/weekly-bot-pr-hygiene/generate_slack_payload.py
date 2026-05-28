#!/usr/bin/env python3
"""Phase 5: Generate Slack Block Kit payload from diagnosis results.

Usage:
    python3 workflows/weekly-bot-pr-hygiene/generate_slack_payload.py <diagnoses_dir> <output_payload.json>

Input:  Directory containing pr-*.json diagnosis result files
Output: Slack Block Kit JSON payload file
"""
import json
import glob
import os
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


def format_pr_line(d):
    """Format a single PR as a Slack mrkdwn bullet line."""
    title = truncate(escape_mrkdwn(d['title']), 50)
    short_repo = d.get('short_repo', d['repo'].split('/')[-1])
    return f"\u2022 <{d['url']}|#{d['pr_number']}> *{short_repo}* \u2014 {title} \u00b7 @{d['author']} \u00b7 _{d['age_days']}d_"


# Friendly display names for failure pattern IDs
PATTERN_NAMES = {
    "go-version-mismatch": "Go Version Mismatch",
    "e2e-cluster-pool": "E2E Cluster Pool",
    "build-failure": "Build Failure",
    "sonarcloud": "SonarCloud Code Analysis",
    "none": "No pattern",
    "unknown": "Unknown",
}


def format_patched_pr(d):
    """Format an auto-patched PR with pattern and fix details."""
    line = format_pr_line(d)
    pattern = PATTERN_NAMES.get(d.get('pattern_matched', ''), d.get('pattern_matched', ''))
    details = escape_mrkdwn(d.get('action_details', ''))
    line += f"\n     _Pattern:_ `{pattern}` \u2014 {details}"
    return line


def format_manual_pr(d):
    """Format a needs-manual PR with diagnosis details and failed checks."""
    line = format_pr_line(d)
    failed = d.get('failed_checks', [])
    details = escape_mrkdwn(d.get('action_details', ''))
    if failed:
        checks_str = ", ".join(f"`{c}`" for c in failed)
        line += f"\n     _Failed:_ {checks_str}"
    if details:
        line += f"\n     _Reason:_ {details}"
    return line


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
    today = today_iso()
    total = len(diagnoses)

    # Group by action
    by_action = {}
    for d in diagnoses:
        by_action.setdefault(d["action"], []).append(d)

    n_merge = len(by_action.get("recommend-merge", []))
    n_fix = len(by_action.get("needs-fix", []))
    n_retest = len(by_action.get("retest", []))
    n_manual = len(by_action.get("needs-manual", []))
    n_fork = len(by_action.get("skipped-fork", []))
    n_pending = len(by_action.get("pending", []))

    # Health: PRs that are resolved (merge + retest) vs total
    n_resolved = n_merge + n_retest
    health_pct = int((n_resolved / total) * 100) if total > 0 else 100

    health_icon = health_emoji(health_pct)

    fallback_text = (
        f"Server Foundation Weekly Bot PR Hygiene \u2014 {today}: "
        f"{total} bot PRs, {n_merge} ready to merge, {n_fix} needs fix, "
        f"{n_manual} needs manual"
    )

    blocks = [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": f"\U0001f916 Bot PR Hygiene \u2014 {today}"
            }
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": (
                    f"{SF_GROUP_MENTION}\n"
                    f"*Summary:* {total} bot PRs \u00b7 {health_icon} {health_pct}% resolved\n"
                    f"*Merge:* {n_merge}  \u00b7  *Fix:* {n_fix}  \u00b7  *Retest:* {n_retest}\n"
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
        text += "\n".join(format_pr_line(d) for d in merge_prs)
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})
    else:
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": "*\U0001f7e2 Recommend Merge (0)* \u2014 None right now"}})

    blocks.append({"type": "divider"})

    # --- Needs Fix ---
    fix_prs = sorted(by_action.get("needs-fix", []), key=lambda x: x["repo"])
    if fix_prs:
        text = f"*\U0001f527 Needs Fix ({n_fix})*\n"
        text += "\n".join(format_patched_pr(d) for d in fix_prs)
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})
        blocks.append({"type": "divider"})

    # --- Recommend Retest ---
    retest_prs = sorted(by_action.get("retest", []), key=lambda x: x["repo"])
    if retest_prs:
        text = f"*\U0001f504 Recommend Retest ({n_retest})*\n"
        text += "\n".join(format_pr_line(d) for d in retest_prs)
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})
        blocks.append({"type": "divider"})

    # --- Needs Manual ---
    manual_prs = sorted(by_action.get("needs-manual", []), key=lambda x: x["repo"])
    if manual_prs:
        text = f"*\u26a0\ufe0f Needs Manual ({n_manual})*\n"
        text += "\n".join(format_manual_pr(d) for d in manual_prs)
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})

    # --- Context footer ---
    blocks.append(agent_footer_block(today))

    payload = {"text": fallback_text, "blocks": blocks}

    with open(output_file, 'w') as f:
        json.dump(payload, f, ensure_ascii=False)

    print(f"Slack payload written to {output_file}", file=sys.stderr)


if __name__ == '__main__':
    main()
