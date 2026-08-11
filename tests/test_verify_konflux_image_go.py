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


def test_fix_version_from_label_no_mce_default():
    assert _mod.fix_version_from_label("v2.11.5", "mce-2.11") == "MCE 2.11.5"
    assert _mod.fix_version_from_label("v2.16.3", "[rhacm-2.16]") == "ACM 2.16.3"
    assert _mod.fix_version_from_label("v2.11.5", None) is None
    assert _mod.fix_version_from_label("v2.11.5", "") is None
