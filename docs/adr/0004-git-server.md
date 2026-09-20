# ADR-0004: GitLab CE (with Gitea as plan B)

## Status
Accepted

## Context
The task offers GitLab or Gitea. In the first interview the company stated
that expanding CI/CD (Ansible, Terraform) is an upcoming goal. The Git
component is therefore a CI/CD platform, not just source hosting.

## Options considered
- **Gitea** — MIT, one Go binary, ~200 MB RAM, official rootless image,
  `app.ini` configuration, Gitea Actions ("mostly compatible" with GitHub
  Actions), OAuth2/OIDC provider, no OpenProject integration, no Terraform
  state backend.
- **GitLab CE** — MIT, Omnibus distribution (~15 processes), baseline
  8 vCPU / 16 GB (https://docs.gitlab.com/install/requirements/), GitLab CI,
  GitLab-managed Terraform state in the Free tier
  (https://docs.gitlab.com/user/infrastructure/iac/terraform_state/), LDAP in
  the Free tier, native OpenProject integration.

## Decision
GitLab CE, image `gitlab/gitlab-ce:<x.y.z>-ce.0` with a pinned version.

## Rationale
- GitLab CI is the reference CI/CD implementation with official Terraform
  templates; a Terraform state backend with locking is built in. With Gitea,
  a separate state backend (S3/MinIO) would be required.
- Native OpenProject integration (webhooks → merge requests and commits
  shown on work packages).
- CE instead of EE: pure open source, no dormant proprietary code, exactly
  "freely available". EE without a licence would only be preferable if a
  later upgrade to Premium without reinstallation were planned.

## Consequences (accepted costs and mitigations)
- **Operational load:** monthly minor releases, patch releases twice a month,
  security backports only for the current and two previous minor versions,
  mandatory upgrade stops (https://docs.gitlab.com/policy/maintenance/,
  https://docs.gitlab.com/update/upgrade_paths/). Mitigation: pinned version,
  documented upgrade procedure (backup → upgrade path tool → upgrade).
- **Attack surface:** Rails application plus many subsystems. Mitigation:
  reachable only through the reverse proxy, sign-up disabled, 2FA enforced,
  unused subsystems (registry, pages, Prometheus) disabled.
- **Root inside the container:** no rootless image exists; `userns-remap`
  ([ADR-0002](0002-os-and-docker.md)) limits the impact.
- **Backup trap:** `gitlab-backup` does not include `gitlab-secrets.json` and
  `gitlab.rb`; both are backed up explicitly and checked in the restore test.
- **Git over SSH:** GitLab's SSH is published on host port 2222 (the proxy is
  HTTP-only); the host `sshd` stays on 22. Clone URLs use port 2222.
- **Plan B:** if GitLab is not stable behind the proxy with TLS and LDAP by
  the end of day 1, switch to Gitea (rootless). The rest of the architecture
  is unaffected; the switch would be documented, including the migration path
  (GitLab's Gitea importer).
- Gitea would have offered a much smaller attack surface, trivial backups and
  updates in seconds; this is given up deliberately for the CI/CD requirement.
