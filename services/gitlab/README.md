# services/gitlab — GitLab CE (Omnibus)

Design: [ADR-0004](../../docs/adr/0004-git-server.md) (why GitLab),
[ADR-0010](../../docs/adr/0010-gitlab-container.md) (container configuration,
hardening, resources).

## Files
- `compose.yaml` — one container; the whole Omnibus configuration is the
  `GITLAB_OMNIBUS_CONFIG` block (evaluated on every start, never written to
  `gitlab.rb`). The only `.env` value is `GITLAB_LDAP_BIND_PASSWORD` (LDAP block).

## Host prerequisites
```
/srv/gitlab/config/               owner 100000   -> /etc/gitlab      (gitlab.rb template, gitlab-secrets.json, trusted-certs/)
/srv/gitlab/config/trusted-certs/ owner 100000   pre-created by bootstrap; reconfigure adds rehash symlinks
/srv/gitlab/logs/                 owner 100000   -> /var/log/gitlab
/srv/gitlab/data/                 owner 100000   -> /var/opt/gitlab  (repositories, database, uploads)
```
`100000` = container root under `userns-remap` (ADR-0002); Omnibus chowns the
per-service subdirectories to its own users (`git`, `gitlab-psql`, …), which
land at 100000 + UID on the host. Created by `scripts/bootstrap.sh`.
`pki/ca.crt` is copied into `trusted-certs/` with that owner (first-start step
below). It is not bind-mounted: `reconfigure` sets owner and mode on every file
in that directory, which fails on a mount (`docs/problems.md` P-010).

Networks `edge` (reached by Caddy) and `ldap` (reaches lldap) exist before the
stack starts (bootstrap). The only published port is `2222` (Git over SSH);
HTTP is reachable only through Caddy as `gitlab:80`.

## First start
```
sudo install -o 100000 -g 100000 -m 644 ~/Test-Projekt/pki/ca.crt /srv/gitlab/config/trusted-certs/ca.crt
cd ~/Test-Projekt/services/gitlab
sudo docker compose config --quiet          # interpolation and schema check, no daemon needed
sudo docker compose up -d
sudo docker logs -f gitlab                  # "gitlab Reconfigured!" then services start; 3-5 min
```
Then, once `sudo docker ps` shows `(healthy)`:

1. Read the generated root password on the host — do not paste it anywhere:
   `sudo grep -v '^#' /srv/gitlab/config/initial_root_password | grep -v '^$'`
   (the file is deleted after 24 h). Sign in at https://git.lab.test as
   `root`, change the password (avatar → Edit profile → Password).
2. Admin → Settings → General (`/admin/application_settings/general`), each
   section has its own *Save changes*:
   - *New user account restrictions*: untick **Allow new user accounts**.
     Minimum password length stays at the default 8: admins have enforced
     MFA, and NIST SP 800-63B accepts 8 characters with a second factor;
     LDAP users' passwords live in lldap, not here.
   - *Sign-in restrictions*: untick **Allow password authentication for Git
     over HTTP(S)** (personal access tokens only), tick **Enforce two-factor
     authentication for administrators**, grace period `0`, tick **Enable
     Admin Mode**. E-mail based options stay off (no mail server).
   GitLab then forces the 2FA set-up for `root` on the next page load: TOTP
   app, and store the recovery codes in the password manager.
3. Create a private project (namespace `root`, initialise with a README) and
   run the clone test below.

Verified 2026-09-19: sign-up closed (`/users/sign_up` → 302 to sign-in),
HTTPS clone with a token through the private CA, SSH clone and push on 2222
with a dedicated key; the SSH host key fingerprint shown on first connect
matched the one printed in the container's first-start log.

## Workstation access to Git
- HTTPS: git must trust the private CA; either import `pki/ca.crt` into the
  system store or pass it per clone:
  `git -c http.sslCAInfo=/path/to/pki/ca.crt clone https://git.lab.test/<ns>/<project>.git`.
  Username is the GitLab user, password is a personal access token with the
  scopes `read_repository`/`write_repository` (password authentication for
  Git over HTTPS is disabled).
- SSH: one dedicated key per person and purpose (`ssh-keygen -t ed25519 -f
  ~/.ssh/gitlab-lab`), public key added under Edit profile → SSH Keys.
  `~/.ssh/config` block, so plain `git clone git@git.lab.test:<ns>/<project>.git`
  works:
  ```
  Host git.lab.test
      Port 2222
      IdentityFile ~/.ssh/gitlab-lab
  ```
  On first connect compare the host key fingerprint with
  `ssh-keyscan -p 2222 -t ed25519 git.lab.test | ssh-keygen -lf -` run
  from a trusted machine, or with the container's first-start log.

## Verification (evidence for docs/security.md)
Run on the host after the first start; expected results in brackets.

```
# the proxy's name resolves to Caddy, not to the container itself (P-011)  [Caddy's address]
sudo docker exec gitlab getent hosts git.lab.test
# self-call through Caddy with TLS: hairpin works and the CA is trusted  [200]
sudo docker exec gitlab curl -sS -o /dev/null -w '%{http_code}\n' https://git.lab.test/users/sign_in
# no-new-privileges tolerated by Omnibus  [all services "run"]
sudo docker exec gitlab gitlab-ctl status
# registry / pages / kas / prometheus absent    [no such lines]
sudo docker exec gitlab gitlab-ctl status | grep -E 'registry|pages|kas|prometheus'
# memory limit applied                    [8589934592]
sudo docker inspect --format '{{.HostConfig.Memory}}' gitlab
# bundled nginx serves HTTP only, no HSTS from the backend  [HTTP/1.1 302, no strict-transport-security]
sudo docker exec gitlab curl -sI http://localhost/ | grep -Ei '^(HTTP|strict-transport|location)'
# security headers on a real 200/302 (P-007)  [strict-transport-security, x-content-type-options, referrer-policy present]
curl -sI https://git.lab.test/users/sign_in | grep -Ei 'strict-transport|x-content-type|referrer-policy|server:'
# real client IP, forged header must NOT win  [last line shows your IP, not 203.0.113.9]
curl -s -o /dev/null -H 'X-Forwarded-For: 203.0.113.9' https://git.lab.test/users/sign_in
sudo tail -1 /srv/gitlab/logs/nginx/gitlab_access.log
# trusted CA linked  [ca.crt plus a <hash>.0 symlink]
sudo ls -l /srv/gitlab/config/trusted-certs/
# actual memory use for ADR-0010  [note the number]
sudo docker stats --no-stream gitlab
# start-up noise that must not grow: one NoScriptError per Puma start, three
# "Peer authentication failed" per reconfigure  [counts stay constant]
sudo docker logs gitlab 2>&1 | grep -c NoScriptError
sudo docker logs gitlab 2>&1 | grep -c 'Peer authentication failed'
```
Results on 2026-09-19 (first build): all checks as expected. `docker stats`
showed 5.97 GiB idle with the auto-detected 8 Puma workers and 2.91 GiB with
`puma['worker_processes'] = 2` (ADR-0010, decision 7). Because the image tails the log files in the volume, `docker logs`
also replays entries from before a container was recreated.

## Operations
- Configuration change: edit `compose.yaml`, `sudo docker compose up -d`
  (recreates the container, reconfigure runs, 2–3 min). `docker logs`
  replays the log files in the volume, so entries from before the recreate
  appear again.
- Lost root password ("forgot password" cannot work without mail):
  `sudo docker exec -it gitlab gitlab-rake "gitlab:password:reset[root]"` —
  Rails takes 30–60 s to load before it prompts twice for the new password
  (https://docs.gitlab.com/security/reset_user_password/). 2FA stays
  configured; a lost authenticator is covered by the recovery codes.
- Upgrade: see ADR-0004 (backup → upgrade path tool → change the image tag).
- Backup: `gitlab-backup create` plus `gitlab-secrets.json`, `gitlab.rb` and the SSH host keys from `/srv/gitlab/config` — none of which the backup tar contains (`docs/backup-restore.md`, P-014). Restore only onto the same image tag.
