# Installation — from an empty workstation and an empty server to a working system

One linear path, top to bottom. The steps were walked through on a fresh
Debian 13 server and a workstation without any prior state (October 2026);
the few that were not re-run on that build are marked *not re-verified*.
Commands that run on the **workstation** and on the **host** are marked as
such.

This guide was written after a second build from scratch and corrects the
stack READMEs where they differ. Where a linked README says something else,
**this guide applies**. Known differences:

| README | says | correct (this guide) |
|---|---|---|
| `services/gitlab/README.md`, `services/xwiki/README.md` | install `~/Test-Projekt/pki/ca.crt` on the host | that file is the reference build's CA until 5.2 replaces it; this guide uses your CA |
| `pki/README.md` | `scp … lab:~/certs-upload/`, then `install` the keys | create the directory first, and `chown 101000` the keys (5.1, 5.2) |
| `proxy/README.md` | checks with `curl --resolve` | without `--resolve`, so `/etc/hosts` is tested too (5.6) |
| `services/xwiki/README.md` | activate the LDAP authenticator, then fill the form | fill the form first (5.15) — the other order can lock everyone out |
| `services/openproject/README.md` | Authentication → *LDAP authentication* | Authentication → **LDAP connections** (OpenProject 16.6) |
| `services/openproject/README.md` | `compose ps` shows the seeder | only `compose ps -a` does |
| `services/lldap/README.md` | every service-account password goes into its stack's `.env` | only GitLab's; OpenProject and XWiki take it in their admin UI |
| `proxy/README.md` | `caddy validate` as shown | needs a placeholder auth file (5.3) |
| `proxy/README.md` | `docker logs caddy \| tail` | `docker logs caddy 2>&1 \| tail` (5.5) |
| `scripts/backup-recipients.txt` | — | holds the reference build's key; replace it (4.1) |

Placeholders: `<server-ip>` is the public IPv4 of the host, `<admin>` the
admin account you create on it, `<your-key>` the file name of your SSH
private key in `~/.ssh/`.

## 1. Server and provider firewall

Outside the repository, at your cloud provider (the reference build used a
Hetzner Cloud CPX42, see [ADR-0001](adr/0001-hosting.md)):

| Setting | Value | Why |
|---|---|---|
| Image | Debian 13 (trixie), amd64 | `bootstrap.sh` targets Debian 13 only |
| Size | 8 vCPU / 16 GB RAM | GitLab and OpenProject together need the memory |
| SSH key | your public key, selected at creation (none yet: `ssh-keygen -t ed25519 -f ~/.ssh/<your-key>` on the workstation) | the first login as root uses it; without it the provider mails a root password instead |
| Firewall | inbound TCP 22, 80, 443, 2222 only, attached to the server | everything else stays closed; 2222 is GitLab's SSH |

Note the server's public IPv4 — it is `<server-ip>` below.

## 2. Workstation

### 2.1 Prerequisites

`openssl`, `ssh`, `git`, `curl`, `age` (backup key, section 4) and a
container runtime (`podman` or `docker`, for the syntax check in 5.3). Check
that they are installed:

```
openssl version
ssh -V
git --version
curl --version
age --version
podman --version          # or: docker --version
```

Git needs an identity for the push test in 5.12; set it once if
`git config --global user.name` prints nothing:

```
git config --global user.name "<your name>"
git config --global user.email "<your e-mail>"
```

### 2.2 Clone the repository

```
git clone https://github.com/NicolasPogorzelski/Test-Projekt.git ~/Test-Projekt
git -C ~/Test-Projekt log --oneline -1
```

The paths below assume this location. Run the `pki/` scripts from the
repository root (`cd ~/Test-Projekt`).

### 2.3 Create your own root CA

```
cd ~/Test-Projekt
./pki/make-ca.sh
```

The script asks three times for a passphrase: twice to set it on the new CA
key, once more to sign the CA certificate with it. Store it in a password
manager — every certificate issued later needs it. The private material goes
to `~/lab-pki/` (override with `PKI_DIR=<dir>`); the script refuses to run if
a CA key already exists there. Details of each `openssl` call:
[`pki/README.md`](../pki/README.md#make-cash--create-the-root-ca-run-once).

Expected: `subject=CN=lab.test Root CA, O=lab.test`, a validity of ten years
and a `sha256 Fingerprint=…` line. **Write this fingerprint down** — it is the
reference for every later check. It differs from the fingerprint printed in
`pki/README.md`, which belongs to the CA of the reference build.

`make-ca.sh` also copies the new `ca.crt` into the clone, so `git status`
shows `M pki/ca.crt`. That is intended: from now on your clone carries your CA.

### 2.4 Issue the four service certificates

One per service, with the full hostname. Each call asks once for the CA
passphrase:

```
./pki/issue-cert.sh git.lab.test
./pki/issue-cert.sh wiki.lab.test
./pki/issue-cert.sh pm.lab.test
./pki/issue-cert.sh ldap.lab.test
```

Expected for each: `…/issued/<host>.crt: OK`, a validity of one year and
`DNS:<host>` as Subject Alternative Name. Result in `~/lab-pki/issued/`: four
`.crt` (mode 644) and four `.key` (mode 600, not encrypted — Caddy reads them
at start-up). Details: [`pki/README.md`](../pki/README.md#issue-certsh-hostname--issue-a-service-certificate).

If a call stops with `bad decrypt` (wrong passphrase), it leaves an empty
`<host>.crt` plus `<host>.csr` and `<host>.key` behind, and the next attempt
refuses with `already exists`. Remove those three files, then run the call
again.

### 2.5 Trust the CA in your browser

Import **your** `pki/ca.crt` (the one `make-ca.sh` just wrote) as an authority
that identifies websites. Firefox and Firefox-based browsers: Settings →
search for "cert" → View/Manage Certificates → Authorities → Import → tick
"Trust this CA to identify websites". Chrome: Settings → Privacy and security
→ Security → Manage certificates → Authorities → Import. Browsers installed as
Flatpak ignore the system trust store, so import in the browser even if you
also add the CA system-wide ([P-001](problems.md#p-001--flatpak-browsers-do-not-use-the-system-ca-trust-store)).

Then open the imported entry ("lab.test Root CA") and compare its SHA-256
fingerprint with the one `make-ca.sh` printed in 2.3. If you imported a CA of
an earlier build before, several entries carry the same name — the
fingerprint tells them apart.

### 2.6 Name resolution

The `*.lab.test` names exist in no public DNS. Add one line to `/etc/hosts`
on the workstation (as root, e.g. `sudoedit /etc/hosts`):

```
<server-ip>  git.lab.test wiki.lab.test pm.lab.test ldap.lab.test
```

Check it — it must print `<server-ip>`:

```
getent hosts git.lab.test
```

Update this line whenever the host is rebuilt with a new address. Checks that
use `curl --resolve` bypass `/etc/hosts` and stay green while the browser
still goes to the old address.

## 3. Host preparation

### 3.1 First login as root

The provider placed your public key in `/root/.ssh/authorized_keys` when the
server was created:

```
ssh -o IdentitiesOnly=yes -i ~/.ssh/<your-key> root@<server-ip>
```

On the first connection SSH shows the server's host-key fingerprint and asks
whether to continue. To compare it out of band, run
`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` in the provider's web
console; in a lab, accepting it right after creating the server is a
reasonable shortcut.

### 3.2 Create the admin account (on the host, as root)

Lower-case username ([P-003](problems.md#p-003--deluser---remove-home-fails-on-the-minimal-debian-image)):

```
adduser --gecos "" <admin>                 # the password you set here is the sudo password
usermod -aG sudo <admin>
install -d -m 700 -o <admin> -g <admin> /home/<admin>/.ssh
install -m 600 -o <admin> -g <admin> /root/.ssh/authorized_keys /home/<admin>/.ssh/authorized_keys
exit
```

`adduser` ends with `usermod: no changes` — harmless, it comes from adduser's
own internal call. The account can now log in with the same key as root.

### 3.3 Log in as the admin and check sudo

`bootstrap.sh` disables root and password logins. Before running it, make sure
the admin account works — including sudo:

```
ssh -o IdentitiesOnly=yes -i ~/.ssh/<your-key> <admin>@<server-ip>
sudo -v                                     # asks for the password from 3.2; no output = OK
```

`IdentitiesOnly=yes` makes SSH offer only this key. After `bootstrap.sh` the
server allows three attempts per connection (`MaxAuthTries 3`); an SSH agent
holding several keys can use them up before the right one is tried and the
login ends with "Too many authentication failures". A block in
`~/.ssh/config` saves typing:

```
Host lab
    HostName <server-ip>
    User <admin>
    IdentityFile ~/.ssh/<your-key>
    IdentitiesOnly yes
```

### 3.4 Install git and clone the repository

The cloud image ships without git ([P-015](problems.md#p-015--the-debian-13-cloud-image-has-no-git-but-the-reinstall-path-starts-with-git-clone)):

```
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/NicolasPogorzelski/Test-Projekt.git ~/Test-Projekt
```

The repository is public, so HTTPS needs no credentials. For a private fork,
use a read-only deploy key instead ([`security.md`](security.md)).

## 4. Prepare the host: `bootstrap.sh`

On the host, as the admin (not as root — the script reads `SUDO_USER` and
allows only that account in `AllowUsers`):

```
sudo ~/Test-Projekt/scripts/bootstrap.sh 2>&1 | tee ~/bootstrap.log
echo "exit: ${PIPESTATUS[0]}"
```

`tee` keeps a copy of the output; `${PIPESTATUS[0]}` is the exit code of the
script itself (`$?` after a pipe would show the one of `tee`). Runtime about
two minutes. What it does: [`scripts/README.md`](../scripts/README.md).

Expected: a self-test block with only `PASS` lines, then `==> done` and
`exit: 0`. These messages on the way are normal:

| Message | Meaning |
|---|---|
| `gpg: directory '/root/.gnupg' created` | first use of gpg while importing Docker's signing key |
| `WARNING: /etc/subuid: another user shares the range starting at 100000` (and `subgid`) | the admin account and `dockremap` got the same subordinate range; no effect on isolation — [P-008](problems.md#p-008--dockremap-received-the-same-subordinate-range-as-the-admin-user) |
| `Old style watch rules are slower` (12×) | `auditctl` notice for file-watch rules; the rules are loaded |
| `added <admin> to group backup (re-login required)` | the group applies from the next login |

Keep this session open and check from a **second** terminal that the admin
can still log in and root cannot:

```
ssh -o IdentitiesOnly=yes -i ~/.ssh/<your-key> <admin>@<server-ip> true && echo "admin ok"
ssh -o IdentitiesOnly=yes -i ~/.ssh/<your-key> root@<server-ip> true      # Permission denied (publickey)
```

Then log out and in again so the `backup` group takes effect.

### 4.1 Your own backup key

`bootstrap.sh` already enabled the nightly `backup.timer`. `backup.sh`
encrypts every set to the public keys in `scripts/backup-recipients.txt` —
in a fresh clone that is the key of the reference build, so you could not
decrypt your own backups. Replace it before the first night. On the
**workstation**:

```
age-keygen -o ~/lab-pki/backup-identity.txt      # prints "Public key: age1…"
chmod 600 ~/lab-pki/backup-identity.txt
```

The identity file is the only way to decrypt a backup — keep a copy in the
password manager. On the **host**, replace the recipient with your public key:

```
echo '<your-age-public-key>' > ~/Test-Projekt/scripts/backup-recipients.txt
```

Replace the placeholder with the full `age1…` string `age-keygen` printed —
a placeholder left in the file makes every backup fail at the last step with
`malformed recipient at line 1`.

This edit — like the CA copy in 5.2 — exists only in the host's clone. A
reinstall from a fresh clone brings back the reference build's key and CA
without warning: keep your public key and CA with your other secrets and
re-apply both files after every `git clone` (or commit them to your own
fork).

Until every stack has its `.env` (5.14), the nightly run stops with `missing
…/.env` — expected. **After 5.15**, test the key once — start a backup on the
host, then fetch and decrypt it on the workstation:

```
sudo systemctl start backup.service                                   # host; stacks pause briefly
sudo journalctl -u backup.service --since '-5 min' --no-pager | tail -5   # host: "==> done"
ls /srv/backups/                                                      # host: <stamp>.tar.age, e.g. 20261019T111335Z
scp lab:/srv/backups/<stamp>.tar.age . && age -d -i ~/lab-pki/backup-identity.txt <stamp>.tar.age | tar -t   # workstation
```

`lab` is the SSH alias from 3.3 (without it:
`scp -o IdentitiesOnly=yes -i ~/.ssh/<your-key> <admin>@<server-ip>:/srv/backups/…`).
`tar -t` lists the set (`<stamp>/env/…`, `<stamp>/gitlab/…`, …) without
unpacking it. If encryption fails, `backup.sh` leaves the **unencrypted** set
`/srv/backups/<stamp>/` behind — delete it with
`sudo rm -rf /srv/backups/<stamp>` after fixing the cause. Details:
[`docs/backup-restore.md`](backup-restore.md).

## 5. Stacks

Order: proxy → lldap → gitlab → openproject → xwiki. Each stack's README has
the reference details; this section is the path through them. Every
generated secret (`.env` values, admin passwords, recovery codes) goes into
the password manager when it is created — `cat .env` shows the values.

The `install -m 600 /dev/null .env && printf … > .env` lines below create a
**new** `.env` each time. Run each of them exactly once per stack: if `.env`
already exists, skip that line. A second run replaces the secrets — a new
`LLDAP_KEY_SEED`, or database passwords that no longer match the database
initialised on the first start.

### 5.1 Copy the certificates to the host

On the **workstation** (`lab` = the `~/.ssh/config` block from 3.3; without
it, use `-o IdentitiesOnly=yes -i ~/.ssh/<your-key> <admin>@<server-ip>`):

```
ssh lab 'mkdir -m 700 ~/certs-upload'
scp ~/lab-pki/issued/*.crt ~/lab-pki/issued/*.key ~/lab-pki/ca.crt lab:~/certs-upload/
```

Nine files: four certificates, four keys, the CA certificate.

### 5.2 Install the certificates (on the host)

```
sudo install -m 644 -o root -g root ~/certs-upload/*.crt /srv/proxy/certs/
sudo install -m 600 -o root -g root ~/certs-upload/*.key /srv/proxy/certs/
sudo chown 101000:101000 /srv/proxy/certs/*.key
cp ~/certs-upload/ca.crt ~/Test-Projekt/pki/ca.crt
rm -r ~/certs-upload
ls -ln /srv/proxy/certs/
```

The `cp` puts **your** CA into the host's clone: OpenProject mounts
`pki/ca.crt` for its outbound TLS calls
([`compose.yaml`](../services/openproject/compose.yaml)), and
`scripts/restore.sh` uses it too. `git status` on the host then shows
`M pki/ca.crt`, as on the workstation. Without this step OpenProject's calls
to `https://git.lab.test` fail with `certificate verify failed` (check in
5.13).

Expected: `ca.crt` and the four `.crt` as `-rw-r--r-- 0 0`, the four `.key`
as `-rw------- 101000 101000`. **Do not skip the `chown`:** Caddy runs as
container UID 1000, which is host UID 101000 under `userns-remap`
([ADR-0002](adr/0002-os-and-docker.md)); with mode 600 and owner root it
cannot read its keys and does not start.

### 5.3 Validate the proxy configuration

On the **workstation**, from the repository root (the paths are relative).
The Caddyfile imports the basic-auth file from `/config`, which only exists
on the host; an empty placeholder is enough for the syntax check:

```
cd ~/Test-Projekt
touch /tmp/ldap-ui.auth
podman run --rm -v ./proxy/Caddyfile:/etc/caddy/Caddyfile:ro,Z \
  -v ~/lab-pki/issued:/certs:ro,Z -v /tmp/ldap-ui.auth:/config/ldap-ui.auth:ro,Z \
  docker.io/library/caddy:2.11.4-alpine caddy validate --config /etc/caddy/Caddyfile
rm /tmp/ldap-ui.auth
```

Expected last line: `Valid configuration`. `docker` works the same way;
with Podman on an SELinux system, `:Z` relabels the mounted paths for the
container — including `~/lab-pki/issued`, which stays readable for you.

On the **host**:

```
cd ~/Test-Projekt
sudo docker compose -f proxy/compose.yaml config --quiet && echo OK
```

### 5.4 Basic-auth gate in front of the lldap UI (on the host)

`ldap.lab.test` asks for a separate password before lldap's own login
([ADR-0011](adr/0011-lldap-container.md)). Caddy refuses to start without
this file, so create it **before** the first start. Pick a username and a new
password (a different secret from the lldap admin password):

```
sudo docker run --rm -it caddy:2.11.4-alpine caddy hash-password   # password twice, prints a bcrypt hash
sudoedit /srv/proxy/config/ldap-ui.auth                            # one line: <username> <bcrypt-hash>
sudo chown 101000:101000 /srv/proxy/config/ldap-ui.auth
sudo chmod 640 /srv/proxy/config/ldap-ui.auth
sudo ls -ln /srv/proxy/config/                                     # -rw-r----- 101000 101000 ldap-ui.auth
```

The hash is printed to the terminal — do not paste it into tickets, chats or
logs; with a weak password a bcrypt hash can be cracked offline.

### 5.5 Start the proxy (on the host)

```
cd ~/Test-Projekt
sudo docker compose -f proxy/compose.yaml up -d
sudo docker logs caddy 2>&1 | tail
sudo docker ps
```

`2>&1`: Caddy logs to stderr; without it `tail` gets nothing and the full
log scrolls by.

Expected: `caddy` is `Up`, the log ends with `serving initial configuration`
and contains no `error` or `permission denied` (that would point to the key
owner from 5.2). Normal warnings: `Caddyfile input is not formatted`
(cosmetic), `admin endpoint disabled` (intended), `HTTP/2 skipped because it
requires TLS` and the same for HTTP/3 on port 80 (port 80 only redirects).

### 5.6 Check the proxy from the workstation

From the repository root (`pki/ca.crt` is a relative path):

```
cd ~/Test-Projekt
for h in git wiki pm ldap; do
  curl -sS --cacert pki/ca.crt "https://$h.lab.test/" \
    -o /dev/null -w "$h http=%{http_code} tls_verify=%{ssl_verify_result} ip=%{remote_ip}\n"
done
curl -sS -o /dev/null -w '%{http_code} -> %{redirect_url}\n' http://git.lab.test/
```

No `--resolve`: this goes through `/etc/hosts` like the browser, so `ip=`
must show `<server-ip>`. Expected now: `tls_verify=0` everywhere; `git`,
`wiki`, `pm` answer `502` (no backend yet), `ldap` answers `401` (the
basic-auth gate answers before the backend is asked); port 80 answers
`308 -> https://git.lab.test/`. These error responses carry only
`server: Caddy` and none of the security headers — known, see
[P-023](problems.md#p-023--the-lldap-gates-401-carries-none-of-the-proxys-security-headers).

In the browser, `https://git.lab.test` must show an error page from the
server (Firefox: "Looks like there's a problem with this site") — **not** a
certificate warning ("Potential Security Risk Ahead").

### 5.7 lldap — first start (on the host)

```
cd ~/Test-Projekt/services/lldap
install -m 600 /dev/null .env && printf 'LLDAP_JWT_SECRET=%s\nLLDAP_KEY_SEED=%s\nLLDAP_LDAP_USER_PASS=%s\n' \
  "$(openssl rand -base64 32)" "$(openssl rand -base64 32)" "$(openssl rand -base64 24)" > .env
cat .env      # copy LLDAP_KEY_SEED and LLDAP_LDAP_USER_PASS into the password manager now
sudo docker compose config --quiet && sudo docker compose up -d
sudo docker logs lldap
```

`.env` is created with mode 600 before anything is written into it; all three
values are random. `LLDAP_KEY_SEED` must never change afterwards;
`LLDAP_LDAP_USER_PASS` is the password of the lldap user `admin` — read only
on the very first start; if you change the password in the UI later, `.env`
no longer reflects it. Details:
[`services/lldap/README.md`](../services/lldap/README.md#first-start).

Normal on the first start: `WARNING: A key_seed was given, we will ignore the
key_file …` and four `WARN … Could not find … trying to create it` lines (the
built-in groups and the `admin` user are created). The log ends with
`starting service: "http" … 0.0.0.0:17170`. The container reports
`(health: starting)` for the first seconds, then `(healthy)`.

If the lldap UI shows `Invalid JWT` right away (no login page), the browser
still holds a session cookie from an earlier server under the same name.
Delete the site data for `ldap.lab.test` or use a private window.

### 5.8 lldap — directory set-up

Sign in at `https://ldap.lab.test`: first the basic-auth gate (5.4), then
lldap as `admin` with `LLDAP_LDAP_USER_PASS`. Generate the passwords on the
host:

```
for s in gitlab xwiki openproject; do echo "svc-$s $(openssl rand -base64 24)"; done
```

In the UI — **Groups → Create a group**, then **Users → Create a user**;
group membership is set on the user's page (**Add to group**):

| Kind | Name | Groups | Notes |
|---|---|---|---|
| group | `git_user`, `wiki_user`, `pm_user` | — | one access group per service |
| service account | `svc-gitlab`, `svc-xwiki`, `svc-openproject` | `lldap_strict_readonly` | e-mail `svc-<name>@lab.test`, password from the loop above |
| test user | `alice` | `git_user`, `wiki_user`, `pm_user` | e-mail `alice@lab.test`, **first and last name required** (OpenProject); password: user page → *Modify password* |
| test user | `bob` | `git_user` only | e-mail `bob@lab.test`, first and last name; password as for alice; negative test: no access to wiki and pm |

The service-account names must be exactly as above — every bind DN in the
services uses them (`uid=svc-xwiki,…` and so on).

Check that a service account can bind **and** see the directory — an account
without `lldap_strict_readonly` binds successfully but every search returns
nothing, which later shows up as "no users found" in the services:

```
sudo docker run --rm -it --network edge alpine sh -c 'apk add -q openldap-clients && \
  ldapsearch -x -H ldap://lldap:3890 -D uid=svc-gitlab,ou=people,dc=lab,dc=test -W \
  -b ou=groups,dc=lab,dc=test "(cn=git_user)" member'
```

`-W` prompts for the `svc-gitlab` password. Expected: `dn: cn=git_user,…`,
one `member:` line per test user, `result: 0 Success`. Container checks:
[`services/lldap/README.md`](../services/lldap/README.md#verification).

### 5.9 GitLab — first start (on the host)

GitLab calls itself through Caddy and must trust **your** CA, so the first
line copies the `ca.crt` from 5.2 into its trust directory:

```
sudo install -o 100000 -g 100000 -m 644 /srv/proxy/certs/ca.crt /srv/gitlab/config/trusted-certs/ca.crt
cd ~/Test-Projekt/services/gitlab
read -rsp 'svc-gitlab password: ' PW; echo
install -m 600 /dev/null .env && printf 'GITLAB_LDAP_BIND_PASSWORD=%s\n' "$PW" > .env; unset PW
sudo docker compose config --quiet
sudo docker compose up -d
```

`.env` holds one value: the `svc-gitlab` password from 5.8. Without it
`compose config` stops with `required variable GITLAB_LDAP_BIND_PASSWORD is
missing a value` — an empty value triggers the same error. `read -rsp`
reads the password without echo and keeps it out of the shell history.

The first start takes several minutes and the log is a flood of JSON lines
(Sidekiq cron jobs; `DEBUG … Cannot obtain an exclusive lease` is normal).
Instead of following it, check for the end of the configuration run and the
health status:

```
sudo docker logs gitlab 2>&1 | grep -m1 'gitlab Reconfigured'
sudo docker ps
```

Expected: `gitlab Reconfigured!`, then `gitlab … (healthy)`. Healthy can take
well over five minutes on the first start; repeat `docker ps` until it
appears. If you do follow the log with `docker logs -f`, leave it with
`Ctrl+C` — the container keeps running. After a later restart the old
`Reconfigured` line is still in the log; add `--since 10m` to `docker logs`.

Once GitLab is healthy, the self-call through Caddy proves the CA:

```
sudo docker exec gitlab curl -sS -o /dev/null -w '%{http_code}\n' https://git.lab.test/users/sign_in
```

Expected: `200`. `curl: (60) … unable to get local issuer certificate` and
`000` mean the wrong CA is in `trusted-certs/`. To replace it on a running
instance: the `install` line (first line of the block above), then
`sudo docker exec gitlab gitlab-ctl reconfigure`. Reconfigure prints a dozen
`warning: already initialized constant …` lines (harmless), and GitLab
answers `502` for a minute while it restarts its web processes.

### 5.10 GitLab — root account

Read the generated password (the file is deleted after 24 h):

```
sudo grep -v '^#' /srv/gitlab/config/initial_root_password | grep -v '^$'
```

At `https://git.lab.test` the sign-in page has two tabs: **LDAP** (directory
users, 5.8) and **Standard** (local accounts). `root` is a local account —
the way in when lldap is down — so sign in on **Standard**. Then avatar →
Edit profile → Password: GitLab refuses passwords under 8 characters and
common weak ones.

Do the next section in the same sitting: until then anyone who reaches the
server can register an account.

If the `root` password is lost (the initial file is gone after 24 h), set a
new one from the host — GitLab stores only a hash, so there is nothing to
read back:

```
sudo docker exec -it gitlab gitlab-rake "gitlab:password:reset[root]"
```

It prompts twice and answers `Password successfully updated for user with
username root.` Put the new password into the password manager right away.

### 5.11 GitLab — admin settings and 2FA

As `root`: Admin → Settings → General (`/admin/application_settings/general`).
Every section is a form of its own with its own **Save changes** — a change
in one section is lost silently if you press the button of another.

- *New user account restrictions*: untick **Allow new user accounts**, save.
- *Sign-in restrictions*: untick **Allow password authentication for Git
  over HTTP(S)**, tick **Enforce two-factor authentication for
  administrators** with grace period `0`, tick **Enable Admin Mode**, save.

GitLab then demands the 2FA set-up for `root` before anything else: scan the
QR code with a TOTP app and store the recovery codes in the password
manager. From now on the admin area asks again for password and TOTP code
(*Enter admin mode*). Reasons for each setting:
[`services/gitlab/README.md`](../services/gitlab/README.md#first-start).

Check from the workstation, in the repository root, that sign-up is closed:

```
cd ~/Test-Projekt
curl -s --cacert pki/ca.crt -o /dev/null -w '%{http_code}\n' https://git.lab.test/users/sign_up
```

Expected: `302` (redirect to the sign-in page). `000` means curl rejected the
certificate — `--cacert` missing or the wrong CA. `200` means the sign-up form
is still served: the setting can take a minute to apply — repeat once, then
check the section again.

### 5.12 GitLab — LDAP sign-in

In a private window, tab **LDAP**: `alice` and `bob` both get in (both are in
`git_user`). An account outside `git_user` — e.g. `svc-openproject` — must be
refused: that proves the group filter
([`compose.yaml`](../services/gitlab/compose.yaml), `user_filter`).

Clone and push over HTTPS (workstation). As `root`: create a private project
`clone-test` with a README; Edit profile → Personal access tokens → *Legacy
token*, scopes `read_repository` and `write_repository`, short expiry. Then:

```
git -c http.sslCAInfo=$HOME/Test-Projekt/pki/ca.crt clone https://git.lab.test/root/clone-test.git ~/clone-test
cd ~/clone-test
git config http.sslCAInfo $HOME/Test-Projekt/pki/ca.crt
echo "push-test $(date -I)" >> README.md && git commit -am "push test" && git push
```

Username `root`, password the token. Paste it with Ctrl+Shift+V — the input
is invisible, and Ctrl+V in a terminal pastes nothing, which ends in `HTTP
Basic: Access denied`. `$HOME` instead of `~`: the shell does not expand a
tilde after `=`. Expected at the end: `main -> main`. SSH on port 2222
(*not re-verified*):
[`services/gitlab/README.md`](../services/gitlab/README.md#workstation-access-to-git).

### 5.13 OpenProject (on the host)

```
cd ~/Test-Projekt/services/openproject
install -m 600 /dev/null .env && printf 'OPENPROJECT_DB_PASSWORD=%s\nOPENPROJECT_SECRET_KEY_BASE=%s\n' \
  "$(openssl rand -hex 24)" "$(openssl rand -hex 64)" > .env
sudo docker compose config --quiet && sudo docker compose up -d
sudo docker compose ps -a
```

`ps -a` also lists stopped containers — without `-a` the finished `seeder`
does not appear at all. Expected after a few minutes: `seeder` `Exited (0)`,
`db` and `web` `(healthy)`, `cache` and `worker` up. The first start pulls
the images first (about three minutes on the reference build).

At `https://pm.lab.test` sign in as `admin` / `admin`; OpenProject forces a
new password. The LDAP form is under Administration → Authentication →
**LDAP connections** → *New LDAP connection*
(`/admin/ldap_auth_sources/new`). Values:
[`services/openproject/README.md`](../services/openproject/README.md#after-the-first-sign-in-admin),
step 5. The bind password of `svc-openproject` goes into this form, not into
`.env`. **Check the port: `3890`**, not the LDAP default `389` — with the
wrong port OpenProject logs every attempt only as `Failed login … invalid
credentials`, not as a connection error. To read back what was saved
(without the password):

```
sudo docker exec openproject-db psql -U openproject -d openproject -x \
  -c "select host, port, account, base_dn, filter_string, onthefly_register, attr_login from ldap_auth_sources;"
```

Expected: `host | lldap`, `port | 3890`, `onthefly_register | t` (automatic
user creation on), the other values as in the README.

Then, in a private window: `alice` gets in (user created automatically),
`bob` is refused (not in `pm_user`).

OpenProject trusts your CA for its outbound calls (needed for the
integrations) — expected `200`:

```
sudo docker exec openproject ruby -rnet/http -e 'puts Net::HTTP.get_response(URI("https://git.lab.test/users/sign_in")).code'
```

`certificate verify failed` means `pki/ca.crt` on the host is not your CA
(5.2); after fixing it, `sudo docker compose restart web worker`.

### 5.14 XWiki — first start (on the host)

The JVM must trust **your** CA, as GitLab in 5.9: the command mounts
`/srv/proxy/certs/ca.crt` from 5.2 (after 5.2 the clone's `pki/ca.crt` is the
same file).

```
cd ~/Test-Projekt/services/xwiki
install -m 600 /dev/null .env && printf 'XWIKI_DB_PASSWORD=%s\n' "$(openssl rand -hex 24)" > .env
sudo docker run --rm -v /srv/proxy/certs/ca.crt:/ca.crt:ro --entrypoint sh xwiki:17.10.13-postgres-tomcat \
  -c 'keytool -importcert -noprompt -cacerts -storepass changeit -alias lab-test-root-ca -file /ca.crt >&2 && cat "$JAVA_HOME/lib/security/cacerts"' \
  | sudo tee /srv/xwiki/cacerts > /dev/null && sudo chmod 644 /srv/xwiki/cacerts && ls -l /srv/xwiki/cacerts
sudo docker compose config --quiet && sudo docker compose up -d
```

Expected: `Certificate was added to keystore`, then `/srv/xwiki/cacerts`
owned by root, mode 644; `xwiki-db` healthy, `xwiki` started. Line by line:
[`services/xwiki/README.md`](../services/xwiki/README.md#first-start).
At `https://wiki.lab.test` the wizard creates the `admin` account and
installs the *XWiki Standard Flavor* (several minutes). Run it right after
the start: until the wizard has run, anyone who reaches `wiki.lab.test` can
create that admin account. Registration and anonymous reading stay open
until the hardening step
([`services/xwiki/README.md`](../services/xwiki/README.md#after-the-wizard-admin)
step 1; OpenProject: its README, step 2).

### 5.15 XWiki — LDAP

Three parts, as in
[`services/xwiki/README.md`](../services/xwiki/README.md#after-the-wizard-admin)
step 2 — but **fill the form before activating the authenticator**. Once the
`xwiki.cfg` line is active, every sign-in goes through LDAP first; with an
empty form (or no form at all) even `admin` is locked out.

1. **Extensions** (Administration → Extensions): `LDAP Authenticator`
   (`org.xwiki.contrib.ldap:ldap-authenticator`) and, via *Advanced search*
   by id, `org.xwiki.contrib.ldap:ldap-ui` — both in version **9.16.6** (the
   tested pair). Check under *Installed extensions* that both are listed.
2. **Form** (`/bin/admin/XWiki/XWikiPreferences?section=LDAP`). The page
   says "LDAP authentication is not enabled" — expected at this point; the
   form below it must be visible, otherwise `ldap-ui` is missing. The form's
   field names differ from the README's wording:

   | Field | Value |
   |---|---|
   | Ldap | Yes |
   | Ldap server address / port | `lldap` / `3890` |
   | Ldap login matching | `uid=svc-xwiki,ou=people,dc=lab,dc=test` — must match the account name in lldap exactly |
   | Ldap password matching | the `svc-xwiki` password |
   | Restrict to group | `cn=wiki_user,ou=groups,dc=lab,dc=test` |
   | Ldap base DN | `ou=people,dc=lab,dc=test` |
   | Ldap UID attribute name | `uid` (the default `cn` does not match lldap logins) |
   | Try local login | **Yes** — keeps `admin` working |
   | Update user from LDAP after login | Yes |
   | Ldap user fields mapping | three entries: `first_name` → `givenName`, `last_name` → `sn`, `email` → `mail` |

   Leave the rest empty or at its default. Save, reload, check the values.
3. **Activate** (on the host, in `~/Test-Projekt/services/xwiki`):

   ```
   sudo docker cp xwiki:/usr/local/tomcat/webapps/ROOT/WEB-INF/xwiki.cfg /srv/xwiki/data/data/xwiki.cfg
   echo 'xwiki.authentication.authclass=org.xwiki.contrib.ldap.XWikiLDAPAuthServiceImpl' | sudo tee -a /srv/xwiki/data/data/xwiki.cfg
   sudo chown 100000:100000 /srv/xwiki/data/data/xwiki.cfg && sudo chmod 640 /srv/xwiki/data/data/xwiki.cfg
   sudo docker compose restart xwiki
   ```

Test in a private window: `alice` gets in, `bob` is refused, `admin` still
works. Right after the sign-in alice may see "You are not allowed to view
this page" — XWiki returns to the page the login started from; if that was an
admin page, the message is correct. `/bin/view/Main/` must show her as signed
in.

If something fails:

| Log line (`sudo docker logs xwiki`) | Meaning |
|---|---|
| `ClassNotFoundException: org.xwiki.contrib.ldap.XWikiLDAPAuthServiceImpl` | `xwiki.cfg` points to the authenticator, but the extension is not installed — back to part 1 |
| only `Authentication failure with login [alice]` | the LDAP module logs details at DEBUG only — switch it on (below) |
| `Binding … login=[uid=svc-…]` then `LDAPException: Invalid Credentials` | bind DN or password in the form does not match lldap — test the account at `https://ldap.lab.test` |

DEBUG for the LDAP module, without needing a working admin sign-in (lasts
until the container is recreated):

```
cd ~/Test-Projekt/services/xwiki
sudo docker exec xwiki sed -i 's|</configuration>|<logger name="org.xwiki.contrib.ldap" level="debug"/></configuration>|' /usr/local/tomcat/webapps/ROOT/WEB-INF/classes/logback.xml
sudo docker compose restart xwiki
```

Way back if everyone is locked out: remove the line and restart — the form
values are kept.

```
cd ~/Test-Projekt/services/xwiki
sudo sed -i '/^xwiki.authentication.authclass=org.xwiki.contrib.ldap/d' /srv/xwiki/data/data/xwiki.cfg
sudo docker compose restart xwiki
```

## 6–8. Not yet written

At this point all services run and accept LDAP sign-in with group filtering.
Still to be added to this guide (until then, see the linked READMEs):

- Hardening of OpenProject (self-registration, host name, public projects,
  wiki module — [`services/openproject/README.md`](../services/openproject/README.md#after-the-first-sign-in-admin)
  steps 2–4) and XWiki (registration and anonymous reading —
  [`services/xwiki/README.md`](../services/xwiki/README.md#after-the-wizard-admin) step 1).
- Integrations GitLab ↔ OpenProject ([`docs/integration.md`](integration.md)).
- Acceptance checks across all services, the verification blocks of each
  README (including GitLab's self-call through Caddy and SSH on 2222), and a
  first backup and restore test ([`docs/backup-restore.md`](backup-restore.md)).

## 9. Access from another workstation

Everything above ran on one workstation: it holds the CA key and the SSH key
the provider installed. A second machine (a laptop, a colleague's PC) needs
three things — and none of them is a copy of a private key.

1. **SSH access.** Create a key pair on the new machine
   (`ssh-keygen -t ed25519`) and append its **public** key (`~/.ssh/id_ed25519.pub`)
   to `/home/<admin>/.ssh/authorized_keys` on the host, from a machine that
   already has access. Selecting a key in the provider's console does not
   help here: the provider writes it only once, when a server is created.
   After `bootstrap.sh`, root cannot log in, so the admin account is the only
   way in.
2. **Trust the CA** — import `pki/ca.crt` of **your** build (not the one in a
   fresh clone from GitHub) as in 2.5, and compare the fingerprint.
3. **Name resolution** — the `/etc/hosts` line from 2.6.

The CA key (`~/lab-pki/ca.key`) stays on the first workstation; issue and
renew certificates only there.

If no key works any more, the provider's rescue system or root-password
reset in the web console is the way back in.
