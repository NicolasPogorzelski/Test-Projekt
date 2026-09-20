# ADR-0014: GitLab → OpenProject webhook — allow one name through the proxy, nothing else

## Status
Accepted (built and verified 2026-09-20 after the restore test)

## Context
Task item 4 asks for the products to be interlinked. Until now the three
products shared only their identity (lldap, ADR-0006). OpenProject ≥ 13.4
ships a GitLab integration: GitLab *pushes* events (merge requests,
comments, pipelines) to `https://<openproject>/webhooks/gitlab?key=<token>`,
and OpenProject shows them on the work packages referenced as `OP#<id>`.
The token identifies an OpenProject user; everything GitLab sends is
processed with that user's rights.

Two things make this a security decision rather than a click-through:

1. **SSRF guard.** Inside the GitLab container `pm.lab.test` resolves to
   Caddy's address on the Docker network `edge` (an alias in
   `proxy/compose.yaml`), i.e. a private IP. GitLab blocks webhooks to
   private and local addresses by default, because a project owner can make
   GitLab call any URL — and on `edge` that includes services that only
   Caddy protects from the outside: the lldap admin UI without its
   basic-auth gate (`lldap:17170`), OpenProject and XWiki without TLS.
2. **The token's blast radius** equals the rights of its owner.

## Decision
- **Network:** do **not** enable "Allow requests to the local network from
  webhooks and integrations". Instead list exactly `pm.lab.test` under
  "Local IP addresses and domain names that hooks and integrations can
  access" (Admin Area → Settings → Network → Outbound requests), keep
  DNS-rebinding protection on. The webhook therefore leaves GitLab through
  the same door a browser uses: Caddy, TLS, certificate checked against the
  lab CA that already sits in `/etc/gitlab/trusted-certs/` (P-010). Every
  other internal address stays blocked.
- **Identity:** a dedicated local OpenProject user `gitlab-integration`
  (internal password, not LDAP, not an administrator), member of the project
  with a purpose-built role `GitLab Integration` that carries exactly three
  permissions: *Show GitLab content*, *View work packages* and *Add
  comments* (`show_gitlab_content`, `view_work_packages`,
  `add_work_package_comments`) — the last two because OpenProject links a
  merge request by looking up the referenced work packages **as this user**
  and writing a comment on them; without them the webhook is accepted with
  `200` and nothing happens (P-018). Its API token is the `key` in the
  webhook URL; it lives in the password manager and, encrypted, in GitLab's
  database.
- **Events:** push, comments, issues, merge requests, pipelines; SSL
  verification enabled.

## Alternatives
| Option | Why not |
|---|---|
| global "allow local network" | opens the SSRF path to every internal service for every project owner |
| admin's API token as key | a leaked webhook URL would be full control over OpenProject |
| point the webhook at `http://openproject:8080` directly | bypasses Caddy, TLS and the headers Caddy sets; would need the local-network exception anyway |
| polling from OpenProject | not how the integration works; would need a GitLab token inside OpenProject instead |

## Consequences
- Both sides of the configuration live in databases (GitLab application
  settings and webhook, OpenProject user/role/token) and are therefore part
  of every backup set; nothing new to add to `backup.sh`.
- The XWiki → OpenProject macro (the other half of known gap 4) needs an
  OAuth application in OpenProject and stays an extension step.
- Verification recorded in `docs/integration.md` §2.
