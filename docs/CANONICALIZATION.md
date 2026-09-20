# Canonicalization — 0.3.0

This repository is the canonical TrustMem engine. It was published in February
2026 as an OSS-safe snapshot (v0.1.0) and then stood still while the same code,
vendored into a private consumer, was developed to v0.2.2. Release 0.3.0 carries
that downstream work back here and makes this repository the source of truth.

This is a **port and reconciliation**, not a redesign. Nothing was invented: the
behaviour below was already proven downstream. What changed on the way in is
genericization — removing one deployment's project names, person names, policy
filename and portfolio-specific assumptions so the engine is configuration-driven
and the deployment-specific parts live in a consumer's own configuration.

## Comparison

| embedded feature | standalone state (before) | ported? | genericized? | tests | intentionally deferred |
|---|---|---|---|---|---|
| **Intake classifier** (`scripts/memory_policy.py`) — one deterministic allow/deny/confirm/review decision shared by Bash and Python callers | absent; policy YAML was declarative and unread | yes, byte-identical | not needed — already generic; only the policy it reads is now configurable | `test_memory_policy.py` (52); `test_policy_block`, `test_full_transcript_block` | — |
| **Credential / secret blocking** — `filters.block_patterns` plus semantic credential regexes | policy declared the patterns; `doctor` grepped the repo tree, nothing checked intake text | yes | yes — patterns come from whichever policy profile is active | `test_policy_block_patterns_deny`, `test_semantic_credentials_are_denied`, `test_block_patterns_come_from_the_active_policy` | — |
| **Full-transcript restriction** — explicit `Transcript:` marker or ≥4 role-prefixed lines | declared only | yes | already generic | `test_marked_transcript_is_denied`, `test_four_role_lines_are_treated_as_a_transcript`, `test_three_role_lines_are_not_a_transcript` | — |
| **Sensitive-content handling** — `confirm`, requires explicit `--confirm` | declared (`sensitive: always_ask`), unenforced | yes | yes — control read from the active profile | `test_sensitive_content_requires_confirmation`, `test_confirmation_cannot_override_a_denial` | — |
| **Ambiguous-content review** — `review`, nothing is stored | declared (`ambiguous: review_queue`), unenforced | yes | yes | `test_ambiguous_markers_route_to_review`, `test_denial_outranks_ambiguity` | no review *queue* is written; ambiguous items are refused, not parked |
| **Stable memory IDs** — 16-hex `mid` at intake, `[mid:…]` in day-files, carried into `.scores` / `.promoted` / vault front-matter | absent; lines matched by raw content | yes | already generic | `test_remember`, `test_lib_functions` (extract/strip/derive), `test_score` (idempotent rescore) | — |
| **Shared library** (`scripts/lib.sh`) | absent; helpers duplicated across scripts | yes | yes — gained `resolve_policy_path`, `policy_project_id`, `regex_escape` | `test_lib_functions` | — |
| **CLI surface** — `--version`, `ingest`, `recall`, `learn <sub>` | `doctor`, `remember`, `forget`, `sync` only | yes | yes — usage documents the environment contract | `test_version`, `test_ingest`, `test_recall_vault`, `test_recall_dayfile_fallback` | `trustmem mcp serve` still unimplemented (ROADMAP) |
| **Scoring** — category-weighted initial score | absent | yes | already generic | `test_score` (weights 100/90/85/80), `test_status` | — |
| **Reinforcement** — pattern boost towards 100, counter, access log | absent | yes | already generic | `test_reinforce` | — |
| **Decay** — per-day decay with category-aware retention shielding | absent | yes | already generic | `test_decay`, `test_decay_category_retention` | retention days are compiled into `category_retention_days()`, not read from the policy's `retention:` block — see *Deferred* below |
| **Consolidation** — snippet dedup keeping the higher score | absent | yes | already generic | `test_consolidate` | semantic contradiction / supersession still absent (was absent downstream too) |
| **Promotion** — threshold gate + `.promoted` manifest; vault materializes promoted mids only | absent; every sync rewrote everything | yes | already generic | `test_promote`, `test_promote_threshold`, `test_sync_promotion_filter` | — |
| **Prune (score-based)** — drops below-threshold entries from scores, manifest and vault | absent | yes | already generic; now self-describing (`prune_mode`, `day_files_modified`, alias `prune-scores`) | `test_prune`, `test_prune_scores_alias` | retention-based archival prune NOT implemented — see *Prune semantics* |
| **Explicit forget** — purge day-file lines, manifests and generated notes | removed the entry but `--rebuild` moved the old vault into `vault-backups/`, so the content stayed recoverable | yes | already generic | `test_forget` (asserts no backup dir is created) | — |
| **Deletion propagation into generated material** — `scrub_vault_memory_ids` + `--rebuild --no-backup` + index removal | absent | yes | already generic | `test_forget`, `test_prune`, `test_lib_functions` scrub case | — |
| **Vault front-matter provenance** — `memory_id` / `memory_ids`, `vault/index.md` | front-matter without any link back to a source line; no index | yes | yes — `project_id` now comes from config, not a constant | `test_sync`, `test_project_scoping` | no source-span provenance (character offsets); only mid→note |
| **Project scoping** | `projects-map.yaml` plus a hard-coded fallback table of that deployment's project slugs | yes | **yes — fallback table removed entirely** | `test_project_scoping`, `test_scopes_require_configuration` | — |
| **Person scoping** | hard-coded alias table and a fixed first-name regex naming real people | yes | **yes — read from a `people:` block, with `people_exclude:`; bare names matched only for configured aliases** | `test_person_scoping`, `test_scopes_require_configuration` | — |
| **Policy file** | `<project>-memory-policy.yaml` with `project: <project>`, referenced by name from the scripts and the OpenClaw example | yes | **yes — `policies/example-memory-policy.yaml`, selected by `POLICY_FILE` or `TRUSTMEM_POLICY_PROFILE`; other profiles are git-ignored** | `test_policy_profile_is_configurable`, `test_repository_is_generic`, `test_block_patterns_come_from_the_active_policy` | — |
| **Doctor health checks** — scores, vault, promoted manifest | binaries, example files, repo secret scan, embedding guardrail | yes | yes — added policy and scope-map checks; `OPENCLAW_CONFIG` overridable | `test_doctor` | — |
| **Audit trail** — `.access_log` for reinforce / promote / prune | absent | yes | already generic | `test_reinforce` (log written) | `remember` / `ingest` / `forget` writes and `recall` reads are still not logged (same gap as downstream) |
| **Test suite** — ~65 assertions | none | yes | yes — genericized fixtures, plus new scoping/policy/prune coverage → **140 assertions** | itself | — |
| **CI** — doctor + test + shellcheck on Ubuntu and macOS | doctor + shellcheck only | yes | yes — adds a pytest job and lints `tests/*.sh` | itself | — |
| **Embeddings / vector index** | documented, no implementation | n/a — nothing to port | n/a | n/a | still unimplemented in the engine; hosts index the vault themselves (ROADMAP) |
| Domain-specific capture (a consumer's own categories, instruments, holdings and risk-state hooks) | absent | **no — deliberately not ported** | n/a | n/a | belongs in a private consumer, not in a generic memory engine |
| Retention-based archival prune with quarterly rollups | absent | **no — deliberately not ported** | n/a | n/a | consumer-side behaviour; see *Prune semantics* |

## Prune semantics — two different operations, deliberately not merged

The downstream deployment ended up with two commands both called "prune", with
different meanings. That was a known, unresolved inconsistency and it would have
been dishonest to paper over it by merging them.

| | what it does | what it touches |
|---|---|---|
| **Score-based prune** (this engine: `trustmem learn prune`, alias `prune-scores`) | removes entries whose trust score fell below `PRUNE_THRESHOLD` | `.scores`, `.promoted`, generated vault notes and `index.md`. **Day-files are never modified** |
| **Retention-based archival prune** (a consumer-side operation; not implemented here) | moves day-file entries older than the policy's `retention:` days into archive rollups | rewrites and can delete day-files |

The engine's position: **day-files are an immutable audit trail**. Anything that
rewrites them is a lifecycle policy decision belonging to the consumer that owns
the data, not to the engine. So 0.3.0 implements only the score-based meaning,
says so in `--help`, and prints `prune_mode: score-threshold` and
`day_files_modified: 0` so a caller can never be in doubt about which one ran.
`test_prune` asserts the day-file entry survives.

**Open question, deferred:** should the engine also own retention-based archival
(say as `trustmem learn archive`), so that both halves of the lifecycle live in
one place and a consumer does not reimplement it? That needs a decision on
whether an engine may ever rewrite a day-file. Until it is answered, the two
meanings stay separate and separately named.

## Other intentionally deferred items

- **Retention days are not read from the policy.** `category_retention_days()`
  hard-codes 365 / 3650 / 90 while the policy file declares
  `retention.decisions_days` and friends. The two agree today but nothing
  enforces that. Wiring the function to the policy is a behaviour change to the
  decay shield and wants its own change with its own tests.
- **Supersession and contradiction detection.** `consolidate` deduplicates
  identical snippets; it does not detect that a newer memory contradicts an
  older one. Absent downstream too.
- **Referential-integrity checker** across day-files, `.scores`, `.promoted` and
  vault front-matter. `doctor` checks each artefact's own health but not that
  they agree with one another.
- **Full audit logging.** `.access_log` records reinforce, promote and prune.
  Intake and recall are not logged.
- **Ambiguous review queue.** Ambiguous content is refused and nothing is
  written. There is no queue file to review and later approve.
- **Embedding / semantic search.** The engine produces a Markdown vault and
  leaves indexing to the host; `config.example.yaml` and the NVIDIA dual-mode
  note describe an unimplemented path.
- **MCP server wiring** (`trustmem mcp serve`) — the example MCP configs remain
  placeholders.

## What a private consumer must now supply

Nothing in this repository names a project, a person, a host or a policy profile.
A consumer supplies all of it as configuration:

1. **A policy profile.** Copy `policies/example-memory-policy.yaml` to
   `policies/<profile>-memory-policy.yaml` and set
   `TRUSTMEM_POLICY_PROFILE=<profile>`, or point `POLICY_FILE` at a path outside
   the repository. Non-example profiles are git-ignored so a downstream profile
   cannot be committed into a public fork. The profile owns `scope.project_id`,
   `retention`, `filters.block_patterns`, `filters.never_store` and the
   `controls.confirmation` behaviour. **The classifier is fail-closed: with no
   readable policy, nothing is stored.**
2. **Project and person scopes.** Copy `projects-map.example.yaml` to
   `projects-map.yaml` (git-ignored) and describe the real projects under
   `projects:` and the real people under `people:`, with `people_exclude:` for
   words that look like a person but are not. Without this file the engine
   writes decisions and commitments but no project or person notes — it never
   guesses at a name it was not told about.
3. **Paths.** `TRUSTMEM_DIR`, `WORKSPACE`, `MEM_DIR`, `VAULT_DIR` and
   `PROJECT_MAP_FILE` if the defaults do not fit; `TRUSTMEM_PROJECT_ID` to stamp
   a project id that differs from the policy's; `OPENCLAW_CONFIG` if the
   embedding guardrail should inspect a host config elsewhere. See
   `.env.example`.
4. **Domain-specific capture.** Anything that decides *which* facts are worth
   remembering in a particular domain — trading, support, research — stays in the
   consumer. The engine takes text, classifies it, scores it and files it.
5. **Scheduling.** Nothing here installs a timer. Run `trustmem learn cycle` from
   whatever scheduler the consumer already uses.

## Porting notes

- `scripts/memory_policy.py` was copied byte-for-byte; its behaviour is unchanged
  and the new pytest suite characterizes it.
- `init_promoted` now reuses `lib.sh`'s `clean_line` instead of an inline
  duplicate of the same sed expression.
- `forget`'s awk filter dropped `BEGIN{IGNORECASE=1}`, a gawk-only setting that
  was dead code beside the explicit `tolower()` comparison and would have been
  ignored by mawk and BSD awk. The comparison itself is unchanged.
- `vault_sync` reuses `clean_line` for the same reason.
