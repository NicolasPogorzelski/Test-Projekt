# scripts

| Script | Runs on | Purpose |
|---|---|---|
| `bootstrap.sh` | host, as root via `sudo` | host baseline: sshd, unattended-upgrades, Docker CE, userns-remap, sudoers, `/srv`, networks |
| `backup.sh` | host | _TBD (day 3)_ |
| `restore.sh` | host | _TBD (day 3)_ |
| `git-hooks/pre-commit` | workstation | gitleaks on the staged changes + private-identifier check; activate with `git config core.hooksPath scripts/git-hooks` (README, "Workstation setup") |

## bootstrap.sh

Turns a fresh Debian 13 host into the state described in
[`docs/security.md`](../docs/security.md) ("Host" table). It is the first step
of a reinstall (`clone → bootstrap.sh → restore.sh`, ADR-0008).

```
sudo ./scripts/bootstrap.sh
```

Run it **from the admin account with `sudo`**, never from a root shell: the
script takes the calling user from `SUDO_USER` and writes it into
`AllowUsers`; started as root it refuses, because `PermitRootLogin no` plus
`AllowUsers root` would lock everyone out.

### What it does, in order

1. Preconditions: root, `SUDO_USER` set and not root, that user has a non-empty
   `authorized_keys`, Debian 13 (trixie), amd64.
2. `sshd` drop-in `10-hardening.conf`, checked with `sshd -t` before
   `systemctl reload ssh`.
3. `unattended-upgrades` with the package defaults plus the Docker origin in a
   separate drop-in.
4. Docker apt repository: downloads the signing key, **compares its primary
   fingerprint with the value pinned in the script**, and only then installs it
   under `/etc/apt/keyrings/`; deb822 source with `Signed-By`; apt pin
   `5:29.*` at priority 990 for `docker-ce` and `docker-ce-cli`.
5. `dockremap` user with a fixed subordinate range `100000:65536`, so the host
   UIDs used for bind mounts (container UID + 100000) are the same on every
   rebuild.
6. `/etc/docker/daemon.json` is written **before** the packages are installed:
   the package postinst starts `dockerd`, which reads the file on its first
   start, so no image is ever stored in the unmapped location.
7. `/etc/sudoers.d/docker-readonly` (checked with `visudo -c`, mode 0440).
8. `/srv` directory layout with the owners the stacks expect.
9. Docker networks `edge` (bridge, publishes ports) and `ldap` (`--internal`).
10. `git` and `rsync`.
11. Self-test: prints one `PASS`/`FAIL` line per measure and exits non-zero on
    any failure. The output is the evidence for the status column in
    `docs/security.md`.

### Idempotency

Every step checks before it acts and prints `skip` when nothing has to change.
Configuration files are compared byte by byte (and by mode); a changed
`daemon.json` restarts Docker only if the daemon was already installed
(`live-restore` keeps running containers up). Verified on 2026-09-19: a second
run on the prepared host reported only `skip` lines and 12× `PASS`.

### What it does not do

Recorded in the README runbook, because these steps are interactive or hold
secrets: creating the admin user and its SSH key, the Hetzner cloud firewall,
the GitHub deploy key, copying the certificates, the `.env` files.

### Lint

```
bash -n scripts/bootstrap.sh
shellcheck --severity=warning scripts/bootstrap.sh
```

The same shellcheck call runs in CI for every tracked `*.sh`.
