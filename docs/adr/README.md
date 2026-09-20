# Architecture Decision Records

One record per non-obvious decision: context, the decision, the alternatives
that were considered and why they lost, and the consequences. Amendments are
appended to the record they change, dated, never rewritten. Template:
[`0000-template.md`](0000-template.md).

| ADR | Decision | Status |
|---|---|---|
| [ADR-0001](0001-hosting.md) | Hosting on a disposable cloud VPS | Accepted |
| [ADR-0002](0002-os-and-docker.md) | Debian 13, Docker CE, userns-remap | Accepted |
| [ADR-0003](0003-project-management-tool.md) | OpenProject Community Edition (not Allegra) | Accepted |
| [ADR-0004](0004-git-server.md) | GitLab CE (with Gitea as plan B) | Accepted |
| [ADR-0005](0005-reverse-proxy.md) | Reverse proxy — Caddy | Accepted |
| [ADR-0006](0006-identity.md) | Shared identity via LDAP (lldap), not SSO | Accepted |
| [ADR-0007](0007-pki.md) | Private CA with OpenSSL, one certificate per service | Accepted |
| [ADR-0008](0008-backup-and-reinstall.md) | Backup and reinstallation | Accepted |
| [ADR-0009](0009-secrets-domain-repo.md) | Secrets handling, domain scheme, repository policy | Accepted |
| [ADR-0010](0010-gitlab-container.md) | GitLab container — configuration, hardening, resources | Accepted |
| [ADR-0011](0011-lldap-container.md) | lldap container — image, database, exposure, directory management | Accepted |
| [ADR-0012](0012-openproject-container.md) | OpenProject stack — image variant, processes, database hardening | Accepted |
| [ADR-0013](0013-xwiki-container.md) | XWiki stack — root without capabilities, JVM trust store, proxy headers, heap | Accepted |
| [ADR-0014](0014-gitlab-openproject-webhook.md) | GitLab → OpenProject webhook — allow one name through the proxy, nothing else | Accepted |
