# ADR-0006: Shared identity via LDAP (lldap), not SSO

## Status
Accepted

## Context
Task item 4 asks to integrate the products as well as possible. Without a
shared identity every service keeps its own user database, and onboarding and
offboarding must be repeated per service.

## Options considered
- **Local accounts everywhere** — no integration; rejected.
- **Single sign-on via OpenID Connect / SAML** — one login session for all
  services. GitLab can act as an OIDC provider, XWiki has an OIDC
  authenticator, but OpenProject supports OIDC/SAML only in the Enterprise
  edition ("OpenID Connect providers is an Enterprise add-on",
  https://www.openproject.org/docs/system-admin-guide/authentication/openid-providers/).
  A 14-day Enterprise trial would work but is not reproducible.
- **Dedicated identity provider (Keycloak)** — adds a heavy component and
  does not solve the OpenProject limitation.
- **Shared LDAP directory** — every service authenticates against the same
  directory. Free in all three products: GitLab Free tier
  (https://docs.gitlab.com/administration/auth/ldap/), OpenProject Community
  (https://www.openproject.org/docs/system-admin-guide/authentication/ldap-authentication/),
  XWiki LDAP authenticator extension.

### LDAP server
- **OpenLDAP** — complete, but configured via `cn=config`/LDIF without a UI;
  effort without benefit for a handful of users.
- **lldap** — lightweight LDAP server with web UI, one container, SQLite,
  built for exactly this use case; supports bind authentication and
  `memberOf` group filters (https://github.com/lldap/lldap).

## Decision
lldap as the single source of user accounts; GitLab, XWiki and OpenProject
authenticate against it via LDAP.

## Rationale
LDAP is the only licence-free mechanism that binds all three products to one
identity. Users get one account and one password; deactivating a user in lldap
locks them out everywhere. This is *shared identity*, not single sign-on: each
service still shows its own login form.

## Design details
- Base DN `dc=lab,dc=test`; users under `ou=people`, groups under `ou=groups`.
- One read-only bind user per service (`svc-gitlab`, `svc-xwiki`,
  `svc-openproject`), members of `lldap_strict_readonly` — least privilege; a
  compromised service cannot modify the directory.
- One access group per service (`git_user`, `wiki_user`, `pm_user`) used in
  each service's user filter (`memberOf`). Onboarding = create user + assign
  groups; offboarding = disable user.
- lldap web UI published through Caddy as `ldap.lab.test` with its own
  certificate.
- Integration order: GitLab (lldap ships an example configuration) →
  OpenProject (UI-driven) → XWiki (extension). Time box: two hours each.

## Consequences
- No single sign-on. Upgrade path: an OIDC provider (e.g. Keycloak) in front
  of lldap, once an Enterprise licence or a different PM tool makes OIDC
  usable in all services. LDAP stays the source of truth.
- Transport: plain LDAP (port 3890) on the isolated Docker network first,
  then LDAPS (6360) with a certificate from the private CA as a separate
  step. If time runs out, the residual risk is documented: bind passwords
  travel unencrypted only within the internal network, no host port is
  published.
- LDAPS requires the CA in three client trust stores (Ruby/GitLab,
  Ruby/OpenProject, JVM/XWiki) — the same mechanism as for HTTPS (ADR-0007).
- Note: lldap's GitLab example uses port 389; lldap listens on 3890.
