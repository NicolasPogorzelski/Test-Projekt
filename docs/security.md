# Security measures

Each measure: what, why, where it is configured. ISO/IEC 27001:2022 Annex A
references are given where a control clearly applies (mapping, not a
compliance claim). The Status column separates what is built from what is
planned or was dropped for time.

## Host
| Measure | Why | Where | ISO 27001:2022 | Status |
|---|---|---|---|---|
| SSH key-only, root login disabled after admin user exists | no password brute force | `/etc/ssh/sshd_config.d/` | A.8.5 secure authentication | done |
| Hetzner Cloud Firewall: inbound 22, 80, 443, 2222 only | reduce exposed surface before the host | Hetzner console | A.8.20 network security | done |
| unattended-upgrades enabled for Debian origins (daily timers) | timely security patches from Debian | `/etc/apt/apt.conf.d/20auto-upgrades`, `50unattended-upgrades` (package default) | A.8.8 technical vulnerabilities | done |
| Docker CE repository key scoped with `Signed-By` | limit reach of the third-party key | `/etc/apt/sources.list.d/docker.sources` | A.8.19 software installation | done |
| `userns-remap` | container root is unprivileged on the host | `/etc/docker/daemon.json` | A.8.9 configuration management | done |
| Docker used via `sudo`; no `docker` group membership; read-only sudoers rule for unattended checks | `docker` group is root-equivalent without password or audit trail | `/etc/sudoers.d/docker-readonly` | A.8.2 privileged access rights, A.8.15 logging | done |
| apt pin `5:29.*` for Docker packages + Docker origin in unattended-upgrades | automatic security patches, manual major upgrades | `/etc/apt/preferences.d/docker-ce`, `/etc/apt/apt.conf.d/52unattended-upgrades-docker` | A.8.8 technical vulnerabilities | done |
| Container log rotation (10 MB × 3 per container), `live-restore` | a full disk stops every service; daemon restarts must not stop containers | `/etc/docker/daemon.json` | A.8.6 capacity management | done |
| AppArmor default profile and seccomp builtin profile (Debian defaults, confirmed in `docker info`) | syscall and file-access confinement for every container | Docker defaults on Debian | A.8.9 configuration management | done |
| Repository on the host is cloned with a **read-only deploy key** (one SSH key, bound to this repository only, no passphrase because `git pull` runs unattended) | a compromised host can read this repository and nothing else; no personal key on the server | GitHub → Settings → Deploy keys; `~/.ssh/config` on the host | A.8.2 privileged access rights | done |

## Containers
| Measure | Why | Where | Status |
|---|---|---|---|
| pinned image versions | reproducibility, deliberate upgrades | every `compose.yaml` | done (proxy), planned (services) |
| no `ports:` except Caddy and GitLab SSH | backends unreachable from outside | every `compose.yaml` | done (proxy), planned (services) |
| per-stack internal networks | DBs unreachable from other stacks | every `compose.yaml` | planned |
| `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, `read_only` where possible | limit what a compromised process can do | every `compose.yaml` (exceptions documented) | done (proxy), planned (services) |
| Caddy: `user: 1000:1000`, `cap_drop: ALL` + `cap_add: NET_BIND_SERVICE` (the binary's file capability, see P-005), `read_only`, `no-new-privileges`, `admin off`, HTTP/3 off | the only Internet-facing process runs with one capability and a read-only filesystem | `proxy/compose.yaml`, `proxy/Caddyfile` | done |
| non-root images where available (lldap) | — | — | planned |
| resource limits (`mem_limit`) | one runaway container cannot starve the host | — | planned |

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
| sign-up disabled | GitLab, OpenProject, XWiki | planned |
| 2FA enforced for admins (GitLab) | GitLab admin settings | planned |
| per-service read-only LDAP bind users; per-service access groups | lldap | planned |
| unused GitLab subsystems disabled (registry, pages, Prometheus) | `gitlab.rb` | planned |

## Secrets and data
See ADR-0009 and ADR-0008: `.env` outside git, gitleaks pre-commit,
encrypted off-host backups, CA key offline.

## Verification
- `docker-bench-security` run and findings triaged (TBD, day 3).
- `openssl s_client` / browser checks for every hostname (TBD).
- Port scan from outside (`nmap`) showing only 22, 80, 443, 2222 (TBD).

## Known gaps / next steps
- Rootless Docker.
- Intermediate CA.
- Central log collection and alerting.
- Compose `secrets:` where images support `_FILE` variables.
