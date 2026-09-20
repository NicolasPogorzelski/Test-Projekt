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

Verified 2026-09-19: `sudo docker exec gitlab gitlab-rake gitlab:ldap:check`
→ `LDAP authentication... Success`, users with access: only
`uid=alice,ou=people,dc=lab,dc=test`; browser sign-in on the LDAP tab as
`alice` (member of `git_user`) succeeded and created her GitLab user, sign-in
as `bob` (no group) was refused with "Invalid credentials" — the group
filter, not the password, is the gate.

### OpenProject
Configured in the admin UI (Administration → Authentication → LDAP
authentication, `/admin/ldap_auth_sources`): host `lldap`, port 3890, no
encryption (internal network), system account
`uid=svc-openproject,ou=people,dc=lab,dc=test`, base `ou=people,dc=lab,dc=test`,
filter `(memberof=cn=pm_user,ou=groups,dc=lab,dc=test)`, automatic user
creation, attributes `uid`/`givenName`/`sn`/`mail`. Self-registration is
disabled, so LDAP is the only way in for non-admin users.

Verified 2026-09-19: "Test connection" succeeded; sign-in as `alice`
(member of `pm_user`) created her account, sign-in as `bob` (no group) was
refused. Note: OpenProject requires first and last name — lldap users need
`givenName`/`sn` filled, not only the display name (lldap README,
onboarding).

### XWiki
Two extensions from xwiki-contrib (`ldap-authenticator` = logic,
`ldap-ui` = admin form), the authenticator activated with one line in
`xwiki.cfg` (`xwiki.authentication.authclass=org.xwiki.contrib.ldap.XWikiLDAPAuthServiceImpl`,
kept in the permanent directory so the entrypoint applies it on every
start), then Administration → Other → LDAP: server `lldap`, port 3890,
bind `uid=svc-xwiki,ou=people,dc=lab,dc=test`, base `ou=people,dc=lab,dc=test`,
restrict to group `cn=wiki_user,ou=groups,dc=lab,dc=test`, UID `uid`,
fields `givenName`/`sn`/`mail`, local login kept as fallback for `admin`.
Registration and anonymous reading are denied, so LDAP is the only entry for
non-admins. Full steps: `services/xwiki/README.md`.

Verified 2026-09-19: sign-in as `alice` (member of `wiki_user`) created her
profile, sign-in as `bob` (no group) was refused. Diagnostics that got
there: without the `xwiki.cfg` line the log showed plain
`Authentication failure` and no LDAP traffic at all — the authenticator was
installed but not the active auth service.

### Summary
All three services authenticate against the same lldap directory with a
read-only bind user each and one access group each (`git_user`, `pm_user`,
`wiki_user`); every integration was verified with a member and a
non-member. On-/offboarding is one place: `services/lldap/README.md`.

## 2. GitLab ↔ OpenProject
Native integration (OpenProject ≥ 13.4, Community Edition):
OpenProject side — dedicated integration user with API token, GitLab module
enabled per project; GitLab side — project webhook to
`https://pm.lab.test/webhooks/gitlab?key=<token>` with push, comment, issue,
merge request and pipeline events, SSL verification **enabled** (requires the
private CA in `/etc/gitlab/trusted-certs/`).
**Built and verified 2026-09-20** on the rebuilt host, after the restore
test (ADR-0014 for the two security decisions: GitLab's outbound allowlist
holds only `pm.lab.test` instead of "allow local network"; the token belongs
to a local user with three permissions).

Configuration, in this order:
1. OpenProject: role `GitLab Integration` (*Show GitLab content*, *View work
   packages*, *Add comments*), local user `gitlab-integration` (no LDAP, no
   admin), GitLab module enabled in the project, user added as member with
   that role, API token generated as that user.
2. GitLab, Admin Area → Settings → Network → Outbound requests: "Allow
   requests to the local network" **off**, `pm.lab.test` in the allowlist,
   DNS-rebinding protection on.
3. GitLab project → Settings → Webhooks: URL
   `https://pm.lab.test/webhooks/gitlab?key=<token>`, events push, comments,
   work items, merge requests, pipelines; SSL verification on; test delivery
   → `HTTP 200`.

Verification: a merge request in `smoke-test` with `OP#37` in title and
description appears on work package #37, tab *GitLab*, first as `ready`
(open) and after merging as `merged`; every delivery is logged by
OpenProject as `POST /webhooks/gitlab … status=200 user=<integration user>`
(`docker logs openproject`). The first attempts linked nothing although
every delivery returned 200 — see P-018 for the permission the role was
missing and how the database showed it.

## 3. XWiki ↔ OpenProject
`xwiki-contrib/openproject` (LGPL) macro: work package lists/tables in wiki
pages, connected via an OAuth application registered in OpenProject
(Administration → Authentication → OAuth applications).
**Not built** within the time-box, same reasoning as §2; the macro would
additionally need the private CA in XWiki's JVM trust store, which is already
in place (`/srv/xwiki/cacerts`, ADR-0013). — `docs/security.md`, "Known gaps",
item 4.

## 4. Links that tie the tools together
- Project template in OpenProject linking to the XWiki space and the GitLab
  group.
- OpenProject's built-in wiki module disabled in favour of XWiki (single
  source for documentation).
