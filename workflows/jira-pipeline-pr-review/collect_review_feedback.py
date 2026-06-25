#!/usr/bin/env python3
"""Enrich jira-pipeline PRs with review feedback state from GitHub API.

Usage:
    python3 collect_review_feedback.py pipeline_prs.json review_candidates.json

Input:  JSON array from filter_pipeline_prs.jq
Output: JSON object { candidates: [...], pick: <first or null> }

A PR is a candidate when it has unresolved **code-fix** feedback from CodeRabbit,
human reviewers, or CHANGES_REQUESTED reviews that request code changes.
Non-code comments (process, CI groom, questions) are ignored.
"""

from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any

# Reviewers whose feedback the agent should address.
ACTIONABLE_REVIEWER_PREFIXES = (
    "coderabbit",
    "chatgpt-codex",
)

# Bots / automation to ignore as feedback sources.
IGNORED_REVIEWERS = frozenset({
    "acm-agent",
    "app/acm-agent",
    "github-actions",
    "github-actions[bot]",
    "openshift-ci",
    "openshift-ci-robot",
    "openshift-ci[bot]",
    "stolostron-bot",
    "red-hat-konflux",
    "red-hat-konflux[bot]",
    "dependabot",
    "dependabot[bot]",
    "prow",
    "prow[bot]",
})

# Prow/org-member one-liners — not code review feedback.
_PROW_COMMAND_RE = __import__("re").compile(
    r"^/(ok-to-test|retest|retest-required|test|approve|approve cancel|lgtm|hold)\b",
    __import__("re").IGNORECASE,
)

# Acknowledgments and non-actionable one-liners on inline threads.
_NON_CODE_INLINE_RE = __import__("re").compile(
    r"^(?:lgtm|looks good|nice|thanks|thank you|\+1|ack|done|will take a look)[\.!?\s]*$",
    __import__("re").IGNORECASE,
)

# Process / grooming language — not code fixes.
_PROCESS_RE = __import__("re").compile(
    r"(?:/ok-to-test|/retest|/lgtm|/hold|"
    r"\bmark (?:this )?(?:pr )?ready\b|"
    r"\bupdate (?:the )?(?:pr )?(?:title|description)\b|"
    r"\badd (?:the )?labels?\b|"
    r"\bplease rebase\b|\bneeds rebase\b|"
    r"\bmerge when\b|\brelease notes?\b|\bchangelog\b|"
    r"\bjira (?:ticket|issue|link)\b)",
    __import__("re").IGNORECASE,
)

# CI / build failure notices without a concrete code fix request.
_CI_ONLY_RE = __import__("re").compile(
    r"(?:\b(?:ci|tests?|build|prow)\s+(?:failed|failing|red|broken)\b|"
    r"\bplease\s+(?:re)?run(?:\s+(?:the\s+)?(?:tests?|ci))?\b|"
    r"\b(?:re)?test(?:\s+required)?\b)",
    __import__("re").IGNORECASE,
)

# Strong code-change signals — avoid bare action verbs (change/update/add/remove)
# that overlap with process/grooming language; _PROCESS_RE handles those cases.
_STRONG_CODE_FIX_RE = __import__("re").compile(
    r"(?:```(?:suggestion)?|suggested change|diff --git|"
    r"\b(?:fix(?:ed|es)?|handle(?:s|d)?|return(?:s|ed)?|"
    r"error|nil|null|panic|race|leak|bug|refactor|rename|extract|inline|"
    r"assert|mock|coverage|(?:unit|regression) test|add (?:a )?test)\b)",
    __import__("re").IGNORECASE,
)

# Question-only comments with no fix request.
_QUESTION_ONLY_RE = __import__("re").compile(
    r"^(?:is this|why (?:is|does|did)|what (?:is|does|did)|can you explain|"
    r"could you explain|does this|should this)\b.*\?\s*$",
    __import__("re").IGNORECASE | __import__("re").DOTALL,
)


def _run_gh(args: list[str]) -> Any:
    result = subprocess.run(
        ["gh", *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "gh failed")
    return json.loads(result.stdout or "null")


def _is_ignored(login: str) -> bool:
    base = login.removesuffix("[bot]").lower()
    if login.lower() in IGNORED_REVIEWERS or base in IGNORED_REVIEWERS:
        return True
    return False


def _is_coderabbit_reviewer(login: str) -> bool:
    if _is_ignored(login):
        return False
    low = login.lower()
    return any(low.startswith(p) for p in ACTIONABLE_REVIEWER_PREFIXES)


def _is_actionable_reviewer(login: str) -> bool:
    if _is_ignored(login):
        return False
    low = login.lower()
    if _is_coderabbit_reviewer(login):
        return True
    # Human reviewers — inline threads and formal reviews only (not top-level comments).
    return "[bot]" not in low and low != "acm-agent"


def _is_prow_command(body: str) -> bool:
    first_line = body.strip().splitlines()[0] if body.strip() else ""
    return bool(_PROW_COMMAND_RE.match(first_line.strip()))


def _is_code_fix_comment(body: str, *, is_inline: bool = False) -> bool:
    """True when the comment requests a code or test change in the PR diff."""
    text = body.strip()
    if not text or _is_prow_command(text):
        return False
    if _NON_CODE_INLINE_RE.match(text):
        return False
    if _QUESTION_ONLY_RE.match(text) and "```" not in text:
        return False

    has_code_signal = bool(_STRONG_CODE_FIX_RE.search(text))
    has_process = bool(_PROCESS_RE.search(text))
    is_ci_only = bool(_CI_ONLY_RE.search(text))

    if is_ci_only and not has_code_signal:
        return False

    if is_inline:
        # Inline threads attach to diff lines; treat as code-fix unless clearly not.
        if has_process and not has_code_signal:
            return False
        if is_ci_only and not has_code_signal:
            return False
        if text.endswith("?") and not has_code_signal:
            return False
        return True

    # Top-level / review summaries need explicit code-fix language.
    if has_process:
        return False
    return has_code_signal


def _is_actionable_issue_comment(login: str, body: str) -> bool:
    """Top-level PR comments: code-fix content from non-ignored reviewers."""
    if not body.strip() or _is_prow_command(body):
        return False
    if _is_ignored(login):
        return False
    return _is_code_fix_comment(body, is_inline=False)


def _parse_iso(ts: str) -> datetime:
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    return datetime.fromisoformat(ts).astimezone(timezone.utc)


_GRAPHQL_PAGE_SIZE = 100

_REVIEW_THREADS_QUERY = f"""
query($owner: String!, $name: String!, $number: Int!, $after: String) {{
  repository(owner: $owner, name: $name) {{
    pullRequest(number: $number) {{
      reviewThreads(first: {_GRAPHQL_PAGE_SIZE}, after: $after) {{
        pageInfo {{ hasNextPage endCursor }}
        nodes {{
          id
          isResolved
          comments(first: {_GRAPHQL_PAGE_SIZE}) {{
            pageInfo {{ hasNextPage endCursor }}
            nodes {{
              author {{ login }}
              body
              createdAt
            }}
          }}
        }}
      }}
    }}
  }}
}}
"""

_THREAD_COMMENTS_QUERY = f"""
query($threadId: ID!, $after: String) {{
  node(id: $threadId) {{
    ... on PullRequestReviewThread {{
      comments(first: {_GRAPHQL_PAGE_SIZE}, after: $after) {{
        pageInfo {{ hasNextPage endCursor }}
        nodes {{
          author {{ login }}
          body
          createdAt
        }}
      }}
    }}
  }}
}}
"""


def _run_graphql(query: str, variables: dict[str, Any]) -> dict[str, Any]:
    args = ["api", "graphql", "-f", f"query={query}"]
    for key, value in variables.items():
        if value is None:
            continue
        flag = "-F" if isinstance(value, int) else "-f"
        args.extend([flag, f"{key}={value}"])
    data = _run_gh(args)
    if data.get("errors"):
        raise RuntimeError(str(data["errors"]))
    return data.get("data") or {}


def _paginate_thread_comments(thread_id: str, comments: dict[str, Any]) -> list[dict[str, Any]]:
    nodes = list(comments.get("nodes") or [])
    page_info = comments.get("pageInfo") or {}
    after = page_info.get("endCursor")
    while page_info.get("hasNextPage"):
        data = _run_graphql(_THREAD_COMMENTS_QUERY, {"threadId": thread_id, "after": after})
        thread_comments = (
            data.get("node", {}).get("comments")
            if data.get("node")
            else None
        )
        if not thread_comments:
            break
        nodes.extend(thread_comments.get("nodes") or [])
        page_info = thread_comments.get("pageInfo") or {}
        after = page_info.get("endCursor")
    return nodes


def _fetch_review_threads(repo: str, number: int) -> list[dict[str, Any]]:
    owner, name = repo.split("/", 1)
    all_threads: list[dict[str, Any]] = []
    thread_after: str | None = None

    while True:
        data = _run_graphql(
            _REVIEW_THREADS_QUERY,
            {"owner": owner, "name": name, "number": number, "after": thread_after},
        )
        review_threads = (
            data.get("repository", {})
            .get("pullRequest", {})
            .get("reviewThreads")
        )
        if not review_threads:
            break

        for thread in review_threads.get("nodes") or []:
            comment_nodes = _paginate_thread_comments(
                thread["id"],
                thread.get("comments") or {},
            )
            all_threads.append({
                "isResolved": thread.get("isResolved"),
                "comments": {"nodes": comment_nodes},
            })

        page_info = review_threads.get("pageInfo") or {}
        if not page_info.get("hasNextPage"):
            break
        thread_after = page_info.get("endCursor")

    return all_threads


def _fetch_reviews(repo: str, number: int) -> list[dict[str, Any]]:
    return _run_gh([
        "api", f"repos/{repo}/pulls/{number}/reviews",
        "--paginate",
    ])


def _fetch_issue_comments(repo: str, number: int) -> list[dict[str, Any]]:
    return _run_gh([
        "api", f"repos/{repo}/issues/{number}/comments",
        "--paginate",
    ])


def _latest_review_per_reviewer(reviews: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """Keep only each reviewer's most recent review by submitted_at."""
    latest: dict[str, dict[str, Any]] = {}
    for review in reviews:
        login = (review.get("user") or {}).get("login", "")
        submitted = review.get("submitted_at")
        if not login or not submitted:
            continue
        prev = latest.get(login)
        if prev is None or _parse_iso(submitted) > _parse_iso(prev["submitted_at"]):
            latest[login] = review
    return latest


def _latest_feedback_at(pr: dict[str, Any]) -> str | None:
    """Return ISO timestamp of newest unresolved code-fix feedback, if any."""
    repo = pr["repo"]
    number = pr["number"]
    latest: datetime | None = None

    threads = _fetch_review_threads(repo, number)
    has_unresolved_threads = any(not t.get("isResolved") for t in threads)
    review_decision = pr.get("review_decision") or "NONE"

    # Review summary bodies are stale once approved with no open threads.
    include_review_summaries = (
        review_decision == "CHANGES_REQUESTED" or has_unresolved_threads
    )

    if include_review_summaries:
        for review in _latest_review_per_reviewer(_fetch_reviews(repo, number)).values():
            login = (review.get("user") or {}).get("login", "")
            state = review.get("state", "")
            if state in ("APPROVED", "DISMISSED"):
                continue
            if state not in ("CHANGES_REQUESTED", "COMMENTED"):
                continue
            if not _is_actionable_reviewer(login):
                continue
            body = (review.get("body") or "").strip()
            if state == "COMMENTED" and not body:
                continue
            if _is_prow_command(body):
                continue
            if not _is_code_fix_comment(body, is_inline=False):
                continue
            submitted = review.get("submitted_at")
            if submitted:
                dt = _parse_iso(submitted)
                if latest is None or dt > latest:
                    latest = dt

    for thread in threads:
        if thread.get("isResolved"):
            continue
        for comment in thread.get("comments", {}).get("nodes", []):
            login = (comment.get("author") or {}).get("login", "")
            body = (comment.get("body") or "").strip()
            if not body or not _is_actionable_reviewer(login):
                continue
            if not _is_code_fix_comment(body, is_inline=True):
                continue
            created = comment.get("createdAt")
            if created:
                dt = _parse_iso(created)
                if latest is None or dt > latest:
                    latest = dt

    # Top-level PR comments from reviewers (e.g. CodeRabbit summary)
    for comment in _fetch_issue_comments(repo, number):
        login = (comment.get("user") or {}).get("login", "")
        body = (comment.get("body") or "").strip()
        if not _is_actionable_issue_comment(login, body):
            continue
        created = comment.get("created_at")
        if created:
            dt = _parse_iso(created)
            if latest is None or dt > latest:
                latest = dt

    return latest.isoformat() if latest else None


def _needs_feedback(pr: dict[str, Any]) -> tuple[bool, str, str | None]:
    """Return (needs_action, reason, latest_feedback_at)."""
    latest = _latest_feedback_at(pr)
    if latest:
        return True, "unresolved_code_fix_feedback", latest

    return False, "no_code_fix_feedback", None


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <pipeline_prs.json> <out.json>", file=sys.stderr)
        return 2

    with open(sys.argv[1], encoding="utf-8") as f:
        pipeline_prs = json.load(f)

    candidates: list[dict[str, Any]] = []
    errors: list[dict[str, str]] = []

    for pr in pipeline_prs:
        try:
            needs, reason, latest_at = _needs_feedback(pr)
            if needs:
                enriched = {**pr, "feedback_reason": reason, "latest_feedback_at": latest_at}
                candidates.append(enriched)
        except Exception as exc:  # noqa: BLE001 — collect per-PR errors for summary
            errors.append({
                "repo": pr.get("repo", "?"),
                "number": str(pr.get("number", "?")),
                "error": str(exc),
            })

    # Oldest feedback first — clear long-standing review queues before newer PRs.
    candidates.sort(key=lambda c: c.get("latest_feedback_at") or c.get("created_at") or "")

    out = {
        "candidates": candidates,
        "pick": candidates[0] if candidates else None,
        "errors": errors,
    }

    with open(sys.argv[2], "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)
        f.write("\n")

    print(
        f"Pipeline PRs scanned: {len(pipeline_prs)}; "
        f"candidates: {len(candidates)}; errors: {len(errors)}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
