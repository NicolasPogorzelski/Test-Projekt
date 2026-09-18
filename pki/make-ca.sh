#!/usr/bin/env bash

set -euo pipefail

# Creates  the private root CA for *.lab.test on the workstation
# Private material stays outside the repo (PKI_DIR) and only ca.crt is copied in

PKI_DIR="${PKI_DIR:-$HOME/lab-pki}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -e "$PKI_DIR/ca.key" ]]; then
    echo "error: $PKI_DIR/ca.key already exists - refusing to overwrite the CA" >&2
    exit 1
fi

mkdir -p "$PKI_DIR"
chmod 700 "$PKI_DIR"

echo "==> generating CA private key"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -aes-256-cbc -out "$PKI_DIR/ca.key"
chmod 600 "$PKI_DIR/ca.key"

echo "==> creating self-signed CA certificate (10 years)"
openssl req -x509 -new -key "$PKI_DIR/ca.key" -sha256 -days 3650 \
    -subj "/CN=lab.test Root CA/O=lab.test" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" \
    -out "$PKI_DIR/ca.crt"
chmod 644 "$PKI_DIR/ca.crt"

cp "$PKI_DIR/ca.crt" "$REPO_DIR/pki/ca.crt"

echo "==> done"
openssl x509 -in "$PKI_DIR/ca.crt" -noout -subject -dates -fingerprint -sha256
