#!/usr/bin/env python3
"""
Format Jira inbox analysis as markdown.
"""

import argparse
import json
import sys
from datetime import datetime


def parse_args():
    parser = argparse.ArgumentParser(description="Format inbox analysis as markdown")
    parser.add_argument("--input", required=True, help="Input JSON file from analyze-inbox.py")
    return parser.parse_args()


def format_date(iso_date: str) -> str:
    """Format ISO date as relative time."""
    try:
        dt = datetime.fromisoformat(iso_date.replace('Z', '+00:00'))
        now = datetime.now(dt.tzinfo)
        delta = now - dt

        if delta.days == 0:
            if delta.seconds < 3600:
                return f"{delta.seconds // 60}m ago"
            else:
                return f"{delta.seconds // 3600}h ago"
        elif delta.days == 1:
            return "1 day ago"
        else:
            return f"{delta.days} days ago"
    except:
        return iso_date[:10]


def format_inbox_table(items: list, title: str, emoji: str) -> str:
    """Format list of items as markdown table."""
    if not items:
        return f"### {emoji} {title} (0)\n\n_No items_\n"

    output = [f"### {emoji} {title} ({len(items)})\n"]
    output.append("| Type | Key | Summary | Status | Reason |")
    output.append("|------|-----|---------|--------|--------|")

    for item in items:
        # Truncate summary if too long
        summary = item['summary']
        if len(summary) > 60:
            summary = summary[:57] + "..."

        # Create clickable key
        key_link = f"[{item['key']}]({item['url']})"

        output.append(
            f"| {item['type']} | {key_link} | {summary} | {item['status']} | {item['reason']} |"
        )

    return "\n".join(output) + "\n"


def format_inbox(inbox_data: dict) -> str:
    """Format complete inbox report."""
    output = []

    output.append("## Your Jira Inbox\n")

    # Requires action section
    if inbox_data['requires_action']:
        output.append(format_inbox_table(
            inbox_data['requires_action'],
            "Requires Action",
            "🔴"
        ))
        output.append("")

    # Watching section
    if inbox_data['watching']:
        output.append(format_inbox_table(
            inbox_data['watching'],
            "Watching",
            "📋"
        ))
        output.append("")

    # Summary
    summary = inbox_data['summary']
    output.append(f"**Total**: {summary['requires_action']} issues require action, "
                  f"{summary['watching']} watching\n")

    return "\n".join(output)


def main():
    args = parse_args()

    try:
        with open(args.input, 'r') as f:
            inbox_data = json.load(f)
    except FileNotFoundError:
        print(f"Error: File not found: {args.input}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error parsing JSON: {e}", file=sys.stderr)
        sys.exit(1)

    # Format and print
    print(format_inbox(inbox_data))


if __name__ == "__main__":
    main()
