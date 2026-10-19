# services/lldap — shared user directory

Design: [ADR-0006](../../docs/adr/0006-identity.md) (why lldap, directory
layout), [ADR-0011](../../docs/adr/0011-lldap-container.md) (container
decisions). Client configuration per service: [`docs/integration.md`](../../docs/integration.md).
First installation, step by step: [`docs/install.md`](../../docs/install.md)
5.7 (start) and 5.8 (directory). This file is the reference for the stack.

## Files
- `compose.yaml` — one rootless container: UI on `lldap:17170` (reached by
  Caddy as `https://ldap.lab.test`), LDAP on `lldap:3890` (internal network
  `ldap` only, never published).
- `.env` — three secrets, see [`.env.example`](../../.env.example) in the repository root. Not in
  git.

## Host prerequisites
```
/srv/lldap/   owner 101000 (container UID 1000 + 100000)   -> /data: lldap_config.toml, users.db
```
Created by [`scripts/bootstrap.sh`](../../scripts/bootstrap.sh). Networks `edge` and `ldap` exist (bootstrap).

## The three secrets in `.env`
Generated on the host by the `install … printf` line in
[`docs/install.md`](../../docs/install.md) 5.7, so no secret appears on the
command line or in the shell history; `install -m 600 /dev/null .env` creates
the file with mode 600 before anything is written into it. Run that line once:
a second run writes a new key seed.

| Variable | Purpose | Change later? |
|---|---|---|
| `LLDAP_JWT_SECRET` | signs UI sessions | yes — logs everyone out of the UI |
| `LLDAP_KEY_SEED` | derives the key that encrypts stored secrets | **never** — a new seed breaks the directory; part of every backup |
| `LLDAP_LDAP_USER_PASS` | password of the built-in `admin` (UI and LDAP bind) | read on the very first start only; change it in the UI afterwards (then `.env` no longer reflects it, or set `LLDAP_FORCE_LDAP_USER_PASS_RESET` — see the config template) |

## Directory layout (ADR-0006)
Created once in the web UI ([`docs/install.md`](../../docs/install.md) 5.8):

| Kind | Name | Groups | Purpose |
|---|---|---|---|
| group | `git_user`, `wiki_user`, `pm_user` | — | one access group per service; a service accepts only members of its group |
| service account | `svc-gitlab`, `svc-xwiki`, `svc-openproject` | `lldap_strict_readonly` | bind accounts of the services: search and bind, nothing else |
| test user | `alice` / `bob` | all three / `git_user` only | positive and negative sign-in test |

Where each bind password goes: `svc-gitlab` into `services/gitlab/.env`
(`GITLAB_LDAP_BIND_PASSWORD`); `svc-openproject` and `svc-xwiki` into the
LDAP form of the respective admin UI — not into a `.env`.

A service account **without** `lldap_strict_readonly` binds successfully but
sees only itself, so every search returns nothing and the service later
reports "no users found". The `ldapsearch` check in 5.8 catches that.

The DNs the services use:
- users: `uid=<username>,ou=people,dc=lab,dc=test`
- groups: `cn=<group>,ou=groups,dc=lab,dc=test`
- bind users: `uid=svc-<service>,ou=people,dc=lab,dc=test`

## On-/offboarding (runbook)
**Onboarding:** Users → Create user (username, e-mail, display name, **first
and last name** — OpenProject refuses to create an account without them —
initial password handed over out of band) → Groups: add the access groups the person
needs (`git_user`, `wiki_user`, `pm_user`). The person can sign in to each
service immediately; GitLab creates its local user record at first login.

**Offboarding:** remove the user from all access groups first (this cuts
access at the next login/sync in every service while keeping the audit
trail intact), then delete the user in lldap. Afterwards in the services:
GitLab → Admin → Users → block the user (repositories and history stay);
OpenProject/XWiki → deactivate the account. Rotate any service credentials
the person knew (bind passwords, deploy keys).

**Password reset:** an admin or a member of `lldap_password_manager` sets a
new password in the UI; self-service reset by e-mail is not available (no
mail server).

## Verification
```
# runs as UID 1000, all capabilities dropped, read-only rootfs  [1000:1000 [ALL] true]
sudo docker inspect --format '{{.Config.User}} {{.HostConfig.CapDrop}} {{.HostConfig.ReadonlyRootfs}}' lldap
# healthy
sudo docker ps --filter name=lldap --format '{{.Status}}'
# LDAP listener answers (anonymous search is rejected by lldap, which still proves the port; "ldap" is
# --internal without package downloads, so the throw-away client joins "edge", where lldap also is)
# [an LDAP result code, not "Can't contact LDAP server"]
sudo docker run --rm --network edge alpine sh -c 'apk add -q openldap-clients && ldapsearch -x -H ldap://lldap:3890 -b dc=lab,dc=test -s base'
# UI through Caddy: basic-auth gate first  [401 without credentials, 200 with the gate credential]
curl -sS -o /dev/null -w '%{http_code}\n' https://ldap.lab.test/
curl -sS -o /dev/null -w '%{http_code}\n' -u '<gate user>' https://ldap.lab.test/
```

Results on 2026-09-19 (first build): started on the first attempt with
`read_only` and `cap_drop: ALL`; the gate answers 401 before lldap is
reached; `gitlab-rake gitlab:ldap:check` bound as `svc-gitlab` and returned
exactly the `git_user` member; positive and negative sign-in as documented in
[`docs/integration.md`](../../docs/integration.md).
