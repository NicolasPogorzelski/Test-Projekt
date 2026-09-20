# services/openproject — OpenProject Community Edition

Design: [ADR-0003](../../docs/adr/0003-project-management-tool.md) (why
OpenProject), [ADR-0012](../../docs/adr/0012-openproject-container.md)
(image variant, processes, database hardening).

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

## First start
```
cd ~/Test-Projekt/services/openproject
install -m 600 /dev/null .env && printf 'OPENPROJECT_DB_PASSWORD=%s\nOPENPROJECT_SECRET_KEY_BASE=%s\n' \
  "$(openssl rand -hex 24)" "$(openssl rand -hex 64)" > .env
cat .env      # copy SECRET_KEY_BASE into the password manager (backup-relevant)
sudo docker compose config --quiet && sudo docker compose up -d
sudo docker compose logs -f seeder     # "Initialising database" … seed … exits 0 (2-4 min)
sudo docker compose ps                 # db healthy, cache up, seeder Exited (0), web (healthy) after ~1 min, worker up
```
Then `https://pm.lab.test` → user `admin`, password `admin` (OpenProject's
seeded default; the first sign-in forces a password change).

## After the first sign-in (admin)
1. Change the admin password (forced), store it in the password manager.
2. Administration → Users and permissions → Settings: **Self-registration:
   disabled**.
3. Administration → System settings → General: check *Host name*
   `pm.lab.test`, *Protocol* HTTPS.
4. Administration → Projects → **New project**: "New projects are public by
   default" **off**; default modules: **Wiki off**, **GitLab on** ([ADR-0003](../../docs/adr/0003-project-management-tool.md),
   [`docs/integration.md`](../../docs/integration.md)). Then check *every* existing project's
   *Project settings → Modules* — the seeder creates two demo projects and
   both start with the wiki on ([P-022](../../docs/problems.md#p-022--the-second-seeded-openproject-project-kept-the-wiki-module)). Verify:
   `select p.identifier, em.name from enabled_modules em join projects p on p.id=em.project_id where em.name='wiki';`
   must return no rows.
5. LDAP (30-minute time-box, [ADR-0012](../../docs/adr/0012-openproject-container.md) §4): Administration → Authentication →
   LDAP authentication → *New*:
   - Name `lldap`, Host `lldap`, Port `3890`, Connection encryption *none*
     (internal network, [ADR-0006](../../docs/adr/0006-identity.md))
   - Account `uid=svc-openproject,ou=people,dc=lab,dc=test`, password of
     `svc-openproject` from lldap
   - Base DN `ou=people,dc=lab,dc=test`, Filter
     `(memberof=cn=pm_user,ou=groups,dc=lab,dc=test)`
   - Attribute mapping: login `uid`, first name `givenName`, last name `sn`,
     e-mail `mail`; **Automatic user creation** on.
   Then add `alice` to `pm_user` in lldap and sign in as `alice`; `bob`
   (not in `pm_user`) must be refused.

## Verification (evidence for docs/security.md)
```
# all processes non-root, db/cache without capabilities, db read-only
sudo docker inspect --format '{{.Name}} user={{.Config.User}} capdrop={{.HostConfig.CapDrop}} ro={{.HostConfig.ReadonlyRootfs}}' openproject openproject-worker openproject-db openproject-cache
sudo docker exec openproject id -u                                  # 1000
sudo docker exec openproject-cache id -u                            # not 0 (image user), otherwise add user:
# health, seeder exit code
sudo docker compose ps
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
