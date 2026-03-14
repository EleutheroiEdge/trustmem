# TrustMem

Local-first memory for AI agents: distilled notes -> canonical Markdown vault (with backlinks), with deterministic scoping and hard safety defaults.

## What it does
- Stores distilled memory logs in `memory/*.md` (no raw chat by default).
- Generates and updates a canonical vault in `vault/` (human-editable Markdown, backlink-friendly).
- Enforces deterministic scoping (projects/people/roles) via `projects-map.yaml`.
- Ships safe-by-default: no shared API keys, secrets blocked, local-first defaults.

## Memory Flow
```mermaid
flowchart LR
  A[Intake] --> B[Distill]
  B --> C[Canonical Vault]
  C --> D[Retrieve]
  D --> E[Agent Context]
  C -.vault-first.-> D
  F[Vector Index] -.second-pass semantic.-> D
```

## Quickstart
```bash
./scripts/install.sh
./bin/trustmem doctor
```

## Requirements
- Linux/macOS recommended. Windows: WSL2 (or Git Bash-compatible environment).
- Dependencies: `bash`, `rg`, `awk`, `sed`, `node`

## Commands
```bash
./bin/trustmem doctor
./bin/trustmem remember "Important preference"
./bin/trustmem forget "stale item"
./bin/trustmem sync --rebuild
./bin/trustmem learn cycle            # full live-learning pass
./bin/trustmem learn status           # learning metrics
./bin/trustmem recall "query text"    # search with learning
```

## Live Learning
TrustMem includes a continuous live-learning engine that improves memory quality over time:
- **score** – assigns trust scores (0–100) to every memory entry, weighted by category.
- **reinforce** – boosts entries that match a pattern (manual confirmation).
- **decay** – applies time-based decay so stale, unreinforced entries fade.
- **consolidate** – deduplicates identical entries across day files.
- **prune** – removes entries that fall below the confidence threshold.
- **recall** – searches memories and lightly reinforces retrieved entries.
- **cycle** – runs score → decay → consolidate → prune in one pass.

Run `trustmem learn cycle` periodically (e.g. via cron or after each sync) to keep the vault sharp.

## Security
- Never commit `.env` or any real API keys.
- Default is local embeddings for OSS; remote embeddings require BYO key.

## NVIDIA Embeddings (OpenClaw)
`nv-embedqa-e5-v5` is dual-mode:
- indexing: `nvidia/nv-embedqa-e5-v5-passage`
- querying: `nvidia/nv-embedqa-e5-v5-query`

OpenClaw single-model embedding config cannot route index vs query correctly without provider or patch support.

## Repo Layout
Tracked: templates, examples, scripts, docs.
Untracked: `.env`, `projects-map.yaml`, `memory/`, `vault/`, `vault-backups/`.

> `examples/cursor.mcp.example.json` and `examples/claude-desktop.mcp.example.json` are placeholders until MCP server wiring is finalized.

## Development
### Included in this repo
- `.gitignore`
- `.gitattributes`
- `.env.example`
- `config.example.yaml`
- `projects-map.example.yaml`
- `projects/project.example.md`
- `examples/`
- `.github/workflows/ci.yml`
- `bin/trustmem`
- `scripts/doctor.sh`
- `scripts/install.sh`
- `scripts/memoryctl.sh`
- `scripts/vault_sync.sh`
- `scripts/livelearn.sh`
- `ROADMAP.md`
- `LICENSE`
- `SECURITY.md`
- `CONTRIBUTING.md`
- `CHANGELOG.md`

### Local-only (not committed)
- `.env`
- `projects-map.yaml`
- `projects/*.md` (except `projects/project.example.md`)
- `memory/`
- `vault/`
- `vault-backups/`
