#!/usr/bin/env python3
"""Phase 4: Generate Markdown report from diagnosis results.

Usage:
    python3 workflows/weekly-bot-pr-report/generate_report.py <diagnoses_dir> <output.md>

Input:  Directory containing pr-*.json diagnosis result files
Output: Markdown report file
"""
import json
import glob
import os
import sys
import datetime
from collections import defaultdict


# Report category order and display names
CATEGORIES = [
    ("recommend-merge", "Recommend Merge"),
    ("patched", "Auto-Patched"),
    ("retest", "Recommend Retest"),
    ("needs-manual", "Needs Manual Intervention"),
    ("skipped-fork", "Skipped (Fork PRs)"),
    ("pending", "Pending"),
]


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
        print("Usage: generate_report.py <diagnoses_dir> <output.md>", file=sys.stderr)
        sys.exit(1)

    diagnoses_dir = sys.argv[1]
    output_file = sys.argv[2]

    diagnoses = load_diagnoses(diagnoses_dir)
    today = datetime.date.today().isoformat()
    total = len(diagnoses)

    # Group by action category
    by_action = defaultdict(list)
    for d in diagnoses:
        by_action[d["action"]].append(d)

    # Group by author
    by_author = defaultdict(int)
    for d in diagnoses:
        by_author[d["author"]] += 1

    # Group by repo
    by_repo = defaultdict(lambda: defaultdict(int))
    for d in diagnoses:
        by_repo[d["repo"]][d["action"]] += 1
        by_repo[d["repo"]]["total"] += 1

    # Group by branch
    by_branch = defaultdict(lambda: defaultdict(int))
    for d in diagnoses:
        by_branch[d["branch"]][d["action"]] += 1
        by_branch[d["branch"]]["total"] += 1

    # Category counts
    counts = {action: len(by_action.get(action, [])) for action, _ in CATEGORIES}

    def format_pr_link(d):
        return f"[#{d['pr_number']}]({d['url']})"

    md = [
        f"# Server Foundation Weekly Bot PR Report — {today}",
        "",
        "## Executive Summary",
        "",
        f"- **Total open bot PRs:** {total}",
        f"- **By category:** "
        + ", ".join(f"{name} ({counts[action]})" for action, name in CATEGORIES),
        f"- **By bot author:** "
        + ", ".join(f"{author} ({count})" for author, count in
                    sorted(by_author.items(), key=lambda x: x[1], reverse=True)),
        "",
        "---",
        "",
    ]

    # --- Recommend Merge ---
    md.extend([
        "## Recommend Merge",
        "",
        "All CI checks passed. Recommend adding `approved` + `lgtm` labels to merge.",
        "",
    ])
    prs = by_action.get("recommend-merge", [])
    if prs:
        md.append("| PR | Repository | Branch | Title | Age (days) |")
        md.append("|----|------------|--------|-------|------------|")
        for d in sorted(prs, key=lambda x: x["age_days"]):
            md.append(f"| {format_pr_link(d)} | {d['repo']} | {d['branch']} | {d['title']} | {d['age_days']} |")
    else:
        md.append("> No bot PRs are currently ready to merge.")
    md.extend(["", "---", ""])

    # --- Auto-Patched ---
    md.extend([
        "## Auto-Patched",
        "",
        "The agent identified a known failure pattern and pushed a fix. CI should re-run automatically.",
        "",
    ])
    prs = by_action.get("patched", [])
    if prs:
        md.append("| PR | Repository | Branch | Title | Pattern | Details |")
        md.append("|----|------------|--------|-------|---------|---------|")
        for d in sorted(prs, key=lambda x: x["repo"]):
            md.append(f"| {format_pr_link(d)} | {d['repo']} | {d['branch']} | {d['title']} | {d['pattern_matched']} | {d['action_details']} |")
    else:
        md.append("> No PRs were auto-patched.")
    md.extend(["", "---", ""])

    # --- Recommend Retest ---
    md.extend([
        "## Recommend Retest",
        "",
        "Infrastructure issue detected (e.g., cluster pool exhaustion). Running `/retest` should resolve.",
        "",
    ])
    prs = by_action.get("retest", [])
    if prs:
        md.append("| PR | Repository | Branch | Title | Details |")
        md.append("|----|------------|--------|-------|---------|")
        for d in sorted(prs, key=lambda x: x["repo"]):
            md.append(f"| {format_pr_link(d)} | {d['repo']} | {d['branch']} | {d['title']} | {d['action_details']} |")
    else:
        md.append("> No PRs need retesting.")
    md.extend(["", "---", ""])

    # --- Needs Manual Intervention ---
    md.extend([
        "## Needs Manual Intervention",
        "",
        "The agent could not diagnose or fix these PRs automatically. Manual review required.",
        "",
    ])
    prs = by_action.get("needs-manual", [])
    if prs:
        md.append("| PR | Repository | Branch | Title | Failed Checks | Details |")
        md.append("|----|------------|--------|-------|---------------|---------|")
        for d in sorted(prs, key=lambda x: x["repo"]):
            failed = ", ".join(d.get("failed_checks", []))
            md.append(f"| {format_pr_link(d)} | {d['repo']} | {d['branch']} | {d['title']} | {failed} | {d['action_details']} |")
    else:
        md.append("> All failing PRs were handled automatically.")
    md.extend(["", "---", ""])

    # --- Skipped (Fork PRs) ---
    md.extend([
        "## Skipped (Fork PRs)",
        "",
        "Cross-repository PRs where the agent cannot push fixes.",
        "",
    ])
    prs = by_action.get("skipped-fork", [])
    if prs:
        md.append("| PR | Repository | Branch | Title | Author |")
        md.append("|----|------------|--------|-------|--------|")
        for d in sorted(prs, key=lambda x: x["repo"]):
            md.append(f"| {format_pr_link(d)} | {d['repo']} | {d['branch']} | {d['title']} | @{d['author']} |")
    else:
        md.append("> No fork PRs.")
    md.extend(["", "---", ""])

    # --- Pending ---
    md.extend([
        "## Pending",
        "",
        "CI checks are still running. Revisit later.",
        "",
    ])
    prs = by_action.get("pending", [])
    if prs:
        md.append("| PR | Repository | Branch | Title | Age (days) |")
        md.append("|----|------------|--------|-------|------------|")
        for d in sorted(prs, key=lambda x: x["age_days"]):
            md.append(f"| {format_pr_link(d)} | {d['repo']} | {d['branch']} | {d['title']} | {d['age_days']} |")
    else:
        md.append("> No PRs with pending checks.")
    md.extend(["", "---", ""])

    # --- Per-Repository Summary ---
    action_keys = [a for a, _ in CATEGORIES]
    action_short = {
        "recommend-merge": "Merge",
        "patched": "Patched",
        "retest": "Retest",
        "needs-manual": "Manual",
        "skipped-fork": "Fork",
        "pending": "Pending",
    }

    md.extend([
        "## Per-Repository Summary",
        "",
        "| Repository | Total | " + " | ".join(action_short[a] for a in action_keys) + " |",
        "|------------|-------| " + " | ".join("---" for _ in action_keys) + " |",
    ])
    for repo, stats in sorted(by_repo.items(), key=lambda x: x[1]["total"], reverse=True):
        cols = " | ".join(str(stats.get(a, 0)) for a in action_keys)
        md.append(f"| {repo} | {stats['total']} | {cols} |")
    md.extend(["", "---", ""])

    # --- Per-Branch Summary ---
    md.extend([
        "## Per-Branch Summary",
        "",
        "| Branch | Total | " + " | ".join(action_short[a] for a in action_keys) + " |",
        "|--------|-------| " + " | ".join("---" for _ in action_keys) + " |",
    ])
    for branch, stats in sorted(by_branch.items(), key=lambda x: x[0], reverse=True):
        cols = " | ".join(str(stats.get(a, 0)) for a in action_keys)
        md.append(f"| {branch} | {stats['total']} | {cols} |")

    with open(output_file, 'w') as f:
        f.write('\n'.join(md) + '\n')

    print(f"Report written to {output_file}", file=sys.stderr)


if __name__ == '__main__':
    main()
