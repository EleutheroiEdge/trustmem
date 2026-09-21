# Changelog

All notable changes to this project will be documented in this file.

## [0.3.0] — 2026-09-20

**This release canonicalizes functionality that was developed downstream.**

TrustMem was published here in February 2026 as an OSS-safe snapshot and then
stood still, while a vendored copy inside a private consumer was developed to
v0.2.2: the intake classifier, stable memory IDs, the live-learning engine,
non-destructive forget and the test suite all grew there and were never carried
back. 0.3.0 ports that work into this repository and makes it the source of
truth for the generic engine.

It is a port and reconciliation, not a redesign. The behaviour below was already
proven downstream; what changed on the way in is that every deployment-specific
assumption became configuration. The feature-by-feature record, including what
was deliberately **not** ported and what remains deferred, is in
[`docs/CANONICALIZATION.md`](docs/CANONICALIZATION.md).

### Security
- Intake is now fail-closed. `scripts/memory_policy.py` is one deterministic
  `allow` / `deny` / `confirm` / `review` classifier shared by the Bash CLI and
  any Python caller; the policy file is enforced rather than merely declared.
- `filters.block_patterns` and `filters.never_store` are checked against every
  intake string, and confirmation cannot override a denial.
- Detected credentials, full transcripts (explicit marker or four or more
  role-prefixed lines) and private personal identifiers are denied.
- Sensitive content requires an explicit `--confirm`; ambiguous content is
  routed to review and nothing is written.
- The classifier never prints or persists the submitted text.
- Explicit `forget` and score-based `prune` rebuild the vault without retaining
  a backup copy of the removed content, and scrub the generated notes and index
  that reference the removed memory ids.

### Added
- Stable 16-hex `memory_id` assigned at intake, embedded in day-file lines and
  carried through `.scores`, `.promoted` and vault front-matter.
- `scripts/lib.sh` — shared helpers for memory ids, category weights, category
  retention, slugs, policy resolution and vault scrubbing.
- `scripts/livelearn.sh` — `score`, `reinforce`, `decay` (with category-aware
  retention shielding), `consolidate`, `promote`, `prune`, `status`, `cycle`.
- `scripts/vault_sync.sh` — promotion-aware materialization, `memory_id` /
  `memory_ids` front-matter, a generated `vault/index.md`, and
  `--rebuild --no-backup` with unsafe- and symlink-target refusal.
- CLI: `--version`, `ingest`, `recall`, `learn <subcommand>`, and the
  `--confirm` / `--category` / `--ambiguous` intake options.
- `doctor` checks the active policy, the scope map, scores integrity, vault
  health and the promotion manifest.
- `tests/test_trustmem.sh` (165 assertions) and `tests/test_memory_policy.py`
  (52 assertions); CI runs both plus shellcheck on Ubuntu and macOS.
- `docs/CANONICALIZATION.md`.

### Changed — genericization
- **Policy is configurable.** The engine ships
  `policies/example-memory-policy.yaml` and selects a profile via
  `POLICY_FILE` or `TRUSTMEM_POLICY_PROFILE`. The previous deployment-specific
  policy file is gone, and non-example profiles are git-ignored so a downstream
  profile cannot be committed into a public fork.
- **Project scoping is configuration only.** The built-in fallback table of
  project slugs and titles has been removed. Projects come from
  `projects-map.yaml`; with no map, no project notes are written.
- **Person scoping is configuration only.** The hard-coded alias table and fixed
  first-name regex are replaced by a `people:` block with an optional
  `people_exclude:` list. Bare names are matched only for configured aliases;
  `@handle` mentions still work with no configuration.
- `project_id` in generated front-matter comes from `TRUSTMEM_PROJECT_ID`, else
  the active policy's `scope.project_id`, else the literal `default`.
- The host embedding guardrail path is overridable via `OPENCLAW_CONFIG` and
  reports a clean skip when no host config is present.
- Domain-specific capture (a consumer's own categories, instruments and
  holdings) was deliberately not ported; it belongs in a private consumer.

### Documented
- **Prune has two meanings and they are not merged.** This engine implements
  only the score-based prune: below-threshold entries leave `.scores`,
  `.promoted` and the vault, and **day-files are never modified**. `prune`
  prints `prune_mode: score-threshold` and `day_files_modified: 0` and accepts
  the explicit alias `prune-scores`. A retention-based prune that archives aged
  day-file content into rollups is a different, consumer-side operation and is
  not implemented here. Whether the engine should own it is recorded as an open
  question in `docs/CANONICALIZATION.md`.
- **The day-file invariant, stated precisely.** Day-files are **append-only in the
  normal lifecycle** — no learning operation rewrites them — and explicit `forget`
  is the **privacy/deletion exception** that may remove matching entries. Earlier
  wording called day-files an "immutable audit trail", which contradicted
  `forget`; the behaviour was right, the wording was not.

### Fixed
- `forget` left recoverable copies behind in TrustMem-managed artifacts: the text snippet
  that `.access_log` stores for each reinforce/promote/prune event, and generated notes
  inside vault backups written by *earlier* rebuilds. `forget` now cleans every derived
  artifact by the **exact stable memory id** of the forgotten entries (including ids
  derived for legacy rows), never by text, so overlapping memories are untouched
  (`test_forget_leaves_no_recoverable_copy`,
  `test_forget_is_precise_for_overlapping_memories`). `.scores` / `.promoted` rows are now
  matched on the id field exactly. The guarantee is scoped: no recoverable copy remains in TrustMem-managed current, generated and backup artifacts covered by the deletion contract;
  external snapshots, OS/third-party backups and Git history are outside it.
  `test_lifecycle_never_rewrites_dayfiles` pins the other half of the invariant.

## [0.1.0] — 2026-02-15

- Initial open-source hardening: safety templates, doctor command, docs, and guardrails.
