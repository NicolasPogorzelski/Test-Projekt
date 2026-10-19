# Test-Projekt — Docker-based team work environment

[![Lint](https://github.com/NicolasPogorzelski/Test-Projekt/actions/workflows/lint.yml/badge.svg?branch=main)](https://github.com/NicolasPogorzelski/Test-Projekt/actions/workflows/lint.yml)
[![Secret scan](https://github.com/NicolasPogorzelski/Test-Projekt/actions/workflows/secret-scan.yml/badge.svg?branch=main)](https://github.com/NicolasPogorzelski/Test-Projekt/actions/workflows/secret-scan.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

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
scripts in [`scripts/`](scripts).

This repository was built as a practical assessment task in three days. Every
design decision is recorded as an Architecture Decision Record in
[`docs/adr/`](docs/adr/).

> **Hand-in state:** tag [`v1.0-hand-in`](https://github.com/NicolasPogorzelski/Test-Projekt/tree/v1.0-hand-in)
> (2026-09-20). Everything changed since — an installation guide tested by a
> first-time reader, three script fixes, restructured documentation — is
> listed in [`CHANGELOG.md`](CHANGELOG.md).

**Proven, not claimed** (2026-09-20): a rebuilt VPS was back to a working system
**21 minutes** after the first root login from one encrypted backup set
([protocol](docs/backup-restore.md#restore-test-protocol)); the security baseline
was measured from outside — port scan, TLS, headers — and with the CIS Docker
Benchmark, **12 → 44 of 117** after three fixes, every remaining finding
classified ([verification](docs/security.md#verification)); 28 problems are
recorded with root cause and fix ([problems](docs/problems.md)). On
2026-10-19 the [installation guide](docs/install.md) was followed word for word
on a fresh server, from an empty workstation to a decrypted backup.

## At a glance

Request path and identity — everything enters through the proxy, except Git
over SSH, which GitLab publishes itself:

```mermaid
flowchart LR
  B(["Browser, git over HTTPS"]) -->|"HTTPS :443 (:80 redirects)"| C
  D([git client]) -->|"SSH :2222"| G
  subgraph host["one Debian 13 host — Docker with userns-remap"]
    C["Caddy<br/>TLS with private CA<br/>security-header baseline"]
    G["GitLab CE"]
    W["XWiki"]
    P["OpenProject"]
    L["lldap<br/>directory"]
    C -->|"git.lab.test"| G
    C -->|"wiki.lab.test"| W
    C -->|"pm.lab.test"| P
    C -->|"ldap.lab.test<br/>basic-auth gate"| L
    G -.->|"authenticates users via LDAP"| L
    W -.->|"authenticates users via LDAP"| L
    P -.->|"authenticates users via LDAP"| L
  end
```

Dotted: the applications query the one directory on every sign-in — they are
LDAP clients, nothing is pushed into them ([`docs/architecture.md`](docs/architecture.md),
[`docs/integration.md`](docs/integration.md) §1).

<details>
<summary><strong>Integrations</strong> — how the products are tied together (<code>docs/integration.md</code>)</summary>

```mermaid
flowchart LR
  G["GitLab<br/>project smoke-test"]
  P["OpenProject<br/>work package #37"]
  W["XWiki<br/>page Projects/smoke-test"]
  L["lldap"]
  G ==>|"webhook: push, MR, comment, work item, pipeline<br/>token of a 3-permission user<br/>outbound allowlist by name (pm, wiki)"| P
  G -.->|"External wiki (menu link)"| W
  P -.->|"Documentation attribute (link)"| W
  W -.->|"links: repository, work packages"| G & P
  G & P & W ---|"LDAP, access groups git_user / pm_user / wiki_user"| L
```

Double: the only call from one product to another. Dotted: links opened in
the user's browser. Not built: rendering work packages inside wiki pages (the only
candidate extension has never been released).

</details>

<details>
<summary><strong>Backup and restore</strong> — one command each, measured (<code>docs/backup-restore.md</code>)</summary>

```mermaid
flowchart LR
  subgraph host["host"]
    A["applications<br/>stopped while read"]
    DB["databases<br/>pg_dump while running"]
    GL["GitLab<br/>gitlab-backup + secrets + host keys"]
    F["certificates, .env,<br/>lldap, proxy state"]
    BS["backup.sh<br/>nightly timer"]
    SET[("/srv/backups/&lt;stamp&gt;.tar.age<br/>manifest + SHA256SUMS<br/>age-encrypted, 7 kept")]
    A & DB & GL & F --> BS --> SET
  end
  SET -->|"rsync pull over SSH"| WS(["workstation<br/>age identity in the password manager"])
  WS -->|"set + identity"| NEW["fresh host<br/>clone → bootstrap.sh → restore.sh"]
  NEW -->|"guards: checksums, image tags, empty targets<br/>lldap → proxy → OpenProject → XWiki → GitLab"| OK(["running system, verified<br/>health + TLS by the script, functional checklist by hand<br/>21 min measured"])
```

</details>

## Contents

- [Repository layout](#repository-layout)
- [Installation](#installation)
- [Evaluating this repository](#evaluating-this-repository)
- [Documentation](#documentation)
- [Operations](#operations): [workstation](#workstation-setup) · [backup and restore](#backup-and-restore) · [certificates](#certificate-renewal-yearly) · [upgrades](#upgrades) · [project onboarding](#project-onboarding) · [users](#on--and-offboarding) · [secrets](#secrets-rotation)
- [Tooling and use of AI assistance](#tooling-and-use-of-ai-assistance)
- [License](#license)

## Repository layout

```
docs/            install guide, architecture, security, integration, backup/restore, problems, ADRs
pki/             scripts to create the private CA and issue service certificates; ca.crt
proxy/           Caddy compose stack and Caddyfile
services/        one compose stack per service: gitlab, xwiki, openproject, lldap
scripts/         bootstrap.sh (host preparation), backup.sh, restore.sh, git pre-commit hook
.github/         CI: shellcheck, yamllint, compose validation, gitleaks over the history
.env.example     every environment variable, with its purpose
CHANGELOG.md     changes since the hand-in
LICENSE          MIT
```

## Installation

**[`docs/install.md`](docs/install.md)** — one linear path from an empty
workstation and an empty server to a working system: server and firewall,
your own CA and certificates, host preparation with `bootstrap.sh`, the five
stacks with LDAP sign-in, and a first backup that is decrypted again. Every
command is marked with the machine it runs on and followed by its expected
output.

Prerequisites: a Debian 13 (amd64) server with a public IPv4 (8 vCPU /
16 GB RAM), a Linux workstation with `openssl`, `ssh`, `git`, `curl`, `age`
and Docker or Podman. Time: about two hours, most of it image pulls and the
first start of GitLab; secrets and directory contents are created by hand on
purpose, not by scripts in the repository.

The stack READMEs ([`pki/`](pki/README.md), [`proxy/`](proxy/README.md),
[`services/*/`](services/)) are the reference for each part — what it is, why
it is configured that way, how to verify and operate it.

## Evaluating this repository

Three ways, from cheapest to most complete:

1. **Read.** The decisions are in [`docs/adr/`](docs/adr/) (one file per
   non-obvious choice, with the alternatives), the problems and their root
   causes in [`docs/problems.md`](docs/problems.md), the security measures
   and what was verified from outside in [`docs/security.md`](docs/security.md),
   and the measured restore test — a rebuilt VPS back to a working system in
   21 minutes — in [`docs/backup-restore.md`](docs/backup-restore.md).
2. **Reproduce on a fresh Debian 13 host** (cloud VPS with 8 vCPU / 16 GB,
   about 0.13 EUR/h at the provider used here): [`docs/install.md`](docs/install.md).
3. **Run it elsewhere.** The supported target is Debian 13 — physical,
   virtual or cloud. On macOS or Windows, use a Debian 13 VM (Multipass, UTM,
   Hyper-V; 16 GB RAM for the VM) and follow the same path; Docker Desktop is
   out of scope because the design relies on Linux user-namespace remapping
   and numeric bind-mount ownership, which do not carry through the Desktop
   VM. Other Linux distributions: the compose stacks, `backup.sh` and
   `restore.sh` are distribution-independent; only `bootstrap.sh` is the
   Debian implementation of the host requirements listed in
   [`docs/architecture.md`](docs/architecture.md#host-requirements) — porting
   means replacing its package-manager steps (not exercised in the time-box).

## Documentation

- [Installation](docs/install.md) — the one path from empty machines to a working, backed-up system
- [Architecture](docs/architecture.md) — components, networks, data flows, threat model
- [Security](docs/security.md) — measures, rationale, ISO 27001 mapping
- [Integration](docs/integration.md) — shared identity (LDAP), GitLab → OpenProject webhook, XWiki as the documentation hub, what is not built and why
- [Backup & restore](docs/backup-restore.md) — what is in a set, procedures, the measured restore test
- [Problems & peculiarities](docs/problems.md) — 28 entries, each symptom → verification → cause → fix
- [Architecture Decision Records](docs/adr/) — 14 decisions with alternatives; [index](docs/adr/README.md)
- [Changelog](CHANGELOG.md) — what changed after the hand-in

## Operations

### Workstation setup

Once per clone, so that every commit is scanned before it exists
([`docs/security.md`](docs/security.md), "Secrets and data"):

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

### Backup and restore

`sudo ./scripts/backup.sh` writes one encrypted set to `/srv/backups/`; the
timer installed by `bootstrap.sh` runs it nightly. Pull the sets to the
workstation with `rsync` (the admin is in group `backup`). Reinstall =
[`docs/install.md`](docs/install.md) sections 1 and 3 → `bootstrap.sh` → copy a
set and the age identity → `sudo ./scripts/restore.sh <set>.tar.age <identity>`;
the CA comes from the set. Procedure, guards and the
measured restore test: [`docs/backup-restore.md`](docs/backup-restore.md).

### Certificate renewal (yearly)

[`pki/README.md`](pki/README.md), "Renewal runbook": issue new leaf certificates with
`issue-cert.sh`, copy them to `/srv/proxy/certs` (keys to owner `101000`),
restart Caddy; for XWiki
rebuild `/srv/xwiki/cacerts` only if the **CA** changed (the leaf does not
matter to the JVM). The certificates are part of every backup set.

### Upgrades

Take a backup, change the image tag in the stack's `compose.yaml`, `docker
compose pull && docker compose up -d`, watch the healthcheck. GitLab: follow
the upgrade path tool ([ADR-0004](docs/adr/0004-git-server.md)) and never skip required stops; a set can only
be restored onto the tag it was taken with (`restore.sh` enforces this).
PostgreSQL major upgrades: dump-based restore ([`docs/backup-restore.md`](docs/backup-restore.md)).

### Project onboarding

For every new project, in this order: create the XWiki page
`Projects/<name>` (any member can, e.g. as the project lead); create the
GitLab project — it inherits the *External wiki* link to the XWiki index,
set the project's own page under *Settings → Integrations → External wiki*
and disable the built-in wiki under *Settings → General → Visibility*; create
the OpenProject project — it inherits the module defaults (GitLab on, Wiki
off), set the `Documentation` attribute on the overview to the XWiki page,
add the `gitlab-integration` user as member with role `GitLab Integration`
and register the webhook in the GitLab project ([`docs/integration.md`](docs/integration.md) §2, §3).

### On- and offboarding

Users exist only in lldap; membership in `git_user`, `wiki_user`, `pm_user`
grants access per product. Steps: [`services/lldap/README.md`](services/lldap/README.md),
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
commit up to the hand-in was made by the author.

Changes after the hand-in were drafted with the assistant as well; they are
listed in [`CHANGELOG.md`](CHANGELOG.md).

## License

MIT — see [`LICENSE`](LICENSE). The third-party products deployed here keep
their own licenses (GitLab CE: MIT Expat; OpenProject CE: GPLv3; XWiki: LGPLv2.1;
lldap: GPLv3; Caddy: Apache-2.0).
