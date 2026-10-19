# proxy — Caddy reverse proxy

Design: [ADR-0005](../docs/adr/0005-reverse-proxy.md). Implicit behaviour:
[architecture.md → What Caddy does implicitly](../docs/architecture.md#what-caddy-does-implicitly).
First installation, step by step: [`docs/install.md`](../docs/install.md)
5.1–5.6. This file is the reference for the stack.

## Files
- `compose.yaml` — the only stack that publishes ports (80, 443).
- `Caddyfile` — global options, the `hardened` header snippet, one site block per
  hostname with its own certificate.

## Host prerequisites
```
/srv/proxy/certs/   <host>.crt (644, root)  <host>.key (600, owner 101000)  ca.crt
/srv/proxy/data/    owner 101000            Caddy internal storage
/srv/proxy/config/  owner 101000            autosaved configuration
docker network edge (external)
```
`101000` = container UID 1000 + the `userns-remap` offset 100000 ([ADR-0002](../docs/adr/0002-os-and-docker.md)).
The certificate commands are in [`pki/README.md`](../pki/README.md) ("Deploying certificates to
the host"), including the `chown 101000:101000` of the keys. Check before the
first start — a key owned by `root` stops Caddy completely
([P-024](../docs/problems.md#p-024--caddy-restart-loop-on-a-first-install-the-key-files-belong-to-root)):
```
sudo ls -ln /srv/proxy/certs/ /srv/proxy/config/   # *.key and ldap-ui.auth: 101000 101000
```

## Validate before starting
Neither check changes or starts anything; both catch a broken configuration
before Caddy goes into a restart loop. On the workstation, from the repository
root, with the real image, the issued certificates and an empty stand-in for
the basic-auth file (it exists only on the host):
```bash
# workstation
touch /tmp/ldap-ui.auth
docker run --rm \
  -v "$PWD/proxy/Caddyfile:/etc/caddy/Caddyfile:ro,Z" \
  -v ~/lab-pki/issued:/certs:ro,Z \
  -v /tmp/ldap-ui.auth:/config/ldap-ui.auth:ro,Z \
  docker.io/library/caddy:2.11.4-alpine \
  caddy validate --config /etc/caddy/Caddyfile
rm /tmp/ldap-ui.auth
```
`podman` works the same way; `:Z` is for SELinux and ignored elsewhere.
Expected: `Valid configuration` (plus the warning `Import file is empty` for
the stand-in). On the host: `sudo docker compose -f proxy/compose.yaml config
--quiet && echo OK`.

## Basic auth in front of the lldap UI (once, on the host)
`ldap.lab.test` carries an additional HTTP basic-auth layer ([ADR-0011](../docs/adr/0011-lldap-container.md)): an
independent credential before the directory's own login. The hash file is
not in the repository.
```bash
sudo docker run --rm -it caddy:2.11.4-alpine caddy hash-password   # type the UI-gate password twice, copy the bcrypt hash
sudoedit /srv/proxy/config/ldap-ui.auth                            # one line per admin:  <username> <bcrypt-hash>
sudo chown 101000:101000 /srv/proxy/config/ldap-ui.auth && sudo chmod 640 /srv/proxy/config/ldap-ui.auth
sudo docker compose -f ~/Test-Projekt/proxy/compose.yaml restart caddy   # only if Caddy already runs
```
On a first install the last line does nothing (there is no container yet);
the next section starts Caddy. `sudoedit` keeps the hash out of the shell history; owner 101000 = Caddy's
host UID, so the container can read `/config/ldap-ui.auth`. Caddy refuses
to start if the file is missing — create it before pulling a Caddyfile that
imports it. The gate password is a separate secret from the lldap admin
password (two independent layers).

At the gate you sign in with the username and the **password** typed into
`hash-password`; the file holds only the bcrypt hash of it, so reading the
file does not let anyone in. To change the password, hash a new one, replace
the line and restart Caddy — it reads the file only at start-up, and with the
admin API off there is no reload.

## Start, restart, logs
```bash
sudo docker compose -f proxy/compose.yaml up -d
sudo docker compose -f proxy/compose.yaml restart caddy    # after certificate or Caddyfile changes
sudo docker logs caddy 2>&1 | tail    # Caddy logs to stderr; without 2>&1 tail sees nothing
```

## If Caddy does not start
`sudo docker ps -a --filter name=caddy` shows `Restarting (1)`, and every
hostname refuses the connection although the services behind it run.
`sudo docker logs caddy 2>&1 | tail` names the file:
- `open /certs/<host>.key: permission denied` → key owner, see above:
  `sudo chown 101000:101000 /srv/proxy/certs/*.key`, then `restart caddy`
  ([P-024](../docs/problems.md#p-024--caddy-restart-loop-on-a-first-install-the-key-files-belong-to-root)).
- `ldap-ui.auth` missing or unreadable → the basic-auth section above.

## Verify from the workstation
From the repository root, through `/etc/hosts` like a browser:
```bash
for h in git wiki pm ldap; do
  curl -sS --cacert pki/ca.crt "https://$h.lab.test/" -o /dev/null \
    -w "$h http=%{http_code} tls_verify=%{ssl_verify_result} ip=%{remote_ip}\n"
done
curl -sS -o /dev/null -w '%{http_code} -> %{redirect_url}\n' http://git.lab.test/
```
`tls_verify=0` means the chain validates against your CA, `ip=` must be the
host's address. `502` is the expected answer while a backend is not running,
the lldap gate answers `401`, port 80 must answer `308`. To test a host
before `/etc/hosts` points to it, add `--resolve "$h.lab.test:443:<server-ip>"`
— and remember that such a check stays green while the browser still goes
elsewhere.

## Hardening summary
non-root (`1000:1000`) · `cap_drop: ALL` + `cap_add: NET_BIND_SERVICE` (file
capability on the binary, [P-005](../docs/problems.md#p-005--caddy-exits-with-exec-usrbincaddy-operation-not-permitted)) · `no-new-privileges` · read-only root fs,
`/tmp` as tmpfs · `admin off` · HTTP/1.1 and HTTP/2 only · HSTS,
`X-Content-Type-Options`, `Referrer-Policy`, `Server` header removed.
