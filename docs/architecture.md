# Architecture

## Components

| Component | Image (pinned) | Why this tag | Role | Internal port |
|---|---|---|---|---|
| Caddy | `caddy:2.11.4-alpine` | current 2.x; Alpine variant = small image | reverse proxy, TLS termination | 80/443 (published) |
| GitLab CE | `gitlab/gitlab-ce:19.4.0-ce.0` | current minor at build time; CE = pure open source (ADR-0004) | source code, CI/CD | 80 (HTTP), 22 (SSH, published as 2222) |
| XWiki | `xwiki:17.10.13-postgres-tomcat` | **LTS** branch: longer fix support; the branch extensions are typically tested against. Runs as root inside the container with all capabilities dropped (ADR-0013) | documentation | 8080 |
| OpenProject | `openproject/openproject:16.6.10-slim` + `memcached:1.6.45-alpine` | current 16.6 patch; `-slim` = application only, one container per role, non-root — the all-in-one image is documented as not for production (ADR-0012) | project management | 8080 |
| lldap | `lldap/lldap:v0.6.3-alpine-rootless` | current release | LDAP directory + web UI | 3890 (LDAP), 17170 (web) |
| PostgreSQL ×2 | `postgres:17.11-alpine` | OpenProject requires PostgreSQL ≥ 16 (system requirements); XWiki's official compose example initialises the DB with the PostgreSQL 17 `builtin` locale provider, which 16 lacks; 17 is maintained until late 2029 | databases for XWiki and OpenProject | 5432 (internal only) |

Tags were taken from the Docker Hub API on 2026-09-18. Every tag is exact
(`x.y.z`), never `latest`, so a rebuild reproduces the same versions.

Host engine as installed by `scripts/bootstrap.sh` on 2026-09-18 (Debian 13,
Docker apt repository): `docker-ce` 29.8.1, `containerd.io` 2.3.5,
`docker-compose-plugin` 5.5.1, `docker-buildx-plugin` 0.37.1. Only
`docker-ce`/`docker-ce-cli` are pinned to `5:29.*` (`docs/security.md`);
a rebuild therefore gets the newest 29.x engine and the current plugin
versions, not necessarily these exact ones.

## Networks

```
Internet ──► Hetzner Cloud Firewall (22, 80, 443, 2222) ──► host
                                                              │
   :443 ──► caddy ──┬── git.lab.test  ──► gitlab:80
                    ├── wiki.lab.test ──► xwiki:8080
                    ├── pm.lab.test   ──► openproject:8080
                    └── ldap.lab.test ──► lldap:17170
   :2222 ───────────────────────────────► gitlab:22
```

- `edge` (external, created by `bootstrap.sh`): Caddy and every web frontend.
  Caddy carries network aliases for all four hostnames so that containers
  reach each other under the same names as browsers do (hairpin through the
  proxy; certificates match in both directions).
- `<stack>_internal` (one per stack): application ↔ its database. Not
  reachable from other stacks.
- `ldap` (external): lldap and the three LDAP clients.
- No container except Caddy (80/443) and GitLab (2222) publishes a port.

## Data flows

| From | To | Protocol | Purpose |
|---|---|---|---|
| Browser | Caddy | HTTPS | all UIs |
| Caddy | backends | HTTP (internal network) | proxying; `X-Forwarded-Proto: https` tells backends the client used TLS |
| GitLab | OpenProject | HTTPS via Caddy | webhook on push, merge request, comment and pipeline events; GitLab allows outbound requests to `pm.lab.test` only (ADR-0014, `docs/integration.md` §2) |
| XWiki | OpenProject | HTTPS via Caddy | OpenProject macro (work package lists) — *extension step, not built* (`docs/integration.md` §3) |
| GitLab, XWiki, OpenProject | lldap | LDAP (LDAPS planned) | authentication |
| Git client | GitLab | SSH :2222 | clone/push |

## Host requirements

What any host must provide before the stacks, `backup.sh` and `restore.sh`
work. `scripts/bootstrap.sh` is the tested implementation of this list for
Debian 13; everything below it is what a port to another distribution has to
reproduce.

| Requirement | Value | Why |
|---|---|---|
| Docker Engine + Compose plugin | Docker CE 29.x, Compose v5 | pinned and tested; the compose files use current syntax |
| `userns-remap` | user `dockremap`, subordinate range `100000:65536` in `/etc/subuid` and `/etc/subgid`, set **before the first image pull** | container root is unprivileged on the host (ADR-0002); the fixed range makes every bind-mount owner reproducible across rebuilds (P-008, P-009) |
| `/srv` layout | directories and owners exactly as in `create_srv_layout` (`bootstrap.sh`) — 0, 100000, 101000, 100070 | the containers' users, offset by the remap base; a wrong owner is a service that cannot start or a restore that cannot be read |
| Docker networks | `edge` (bridge), `ldap` (bridge, `--internal`) | the proxy publishes on `edge`; LDAP traffic never leaves `ldap` |
| Packages | `git`, `rsync`, `age`, `curl`, `openssl` | clone, off-host copy, set encryption, health checks, PKI |
| Group `backup` with the admin as member | Debian's GID 34; create it where it does not exist | encrypted sets are `root:backup 0640` for the off-host pull without root |
| Free ports | 22 (host sshd), 80, 443, 2222 | the only listeners; everything else stays internal |
| systemd | for `backup.timer` (optional: run `backup.sh` by hand instead) | nightly sets |
| Memory / disk | 16 GB RAM, ≥ 40 GB disk | GitLab alone is limited to 8 GiB |

Not required by the stacks but part of the baseline on the reference host:
sshd hardening, unattended upgrades, the read-only sudoers rule
(`docs/security.md`, "Host").

**Out of scope:** Docker Desktop on macOS or Windows — the engine runs in a
VM whose file sharing rewrites bind-mount ownership and where
`userns-remap` does not apply; a demo profile with named volumes and without
the remap layer would be a separate deployment target, not a port of this
one. A Debian 13 VM on those systems runs the repository unchanged.

## Threat model (scope and assumptions)

- **Assets:** source code, wiki content, project data, user credentials, the
  private CA.
- **Exposure:** one public IP. Only 22, 80, 443 and 2222 are reachable.
- **Attackers considered:** (1) an unauthenticated attacker on the Internet,
  (2) an attacker who has compromised one application container,
  (3) an insider with a valid account.
- **Not in scope:** the Hetzner hypervisor, physical security, denial of
  service, the workstation.
- **Trust model:** defence in depth with one identity source — not a Zero
  Trust architecture. Two zones are trusted: the internal Docker network
  `ldap` (plain LDAP) and the Docker address pool for proxy headers. The
  assessment and the target architecture are in ADR-0006, "Trust model
  assessment".
- **Main controls:** SSH key-only access; Cloud Firewall; single TLS entry
  point; no published backend ports; `userns-remap` and container hardening
  (limits attacker 2); per-service read-only LDAP bind users and per-service
  access groups (limits attacker 2 and 3); secrets outside git; backups
  encrypted off-host; CA key offline.

## What Caddy does implicitly

Verified against the Caddy documentation on 2026-09-18 and against the running
proxy (`curl --resolve … --cacert ca.crt`):

| Behaviour | Source | Note |
|---|---|---|
| HTTP → HTTPS redirect (308) on port 80 for every site with a hostname | [Automatic HTTPS](https://caddyserver.com/docs/automatic-https) | confirmed: `curl http://git.lab.test/` → `308 → https://git.lab.test/` |
| No ACME because `tls <cert> <key>` supplies certificates | [tls directive](https://caddyserver.com/docs/caddyfile/directives/tls) | log: "skipping automatic certificate management because … certificates are already loaded" |
| `reverse_proxy` sets `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Host` and passes `Host` through unchanged | [reverse_proxy directive, section "Headers"](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy) | this is the header contract every backend relies on |
| Upstream connections are plaintext HTTP when only `host:port` is given | same page | backends terminate no TLS themselves |
| WebSocket upgrade is proxied automatically | same page | needed by GitLab |
| Protocols default to `h1 h2 h3`; restricted here to `h1 h2` | [Global options, "servers"](https://caddyserver.com/docs/caddyfile/options) | HTTP/3 would need UDP/443 published and allowed; deliberately off (see P-006) |
| Admin API on `localhost:2019` by default; disabled here with `admin off` | [Global options, "admin"](https://caddyserver.com/docs/caddyfile/options) | consequence: no `caddy reload`; configuration changes need a container restart |
| Security headers are **not** set by default | [header directive](https://caddyserver.com/docs/caddyfile/directives/header) | set explicitly in the `hardened` snippet; CSP left to the applications |
| No request body limit unless `request_body { max_size }` is set | [request_body directive](https://caddyserver.com/docs/caddyfile/directives/request_body) | deliberately not set: each application's own upload limit applies (GitLab's NGINX unlimited, OpenProject/XWiki attachment settings), so Git pushes over HTTPS are never cut by the proxy |
