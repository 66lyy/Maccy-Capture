#!/usr/bin/env bash
set -euo pipefail
umask 077

REPOSITORY="${1:?Usage: bash $0 OWNER/REPO}"
SECRET_NAME=MACCY_RELEASE_SIGNING_IDENTITY
BACKUP_DIR="$HOME/.config/maccy-capture/release-signing/$REPOSITORY"
BACKUP_FILE="$BACKUP_DIR/identity.secret"

existing_secrets="$(gh secret list --repo "$REPOSITORY" --json name --jq '.[].name')"
if grep -Fxq "$SECRET_NAME" <<< "$existing_secrets"; then
  echo "$SECRET_NAME is already configured; leaving the signing identity unchanged."
  exit 0
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
  workspace="$(mktemp -d "${TMPDIR:-/tmp}/MaccyCaptureCertificate.XXXXXX")"
  trap 'rm -rf "$workspace"' EXIT
  cat > "$workspace/openssl.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = Maccy Capture Release Signing
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG
  openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
    -config "$workspace/openssl.cnf" -keyout "$workspace/key.pem" -out "$workspace/cert.pem"
  password="$(openssl rand -base64 32)"
  P12_PASSWORD="$password" openssl pkcs12 -export -name "Maccy Capture Release Signing" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -inkey "$workspace/key.pem" -in "$workspace/cert.pem" \
    -out "$workspace/identity.p12" -passout env:P12_PASSWORD
  mkdir -p "$BACKUP_DIR"
  (set -o noclobber; { printf '%s:' "$password"; base64 < "$workspace/identity.p12" | tr -d '\r\n'; } > "$BACKUP_FILE")
fi

gh secret set "$SECRET_NAME" --repo "$REPOSITORY" < "$BACKUP_FILE"
printf 'Configured %s for %s. Keep a private offline copy of %s; never share it.\n' \
  "$SECRET_NAME" "$REPOSITORY" "$BACKUP_FILE"
