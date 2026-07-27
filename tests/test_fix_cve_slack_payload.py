"""Tests for fix-cve Slack payload bucketing (mocked PR state, no gh)."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "workflows" / "fix-cve"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "workflows" / "lib"))

from gh_pr_state import PrState  # noqa: E402

# Import module under test by path
import importlib.util

_spec = importlib.util.spec_from_file_location(
    "generate_slack_payload",
    Path(__file__).resolve().parents[1]
    / "workflows"
    / "fix-cve"
    / "generate_slack_payload.py",
)
_mod = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(_mod)


def _state(url: str, repo: str, num: int, state: str, draft: bool) -> PrState:
    return PrState(
        url=url,
        repo=repo,
        number=num,
        state=state,
        is_draft=draft,
        merged_at="2026-06-22T20:19:32Z" if state == "MERGED" else None,
    )


@patch.object(_mod, "pr_state_from_row")
def test_aggregate_buckets_merged_vs_ready(mock_from_row):
    remediation = [
        {
            "action": "skipped_existing_pr",
            "pr_url": "https://github.com/stolostron/ocm/pull/767",
            "repo": "stolostron/ocm",
            "branch": "backplane-2.8",
            "issue_key": "ACM-1",
        },
        {
            "action": "skipped_existing_pr",
            "pr_url": "https://github.com/stolostron/klusterlet-addon-controller/pull/659",
            "repo": "stolostron/klusterlet-addon-controller",
            "branch": "release-2.13",
            "issue_key": "ACM-2",
        },
    ]

    def side_effect(row):
        url = row["pr_url"]
        if "ocm" in url:
            return _state(url, "stolostron/ocm", 767, "MERGED", False)
        return _state(url, "stolostron/klusterlet-addon-controller", 659, "OPEN", False)

    mock_from_row.side_effect = side_effect
    prs = _mod._aggregate_prs(remediation)
    buckets = _mod._bucket_prs(prs)
    assert len(buckets["merged"]) == 1
    assert len(buckets["awaiting_approval"]) == 1
    assert len(buckets["draft"]) == 0

    follow_up = _mod._derive_follow_up(buckets)
    assert follow_up.startswith("•")
    assert "\n•" in follow_up or follow_up.count("•") == 1
    assert "<https://github.com/stolostron/klusterlet-addon-controller/pull/659|klusterlet-addon-controller#659>" in follow_up
    assert "/approve" in follow_up


def test_follow_up_extra_splits_into_bullets():
    lookup = {
        "multicloud-operators-foundation#1319": "https://github.com/stolostron/multicloud-operators-foundation/pull/1319",
        "klusterlet-addon-controller#659": "https://github.com/stolostron/klusterlet-addon-controller/pull/659",
    }
    extra = (
        "multicloud-operators-foundation#1319 needs /approve; "
        "klusterlet-addon-controller#659 needs prow; "
        "Consider backport PRs for backplane-2.9"
    )
    bullets = _mod._follow_up_extra_bullets(extra, lookup)
    assert len(bullets) == 3
    assert all(b.startswith("• ") for b in bullets)
    assert "multicloud-operators-foundation/pull/1319" in bullets[0]
    assert "backplane-2.9" in bullets[2]


def test_closure_rows_this_run_from_remediation():
    remediation = [
        {
            "issue_key": "ACM-35352",
            "action": "closed_merged_pr",
            "closed_this_run": True,
            "pr_url": "https://github.com/stolostron/ocm/pull/767",
        },
        {
            "issue_key": "ACM-35353",
            "action": "closed_merged_pr",
            "closed_this_run": False,
            "pr_url": "https://github.com/stolostron/ocm/pull/767",
        },
    ]
    rows = _mod._closure_rows_this_run(remediation, {}, "closed_merged_pr")
    assert len(rows) == 1
    assert rows[0]["issue_key"] == "ACM-35352"


def test_closure_rows_this_run_falls_back_to_run_meta():
    remediation = []
    meta = {
        "jira_closed_this_run": [
            {
                "issue_key": "ACM-35352",
                "action": "closed_merged_pr",
                "closed_this_run": True,
                "pr_url": "https://github.com/stolostron/ocm/pull/767",
                "notes": "ocm#767 merged on backplane-2.8",
            }
        ]
    }
    rows = _mod._closure_rows_this_run(remediation, meta, "closed_merged_pr")
    assert len(rows) == 1
    line = _mod._format_closed_merged_line(rows[0])
    assert "ACM-35352" in line
    assert "ocm/pull/767" in line
    assert "ocm #767" in line
    assert line.index("ocm #767") < line.index("ACM-35352")


def test_closure_rows_ignores_legacy_jira_closed_without_flag():
    remediation = [
        {
            "issue_key": "ACM-35352",
            "action": "closed_merged_pr",
            "pr_url": "https://github.com/stolostron/ocm/pull/767",
        }
    ]
    meta = {
        "jira_closed": [
            {
                "issue_key": "ACM-35354",
                "action": "closed_merged_pr",
                "pr_url": "https://github.com/stolostron/clusterlifecycle-state-metrics/pull/642",
            }
        ]
    }
    rows = _mod._closure_rows_this_run(remediation, meta, "closed_merged_pr")
    assert rows == []


def test_aggregate_closed_merged_groups_by_pr():
    rows = [
        {
            "issue_key": f"ACM-{k}",
            "pr_url": "https://github.com/stolostron/ocm/pull/767",
            "repo": "stolostron/ocm",
            "branch": "backplane-2.8",
            "action": "closed_merged_pr",
            "closed_this_run": True,
        }
        for k in (35352, 35353, 35355, 35357, 35358)
    ]
    groups = _mod._aggregate_closed_merged(rows)
    assert len(groups) == 1
    assert len(groups[0]["keys"]) == 5
    line = _mod._format_pr_line(
        groups[0]["pr_url"],
        groups[0]["repo"],
        groups[0]["branch"],
        groups[0]["keys"],
        pr_number=groups[0]["pr_number"],
    )
    assert "ACM-35352" in line
    assert "ACM-35358" in line
    assert "ocm #767" in line


def test_format_pr_line_validates_pr_url():
    line = _mod._format_pr_line(
        "https://github.com/stolostron/ocm/pull/767",
        "stolostron/ocm",
        "backplane-2.8",
        ["ACM-1"],
        pr_number=767,
    )
    assert "<https://github.com/stolostron/ocm/pull/767|ocm #767>" in line


def test_append_pr_section_groups_by_cve_with_links():
    items = [
        {
            "pr_url": "https://github.com/stolostron/ocm/pull/797",
            "repo": "stolostron/ocm",
            "branch": "backplane-2.8",
            "keys": ["ACM-37693"],
            "cve_ids": ["CVE-2026-27145"],
            "pr_number": 797,
        },
        {
            "pr_url": "https://github.com/stolostron/ocm/pull/799",
            "repo": "stolostron/ocm",
            "branch": "backplane-2.11",
            "keys": ["ACM-37541"],
            "cve_ids": ["CVE-2026-33814"],
            "pr_number": 799,
        },
    ]
    blocks: list[dict] = []
    _mod._append_pr_section(blocks, "Draft — mark Ready for review", items)
    assert blocks[0]["type"] == "section"
    text = blocks[0]["text"]["text"]
    assert "*CVE-2026-27145*" in text
    assert "*CVE-2026-33814*" in text
    assert "<https://github.com/stolostron/ocm/pull/797|ocm #797>" in text
    assert "<https://github.com/stolostron/ocm/pull/799|ocm #799>" in text
    assert blocks[1]["type"] == "divider"


def test_fallback_notification_text_includes_full_pr_urls():
    buckets = {
        "draft": [
            {
                "pr_url": "https://github.com/stolostron/ocm/pull/797",
                "cve_ids": ["CVE-2026-27145"],
            }
        ],
        "awaiting_approval": [],
        "merged": [],
        "closed": [],
    }
    text = _mod._fallback_notification_text(
        today="2026-07-27",
        open_pr_count=1,
        merged_count=0,
        closed_merged_count=0,
        closed_na_count=0,
        cves_processed=1,
        buckets=buckets,
    )
    assert "https://github.com/stolostron/ocm/pull/797" in text
    assert "CVE-2026-27145" in text
    assert "Draft PRs:" in text


def test_aggregate_prs_collects_cve_ids():
    remediation = [
        {
            "action": "pr_opened",
            "pr_url": "https://github.com/stolostron/ocm/pull/797",
            "repo": "stolostron/ocm",
            "branch": "backplane-2.8",
            "issue_key": "ACM-37693",
            "cve_id": "CVE-2026-27145",
            "pr_state": "OPEN",
            "is_draft": True,
        },
        {
            "action": "pr_opened",
            "pr_url": "https://github.com/stolostron/ocm/pull/797",
            "repo": "stolostron/ocm",
            "branch": "backplane-2.8",
            "issue_key": "ACM-37686",
            "cve_id": "CVE-2026-27145",
            "pr_state": "OPEN",
            "is_draft": True,
        },
    ]
    with patch.object(_mod, "pr_state_from_row") as mock_from_row:
        mock_from_row.return_value = _state(
            "https://github.com/stolostron/ocm/pull/797",
            "stolostron/ocm",
            797,
            "OPEN",
            True,
        )
        prs = _mod._aggregate_prs(remediation)
    entry = prs["https://github.com/stolostron/ocm/pull/797"]
    assert entry["cve_ids"] == ["CVE-2026-27145"]
    assert set(entry["keys"]) == {"ACM-37693", "ACM-37686"}


def test_format_pr_line_invalid_url_falls_back_to_plain_text():
    line = _mod._format_pr_line(
        "https://evil.example|<!channel>",
        "stolostron/ocm",
        "backplane-2.8",
        ["ACM-1"],
        pr_number=767,
    )
    assert "<https://" not in line.split("—")[0]
    assert "ocm #767" in line
    assert "<!channel>" not in line


def test_format_closed_merged_line_invalid_url_falls_back_to_plain_text():
    line = _mod._format_closed_merged_line(
        {
            "issue_key": "ACM-1",
            "pr_url": "not-a-github-pr|@channel>",
            "repo": "stolostron/ocm",
            "branch": "backplane-2.8",
        }
    )
    assert "<https://" not in line.split("—")[0]
    assert "ACM-1" in line


def test_format_closed_merged_line_escapes_malicious_issue_key():
    line = _mod._format_closed_merged_line(
        {
            "issue_key": "<!channel>",
            "pr_url": "",
            "notes": "Fix PR merged",
        }
    )
    assert "<!channel>" not in line
    assert "&lt;!channel&gt;" in line


def test_format_closed_na_line_escapes_malicious_issue_key():
    line = _mod._format_closed_na_line(
        {
            "issue_key": "ACM-1|<!here>",
            "notes": "Not applicable",
        }
    )
    assert "<!here>" not in line
    assert "redhat.atlassian.net/browse/ACM-1" in line


def test_aggregate_toolchain_rebuilds_collapses_by_commit():
    remediation = [
        {
            "action": "toolchain_rebuild",
            "cve_id": "CVE-2026-42504",
            "repo": "stolostron/ocm",
            "branch": "backplane-2.11",
            "commit": "6031040741660bca3ae07df68240cae9c26af5c6",
            "commit_url": (
                "https://github.com/stolostron/ocm/commit/"
                "6031040741660bca3ae07df68240cae9c26af5c6"
            ),
            "issue_key": "ACM-37383",
            "images": ["multicluster-engine/addon-manager-rhel9"],
        },
        {
            "action": "skipped_existing_rebuild",
            "cve_id": "CVE-2026-42504",
            "repo": "stolostron/ocm",
            "branch": "backplane-2.11",
            "commit": "6031040741660bca3ae07df68240cae9c26af5c6",
            "commit_url": (
                "https://github.com/stolostron/ocm/commit/"
                "6031040741660bca3ae07df68240cae9c26af5c6"
            ),
            "issue_keys": ["ACM-37384", "ACM-37395"],
            "images": ["multicluster-engine/placement-rhel9"],
        },
    ]
    groups = _mod._aggregate_toolchain_rebuilds(remediation)
    assert len(groups) == 1
    assert groups[0]["repo"] == "stolostron/ocm"
    assert set(groups[0]["issue_keys"]) == {"ACM-37383", "ACM-37384", "ACM-37395"}
    assert len(groups[0]["images"]) == 2
    line = _mod._format_toolchain_rebuild_line(groups[0])
    assert "stolostron/ocm" in line
    assert "6031040" in line
    assert "ACM-37383" in line


def test_format_toolchain_close_line():
    line = _mod._format_toolchain_close_line(
        {
            "issue_key": "ACM-37577",
            "action": "toolchain_verify_close",
            "closed_this_run": True,
            "go_ver": "1.25.11",
            "fix_version": "MCE 2.11.5",
        }
    )
    assert "ACM-37577" in line
    assert "go1.25.11" in line
    assert "MCE 2.11.5" in line


def test_main_includes_toolchain_sections(tmp_path):
    rem = [
        {
            "action": "toolchain_rebuild",
            "cve_id": "CVE-2026-39825",
            "repo": "stolostron/ocm",
            "branch": "backplane-2.11",
            "commit": "abc1234deadbeef",
            "commit_url": "https://github.com/stolostron/ocm/commit/abc1234deadbeef",
            "issue_keys": ["ACM-37577"],
        },
        {
            "action": "toolchain_verify_close",
            "cve_id": "CVE-2026-39825",
            "issue_key": "ACM-37577",
            "closed_this_run": True,
            "go_ver": "1.25.11",
            "fix_version": "MCE 2.11.5",
        },
    ]
    rem_path = tmp_path / "remediation.json"
    rem_path.write_text(json.dumps(rem), encoding="utf-8")
    out_path = tmp_path / "slack_payload.json"
    with patch.object(_mod, "pr_state_from_row", return_value=None):
        with patch.object(sys, "argv", ["gen", str(tmp_path), str(out_path)]):
            _mod.main()
    payload = json.loads(out_path.read_text(encoding="utf-8"))
    parts: list[str] = [str(payload.get("text") or "")]
    for block in payload["blocks"]:
        text = block.get("text")
        if isinstance(text, dict):
            parts.append(str(text.get("text") or ""))
        elif isinstance(text, str):
            parts.append(text)
    joined = "\n".join(parts)
    assert "Toolchain rebuilds" in joined
    assert "Closed this run (toolchain verify)" in joined
    assert "*Toolchain rebuilds:* 1" in joined
    assert "abc1234" in joined
