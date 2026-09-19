# ADR-0012: OpenProject stack — image variant, processes, database hardening

## Status
Accepted

## Context
ADR-0003 chose OpenProject Community Edition. OpenProject publishes two
container flavours (https://www.openproject.org/docs/installation-and-operations/installation/docker/):
`X.Y.Z-slim` (application only, one container per role, "recommended for
production") and `X.Y.Z` all-in-one (supervisord starts Puma, worker, cron,
its own PostgreSQL, memcached and Apache in one root container, "not
recommended for production"). OpenProject 16 requires PostgreSQL ≥ 16.

## Decisions

### 1. `-slim` image, one container per role
- **Options:** (a) `openproject/openproject:16.6.10-slim` as `web`, `worker`,
  one-off `seeder`, plus `memcached` and our `postgres:17.11-alpine`;
  (b) all-in-one.
- **Decision: (a).** The vendor documents (b) as not production-ready; a
  system built as an assessment for a company follows the production path.
  (a) also fits the existing pattern: every process non-root, per-role
  memory limits, the database on our pinned PostgreSQL 17 with the `pg_dump`
  backup path (ADR-0008), background jobs visible as their own container
  (they carry the GitLab webhook processing, ADR integration item 2).
- Not taken from the vendor's compose file: `autoheal` (needs the Docker
  socket — the reason Traefik was rejected in ADR-0005) and the
  `openproject/proxy` Apache container (Caddy talks to Puma directly; Puma
  serves assets itself in production mode). Caddy's upstream is
  `openproject:8080`.

### 2. No cron process
- The `cron` role sends reminders/digests and runs periodic clean-up. There
  is no mail server in this environment and the test data set produces
  nothing to clean up; the role would cost ~300 MB on a 16 GB host whose
  final load is not yet known. **Deferred** with a README note; for company
  use it is a one-line addition once mail exists and reminders are wanted.

### 3. PostgreSQL non-root with all capabilities dropped
- **Options:** (a) `user: 70:70` (the alpine image's `postgres` user),
  `cap_drop: ALL`, `no-new-privileges`, read-only root filesystem with
  tmpfs for the socket directory and `/tmp`, data directory owned by host
  UID 100070 (bootstrap owner table); (b) the image default: start as root,
  `chown` the data directory, drop to `postgres`.
- **Decision: (a)** — least privilege is the design rule; (b) stays the
  documented fallback if (a) fails at first start. The same pattern is
  reused for XWiki's database.

### 4. LDAP right after the first start, 30-minute time-box
- Configured in the admin UI (Administration → Authentication → LDAP),
  bind user `svc-openproject`, filter on the `pm_user` group, after the
  admin password, sign-up and wiki module are handled. If the time-box
  expires, LDAP for OpenProject moves behind XWiki (MVP first).

## Consequences
- Secrets `OPENPROJECT_DB_PASSWORD` and `OPENPROJECT_SECRET_KEY_BASE` come
  from `services/openproject/.env` and must be **hex** (`openssl rand -hex`):
  the database password is embedded in `DATABASE_URL`, where `/` or `+`
  would break the URL. `SECRET_KEY_BASE` signs sessions and tokens and is
  part of every backup.
- `SSL_CERT_FILE` points at the private CA (mounted read-only — nothing
  chowns it, unlike GitLab's `trusted-certs`, P-010). This replaces the
  system bundle for OpenProject's outbound TLS: fine for calls to
  `git.lab.test`/`wiki.lab.test`; outbound calls to public sites would
  fail — none are needed.
- `OPENPROJECT_HTTPS=true` (secure cookies, https links) with
  `OPENPROJECT_HSTS=false`: HSTS is Caddy's job (ADR-0005).
- The seeder runs on every `up` (migrations on upgrades) and must finish
  before web/worker start (`service_completed_successfully`).
- **Measured 2026-09-19 (idle, after first start):** web 1.56 GiB, worker
  640 MiB, db 65 MiB, cache 2 MiB. The web limit was raised from 2 to 3 GiB
  because 78 % use at idle leaves no headroom for exports or larger
  requests; worker 1.5 GiB, db 1 GiB and cache 128 MiB stay. Verified:
  `db` and `cache` run with all capabilities dropped and a read-only root
  filesystem (cache as the image's own `memcache` user), web/worker as
  `app` (UID 1000); no port is published.
