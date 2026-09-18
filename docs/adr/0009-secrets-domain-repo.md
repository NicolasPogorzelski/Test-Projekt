# ADR-0009: Secrets handling, domain scheme, repository policy

## Status
Accepted

## Secrets
- Each stack reads a `.env` file (`chmod 600`) that is excluded from git;
  `.env.example` documents every variable with a placeholder.
- Secrets are generated (`openssl rand -base64 32`), never invented.
- `.gitignore` excludes `.env`, private keys, certificates except `pki/ca.crt`,
  backups and dumps. `gitleaks` runs as a pre-commit hook to catch patterns
  that `.gitignore` cannot know about.
- Rotation is documented in the runbook.
- Docker Compose `secrets:` would avoid secrets in `docker inspect`, but only
  images with `_FILE` variants support it; kept as a next step.
- Accepted: root on the host can read secrets via `docker inspect` — root can
  read everything anyway.

## Domain scheme
- `lab.test` → `git.lab.test`, `wiki.lab.test`, `pm.lab.test`, `ldap.lab.test`.
- `.test` is reserved for testing by RFC 2606 and can never collide with a
  public name; `.local` belongs to mDNS (RFC 6762) and would clash with Avahi
  on Fedora; `.internal` (ICANN 2024) would also work but signals
  "production-internal".
- Functional service names (`git`, not `gitlab`) survive a product swap.
- No company name in the domain.
- Resolution: `/etc/hosts` on the workstation; Caddy network aliases inside
  Docker.
- Let's Encrypt is impossible for these names — irrelevant, a private CA is
  required.

## Repository
- Private during the build, public on submission (portfolio piece).
  Publishing is the moment secrets hygiene must be final: anything ever
  public counts as leaked.
- English only; small, chronological commits as evidence of the process.
- One ADR per non-obvious decision; problems recorded in `docs/problems.md`.
- Transparent statement on the use of AI assistance in the README.
