# services/xwiki — XWiki LTS

Design: [ADR-0013](../../docs/adr/0013-xwiki-container.md) (root without
capabilities, JVM trust store, proxy headers, heap); product choice and image
in [`docs/architecture.md`](../../docs/architecture.md). First installation,
step by step: [`docs/install.md`](../../docs/install.md) 5.14–5.15. This file
is the reference for the stack.

## Files
- `compose.yaml` — `db` (PostgreSQL 17, non-root, all capabilities dropped,
  read-only) and `xwiki` (Tomcat, reached by Caddy as `xwiki:8080`, root
  with all capabilities dropped).
- `tomcat/server.xml` — Tomcat's stock configuration from the image plus
  the `RemoteIpValve` ([ADR-0013](../../docs/adr/0013-xwiki-container.md) §3), mounted read-only.
- `.env` — one hex secret, see [`.env.example`](../../.env.example). Not in git.

## Host prerequisites
```
/srv/xwiki/data/            owner 100000 (container root)   -> /usr/local/xwiki (permanent directory)
/srv/xwiki/data/data/xwiki.cfg  owner 100000, mode 640      XWiki configuration override, copied into WEB-INF on every start (see LDAP)
/srv/xwiki/db/              owner 100070 (postgres user 70) -> /var/lib/postgresql/data
/srv/xwiki/cacerts          root 644, built below           -> JVM trust store (image cacerts + lab.test CA)
```
Directories by [`scripts/bootstrap.sh`](../../scripts/bootstrap.sh); networks `edge`/`ldap` exist
(bootstrap), `xwiki_internal` is created by this stack.

## JVM trust store
XWiki's JVM keeps its own list of trusted CAs and ignores the system's, so it
must learn the lab CA. [`docs/install.md`](../../docs/install.md) 5.14 builds
`/srv/xwiki/cacerts` with a throw-away container: the CA from
`/srv/proxy/certs/ca.crt` is mounted, `keytool -importcert -cacerts` adds it to
the image's default store (`changeit` is Java's fixed default password for that
file, it protects nothing), and the resulting file is printed to stdout, which
`sudo tee` writes to the host. keytool's own messages go to stderr so they do
not end up in the file. The file must exist before `compose up`: Docker would
otherwise create a directory at the mount point. Rebuild it after an image
update (the JRE may change) or a CA change — not for a renewed leaf
certificate.

## Wizard and hardening
On the first visit the distribution wizard creates the `admin` account and
installs the *XWiki Standard Flavor* (several minutes). Run it right after the
start: until then anyone who reaches `wiki.lab.test` can create that account.
Then close registration and anonymous reading (Administer Wiki → Users &
Rights → Rights → tab Users → *Unregistered Users*: **Register** to ✗ — it
cycles empty → ✓ → ✗ —, *Prevent unregistered users from viewing / editing
pages*; *Registration* closed). Check, logged out:
`/bin/register/XWiki/XWikiRegister` and `/bin/view/Main/` both answer `302`
to the login page.

## LDAP
Design: [ADR-0013](../../docs/adr/0013-xwiki-container.md) §5. Three parts,
all needed, **in this order** — steps in
[`docs/install.md`](../../docs/install.md) 5.15:

1. **Two extensions**, both 9.16.6: *LDAP Authenticator*
   (`org.xwiki.contrib.ldap:ldap-authenticator`, the sign-in logic) and *LDAP
   Application* (`org.xwiki.contrib.ldap:ldap-ui`, the admin form; may need
   *Advanced search* by id). Check *Installed extensions* — a success message
   alone is not proof.
2. **The form** (`?section=LDAP`): server `lldap:3890`, bind
   `uid=svc-xwiki,ou=people,dc=lab,dc=test` + its password, group
   `cn=wiki_user,ou=groups,dc=lab,dc=test`, base DN `ou=people,dc=lab,dc=test`,
   UID attribute `uid`, *Try local login* **Yes** (keeps `admin` usable), user
   fields `first_name`→`givenName`, `last_name`→`sn`, `email`→`mail`.
3. **Activate** — one line in `xwiki.cfg`, no UI for it in this version. The
   entrypoint copies a `xwiki.cfg` from the permanent directory into
   `WEB-INF` on every start, so the line lives in
   `/srv/xwiki/data/data/xwiki.cfg` (owner 100000, 640) and is part of the
   backup.

Why the order: once the line is active, every sign-in goes through LDAP first;
with an empty or missing form even `admin` is locked out. The way back is to
delete the line and restart — the form values are kept.

On the first LDAP sign-in the log shows `WARN … Abusive modification of the
cached document [xwiki:XWiki.alice()]` — a known incompatibility warning of
the 9.x authenticator with XWiki 17, tolerated by the platform; the profile is
created and the login works.

## Verification (evidence for docs/security.md)
```
# root without capabilities, db non-root read-only  [xwiki user= capdrop=[ALL]; db user=70:70 capdrop=[ALL] ro=true]
sudo docker inspect --format '{{.Name}} user={{.Config.User}} capdrop={{.HostConfig.CapDrop}} ro={{.HostConfig.ReadonlyRootfs}}' xwiki xwiki-db
# no published port; healthy
sudo docker port xwiki; sudo docker compose ps --format '{{.Name}} {{.Status}}'
# proxy headers honoured: links and redirects are https, not http  [Location: https://wiki.lab.test/...]
curl -sSI https://wiki.lab.test/ | grep -Ei '^(HTTP|location|strict-transport|x-content-type|referrer-policy|server:)'
# JVM trusts the private CA  [lab-test-root-ca listed]
sudo docker exec xwiki keytool -list -cacerts -storepass changeit -alias lab-test-root-ca
# memory after start (ADR-0013)
sudo docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' xwiki xwiki-db
```

## Operations
- Configuration change: edit `compose.yaml` or `tomcat/server.xml`,
  `sudo docker compose up -d`.
- Upgrade: bump the image tag, rebuild `/srv/xwiki/cacerts` (JRE may
  change), `up -d`; XWiki migrates its data on start.
- Backup: `pg_dump` from `xwiki-db` + `/srv/xwiki/data` + `.env` +
  `/srv/xwiki/cacerts` (regenerable) — [ADR-0008](../../docs/adr/0008-backup-and-reinstall.md), day 3.

Results on 2026-09-19 (first build): started on the first attempt with
`cap_drop: ALL` as root; db 70:70 read-only with all capabilities dropped;
no published port; `keytool -list` shows `lab-test-root-ca` with the CA's
SHA-256 fingerprint; redirects are `https://`; memory 2.18 GiB after the
flavor and LDAP extensions (limit raised to 3 GiB), db 63 MiB. LDAP sign-in
verified with a member and a non-member ([`docs/integration.md`](../../docs/integration.md), [P-012](../../docs/problems.md#p-012--xwiki-ldap-installed-configured-and-still-invalid-credentials)).
