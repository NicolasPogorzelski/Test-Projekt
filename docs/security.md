# Security measures

Each measure: what, why, where it is configured. ISO/IEC 27001:2022 Annex A
references are given where a control clearly applies (mapping, not a
compliance claim). The Status column separates what is built from what is
planned or was dropped for time.

## Host

Every row except the provider firewall and the deploy key is applied by
`scripts/bootstrap.sh`; its self-test checks the effective state (`docker
info`, `sshd -T`, `sudo -l`, `apt-cache policy`) and fails on any deviation.
The files named in "Where" are what the script writes.

| Measure | Why | Where | ISO 27001:2022 | Status |
|---|---|---|---|---|
| SSH key-only, root login disabled after admin user exists | no password brute force | `/etc/ssh/sshd_config.d/` | A.8.5 secure authentication | done |
| Hetzner Cloud Firewall: inbound 22, 80, 443, 2222 only | reduce exposed surface before the host | Hetzner console | A.8.20 network security | done |
| unattended-upgrades enabled for Debian origins (daily timers) | timely security patches from Debian | `/etc/apt/apt.conf.d/20auto-upgrades`, `50unattended-upgrades` (package default) | A.8.8 technical vulnerabilities | done |
| Docker CE repository key scoped with `Signed-By`; key fingerprint compared with the value pinned in `bootstrap.sh` on every run | limit reach of the third-party key; detect a swapped key at the download URL | `/etc/apt/keyrings/docker.asc`, `/etc/apt/sources.list.d/docker.sources` | A.8.19 software installation | done (day 1: manual `gpg --show-keys`; since day 2: checked by the script) |
| `userns-remap` with a fixed subordinate range (`dockremap:100000:65536`) | container root is unprivileged on the host; fixed range keeps bind-mount owners reproducible (P-008) | `/etc/docker/daemon.json`, `/etc/subuid`, `/etc/subgid` | A.8.9 configuration management | done |
| Docker used via `sudo`; no `docker` group membership; read-only sudoers rule for unattended checks | `docker` group is root-equivalent without password or audit trail | `/etc/sudoers.d/docker-readonly` | A.8.2 privileged access rights, A.8.15 logging | done |
| apt pin `5:29.*` (priority 990) for `docker-ce` and `docker-ce-cli` + Docker origin in unattended-upgrades | automatic security patches, manual major upgrades of the engine. `containerd.io` and the buildx/compose plugins have their own version schemes, so a `5:29.*` pin would never match them; they follow normal updates (day 1 listed them in the pin without effect) | `/etc/apt/preferences.d/docker-ce`, `/etc/apt/apt.conf.d/52unattended-upgrades-docker` | A.8.8 technical vulnerabilities | done |
| Container log rotation (10 MB × 3 per container), `live-restore` | a full disk stops every service; daemon restarts must not stop containers | `/etc/docker/daemon.json` | A.8.6 capacity management | done |
| AppArmor default profile and seccomp builtin profile (Debian defaults, confirmed in `docker info`) | syscall and file-access confinement for every container | Docker defaults on Debian | A.8.9 configuration management | done |
| Repository on the host is cloned with a **read-only deploy key** (one SSH key, bound to this repository only, no passphrase because `git pull` runs unattended) | a compromised host can read this repository and nothing else; no personal key on the server | GitHub → Settings → Deploy keys; `~/.ssh/config` on the host | A.8.2 privileged access rights | done |

## Containers
| Measure | Why | Where | Status |
|---|---|---|---|
| pinned image versions | reproducibility, deliberate upgrades | every `compose.yaml` | done (proxy, gitlab), planned (lldap, xwiki, openproject) |
| no `ports:` except Caddy and GitLab SSH | backends unreachable from outside | every `compose.yaml` | done (proxy, gitlab), planned (lldap, xwiki, openproject) |
| per-stack internal networks | DBs unreachable from other stacks | every `compose.yaml` | planned |
| `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, `read_only` where possible | limit what a compromised process can do | every `compose.yaml` (exceptions documented) | done (proxy); gitlab: `no-new-privileges` only, no `cap_drop` — Omnibus needs root and user switching, exception recorded in ADR-0010; planned (lldap, xwiki, openproject) |
| Caddy: `user: 1000:1000`, `cap_drop: ALL` + `cap_add: NET_BIND_SERVICE` (the binary's file capability, see P-005), `read_only`, `no-new-privileges`, `admin off`, HTTP/3 off | the only Internet-facing process runs with one capability and a read-only filesystem | `proxy/compose.yaml`, `proxy/Caddyfile` | done |
| non-root images where available (lldap) | no root inside the container at all | `services/lldap/compose.yaml` (`-rootless` image, `user: 1000:1000`, `cap_drop: ALL`, `read_only`) | done (lldap); Caddy runs non-root too |
| resource limits (`mem_limit`) | one runaway container cannot starve the host | `services/gitlab/compose.yaml` (8 GiB, ADR-0010) | done (gitlab), planned (others) |

## Transport
| Measure | Why | Status |
|---|---|---|
| TLS everywhere at the edge, private CA, per-service certificates | task item 5; confidentiality and authenticity | done |
| certificate verification never disabled in any client | otherwise TLS between services is worthless | done |
| LDAPS (planned) | bind passwords not in clear text | planned |
| HSTS at the proxy | prevent downgrade after first visit | done |

## Applications
| Measure | Where | Status |
|---|---|---|
| sign-up disabled | GitLab (admin settings, verified: `/users/sign_up` redirects to sign-in), OpenProject, XWiki | done (GitLab), planned (others) |
| 2FA enforced for admins, Admin Mode (re-authentication for the admin area), no password authentication for Git over HTTPS (tokens only) | GitLab admin settings (`services/gitlab/README.md`) | done |
| per-service read-only LDAP bind users (`lldap_strict_readonly`); per-service access groups (`git_user`, `wiki_user`, `pm_user`) | lldap; GitLab `user_filter` verified with a member and a non-member | done (directory, GitLab), planned (OpenProject, XWiki) |
| lldap web UI behind an additional Caddy `basic_auth` gate (independent credential, hash outside the repository); LDAP port never published | the directory is the root of trust for all services and has neither MFA nor login rate limiting; before production: forward-auth with MFA or admin-network restriction (ADR-0011) | `proxy/Caddyfile`, `/srv/proxy/config/ldap-ui.auth` | done |
| unused GitLab subsystems disabled (registry, Pages, KAS, Prometheus, outgoing mail) | `GITLAB_OMNIBUS_CONFIG` in `services/gitlab/compose.yaml`; verified with `gitlab-ctl status` | done |

## Secrets and data
See ADR-0009 and ADR-0008: `.env` outside git, gitleaks pre-commit,
encrypted off-host backups, CA key offline.

| Measure | Why | Where | ISO 27001:2022 | Status |
|---|---|---|---|---|
| gitleaks on every commit (staged changes, fails closed if the binary is missing) and on every push/PR in CI (full history) | a credential that reaches git history stays there; catching it before the commit is the only cheap point | `scripts/git-hooks/pre-commit` (`core.hooksPath`), `.github/workflows/secret-scan.yml` | A.8.28 secure coding | done |
| custom gitleaks rule: any IPv4 address except loopback, `0.0.0.0` and RFC 5737 documentation ranges | the repository is public after hand-in; only `*.lab.test` names and placeholders may identify the host | `.gitleaks.toml` (used by hook and CI alike) | A.5.12 classification of information | done |
| private identifiers (admin account, host names, key names) checked against a pattern list kept **outside** the repository | listing them in a tracked config would publish exactly what the check protects | `git config hooks.sanitizePatterns <file>`, read by the hook; skipped with a notice when unset | A.5.12 classification of information | done (workstation of the author; other admins set their own list) |

## Verification
- `docker-bench-security` run and findings triaged (TBD, day 3).
- `openssl s_client` / browser checks for every hostname (TBD).
- Port scan from outside (`nmap`) showing only 22, 80, 443, 2222 (TBD).

## Known gaps / extension steps (in order of value)
Deliberately not built within the three-day time-box; each item names why it
matters, why it was deferred, and where the decision is recorded.

1. **MFA in front of the lldap admin UI** (forward-auth with Authelia or
   Authentik, or restriction to an admin network). The directory is the root
   of trust for every service and has neither MFA nor login rate limiting;
   today an independent `basic_auth` gate stands in front of it. Deferred:
   a further service with its own secrets and session logic (2–3 h) whose
   failure modes would have put the restore test at risk. Required before
   production use. — ADR-0011 §3.
2. **Detection of failed gate attempts**: dedicated Caddy access log for
   `ldap.lab.test` and a runbook line to review 401s; later fail2ban on the
   host reading that log (Caddy has no built-in rate limiting). Cheap
   (~10 min for the log), deferred behind the three MVP services.
3. **2FA for LDAP users in GitLab** (currently enforced for administrators
   only): one admin setting; deferred so that test users could be created
   without TOTP enrolment. — `services/gitlab/README.md`.
4. **Minimal capability list for GitLab** (`cap_drop: ALL` + explicit
   `cap_add`) instead of Docker's default set; GitLab documents no minimal
   set, so the list must be derived by trial at 3–5 min per start.
   — ADR-0010 §2.
5. **Trust only the proxy's address for `X-Forwarded-For`** (pinned `edge`
   subnet, fixed Caddy address) instead of the Docker pool; closes the
   forged-header path from a compromised neighbour container. — ADR-0010 §3.
6. **Identities as code**: lldap's `bootstrap.sh` with versioned user/group
   definitions replacing the manual UI procedure; reconciles idempotently,
   so it can be introduced without discarding existing entries.
   — ADR-0011 §4.
7. **Compose `secrets:` (file-based) where images support `_FILE`
   variables** (lldap does): keeps secrets out of `docker inspect`. Deferred
   so that all stacks use one mechanism today. — ADR-0009, ADR-0011.
8. **LDAPS between containers**: traffic is plain text on an internal Docker
   network; LDAPS would add certificate handling in every client. — ADR-0006.
9. **Content-Security-Policy in GitLab** (off by default, sent as an empty
   header); application setting, needs testing against the UI. — P-007.
10. **Rootless Docker**, **intermediate CA**, **central log collection and
    alerting**: production-grade measures outside the scope of a
    single-host lab. — ADR-0002, ADR-0007.
