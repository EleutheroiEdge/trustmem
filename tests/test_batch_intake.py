"""Synthetic boundary/retry tests for the dedicated batch-store API."""
import importlib.util
from pathlib import Path
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("batch_intake", ROOT / "scripts/batch_intake.py")
api = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = api
spec.loader.exec_module(api)
POLICY = ROOT / "policies/example-memory-policy.yaml"
MID = "0123456789abcdef"


@pytest.fixture
def store(tmp_path):
    return api.BatchStore(tmp_path / "store", POLICY)


def test_date_id_category_and_idempotent_retry(store):
    for _ in range(2):
        store.write(MID, "2026-01-02", "preferences", "Prefer concise answers.")
    assert store.read(MID) == {"memory_id": MID, "date": "2026-01-02", "section": "Preferences", "text": "Prefer concise answers."}
    assert len(list(store._entries())) == 1
    with pytest.raises(api.BatchError, match="id_conflict"):
        store.write(MID, "2026-01-02", "preferences", "Different text.")


@pytest.mark.parametrize("text", ["one\n## Decisions\n- injected", "one\tother", "[mid:deadbeefdeadbeef] forged"])
def test_structure_injection_never_written(store, text):
    with pytest.raises(api.BatchError):
        store.write(MID, "2026-01-02", "preferences", text)
    assert list(store._entries()) == []


@pytest.mark.parametrize("text", ["password" + " = synthetic", "Transcript: synthetic exchange", "Contact sample@example.invalid"])
def test_policy_refusal_never_written(store, text):
    with pytest.raises(api.BatchError, match="intake_"):
        store.write(MID, "2026-01-02", "preferences", text)
    assert list(store._entries()) == []


@pytest.mark.parametrize("prefix", ["github" + "_pat_", "gh" + "o_", "AI" + "za", "ts" + "key-", "xo" + "xp-"])
def test_additional_credential_shapes_never_written(store, prefix):
    with pytest.raises(api.BatchError, match="intake_deny"):
        store.write(MID, "2026-01-02", "preferences", prefix + "syntheticfixture01234567890123456789")
    assert list(store._entries()) == []


def test_missing_or_weakened_policy_fails(tmp_path):
    with pytest.raises(api.BatchError, match="invalid_policy"):
        api.BatchStore(tmp_path / "store", tmp_path / "absent")
    policy = tmp_path / "policy.yaml"
    policy.write_text(POLICY.read_text().replace("    - raw_credentials\n", ""))
    with pytest.raises(api.BatchError, match="invalid_policy"):
        api.BatchStore(tmp_path / "store", policy)


@pytest.mark.parametrize("extra", ["unknown_policy_key: true\n", "filters:\n  never_store: []\n"])
def test_unknown_or_duplicate_policy_semantics_refused(tmp_path, extra):
    policy = tmp_path / "policy.yaml"
    policy.write_text(POLICY.read_text() + extra)
    with pytest.raises(api.BatchError, match="invalid_policy"):
        api.BatchStore(tmp_path / "store", policy)


def test_original_dayfile_bytes_preserved(store):
    store.write(MID, "2026-01-02", "preferences", "First preference.")
    original = (store.memory / "2026-01-02.md").read_bytes()
    store.write("fedcba9876543210", "2026-01-02", "decisions", "Use local notes.")
    assert (store.memory / "2026-01-02.md").read_bytes().startswith(original)


def test_forget_exact_id_preserves_overlap(store):
    other = "fedcba9876543210"
    store.write(MID, "2026-01-02", "preferences", "Prefer concise answers.")
    store.write(other, "2026-01-02", "preferences", "Prefer concise answers with examples.")
    store.forget(MID)
    assert store.read(MID) is None
    assert store.read(other)["text"] == "Prefer concise answers with examples."
    assert not (store.root / "vault-backups").exists()


def test_symlink_store_refused(store, tmp_path):
    target = tmp_path / "untouched"
    target.write_text("sentinel")
    (store.memory / "2026-01-02.md").symlink_to(target)
    with pytest.raises(api.BatchError, match="symlink"):
        store.write(MID, "2026-01-02", "preferences", "A preference.")
    assert target.read_text() == "sentinel"


def test_atomic_failure_does_not_create_partial_entry(store, monkeypatch):
    def fail(*args):
        raise OSError("synthetic failure")
    monkeypatch.setattr(api.os, "replace", fail)
    with pytest.raises(OSError):
        store.write(MID, "2026-01-02", "preferences", "A preference.")
    assert list(store._entries()) == []
    assert not list(store.memory.glob(".batch-*"))
