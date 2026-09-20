# Test-Projekt — Docker-based team work environment

A self-hosted work environment for a small team, deployed with Docker Compose on a
single Debian 13 host:

| Role | Product | Hostname |
|---|---|---|
| Source code & CI/CD | GitLab CE | `git.lab.test` |
| Documentation | XWiki | `wiki.lab.test` |
| Project management | OpenProject Community | `pm.lab.test` |
| Identity (shared accounts) | lldap | `ldap.lab.test` |
| Reverse proxy / TLS | Caddy | — |

All services are served over HTTPS with certificates issued by a private CA, share
one LDAP directory for user accounts, and can be backed up and reinstalled with the
scripts in `scripts/`.

This repository was built as a practical assessment task. Every design decision is
recorded as an Architecture Decision Record in [`docs/adr/`](docs/adr/).

## Repository layout

```
docs/            architecture, security, integration, backup/restore, problems, ADRs
pki/             scripts to create the private CA and issue service certificates; ca.crt
proxy/           Caddy compose stack and Caddyfile
services/        one compose stack per service: gitlab, xwiki, openproject, lldap
scripts/         bootstrap.sh (host preparation), backup.sh, restore.sh
.env.example     all environment variables with placeholders
```

## Quick start

> Full runbook: see below. Prerequisites: a Debian 13 host with a public IP, a
> workstation with `openssl`, `ssh` and `git`.

1. **Workstation:** clone this repository, create the CA and the service
   certificates (`pki/make-ca.sh`, `pki/issue-cert.sh` — see
   [`pki/README.md`](pki/README.md)), add the `*.lab.test` names to
   `/etc/hosts`, import `pki/ca.crt` into your browser and verify its
   fingerprint:
   `SHA256 A7:08:31:80:94:29:B9:64:81:47:C3:83:9F:D3:55:04:AE:37:06:FD:81:9A:0D:AB:A7:9B:3E:3D:38:97:49:B0`
2. **Host:** create the admin user (see "Host preparation" below), clone this
   repository and run `sudo ./scripts/bootstrap.sh` from that account (sshd
   hardening, Docker CE with `userns-remap`, apt pin, sudoers rule, `/srv`,
   Docker networks — see [`scripts/README.md`](scripts/README.md)).
3. Copy `.env.example` to `.env` in each stack directory and fill in secrets.
4. Copy the service certificates to `/srv/proxy/certs/`.
5. Start the stacks in this order: `proxy`, `lldap`, `gitlab`, `xwiki`, `openproject`.
6. Configure LDAP in each service and the integrations (`docs/integration.md`).

## Documentation

- [Architecture](docs/architecture.md) — components, networks, data flows, threat model
- [Security](docs/security.md) — measures, rationale, ISO 27001 mapping
- [Integration](docs/integration.md) — LDAP, GitLab ↔ OpenProject, XWiki ↔ OpenProject
- [Backup & restore](docs/backup-restore.md) — concept and restore test protocol
- [Problems & peculiarities](docs/problems.md)
- [Architecture Decision Records](docs/adr/)

## Runbook

### Workstation setup

Once per clone, so that every commit is scanned before it exists
(`docs/security.md`, "Secrets and data"):

```
brew install gitleaks shellcheck            # or the distribution packages
git config core.hooksPath scripts/git-hooks
git config hooks.sanitizePatterns ~/path/to/sanitize-patterns   # optional, see below
```

`sanitize-patterns` is a private file **outside** the repository with one
extended regex per line (your admin account name, real host names, key file
names). The hook blocks a commit whose added lines match; without the setting
the hook says so and only gitleaks runs. Before making the repository public,
run the same check over the whole tree:
`grep -rniE -f ~/path/to/sanitize-patterns --exclude-dir=.git .` (no output =
clean).

### Host preparation

Prerequisites outside the repository: a Debian 13 (trixie) cloud server and a
provider firewall that allows inbound TCP 22, 80, 443 and 2222 only.

**First login as root** (once, via the provider's root key). Create the admin
account and hand it the SSH key; everything else is done by `bootstrap.sh`.
Use a lower-case username (`docs/problems.md` P-003).

```
adduser --gecos "" <admin>                 # asks for a password: this is the sudo password
usermod -aG sudo <admin>
install -d -m 700 -o <admin> -g <admin> /home/<admin>/.ssh
install -m 600 -o <admin> -g <admin> /root/.ssh/authorized_keys /home/<admin>/.ssh/authorized_keys
exit
```

Log in as `<admin>` (verify that this works before the next step — the script
disables root and password logins), then:

```
sudo apt-get update && sudo apt-get install -y git   # the cloud image ships without git (P-015)
git clone <this repository> ~/Test-Projekt          # read-only deploy key, see docs/security.md
sudo ~/Test-Projekt/scripts/bootstrap.sh
```

The script is idempotent: run it again after any manual change on the host to
make sure the baseline still holds; the self-test at the end must show only
`PASS`. Details: [`scripts/README.md`](scripts/README.md).

### First start of the stacks

In this order, each README has the exact steps: [`proxy/`](proxy/README.md)
(certificates from `pki/`, Caddy) → [`services/lldap/`](services/lldap/README.md)
(directory, groups, service accounts) → [`services/gitlab/`](services/gitlab/README.md)
→ [`services/openproject/`](services/openproject/README.md) →
[`services/xwiki/`](services/xwiki/README.md). LDAP wiring per product:
[`docs/integration.md`](docs/integration.md).

### Backup and restore

`sudo ./scripts/backup.sh` writes one encrypted set to `/srv/backups/`; the
timer installed by `bootstrap.sh` runs it nightly. Pull the sets to the
workstation with `rsync` (the admin is in group `backup`). Reinstall = host
preparation above → `bootstrap.sh` → copy a set and the age identity →
`sudo ./scripts/restore.sh <set>.tar.age <identity>`. Procedure, guards and the
measured restore test: [`docs/backup-restore.md`](docs/backup-restore.md).

### Certificate renewal (yearly)

`pki/README.md`, "Renewal runbook": issue new leaf certificates with
`issue-cert.sh`, copy them to `/srv/proxy/certs`, restart Caddy; for XWiki
rebuild `/srv/xwiki/cacerts` only if the **CA** changed (the leaf does not
matter to the JVM). The certificates are part of every backup set.

### Upgrades

Take a backup, change the image tag in the stack's `compose.yaml`, `docker
compose pull && docker compose up -d`, watch the healthcheck. GitLab: follow
the upgrade path tool (ADR-0004) and never skip required stops; a set can only
be restored onto the tag it was taken with (`restore.sh` enforces this).
PostgreSQL major upgrades: dump-based restore (`docs/backup-restore.md`).

### On- and offboarding

Users exist only in lldap; membership in `git_user`, `wiki_user`, `pm_user`
grants access per product. Steps: `services/lldap/README.md`,
"On-/offboarding". Offboarding removes the account in lldap; sessions in the
products expire on their own; GitLab CE additionally blocks a user whose
LDAP entry no longer exists at that user's next sign-in attempt (the periodic
LDAP sync is a Premium feature).

### Secrets rotation

Rotatable at any time: `GITLAB_LDAP_BIND_PASSWORD` and the bind passwords set
in the OpenProject/XWiki admin UIs (change in lldap, then in the consumer),
`LLDAP_JWT_SECRET` (invalidates UI sessions), the `ldap-ui.auth` gate hash,
database passwords (change in `.env` and in the database, restart the stack).
Never rotate: `LLDAP_KEY_SEED` (encrypts stored keys — a new seed breaks the
directory) and `gitlab-secrets.json` (encrypts database columns). Both are
therefore in every backup set, and the set itself is encrypted with `age`.

## Tooling and use of AI assistance

This project was built with the help of an LLM-based coding assistant (Claude Code).
It was used for research (locating and summarising official documentation), for
explaining concepts and commands, for reviewing configuration, and for drafting the
documentation in `docs/`. Configuration files and scripts were typed and reviewed
line by line by the author, following the official documentation and the
assistant's guidance; every line and every decision recorded in the ADRs can be
explained by the author. Documentation drafts were reviewed before each commit.
No credentials or private keys were ever shared with the assistant, and every
commit was made by the author.

## License

MIT — see [`LICENSE`](LICENSE). The third-party products deployed here keep
their own licenses (GitLab CE: MIT Expat; OpenProject CE: GPLv3; XWiki: LGPLv2.1;
lldap: GPLv3; Caddy: Apache-2.0).
