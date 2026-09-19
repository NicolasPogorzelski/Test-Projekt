# Problems and peculiarities

Chronological. Format: symptom → verification → cause → fix / decision.

## P-001 — Flatpak browsers do not use the system CA trust store
- **Symptom:** (anticipated) after `update-ca-trust` on the Fedora-based
  workstation, Firefox/Chrome still show a certificate warning for
  `*.lab.test`.
- **Verification:** `flatpak list --app` shows Firefox and Chrome installed as
  Flatpaks; Flatpak sandboxes ship their own trust store.
- **Cause:** Flatpak applications do not read `/etc/pki/ca-trust`.
- **Fix:** import `pki/ca.crt` in the browser's own certificate manager
  (Firefox: Settings → Privacy & Security → Certificates → Authorities →
  Import). Documented in the README for other admins.

## P-002 — SSH host key fingerprint not visible before the first connection
- **Symptom:** the Hetzner web console only showed the login prompt; the
  cloud-init block `SSH HOST KEY FINGERPRINTS` had already scrolled out of the
  buffer, so the fingerprint could not be compared before the first `ssh`.
- **Verification:** first connection made with
  `StrictHostKeyChecking=accept-new` (accepts a *new* key, never a *changed*
  one); afterwards `ssh-keygen -l -f /etc/ssh/ssh_host_ed25519_key.pub` on the
  server and `ssh-keygen -l -F <ip>` on the workstation were compared: both
  `SHA256:oKz1ekLeBzSwijRdYIiTLhHp8jXc94LcvlWcnsBL3LU`.
- **Cause:** limited scrollback of the browser console; no fingerprint shown
  in the server details.
- **Decision:** trust-on-first-use accepted for a server that was seconds old,
  with immediate post-hoc verification. Residual risk documented; a
  production process would publish host keys out of band (e.g. via the
  provider API or SSHFP records).

## P-003 — `deluser --remove-home` fails on the minimal Debian image
- **Symptom:** `deluser --remove-home <user>` aborts with
  "you need to install the `perl' package".
- **Verification:** `dpkg -l perl` → not installed; `deluser` is a Perl script.
- **Cause:** Hetzner's Debian 13 cloud image is minimal.
- **Fix:** use the C implementation `userdel -r <user>` instead of installing
  perl. (Context: the admin user had been created with a capital letter by
  mistake; Linux usernames are case-sensitive and lower-case by convention.)

## P-004 — Shared proxy network must not be `--internal`
- **Symptom:** (design correction during the build, no runtime error)
- **Cause:** a Docker network created with `--internal` has no NAT rule and
  cannot publish ports. Caddy must publish 80/443 on the `edge` network and
  the application containers need outbound Internet (extension downloads,
  webhooks).
- **Fix:** `edge` created as a regular bridge network; only `ldap` is
  `--internal`. Per-stack database networks are declared `internal: true` in
  the compose files.

## P-005 — Caddy exits with `exec /usr/bin/caddy: operation not permitted`
- **Symptom:** container restarts in a loop; `docker logs caddy` shows only the
  exec error. The compose service ran as `user: 1000:1000` with
  `cap_drop: [ALL]` and a sysctl (`net.ipv4.ip_unprivileged_port_start=0`)
  intended to allow binding ports 80/443 without capabilities.
- **Verification:** `docker run --rm --entrypoint sh caddy:2.11.4-alpine -c
  'apk add -q libcap && getcap /usr/bin/caddy'` →
  `/usr/bin/caddy cap_net_bind_service=ep`.
- **Cause:** the official image marks the binary with a *file capability*
  (`+ep`). Executing such a binary requires the capability to be present in
  the process' bounding set; `cap_drop: ALL` removes it and the kernel refuses
  the `exec` with EPERM — before Caddy even starts, so the port sysctl never
  mattered.
- **Fix:** `cap_drop: [ALL]` plus `cap_add: [NET_BIND_SERVICE]` — exactly one
  capability, the one the binary asks for; the sysctl was removed as
  redundant. Lesson: "drop all capabilities" must be checked against the
  image's file capabilities (`getcap`), not assumed.

## P-006 — HTTP/3 still listed on the port-80 redirect listener (open)
- **Symptom:** with `servers { protocols h1 h2 }` in the global block, the
  TLS servers run h1/h2, but the automatic HTTP→HTTPS redirect server logs
  `"protocols":["h1","h2","h3"]`.
- **Impact:** none — UDP/443 is neither published by the container nor allowed
  by the cloud firewall, so HTTP/3 is unreachable regardless.
- **Open:** verify in the Caddy documentation whether the option must be set
  per listener (`servers :80 { … }`) to cover the redirect server as well.

## P-007 — Security headers absent on 502 responses (closed 2026-09-19)
- **Symptom:** before any backend existed, `curl -I https://git.lab.test/`
  returned `502` with `server: Caddy` and without the HSTS/nosniff/Referrer
  headers from the `hardened` snippet.
- **Verification with a real backend (GitLab):** `curl -sI
  https://git.lab.test/users/sign_in` → `200` with
  `strict-transport-security`, `x-content-type-options: nosniff`,
  `referrer-policy: strict-origin-when-cross-origin` and no `server` header
  (Caddy also strips the backend's `Server: nginx`).
- **Cause:** a 502 generated by `reverse_proxy` is emitted through Caddy's
  error path, which does not pass through the site's `header` handler. Only
  Caddy's own error pages are affected.
- **Decision:** accepted. An error page reveals nothing and is not a
  navigable document; a `handle_errors` block that repeats the headers is an
  extension step. Observation from the same test: GitLab sends an empty
  `content-security-policy` header (CSP is off by default in GitLab and is
  enabled per application setting) — extension step, not part of the
  time-box.

## P-008 — `dockremap` received the same subordinate range as the admin user
- **Symptom:** `/etc/subuid` (and `/etc/subgid`) on the first host contain
  both `<admin>:100000:65536` and `dockremap:100000:65536` — two users, one
  identical range.
- **Verification:** `cat /etc/subuid /etc/subgid`; `login.defs` has
  `SUB_UID_MIN 100000`, so Debian's `useradd` had already given the first
  regular user the range starting at 100000. Docker's allocation code
  (moby tag `docker-v29.8.1`, `daemon/internal/usergroup/add_linux.go`:
  `defaultRangeStart = 100000`, `findNextUIDRange()` →
  `user.CurrentUserSubUIDs()`) only looks at the ranges of the *calling* user
  (root) and starts at its own default 100000 when none exist. Ranges of other
  users are never considered.
- **Cause:** two independent allocators (shadow's `useradd` and `dockerd`)
  with the same default start and no shared bookkeeping.
- **Impact:** none for isolation — the admin user does not run user
  namespaces, so nothing else maps these IDs. The real risk is
  **reproducibility**: on a rebuild `dockerd` could pick a different start
  (e.g. if root ever gets a range), and every documented host UID such as
  `101000` for Caddy would be wrong.
- **Fix:** `scripts/bootstrap.sh` creates `dockremap` itself and pins
  `dockremap:100000:65536` in `/etc/subuid` and `/etc/subgid`; `daemon.json`
  names the user explicitly (`"userns-remap": "dockremap"`) instead of
  `"default"`. The script warns when another user shares the range, which is
  expected on the first host and documents this finding on every run.

## P-009 — First image pulled before `userns-remap` was active
- **Symptom:** ADR-0002 says `userns-remap` is enabled "before the first
  image pull". The sudo journal of day 1 shows `docker run hello-world`
  *before* `daemon.json` was written and Docker restarted.
- **Verification:** `journalctl _COMM=sudo` order; `/var/lib/docker/image`
  (unmapped store) created 13:07, `/var/lib/docker/100000.100000` (mapped
  store) created 13:23.
- **Cause:** the manual order on day 1 was install → test → configure. The
  package postinst starts `dockerd` immediately with whatever `daemon.json`
  exists at that moment — nothing, in this case.
- **Impact:** none: the unmapped store only holds `hello-world`, which no
  stack uses; the remapped daemon never reads it. It costs a few kilobytes.
- **Fix:** `scripts/bootstrap.sh` writes `daemon.json` before
  `apt-get install docker-ce`, so the first `dockerd` start already runs with
  the remap and the unmapped store is never populated. Lesson: configuration
  files take effect when the process starts, not when they are written —
  put them in place before the first start.

## P-010 — GitLab `reconfigure` fails on a bind-mounted CA certificate
- **Symptom:** first start of the GitLab container aborts with
  `Errno::EROFS: Read-only file system @ apply2files -
  /etc/gitlab/trusted-certs/ca.crt` (`certificate_helper.rb`,
  `update_permissions`). `pki/ca.crt` had been bind-mounted read-only from
  the repository clone into `/etc/gitlab/trusted-certs/`.
- **Verification:** the Chef trace shows the failing step is
  `link_certificates → update_permissions`, i.e. a `chown`/`chmod` on the
  certificate file itself, before the rehash symlink is created.
- **Cause:** Omnibus normalises owner and mode of every file in
  `trusted-certs/`. That is impossible on a read-only mount, and would also
  fail on a read-write mount because the file on the host belongs to the
  admin user — an unmapped UID under `userns-remap`, which no process in the
  container may `chown`.
- **Fix:** no mount. The certificate is copied into the volume with the
  container's root UID: `install -o 100000 -g 100000 -m 644 pki/ca.crt
  /srv/gitlab/config/trusted-certs/ca.crt` (documented as a first-start step
  in `services/gitlab/README.md`). The copy travels with the volume in
  backups, so a restore needs no extra step. Lesson: a bind mount is the
  wrong tool for a file the application wants to own.

## P-011 — GitLab resolves its own external hostname to itself, not to the proxy
- **Symptom:** after the first successful start, the KAS service logs every
  30 s: `Get "https://git.lab.test/api/v4/internal/kubernetes/receptive_agents":
  dial tcp <address>:443: connect: connection refused`.
- **Verification:** `docker exec gitlab getent hosts git.lab.test` returns
  two addresses; `docker inspect` shows they are the GitLab container's own
  addresses in `edge` and `ldap`, and that Caddy has a different one.
- **Cause:** `compose.yaml` set `hostname: git.lab.test`. Docker writes a
  container's hostname with its own address into the container's
  `/etc/hosts`, and `/etc/hosts` wins over Docker's DNS. The proxy's network
  alias for `git.lab.test` (ADR-0005, hairpin) was therefore never consulted;
  any self-call through `external_url` reached the GitLab container itself,
  which listens on 80 only.
- **Fix:** drop `hostname:` (Omnibus derives everything from `external_url`)
  and disable KAS (`gitlab_kas['enable'] = false`) as an unused subsystem.
  Self-calls now go through Caddy with TLS — which also exercises the CA in
  `trusted-certs/`. Lesson: never give a container the hostname that the
  reverse proxy answers for.
