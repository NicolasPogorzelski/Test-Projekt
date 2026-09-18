# ADR-0002: Debian 13, Docker CE, userns-remap

## Status
Accepted

## Context
The host needs an operating system and a container runtime. Nothing runs on the
host itself except Docker and the backup scripts; all applications are
containers.

## Options considered

### Operating system
- **Debian 12 (bookworm)** — familiar, but in LTS since 2026-06-11: security
  updates come from the separate LTS team with reduced coverage, end of life
  June 2028 (https://wiki.debian.org/LTS).
- **Debian 13 (trixie)** — current stable (released 2025-08-09), kernel 6.12,
  OpenSSL 3.5, OpenSSH 10; regular security support by the Debian Security
  Team.

### Docker installation
- **`docker.io` from Debian** — version 26.1.5 in trixie (two major versions
  behind upstream), single trust base, patched by Debian.
- **Docker CE from the Docker apt repository** — current engine (29.x),
  fastest security fixes for `dockerd`/`containerd`/`runc`, `docker compose`
  plugin; adds a third-party repository to the trust base
  (https://docs.docker.com/engine/install/debian/).
- **Podman** — rootless by default, but the task says "Docker environment" and
  the vendors' compose files are tested on Docker.

### Privilege model
- **Rootful (default)** — root in a container is root on the host if the
  container is escaped.
- **Rootful + `userns-remap`** — the daemon stays root, but UID 0 inside every
  container is mapped to an unprivileged host UID from `/etc/subuid`
  (https://docs.docker.com/engine/security/userns-remap/).
- **Rootless** — daemon and containers unprivileged; smallest blast radius, but
  ports below 1024 need a sysctl, user-space networking loses the client
  source IP, and the vendors' compose files are untested in this mode.

## Decision
Debian 13, Docker CE from the Docker repository, rootful daemon with
`userns-remap` enabled before the first image pull.

## Rationale
- A fresh installation defaults to current stable; there is no concrete reason
  to deviate. Debian 12 being in LTS is the deciding fact.
- `dockerd` is the most privileged process on the host; it should receive
  security fixes fastest. This requires three measures: (1) the Docker
  repository key is scoped with `Signed-By:` to that repository only,
  (2) `unattended-upgrades` includes the Docker origin, (3) apt pinning
  restricts automatic upgrades to the current major version (`29.*`); major
  upgrades are done manually after reading the release notes.
- `userns-remap` is one line in `daemon.json` and limits the damage of a
  container escape without the operational restrictions of rootless mode.
  It is damage limitation, not a guarantee: kernel exploits can bypass user
  namespaces. Container hardening (non-root images where available,
  `cap_drop: [ALL]`, `no-new-privileges`, read-only where possible, no
  published ports except the proxy) applies regardless.

## Consequences
- `/tmp` is a tmpfs on Debian 13: scripts must not stage large files there.
- Bind-mounted directories must be owned by the *remapped* UID
  (subuid start + container UID); this is expected to cause permission
  issues and is documented in `docs/problems.md`.
- Images requiring `--privileged` or `--network=host` cannot run; none are
  needed.
- Fallback: if `userns-remap` costs more than one hour on day 1, it is
  disabled and the decision is recorded as reverted.
- Rootless Docker remains the next hardening step for a production setup.

## Addendum: `docker` group vs. `sudo`
The Docker socket is owned by root and the `docker` group; members of that
group can start containers with arbitrary host mounts and are therefore
root-equivalent without a password prompt and without a `sudo` audit entry
(Docker: "Docker daemon attack surface"; CIS Docker Benchmark, host
configuration). The admin user is deliberately **not** added to the group.
Docker is used via `sudo`, which keeps a second factor (the sudo password,
stored only in the password manager) between a stolen SSH key and root, and
logs every privileged action.

For unattended read-only checks (monitoring, tooling, restricted operators) a
minimal sudoers rule allows exactly `docker ps`, `docker ps -a`,
`docker info`, `docker images`, `docker logs <container>` and
`docker compose ls` without a password (`/etc/sudoers.d/docker-readonly`,
created with `visudo -f`). `docker inspect` (would reveal environment
variables) and `docker exec` are intentionally excluded; anything that
changes state still requires the password.
