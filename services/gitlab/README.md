# services/gitlab — GitLab CE (Omnibus)

Design: [ADR-0004](../../docs/adr/0004-git-server.md) (why GitLab),
[ADR-0010](../../docs/adr/0010-gitlab-container.md) (container configuration,
hardening, resources). First installation, step by step:
[`docs/install.md`](../../docs/install.md) 5.9–5.12. This file is the
reference for the stack.

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
`100000` = container root under `userns-remap` ([ADR-0002](../../docs/adr/0002-os-and-docker.md)); Omnibus chowns the
per-service subdirectories to its own users (`git`, `gitlab-psql`, …), which
land at 100000 + UID on the host. Created by [`scripts/bootstrap.sh`](../../scripts/bootstrap.sh).
Your CA (`/srv/proxy/certs/ca.crt`, the one the leaf certificates were signed
with) is copied into `trusted-certs/` with that owner ([`docs/install.md`](../../docs/install.md) 5.9;
on a restore, `restore.sh` takes it from the backup set). It is not bind-mounted: `reconfigure` sets owner and mode on every file
in that directory, which fails on a mount ([`docs/problems.md`](../../docs/problems.md) [P-010](../../docs/problems.md#p-010--gitlab-reconfigure-fails-on-a-bind-mounted-ca-certificate)).

Networks `edge` (reached by Caddy) and `ldap` (reaches lldap) exist before the
stack starts (bootstrap). The only published port is `2222` (Git over SSH);
HTTP is reachable only through Caddy as `gitlab:80`.

## Why the first-start settings
The steps are in [`docs/install.md`](../../docs/install.md) 5.10–5.11; the
reasons:

- **Root password from `initial_root_password`, not from `.env`.** GitLab
  generates it on the first start; the file is deleted after 24 h. Nothing
  in the repository or the environment holds it ([ADR-0010](../../docs/adr/0010-gitlab-container.md)).
- **Sign-up off** (*Allow new user accounts*): accounts come from lldap; a
  public sign-up form would let anyone who reaches the host create one.
- **Minimum password length stays at the default 8:** admins have enforced
  MFA, and NIST SP 800-63B accepts 8 characters with a second factor; LDAP
  users' passwords live in lldap, not here.
- **No password authentication for Git over HTTP(S):** personal access tokens
  only — scoped, expiring, revocable one by one.
- **2FA enforced for administrators**, grace period `0`, **Admin Mode** on:
  the admin area asks again for password and TOTP code. E-mail based options
  stay off (no mail server).

Verified 2026-09-19 and again on 2026-10-19: sign-up closed
(`/users/sign_up` → 302 to sign-in), HTTPS clone and push with a token through
the private CA. On 2026-09-19 also SSH clone and push on 2222 with a dedicated
key; the SSH host key fingerprint shown on first connect matched the one
printed in the container's first-start log.

## Workstation access to Git
- HTTPS: git must trust your CA; either import it into the system store or
  set it per repository:
  `git -c http.sslCAInfo=$HOME/Test-Projekt/pki/ca.crt clone https://git.lab.test/<ns>/<project>.git`,
  then `git config http.sslCAInfo $HOME/Test-Projekt/pki/ca.crt` inside the
  clone. Not with `--global`: `http.sslCAInfo` replaces Git's list of trusted
  CAs, so every clone from a public host would fail. Username is the GitLab
  user, password is a personal access token with the scopes
  `read_repository`/`write_repository` (password authentication for Git over
  HTTPS is disabled).
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
`puma['worker_processes'] = 2` ([ADR-0010](../../docs/adr/0010-gitlab-container.md), decision 7). Because the image tails the log files in the volume, `docker logs`
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
- Upgrade: see [ADR-0004](../../docs/adr/0004-git-server.md) (backup → upgrade path tool → change the image tag).
- Backup: `gitlab-backup create` plus `gitlab-secrets.json`, `gitlab.rb` and the SSH host keys from `/srv/gitlab/config` — none of which the backup tar contains ([`docs/backup-restore.md`](../../docs/backup-restore.md), [P-014](../../docs/problems.md#p-014--gitlab-backup-covers-neither-the-ssh-host-keys-nor-trusted-certs)). Restore only onto the same image tag.
