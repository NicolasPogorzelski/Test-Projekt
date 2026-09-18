# Security measures

Each measure: what, why, where it is configured. ISO/IEC 27001:2022 Annex A
references are given where a control clearly applies (mapping, not a
compliance claim).

## Host
| Measure | Why | Where | ISO 27001:2022 |
|---|---|---|---|
| SSH key-only, root login disabled after admin user exists | no password brute force | `/etc/ssh/sshd_config.d/` | A.8.5 secure authentication |
| Hetzner Cloud Firewall: inbound 22, 80, 443, 2222 only | reduce exposed surface before the host | Hetzner console | A.8.20 network security |
| unattended-upgrades incl. Docker origin | timely security patches | `/etc/apt/apt.conf.d/50unattended-upgrades` | A.8.8 technical vulnerabilities |
| Docker CE repository key scoped with `Signed-By` | limit reach of the third-party key | `/etc/apt/sources.list.d/docker.sources` | A.8.19 software installation |
| `userns-remap` | container root is unprivileged on the host | `/etc/docker/daemon.json` | A.8.22 segregation |

## Containers
| Measure | Why | Where |
|---|---|---|
| pinned image versions | reproducibility, deliberate upgrades | every `compose.yaml` |
| no `ports:` except Caddy and GitLab SSH | backends unreachable from outside | every `compose.yaml` |
| per-stack internal networks | DBs unreachable from other stacks | every `compose.yaml` |
| `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, `read_only` where possible | limit what a compromised process can do | every `compose.yaml` (exceptions documented) |
| non-root images where available (Caddy, lldap) | — | — |
| resource limits (`mem_limit`) | one runaway container cannot starve the host | — |

## Transport
| Measure | Why |
|---|---|
| TLS everywhere at the edge, private CA, per-service certificates | task item 5; confidentiality and authenticity |
| certificate verification never disabled in any client | otherwise TLS between services is worthless |
| LDAPS (planned) | bind passwords not in clear text |
| HSTS at the proxy | prevent downgrade after first visit |

## Applications
| Measure | Where |
|---|---|
| sign-up disabled | GitLab, OpenProject, XWiki |
| 2FA enforced for admins (GitLab) | GitLab admin settings |
| per-service read-only LDAP bind users; per-service access groups | lldap |
| unused GitLab subsystems disabled (registry, pages, Prometheus) | `gitlab.rb` |

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
