"""Unit tests for verify-konflux-image-go helpers (no skopeo/network)."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "verify_konflux_image_go",
    Path(__file__).resolve().parents[1]
    / ".claude"
    / "skills"
    / "sfa-cve-toolchain-verify"
    / "verify-konflux-image-go.py",
)
_mod = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
sys.modules["verify_konflux_image_go"] = _mod
_spec.loader.exec_module(_mod)


def test_strip_dot_slash_preserves_wh_prefix():
    assert _mod._strip_dot_slash(".wh.work") == ".wh.work"
    assert _mod._strip_dot_slash("./.wh.work") == ".wh.work"
    assert _mod._strip_dot_slash("././build/foo") == "build/foo"
    # str.lstrip("./") would wrongly turn this into "wh.work"
    assert ".wh.work".lstrip("./") == "wh.work"


def test_apply_whiteout_root_level_marker(tmp_path: Path):
    victim = tmp_path / "work"
    victim.write_bytes(b"x" * 10)
    assert _mod._apply_whiteout(tmp_path, ".wh.work") is True
    assert not victim.exists()


def test_apply_whiteout_rejects_traversal(tmp_path: Path):
    assert _mod._apply_whiteout(tmp_path, "../.wh.escape") is True
    assert _mod._apply_whiteout(tmp_path, "/etc/.wh.passwd") is True


def test_validate_image_ref_allowlist():
    good = (
        "quay.io/redhat-user-workloads/crt-redhat-acm-tenant/"
        "work-mce-211:6031040741660bca3ae07df68240cae9c26af5c6"
    )
    assert _mod.validate_image_ref(good) is None
    assert _mod.validate_image_ref("docker.io/library/busybox:latest") is not None
    assert _mod.validate_image_ref(
        "quay.io/redhat-user-workloads/crt-redhat-acm-tenant/work-mce-211:latest"
    ) is not None
    assert _mod.validate_image_ref("") is not None


def test_verify_image_rejects_disallowed_ref_before_skopeo():
    result = _mod.verify_image("evil.example/x:deadbeef")
    assert result["ok"] is False
    assert "not allowed" in result["error"]


def test_find_binary_rejects_dotdot_hints(tmp_path: Path):
    # Host file outside root — must not be returned via ../ hint
    outside = tmp_path / "outside.bin"
    outside.write_bytes(b"\x7fELF" + b"x" * 1_000_100)
    root = tmp_path / "root"
    root.mkdir()
    inside = root / "work"
    inside.write_bytes(b"\x7fELF" + b"y" * 1_000_100)
    assert _mod.find_binary(root, ["../outside.bin"]) is None
    assert _mod.find_binary(root, ["work"]) == inside.resolve()
    assert _mod.find_binary(root, ["/work"]) == inside.resolve()


def test_pick_latest_sha_tag_by_last_modified():
    tags = [
        {"name": "abc1234", "last_modified": "2026-01-01T00:00:00Z"},
        {
            "name": "01c1755e41350091a381719553424e60d31b4173",
            "last_modified": "2026-08-21T18:00:49Z",
        },
        {"name": "latest", "last_modified": "2026-09-01T00:00:00Z"},
    ]
    picked = _mod.pick_latest_sha_tag(tags)
    assert picked is not None
    assert picked["name"] == "01c1755e41350091a381719553424e60d31b4173"


def test_pick_latest_sha_tag_empty():
    assert _mod.pick_latest_sha_tag([]) is None
    assert _mod.pick_latest_sha_tag([{"name": "latest"}]) is None


def test_fix_version_from_label_no_mce_default():
    assert _mod.fix_version_from_label("v2.11.5", "mce-2.11") == "MCE 2.11.5"
    assert _mod.fix_version_from_label("v2.16.3", "[rhacm-2.16]") == "ACM 2.16.3"
    assert _mod.fix_version_from_label("v2.11.5", None) is None
    assert _mod.fix_version_from_label("v2.11.5", "") is None


def test_validate_jira_issue_key_allowlist():
    assert _mod.validate_jira_issue_key("ACM-37547") == "ACM-37547"
    assert _mod.validate_jira_issue_key("acm-40097") == "ACM-40097"
    assert _mod.validate_jira_issue_key("  ACM-1  ") == "ACM-1"


def test_validate_jira_issue_key_rejects_unsafe():
    for bad in (
        "",
        "ACM",
        "ACM-",
        "37547",
        "ACM-37547/extra",
        "../ACM-37547",
        "ACM-37547?fields=summary",
        "ACM-37547&x=1",
        "ACM-37547#fragment",
        "ACM/37547",
        "ACM\\37547",
    ):
        assert _mod.validate_jira_issue_key(bad) is None


def test_fetch_jira_issue_rejects_invalid_key():
    assert _mod.fetch_jira_issue("ACM-37547/evil") is None


def test_resolve_latest_quay_tag_rejects_prefix_bypass():
    prefix = _mod.ALLOWED_IMAGE_PREFIX
    bad = f"{prefix.rstrip('/')}-evil/work-mce-211"
    try:
        _mod.resolve_latest_quay_tag(bad)
        raise AssertionError("expected ValueError for tenant prefix bypass")
    except ValueError as exc:
        assert "not allowed" in str(exc)


def test_apply_arch_mismatch_failure_not_cleared_by_later_checks():
    result = {"ok": True, "go_ver": "1.25.11"}
    _mod.apply_arch_mismatch(result, "ppc64le", "amd64")
    result["meets_min"] = True
    result["ok"] = result["ok"] and result["meets_min"]
    result["ok"] = result["ok"] and True  # assembly check pass
    assert result["ok"] is False
    assert "arch_warning" in result


def test_apply_arch_mismatch_no_op_when_archs_match():
    result = {"ok": True}
    _mod.apply_arch_mismatch(result, "amd64", "amd64")
    assert result["ok"] is True
    assert "arch_warning" not in result
