# services/openproject — OpenProject Community Edition

Design: [ADR-0003](../../docs/adr/0003-project-management-tool.md) (why
OpenProject), [ADR-0012](../../docs/adr/0012-openproject-container.md)
(image variant, processes, database hardening). First installation, step by
step: [`docs/install.md`](../../docs/install.md) 5.13. This file is the
reference for the stack.

## Files
- `compose.yaml` — five definitions: `db` (PostgreSQL 17, non-root),
  `cache` (memcached), `seeder` (one-off: schema load / migrations, exits),
  `web` (Puma, reached by Caddy as `openproject:8080`), `worker` (background
  jobs). No cron ([ADR-0012](../../docs/adr/0012-openproject-container.md)).
- `.env` — two hex secrets, see [`.env.example`](../../.env.example) in the repository root. Not
  in git.

## Host prerequisites
```
/srv/openproject/assets/   owner 101000 (app user 1000 + 100000)      -> /var/openproject/assets (uploads)
/srv/openproject/db/       owner 100070 (postgres user 70 + 100000)   -> /var/lib/postgresql/data
```
Created by [`scripts/bootstrap.sh`](../../scripts/bootstrap.sh). Networks `edge` and `ldap` exist
(bootstrap); `openproject_internal` is created by this stack and is
`internal: true` (db and cache are unreachable from anywhere else).

## First start, in short
Two hex secrets in `.env` (hex because the DB password is embedded in
`DATABASE_URL`, where `/` or `+` would break it), then `up -d`. The `seeder`
loads the schema and exits; `sudo docker compose ps -a` shows it as
`Exited (0)` — without `-a` it does not appear at all. `web` turns
`(healthy)` about a minute later. First sign-in: `admin` / `admin`
(OpenProject's seeded default), a new password is forced.
`OPENPROJECT_SECRET_KEY_BASE` signs sessions and tokens; it is part of every
backup.

## After the first sign-in (admin) — what and why
Menu names of OpenProject 16.6; the exact clicks are in
[`docs/install.md`](../../docs/install.md) 5.13.

1. **Self-registration disabled** (Administration → Authentication → Login
   and registration): accounts come from lldap only.
2. **Host name and HTTPS** come from `compose.yaml`
   (`OPENPROJECT_HOST__NAME`, `OPENPROJECT_HTTPS`); System settings → General
   only shows the host name, and there is no *Protocol* field. Set in the
   environment, they are correct after every rebuild.
3. **Projects private by default, Wiki module off, GitLab module on**
   (Administration → Projects → New project) — documentation lives in XWiki,
   code links come from GitLab ([ADR-0003](../../docs/adr/0003-project-management-tool.md),
   [`docs/integration.md`](../../docs/integration.md)). The defaults apply only
   to projects created later: the seeder's two demo projects must be switched
   by hand (Project settings → Modules), or one keeps its wiki
   ([P-022](../../docs/problems.md#p-022--the-second-seeded-openproject-project-kept-the-wiki-module)). Check:
   `select p.identifier, em.name from enabled_modules em join projects p on p.id=em.project_id where em.name='wiki';`
   must return no rows.
4. **LDAP** (30-minute time-box, [ADR-0012](../../docs/adr/0012-openproject-container.md) §4) under
   Authentication → **LDAP connections**: host `lldap`, port **`3890`**, no
   encryption (internal network, [ADR-0006](../../docs/adr/0006-identity.md)), bind account
   `uid=svc-openproject,ou=people,dc=lab,dc=test` (its password goes into this
   form, not into `.env`), base DN `ou=people,dc=lab,dc=test`, filter
   `(memberof=cn=pm_user,ou=groups,dc=lab,dc=test)`, attributes `uid` /
   `givenName` / `sn` / `mail`, automatic user creation on. A wrong port shows
   up only as `Failed login … invalid credentials`, not as a connection error.
   `alice` (in `pm_user`) gets in, `bob` is refused.

## Verification (evidence for docs/security.md)
```
# all processes non-root, db/cache without capabilities, db read-only
sudo docker inspect --format '{{.Name}} user={{.Config.User}} capdrop={{.HostConfig.CapDrop}} ro={{.HostConfig.ReadonlyRootfs}}' openproject openproject-worker openproject-db openproject-cache
sudo docker exec openproject id -u                                  # 1000
sudo docker exec openproject-cache id -u                            # not 0 (image user), otherwise add user:
# health, seeder exit code (-a: the seeder has exited)
sudo docker compose ps -a
# only through Caddy: HTTPS 302/200 with the hardened headers, no direct port  [no ports published]
curl -sI https://pm.lab.test/ | grep -Ei '^(HTTP|strict-transport|x-content-type|referrer-policy|server:)'
sudo docker port openproject
# memory after start (ADR-0012)
sudo docker stats --no-stream openproject openproject-worker openproject-db openproject-cache
```

## Operations
- Configuration change: edit `compose.yaml`, `sudo docker compose up -d`
  (seeder re-runs migrations, web/worker restart).
- Upgrade: bump the image tag, `up -d`; the seeder migrates the schema.
- Backup: `pg_dump` from `openproject-db` + `/srv/openproject/assets` +
  `.env` (`SECRET_KEY_BASE`) — [ADR-0008](../../docs/adr/0008-backup-and-reinstall.md), day 3.
- Not running: `cron` (reminders, digests) — add
  `command: "./docker/prod/cron"` as a sixth service once a mail server
  exists ([ADR-0012](../../docs/adr/0012-openproject-container.md) §2).

Results on 2026-09-19 (first build): seeder exited 0 after ~1 minute, web
healthy; `db` 70:70 with `[ALL]` dropped and read-only, `cache` as
`memcache` with the same, web/worker as UID 1000; no published port; memory
web 1.56 GiB / worker 640 MiB / db 65 MiB / cache 2 MiB at idle (web limit
raised to 3 GiB). Sign-in through Caddy with the hardened headers plus
OpenProject's own Content-Security-Policy; LDAP verified with a member and a
non-member of `pm_user` ([`docs/integration.md`](../../docs/integration.md)).
