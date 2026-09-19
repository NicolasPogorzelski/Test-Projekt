# Integration

## 1. Shared identity — LDAP (lldap)

Directory layout, bind users, groups: see ADR-0006.

### GitLab
Configured in `services/gitlab/compose.yaml` (`GITLAB_OMNIBUS_CONFIG`,
`gitlab_rails['ldap_servers']`): host `lldap`, port 3890, plain LDAP on the
internal network, bind user `uid=svc-gitlab,ou=people,dc=lab,dc=test`
(member of `lldap_strict_readonly`), base `ou=people,dc=lab,dc=test`,
`user_filter` `(&(objectclass=person)(memberof=cn=git_user,ou=groups,dc=lab,dc=test))`,
attributes `uid`/`mail`/`displayName`/`givenName`/`sn`. The bind password
comes from `services/gitlab/.env` (`GITLAB_LDAP_BIND_PASSWORD`).

Behaviour: a person becomes a GitLab user at the first LDAP sign-in
(`block_auto_created_users` false — the group filter decides who may sign
in at all); removing the person from `git_user` in lldap blocks the next
sign-in. Local accounts (`root`) keep working with password + 2FA.

Verification: `sudo docker exec gitlab gitlab-rake gitlab:ldap:check` lists
the bind result and the users the filter returns; sign-in as `alice`
(member of `git_user`) succeeds, sign-in as `bob` (no group) is refused.

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
