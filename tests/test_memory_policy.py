"""Unit tests for the shared TrustMem intake classifier.

Run:  python3 -m pytest tests/test_memory_policy.py -q

Every string in this file is synthetic. Nothing here is a real credential,
address, account number or person.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
CLASSIFIER = REPO_ROOT / "scripts" / "memory_policy.py"
EXAMPLE_POLICY = REPO_ROOT / "policies" / "example-memory-policy.yaml"
FIXTURE_POLICY = Path(__file__).resolve().parent / "fixtures" / "strict-memory-policy.yaml"


def _load_module():
    """Import scripts/memory_policy.py by path.

    The module must be registered in sys.modules before it is executed:
    @dataclass resolves annotations through sys.modules[cls.__module__].
    """
    name = "trustmem_memory_policy"
    spec = importlib.util.spec_from_file_location(name, CLASSIFIER)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


mp = _load_module()


def classify(text: str, *, policy: Path = EXAMPLE_POLICY, **kwargs):
    return mp.classify_memory(text, policy_path=policy, **kwargs)


# ── allow ────────────────────────────────────────────────────────────


def test_ordinary_text_is_allowed():
    decision = classify("Decision: we chose Markdown vaults for the canonical store")
    assert decision.action == "allow"
    assert decision.reasons == ()
    assert decision.categories == ()


def test_allowed_text_is_normalized():
    decision = classify("  Decision:   collapse    whitespace \n aggressively  ")
    assert decision.action == "allow"
    assert decision.normalized_text == "Decision: collapse whitespace aggressively"


def test_empty_text_is_denied():
    decision = classify("   \n\t  ")
    assert decision.action == "deny"
    assert "memory_text_required" in decision.reasons


# ── deny: block patterns ─────────────────────────────────────────────


@pytest.mark.parametrize(
    "text",
    [
        "synthetic token sk-not-a-real-key",
        "synthetic token ghp_not-a-real-token",
        "synthetic arn AKIA-not-real",
        "synthetic slack xoxb-not-real",
        "pasted -----BEGIN PRIVATE KEY----- synthetic",
    ],
)
def test_policy_block_patterns_deny(text):
    decision = classify(text)
    assert decision.action == "deny"
    assert "blocked_pattern" in decision.reasons
    assert "raw_credentials" in decision.categories


def test_block_pattern_match_is_case_insensitive():
    assert classify("synthetic SK-NOT-A-REAL-KEY").action == "deny"


def test_block_patterns_come_from_the_active_policy():
    # The fixture profile blocks a token the shipped example policy allows.
    text = "note containing zzq-fixture-blocked marker"
    assert classify(text, policy=FIXTURE_POLICY).action == "deny"
    assert classify(text, policy=EXAMPLE_POLICY).action == "allow"


# ── deny: never_store categories ─────────────────────────────────────


@pytest.mark.parametrize(
    "text",
    [
        "password = synthetic-value",
        "api_key: synthetic-value",
        "client-secret=synthetic-value",
        "access_token : synthetic-value",
        "Authorization: Bearer synthetic-value",
    ],
)
def test_semantic_credentials_are_denied(text):
    decision = classify(text)
    assert decision.action == "deny"
    assert "raw_credentials" in decision.categories


def test_marked_transcript_is_denied():
    decision = classify("Transcript: a synthetic conversation about nothing")
    assert decision.action == "deny"
    assert "full_transcripts" in decision.categories


def test_four_role_lines_are_treated_as_a_transcript():
    text = "user: one\nassistant: two\nhuman: three\nagent: four"
    decision = classify(text)
    assert decision.action == "deny"
    assert "full_transcripts" in decision.categories


def test_three_role_lines_are_not_a_transcript():
    text = "user: one\nassistant: two\nuser: three"
    assert classify(text).action == "allow"


@pytest.mark.parametrize(
    "text",
    [
        "synthetic id 123-45-6789",
        "brokerage account number: ABC123456",
        "card 1234 5678 9012 3456",
    ],
)
def test_private_personal_data_is_denied(text):
    decision = classify(text)
    assert decision.action == "deny"
    assert "private_personal_data" in decision.categories


def test_declared_category_is_honoured():
    decision = classify("a perfectly ordinary sentence", category="full_transcripts")
    assert decision.action == "deny"
    assert "never_store:full_transcripts" in decision.reasons


def test_declared_category_is_case_insensitive():
    decision = classify("a perfectly ordinary sentence", category="  RAW_Credentials ")
    assert decision.action == "deny"


def test_unknown_declared_category_does_not_deny():
    assert classify("an ordinary sentence", category="notes").action == "allow"


# ── confirm: sensitive content ───────────────────────────────────────


@pytest.mark.parametrize(
    "text",
    [
        "Contact test@example.com about the rollout",
        "Reach the desk at 555 010 9999",
        "the date of birth field must stay out of memory",
        "note about a medical record handling rule",
    ],
)
def test_sensitive_content_requires_confirmation(text):
    decision = classify(text)
    assert decision.action == "confirm"
    assert decision.reasons == ("sensitive_confirmation_required",)
    assert "sensitive" in decision.categories


def test_confirmation_allows_sensitive_content():
    decision = classify("Contact test@example.com", confirmed=True)
    assert decision.action == "allow"


def test_confirmation_cannot_override_a_denial():
    decision = classify("synthetic token sk-not-a-real-key", confirmed=True)
    assert decision.action == "deny"


# ── review: ambiguous content ────────────────────────────────────────


@pytest.mark.parametrize(
    "text",
    [
        "[ambiguous] something we are unsure about",
        "[privacy-ambiguous] something we are unsure about",
        "possibly private detail about the schedule",
        "sensitivity unknown for this item",
    ],
)
def test_ambiguous_markers_route_to_review(text):
    decision = classify(text)
    assert decision.action == "review"
    assert decision.reasons == ("ambiguous_review_required",)


def test_ambiguous_flag_routes_to_review():
    decision = classify("an otherwise ordinary sentence", ambiguous=True)
    assert decision.action == "review"


def test_denial_outranks_ambiguity():
    decision = classify("synthetic token sk-not-a-real-key", ambiguous=True)
    assert decision.action == "deny"


# ── enforcement wrapper ──────────────────────────────────────────────


def test_enforce_returns_normalized_text_when_allowed():
    result = mp.enforce_memory_policy(
        "  Decision:  keep   it   tidy ", policy_path=EXAMPLE_POLICY
    )
    assert result == "Decision: keep it tidy"


@pytest.mark.parametrize(
    "text,exc",
    [
        ("synthetic token sk-not-a-real-key", "MemoryPolicyDenied"),
        ("", "MemoryPolicyDenied"),
        ("password = synthetic-value", "MemoryPolicyDenied"),
        ("Contact test@example.com", "MemoryPolicyConfirmationRequired"),
        ("[ambiguous] unclear", "MemoryPolicyReviewRequired"),
    ],
)
def test_enforce_raises_before_any_write(text, exc):
    with pytest.raises(getattr(mp, exc)):
        mp.enforce_memory_policy(text, policy_path=EXAMPLE_POLICY)


def test_all_policy_errors_share_a_base_class():
    for name in (
        "MemoryPolicyDenied",
        "MemoryPolicyConfirmationRequired",
        "MemoryPolicyReviewRequired",
    ):
        assert issubclass(getattr(mp, name), mp.MemoryPolicyError)


def test_missing_policy_file_fails_closed():
    with pytest.raises(FileNotFoundError):
        classify("anything", policy=Path("/nonexistent/policy.yaml"))


# ── CLI contract (this is what the Bash caller depends on) ───────────


def _cli(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(CLASSIFIER), *args],
        capture_output=True,
        text=True,
        check=False,
    )


@pytest.mark.parametrize(
    "text,extra,code",
    [
        ("an ordinary sentence", [], 0),
        ("synthetic token sk-not-a-real-key", [], 2),
        ("Contact test@example.com", [], 3),
        ("Contact test@example.com", ["--confirmed"], 0),
        ("an ordinary sentence", ["--ambiguous"], 4),
    ],
)
def test_validate_exit_codes(text, extra, code):
    result = _cli("validate", "--policy", str(EXAMPLE_POLICY), "--text", text, *extra)
    assert result.returncode == code


def test_validate_never_echoes_the_submitted_text():
    secret_ish = "password = synthetic-value-do-not-echo"
    result = _cli("validate", "--policy", str(EXAMPLE_POLICY), "--text", secret_ish)
    assert result.returncode == 2
    assert "synthetic-value-do-not-echo" not in result.stdout
    assert "synthetic-value-do-not-echo" not in result.stderr


def test_classify_emits_json_without_the_text():
    result = _cli("classify", "--policy", str(EXAMPLE_POLICY), "--text", "Contact test@example.com")
    assert result.returncode == 0
    payload = json.loads(result.stdout)
    assert payload["action"] == "confirm"
    assert "normalized_text" not in payload
    assert "sensitive" in payload["categories"]


def test_classify_reports_allow_for_ordinary_text():
    result = _cli("classify", "--policy", str(EXAMPLE_POLICY), "--text", "an ordinary sentence")
    payload = json.loads(result.stdout)
    assert payload == {"action": "allow", "categories": [], "reasons": []}
