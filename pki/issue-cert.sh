#!/usr/bin/env bash

set -euo pipefail

# Issues one server certificate signed by the lab.test Root CA.
# Usage: issue-cert.sh <hostname>        e.g. issue-cert.sh git.lab.test
# Output: $PKI_DIR/issued/<hostname>.{key,crt}; the key is NOT encrypted because
# Caddy must read it at start-up - protection comes from file mode 600 on the host.

PKI_DIR="${PKI_DIR:-$HOME/lab-pki}"
OUT_DIR="$PKI_DIR/issued"

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <hostname>" >&2
    exit 64
fi
NAME="$1"

if [[ ! -f "$PKI_DIR/ca.key" || ! -f "$PKI_DIR/ca.crt" ]]; then
    echo "error: CA not found in $PKI_DIR - run make-ca.sh first" >&2
    exit 1
fi

if [[ -e "$OUT_DIR/$NAME.crt" ]]; then
    echo "error: $OUT_DIR/$NAME.crt already exists - move it away to renew" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

echo "==> generating private key for $NAME"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$OUT_DIR/$NAME.key"
chmod 600 "$OUT_DIR/$NAME.key"

echo "==> creating certificate signing request"
openssl req -new -key "$OUT_DIR/$NAME.key" -subj "/CN=$NAME" -out "$OUT_DIR/$NAME.csr"

echo "==> signing with the CA (you will be asked for the CA passphrase)"
openssl x509 -req -in "$OUT_DIR/$NAME.csr" \
    -CA "$PKI_DIR/ca.crt" -CAkey "$PKI_DIR/ca.key" -CAcreateserial \
    -days 365 -sha256 \
    -extfile <(printf 'subjectAltName=DNS:%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n' "$NAME") \
    -out "$OUT_DIR/$NAME.crt"
chmod 644 "$OUT_DIR/$NAME.crt"
rm -f "$OUT_DIR/$NAME.csr"

echo "==> verifying chain"
openssl verify -CAfile "$PKI_DIR/ca.crt" "$OUT_DIR/$NAME.crt"
echo "==> done: $OUT_DIR/$NAME.crt"
openssl x509 -in "$OUT_DIR/$NAME.crt" -noout -subject -dates -ext subjectAltName

