# Integration

## 1. Shared identity — LDAP (lldap)

Directory layout, bind users, groups: see ADR-0006.

### GitLab
_TBD: `gitlab.rb` LDAP block (host `ldap`, port 3890, `uid`, base
`ou=people,dc=lab,dc=test`, bind user `svc-gitlab`, `user_filter` on
`memberOf=cn=git_user,ou=groups,dc=lab,dc=test`, attribute mapping)._

### OpenProject
_TBD: Administration → Authentication → LDAP authentication._

### XWiki
_TBD: LDAP Authenticator extension / LDAP Application._

## 2. GitLab ↔ OpenProject
Native integration (OpenProject ≥ 13.4, Community Edition):
OpenProject side — dedicated integration user with API token, GitLab module
enabled per project; GitLab side — project webhook to
`https://pm.lab.test/webhooks/gitlab?key=<token>` with push, comment, issue,
merge request and pipeline events, SSL verification **enabled** (requires the
private CA in `/etc/gitlab/trusted-certs/`).
_TBD: steps and screenshots._

## 3. XWiki ↔ OpenProject
`xwiki-contrib/openproject` (LGPL) macro: work package lists/tables in wiki
pages, connected via an OAuth application registered in OpenProject
(Administration → Authentication → OAuth applications).
_TBD: installation via Extension Manager, OAuth client configuration, JVM
trust store for the private CA._

## 4. Links that tie the tools together
- Project template in OpenProject linking to the XWiki space and the GitLab
  group.
- OpenProject's built-in wiki module disabled in favour of XWiki (single
  source for documentation).
