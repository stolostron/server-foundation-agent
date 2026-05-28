#!/usr/bin/env python3
"""Generate Slack Block Kit payload from sprint metrics.

Usage:
    python3 workflows/daily-scrum-prep/generate_slack_payload.py \
        <metrics.json> <output_payload.json> [agent_insights.json]

Input:
    - metrics.json from compute_metrics.py
    - agent_insights.json (optional): AI-generated insights from agent analysis
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
    linkify_issue_keys,
    today_iso,
)

# Severity emoji
SEVERITY_EMOJI = {"high": "\U0001f534", "medium": "\U0001f7e1"}

# Category emoji
CATEGORY_EMOJI = {
    "Burndown": "\U0001f4c9",
    "Flow": "\U0001f500",
    "WIP": "\U0001f6a7",
    "Scope": "\U0001f4cb",
    "Priority": "\u26a1",
    "Commitment": "\U0001f4ca",
    "CycleTime": "\u23f1\ufe0f",
}


def make_progress_bar(done_pct, width=16):
    """Create a text-based progress bar."""
    filled = round(done_pct / 100 * width)
    empty = width - filled
    return "\u2588" * filled + "\u2591" * empty


def format_metric_value(value, unit=""):
    """Format a metric value, handling None."""
    if value is None:
        return "N/A"
    if isinstance(value, float):
        return f"{value:.1f}{unit}"
    return f"{value}{unit}"


def build_blocks(metrics, agent_insights=None):
    """Build Slack Block Kit blocks from metrics."""
    today = today_iso()
    sprint = metrics.get("sprint") or {}
    burndown = metrics.get("burndown", {})
    scope = metrics.get("scope_change", {})
    cycle_time = metrics.get("cycle_time", {})
    review = metrics.get("review_bottleneck", {})
    wip = metrics.get("wip", {})
    per_member = metrics.get("per_member", {})
    recommendations = metrics.get("recommendations", [])

    sprint_name = sprint.get("name", "Unknown Sprint")
    end_date = sprint.get("end_date", "")

    blocks = []

    # Header
    blocks.append({
        "type": "header",
        "text": {
            "type": "plain_text",
            "text": f"\U0001f4ca SF Daily Scrum Prep \u2014 {today}",
        },
    })

    # Sprint progress bar
    bar = make_progress_bar(burndown.get("done_pct", 0))
    elapsed_days = burndown.get("elapsed_days", 0)
    total_days = burndown.get("total_days", 0)
    remaining = burndown.get("remaining_days", 0)
    done_count = burndown.get("done_count", 0)
    total_count = burndown.get("total_count", 0)
    done_pct = burndown.get("done_pct", 0)
    elapsed_pct = burndown.get("elapsed_pct", 0)

    progress_text = (
        f"{SF_GROUP_MENTION}\n"
        f"*{sprint_name}* \u00b7 Day {elapsed_days}/{total_days} \u00b7 "
        f"{remaining}d remaining \u00b7 Ends {end_date}\n"
        f"`{bar}` *{done_pct}%* ({done_count}/{total_count}) done  \u00b7  "
        f"{elapsed_pct}% elapsed"
    )

    # Burndown status indicator
    gap = burndown.get("gap", 0)
    if gap <= 5:
        progress_text += "  \u2705 On track"
    elif gap <= 15:
        progress_text += f"  \u26a0\ufe0f {gap}% behind"
    else:
        progress_text += f"  \U0001f534 {gap}% behind \u2014 at risk"

    blocks.append({
        "type": "section",
        "text": {"type": "mrkdwn", "text": progress_text},
    })

    blocks.append({"type": "divider"})

    # Key Metrics Dashboard
    median_ct = format_metric_value(cycle_time.get("median"), "d")
    ct_benchmark = f"Target: <{5}d"
    scope_rate = format_metric_value(scope.get("rate"), "%")
    review_count = review.get("count", 0)
    avg_wip = format_metric_value(wip.get("avg_wip_per_member"), "")
    commit_rate = f"{done_pct}%"  # Simplified: done/total

    metrics_text = (
        "*Key Metrics*\n"
        "```\n"
        f"{'Metric':<22s} {'Value':>7s}   {'Benchmark'}\n"
        f"{'─' * 22:<22s} {'─' * 7:>7s}   {'─' * 15}\n"
        f"{'Sprint Completion':<22s} {commit_rate:>7s}   Target: 80-90%\n"
        f"{'Scope Change':<22s} {scope_rate:>7s}   Target: <10%\n"
        f"{'Median Cycle Time':<22s} {median_ct:>7s}   {ct_benchmark}\n"
        f"{'Items in Review':<22s} {str(review_count):>7s}   Healthy: <5\n"
        f"{'Avg WIP/Person':<22s} {avg_wip:>7s}   Limit: 2-3\n"
        "```"
    )

    blocks.append({
        "type": "section",
        "text": {"type": "mrkdwn", "text": metrics_text},
    })

    blocks.append({"type": "divider"})

    # Coaching Recommendations — max 3 action items, no separate suggestions
    # Merge high + medium, prioritize high, cap at 3 total
    all_recs = sorted(recommendations, key=lambda r: (0 if r["severity"] == "high" else 1))
    top_recs = all_recs[:5]

    if top_recs:
        rec_text = "*\U0001f3af Action Required*\n"
        for r in top_recs:
            msg = linkify_issue_keys(escape_mrkdwn(r["message"]))
            rec_text += f"\u2022 {msg}\n"

        blocks.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": rec_text},
        })
    else:
        blocks.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": "\u2705 *No critical issues!* Sprint is healthy."},
        })

    blocks.append({"type": "divider"})

    # Sprint Insights (AI-generated by agent)
    if agent_insights:
        # Team-level insights
        team_insights = agent_insights.get("team_insights", [])
        member_insights = agent_insights.get("member_insights", [])

        if team_insights or member_insights:
            insights_text = "*\U0001f9e0 Sprint Insights*\n"

            for insight in team_insights:
                msg = linkify_issue_keys(escape_mrkdwn(insight))
                insights_text += f"\u2022 {msg}\n"

            if member_insights:
                insights_text += "\n*Per-member:*\n"
                for mi in member_insights:
                    member = escape_mrkdwn(mi.get("member", ""))
                    msg = linkify_issue_keys(escape_mrkdwn(mi.get("insight", "")))
                    insights_text += f"\u2022 *{member}*: {msg}\n"

            # Slack section text limit is 3000 chars
            if len(insights_text) > 2900:
                insights_text = insights_text[:2897] + "..."

            blocks.append({
                "type": "section",
                "text": {"type": "mrkdwn", "text": insights_text},
            })
            blocks.append({"type": "divider"})

    # Per-Member Status (compact table)
    if per_member:
        member_text = "*Per-Member Status*\n```\n"
        member_text += f"{'Member':<18s} {'New':>3s} {'Back':>4s} {'Prog':>4s} {'Rev':>3s} {'Test':>4s} {'Resv':>4s} {'Clos':>4s}\n"
        member_text += f"{'─' * 18:<18s} {'─' * 3:>3s} {'─' * 4:>4s} {'─' * 4:>4s} {'─' * 3:>3s} {'─' * 4:>4s} {'─' * 4:>4s} {'─' * 4:>4s}\n"

        for member, stats in per_member.items():
            # Truncate long names
            name = member[:17] if len(member) > 17 else member
            member_text += (
                f"{name:<18s} {stats['new']:>3d} {stats['backlog']:>4d} {stats['in_progress']:>4d} "
                f"{stats['review']:>3d} {stats['testing']:>4d} {stats['resolved']:>4d} {stats['closed']:>4d}\n"
            )

        member_text += "```"

        # Split if too long
        if len(member_text) > 3000:
            member_text = member_text[:2997] + "```"

        blocks.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": member_text},
        })

    blocks.append({"type": "divider"})

    # Review items detail (only sprint items — all come from sprint query)
    over_threshold = review.get("items", [])
    stale_reviews = [r for r in over_threshold if r.get("days_in_review", 0) > 2]
    if stale_reviews:
        review_text = f"*\U0001f50d Review Queue \u2014 {sprint_name}* ({review_count} items in sprint)\n"
        for item in stale_reviews[:8]:
            key = item["key"]
            url = f"https://redhat.atlassian.net/browse/{key}"
            summary = escape_mrkdwn(item.get("summary", "")[:50])
            days = item.get("days_in_review", 0)
            assignee = item.get("assignee", "Unassigned")
            review_text += f"\u2022 <{url}|{key}> \u2014 {summary} \u00b7 _{assignee}_ \u00b7 *{days}d* in review\n"

        blocks.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": review_text},
        })
        blocks.append({"type": "divider"})

    # Context footer
    blocks.append(agent_footer_block(today))

    return blocks


def main():
    if len(sys.argv) < 3:
        print("Usage: generate_slack_payload.py <metrics.json> <output.json> [agent_insights.json]", file=sys.stderr)
        sys.exit(1)

    metrics_file = sys.argv[1]
    output_file = sys.argv[2]
    insights_file = sys.argv[3] if len(sys.argv) > 3 else None

    with open(metrics_file) as f:
        metrics = json.load(f)

    agent_insights = None
    if insights_file:
        try:
            with open(insights_file) as f:
                agent_insights = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError) as e:
            print(f"Warning: Could not load agent insights: {e}", file=sys.stderr)

    blocks = build_blocks(metrics, agent_insights)

    sprint_name = metrics.get("sprint", {}).get("name", "Unknown")
    burndown = metrics.get("burndown", {})
    done_pct = burndown.get("done_pct", 0)
    elapsed_pct = burndown.get("elapsed_pct", 0)
    recs = metrics.get("recommendations", [])
    high_count = sum(1 for r in recs if r["severity"] == "high")

    fallback_text = (
        f"SF Daily Scrum Prep \u2014 {today_iso()}: "
        f"{sprint_name} \u00b7 {done_pct}% done ({elapsed_pct}% elapsed)"
        + (f" \u00b7 {high_count} action items" if high_count > 0 else " \u00b7 on track")
    )

    payload = {"text": fallback_text, "blocks": blocks}

    with open(output_file, "w") as f:
        json.dump(payload, f, ensure_ascii=False)

    print(f"Slack payload written to {output_file}", file=sys.stderr)


if __name__ == "__main__":
    main()
