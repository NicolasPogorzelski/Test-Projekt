# PKI — private CA and service certificates

Design decisions: [ADR-0007](../docs/adr/0007-pki.md).

## Concept in four sentences

A certificate binds a public key to a hostname and is signed by a Certificate
Authority (CA). Clients trust a certificate if they trust the CA that signed
it. This project runs its own root CA on the workstation and issues one
certificate per service (`git`, `wiki`, `pm`, `ldap` under `lab.test`). Every
client — browsers and the services themselves when they call each other — must
therefore import `ca.crt` once; the private CA key never leaves the
workstation.

## Files and where they live

| File | Location | Tracked in git | Mode |
|---|---|---|---|
| `ca.key` (CA private key, AES-256 encrypted) | workstation `~/lab-pki/` | **never** | 600 |
| `ca.crt` (CA certificate, public) | workstation `~/lab-pki/`, repo `pki/ca.crt`, host `/srv/proxy/certs/` | yes | 644 |
| `ca.srl` (serial counter) | workstation `~/lab-pki/` | no | 644 |
| `<host>.key` (service private key, unencrypted) | workstation `~/lab-pki/issued/`, host `/srv/proxy/certs/` | never | 600 |
| `<host>.crt` (service certificate) | workstation `~/lab-pki/issued/`, host `/srv/proxy/certs/` | no | 644 |

`PKI_DIR` (default `~/lab-pki`) can be overridden in the environment.

## CA certificate fingerprint

```
SHA256 A7:08:31:80:94:29:B9:64:81:47:C3:83:9F:D3:55:04:AE:37:06:FD:81:9A:0D:AB:A7:9B:3E:3D:38:97:49:B0
```

Compare after importing: `openssl x509 -in pki/ca.crt -noout -fingerprint -sha256`.
A different value means the file was replaced on the way — do not trust it.

## `make-ca.sh` — create the root CA (run once)

```
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -aes-256-cbc -out ca.key
```
| Flag | Meaning |
|---|---|
| `genpkey` | generate a private key of any algorithm (replaces `genrsa`/`ecparam`) |
| `-algorithm EC -pkeyopt ec_paramgen_curve:P-256` | elliptic curve NIST P-256 (`prime256v1`) — small, fast, supported by Caddy, Java 17+, Ruby/OpenSSL and all browsers |
| `-aes-256-cbc` | encrypt the key file with a passphrase (asked interactively) |

```
openssl req -x509 -new -key ca.key -sha256 -days 3650 -subj "/CN=lab.test Root CA/O=lab.test" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" -out ca.crt
```
| Flag | Meaning |
|---|---|
| `req -x509 -new -key` | create a self-signed certificate directly from the key (a root CA signs itself) |
| `-sha256` | signature hash; SHA-1 is deprecated |
| `-days 3650` | 10 years — renewing a CA means touching every trust store |
| `-subj` | the certificate name; the CN is only a label for a CA |
| `basicConstraints=critical,CA:TRUE,pathlen:0` | this is a CA; it may **not** issue sub-CAs; clients that do not understand the extension must reject the certificate |
| `keyUsage=critical,keyCertSign,cRLSign` | the key may sign certificates and revocation lists, nothing else |
| `subjectKeyIdentifier=hash` | key identifier that leaf certificates reference to build the chain |

## `issue-cert.sh <hostname>` — issue a service certificate

```
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out <host>.key
```
Not encrypted: Caddy must read it at start-up without a passphrase. Protection
is the file mode (600) and the owner on the host.

```
openssl req -new -key <host>.key -subj "/CN=<host>" -out <host>.csr
```
A certificate signing request: public key plus name, no extensions — the CA
decides the extensions when signing.

```
openssl x509 -req -in <host>.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 365 -sha256 \
  -extfile <(printf 'subjectAltName=DNS:%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n' "<host>") \
  -out <host>.crt
```
| Flag / extension | Meaning |
|---|---|
| `x509 -req -in` | turn a CSR into a certificate |
| `-CA`, `-CAkey` | sign with the CA (passphrase asked) |
| `-CAcreateserial` | maintain `ca.srl`; every certificate of a CA needs a unique serial |
| `-days 365` | below the 397-day convention browsers enforce for public CAs; forces a yearly renewal routine |
| `-extfile <(printf …)` | extensions from a here-string via process substitution, no temp file |
| `subjectAltName=DNS:<host>` | **the** name browsers check; the CN is ignored by modern clients |
| `basicConstraints=critical,CA:FALSE` | a leaf, not a CA |
| `keyUsage=critical,digitalSignature` | sufficient for ECDSA TLS (`keyEncipherment` is RSA key transport) |
| `extendedKeyUsage=serverAuth` | TLS server; browsers require it |
| `subjectKeyIdentifier`, `authorityKeyIdentifier` | link the leaf to the CA |

The script ends with `openssl verify -CAfile ca.crt <host>.crt`, which must print `OK`.

## Deploying certificates to the host

```
scp ~/lab-pki/issued/*.crt ~/lab-pki/issued/*.key ~/lab-pki/ca.crt lab:~/certs-upload/
ssh lab
sudo install -m 644 -o root -g root ~/certs-upload/*.crt /srv/proxy/certs/
sudo install -m 600 -o root -g root ~/certs-upload/*.key /srv/proxy/certs/
rm -r ~/certs-upload
```
`install` copies and sets mode and owner in one step. The owner of the key
files is adjusted to the (userns-remapped) UID of the Caddy process when the
proxy stack is set up — see `proxy/README.md`.

## Renewal runbook (yearly)

1. On the workstation: `mv ~/lab-pki/issued/<host>.crt ~/lab-pki/issued/<host>.crt.$(date +%F)`
   (the script refuses to overwrite an existing certificate on purpose).
2. `./pki/issue-cert.sh <host>` — a new key pair and certificate are created.
3. Copy to the host as above; restore the owner of the key file.
4. Reload Caddy: `sudo docker compose -f proxy/compose.yaml exec caddy caddy reload --config /etc/caddy/Caddyfile`.
5. Check: `openssl s_client -connect <host>:443 -servername <host> </dev/null 2>/dev/null | openssl x509 -noout -dates`.

## Importing the CA on a workstation

- **Fedora / Bazzite system store:** `sudo cp pki/ca.crt /etc/pki/ca-trust/source/anchors/lab-test-ca.crt && sudo update-ca-trust`
- **Debian/Ubuntu:** `sudo cp pki/ca.crt /usr/local/share/ca-certificates/lab-test-ca.crt && sudo update-ca-certificates`
- **Flatpak browsers do not read the system store** (see `docs/problems.md`, P-001):
  Firefox → Settings → Privacy & Security → Certificates → View Certificates →
  Authorities → Import → select `pki/ca.crt` → "Trust this CA to identify websites".
  Chrome → Settings → Privacy and security → Security → Manage certificates →
  Authorities → Import.
- Name resolution: add `<server-ip>  git.lab.test wiki.lab.test pm.lab.test ldap.lab.test`
  to `/etc/hosts`.
