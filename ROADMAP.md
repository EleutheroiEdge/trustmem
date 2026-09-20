# Roadmap

## Done in 0.3.0

- ~~Continuous live-learning engine (score, reinforce, decay, consolidate, promote, prune).~~
- ~~Unified memory lifecycle with intake-assigned IDs and manifest-based promotion.~~
- ~~Enforced (not merely declared) intake policy shared by Bash and Python callers.~~
- ~~Non-destructive forget and prune that also clean the generated vault.~~
- ~~Functional test suite and CI.~~
- ~~Remove deployment-specific project/person/policy assumptions from the engine.~~

## Near-term

- Add provider-level embedding split support:
  - `indexModel` for write/index operations
  - `queryModel` for retrieval/search operations
- Add explicit guardrail error when a dual-mode model is configured in a single-model path.
- Add MCP server command wiring (`trustmem mcp serve`) for Cursor/Claude Desktop.
- Read `category_retention_days()` from the active policy's `retention:` block
  instead of the compiled-in defaults.
- Referential-integrity check across day-files, `.scores`, `.promoted` and vault
  front-matter (`doctor` currently checks each artefact in isolation).

## Open questions

- **Should the engine own retention-based archival?** Today `learn prune` is
  purely score-based and day-files are an immutable audit trail. A
  retention-based prune that archives aged day-file entries into rollups is a
  different operation, currently left to consumers. Adopting it (as, say,
  `learn archive`) requires deciding whether the engine may ever rewrite a
  day-file. See `docs/CANONICALIZATION.md`.
- Supersession / contradiction detection: `consolidate` deduplicates identical
  snippets but does not know that a newer memory replaces an older one.
- Whether ambiguous content should be parked in a reviewable queue rather than
  simply refused.

## NVIDIA embedding note

For `nv-embedqa-e5-v5`, correct routing is:
- index: `nvidia/nv-embedqa-e5-v5-passage`
- query: `nvidia/nv-embedqa-e5-v5-query`

Single-model embedding paths should not silently run this model in production.
