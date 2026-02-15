# TrustMem

Local-first memory layer for agents: distilled memory logs + canonical vault generation.

## Scope

- Local-first storage by default.
- Distilled memory (`memory/*.md`) -> canonical vault (`vault/`) sync.
- Deterministic project/person extraction via `projects-map.yaml`.
- No shared API keys.

## Requirements

- OS:
  - Linux/macOS recommended
  - Windows requires WSL2 (or Git Bash-compatible environment)
- Dependencies:
  - `bash`
  - `ripgrep` (`rg`)
  - `awk`
  - `sed`
  - `node` (used by `trustmem doctor` guardrail checks)
- Permissions:
  - `chmod +x bin/trustmem scripts/*.sh`

## Security and OSS shipping rules

- Never commit `.env` or any real API key.
- Never hardcode secrets in config.
- Default to local embeddings for OSS distribution.
- Remote embeddings must be user-provided (BYO key).
- Commit only templates/examples; keep local generated memory and personal maps untracked.

## NVIDIA embedding guardrail

`nv-embedqa-e5-v5` is dual-mode:
- indexing: `nvidia/nv-embedqa-e5-v5-passage`
- querying: `nvidia/nv-embedqa-e5-v5-query`

OpenClaw single-model embedding config will not route this correctly without patch/provider support for separate index/query models.

## Quickstart

```bash
./scripts/install.sh
./bin/trustmem doctor
```

## CLI

```bash
./bin/trustmem doctor
./bin/trustmem remember "Important preference"
./bin/trustmem forget "stale item"
./bin/trustmem sync --rebuild
```

## Files shipped for open source

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
- `ROADMAP.md`
- `LICENSE`
- `SECURITY.md`
- `CONTRIBUTING.md`
- `CHANGELOG.md`

## CI

- GitHub Actions workflow runs:
  - `trustmem doctor` on Ubuntu and macOS
  - `shellcheck` on shell scripts (Ubuntu)

## Files not shipped

- `.env`
- `projects-map.yaml`
- `projects/*.md` (except `projects/project.example.md`)
- `memory/`
- `vault/`
- `vault-backups/`

## Notes

- `examples/cursor.mcp.example.json` and `examples/claude-desktop.mcp.example.json` are placeholders until MCP server command wiring is finalized.
