# services/lldap — shared user directory

Design: [ADR-0006](../../docs/adr/0006-identity.md) (why lldap, directory
layout), [ADR-0011](../../docs/adr/0011-lldap-container.md) (container
decisions). Client configuration per service: [`docs/integration.md`](../../docs/integration.md).

## Files
- `compose.yaml` — one rootless container: UI on `lldap:17170` (reached by
  Caddy as `https://ldap.lab.test`), LDAP on `lldap:3890` (internal network
  `ldap` only, never published).
- `.env` — three secrets, see `.env.example` in the repository root. Not in
  git.

## Host prerequisites
```
/srv/lldap/   owner 101000 (container UID 1000 + 100000)   -> /data: lldap_config.toml, users.db
```
Created by `scripts/bootstrap.sh`. Networks `edge` and `ldap` exist (bootstrap).

## First start
```
cd ~/Test-Projekt/services/lldap
umask 077 && printf 'LLDAP_JWT_SECRET=%s\nLLDAP_KEY_SEED=%s\nLLDAP_LDAP_USER_PASS=%s\n' \
  "$(openssl rand -base64 32)" "$(openssl rand -base64 32)" "$(openssl rand -base64 24)" > .env
cat .env      # copy LLDAP_KEY_SEED and LLDAP_LDAP_USER_PASS into the password manager now
sudo docker compose config --quiet && sudo docker compose up -d
sudo docker logs lldap
```
All three values are generated, so no secret ever appears on the command
line or in the shell history; `umask 077` makes the new `.env` mode 600.
The key seed must never change afterwards; the admin password can be
changed in the UI later (then update `.env` too, or set
`LLDAP_FORCE_LDAP_USER_PASS_RESET` — see the config template).

Then `https://ldap.lab.test` → user `admin`, the password from `.env`.

## Directory set-up (ADR-0006, once)
In the web UI, as `admin`:

1. **Groups** → create `git_user`, `wiki_user`, `pm_user` (one access group
   per service; a service only accepts members of its group).
2. **Users** → create the service accounts `svc-gitlab`, `svc-xwiki`,
   `svc-openproject` (e-mail is mandatory in lldap, use
   `svc-<name>@lab.test`), each with a generated password that goes into the
   respective stack's `.env` (`*_LDAP_BIND_PASSWORD`). Add each to the
   built-in group **`lldap_strict_readonly`**: they may search and bind,
   nothing else.
3. **Users** → two test users (e.g. `alice`, `bob`) with `git_user` (and
   later `wiki_user`/`pm_user`) membership.

The resulting DNs the services use:
- users: `uid=<username>,ou=people,dc=lab,dc=test`
- groups: `cn=<group>,ou=groups,dc=lab,dc=test`
- bind user for GitLab: `uid=svc-gitlab,ou=people,dc=lab,dc=test`

## On-/offboarding (runbook)
**Onboarding:** Users → Create user (username, e-mail, display name, initial
password handed over out of band) → Groups: add the access groups the person
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
`docs/integration.md`.
