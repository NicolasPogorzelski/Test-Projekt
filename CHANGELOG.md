# Changelog

The hand-in state is tag
[`v1.0-hand-in`](https://github.com/NicolasPogorzelski/Test-Projekt/tree/v1.0-hand-in)
(2026-09-20). Everything below came later, triggered by a reviewer who could
not get the stack to start from the READMEs.

## After the hand-in (October 2026)

### Why

A reviewer installed from the README and reported that the stack "does not
start". Two rebuilds from scratch reproduced it: Caddy cannot read keys owned
by `root` and takes every site down with it
([P-024](docs/problems.md#p-024--caddy-restart-loop-on-a-first-install-the-key-files-belong-to-root)).
The information to avoid that was in the repository, but spread over six
READMEs, partly contradicting each other, with no fixed order. The answer is
one installation path, tested by a first-time reader.

### Added

- [`docs/install.md`](docs/install.md) — one linear path from an empty
  workstation and an empty server to a working system and a decrypted
  backup. Every command is marked `# workstation` or `# host` and followed by
  its expected output. Followed word for word on a fresh server on
  2026-10-19 ([P-028](docs/problems.md#p-028--literal-walk-through-of-the-install-guide-on-2026-10-19)).
- Problems [P-024](docs/problems.md#p-024--caddy-restart-loop-on-a-first-install-the-key-files-belong-to-root)
  to [P-028](docs/problems.md#p-028--literal-walk-through-of-the-install-guide-on-2026-10-19).

### Fixed

Checked locally (`bash -n`, `shellcheck`, the failure paths in a sandbox);
**not yet run on a host** — remove this note once `backup.sh` and a restore
have run with these versions.

- `scripts/restore.sh` takes the CA from the backup set instead of the
  repository. A fresh clone carries the reference build's CA, so after a
  restore of any other build GitLab and OpenProject trusted the wrong CA
  ([P-026](docs/problems.md#p-026--other-builds-trusted-the-reference-builds-ca)).
- `scripts/backup.sh` no longer leaves the unencrypted set behind when
  encryption fails, and rejects a malformed `age` recipient before it stops
  any service ([P-027](docs/problems.md#p-027--a-failed-encryption-left-the-plaintext-backup-set-behind)).
- `pki/issue-cert.sh` leaves nothing behind after a wrong CA passphrase, so
  the call can simply be repeated
  ([P-025](docs/problems.md#p-025--first-install-walkthrough-on-2026-10-18-smaller-gaps-bundled)).
- `proxy/Caddyfile` formatted with `caddy fmt` (indentation only).

### Changed

- The stack READMEs are the reference for each part — what, why,
  verification, operations — and link to the install guide for the steps,
  instead of carrying their own, diverging first-start instructions.
- `README.md`: "Installation" points to the guide; the quick start and the
  host-preparation runbook, which duplicated it, are gone; the remaining
  runbook is "Operations".
- `docs/backup-restore.md`: the CA travels in the set; a failed backup
  leaves no plaintext; restore prerequisites refer to the install guide.
- OpenProject documentation uses the menu names of OpenProject 16.6.
