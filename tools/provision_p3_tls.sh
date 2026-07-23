#!/bin/sh
set -eu

workspace_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir="$workspace_dir/.build/p3-poc-tls"
password_file="$output_dir/password"
key_file="$output_dir/key.pem"
certificate_file="$output_dir/cert.pem"
identity_file="$output_dir/identity.p12"

mkdir -p "$output_dir"
umask 077

if [ -s "$identity_file" ] && [ -s "$certificate_file" ] && [ -s "$password_file" ]; then
    exit 0
fi

openssl rand -hex 24 > "$password_file"
openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 30 \
    -subj "/CN=Second Display P3 PoC" \
    -addext "subjectAltName=IP:192.168.43.9,IP:127.0.0.1,DNS:localhost" \
    -keyout "$key_file" -out "$certificate_file"
openssl pkcs12 -export -out "$identity_file" -inkey "$key_file" -in "$certificate_file" \
    -passout "file:$password_file"
chmod 600 "$password_file" "$key_file" "$certificate_file" "$identity_file"
