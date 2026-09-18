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
