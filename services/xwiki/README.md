# services/xwiki — XWiki LTS

Design: [ADR-0013](../../docs/adr/0013-xwiki-container.md) (root without
capabilities, JVM trust store, proxy headers, heap); product choice and image
in [`docs/architecture.md`](../../docs/architecture.md).

## Files
- `compose.yaml` — `db` (PostgreSQL 17, non-root, all capabilities dropped,
  read-only) and `xwiki` (Tomcat, reached by Caddy as `xwiki:8080`, root
  with all capabilities dropped).
- `tomcat/server.xml` — Tomcat's stock configuration from the image plus
  the `RemoteIpValve` (ADR-0013 §3), mounted read-only.
- `.env` — one hex secret, see `.env.example`. Not in git.

## Host prerequisites
```
/srv/xwiki/data/     owner 100000 (container root)         -> /usr/local/xwiki (attachments, Solr index, config copies)
/srv/xwiki/db/       owner 100070 (postgres user 70)       -> /var/lib/postgresql/data
/srv/xwiki/cacerts   root 644, built below                 -> JVM trust store (image cacerts + lab.test CA)
```
Directories by `scripts/bootstrap.sh`; networks `edge`/`ldap` exist
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
1. Registration off: Administration (wiki) → *Users & Rights* → *Rights*:
   for the *Guest*/unregistered users deny **Register**; alternatively
   Administration → *Registration* → disable. Verify: logged out,
   `/xwiki/bin/register/XWiki/XWikiRegister` must not offer a form.
2. LDAP (30-minute time-box, ADR-0013 §5): Administration → *Extensions* →
   search **LDAP Authenticator** (xwiki-contrib) → install (globally).
   Then Administration → *LDAP*:
   - Host `lldap`, Port `3890`, no SSL
   - Bind DN `uid=svc-xwiki,ou=people,dc=lab,dc=test`, password of
     `svc-xwiki`
   - Base DN `ou=people,dc=lab,dc=test`, user filter / UID attribute `uid`
   - Group membership required: `cn=wiki_user,ou=groups,dc=lab,dc=test`
   - Field mapping: `first_name=givenName,last_name=sn,email=mail`
   - Keep local authentication as fallback so `admin` stays usable.
   Add `alice` to `wiki_user` in lldap; sign in as `alice` (works), as
   `bob` (refused).

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
  `/srv/xwiki/cacerts` (regenerable) — ADR-0008, day 3.
