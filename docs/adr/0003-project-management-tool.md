# ADR-0003: OpenProject Community Edition (not Allegra)

## Status
Accepted

## Context
The task offers a choice between Allegra and OpenProject.

## Options considered
- **Allegra** (Alltena GmbH) — proprietary, Java 21 + PostgreSQL, Docker
  installer, LDAP and GitLab integration built in. Pricing: 12–29 EUR per
  user per month, 12-month contract, no free edition; 30-day trial only
  (https://alltena.com/de/preise/).
- **OpenProject Community Edition** — GPL v3, unlimited users, Docker Compose
  setup, LDAP authentication free, native GitLab integration free; OpenID
  Connect/SAML and the official XWiki integration are Enterprise add-ons.

## Decision
OpenProject Community Edition.

## Rationale
- The task asks for freely available products and for a reinstallable
  environment. Allegra's trial expires after 30 days; a restore after that is
  a licensing problem, not a recovery.
- Open source allows inspecting behaviour and finding community solutions
  when problems occur (which the task explicitly anticipates).
- Integration paths are equivalent (LDAP, GitLab); OpenProject additionally
  has a free LGPL XWiki macro extension (xwiki-contrib/openproject).

## Consequences
- OpenProject's SSO (OIDC/SAML) is unavailable in the Community Edition; this
  drives [ADR-0006](0006-identity.md) (LDAP instead of SSO).
- In a company with a budget, Allegra would be a legitimate option: it ships
  LDAP and GitLab integration without an enterprise surcharge, whereas
  OpenProject charges for SSO.
