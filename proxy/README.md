# proxy — Caddy reverse proxy

Design: [ADR-0005](../docs/adr/0005-reverse-proxy.md). Implicit behaviour:
[architecture.md → What Caddy does implicitly](../docs/architecture.md#what-caddy-does-implicitly).

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

## Validate before starting
On the workstation, with the real image and the issued certificates mounted:
```bash
podman run --rm -v ./proxy/Caddyfile:/etc/caddy/Caddyfile:ro,Z -v ~/lab-pki/issued:/certs:ro,Z \
  docker.io/library/caddy:2.11.4-alpine caddy validate --config /etc/caddy/Caddyfile
```
On the host: `sudo docker compose -f proxy/compose.yaml config --quiet`.

## Basic auth in front of the lldap UI (once, on the host)
`ldap.lab.test` carries an additional HTTP basic-auth layer ([ADR-0011](../docs/adr/0011-lldap-container.md)): an
independent credential before the directory's own login. The hash file is
not in the repository.
```bash
sudo docker run --rm -it caddy:2.11.4-alpine caddy hash-password   # type the UI-gate password twice, copy the bcrypt hash
sudoedit /srv/proxy/config/ldap-ui.auth                            # one line per admin:  <username> <bcrypt-hash>
sudo chown 101000:101000 /srv/proxy/config/ldap-ui.auth && sudo chmod 640 /srv/proxy/config/ldap-ui.auth
sudo docker compose -f ~/Test-Projekt/proxy/compose.yaml restart caddy
```
`sudoedit` keeps the hash out of the shell history; owner 101000 = Caddy's
host UID, so the container can read `/config/ldap-ui.auth`. Caddy refuses
to start if the file is missing — create it before pulling a Caddyfile that
imports it. The gate password is a separate secret from the lldap admin
password (two independent layers).

## Start, restart, logs
```bash
sudo docker compose -f proxy/compose.yaml up -d
sudo docker compose -f proxy/compose.yaml restart caddy    # after certificate or Caddyfile changes
sudo docker logs caddy | tail
```

## Verify from the workstation
```bash
for h in git wiki pm ldap; do
  curl -sS --resolve "$h.lab.test:443:<server-ip>" --cacert pki/ca.crt "https://$h.lab.test/" \
    -o /dev/null -w "$h http=%{http_code} tls_verify=%{ssl_verify_result}\n"
done
curl -sS --resolve git.lab.test:80:<server-ip> -o /dev/null -w '%{http_code} -> %{redirect_url}\n' http://git.lab.test/
```
`tls_verify=0` means the chain validates against the private CA. `502` is the
expected answer while a backend is not running; port 80 must answer `308`.

## Hardening summary
non-root (`1000:1000`) · `cap_drop: ALL` + `cap_add: NET_BIND_SERVICE` (file
capability on the binary, [P-005](../docs/problems.md#p-005--caddy-exits-with-exec-usrbincaddy-operation-not-permitted)) · `no-new-privileges` · read-only root fs,
`/tmp` as tmpfs · `admin off` · HTTP/1.1 and HTTP/2 only · HSTS,
`X-Content-Type-Options`, `Referrer-Policy`, `Server` header removed.
