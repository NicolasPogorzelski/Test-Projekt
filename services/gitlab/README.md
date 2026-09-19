# services/gitlab — GitLab CE (Omnibus)

Design: [ADR-0004](../../docs/adr/0004-git-server.md) (why GitLab),
[ADR-0010](../../docs/adr/0010-gitlab-container.md) (container configuration,
hardening, resources).

## Files
- `compose.yaml` — one container; the whole Omnibus configuration is the
  `GITLAB_OMNIBUS_CONFIG` block (evaluated on every start, never written to
  `gitlab.rb`). No `.env` is needed until the LDAP block is added (phase 6).

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

1. Read the generated root password:
   `sudo cat /srv/gitlab/config/initial_root_password` (file is deleted after
   24 h). Sign in at https://git.lab.test as `root`, change the password
   (user menu → Edit profile → Password).
2. Admin area → Settings → General → *Sign-up restrictions*: disable
   "Sign-up enabled". Same page, *Sign-in restrictions*: enable
   "Enforce two-factor authentication" (grace period 0 for admins).
3. Clone test (workstation, CA imported):
   `git clone https://git.lab.test/<group>/<project>.git` and
   `git clone ssh://git@git.lab.test:2222/<group>/<project>.git`.

## Verification (evidence for docs/security.md)
Run on the host after the first start; expected results in brackets.

```
# no-new-privileges tolerated by Omnibus  [all services "run"]
sudo docker exec gitlab gitlab-ctl status
# registry / pages / prometheus absent    [no such lines]
sudo docker exec gitlab gitlab-ctl status | grep -E 'registry|pages|prometheus'
# memory limit applied                    [8589934592]
sudo docker inspect --format '{{.HostConfig.Memory}}' gitlab
# nginx in the container serves HTTP only, no HSTS from the backend  [HTTP/1.1 302, no strict-transport-security]
sudo docker exec caddy wget -qS -O /dev/null http://gitlab/ 2>&1 | head -12
# security headers on a real 200/302 (P-007)  [strict-transport-security, x-content-type-options, referrer-policy present]
curl -sI https://git.lab.test/users/sign_in | grep -Ei 'strict-transport|x-content-type|referrer-policy|server:'
# real client IP, forged header must NOT win  [last line shows your IP, not 203.0.113.9]
curl -s -o /dev/null -H 'X-Forwarded-For: 203.0.113.9' https://git.lab.test/users/sign_in
sudo tail -1 /srv/gitlab/logs/nginx/gitlab_access.log
# trusted CA linked  [ca.crt plus a <hash>.0 symlink]
sudo ls -l /srv/gitlab/config/trusted-certs/
# actual memory use for ADR-0010  [note the number]
sudo docker stats --no-stream gitlab
```

## Operations
- Configuration change: edit `compose.yaml`, `sudo docker compose up -d`
  (recreates the container, reconfigure runs, 2–3 min).
- Upgrade: see ADR-0004 (backup → upgrade path tool → change the image tag).
- Backup: `gitlab-secrets.json` + the three volumes (ADR-0008, day 3).
