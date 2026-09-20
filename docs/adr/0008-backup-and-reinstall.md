# ADR-0008: Backup and reinstallation

## Status
Accepted

## Context
Task item 3: backups and reinstallation must be as simple as possible.

## Principles
1. **Separate configuration from state.** Configuration lives in git
   (compose files, Caddyfile, scripts). State (databases, repositories, wiki
   pages, attachments, the directory) is what gets backed up. Reinstall =
   clone → `bootstrap.sh` → `restore.sh`.
2. **Consistency.** Databases are dumped with their own tool (`pg_dump`,
   `gitlab-backup`); copying a running database's files is inconsistent.
3. **3-2-1.** A backup on the host that fails is not a backup: local copy plus
   a copy on the workstation.
4. **A backup that was never restored is a hope.** The restore test on a
   rebuilt host is the proof for item 3 and the source for item 7.

## What is state, per component
| Component | State | Tool |
|---|---|---|
| GitLab | repositories, DB, uploads | `gitlab-backup create` → `/var/opt/gitlab/backups`; **plus** `gitlab-secrets.json` and `gitlab.rb`, which the backup does not include; restore only onto the same version and edition (https://docs.gitlab.com/administration/backup_restore/backup_gitlab/) |
| OpenProject | PostgreSQL, `/var/openproject/assets` | `pg_dump` + tar (https://www.openproject.org/docs/installation-and-operations/operation/backing-up/) |
| XWiki | PostgreSQL, permanent directory `/usr/local/xwiki` | `pg_dump` + tar |
| lldap | SQLite in `/data` | tar |
| all stacks | `.env` files (not in git) | tar |
| PKI | service certificates and keys on the host | tar; CA key lives on the workstation |

## Decisions
| Decision | Choice | Alternatives |
|---|---|---|
| Tool | own Bash scripts `backup.sh` / `restore.sh` | restic/borg (dedup, encryption) — next step; Hetzner snapshots — not application-consistent, complement only |
| Data location | bind mounts under `/srv/<stack>/` | named volumes — backup only via helper containers |
| Services during backup | stopped (`compose stop` → dump/tar → `compose start`) | running — small consistency window; acceptable, but stopped is simpler to reason about |
| Off-host copy | pull to the workstation (rsync/scp) | Hetzner Storage Box / S3 — next step |
| Retention | 7 sets | — |
| Integrity | `sha256sum` per backup set | — |
| Encryption | `age` before copying off-host (backup contains secrets and password hashes) | none — data leak on the copy path |
| Scheduling | systemd timer | cron |
| Reinstall | `bootstrap.sh` + README runbook | Ansible playbook — next step |
| Proof | restore test on a rebuilt VPS, protocol with duration (RTO) in `docs/backup-restore.md` | — |

## Consequences
- Bind mounts must carry the remapped ownership (ADR-0002).
- Encryption and the systemd timer are the first items to drop if time runs
  short; the restore test is not negotiable.
- RPO = backup interval (daily); RTO measured in the test.

## Amendment 2026-09-20 (implementation)
- **Services during backup — corrected.** "Stopped" was too coarse: `pg_dump`
  and `gitlab-backup` need running processes. Rule as implemented: application
  containers are stopped while their files are read (OpenProject `web`/`worker`,
  `xwiki`, `lldap`), database containers keep running and are dumped
  (`pg_dump -Fc`, one MVCC snapshot), GitLab is never stopped
  (`gitlab-backup create STRATEGY=copy` is consistent on its own), Caddy keeps
  running. An `EXIT` trap restarts whatever was stopped.
- **Encryption — built, not deferred.** The workstation that holds the off-host
  copy has no disk encryption (checked with `lsblk`: plain btrfs, no `crypt`
  layer), so a plaintext copy there was not acceptable. Sets are encrypted with
  `age` on the host before they leave it; recipient in
  `scripts/backup-recipients.txt`, identity in the password manager only.
- **Read access for the off-host pull.** Sets are `root:backup 0640`; the admin
  is added to Debian's `backup` group by `bootstrap.sh` (the group exists for
  delegated backup duties and grants nothing else on a stock system).
- **GitLab set contents.** `gitlab-secrets.json`, `gitlab.rb` and the SSH host
  keys are copied next to the `gitlab-backup` archive (P-014).
- **Retention** counts encrypted sets by name (7), never by mtime.
- Still deferred: systemd timer (runbook task until then), restic/borg,
  off-site storage.
