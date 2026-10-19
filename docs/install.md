# Installation — from an empty workstation and an empty server to a working system

One linear path, top to bottom. On 2026-10-19 the whole guide (sections 1 to
5.16) was followed literally on a fresh Debian 13 server and a workstation
without any prior state; the few steps not exercised in that run are marked
*not re-verified*.

This is the only installation path. The READMEs next to each stack are the
reference — what each part is, why it is configured that way, how to verify
and operate it — and link back here for the steps.

## How to read this guide

- **In order.** Each section needs the ones before it — section 3 needs the
  server from section 1.
- **Where a command runs.** Every code block starts with a comment line,
  `# workstation` or `# host`. Check your prompt before you run the block —
  the commands of both machines look alike, and several of them fail
  silently or do harm on the wrong one (a backup key created on the server it
  protects).
- **Placeholders** are written in angle brackets; replace them *including*
  the brackets. Typed literally, the shell reads `<` as an input redirection
  (`<stamp>` ends in `stamp: No such file or directory`).

  | Placeholder | Meaning |
  |---|---|
  | `<server-ip>` | public IPv4 of the host (section 1) |
  | `<your-key>` | file name of your SSH **private** key in `~/.ssh/` (the `.pub` file is its public half) |
  | `<admin>` | the admin account you create on the host (3.2) |
  | `<your-age-public-key>` | the `age1…` string from 4.1 |
  | `<username>` | a name you pick for the basic-auth gate (5.4) |
  | `<stamp>` | the time stamp of a backup set, e.g. `20261019T162135Z` (5.16) |

- **Copying commands.** Read the guide on GitHub or with `less`. Terminal
  Markdown viewers such as `glow` wrap long lines by default; a pasted line
  break splits one command into two (`glow -w 0` turns wrapping off).
- **Expected output** follows each block. Compare before you move on.

## 1. Server and provider firewall

Outside the repository, at your cloud provider (the reference build used a
Hetzner Cloud CPX42, see [ADR-0001](adr/0001-hosting.md)). If you have no SSH
key pair for this server yet, create one first:

```
# workstation
ssh-keygen -t ed25519 -f ~/.ssh/<your-key>
cat ~/.ssh/<your-key>.pub
```

`ssh-keygen` writes two files: `~/.ssh/<your-key>` (private — it never leaves
the workstation) and `~/.ssh/<your-key>.pub` (public). `cat` prints the
public key as one line, `ssh-ed25519 AAAA… user@host`; that line is what the
provider gets.

| Setting | Value | Why |
|---|---|---|
| Image | Debian 13 (trixie), amd64 | `bootstrap.sh` targets Debian 13 only |
| Size | 8 vCPU / 16 GB RAM | GitLab and OpenProject together need the memory |
| SSH key | paste the `.pub` line, then **select** the key for this server | the first login as root uses it; a key that is stored but not selected is not installed, and the provider mails a root password instead |
| Firewall | inbound TCP 22, 80, 443, 2222 only, attached to the server | everything else stays closed; 2222 is GitLab's SSH |

Note the server's public IPv4 — it is `<server-ip>` below.

## 2. Workstation

### 2.1 Prerequisites

`openssl`, `ssh`, `git`, `curl`, `age` (backup key, section 4) and a
container runtime for the syntax check in 5.3 — `docker` (the host runs
Docker too) or `podman`, the commands are the same. Check that they are
installed:

```
# workstation
openssl version
ssh -V
git --version
curl --version
age --version
docker --version          # or: podman --version
```

Install whatever is missing:

| System | Command |
|---|---|
| Debian, Ubuntu | `sudo apt install openssl openssh-client git curl age docker.io` |
| Fedora | `sudo dnf install openssl openssh-clients git curl age podman` |
| Fedora Atomic (Silverblue, Bazzite, …) | everything except `age` is in the image: `brew install age` (or `rpm-ostree install age` and reboot) |

Git needs an identity for the push test in 5.12 — name and e-mail written
into each commit, not an account or a password. Check it:

```
# workstation
git config --global user.name
git config --global user.email
```

If either prints nothing, set it once:

```
# workstation
git config --global user.name "<your name>"
git config --global user.email "<your e-mail>"
```

### 2.2 Clone the repository

```
# workstation
git clone https://github.com/NicolasPogorzelski/Test-Projekt.git ~/Test-Projekt
git -C ~/Test-Projekt log --oneline -1
```

The paths below assume this location. Run the `pki/` scripts from the
repository root (`cd ~/Test-Projekt`).

### 2.3 Create your own root CA

```
# workstation
cd ~/Test-Projekt
./pki/make-ca.sh
```

The script asks three times for a passphrase: twice to set it on the new CA
key, once more to sign the CA certificate with it. Choose it beforehand and
store it in a password manager — every certificate issued later needs it,
and anyone holding `ca.key` plus the passphrase can issue certificates your
browser trusts. OpenSSL wants at least four characters; a shorter one stops
the script with `You must type in 4 to 1024 characters` before anything is
written, and you simply run it again. The private material goes to
`~/lab-pki/` (override with `PKI_DIR=<dir>`); the script refuses to run if a
CA key already exists there. Details of each `openssl` call:
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
# workstation
./pki/issue-cert.sh git.lab.test
./pki/issue-cert.sh wiki.lab.test
./pki/issue-cert.sh pm.lab.test
./pki/issue-cert.sh ldap.lab.test
```

Expected for each: `…/issued/<host>.crt: OK`, a validity of one year and
`DNS:<host>` as Subject Alternative Name. Result in `~/lab-pki/issued/`: four
`.crt` (mode 644) and four `.key` (mode 600, not encrypted — Caddy reads them
at start-up). Details: [`pki/README.md`](../pki/README.md#issue-certsh-hostname--issue-a-service-certificate).

If a call stops with `bad decrypt` (wrong passphrase), it removes what it
had created; run it again.

### 2.5 Trust the CA in your browser

Import **your** `pki/ca.crt` (the one `make-ca.sh` just wrote) as an authority
that identifies websites:

- Firefox and Firefox-based browsers: Settings → search for "cert" →
  View/Manage Certificates → Authorities → Import → tick "Trust this CA to
  identify websites".
- Chrome and Chromium-based browsers (Brave, Edge): Settings → Privacy and
  security → Security → Manage certificates, then import it as a trusted
  authority (the tab is *Authorities* in older versions; the menu names have
  changed between versions — *not re-verified*).

Browsers installed as Flatpak ignore the system trust store, so import in the
browser even if you also add the CA system-wide
([P-001](problems.md#p-001--flatpak-browsers-do-not-use-the-system-ca-trust-store)).

Then open the imported entry ("lab.test Root CA") and compare its SHA-256
fingerprint with the one `make-ca.sh` printed in 2.3. If you imported a CA of
an earlier build before, several entries carry the same name — the
fingerprint tells them apart. The check that the browser really uses it
follows in 5.6.

### 2.6 Name resolution

The `*.lab.test` names exist in no public DNS. `/etc/hosts` on the
workstation needs **exactly one** line for them:

```
<server-ip>  git.lab.test wiki.lab.test pm.lab.test ldap.lab.test
```

Edit the file as root with `sudoedit /etc/hosts` (it opens the editor from
`$EDITOR`, often nano: save with Ctrl+O and Enter, leave with Ctrl+X). If a
line for these names is already there from an earlier build, change its
address or put a `#` in front of it — an old line further up wins, because
the first match counts.

```
# workstation
getent hosts git.lab.test
```

Expected: **one** line, starting with `<server-ip>`. Two lines mean an old
entry is still active.

Update this line whenever the host is rebuilt with a new address. Checks that
use `curl --resolve` bypass `/etc/hosts` and stay green while the browser
still goes to the old address.

## 3. Host preparation

### 3.1 First login as root

The provider placed your public key in `/root/.ssh/authorized_keys` when the
server was created. Compare the address with the provider's console before
you press Enter — a typo connects you to somebody else's machine:

```
# workstation
ssh -o IdentitiesOnly=yes -i ~/.ssh/<your-key> root@<server-ip>
```

On the first connection SSH shows the server's host-key fingerprint and asks
whether to continue. Before answering `yes`, open the provider's web console
of this server and run

```
# host, in the provider's web console
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

The `SHA256:…` value must be the one SSH shows. Expected after `yes`: a root
prompt **without** a password question. A password question means a wrong
address or a key that was not selected in section 1 — leave with Ctrl+C and
never type a password there. If you accepted the key of a wrong address,
remove it again: `ssh-keygen -R <that address>`.

### 3.2 Create the admin account (on the host, as root)

Lower-case username ([P-003](problems.md#p-003--deluser---remove-home-fails-on-the-minimal-debian-image)):

```
# host, as root
adduser --gecos "" <admin>                 # the password you set here is the sudo password
usermod -aG sudo <admin>
install -d -m 700 -o <admin> -g <admin> /home/<admin>/.ssh
install -m 600 -o <admin> -g <admin> /root/.ssh/authorized_keys /home/<admin>/.ssh/authorized_keys
exit
```

`adduser` ends with `usermod: no changes` — harmless, it comes from adduser's
own internal call. The account can now log in with the same key as root.

### 3.3 Log in as the admin, check sudo, create the `lab` alias

`bootstrap.sh` disables root and password logins. Before running it, make sure
the admin account works — including sudo:

```
# workstation
ssh -o IdentitiesOnly=yes -i ~/.ssh/<your-key> <admin>@<server-ip>
```

```
# host
sudo -v                                     # asks for the password from 3.2; no output = OK
exit
```

`IdentitiesOnly=yes` makes SSH offer only this key. After `bootstrap.sh` the
server allows three attempts per connection (`MaxAuthTries 3`); an SSH agent
holding several keys can use them up before the right one is tried and the
login ends with "Too many authentication failures".

**Create the alias now** — the rest of the guide uses `lab`. Append this block
to `~/.ssh/config` on the workstation, with your values:

```
Host lab
    HostName <server-ip>
    User <admin>
    IdentityFile ~/.ssh/<your-key>
    IdentitiesOnly yes
```

`IdentityFile` is the **private** key (the file without `.pub`). Check:

```
# workstation
ssh lab true && echo ok
```

Expected: `ok`, no password question.

### 3.4 Install git and clone the repository

The cloud image ships without git ([P-015](problems.md#p-015--the-debian-13-cloud-image-has-no-git-but-the-reinstall-path-starts-with-git-clone)).
Log in with `ssh lab`, then:

```
# host
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/NicolasPogorzelski/Test-Projekt.git ~/Test-Projekt
```

The repository is public, so HTTPS needs no credentials. For a private fork,
use a read-only deploy key instead ([`security.md`](security.md)).

## 4. Prepare the host: `bootstrap.sh`

On the host, as the admin (not as root — the script reads `SUDO_USER` and
allows only that account in `AllowUsers`):

```
# host
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

The script has just rewritten the SSH configuration. **Keep this session
open** — if the admin can no longer log in, it is the only way left to repair
that — and check from a **second** terminal on the workstation:

```
# workstation
ssh lab true && echo "admin ok"
ssh -o IdentitiesOnly=yes -i ~/.ssh/<your-key> root@<server-ip> true      # Permission denied (publickey)
```

Then log out and in again so the `backup` group takes effect.

### 4.1 Your own backup key

`bootstrap.sh` already enabled the nightly `backup.timer`. `backup.sh`
encrypts every set to the public keys in `scripts/backup-recipients.txt` —
in a fresh clone that is the key of the reference build, so you could not
decrypt your own backups. Replace it before the first night.

The private half stays on the **workstation** — on the host it would sit next
to the backups it is meant to protect:

```
# workstation
age-keygen -o ~/lab-pki/backup-identity.txt      # prints "Public key: age1…"
chmod 600 ~/lab-pki/backup-identity.txt
```

The identity file is the only way to decrypt a backup — keep a copy in the
password manager. Then replace the recipient with your public key:

```
# host
echo '<your-age-public-key>' > ~/Test-Projekt/scripts/backup-recipients.txt
cat ~/Test-Projekt/scripts/backup-recipients.txt
```

Expected: one line, your `age1…` key. `>` replaces the file (`>>` would keep
the reference key as a second recipient). A placeholder left in the file
makes every backup fail at the last step with `malformed recipient at line 1`.

This edit — like the CA copy in 5.2 — exists only in the host's clone. A
reinstall from a fresh clone brings back the reference build's key and CA
without warning: keep your public key and CA with your other secrets and
re-apply both files after every `git clone` (or commit them to your own
fork).

Until every stack has its `.env` (5.14), the nightly run stops with `missing
…/.env` — expected. The key is tested in 5.16, once all stacks run.

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

```
# workstation
ssh lab 'mkdir -m 700 ~/certs-upload'
scp ~/lab-pki/issued/*.crt ~/lab-pki/issued/*.key ~/lab-pki/ca.crt lab:~/certs-upload/
```

Nine files: four certificates, four keys, the CA certificate.

### 5.2 Install the certificates (on the host)

```
# host
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

Two checks before the first start; neither changes or starts anything. They
catch a broken configuration while you still know what you just changed,
instead of a proxy that keeps restarting.

On the **workstation**, from the repository root (the paths are relative).
The Caddyfile imports the basic-auth file `/config/ldap-ui.auth`, which only
exists on the host (5.4); an empty placeholder is enough for the syntax check:

```
# workstation
cd ~/Test-Projekt
touch /tmp/ldap-ui.auth
docker run --rm \
  -v "$PWD/proxy/Caddyfile:/etc/caddy/Caddyfile:ro,Z" \
  -v ~/lab-pki/issued:/certs:ro,Z \
  -v /tmp/ldap-ui.auth:/config/ldap-ui.auth:ro,Z \
  docker.io/library/caddy:2.11.4-alpine \
  caddy validate --config /etc/caddy/Caddyfile
rm /tmp/ldap-ui.auth
```

Prefix `sudo` if your user is not in the `docker` group; with Podman, write
`podman` instead of `docker`. `:Z` relabels the mounted paths for SELinux
(Fedora and relatives; ignored elsewhere) — `~/lab-pki/issued` stays readable
for you.

Expected last line: `Valid configuration`. Two warnings on the way are
normal: `Import file is empty` (the placeholder) and `Caddyfile input is not
formatted` (cosmetic).

On the **host**:

```
# host
cd ~/Test-Projekt
sudo docker compose -f proxy/compose.yaml config --quiet && echo OK
```

Expected: `OK`.

### 5.4 Basic-auth gate in front of the lldap UI (on the host)

`ldap.lab.test` asks for a separate password before lldap's own login
([ADR-0011](adr/0011-lldap-container.md)). Caddy refuses to start without
this file, so create it **before** the first start. Pick a username and a new
password (a different secret from the lldap admin password):

```
# host
sudo docker run --rm -it caddy:2.11.4-alpine caddy hash-password   # password twice, prints a bcrypt hash
sudoedit /srv/proxy/config/ldap-ui.auth                            # one line: <username> <bcrypt-hash>
sudo chown 101000:101000 /srv/proxy/config/ldap-ui.auth
sudo chmod 640 /srv/proxy/config/ldap-ui.auth
sudo ls -ln /srv/proxy/config/                                     # -rw-r----- 101000 101000 ldap-ui.auth
```

In `sudoedit` (nano): paste the line, save with Ctrl+O and Enter, leave with
Ctrl+X — leaving without saving ends in `ldap-ui.auth unchanged`.

At the gate you later sign in with `<username>` and the **password you typed**
into `hash-password` — the hash only goes into the file. Caddy hashes what you
type and compares; the hash itself, typed as a password, never matches. That
is the point of storing a hash: whoever reads the file still cannot sign in.

The hash is printed to the terminal — do not paste it into tickets, chats or
logs; with a weak password a bcrypt hash can be cracked offline.

Password forgotten: hash a new one, replace the line with `sudoedit`, then
restart Caddy — it reads the file only at start-up, and its admin endpoint
is disabled, so there is no reload:

```
# host
cd ~/Test-Projekt && sudo docker compose -f proxy/compose.yaml restart
```

### 5.5 Start the proxy (on the host)

```
# host
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
# workstation
cd ~/Test-Projekt
for h in git wiki pm ldap; do
  curl -sS --cacert pki/ca.crt "https://$h.lab.test/" -o /dev/null \
    -w "$h http=%{http_code} tls_verify=%{ssl_verify_result} ip=%{remote_ip}\n"
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

In the browser, `https://git.lab.test` must show an error page **from the
server** — Firefox: "Looks like there's a problem with this site"; Chrome,
Brave: "This page isn't working … HTTP ERROR 502". A **certificate warning**
("Potential Security Risk Ahead", "Your connection is not private") means the
browser does not trust your CA yet — back to 2.5.

### 5.7 lldap — first start (on the host)

```
# host
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
[`services/lldap/README.md`](../services/lldap/README.md#the-three-secrets-in-env).

Normal on the first start: `WARNING: A key_seed was given, we will ignore the
key_file …` and four `WARN … Could not find … trying to create it` lines (the
built-in groups and the `admin` user are created). The log ends with
`starting service: "http" … 0.0.0.0:17170`. The container reports
`(health: starting)` for the first seconds, then `(healthy)`.

If the lldap UI shows `Invalid JWT` right away (no login page), the browser
still holds a session cookie from an earlier server under the same name.
Delete the site data for `ldap.lab.test` or use a private window.

### 5.8 lldap — directory set-up

1. **Generate the service-account passwords** — the loop only prints them,
   nothing is stored; put each into the password manager:

   ```
   # host
   for s in gitlab xwiki openproject; do echo "svc-$s $(openssl rand -base64 24)"; done
   ```

2. **Create groups and users.** Sign in at `https://ldap.lab.test`: first the
   basic-auth gate (5.4), then lldap as `admin` with `LLDAP_LDAP_USER_PASS`.
   **Groups → Create a group**, then **Users → Create a user**; group
   membership is set on the user's page (**Add to group**):

   | Kind | Name | Groups | Notes |
   |---|---|---|---|
   | group | `git_user`, `wiki_user`, `pm_user` | — | one access group per service |
   | service account | `svc-gitlab`, `svc-xwiki`, `svc-openproject` | `lldap_strict_readonly` | e-mail `svc-<name>@lab.test`; set the password **generated in step 1** |
   | test user | `alice` | `git_user`, `wiki_user`, `pm_user` | e-mail `alice@lab.test`, **first and last name required** (OpenProject); password: user page → *Modify password* |
   | test user | `bob` | `git_user` only | e-mail `bob@lab.test`, first and last name; password as for alice; negative test: no access to wiki and pm |

   The service-account names must be exactly as above — every bind DN in the
   services uses them (`uid=svc-xwiki,…` and so on).

3. **Check that a service account can bind and see the directory** — do not
   skip this: an account without `lldap_strict_readonly` binds successfully
   but every search returns nothing, which later shows up as "no users found"
   in the services:

   ```
   # host
   sudo docker run --rm -it --network edge alpine sh -c 'apk add -q openldap-clients && \
     ldapsearch -x -H ldap://lldap:3890 -D uid=svc-gitlab,ou=people,dc=lab,dc=test -W \
     -b ou=groups,dc=lab,dc=test "(cn=git_user)" member'
   ```

   `-W` prompts for the `svc-gitlab` password. Expected: `dn: cn=git_user,…`,
   one `member:` line per test user (alice and bob), `result: 0 Success`.
   Container checks:
   [`services/lldap/README.md`](../services/lldap/README.md#verification).

### 5.9 GitLab — first start (on the host)

GitLab calls itself through Caddy and must trust **your** CA, so the first
line copies the `ca.crt` from 5.2 into its trust directory:

```
# host
sudo install -o 100000 -g 100000 -m 644 /srv/proxy/certs/ca.crt /srv/gitlab/config/trusted-certs/ca.crt
cd ~/Test-Projekt/services/gitlab
read -rsp 'svc-gitlab password: ' PW; echo
install -m 600 /dev/null .env && printf 'GITLAB_LDAP_BIND_PASSWORD=%s\n' "$PW" > .env; unset PW
sudo docker compose config --quiet
sudo docker compose up -d
```

`.env` holds one value: the `svc-gitlab` password from 5.8 — the same one you
set in the lldap UI, because GitLab binds with it. Without it `compose
config` stops with `required variable GITLAB_LDAP_BIND_PASSWORD is missing a
value` — an empty value triggers the same error. `read -rsp` reads the
password without echo and keeps it out of the shell history.

The image pull takes a few minutes (about 3.5 on the reference build), the
first start several more, and the log is a flood of JSON lines (Sidekiq cron
jobs; `DEBUG … Cannot obtain an exclusive lease` is normal). Instead of
following it, check for the end of the configuration run and the health
status:

```
# host
sudo docker logs gitlab 2>&1 | grep -m1 'gitlab Reconfigured'
sudo docker ps
```

Expected: `gitlab Reconfigured!`, then `gitlab … (healthy)`. Healthy can take
several minutes on the first start; repeat `docker ps` until it appears. If
you do follow the log with `docker logs -f`, leave it with `Ctrl+C` — the
container keeps running. After a later restart the old `Reconfigured` line is
still in the log; add `--since 10m` to `docker logs`.

Once GitLab is healthy, the self-call through Caddy proves the CA:

```
# host
sudo docker exec gitlab curl -sS -o /dev/null -w '%{http_code}\n' https://git.lab.test/users/sign_in
```

Expected: `200`. `curl: (60) … unable to get local issuer certificate` and
`000` mean the wrong CA is in `trusted-certs/`. To replace it on a running
instance: the `install` line (first line of the block above), then
`sudo docker exec gitlab gitlab-ctl reconfigure`. Reconfigure prints a dozen
`warning: already initialized constant …` lines (harmless), and GitLab
answers `502` for a minute while it restarts its web processes.

### 5.10 GitLab — root account

Have a TOTP app ready (5.11 needs it). Read the generated password (the file
is deleted after 24 h):

```
# host
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
# host
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
[`services/gitlab/README.md`](../services/gitlab/README.md#why-the-first-start-settings).

Check from the workstation, in the repository root, that sign-up is closed:

```
# workstation
cd ~/Test-Projekt
curl -s --cacert pki/ca.crt -o /dev/null -w '%{http_code}\n' https://git.lab.test/users/sign_up
```

Expected: `302` (redirect to the sign-in page). `200` means the sign-up form
is still served: the setting can take a minute to apply — repeat once, then
check the section again. `000` means curl got no answer it accepted:
`--cacert` missing or the wrong CA, a name that does not resolve (2.6), or a
broken URL — a space inside it makes two URLs, and curl prints `000` twice.

### 5.12 GitLab — LDAP sign-in, clone and push

In a private window, tab **LDAP**: `alice` and `bob` both get in (both are in
`git_user`). An account outside `git_user` — e.g. `svc-openproject` — must be
refused: that proves the group filter
([`compose.yaml`](../services/gitlab/compose.yaml), `user_filter`).

A clone and a push over HTTPS prove the write path end to end: Git on the
workstation trusts your CA, a token authenticates (password authentication
for Git is off since 5.11), and GitLab accepts the change. As `root`: create
a private project `clone-test` with a README; Edit profile → Personal access
tokens → *Legacy token*, scopes `read_repository` and `write_repository`,
short expiry. GitLab shows the token only once. Then:

```
# workstation
git -c http.sslCAInfo=$HOME/Test-Projekt/pki/ca.crt clone https://git.lab.test/root/clone-test.git ~/clone-test
cd ~/clone-test
git config http.sslCAInfo $HOME/Test-Projekt/pki/ca.crt
echo "push-test $(date -I)" >> README.md && git commit -am "push test" && git push
```

Username `root`, password the token. Paste it with Ctrl+Shift+V — the input
is invisible, and Ctrl+V in a terminal pastes nothing, which ends in `HTTP
Basic: Access denied`. Expected at the end: `main -> main`.

`http.sslCAInfo` tells Git which CA to trust — it answers "is this really
git.lab.test?", not "who are you?" (that is the token). It **replaces** Git's
list of trusted CAs, so it is set for this repository only (`.git/config`);
set with `--global`, every clone from a public host such as GitHub would fail
the certificate check. `$HOME` instead of `~`: the shell does not expand a
tilde after `=`. SSH on port 2222 (*not re-verified*):
[`services/gitlab/README.md`](../services/gitlab/README.md#workstation-access-to-git).

### 5.13 OpenProject (on the host)

```
# host
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
new password. Then, as `admin`, in this order (OpenProject 16.6 menu names):

1. **Close self-registration:** Administration → Authentication → **Login and
   registration** → *Self-registration*: **Disabled**, save.
2. **Host name:** Administration → System settings → General shows *Host name*
   `pm.lab.test`. HTTPS and the host name come from `compose.yaml`
   (`OPENPROJECT_HTTPS`, `OPENPROJECT_HOST__NAME`), so the field may be
   greyed out, and there is no *Protocol* field.
3. **Project defaults:** Administration → Projects → New project: untick
   *New projects are public by default*; *Default enabled modules*: **Wiki
   off**, **GitLab on** ([ADR-0003](adr/0003-project-management-tool.md),
   [`integration.md`](integration.md)), save. The defaults apply only to
   projects created later: open each of the two demo projects the seeder
   created → Project settings → Modules → untick *Wiki*, save
   ([P-022](problems.md#p-022--the-second-seeded-openproject-project-kept-the-wiki-module)).
   Check:

   ```
   # host
   sudo docker exec openproject-db psql -U openproject -d openproject \
     -c "select p.identifier, em.name from enabled_modules em join projects p on p.id=em.project_id where em.name='wiki';"
   ```

   Expected: `(0 rows)`.
4. **LDAP:** Administration → Authentication → **LDAP connections** → *New
   LDAP connection* (`/admin/ldap_auth_sources/new`):

   | Field | Value |
   |---|---|
   | Name | `lldap` |
   | Host / Port | `lldap` / **`3890`** — not the LDAP default `389` |
   | Connection encryption | none (internal Docker network, [ADR-0006](adr/0006-identity.md)) |
   | Account | `uid=svc-openproject,ou=people,dc=lab,dc=test` |
   | Password | the `svc-openproject` password from 5.8 (it goes into this form, not into `.env`) |
   | Base DN | `ou=people,dc=lab,dc=test` |
   | Filter | `(memberof=cn=pm_user,ou=groups,dc=lab,dc=test)` |
   | Attributes: login / first name / last name / e-mail | `uid` / `givenName` / `sn` / `mail` |
   | Automatic user creation | on |

   With the wrong port OpenProject logs every attempt only as `Failed login …
   invalid credentials`, not as a connection error. Read back what was saved
   (without the password):

   ```
   # host
   sudo docker exec openproject-db psql -U openproject -d openproject -x \
     -c "select host, port, account, base_dn, filter_string, onthefly_register, attr_login from ldap_auth_sources;"
   ```

   Expected: `host | lldap`, `port | 3890`, `onthefly_register | t` (automatic
   user creation on), the other values as in the table.

Then, in a private window: `alice` gets in (user created automatically),
`bob` is refused (not in `pm_user`).

OpenProject trusts your CA for its outbound calls (needed for the
integrations) — expected `200`:

```
# host
sudo docker exec openproject ruby -rnet/http -e 'puts Net::HTTP.get_response(URI("https://git.lab.test/users/sign_in")).code'
```

`certificate verify failed` means `pki/ca.crt` on the host is not your CA
(5.2); after fixing it, `sudo docker compose restart web worker`.

### 5.14 XWiki — first start and hardening (on the host)

The JVM keeps its own list of trusted CAs (`cacerts`) and ignores the
system's, so it must learn **your** CA, as GitLab in 5.9. A throw-away
container adds the CA from 5.2 to the image's `cacerts` and writes the result
to `/srv/xwiki/cacerts`, which `compose.yaml` mounts into XWiki. Run `sudo -v`
first: two `sudo` in one pipe would otherwise both ask for the password at
once.

```
# host
cd ~/Test-Projekt/services/xwiki
install -m 600 /dev/null .env && printf 'XWIKI_DB_PASSWORD=%s\n' "$(openssl rand -hex 24)" > .env
sudo -v
sudo docker run --rm -v /srv/proxy/certs/ca.crt:/ca.crt:ro --entrypoint sh xwiki:17.10.13-postgres-tomcat \
  -c 'keytool -importcert -noprompt -cacerts -storepass changeit -alias lab-test-root-ca -file /ca.crt >&2 && cat "$JAVA_HOME/lib/security/cacerts"' \
  | sudo tee /srv/xwiki/cacerts > /dev/null && sudo chmod 644 /srv/xwiki/cacerts && ls -l /srv/xwiki/cacerts
sudo docker compose config --quiet && sudo docker compose up -d
```

Expected: `Certificate was added to keystore`, then `/srv/xwiki/cacerts`
owned by root, mode 644; `xwiki-db` healthy, `xwiki` started. Line by line:
[`services/xwiki/README.md`](../services/xwiki/README.md#jvm-trust-store).

**Right after the start**, open `https://wiki.lab.test`: the wizard creates
the `admin` account and installs the *XWiki Standard Flavor* (several
minutes). Until the wizard has run, anyone who reaches `wiki.lab.test` can
create that admin account.

Then close registration and anonymous reading, as `admin`: Administer Wiki →
Users & Rights → Rights → tab **Users** → row *Unregistered Users*: click
**Register** until it shows ✗ (it cycles empty → ✓ → ✗); tick *Prevent
unregistered users from viewing pages* and *… from editing pages*. On the
*Registration* page set who may create accounts to *Closed* if offered. Check,
without being signed in:

```
# workstation
cd ~/Test-Projekt
for p in /bin/register/XWiki/XWikiRegister /bin/view/Main/; do curl -s --cacert pki/ca.crt -o /dev/null -w "$p %{http_code} %{redirect_url}\n" "https://wiki.lab.test$p"; done
```

Expected for both: `302` to `…/bin/login/XWiki/XWikiLogin…`.

### 5.15 XWiki — LDAP

Three parts ([`services/xwiki/README.md`](../services/xwiki/README.md#ldap)) —
**fill the form before activating the authenticator**. Once the
`xwiki.cfg` line is active, every sign-in goes through LDAP first; with an
empty form (or no form at all) even `admin` is locked out.

1. **Extensions** (Administration → Extensions), both in version **9.16.6**
   (the tested pair): *LDAP Authenticator*
   (`org.xwiki.contrib.ldap:ldap-authenticator`, the sign-in logic) and *LDAP
   Application* (`org.xwiki.contrib.ldap:ldap-ui`, the admin form). The
   second one may not show up in the default search — use *Advanced search*
   with the id. Check under *Installed extensions* that **both** are listed;
   a success message alone is not proof.
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
3. **Activate.** There is no switch in the UI for this version: one line in
   `xwiki.cfg` selects the authenticator. The container's entrypoint copies a
   `xwiki.cfg` from the data directory into place on every start, so the edit
   survives restarts and is part of the backup:

   ```
   # host
   cd ~/Test-Projekt/services/xwiki
   sudo docker cp xwiki:/usr/local/tomcat/webapps/ROOT/WEB-INF/xwiki.cfg /srv/xwiki/data/data/xwiki.cfg
   echo 'xwiki.authentication.authclass=org.xwiki.contrib.ldap.XWikiLDAPAuthServiceImpl' | sudo tee -a /srv/xwiki/data/data/xwiki.cfg
   sudo chown 100000:100000 /srv/xwiki/data/data/xwiki.cfg && sudo chmod 640 /srv/xwiki/data/data/xwiki.cfg
   sudo docker compose restart xwiki
   ```

   `restart` returns while XWiki is still starting; wait for `(healthy)` in
   `sudo docker ps` (about a minute).

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
# host
cd ~/Test-Projekt/services/xwiki
sudo docker exec xwiki sed -i 's|</configuration>|<logger name="org.xwiki.contrib.ldap" level="debug"/></configuration>|' /usr/local/tomcat/webapps/ROOT/WEB-INF/classes/logback.xml
sudo docker compose restart xwiki
```

Way back if everyone is locked out: remove the line and restart — the form
values are kept.

```
# host
cd ~/Test-Projekt/services/xwiki
sudo sed -i '/^xwiki.authentication.authclass=org.xwiki.contrib.ldap/d' /srv/xwiki/data/data/xwiki.cfg
sudo docker compose restart xwiki
```

### 5.16 Test the backup key

Now that every stack has its `.env`, run one backup by hand and decrypt it on
the workstation — this proves the key from 4.1:

```
# host
sudo systemctl start backup.service
sudo journalctl -u backup.service --since '-10 min' --no-pager | tail -5
ls -l /srv/backups/
```

`backup.service` is a one-shot unit: `systemctl start` returns only when the
backup is finished — about one and a half minutes without any output, while
the stacks pause briefly. To watch it, run `systemctl status backup.service`
in a second terminal. Expected: `==> done` in the journal, and in
`/srv/backups/` one file `<stamp>.tar.age` (e.g. `20261019T162135Z.tar.age`),
`-rw-r----- root backup`. A **directory** `<stamp>/` next to it means
encryption failed and the set lies there unencrypted — fix the cause (4.1),
then `sudo rm -rf /srv/backups/<stamp>`.

Fetch and decrypt — replace both `<stamp>` with the name `ls` printed:

```
# workstation
scp lab:/srv/backups/<stamp>.tar.age . && age -d -i ~/lab-pki/backup-identity.txt <stamp>.tar.age | tar -t
```

The admin may read the file because `bootstrap.sh` put it into the group
`backup`. `tar -t` lists the set without unpacking it. Expected:
`<stamp>/env/` (one `.env` per stack), `<stamp>/gitlab/` (including
`gitlab-secrets.json`), `<stamp>/lldap/`, `<stamp>/openproject/`,
`<stamp>/proxy/`, `<stamp>/xwiki/`, `manifest.txt`, `SHA256SUMS`. `no
identity matched any of the recipients` means the host still encrypts to
another key (4.1). The downloaded file holds every secret of the
installation — delete it when the test is done. Restore:
[`docs/backup-restore.md`](backup-restore.md).

At this point all services run, accept LDAP sign-in with group filtering,
and the backup can be decrypted. Sections 6 to 8 were built and verified on
the reference build on 2026-09-20 ([`integration.md`](integration.md),
[`backup-restore.md`](backup-restore.md)) but have **not** yet been walked
through with this guide — *not re-verified*.

## 6. Integrations

Why each one exists and what was deliberately not built:
[`integration.md`](integration.md). Security decisions behind the webhook:
[ADR-0014](adr/0014-gitlab-openproject-webhook.md).

### 6.1 GitLab → OpenProject: webhook

A merge request or commit that mentions `OP#<id>` appears on that work
package in OpenProject, tab *GitLab*. In this order:

1. **OpenProject**, as `admin`: a new role `GitLab Integration` with the
   three permissions *Show GitLab content*, *View work packages*, *Add
   comments*; a local user `gitlab-integration` (not from LDAP, no admin). In
   the project: module *GitLab* on (the default from 5.13), add the user as
   member with that role. Sign in as that user and create an API token in
   the account settings; store it.
2. **GitLab**, as `root` in admin mode: Admin → Settings → Network →
   Outbound requests: *Allow requests to the local network* **off**, allowlist
   `pm.lab.test` and `wiki.lab.test`, DNS-rebinding protection on.
3. **GitLab project** → Settings → Webhooks: URL
   `https://pm.lab.test/webhooks/gitlab?key=<token>`, events push, comments,
   work items, merge requests, pipelines; SSL verification **on** (GitLab
   trusts your CA since 5.9). *Test* → push events: `HTTP 200`.

Check: a merge request with `OP#<id>` in title and description shows up on
the work package, tab *GitLab*. Every delivery answering `200` and nothing
linked means a missing permission of the role
([P-018](problems.md#p-018--webhook-answered-200-on-every-delivery-and-linked-nothing)).

### 6.2 XWiki as the documentation hub

- **GitLab → XWiki:** Admin → Settings → Integrations → *External wiki*:
  `https://wiki.lab.test/bin/view/Projects/` (inherited by every project);
  per project, disable the built-in wiki (Settings → General → Visibility).
  Saving fails with "Requests to the local network are not allowed" until
  `wiki.lab.test` is in the allowlist from 6.1
  ([P-021](problems.md#p-021--gitlab-refuses-the-external-wiki-url-requests-to-the-local-network-are-not-allowed)).
- **OpenProject → XWiki:** Administration → Projects → Project attributes →
  new attribute `Documentation`, type *Link*; set it per project to the
  XWiki page.
- **XWiki → GitLab, OpenProject:** a page `Projects/<name>` per project with
  links to the repository and the work packages.

New projects later: README, "Project onboarding".

## 7. Acceptance checks

Each stack README ends with a *Verification* block — the commands with their
expected results in brackets, run on the host:
[`proxy`](../proxy/README.md#hardening-summary),
[`lldap`](../services/lldap/README.md#verification),
[`gitlab`](../services/gitlab/README.md#verification-evidence-for-docssecuritymd),
[`openproject`](../services/openproject/README.md#verification-evidence-for-docssecuritymd),
[`xwiki`](../services/xwiki/README.md#verification-evidence-for-docssecuritymd).
From outside — open ports, TLS, headers, the CIS Docker Benchmark:
[`security.md`](security.md#verification). Git over SSH on port 2222:
[`services/gitlab/README.md`](../services/gitlab/README.md#workstation-access-to-git).

## 8. Restore test

A backup counts only once it has been restored. On a **second** fresh server
(the first one keeps running for comparison): sections 1 and 3 of this guide,
then `bootstrap.sh`, copy a set and the identity, `restore.sh` —
[`backup-restore.md`](backup-restore.md#restore-procedure), with the
functional checklist afterwards. The reference build measured 21 minutes from
the first root login to a working system.

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
