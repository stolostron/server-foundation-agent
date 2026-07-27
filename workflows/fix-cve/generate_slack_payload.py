#!/usr/bin/env python3
"""Generate Slack Block Kit payload for fix-cve agent-swarm runs.

Usage:
    python3 workflows/fix-cve/generate_slack_payload.py \\
        <output_dir_or_remediation.json> <slack_payload.json>

Reads optional files from the output directory (when first arg is a directory):
  - remediation.json — array of remediation action records
  - run_meta.json — optional counts and failure strings
  - vulnerabilities.json — optional; used for early-exit / issue counts

Before building Slack blocks, refreshes live GitHub PR state via gh when available.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from gh_pr_state import (  # noqa: E402
    linkify_pr_refs,
    parse_pr_url,
    pr_lookup_from_entries,
    pr_short_label,
    pr_state_from_row,
)
from slack_blocks import (  # noqa: E402
    SF_GROUP_LABEL,
    agent_footer_block,
    escape_mrkdwn,
    header_block,
    linkify_issue_keys,
    section_mrkdwn,
    section_mrkdwn_chunks,
    today_iso,
)

PR_TRACKING_ACTIONS = frozenset(
    {"pr_opened", "skipped_existing_pr", "pr_merged", "pr_closed"}
)


def _load_json(path: Path) -> object | None:
    if not path.is_file():
        return None
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def _resolve_input_dir(arg: str) -> tuple[Path, Path]:
    p = Path(arg)
    if p.is_dir():
        return p, p / "remediation.json"
    return p.parent, p


def _slack_pr_link(pr_url: str, label: str) -> str:
    """Slack mrkdwn PR link using a validated GitHub URL, or escaped plain text."""
    parsed = parse_pr_url(pr_url)
    if not parsed:
        return escape_mrkdwn(label)
    repo, number = parsed
    safe_url = f"https://github.com/{repo}/pull/{number}"
    return f"<{safe_url}|{escape_mrkdwn(label)}>"


def _format_pr_line(
    pr_url: str,
    repo: str,
    branch: str,
    keys: list[str],
    *,
    pr_number: int | None = None,
) -> str:
    repo_short = repo.split("/")[-1] if repo else "repo"
    key_part = ", ".join(keys[:6])
    if len(keys) > 6:
        key_part += f" (+{len(keys) - 6} more)"
    link_label = f"{repo_short} #{pr_number}" if pr_number else repo_short
    branch_part = f" `{branch}`" if branch else ""
    return (
        f"• {_slack_pr_link(pr_url, link_label)}{branch_part} — "
        f"{linkify_issue_keys(escape_mrkdwn(key_part))}"
    )


def _aggregate_prs(remediation: list[dict]) -> dict[str, dict[str, Any]]:
    prs: dict[str, dict[str, Any]] = {}
    for row in remediation:
        action = row.get("action", "")
        if action not in PR_TRACKING_ACTIONS or not row.get("pr_url"):
            continue
        url = row["pr_url"]
        state = pr_state_from_row(row)
        entry = prs.setdefault(
            url,
            {
                "pr_url": url,
                "repo": row.get("repo", "") or (state.repo if state else ""),
                "branch": row.get("branch", ""),
                "keys": [],
                "cve_ids": [],
                "bucket": state.bucket if state else "draft",
                "pr_number": state.number if state else None,
            },
        )
        if state:
            entry["bucket"] = state.bucket
            entry["pr_number"] = state.number
            if not entry["repo"]:
                entry["repo"] = state.repo
        key = row.get("issue_key")
        if key and key not in entry["keys"]:
            entry["keys"].append(key)
        cve = row.get("cve_id")
        if cve and cve not in entry["cve_ids"]:
            entry["cve_ids"].append(cve)
        if not entry.get("branch") and row.get("branch"):
            entry["branch"] = row["branch"]
    return prs


def _bucket_prs(prs: dict[str, dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    buckets: dict[str, list[dict[str, Any]]] = {
        "draft": [],
        "awaiting_approval": [],
        "merged": [],
        "closed": [],
    }
    for entry in prs.values():
        bucket = entry.get("bucket", "draft")
        if bucket not in buckets:
            bucket = "draft"
        buckets[bucket].append(entry)
    for items in buckets.values():
        items.sort(
            key=lambda p: (
                (p.get("cve_ids") or [""])[0],
                p.get("repo", ""),
                p.get("branch", ""),
            )
        )
    return buckets


def _primary_cve(entry: dict[str, Any]) -> str:
    cves = entry.get("cve_ids") or []
    return cves[0] if cves else ""


def _group_by_cve(items: list[dict[str, Any]]) -> list[tuple[str, list[dict[str, Any]]]]:
    """Preserve CVE order from sorted items; empty CVE last."""
    order: list[str] = []
    groups: dict[str, list[dict[str, Any]]] = {}
    for entry in items:
        cve = _primary_cve(entry) or "Unspecified CVE"
        if cve not in groups:
            order.append(cve)
            groups[cve] = []
        groups[cve].append(entry)
    return [(cve, groups[cve]) for cve in order]


def _derive_follow_up_lines(buckets: dict[str, list[dict[str, Any]]]) -> list[str]:
    """One bullet per open PR needing human action."""
    lines: list[str] = []

    for entry in buckets["draft"]:
        label = pr_short_label(entry.get("repo", ""), entry.get("pr_number"))
        url = entry["pr_url"]
        lines.append(f"• <{url}|{label}> — mark Ready for review; `/ok-to-test` if needed")

    for entry in buckets["awaiting_approval"]:
        label = pr_short_label(entry.get("repo", ""), entry.get("pr_number"))
        url = entry["pr_url"]
        lines.append(f"• <{url}|{label}> — `/approve` + `/lgtm` when CI is green")

    for entry in buckets["closed"]:
        label = pr_short_label(entry.get("repo", ""), entry.get("pr_number"))
        url = entry["pr_url"]
        lines.append(f"• <{url}|{label}> — closed unmerged; may need a new fix PR")

    return lines


def _follow_up_extra_bullets(extra: str, pr_lookup: dict[str, str]) -> list[str]:
    """Split agent prose follow-up into point-form bullets with linkified PR refs."""
    parts = re.split(r";\s*|\n+", extra.strip())
    bullets: list[str] = []
    for part in parts:
        text = part.strip().rstrip(".")
        if not text:
            continue
        linked = linkify_pr_refs(linkify_issue_keys(escape_mrkdwn(text)), pr_lookup)
        bullets.append(f"• {linked}")
    return bullets


def _build_follow_up_text(
    buckets: dict[str, list[dict[str, Any]]],
    extra: str | None,
    pr_lookup: dict[str, str],
) -> str:
    """Assemble Follow-up body as a bullet list."""
    lines = _derive_follow_up_lines(buckets)
    if extra and extra.strip():
        lines.extend(_follow_up_extra_bullets(extra.strip(), pr_lookup))
    if lines:
        return "\n".join(lines)
    if buckets["merged"]:
        return "• _All tracked CVE PRs merged this run — see Closed (merged PR) for Jira updates_"
    return (
        "• _No open CVE PRs need action this run — monitor z-stream backports in tracking tasks_"
    )


def _derive_follow_up(buckets: dict[str, list[dict[str, Any]]]) -> str:
    """Backward-compatible wrapper for tests."""
    return _build_follow_up_text(buckets, None, {})


def _is_closed_this_run(row: dict[str, Any]) -> bool:
    """True only for Jira issues transitioned to Closed during this run."""
    return row.get("closed_this_run") is True


def _closure_rows_this_run(
    remediation: list[dict],
    meta: dict[str, Any],
    action: str,
) -> list[dict]:
    """Return closure rows for issues closed during this run only."""
    rows = [
        r
        for r in remediation
        if r.get("action") == action and _is_closed_this_run(r)
    ]
    seen = {r.get("issue_key") for r in rows if r.get("issue_key")}
    for row in meta.get("jira_closed_this_run") or []:
        if not isinstance(row, dict) or row.get("action") != action:
            continue
        if not _is_closed_this_run(row):
            continue
        key = row.get("issue_key")
        if key and key not in seen:
            rows.append(row)
            seen.add(key)
    return rows


def _aggregate_closed_merged(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Group closed_merged_pr rows by PR URL (same layout as open PR sections)."""
    by_url: dict[str, dict[str, Any]] = {}
    for row in rows:
        url = row.get("pr_url") or ""
        if not url:
            key = row.get("issue_key")
            entry = by_url.setdefault(
                f"no-pr:{key}",
                {
                    "pr_url": "",
                    "repo": row.get("repo", ""),
                    "branch": row.get("branch", ""),
                    "keys": [],
                    "cve_ids": [],
                    "pr_number": None,
                },
            )
            if key and key not in entry["keys"]:
                entry["keys"].append(key)
            cve = row.get("cve_id")
            if cve and cve not in entry["cve_ids"]:
                entry["cve_ids"].append(cve)
            continue
        parsed = parse_pr_url(url)
        num = parsed[1] if parsed else None
        repo = row.get("repo") or (parsed[0] if parsed else "")
        entry = by_url.setdefault(
            url,
            {
                "pr_url": url,
                "repo": repo,
                "branch": row.get("branch", ""),
                "keys": [],
                "cve_ids": [],
                "pr_number": num,
            },
        )
        if not entry["repo"] and repo:
            entry["repo"] = repo
        if not entry["branch"] and row.get("branch"):
            entry["branch"] = row["branch"]
        if num:
            entry["pr_number"] = num
        key = row.get("issue_key")
        if key and key not in entry["keys"]:
            entry["keys"].append(key)
        cve = row.get("cve_id")
        if cve and cve not in entry["cve_ids"]:
            entry["cve_ids"].append(cve)
    items = list(by_url.values())
    items.sort(
        key=lambda p: (
            (p.get("cve_ids") or [""])[0],
            p.get("repo", ""),
            p.get("branch", ""),
        )
    )
    return items


def _format_closed_merged_line(row: dict[str, Any]) -> str:
    """Same layout as open PR rows: repo #N `branch` — ACM-xxx."""
    pr_url = row.get("pr_url", "")
    repo = row.get("repo", "")
    branch = row.get("branch", "")
    num = None
    if pr_url:
        parsed = parse_pr_url(pr_url)
        if parsed:
            repo = repo or parsed[0]
            num = parsed[1]
    key = row.get("issue_key", "?")
    if not pr_url:
        return (
            f"• {linkify_issue_keys(escape_mrkdwn(key))} — "
            f"{escape_mrkdwn(truncate_note(row.get('notes') or 'Fix PR merged'))}"
        )
    return _format_pr_line(pr_url, repo, branch, [key], pr_number=num)


def _format_closed_na_line(row: dict[str, Any]) -> str:
    key = row.get("issue_key", "?")
    note = truncate_note(row.get("notes") or row.get("impact") or "Not applicable")
    return f"• {linkify_issue_keys(escape_mrkdwn(key))} — {escape_mrkdwn(note)}"


def _format_toolchain_rebuild_line(row: dict[str, Any]) -> str:
    """One line for a Konflux TRIGGER_BUILD group."""
    repo = row.get("repo") or "?"
    branch = row.get("branch") or ""
    commit_url = row.get("commit_url") or ""
    commit = row.get("commit") or ""
    short = commit[:7] if commit else "rebuild"
    keys = row.get("issue_keys") or []
    if not keys and row.get("issue_key"):
        keys = [row["issue_key"]]
    key_part = ", ".join(str(k) for k in keys[:6])
    if len(keys) > 6:
        key_part += f" (+{len(keys) - 6} more)"
    branch_part = f" `{branch}`" if branch else ""
    if commit_url:
        link = f"<{commit_url}|{escape_mrkdwn(short)}>"
    else:
        link = escape_mrkdwn(short)
    return (
        f"• {escape_mrkdwn(repo)}{branch_part} — {link} — "
        f"{linkify_issue_keys(escape_mrkdwn(key_part))}"
    )


def _format_toolchain_close_line(row: dict[str, Any]) -> str:
    key = row.get("issue_key", "?")
    fix_ver = row.get("fix_version") or ""
    go_ver = row.get("go_ver") or ""
    note_bits = []
    if go_ver:
        note_bits.append(f"go{go_ver}" if not str(go_ver).startswith("go") else str(go_ver))
    if fix_ver:
        note_bits.append(str(fix_ver))
    note = truncate_note(
        " · ".join(note_bits) if note_bits else (row.get("notes") or "toolchain verify")
    )
    return f"• {linkify_issue_keys(escape_mrkdwn(key))} — {escape_mrkdwn(note)}"


def _aggregate_toolchain_rebuilds(remediation: list[dict]) -> list[dict[str, Any]]:
    """Collapse toolchain_rebuild / skipped_existing_rebuild rows by commit_url."""
    by_key: dict[str, dict[str, Any]] = {}
    for row in remediation:
        action = row.get("action", "")
        if action not in {"toolchain_rebuild", "skipped_existing_rebuild"}:
            continue
        commit_url = row.get("commit_url") or ""
        repo = row.get("repo", "")
        branch = row.get("branch", "")
        group = commit_url or f"{repo}@{branch}:{row.get('commit') or row.get('cve_id')}"
        entry = by_key.setdefault(
            group,
            {
                "commit_url": commit_url,
                "commit": row.get("commit", ""),
                "repo": repo,
                "branch": branch,
                "issue_keys": [],
                "images": list(row.get("images") or []),
                "action": action,
            },
        )
        if row.get("commit") and not entry["commit"]:
            entry["commit"] = row["commit"]
        keys = row.get("issue_keys") or []
        if row.get("issue_key"):
            keys = list(keys) + [row["issue_key"]]
        for key in keys:
            if key and key not in entry["issue_keys"]:
                entry["issue_keys"].append(key)
        for img in row.get("images") or []:
            if img and img not in entry["images"]:
                entry["images"].append(img)
    items = list(by_key.values())
    items.sort(key=lambda p: (p.get("repo", ""), p.get("branch", "")))
    return items


def _append_pr_section(
    blocks: list[dict],
    title: str,
    items: list[dict[str, Any]],
) -> None:
    if not items:
        return
    lines: list[str] = [f"*{title}* ({len(items)})"]
    groups = _group_by_cve(items)
    show_cve_headers = len(groups) > 1 or (
        len(groups) == 1 and groups[0][0] != "Unspecified CVE"
    )
    for cve, group in groups:
        if show_cve_headers:
            lines.append(f"*{escape_mrkdwn(cve)}*")
        for p in group:
            lines.append(
                _format_pr_line(
                    p["pr_url"],
                    p["repo"],
                    p["branch"],
                    p["keys"],
                    pr_number=p.get("pr_number"),
                )
            )
    blocks.extend(section_mrkdwn_chunks("\n".join(lines)))
    blocks.append({"type": "divider"})


def _fallback_notification_text(
    *,
    today: str,
    open_pr_count: int,
    merged_count: int,
    closed_merged_count: int,
    closed_na_count: int,
    cves_processed: int,
    buckets: dict[str, list[dict[str, Any]]],
    closed_toolchain_count: int = 0,
) -> str:
    """Plain-text fallback used when Block Kit fails or for push notifications.

    Always includes full GitHub PR URLs so the message stays actionable even if
    blocks are dropped (e.g. invalid_blocks from a hand-rolled agent fallback).
    """
    lines = [
        f"SF CVE fix — {today}: {open_pr_count} open PR(s), "
        f"{merged_count} merged, {closed_merged_count} Jira closed (merged PR), "
        f"{closed_toolchain_count} closed (toolchain), "
        f"{closed_na_count} closed N/A, {cves_processed} CVE(s) processed",
    ]
    for label, key in (
        ("Draft PRs", "draft"),
        ("Ready for review", "awaiting_approval"),
        ("Merged", "merged"),
    ):
        items = buckets.get(key) or []
        if not items:
            continue
        lines.append(f"{label}:")
        for entry in items:
            cve = _primary_cve(entry)
            prefix = f"{cve} " if cve else ""
            lines.append(f"  {prefix}{entry['pr_url']}")
    return "\n".join(lines)


def main() -> None:
    if len(sys.argv) < 3:
        print(
            "Usage: generate_slack_payload.py <output_dir|remediation.json> "
            "<slack_payload.json>",
            file=sys.stderr,
        )
        sys.exit(1)

    input_dir, remediation_path = _resolve_input_dir(sys.argv[1])
    out_path = Path(sys.argv[2])

    remediation_raw = _load_json(remediation_path)
    remediation: list[dict] = remediation_raw if isinstance(remediation_raw, list) else []

    meta = _load_json(input_dir / "run_meta.json")
    if not isinstance(meta, dict):
        meta = {}

    vulns = _load_json(input_dir / "vulnerabilities.json")
    issue_count = len(vulns) if isinstance(vulns, list) else meta.get("issues_found")

    prs = _aggregate_prs(remediation)
    buckets = _bucket_prs(prs)
    closed_issues = _closure_rows_this_run(remediation, meta, "closed")
    closed_merged = _closure_rows_this_run(remediation, meta, "closed_merged_pr")
    closed_toolchain = _closure_rows_this_run(
        remediation, meta, "toolchain_verify_close"
    )
    toolchain_rebuilds = _aggregate_toolchain_rebuilds(remediation)
    pr_lookup = pr_lookup_from_entries(prs)
    for row in closed_merged:
        url = row.get("pr_url")
        if not url:
            continue
        parsed = parse_pr_url(url)
        if not parsed:
            continue
        repo_path, num = parsed
        repo = row.get("repo") or repo_path
        short = repo.split("/")[-1]
        pr_lookup[f"{short}#{num}".lower()] = url

    failures: list[str] = list(meta.get("failures") or [])
    for row in remediation:
        if row.get("action") == "failed" and row.get("notes"):
            failures.append(str(row["notes"]))

    cves_processed = meta.get("cves_processed")
    if cves_processed is None:
        cves = {r.get("cve_id") for r in remediation if r.get("cve_id")}
        cves_processed = len(cves)

    today = today_iso()
    open_pr_count = len(buckets["draft"]) + len(buckets["awaiting_approval"])
    merged_count = len(buckets["merged"])
    closed_na_count = len(closed_issues)
    closed_merged_count = len(closed_merged)
    closed_toolchain_count = len(closed_toolchain)
    rebuild_count = len(toolchain_rebuilds)

    if issue_count == 0 and not remediation:
        fallback = f"SF CVE fix — {today}: no active vulnerability issues"
        blocks = [
            header_block(f"SF CVE fix — {today}"),
            section_mrkdwn(
                f"{SF_GROUP_LABEL}\n_No active Server Foundation CVE issues._"
            ),
            agent_footer_block(today),
        ]
    else:
        fallback = _fallback_notification_text(
            today=today,
            open_pr_count=open_pr_count,
            merged_count=merged_count,
            closed_merged_count=closed_merged_count,
            closed_na_count=closed_na_count,
            cves_processed=int(cves_processed or 0),
            buckets=buckets,
            closed_toolchain_count=closed_toolchain_count,
        )
        summary_lines = [
            SF_GROUP_LABEL,
            f"*CVEs processed:* {cves_processed or 0}",
        ]
        if issue_count is not None:
            summary_lines.append(f"*Active issues scanned:* {issue_count}")
        if meta.get("comments_posted") is not None:
            summary_lines.append(f"*Jira comments posted:* {meta['comments_posted']}")
        summary_lines.append(
            f"*Open PRs:* {open_pr_count} "
            f"({len(buckets['draft'])} draft · {len(buckets['awaiting_approval'])} ready) · "
            f"*Merged:* {merged_count} · *Jira closed (merged PR):* {closed_merged_count} · "
            f"*Closed (toolchain):* {closed_toolchain_count} · "
            f"*Closed (N/A):* {closed_na_count} · "
            f"*Toolchain rebuilds:* {rebuild_count}"
        )

        blocks: list[dict] = [
            header_block(f"SF CVE fix — {today}"),
            section_mrkdwn("\n".join(summary_lines)),
            {"type": "divider"},
        ]

        _append_pr_section(blocks, "Draft — mark Ready for review", buckets["draft"])
        _append_pr_section(
            blocks, "Ready for review — approve", buckets["awaiting_approval"]
        )
        _append_pr_section(blocks, "Merged this cycle", buckets["merged"])

        if toolchain_rebuilds:
            lines = [_format_toolchain_rebuild_line(r) for r in toolchain_rebuilds]
            blocks.append(
                section_mrkdwn(
                    f"*Toolchain rebuilds* ({rebuild_count})\n" + "\n".join(lines)
                )
            )
            blocks.append({"type": "divider"})

        if closed_merged:
            merged_groups = _aggregate_closed_merged(closed_merged)
            _append_pr_section(
                blocks,
                "Closed this run (merged PR)",
                [g for g in merged_groups if g.get("pr_url")],
            )
            orphan = [g for g in merged_groups if not g.get("pr_url")]
            if orphan:
                orphan_lines = [
                    _format_closed_merged_line(
                        {"issue_key": k, "pr_url": "", "notes": "Fix PR merged"}
                    )
                    for g in orphan
                    for k in g["keys"]
                ]
                blocks.extend(
                    section_mrkdwn_chunks(
                        f"*Closed this run (merged PR, no URL)* "
                        f"({sum(len(g['keys']) for g in orphan)})\n"
                        + "\n".join(orphan_lines)
                    )
                )
                blocks.append({"type": "divider"})

        if closed_toolchain:
            lines = [_format_toolchain_close_line(row) for row in closed_toolchain[:20]]
            blocks.append(
                section_mrkdwn(
                    f"*Closed this run (toolchain verify)* ({closed_toolchain_count})\n"
                    + "\n".join(lines)
                )
            )
            blocks.append({"type": "divider"})

        if closed_issues:
            closed_lines = [_format_closed_na_line(row) for row in closed_issues[:20]]
            blocks.extend(
                section_mrkdwn_chunks(
                    f"*Closed as Not Applicable* ({closed_na_count})\n"
                    + "\n".join(closed_lines)
                )
            )
            blocks.append({"type": "divider"})

        follow_up = _build_follow_up_text(
            buckets,
            meta.get("follow_up") if isinstance(meta.get("follow_up"), str) else None,
            pr_lookup,
        )
        blocks.extend(section_mrkdwn_chunks(f"*Follow-up*\n\n{follow_up}"))

        if failures:
            fail_text = "\n".join(f"• {escape_mrkdwn(f)}" for f in failures[:10])
            blocks.append({"type": "divider"})
            blocks.extend(section_mrkdwn_chunks(f"*Warnings / failures*\n{fail_text}"))

        blocks.append(agent_footer_block(today))

    payload = {"text": fallback, "blocks": blocks}
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)

    print(
        f"Wrote {out_path} "
        f"({open_pr_count} open, {merged_count} merged, "
        f"{closed_merged_count} jira-closed, {closed_toolchain_count} toolchain-closed, "
        f"{closed_na_count} closed N/A, {rebuild_count} rebuilds)"
    )


def truncate_note(text: str, max_len: int = 80) -> str:
    text = text.strip()
    if len(text) <= max_len:
        return text
    return text[: max_len - 1] + "…"


if __name__ == "__main__":
    main()
