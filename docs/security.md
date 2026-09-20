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
| pinned image versions | reproducibility, deliberate upgrades | every `compose.yaml` | done |
| no `ports:` except Caddy and GitLab SSH | backends unreachable from outside | every `compose.yaml` | done |
| per-stack internal networks | DBs unreachable from other stacks | `openproject_internal` (db, cache), `xwiki_internal` (db) — both `internal: true` | done |
| `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, `read_only` where possible | limit what a compromised process can do | every `compose.yaml` (exceptions documented) | done: proxy, lldap, both PostgreSQL and memcached with all three; openproject web/worker non-root with `no-new-privileges`; xwiki as root but with `cap_drop: ALL` (image needs root, needs no capability — ADR-0013); gitlab `no-new-privileges` only (Omnibus needs root and user switching, ADR-0010) |
| Caddy: `user: 1000:1000`, `cap_drop: ALL` + `cap_add: NET_BIND_SERVICE` (the binary's file capability, see P-005), `read_only`, `no-new-privileges`, `admin off`, HTTP/3 off | the only Internet-facing process runs with one capability and a read-only filesystem | `proxy/compose.yaml`, `proxy/Caddyfile` | done |
| non-root images where available (lldap) | no root inside the container at all | `services/lldap/compose.yaml` (`-rootless` image, `user: 1000:1000`, `cap_drop: ALL`, `read_only`) | done (lldap); Caddy runs non-root too |
| resource limits (`mem_limit`) | one runaway container cannot starve the host | gitlab 8 GiB (ADR-0010), lldap 256 MB, openproject web 3 GiB / worker 1.5 GiB / db 1 GiB / cache 128 MB (ADR-0012), xwiki 3 GiB with a 1.5 GiB JVM heap / db 1 GiB (ADR-0013) | done |

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
| sign-up disabled; XWiki additionally denies anonymous reading | GitLab (admin settings, verified: `/users/sign_up` redirects to sign-in), OpenProject (self-registration disabled), XWiki (Register and View denied for unregistered users — both URLs redirect to login); LDAP is the only entry for non-admins everywhere | done |
| 2FA enforced for admins, Admin Mode (re-authentication for the admin area), no password authentication for Git over HTTPS (tokens only) | GitLab admin settings (`services/gitlab/README.md`) | done |
| per-service read-only LDAP bind users (`lldap_strict_readonly`); per-service access groups (`git_user`, `wiki_user`, `pm_user`) | lldap; GitLab, OpenProject and XWiki each verified with a member and a non-member of their group | done |
| lldap web UI behind an additional Caddy `basic_auth` gate (independent credential, hash outside the repository); LDAP port never published | the directory is the root of trust for all services and has neither MFA nor login rate limiting; before production: forward-auth with MFA or admin-network restriction (ADR-0011) | `proxy/Caddyfile`, `/srv/proxy/config/ldap-ui.auth` | done |
| unused GitLab subsystems disabled (registry, Pages, KAS, Prometheus, outgoing mail) | `GITLAB_OMNIBUS_CONFIG` in `services/gitlab/compose.yaml`; verified with `gitlab-ctl status` | done |
| proxy headers trusted only from the Docker address pool: GitLab `real_ip`, Tomcat `RemoteIpValve` for XWiki | correct client IP in logs and per-IP limits, https links behind the proxy; a forged `X-Forwarded-For` from the Internet is ignored (verified on GitLab) | `services/gitlab/compose.yaml`, `services/xwiki/tomcat/server.xml` | done (residual risk: neighbour containers, ADR-0010 §3) |

## Secrets and data
See ADR-0009 and ADR-0008: `.env` outside git, gitleaks pre-commit,
encrypted off-host backups, CA key offline.

| Measure | Why | Where | ISO 27001:2022 | Status |
|---|---|---|---|---|
| gitleaks on every commit (staged changes, fails closed if the binary is missing) and on every push/PR in CI (full history) | a credential that reaches git history stays there; catching it before the commit is the only cheap point | `scripts/git-hooks/pre-commit` (`core.hooksPath`), `.github/workflows/secret-scan.yml` | A.8.28 secure coding | done |
| custom gitleaks rule: any IPv4 address except loopback, `0.0.0.0` and RFC 5737 documentation ranges | the repository is public after hand-in; only `*.lab.test` names and placeholders may identify the host | `.gitleaks.toml` (used by hook and CI alike) | A.5.12 classification of information | done |
| private identifiers (admin account, host names, key names) checked against a pattern list kept **outside** the repository | listing them in a tracked config would publish exactly what the check protects | `git config hooks.sanitizePatterns <file>`, read by the hook; skipped with a notice when unset | A.5.12 classification of information | done (workstation of the author; other admins set their own list) |

## Verification
Measured from the workstation against the rebuilt host on 2026-09-20 (after
the restore test, so the numbers describe the state a reinstall produces):

- **Port scan from outside.** Three measurements, because one alone was not
  trustworthy: (1) a full-range `nmap -sT -Pn -p- --open --reason` **through
  the workstation's VPN exit node** (slow, therefore complete) showed
  `22, 53, 80, 443, 2222`; (2) full-range scans over the residential uplink
  were lossy in both directions (open ports missing, two random high ports
  "open" once and `filtered` on every re-test — NAT connection tracking under
  65 k connections); (3) targeted direct scans, repeated three times, show
  `22/tcp` (host sshd, Debian banner), `80`, `443`, `2222/tcp` (GitLab's own
  sshd, Ubuntu banner from the Omnibus image) `open` and `53` `filtered`. The
  host itself (`ss -tlnH`) listens on exactly these four (IPv4 and IPv6);
  Docker publishes only 2222 (GitLab) and 80/443 (Caddy). Conclusion: 53 was
  an artefact of the exit node answering DNS, and nothing but the four
  documented ports is reachable. Lesson: know the path of the scanner
  (`ip route get <host>`) and cross-check outside view against inside view.
- **TLS per hostname.** `openssl s_client -connect <host>:443 -servername
  <name> -CAfile pki/ca.crt` for all four names: `CN=<name>`, SAN `DNS:<name>`,
  issuer `CN=lab.test Root CA`, valid 2026-09-18 → 2027-09-18, TLSv1.3,
  `TLS_AES_128_GCM_SHA256`, `Verify return code: 0`. Port 80 answers `308` to
  `https://`. Response headers on a `200`: HSTS (`max-age=31536000`),
  `X-Content-Type-Options: nosniff`, `Referrer-Policy`, no `Server` header;
  GitLab sends an empty `Content-Security-Policy` (known gap 10).
- **Sign-up closed everywhere** (`/users/sign_up`, XWiki `register`,
  `/account/register` all redirect to the login); lldap UI answers `401`
  without the gate credential.
- **`docker-bench-security`: not run** within the time-box. It is the next
  verification step; expected findings are the documented ones (GitLab and
  XWiki as container root, no user namespace for the docker group — accepted in
  ADR-0010/0013) and they should be triaged into accepted / fixed / gap here.

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
4. **XWiki → OpenProject macro** (work-package tables in wiki pages): needs
   an OAuth application in OpenProject plus the macro extension in XWiki;
   deferred behind the backup/restore test. The other half of this item,
   the **GitLab → OpenProject webhook**, was built on day 3 with a
   host-allowlist instead of "allow local network" and a three-permission
   integration user — ADR-0014, `docs/integration.md` §2, P-018.
5. **Minimal capability list for GitLab** (`cap_drop: ALL` + explicit
   `cap_add`) instead of Docker's default set; GitLab documents no minimal
   set, so the list must be derived by trial at 3–5 min per start.
   — ADR-0010 §2.
6. **Trust only the proxy's address for `X-Forwarded-For`** (pinned `edge`
   subnet, fixed Caddy address) instead of the Docker pool; closes the
   forged-header path from a compromised neighbour container. — ADR-0010 §3.
7. **Identities as code**: lldap's `bootstrap.sh` with versioned user/group
   definitions replacing the manual UI procedure; reconciles idempotently,
   so it can be introduced without discarding existing entries.
   — ADR-0011 §4.
8. **Compose `secrets:` (file-based) where images support `_FILE`
   variables** (lldap does): keeps secrets out of `docker inspect`. Deferred
   so that all stacks use one mechanism today. — ADR-0009, ADR-0011.
9. **LDAPS between containers**: traffic is plain text on an internal Docker
   network; LDAPS would add certificate handling in every client. — ADR-0006.
10. **Content-Security-Policy in GitLab** (off by default, sent as an empty
    header); application setting, needs testing against the UI. — P-007.
    **XWiki session IDs in URLs** (`;jsessionid=` on redirects, URL
    rewriting for cookie-less clients): disable in Tomcat's `context.xml`
    (`disableURLRewriting`) so session IDs never land in logs or referrers.
    **XWiki read-only root filesystem**: possible with tmpfs for Tomcat's
    `work/`, `temp/`, `logs/` — untested. — ADR-0013.
    **Offboarding automation for XWiki**: the `LDAP user cleanup` extension
    removes profiles of users deleted from LDAP; only after the offboarding
    policy decides whether profiles are deleted or kept (audit trail).
11. **Rootless Docker**, **intermediate CA**, **central log collection and
    alerting**: production-grade measures outside the scope of a
    single-host lab. — ADR-0002, ADR-0007.
