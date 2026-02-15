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
./bin/trustmem sync
```

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
