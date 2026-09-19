# ADR-0011: lldap container — image, database, exposure, directory management

## Status
Accepted

## Context
ADR-0006 chose lldap as the shared directory (base DN `dc=lab,dc=test`,
one read-only bind user per service, one access group per service). This
ADR records how the container is run. lldap is a single Rust process with an
LDAP listener (3890) and a web UI (17170), configured through `LLDAP_*`
environment variables that override `lldap_config.toml` in `/data`
(https://github.com/lldap/lldap, config template in the repository).

## Decisions

### 1. Image variant: rootless
- **Options:** (a) `lldap/lldap:v0.6.3-alpine-rootless`; (b) the default
  image, which starts as root, `chown`s `/data` and drops to `UID`/`GID`
  via `gosu`.
- **Decision: (a).** The rootless image runs as its built-in user `lldap`
  (UID 1000) from the first instruction; no root exists in the container.
  That allows the full proxy pattern: `user: 1000:1000`, `cap_drop: ALL`
  (both ports are above 1024), `no-new-privileges`, `read_only` root
  filesystem with `/data` as the only writable path. The precondition the
  lldap README names — permissions on `/data` set before the first start —
  is met by `scripts/bootstrap.sh` (owner 100000 + 1000 = 101000, ADR-0002).
- **Rejected (b):** tolerates wrong permissions by repairing them as root,
  which is exactly the capability we do not want to grant.
- Verified at first start; if `read_only` had broken the start, it would
  have been dropped and recorded here.

### 2. Database: SQLite
- **Options:** (a) SQLite file `/data/users.db` (lldap default);
  (b) a dedicated PostgreSQL container as for XWiki and OpenProject.
- **Decision: (a).** A directory for a company of ~30 people changes a few
  times a month; write concurrency is not a factor. SQLite means one
  container, one volume, no second secret, and the documented default
  configuration — troubleshooting follows the upstream documentation
  without translation. Backup is the file (consistent while the container
  is stopped, which `backup.sh` does anyway, ADR-0008).
- **Revisit** when lldap must be highly available or shared by several
  instances; then (b) with `LLDAP_DATABASE_URL`.

### 3. Web UI exposed through Caddy
- **Options:** (a) `https://ldap.lab.test` through Caddy (TLS, ADR-0005);
  (b) no public route, UI only over an SSH tunnel to the host; (c) (a) plus
  Caddy `basic_auth` in front of the UI.
- **Decision: (a) + (c).** Maximum security would be (b). The assignment
  does not require an identity admin panel — it asks for integration
  (item 4) and documentation for other admins (item 6) — so exposing the
  UI is an operational decision: user administration (on-/offboarding)
  must not require SSH access to the host, otherwise it becomes a
  bottleneck that gets worked around with local accounts. The LDAP port
  itself stays on the internal network and is never published.
- **Why (c) is not optional here:** lldap is the *root of trust* — whoever
  holds its admin account can create members of every access group and
  reset any password, and is therefore inside GitLab, XWiki and OpenProject
  without attacking any of them. lldap's UI login has no second factor, and
  no login rate limiting was found in v0.6.3 (code search and issue
  tracker, 2026-09-19; treated as absent). A single password in front of
  the root of trust would be inconsistent with the enforced 2FA for GitLab
  administrators (ADR-0010) and below the "minimum of common security
  standards" the assignment asks for (CIS Control 6.5, ISO 27001 A.8.5:
  strong authentication for privileged access). Caddy `basic_auth` adds an
  independent credential (different password, different code path, bcrypt
  hash kept outside the repository) and the failed attempts appear in
  Caddy's access log.
- **Accepted residual risk:** two passwords and TLS, still no MFA in front
  of the directory. **Before production use:** forward-auth with MFA
  (Authelia/Authentik) in front of the UI, or restrict `ldap.lab.test` to
  an admin network. This is a required next step, not an option.

### 4. Directory content: web UI now, script later
- **Options:** (a) create service accounts, groups and users in the UI and
  document the procedure; (b) lldap's `bootstrap.sh` with versioned JSON
  definitions (identities as code); (c) (a) today, (b) once the system is
  complete and verified.
- **Decision: (c).** Building and verifying the whole system comes first;
  automation on top of a verified system is the professional order, and
  lldap's script reconciles idempotently against the API, so it can be
  introduced later without discarding UI-created entries. The manual
  procedure is in `services/lldap/README.md` (on-/offboarding).

## Consequences
- Secrets (`LLDAP_JWT_SECRET`, `LLDAP_KEY_SEED`, `LLDAP_LDAP_USER_PASS`) come
  from `services/lldap/.env` (ADR-0009). `LLDAP_KEY_SEED` encrypts stored
  keys and must never change after the first start — it is part of every
  backup. The image's template ships a **default** `key_seed`, so the
  variable is mandatory; Compose's `${VAR:?}` aborts the start if it is
  missing.
- lldap supports `LLDAP_*_FILE` variables, i.e. file-based secrets that
  would keep them out of `docker inspect`; kept as the extension step noted
  in ADR-0009, so that all stacks use one mechanism today.
- LDAP between containers is plain text on the internal `ldap` network
  (ADR-0006); LDAPS remains an extension step.
