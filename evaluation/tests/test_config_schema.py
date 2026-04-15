"""Validate config file schemas on every push.

Catches the class of bug where rag_assets.lock.json points to a deleted/renamed
release, eval_config.json is missing a required key, or runtime_config.json has
a malformed value — all of which would silently break the app or eval harness.
"""

import json
import re
from pathlib import Path

CONFIG_DIR = Path(__file__).parents[2] / "config"


# ── rag_assets.lock.json ─────────────────────────────────────────────────────

def _lock() -> dict:
    return json.loads((CONFIG_DIR / "rag_assets.lock.json").read_text())


def test_lock_parses_as_json():
    _lock()  # raises if malformed


def test_lock_bundle_version_format():
    version = _lock()["bundle_version"]
    assert re.fullmatch(r"v\d+\.\d+\.\d+(-\w+(\.\w+)*)?", version), (
        f"bundle_version '{version}' does not match vX.Y.Z[-prerelease]"
    )


def test_lock_bundle_url_contains_version():
    lock = _lock()
    assert lock["bundle_version"] in lock["bundle_url"], (
        f"bundle_url does not contain bundle_version '{lock['bundle_version']}'"
    )


def test_lock_manifest_sha256_is_64_hex():
    sha = _lock()["manifest_sha256"]
    assert re.fullmatch(r"[0-9a-f]{64}", sha), (
        f"manifest_sha256 '{sha}' is not a valid 64-char lowercase hex string"
    )


def test_lock_chunk_count_positive():
    assert _lock()["chunk_count"] > 0


def test_lock_source_count_positive():
    assert _lock()["source_count"] > 0


def test_lock_producer_commit_is_hex():
    commit = _lock()["producer_commit"]
    assert re.fullmatch(r"[0-9a-f]{40}", commit), (
        f"producer_commit '{commit}' is not a 40-char hex SHA"
    )


# ── eval_config.json ─────────────────────────────────────────────────────────

def _evalcfg() -> dict:
    return json.loads((CONFIG_DIR / "eval_config.json").read_text())


def test_evalcfg_parses_as_json():
    _evalcfg()


def test_evalcfg_required_keys():
    cfg = _evalcfg()
    for key in ("n_ctx", "max_tokens", "judge_model", "judge_temperature"):
        assert key in cfg, f"eval_config.json missing required key '{key}'"


def test_evalcfg_n_ctx_positive_int():
    assert isinstance(_evalcfg()["n_ctx"], int) and _evalcfg()["n_ctx"] > 0


def test_evalcfg_judge_temperature_in_range():
    t = _evalcfg()["judge_temperature"]
    assert 0.0 <= t <= 2.0, f"judge_temperature {t} out of expected range [0, 2]"


# ── runtime_config.json ──────────────────────────────────────────────────────

def _runtime() -> dict:
    return json.loads((CONFIG_DIR / "runtime_config.json").read_text())


def test_runtime_parses_as_json():
    _runtime()


def test_runtime_required_keys():
    cfg = _runtime()
    assert "generation" in cfg
    assert "retrieval" in cfg
    assert "context_injection" in cfg


def test_runtime_generation_params():
    gen = _runtime()["generation"]
    assert 0.0 < gen["temperature"] <= 2.0
    assert 0.0 < gen["top_p"] <= 1.0
    assert isinstance(gen["top_k"], int) and gen["top_k"] > 0


def test_runtime_retrieval_top_k_positive():
    assert _runtime()["retrieval"]["top_k"] > 0


def test_runtime_context_injection_labels_nonempty():
    ci = _runtime()["context_injection"]
    for key in ("context_label_en", "question_label_en"):
        assert ci.get(key, "").strip(), f"context_injection.{key} is empty"
