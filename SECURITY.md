# Security Policy

## Reporting a Vulnerability

Please report security issues privately via GitHub Security Advisories for this repo.

If Advisories are unavailable, open an issue with minimal detail and request a secure contact channel.

## Secrets Handling

- Do not paste API keys, tokens, private keys, or credentials into issues or PRs.
- Do not commit `.env`, `config.yaml`, `projects-map.yaml`, `vault/`, `vault-backups/`, or `memory/`.
- Use `.env.example` and other example files as templates only.

## Scope Notes

- This project is local-first by default.
- Remote provider credentials are BYO and must stay in user-managed env/config outside version control.
