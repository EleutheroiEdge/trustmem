# Dedicated batch-store API

`scripts/batch_intake.py` provides `BatchStore(root, policy_path)` for an operator-controlled consumer. It uses the shared `memory_policy.py` classifier and existing exact-ID deletion propagation. This is an additional source API, not a deployed service or a new published package version.

- `classify(text)` screens original structure before normalization. It refuses malformed multiline/control-character and embedded-ID structures and bounds UTF-8 input to 4,096 bytes. A policy allow is content screening, not authentication or proof of truth.
- `write(memory_id, source_date, category, text)` requires a caller-supplied 16-digit lowercase hexadecimal ID, ISO date and known category. It atomically appends a day-file entry while preserving earlier bytes. Identical retries reuse the entry; a conflicting reuse of the ID fails. The compatibility timestamp `00:00:00` denotes date-only precision, not a known observation time.
- `read(memory_id)` returns one exact matching entry, or none; duplicate IDs and unsupported entry formats fail closed.
- `forget(memory_id)` selects only the literal bracketed ID, then delegates propagation through notes, generated artifacts, indexes and managed backups to the existing CLI. It does not remove the consumer's review queue, audit, publications, backups, external source archive, or prior provider context.

The API accepts the exact reviewed example policy bytes, pinned by SHA-256. Unknown keys, duplicate keys, edits and alternate profiles fail closed. Customizable batch policy semantics require a separately reviewed schema/parser; the legacy CLI's configurable policy behavior is unchanged. Consumer scopes, freshness and disclosure rules are separate from this fixed screening profile. The profile's retention/embedding declarations are not new batch lifecycle features.

Use a dedicated directory owned by the current user with mode 700. New data files use mode 600. File locks serialize this API's operations and atomic replacements are fsynced. Symlink paths are rejected. All callers must honor the same lock; do not mix direct CLI writers with batch writers. This is not isolation against hostile code with the same UID, filesystem snapshots or physical disk recovery.

The consumer must authenticate its inputs, preserve source identity and dates, decide category/scope, manage review/consent, and maintain a crash-recoverable eligibility view. An engine write alone must never make a claim publishable. No network calls, subprocess memory bodies, provider credentials or personal configuration are part of this API.

Synthetic tests: `tests/test_batch_intake.py`, `tests/test_memory_policy.py` and the existing `tests/test_trustmem.sh`. Run using temporary HOME/state and disabled networking; no new dependencies beyond the existing test environment.
