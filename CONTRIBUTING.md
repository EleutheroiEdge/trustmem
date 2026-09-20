# Contributing

## Development Setup

```bash
chmod +x bin/trustmem scripts/*.sh
cp .env.example .env
cp projects-map.example.yaml projects-map.yaml
./bin/trustmem doctor
```

## Before Opening a PR

```bash
./bin/trustmem doctor
bash tests/test_trustmem.sh
python3 -m pytest tests/test_memory_policy.py -q
shellcheck scripts/*.sh bin/trustmem tests/*.sh
```

## Keep the Engine Generic

This repository is public and is the canonical *generic* engine. Anything
specific to one deployment belongs in that deployment's configuration, not here.

- No project names, person names, hostnames, usernames or e-mail addresses in
  code, defaults, examples or tests.
- No domain-specific capture logic (finance, support, research). The engine
  takes text, classifies it, scores it and files it.
- New scoping or policy behaviour must be read from `projects-map.yaml` or the
  active policy profile, never compiled in as a fallback table.
- Ship only `policies/example-memory-policy.yaml`; other profiles are
  git-ignored on purpose.
- Test fixtures must be synthetic and obviously fake.

`tests/test_trustmem.sh::test_repository_is_generic` and
`test_scopes_require_configuration` guard these rules.

## Safety Rules

- Intake is fail-closed. Any new write path must go through the shared
  classifier in `scripts/memory_policy.py` before touching a file.
- The classifier must never print or persist the submitted text.
- Day-files are an immutable audit trail. `learn prune` is score-based and must
  not modify them. If you add a command that rewrites day-files, give it a
  different name and say so in `docs/CANONICALIZATION.md`.
- Any deletion must propagate: day-file, `.scores`, `.promoted`, generated vault
  notes and `vault/index.md`, with no backup copy left behind.

## Provider Contributions

- Keep local-first defaults.
- Do not add shared API keys.
- Remote providers must be opt-in and documented.
- For embeddings, document whether models are single-mode or dual-mode.

## NVIDIA Dual-Mode Rule

`nv-embedqa-e5-v5` requires split routing:
- index: `nvidia/nv-embedqa-e5-v5-passage`
- query: `nvidia/nv-embedqa-e5-v5-query`

Do not wire this as a single-model path without explicit index/query support.
