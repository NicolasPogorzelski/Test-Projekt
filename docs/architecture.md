# Architecture

## Components

| Component | Image (pinned version) | Role | Internal port |
|---|---|---|---|
| Caddy | `caddy:<TBD>` | reverse proxy, TLS termination | 8080/8443 (published 80/443) |
| GitLab CE | `gitlab/gitlab-ce:<TBD>-ce.0` | source code, CI/CD | 80 (HTTP), 22 (SSH, published 2222) |
| XWiki | `xwiki:<TBD>-postgres-tomcat` | documentation | 8080 |
| OpenProject | `openproject/openproject:<TBD>` | project management | 80 |
| lldap | `lldap/lldap:<TBD>` | LDAP directory + web UI | 3890 (LDAP), 17170 (web) |
| PostgreSQL ×2 | `postgres:<TBD>` | databases for XWiki and OpenProject | 5432 (internal only) |

## Networks

```
Internet ──► Hetzner Cloud Firewall (22, 80, 443, 2222) ──► host
                                                              │
   :443 ──► caddy ──┬── git.lab.test  ──► gitlab:80
                    ├── wiki.lab.test ──► xwiki:8080
                    ├── pm.lab.test   ──► openproject:80
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
| GitLab | OpenProject | HTTPS via Caddy | webhooks (MR/commit events) |
| XWiki | OpenProject | HTTPS via Caddy | OpenProject macro (work package lists) |
| GitLab, XWiki, OpenProject | lldap | LDAP (LDAPS planned) | authentication |
| Git client | GitLab | SSH :2222 | clone/push |

## Threat model (scope and assumptions)

- **Assets:** source code, wiki content, project data, user credentials, the
  private CA.
- **Exposure:** one public IP. Only 22, 80, 443 and 2222 are reachable.
- **Attackers considered:** (1) an unauthenticated attacker on the Internet,
  (2) an attacker who has compromised one application container,
  (3) an insider with a valid account.
- **Not in scope:** the Hetzner hypervisor, physical security, denial of
  service, the workstation.
- **Main controls:** SSH key-only access; Cloud Firewall; single TLS entry
  point; no published backend ports; `userns-remap` and container hardening
  (limits attacker 2); per-service read-only LDAP bind users and per-service
  access groups (limits attacker 2 and 3); secrets outside git; backups
  encrypted off-host; CA key offline.

## What Caddy does implicitly

_TBD — verify each item against the Caddy documentation and link the section:_

- Automatic HTTP → HTTPS redirect for every site block with a hostname.
- TLS defaults (protocol versions, cipher suites, curves).
- `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Host` set on
  `reverse_proxy` requests; `Host` passed through.
- WebSocket upgrade passed through by `reverse_proxy`.
- Not set automatically: HSTS and other security headers (set explicitly in
  the Caddyfile).
