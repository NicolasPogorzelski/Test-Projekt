# Backup and restore

Concept and decisions: [ADR-0008](adr/0008-backup-and-reinstall.md) (amended 2026-09-20, see the ADR's last section).
Scripts: [`scripts/backup.sh`](../scripts/backup.sh), [`scripts/restore.sh`](../scripts/restore.sh). Both run as root via `sudo`
from the admin account and refuse anything else.

## What is backed up

One run of `backup.sh` produces one *set*, first as a directory
`/srv/backups/<UTC stamp>/`, then packed and encrypted with `age` into
`/srv/backups/<UTC stamp>.tar.age`; the plaintext directory is removed once the
archive exists. Contents of a set:

| Path in the set | Source on the host | How | Why this way |
|---|---|---|---|
| `gitlab/<ts>_gitlab_backup.tar` | produced by `docker exec gitlab gitlab-backup create STRATEGY=copy` in `/srv/gitlab/data/backups`, moved into the set | GitLab's own tool; DB, repositories, uploads, artifacts, LFS in one consistent archive | the documented way; restorable only onto the same GitLab version and edition (the manifest records the tag) |
| `gitlab/gitlab-secrets.json`, `gitlab/gitlab.rb` | `/srv/gitlab/config/` | copy | **not** part of `gitlab-backup`; without the secrets file encrypted DB columns (tokens, 2FA) are unreadable after a restore |
| `gitlab/ssh-host-keys.tar.gz` | `/srv/gitlab/config/ssh_host_*` | tar | not part of `gitlab-backup` either; without them every `git@` client warns about a changed host key after a rebuild ([P-014](problems.md#p-014--gitlab-backup-covers-neither-the-ssh-host-keys-nor-trusted-certs)) |
| `openproject/db.dump` | `docker exec openproject-db pg_dump -Fc` | dump while the DB runs, application containers stopped | one MVCC snapshot; independent of the PostgreSQL major version |
| `openproject/assets.tar.gz` | `/srv/openproject/assets` | tar | attachments; taken while `web`/`worker` are stopped so DB and files match |
| `xwiki/db.dump` | `docker exec xwiki-db pg_dump -Fc` | as above | attachments live in the DB (default storage) |
| `xwiki/data.tar.gz` | `/srv/xwiki/data` | tar, `xwiki` stopped | configuration (`xwiki.cfg` with the LDAP line, [P-012](problems.md#p-012--xwiki-ldap-installed-configured-and-still-invalid-credentials)) and installed extensions |
| `xwiki/cacerts` | `/srv/xwiki/cacerts` | copy | JVM trust store with the lab CA |
| `lldap/data.tar.gz` | `/srv/lldap` | tar, `lldap` stopped | SQLite: safe only without a writer |
| `proxy/certs.tar.gz`, `proxy/config.tar.gz`, `proxy/data.tar.gz` | `/srv/proxy/*` | tar, Caddy keeps running | static files: leaf certificates and keys, `ldap-ui.auth`, Caddy state |
| `env/<stack>.env` | `services/<stack>/.env` | copy | every secret the stacks need; not in git by design |
| `manifest.txt` | — | generated | stamp, host, repo commit, image tags per stack, GitLab archive name — what `restore.sh` checks against the checkout |
| `SHA256SUMS` | — | `sha256sum` over every file, relative paths | `sha256sum -c` from inside the set |

Not in the set, restored from the repository: [`pki/ca.crt`](../pki/ca.crt) (public CA
certificate, also copied to `/srv/gitlab/config/trusted-certs/`). Not in the set
at all: the PostgreSQL data directories (`*/db`, recreated from the dumps) and
`/srv/gitlab/logs`.

The set contains every secret of the installation in plaintext. Therefore:
`root:backup` with `0750/0640` while the directory exists, `age` encryption
before anything leaves the host, and the plaintext removed in the same run.
The recipient (public key) is [`scripts/backup-recipients.txt`](../scripts/backup-recipients.txt); the identity
(private key) lives in the password manager and never on the server.

All tar archives are written and read with `--numeric-owner`: the remapped
owners (100000, 101000, 100070 — [ADR-0002](adr/0002-os-and-docker.md)) have no user names on any host, and
`bootstrap.sh` pins the subordinate range so the numbers are the same on a
rebuilt host.

## Backup procedure

```
sudo ./scripts/backup.sh
```

Order inside the script (each stack: stop → dump/tar → start; an `EXIT` trap
restarts stopped containers even after a failure):

1. preconditions: root, `/srv/backups`, group `backup`, `age` and the
   recipients file, the four `.env` files, `gitlab` healthy
2. lldap — stop, tar, start (seconds)
3. openproject — stop `web` + `worker`, `pg_dump`, tar assets, start
   (`compose start` re-runs the seeder, ~45 s, [P-013](problems.md#p-013--docker-compose-start-re-runs-the-openproject-seeder-on-every-backup))
4. xwiki — stop `xwiki`, `pg_dump`, tar data, copy cacerts, start
5. gitlab — `gitlab-backup create` with the instance running, move the archive
   into the set, copy secrets, `gitlab.rb`, SSH host keys
6. proxy archives, `.env` files, manifest, `SHA256SUMS`
7. ownership `root:backup`, rename `<stamp>.partial` → `<stamp>` (atomic),
   encrypt to `<stamp>.tar.age`, remove the plaintext
8. prune: keep the 7 newest `.tar.age` (sorted by name), remove stale
   `.partial` leftovers

Measured on 2026-09-20, six runs on two hosts (three by hand on the source
host, three on the rebuilt host including one through `backup.service`):
1 min 17–33 s wall clock, 64 MB per set; service interruption per application
1–45 s (OpenProject longest because of the seeder).

Off-host copy (3-2-1), pulled from the workstation over SSH — the admin is in
group `backup`, so no root is involved:

```
install -d -m 700 ~/backups/<host>
rsync -a --info=progress2 <host>:/srv/backups/ ~/backups/<host>/
```

Check that the identity decrypts the copy, without leaving plaintext behind:

```
T="$(mktemp -d)"; age -d -i <identity file> ~/backups/<host>/<stamp>.tar.age | tar -x -C "$T" \
  && (cd "$T"/<stamp> && sha256sum -c SHA256SUMS); rm -rf "$T"
```

Scheduling: `bootstrap.sh` installs `backup.service` (oneshot, runs the script
as root) and `backup.timer` (`OnCalendar=*-*-* 03:00:00 UTC`,
`RandomizedDelaySec=15min`, `Persistent=true` so a run missed while the host
was down happens after boot). RPO is therefore up to 24 h. Useful commands:
`systemctl list-timers backup.timer`, `sudo systemctl start backup.service`
(run now), `sudo journalctl -u backup.service -n 50` (last run's log).

## Restore procedure

On a fresh host, after the README runbook steps "Host preparation" (admin
account, SSH key, firewall) and `git clone` at the commit the set came from:

```
sudo ./scripts/bootstrap.sh                    # packages, userns-remap, /srv layout, group backup, age
rsync -a ~/backups/<host>/<stamp>.tar.age <new host>:/tmp/   # from the workstation
sudo install -m 640 -g backup /tmp/<stamp>.tar.age /srv/backups/
install -m 600 /dev/null ~/age.key && $EDITOR ~/age.key      # paste the identity from the password manager
time sudo ./scripts/restore.sh /srv/backups/<stamp>.tar.age ~/age.key
rm ~/age.key
```

`restore.sh` refuses to continue if (1) a checksum in the set does not match,
(2) the image tags in the manifest differ from the `compose.yaml` files of the
checkout, or (3) any `/srv` target directory, `.env` file or stack container
already exists. Then: host artifacts → lldap → proxy → OpenProject (db
container alone, `pg_restore --no-owner -1`, assets, rest of the stack) →
XWiki (same) → GitLab (secrets, host keys and archive in place, start,
`gitlab-backup restore`, restart, `gitlab:check`) → machine verification
(containers healthy, four hostnames answer over TLS via `curl --resolve`).
The decrypted set is removed at the end.

After the script: update the workstation's `/etc/hosts` entry for the four
names to the new address, then the functional checklist below. Note that
GitLab's first start on the empty database writes a fresh
`/srv/gitlab/config/initial_root_password`; the restore replaces the database
afterwards, so that file is stale — `restore.sh` removes it ([P-020](problems.md#p-020--a-stale-initial_root_password-reappears-after-a-restore)).

## Restore test protocol
| Date | Host state | Steps | Duration (RTO) | Result | Findings |
|---|---|---|---|---|---|
| 2026-09-20 | new VPS, same image (Debian 13) and size; the source host kept running for comparison | first root login → admin account → deploy key → `git clone` → `bootstrap.sh` → copy set + identity → `restore.sh` → machine verification | **21 min 08 s** from first root login to all containers healthy and all four hostnames answering over TLS (timestamps from file birth times and the script log); `restore.sh` alone 11 min 06 s | passed — functional checklist below completed afterwards (~15 min, manual) | [P-015](problems.md#p-015--the-debian-13-cloud-image-has-no-git-but-the-reinstall-path-starts-with-git-clone) (`git` missing on the image, ~1 min), [P-016](problems.md#p-016--restoresh-exited-silently-in-its-own-verification-step) (verifier bug, no data impact); `gitlab:check` reported Sidekiq "not running" immediately after the restart, `gitlab-ctl status` two minutes later showed it running (start-up order, not a fault) |

Phase durations of `restore.sh` in that run: lldap 0:35 · proxy 0:04 ·
OpenProject 2:52 (pg_restore, seeder, healthcheck) · XWiki 1:17 · GitLab first
start 3:09 · `gitlab-backup restore` 1:02 · GitLab restart + `gitlab:check`
2:07. GitLab is 57 % of the script time; the rest is dominated by container
start-up, not by data volume (64 MB set).

Verification checklist after restore (functional — what the script cannot know), result of 2026-09-20:
- [x] all four hostnames answer over HTTPS with the lab CA certificate (browser, no warning; `curl --cacert pki/ca.crt --resolve` from the workstation: 302/302/302/401, `ssl_verify_result 0`)
- [x] LDAP login `alice` works in GitLab, XWiki and OpenProject; `bob` (no group) is refused in all three (group filters, [`docs/integration.md`](integration.md))
- [x] the test repository clones via SSH `:2222` without a host-key warning — the restored host key has the same fingerprint as on the source host (`ssh-keyscan` on both, [P-014](problems.md#p-014--gitlab-backup-covers-neither-the-ssh-host-keys-nor-trusted-certs))
- [x] the test wiki page exists
- [x] OpenProject: project visible to `alice`, work package `Test` with attachment `Test-restore-openproject.txt` opens with the original content

Not covered by this test: HTTPS clone with a token (the test token had expired),
CI artifacts and LFS (none exist), a restore onto a *different* GitLab
version (the version guard refuses it by design).
