# Backup and restore

Concept and decisions: see ADR-0008.

## What is backed up
_TBD: table with paths as implemented in `scripts/backup.sh`._

## Backup procedure
_TBD: `scripts/backup.sh` — stop stacks → dumps → tar → checksums → start →
prune → (encrypt) → copy off-host._

## Restore procedure
_TBD: `scripts/restore.sh` on a freshly bootstrapped host._

## Restore test protocol
| Date | Host state | Steps | Duration (RTO) | Result | Findings |
|---|---|---|---|---|---|
| _TBD_ | rebuilt VPS | clone → bootstrap → restore | | | |

Verification checklist after restore:
- [ ] all four hostnames answer over HTTPS with the expected certificate
- [ ] LDAP login works in GitLab, XWiki, OpenProject
- [ ] a test repository can be cloned via SSH :2222 and HTTPS
- [ ] a test wiki page and a test work package exist with their attachments
- [ ] GitLab → OpenProject webhook still delivers
