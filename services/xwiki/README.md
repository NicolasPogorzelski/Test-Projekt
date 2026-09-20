# services/xwiki — XWiki LTS

Design: [ADR-0013](../../docs/adr/0013-xwiki-container.md) (root without
capabilities, JVM trust store, proxy headers, heap); product choice and image
in [`docs/architecture.md`](../../docs/architecture.md).

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

## First start
```
cd ~/Test-Projekt/services/xwiki
install -m 600 /dev/null .env && printf 'XWIKI_DB_PASSWORD=%s\n' "$(openssl rand -hex 24)" > .env
# JVM trust store: the image's cacerts plus our CA, written to the host (repeat after an image update)
sudo docker run --rm -v ~/Test-Projekt/pki/ca.crt:/ca.crt:ro --entrypoint sh xwiki:17.10.13-postgres-tomcat \
  -c 'keytool -importcert -noprompt -cacerts -storepass changeit -alias lab-test-root-ca -file /ca.crt >&2 && cat "$JAVA_HOME/lib/security/cacerts"' \
  | sudo tee /srv/xwiki/cacerts > /dev/null && sudo chmod 644 /srv/xwiki/cacerts && ls -l /srv/xwiki/cacerts
sudo docker compose config --quiet && sudo docker compose up -d
sudo docker logs -f xwiki        # WAR unpacks, then "Server startup in [...] ms"; 1-3 min on first start
```
The `keytool` line runs a throw-away container with the CA mounted, adds the
CA to the JVM's default store (`-cacerts`; `changeit` is Java's fixed default
password for that file, it protects nothing) and prints the resulting file to
stdout, which `tee` writes to `/srv/xwiki/cacerts`. keytool's own messages go
to stderr so they do not end up in the file. The file must exist before
`compose up`: Docker would otherwise create a directory at the mount point.

Then `https://wiki.lab.test` → the distribution wizard runs on the first
visit: create the admin user (username `admin`, password from the password
manager), install the default flavor ("XWiki Standard Flavor"), wait for the
extensions to install (several minutes).

## After the wizard (admin)
1. Registration and anonymous reading off: Administration → *Users &
   Rights* → *Rights* → tab **Users** → row *Unregistered Users*: click
   **Register** until it shows deny (✗); tick *Prevent unregistered users
   from viewing pages* and *… from editing pages*. On the *Registration*
   page set "Who should be allowed to create new user accounts" to
   *Closed* if offered. Verify, logged out:
   `/bin/register/XWiki/XWikiRegister` and `/bin/view/Main/` both redirect
   to the login page.
2. LDAP ([ADR-0013](../../docs/adr/0013-xwiki-container.md) §5) — three parts, all needed:
   1. **Two extensions.** Administration → *Extensions*: install **LDAP
      Authenticator** (`org.xwiki.contrib.ldap:ldap-authenticator`, the
      logic) *and* **LDAP Application** (`org.xwiki.contrib.ldap:ldap-ui`,
      the admin form). The second one does not show up in the default
      search — use *Advanced search* with the id and version (9.16.6).
   2. **Activate the authenticator** — a `xwiki.cfg` line, no UI for it in
      this version (the LDAP section shows "LDAP authentication is not
      enabled" until it is set). The entrypoint copies a `xwiki.cfg` found
      in the permanent directory into `WEB-INF` on every start:
      ```
      sudo docker cp xwiki:/usr/local/tomcat/webapps/ROOT/WEB-INF/xwiki.cfg /srv/xwiki/data/data/xwiki.cfg
      echo 'xwiki.authentication.authclass=org.xwiki.contrib.ldap.XWikiLDAPAuthServiceImpl' | sudo tee -a /srv/xwiki/data/data/xwiki.cfg
      sudo chown 100000:100000 /srv/xwiki/data/data/xwiki.cfg && sudo chmod 640 /srv/xwiki/data/data/xwiki.cfg
      sudo docker compose restart xwiki      # log: "Synchronizing config file xwiki.cfg..."
      ```
      That file is now part of the data volume (and of the backup).
   3. **Configure** — Administration → *Other* → *LDAP*
      (`?section=LDAP`): Ldap = Yes, server `lldap`, port `3890`,
      login matching `uid=svc-xwiki,ou=people,dc=lab,dc=test` + its
      password, restrict to group `cn=wiki_user,ou=groups,dc=lab,dc=test`,
      base DN `ou=people,dc=lab,dc=test`, UID attribute `uid`, *Try local
      login* Yes (keeps `admin` usable), update user after login Yes,
      user fields mapping `first_name`→`givenName`, `last_name`→`sn`,
      `email`→`mail`. Save.
   Add `alice` to `wiki_user` in lldap; sign in as `alice` (works), as
   `bob` (refused). The log shows a `WARN … Abusive modification of the
   cached document [xwiki:XWiki.alice()]` on the first LDAP sign-in — a
   known incompatibility warning of the 9.x authenticator with XWiki 17,
   tolerated by the platform; the profile is created and the login works.

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
