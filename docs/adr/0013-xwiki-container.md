# ADR-0013: XWiki stack — root without capabilities, JVM trust store, proxy headers, heap

## Status
Accepted

## Context
XWiki (LTS 17.10, ADR: `docs/architecture.md`) ships as a Java web
application in Tomcat 10 on JRE 21; the official image
`xwiki:17.10.13-postgres-tomcat` (https://github.com/xwiki/xwiki-docker) has
no non-root user, and its entrypoint edits files inside the image on the
first start (`hibernate.cfg.xml`, `xwiki.cfg`). Extensions such as the LDAP
authenticator are installed at runtime from `extensions.xwiki.org` over
HTTPS. Behind Caddy (ADR-0005) Tomcat sees plain HTTP from the proxy's
address.

## Decisions

### 1. Root inside the container, but with every capability dropped
- **Options:** (a) root + `cap_drop: ALL` + `no-new-privileges`;
  (b) root + `no-new-privileges` only (the GitLab pattern); (c) force a
  non-root user.
- **Decision: (a).** (c) fails: the entrypoint must write into
  image-owned paths, which would require a rebuilt image. Unlike GitLab
  Omnibus, Tomcat needs no capability: it binds 8080, switches no user and
  chowns nothing; as UID 0 it owns the image files and the data volume
  (host UID 100000) through the normal permission bits, so
  `CAP_DAC_OVERRIDE` is not needed either. Root without capabilities is a
  materially smaller attack surface than root with Docker's default set.
  (b) is the documented fallback if the first start proves a capability
  necessary. A read-only root filesystem is an extension step (Tomcat
  writes `work/`, `temp/`, `logs/` and the entrypoint edits `WEB-INF`).

### 2. JVM trust store: image `cacerts` plus the private CA, mounted read-only
- **Options:** (a) build the merged `cacerts` once on the host with
  `keytool` inside a throw-away container and mount it over the image path;
  (b) defer until the XWiki↔OpenProject macro needs it; (c) replace the
  trust store via `JAVA_OPTS` (`-Djavax.net.ssl.trustStore`).
- **Decision: (a).** Java ignores the system trust store and uses its own
  `cacerts`. (c) would make the private CA the *only* trusted CA and break
  the Extension Manager (public TLS). (a) keeps the public CAs and adds
  `lab.test Root CA`; the file lives in `/srv/xwiki/cacerts` and must be
  regenerated after an image update with a newer JRE (README).
- **Production variant:** a derived image built in CI
  (`FROM xwiki:… RUN keytool -importcert …`). Not taken because this
  project builds no images (no registry, no build step in the reinstall).

### 3. Proxy headers via Tomcat's `RemoteIpValve`
- **Options:** (a) `RemoteIpValve` in a versioned `server.xml`
  (`services/xwiki/tomcat/server.xml`, mounted read-only);
  (b) `xwiki.url.protocol=https` in `xwiki.cfg`.
- **Decision: (a).** Caddy terminates TLS and forwards plain HTTP with
  `X-Forwarded-Proto` and `X-Forwarded-For`. Without the valve, XWiki
  builds `http://` links and redirects, and its logs show the proxy as the
  client. The valve rewrites scheme and client address for requests from
  `internalProxies` — the Docker address pool, with the same residual risk
  and extension step as GitLab's `real_ip` (ADR-0010 §3). (b) fixes only
  the links.
- The mount is read-only because Tomcat only reads the file (contrast
  P-010, where the application chowned the mounted file).

### 4. Heap and memory limit
- **Decision: `JAVA_OPTS=-Xmx1536m`, `mem_limit: 2560m`.** The JVM
  reserves the heap up to `-Xmx` and never returns it; the image default
  is 1 GiB, XWiki's minimum. Extension installation (LDAP, today) and Solr
  indexing are the peaks. The container needs roughly heap + 1 GiB for
  metaspace, threads and the embedded Solr, so the limit must exceed the
  heap by that margin or the kernel kills the container while Java still
  believes it has room. Measured after the first start (README).

### 5. LDAP authenticator: extension, 30-minute time-box
- Installed through the Extension Manager (`LDAP Authenticator`,
  xwiki-contrib), configured in the admin UI with `svc-xwiki` and the
  `wiki_user` group — the OpenProject procedure. If the time-box expires
  it becomes an extension step.

## Consequences
- `XWIKI_DB_PASSWORD` must be hex (`openssl rand -hex 24`): it is placed in
  a JDBC URL by the entrypoint.
- PostgreSQL is initialised with `--locale-provider=builtin --locale=C.UTF-8`
  as in XWiki's official compose file — the reason PostgreSQL 17 was chosen
  (`docs/architecture.md`).
- Two host-side artefacts exist outside the repository and are part of the
  reinstall: `/srv/xwiki/cacerts` (regenerable from `pki/ca.crt`) and the
  data volume.
