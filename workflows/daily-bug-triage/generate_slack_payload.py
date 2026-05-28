#!/usr/bin/env python3
"""Generate Slack Block Kit payload from bug triage analysis results.

Usage:
    python3 workflows/daily-bug-triage/generate_slack_payload.py <analyses_dir> <output_payload.json> [--previously-analyzed <skipped_bugs.json>]

Input:  Directory containing bug-*.json analysis result files
        Optional: JSON file with bugs that were previously analyzed (from Phase 1.5 dedup)
Output: Slack Block Kit JSON payload file
"""
import json
import glob
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from slack_blocks import SF_GROUP_MENTION, agent_footer_block, escape_mrkdwn, today_iso, truncate

# Priority emoji mapping
PRIORITY_EMOJI = {
    "Blocker": "\U0001f534",   # red circle
    "Critical": "\U0001f7e0",  # orange circle
    "Major": "\U0001f7e1",     # yellow circle
    "Normal": "\U0001f535",    # blue circle
    "Minor": "\u26aa",         # white circle
}


def load_analyses(analyses_dir):
    """Load all bug-*.json files from the analyses directory."""
    pattern = os.path.join(analyses_dir, "bug-*.json")
    results = []
    for path in sorted(glob.glob(pattern)):
        with open(path, 'r') as f:
            results.append(json.load(f))
    return results


def format_root_cause_bug(a):
    """Format a bug with root cause found."""
    priority_em = PRIORITY_EMOJI.get(a['priority'], '')
    summary = truncate(escape_mrkdwn(a['summary']), 60)
    short_repo = a.get('relevant_repo', '').split('/')[-1] if a.get('relevant_repo') else 'unknown'

    lines = [f"\u2022 <{a['url']}|{a['key']}> {priority_em} *{a['priority']}* \u2014 {summary}"]

    # Relevant repo and files
    files = a.get('relevant_files', [])
    files_str = ', '.join(f"`{f.split('/')[-1]}`" for f in files[:3]) if files else '_none_'
    lines.append(f"     _Repo:_ {short_repo} \u00b7 _Files:_ {files_str}")

    # One-line summary (full details in Jira comment)
    root_cause = truncate(escape_mrkdwn(a.get('root_cause', '')), 120)
    lines.append(f"     {root_cause}")
    lines.append(f"     \U0001f4ac <{a['url']}|Full analysis in Jira comment>")

    # Draft PR link (from Phase 2.5 auto-fix)
    draft_pr_url = a.get('draft_pr_url', '')
    if draft_pr_url:
        pr_num = draft_pr_url.rstrip('/').split('/')[-1]
        lines.append(f"     \U0001f527 _Draft PR:_ <{draft_pr_url}|#{pr_num}> \u2014 ready for review")

    return "\n".join(lines)


def format_partial_bug(a):
    """Format a bug with partial analysis."""
    priority_em = PRIORITY_EMOJI.get(a['priority'], '')
    summary = truncate(escape_mrkdwn(a['summary']), 60)
    short_repo = a.get('relevant_repo', '').split('/')[-1] if a.get('relevant_repo') else 'unknown'

    lines = [f"\u2022 <{a['url']}|{a['key']}> {priority_em} *{a['priority']}* \u2014 {summary}"]
    lines.append(f"     _Repo:_ {short_repo}")

    notes = truncate(escape_mrkdwn(a.get('notes', a.get('root_cause', ''))), 200)
    if notes:
        lines.append(f"     _Notes:_ {notes}")

    return "\n".join(lines)


def format_insufficient_bug(a):
    """Format a bug with insufficient info."""
    priority_em = PRIORITY_EMOJI.get(a['priority'], '')
    summary = truncate(escape_mrkdwn(a['summary']), 60)

    lines = [f"\u2022 <{a['url']}|{a['key']}> {priority_em} *{a['priority']}* \u2014 {summary}"]

    reason = truncate(escape_mrkdwn(a.get('notes', 'Insufficient information for analysis')), 200)
    lines.append(f"     _Reason:_ {reason}")

    return "\n".join(lines)


def format_previously_analyzed_bug(bug):
    """Format a bug that was already analyzed in a prior triage run."""
    priority_em = PRIORITY_EMOJI.get(bug.get('priority', ''), '')
    summary = truncate(escape_mrkdwn(bug.get('summary', '')), 60)
    url = bug.get('url', '')
    key = bug.get('key', '')
    assignee = bug.get('assignee', 'Unassigned')
    created = bug.get('created', '')[:10]

    lines = [f"\u2022 <{url}|{key}> {priority_em} *{bug.get('priority', '')}* \u2014 {summary}"]
    lines.append(f"     _Assignee:_ {assignee} \u00b7 _Created:_ {created} \u00b7 _Still in New_")
    return "\n".join(lines)


def main():
    if len(sys.argv) < 3:
        print("Usage: generate_slack_payload.py <analyses_dir> <output.json> [--previously-analyzed <skipped.json>]", file=sys.stderr)
        sys.exit(1)

    analyses_dir = sys.argv[1]
    output_file = sys.argv[2]

    # Parse optional --previously-analyzed flag
    previously_analyzed = []
    args = sys.argv[3:]
    if "--previously-analyzed" in args:
        idx = args.index("--previously-analyzed")
        if idx + 1 < len(args):
            pa_file = args[idx + 1]
            if os.path.exists(pa_file):
                with open(pa_file, 'r') as f:
                    previously_analyzed = json.load(f)

    analyses = load_analyses(analyses_dir)
    today = today_iso()
    total = len(analyses)

    # Group by analysis_status
    by_status = {}
    for a in analyses:
        by_status.setdefault(a["analysis_status"], []).append(a)

    n_root_cause = len(by_status.get("root-cause-found", []))
    n_partial = len(by_status.get("partial-analysis", []))
    n_insufficient = len(by_status.get("insufficient-info", []))
    n_error = len(by_status.get("error", []))
    n_draft_prs = sum(1 for a in analyses if a.get('draft_pr_url'))
    n_previously_analyzed = len(previously_analyzed)

    fallback_text = (
        f"SF Daily Bug Triage \u2014 {today}: "
        f"{total} new bugs analyzed, {n_root_cause} root cause found, "
        f"{n_draft_prs} draft PRs, "
        f"{n_partial} partial, {n_insufficient} needs info"
        + (f", {n_previously_analyzed} previously analyzed" if n_previously_analyzed > 0 else "")
    )

    summary_text = (
        f"{SF_GROUP_MENTION}\n"
        f"*Summary:* {total} new bug{'s' if total != 1 else ''} analyzed"
        + (f" \u00b7 {n_draft_prs} draft PR{'s' if n_draft_prs != 1 else ''} submitted" if n_draft_prs > 0 else "")
        + (f" \u00b7 {n_previously_analyzed} still in New (previously analyzed)" if n_previously_analyzed > 0 else "")
        + f"\n*Root cause found:* {n_root_cause}  \u00b7  "
        f"*Partial:* {n_partial}  \u00b7  "
        f"*Needs info:* {n_insufficient}"
        + (f"  \u00b7  *Error:* {n_error}" if n_error > 0 else "")
    )

    blocks = [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": f"\U0001f41b SF Daily Bug Triage \u2014 {today}"
            }
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": summary_text
            }
        },
        {"type": "divider"}
    ]

    # --- Root Cause Found ---
    root_cause_bugs = by_status.get("root-cause-found", [])
    if root_cause_bugs:
        # Sort by priority: Blocker > Critical > Major > Normal > Minor
        priority_order = {"Blocker": 0, "Critical": 1, "Major": 2, "Normal": 3, "Minor": 4}
        root_cause_bugs.sort(key=lambda x: priority_order.get(x['priority'], 99))

        text = f"*\U0001f7e2 Root Cause Identified ({n_root_cause})*\n"
        text += "\n".join(format_root_cause_bug(a) for a in root_cause_bugs)
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})
        blocks.append({"type": "divider"})

    # --- Partial Analysis ---
    partial_bugs = by_status.get("partial-analysis", [])
    if partial_bugs:
        text = f"*\U0001f7e1 Partial Analysis ({n_partial})*\n"
        text += "\n".join(format_partial_bug(a) for a in partial_bugs)
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})
        blocks.append({"type": "divider"})

    # --- Insufficient Info ---
    insufficient_bugs = by_status.get("insufficient-info", [])
    if insufficient_bugs:
        text = f"*\U0001f534 Needs More Info ({n_insufficient})*\n"
        text += "\n".join(format_insufficient_bug(a) for a in insufficient_bugs)
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})
        blocks.append({"type": "divider"})

    # --- Errors ---
    error_bugs = by_status.get("error", [])
    if error_bugs:
        text = f"*\u26a0\ufe0f Analysis Error ({n_error})*\n"
        for a in error_bugs:
            summary = truncate(escape_mrkdwn(a['summary']), 60)
            notes = escape_mrkdwn(a.get('notes', 'Unknown error'))
            text += f"\u2022 <{a['url']}|{a['key']}> \u2014 {summary}\n     _Error:_ {notes}\n"
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})

    # --- Previously Analyzed (still in New) ---
    if previously_analyzed:
        text = f"*\u23f3 Still in New \u2014 Previously Analyzed ({n_previously_analyzed})*\n"
        text += "_These bugs were analyzed in a prior triage run but remain in New status. They may need assignee attention._\n"
        text += "\n".join(format_previously_analyzed_bug(b) for b in previously_analyzed)
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})
        blocks.append({"type": "divider"})

    # --- No bugs case ---
    if total == 0 and not previously_analyzed:
        blocks.append({
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "*\u2705 No new bugs!* All clear."
            }
        })

    # --- Context footer ---
    blocks.append(agent_footer_block(today))

    payload = {"text": fallback_text, "blocks": blocks}

    with open(output_file, 'w') as f:
        json.dump(payload, f, ensure_ascii=False)

    print(f"Slack payload written to {output_file} ({total} bugs)", file=sys.stderr)


if __name__ == '__main__':
    main()
