# ADR-0010: GitLab container — configuration, hardening, resources

## Status
Accepted

## Context
[ADR-0004](0004-git-server.md) chose GitLab CE (Omnibus image). Omnibus is a full distribution in
one container: Rails (Puma), Sidekiq, PostgreSQL, Redis, NGINX, Gitaly,
gitlab-shell with its own sshd, supervised by runit, which starts as root and
drops to a dedicated user per service. It is configured through one Ruby file
(`/etc/gitlab/gitlab.rb`) that `gitlab-ctl reconfigure` turns into the
individual service configurations. Running it behind Caddy ([ADR-0005](0005-reverse-proxy.md)) with
`userns-remap` ([ADR-0002](0002-os-and-docker.md)) raises six decisions that neither ADR covers.

## Decisions

### 1. Where the Omnibus configuration lives
- **Options:** (a) `GITLAB_OMNIBUS_CONFIG` in `compose.yaml`; (b) `gitlab.rb`
  edited on the host only; (c) a `gitlab.rb` in the repository, bind-mounted
  read-only, reading secrets via `ENV[...]`.
- **Decision: (a).** The variable is the documented way for the Docker image
  (https://docs.gitlab.com/install/docker/configuration/): evaluated on every
  start, before `gitlab.rb`, never written to it — the file stays the
  untouched template. The configuration is versioned and reviewable next to
  the stack; a change is `docker compose up -d`.
- **Rejected (b):** configuration outside the repository; a reinstall would
  depend on the backup for it. **Rejected (c):** functionally identical and
  more readable (a real `.rb` file can be syntax-checked with `ruby -c`),
  but whether the image's start-up wrapper tolerates a read-only `gitlab.rb`
  is unverified; at 3–5 minutes per GitLab start that test was not worth the
  time-box. Known and deliberately not taken.
- **Consequence:** the backup needs `gitlab-secrets.json` and the volumes;
  `gitlab.rb` on the host is only the template ([ADR-0004](0004-git-server.md) listed it as a
  backup item — now optional).

### 2. Container hardening
- **Options:** (a) Docker default capabilities + `no-new-privileges`;
  (b) nothing beyond `userns-remap`; (c) `cap_drop: ALL` with a minimal
  `cap_add` list.
- **Decision: (a).** `no-new-privileges` sets the kernel flag that stops any
  `exec` from gaining privileges via setuid bits or file capabilities; it
  does not stop an already-root process from *dropping* privileges with
  `setuid()`, which is what runit does — so Omnibus is expected to run.
  Verified at first start (see [`services/gitlab/README.md`](../../services/gitlab/README.md)).
- **Rejected (c) for now:** GitLab documents no minimal capability set; the
  list would be derived by trial (SETUID, SETGID, CHOWN, DAC_OVERRIDE,
  FOWNER, FSETID, KILL, SYS_CHROOT, NET_BIND_SERVICE as a starting point),
  and every missing capability shows up minutes later as a failing
  sub-service. **Extension step** for a production setup.
- **Honest statement:** this is *not* least privilege at the capability
  level. Isolation comes from `userns-remap` (container root = host UID
  100000), no socket, no host network, one published port, reachability only
  through the proxy.

### 3. Real client IP behind the proxy
- **Problem:** every request reaches the bundled NGINX from Caddy's container
  address. Without the `realip` module, logs, audit events and "last
  sign-in from" show the proxy, and GitLab's per-IP rate limits for
  unauthenticated requests treat all users as one address: one brute-force
  attempt locks everyone out.
- **Options:** (a) trust `X-Forwarded-For` from `172.16.0.0/12` (Docker's
  default address pool); (b) pin the `edge` subnet and give Caddy a fixed
  address, trust only that `/32`; (c) leave it.
- **Decision: (a)** — `gitlab_rails['nginx']['real_ip_trusted_addresses']`,
  `real_ip_header = X-Forwarded-For`, `real_ip_recursive = on`
  (https://docs.gitlab.com/omnibus/settings/nginx/). The broad range survives
  a rebuild without pinned subnets ([`scripts/bootstrap.sh`](../../scripts/bootstrap.sh) deliberately does
  not fix them).
- **Accepted residual risk:** any container on `edge` (the other stacks) could
  send a forged `X-Forwarded-For` directly to `gitlab:80`. An attacker in that
  position can already do worse. (b) is the precise extension step.
- **Verified 2026-09-19:** a request from the workstation with a forged
  `X-Forwarded-For: 203.0.113.9` was logged by GitLab (`remote_ip` in the
  Workhorse access log) with the workstation's real public address — Caddy
  does not pass a client-supplied header through (its `reverse_proxy`
  default without `trusted_proxies`), and `real_ip` takes the address Caddy
  sets.

### 4. Ownership of the bind-mounted directories
Under `userns-remap`, host UID 0 has no mapping inside the container, so
root-owned `/srv/gitlab/*` would be read-only for Omnibus and the first
`reconfigure` would fail. Omnibus does not know about the remap (without it,
container root *is* host root); the consequence is ours to implement. It is
implemented in [`scripts/bootstrap.sh`](../../scripts/bootstrap.sh) (owner table: `gitlab/*` → 100000,
including `config/trusted-certs`, which `reconfigure` writes rehash symlinks
into) rather than as a runbook step, so a reinstall cannot forget it.
The CA certificate is *copied* into `trusted-certs/` with owner 100000, not
bind-mounted from the repository: `reconfigure` chowns and chmods every file
there, which is impossible on a read-only mount and, on a read-write mount,
on a file owned by an unmapped host UID ([P-010](../problems.md#p-010--gitlab-reconfigure-fails-on-a-bind-mounted-ca-certificate)).

### 5. Initial root password
- **Options:** (a) `GITLAB_ROOT_PASSWORD` from `.env`; (b) let GitLab generate
  it (`/etc/gitlab/initial_root_password`, deleted after 24 h), change it at
  first login.
- **Decision: (b).** (a) would keep a secret in the container environment
  (visible via `docker inspect`) that is used exactly once and never again.
  A secret that is no longer needed should not exist. After a restore the
  password comes from the database anyway, so (a) has no reinstall advantage.
- **Consequence:** [`.env.example`](../../.env.example) has no `GITLAB_ROOT_PASSWORD`; the runbook
  reads the file once.

### 6. Memory limit
- **Decision: `mem_limit: 8g`** plus `shm_size: 256m` (required by the
  bundled PostgreSQL, GitLab docs). Omnibus is the largest consumer on a
  16 GB host shared with XWiki (JVM), OpenProject, two PostgreSQL instances,
  lldap and Caddy. Without a limit, a runaway GitLab lets the kernel OOM
  killer pick *any* process on the host; with it, the kill lands inside the
  container, runit restarts the affected service, and maintenance stays a
  single-container matter. The number is a starting point; real monitoring
  is out of scope.
- **Measured 2026-09-19:** 5.97 GiB idle right after the first start
  (74 % of the limit) on the 8-vCPU host. Omnibus sizes Puma workers by CPU
  count; for a small team that is oversized. Follow-up decision 7 below.
- Consistent with this, the bundled Prometheus is disabled (memory and one
  listener less); registry, Pages, KAS and outgoing mail are disabled as
  unused.

### 7. Puma and Sidekiq sizing
- **Finding:** the generated `puma.rb` had `workers 8, threads 4,4`.
  Omnibus derives the worker count from `nproc` (respecting cgroup CPU
  limits, not the memory limit) and available RAM — one worker per vCPU on
  this 8-vCPU host, each a full copy of the Rails application (~700 MB).
  Measured: 5.97 GiB idle.
- **Theoretical sizing (documented for reference):** GitLab's sizing guide
  lists "eight workers for 8 CPU cores and 16 GB of memory"
  (https://docs.gitlab.com/administration/operations/puma/, "Worker and
  thread sizing"), and the reference architecture for up to 1,000 users /
  20 requests per second is exactly one 8 vCPU / 16 GB node
  (https://docs.gitlab.com/administration/reference_architectures/1k_users/)
  — dedicated to GitLab. The installer therefore assumed it owns the host.
- **Real load:** the company is estimated at 20–30 people; this host also
  runs XWiki, OpenProject, two PostgreSQL instances, lldap and Caddy. A
  Puma worker handles CPU-bound requests one at a time; two workers × four
  threads keep eight requests in flight, which covers a team of that size
  with margin. Git push/pull and CI runners barely touch Puma.
- **Decision:** `puma['worker_processes'] = 2` (the documented minimum: "a
  node must never have fewer than two Puma workers" — the web editor needs
  two; the memory-constrained guide's single-process mode was therefore not
  chosen), `sidekiq['concurrency'] = 10` (default 20; recommended 5–10 in
  https://docs.gitlab.com/omnibus/settings/memory_constrained_envs/), and
  the Puma/Sidekiq metrics exporters off (same guide, "Disable monitoring";
  nothing scrapes them).
- **Rejected:** raising `mem_limit` instead — would keep paying RAM for
  capacity nobody uses; leaving it — no headroom for a push or a CI job
  once the other stacks run. Revisit when a CI runner or more than ~50
  users are added; it is one line and a two-minute restart.
- **Result:** 2.91 GiB idle after the change (was 5.97 GiB) — measured with
  `docker stats` a few minutes after the restart, 179 processes instead of
  332.

## Consequences
- All GitLab-specific NGINX keys use the `gitlab_rails['nginx'][...]`
  namespace introduced in GitLab 19.2; the old `nginx[...]` keys still work
  with a deprecation warning and are not used here.
- Compose interpolates `$VAR` inside `GITLAB_OMNIBUS_CONFIG`, so NGINX
  variables are written as `$$http_host_with_default` etc.
- Sign-up restriction and 2FA enforcement are application settings, not
  `gitlab.rb` keys: they are set after the first start (runbook).
- Revisit 2(c) and 3(b) for a production deployment; revisit 6 once real
  usage numbers exist.
