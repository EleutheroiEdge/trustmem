#!/usr/bin/env python3
"""Shared fail-closed TrustMem intake policy for Python and Bash callers.

The policy file remains the authority for literal blocks, never-store
categories, and confirmation behavior.  This module adds a small deterministic
classifier for credential, transcript, personal-data, sensitive, and ambiguous
content.  It never prints or persists the submitted text.
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import asdict, dataclass
from pathlib import Path


class MemoryPolicyError(ValueError):
    """Base class for a policy decision that prevents a write."""


class MemoryPolicyDenied(MemoryPolicyError):
    pass


class MemoryPolicyConfirmationRequired(MemoryPolicyError):
    pass


class MemoryPolicyReviewRequired(MemoryPolicyError):
    pass


@dataclass(frozen=True)
class PolicyDecision:
    action: str
    normalized_text: str
    categories: tuple[str, ...]
    reasons: tuple[str, ...]


_CREDENTIAL_PATTERNS = (
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----", re.IGNORECASE),
    re.compile(
        r"\b(?:password|passwd|api[_ -]?key|client[_ -]?secret|access[_ -]?token|refresh[_ -]?token)\s*[:=]\s*\S+",
        re.IGNORECASE,
    ),
    re.compile(r"\bauthorization\s*:\s*bearer\s+\S+", re.IGNORECASE),
    re.compile(
        r"\b(?:github_pat_[A-Za-z0-9_]{12,}|gh[pousr]_[A-Za-z0-9_]{12,}|"
        r"AIza[A-Za-z0-9_-]{20,}|tskey-[A-Za-z0-9_-]{8,}|xox[baprs]-[A-Za-z0-9-]{8,}|"
        r"(?:AKIA|ASIA)[A-Z0-9]{16}|[0-9]{6,}:[A-Za-z0-9_-]{30,}|"
        r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{8,})"
    ),
    re.compile(r"https?://[^\s/]+:[^\s/@]+@|[?&](?:token|key|secret|sig|signature)=[^\s&]+", re.IGNORECASE),
)
_PERSONAL_DATA_PATTERNS = (
    re.compile(r"\b\d{3}-\d{2}-\d{4}\b"),
    re.compile(r"\b(?:brokerage|bank|routing|account)\s*(?:number|no\.?|#)\s*[:=]?\s*[A-Z0-9-]{6,}\b", re.IGNORECASE),
    re.compile(r"\b(?:\d[ -]*?){13,19}\b"),
)
_SENSITIVE_PATTERNS = (
    re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE),
    re.compile(r"(?<!\d)(?:\+?1[ .-]?)?\(?\d{3}\)?[ .-]\d{3}[ .-]\d{4}(?!\d)"),
    re.compile(r"\b(?:diagnosis|medical record|date of birth|home address)\b", re.IGNORECASE),
)
_AMBIGUOUS_PATTERNS = (
    re.compile(r"\[(?:privacy-)?ambiguous\]", re.IGNORECASE),
    re.compile(r"\b(?:possibly private|unsure whether sensitive|sensitivity unknown)\b", re.IGNORECASE),
)
_ROLE_LINE_RE = re.compile(r"(?im)^\s*(?:user|assistant|human|agent)\s*:")


def _yaml_list(text: str, key: str) -> list[str]:
    values: list[str] = []
    in_list = False
    for line in text.splitlines():
        if re.match(rf"^\s{{2}}{re.escape(key)}:\s*$", line):
            in_list = True
            continue
        if not in_list:
            continue
        match = re.match(r'^\s{4}-\s+["\']?(.*?)["\']?\s*$', line)
        if not match:
            break
        value = match.group(1).strip().strip("\"'")
        if value:
            values.append(value)
    return values


def _load_policy(policy_path: Path) -> dict[str, object]:
    if not policy_path.is_file():
        raise FileNotFoundError(f"required TrustMem policy is missing: {policy_path}")
    raw = policy_path.read_text(encoding="utf-8")
    sensitive = re.search(r"^\s{4}sensitive:\s*(\S+)\s*$", raw, re.MULTILINE)
    ambiguous = re.search(r"^\s{4}ambiguous:\s*(\S+)\s*$", raw, re.MULTILINE)
    return {
        "block_patterns": _yaml_list(raw, "block_patterns"),
        "never_store": {value.casefold() for value in _yaml_list(raw, "never_store")},
        "sensitive_control": sensitive.group(1) if sensitive else "always_ask",
        "ambiguous_control": ambiguous.group(1) if ambiguous else "review_queue",
    }


def _detected_categories(text: str) -> set[str]:
    categories: set[str] = set()
    if any(pattern.search(text) for pattern in _CREDENTIAL_PATTERNS):
        categories.add("raw_credentials")
    transcript_marked = re.match(r"^\s*(?:full\s+)?transcript\s*:", text, re.IGNORECASE)
    if transcript_marked or len(_ROLE_LINE_RE.findall(text)) >= 4:
        categories.add("full_transcripts")
    if any(pattern.search(text) for pattern in _PERSONAL_DATA_PATTERNS):
        categories.add("private_personal_data")
    if any(pattern.search(text) for pattern in _SENSITIVE_PATTERNS):
        categories.add("sensitive")
    if any(pattern.search(text) for pattern in _AMBIGUOUS_PATTERNS):
        categories.add("ambiguous")
    return categories


def classify_memory(
    text: str,
    *,
    policy_path: Path,
    category: str | None = None,
    confirmed: bool = False,
    ambiguous: bool = False,
) -> PolicyDecision:
    policy = _load_policy(Path(policy_path))
    normalized = " ".join(str(text).split())
    if not normalized:
        return PolicyDecision("deny", normalized, (), ("memory_text_required",))

    categories = _detected_categories(str(text))
    if category:
        categories.add(category.strip().casefold())
    if ambiguous:
        categories.add("ambiguous")

    reasons: list[str] = []
    folded = normalized.casefold()
    for pattern in policy["block_patterns"]:
        if str(pattern).casefold() in folded:
            reasons.append("blocked_pattern")
            categories.add("raw_credentials")
            break

    never_store = policy["never_store"]
    denied_categories = sorted(category_name for category_name in categories if category_name in never_store)
    if denied_categories:
        reasons.extend(f"never_store:{name}" for name in denied_categories)
    if reasons:
        return PolicyDecision("deny", normalized, tuple(sorted(categories)), tuple(reasons))

    if "sensitive" in categories and policy["sensitive_control"] == "always_ask" and not confirmed:
        return PolicyDecision(
            "confirm",
            normalized,
            tuple(sorted(categories)),
            ("sensitive_confirmation_required",),
        )
    if "ambiguous" in categories and policy["ambiguous_control"] == "review_queue":
        return PolicyDecision(
            "review",
            normalized,
            tuple(sorted(categories)),
            ("ambiguous_review_required",),
        )
    return PolicyDecision("allow", normalized, tuple(sorted(categories)), ())


def enforce_memory_policy(
    text: str,
    *,
    policy_path: Path,
    category: str | None = None,
    confirmed: bool = False,
    ambiguous: bool = False,
) -> str:
    decision = classify_memory(
        text,
        policy_path=policy_path,
        category=category,
        confirmed=confirmed,
        ambiguous=ambiguous,
    )
    if decision.action == "deny":
        if "blocked_pattern" in decision.reasons:
            raise MemoryPolicyDenied("memory text matches a blocked policy pattern")
        if "memory_text_required" in decision.reasons:
            raise MemoryPolicyDenied("memory text is required")
        raise MemoryPolicyDenied(f"memory policy denied write: {', '.join(decision.reasons)}")
    if decision.action == "confirm":
        raise MemoryPolicyConfirmationRequired("memory policy requires explicit sensitive-content confirmation")
    if decision.action == "review":
        raise MemoryPolicyReviewRequired("memory policy routed ambiguous content to review; nothing was stored")
    return decision.normalized_text


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("classify", "validate"))
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--text", required=True)
    parser.add_argument("--category")
    parser.add_argument("--confirmed", action="store_true")
    parser.add_argument("--ambiguous", action="store_true")
    args = parser.parse_args(argv)

    decision = classify_memory(
        args.text,
        policy_path=args.policy,
        category=args.category,
        confirmed=args.confirmed,
        ambiguous=args.ambiguous,
    )
    if args.mode == "classify":
        safe = asdict(decision)
        safe.pop("normalized_text", None)
        print(json.dumps(safe, sort_keys=True))
        return 0
    if decision.action == "allow":
        return 0
    print(f"trustmem: policy action={decision.action}; reason={','.join(decision.reasons)}", file=__import__("sys").stderr)
    return {"deny": 2, "confirm": 3, "review": 4}[decision.action]


if __name__ == "__main__":
    raise SystemExit(main())
