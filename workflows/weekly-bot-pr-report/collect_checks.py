#!/usr/bin/env python3
"""Phase 2b: Collect CI check results for each bot PR.

Usage:
    python3 workflows/weekly-bot-pr-report/collect_checks.py <bot_prs.json> <output.json>

Input:  Filtered bot PR JSON (output of process_bot_prs.jq)
Output: Same JSON array with check results added per PR:
    .check_status: "all_passed" | "has_failures" | "all_pending" | "mixed" | "no_checks"
    .failed_checks: ["ci/prow/images", "ci/prow/e2e", ...]
    .all_checks: [{name, bucket, link}, ...]
"""
import json
import subprocess
import sys


# Checks to exclude from pass/fail classification
EXCLUDED_CHECKS = {"tide", "SonarCloud Code Analysis"}


def get_pr_checks(repo, pr_number):
    """Run gh pr checks and return parsed check results."""
    try:
        result = subprocess.run(
            ["gh", "pr", "checks", str(pr_number), "-R", repo,
             "--json", "name,bucket,link"],
            capture_output=True, text=True, timeout=30
        )
    except subprocess.TimeoutExpired:
        return []

    # gh pr checks exits 1 when checks have failures — still has valid JSON
    output = result.stdout.strip()
    if not output:
        return []

    try:
        return json.loads(output)
    except json.JSONDecodeError:
        return []


def classify_checks(checks):
    """Classify PR check status, excluding tide and SonarCloud."""
    relevant = [c for c in checks if c.get("name") not in EXCLUDED_CHECKS]

    if not relevant:
        return "no_checks", []

    buckets = [c.get("bucket", "") for c in relevant]
    failed = [c["name"] for c in relevant if c.get("bucket") == "fail"]

    if all(b == "pass" for b in buckets):
        return "all_passed", []
    if all(b == "pending" for b in buckets):
        return "all_pending", []
    if failed:
        return "has_failures", failed
    # Mix of pass and pending (no failures)
    return "mixed", []


def main():
    if len(sys.argv) < 3:
        print("Usage: collect_checks.py <bot_prs.json> <output.json>", file=sys.stderr)
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2]

    with open(input_file, 'r') as f:
        prs = json.load(f)

    total = len(prs)
    for i, pr in enumerate(prs):
        repo = pr["repo"]
        number = pr["number"]
        print(f"[{i+1}/{total}] Checking {repo}#{number}...", file=sys.stderr)

        checks = get_pr_checks(repo, number)
        check_status, failed_checks = classify_checks(checks)

        pr["check_status"] = check_status
        pr["failed_checks"] = failed_checks
        pr["all_checks"] = checks

    with open(output_file, 'w') as f:
        json.dump(prs, f, indent=2, ensure_ascii=False)

    print(f"Check results written to {output_file}", file=sys.stderr)


if __name__ == '__main__':
    main()
