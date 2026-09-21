# Security Policy

## Reporting a Vulnerability

Please report security issues privately via GitHub Security Advisories for this repo.

If Advisories are unavailable, open an issue with minimal detail and request a secure contact channel.

## Secrets Handling

- Do not paste API keys, tokens, private keys, or credentials into issues or PRs.
- Do not commit `.env`, `config.yaml`, `projects-map.yaml`, a non-example policy
  profile, `vault/`, `vault-backups/`, or `memory/`.
- Use `.env.example` and other example files as templates only.

## Intake Guarantees

Memory intake is fail-closed. Before anything is written, both the Bash CLI and
any Python caller run the same classifier (`scripts/memory_policy.py`) against
the active policy profile:

- `deny` — the active policy's `filters.block_patterns` matched, or the text was
  classified into a `never_store` category (detected credentials, full
  transcripts, private personal identifiers). A denial cannot be overridden by
  confirmation.
- `confirm` — sensitive content was detected; the write needs an explicit
  `--confirm` from the caller.
- `review` — the content is ambiguous; nothing is written.

The classifier never prints or persists the submitted text, in either its
`validate` or `classify` mode. With no readable policy file, nothing is stored.

## Deletion Guarantees

`trustmem forget` and the score-based `trustmem learn prune` remove the affected
memory ids from the day-files (forget only), `.scores`, `.promoted`, every
generated vault note that references them, and `vault/index.md`, then rebuild the
vault **without** archiving a backup copy of the removed content.

Note the boundary. In the normal lifecycle day-files are **append-only**: scoring,
reinforcement, decay, consolidation, promotion and score-based `prune` never
rewrite them. **Explicit `forget` is the privacy/deletion exception**: it removes
the matching source entries from day-files and then cleans every derived artifact by the
**exact stable memory id** of those entries - `.scores`, `.promoted`, `.access_log` (which
stores a snippet per learning event), the generated vault and its index, and generated
notes inside vault backups written by *earlier* rebuilds. Cleanup never matches on text,
so a memory whose wording merely overlaps is not affected.

**What is guaranteed:** after `forget`, no recoverable copy remains in TrustMem-managed current, generated and backup artifacts covered by the deletion contract.
**What is not:** TrustMem cannot and does not claim that no copy exists anywhere on the
machine. Filesystem snapshots, OS or third-party backups, Git history of a private vault,
and search indexes built by other tools are outside the guarantee and remain your
responsibility. Day-files are therefore an append-only record, **not** an immutable one -
privacy deletion outranks literal history.

## Scope Notes

- This project is local-first by default.
- Remote provider credentials are BYO and must stay in user-managed env/config outside version control.
- This repository is the generic engine and contains no real memory content,
  identities, project names or deployment configuration.
