"""Local batch API over TrustMem day-files and the canonical intake classifier.

The caller owns authentication, source provenance, review, and disclosure. This
API owns validated single-line storage with caller-supplied stable IDs and dates.
Use a dedicated store; never mix direct CLI writers with a running batch owner.
No network, environment credentials, content-bearing process arguments or logs.
"""
from __future__ import annotations

from contextlib import contextmanager
from datetime import date
import fcntl
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile


CODE_ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("_trustmem_batch_policy", CODE_ROOT / "scripts/memory_policy.py")
_policy = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = _policy
_spec.loader.exec_module(_policy)
SECTIONS = {"preferences": "Preferences", "decisions": "Decisions", "constraints": "Constraints",
            "projects": "Manual Pins", "todos": "Open TODOs"}
MID = re.compile(r"[a-f0-9]{16}\Z")
ENTRY = re.compile(r"^- \[mid:([a-f0-9]{16})\] \[00:00:00\] (.+)$")
# Stage-one API intentionally accepts exactly this reviewed profile, not a
# partial YAML interpretation. A future configurable profile needs a schema.
STRICT_POLICY_SHA256 = "2a1ca5dfb3b51001a95cf6de887e6d4ca099ed736db7c50b2364d90275e54972"


class BatchError(ValueError):
    """A closed reason code; never includes submitted text."""


def safe_path(path: Path) -> Path:
    path = Path(os.path.abspath(path))
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise BatchError("symlink_path")
    return path


def private_dir(path: Path) -> Path:
    path = safe_path(path)
    if not path.exists():
        path.mkdir(mode=0o700, parents=True)
    if not path.is_dir() or path.stat().st_uid != os.getuid() or stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise BatchError("private_directory_required")
    return path


def atomic_write(path: Path, data: bytes) -> None:
    path = safe_path(path)
    if path.exists() and (not path.is_file() or path.stat().st_uid != os.getuid()):
        raise BatchError("unsafe_target")
    fd, name = tempfile.mkstemp(prefix=".batch-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


class BatchStore:
    def __init__(self, root: Path, policy_path: Path):
        self.policy_path = safe_path(policy_path)
        self._validate_policy()
        self.root = private_dir(root)
        self.memory = private_dir(self.root / "memory")

    def _validate_policy(self):
        try:
            if hashlib.sha256(self.policy_path.read_bytes()).hexdigest() != STRICT_POLICY_SHA256:
                raise BatchError("invalid_policy")
            policy = _policy._load_policy(self.policy_path)
            text = self.policy_path.read_text()
        except (OSError, ValueError):
            raise BatchError("invalid_policy") from None
        required = {"raw_credentials", "full_transcripts", "private_personal_data"}
        # This API deliberately supports the strict profile only. Legacy CLI
        # policies retain their existing behavior; unsupported profiles fail here.
        for key in ("block_patterns", "never_store"):
            if len(re.findall(r"^  " + key + r":\s*$", text, re.M)) != 1:
                raise BatchError("invalid_policy")
        for key, value in (("sensitive", "always_ask"), ("ambiguous", "review_queue")):
            matches = re.findall(r"^    " + key + r":\s*(\S+)\s*$", text, re.M)
            if matches != [value]:
                raise BatchError("invalid_policy")
        if not required <= policy["never_store"] or not policy["block_patterns"]:
            raise BatchError("invalid_policy")

    def classify(self, text: str):
        self._validate_policy()
        if not isinstance(text, str) or not text.strip() or len(text.encode()) > 4096:
            raise BatchError("invalid_text")
        # Inspect original structure before normalization: role-line transcripts
        # and injected day-file headings must not be normalized into an allow.
        result = _policy.classify_memory(text, policy_path=self.policy_path)
        if result.action != "allow":
            return result
        if any(ord(c) < 32 or ord(c) == 127 for c in text) or "[mid:" in text.casefold():
            raise BatchError("single_line_required")
        return result

    @contextmanager
    def _lock(self):
        path = safe_path(self.root / ".batch.lock")
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            # No symlink can be handed to the existing cleanup/materializer.
            if any(p.is_symlink() for p in self.root.rglob("*")):
                raise BatchError("symlink_store")
            yield
        finally:
            os.close(fd)

    def _entries(self):
        for path in sorted(self.memory.glob("*.md")):
            safe_path(path)
            try:
                day = date.fromisoformat(path.stem).isoformat()
            except ValueError:
                raise BatchError("unexpected_dayfile") from None
            section = ""
            for line in path.read_text().splitlines():
                if line.startswith("## "):
                    section = line[3:]
                match = ENTRY.fullmatch(line)
                if match:
                    yield {"memory_id": match[1], "date": day, "section": section, "text": match[2]}
                elif "[mid:" in line:
                    raise BatchError("unsupported_entry_format")

    def read(self, memory_id: str):
        if not MID.fullmatch(memory_id):
            raise BatchError("invalid_id")
        with self._lock():
            rows = [row for row in self._entries() if row["memory_id"] == memory_id]
            if len(rows) > 1:
                raise BatchError("duplicate_id")
            return rows[0] if rows else None

    def write(self, memory_id: str, source_date: str, category: str, text: str):
        if not MID.fullmatch(memory_id) or category not in SECTIONS:
            raise BatchError("invalid_identity_or_category")
        try:
            if date.fromisoformat(source_date).isoformat() != source_date:
                raise ValueError
        except (ValueError, TypeError):
            raise BatchError("invalid_source_date") from None
        decision = self.classify(text)
        if decision.action != "allow":
            raise BatchError("intake_" + decision.action)
        normalized = decision.normalized_text
        target = {"memory_id": memory_id, "date": source_date, "section": SECTIONS[category], "text": normalized}
        with self._lock():
            existing = [r for r in self._entries() if r["memory_id"] == memory_id]
            if existing:
                if existing != [target]:
                    raise BatchError("id_conflict")
                return memory_id
            path = self.memory / (source_date + ".md")
            old = path.read_bytes() if path.exists() else ("# " + source_date + "\n").encode()
            addition = "\n## " + SECTIONS[category] + "\n\n- [mid:" + memory_id + "] [00:00:00] " + normalized + "\n"
            atomic_write(path, old + addition.encode())
        return memory_id

    def forget(self, memory_id: str):
        if not MID.fullmatch(memory_id):
            raise BatchError("invalid_id")
        with self._lock():
            # Reuse canonical exact-ID propagation through the existing CLI's
            # literal selector; no memory text enters argv or captured output.
            env = {"PATH": "/usr/bin:/bin", "HOME": str(self.root), "LANG": "C.UTF-8",
                   "TRUSTMEM_DIR": str(CODE_ROOT), "WORKSPACE": str(self.root),
                   "MEM_DIR": str(self.memory), "VAULT_DIR": str(self.root / "vault"),
                   "BACKUP_DIR": str(self.root / "vault-backups"),
                   "PROJECT_MAP_FILE": str(self.root / "absent-project-map.yaml"),
                   "POLICY_FILE": str(self.policy_path)}
            result = subprocess.run(["/bin/bash", str(CODE_ROOT / "scripts/memoryctl.sh"), "forget", "[mid:" + memory_id + "]"],
                                    env=env, capture_output=True, timeout=30)
            if result.returncode:
                raise BatchError("forget_failed")
            if any(row["memory_id"] == memory_id for row in self._entries()):
                raise BatchError("forget_incomplete")
