#!/usr/bin/env bash
set -euo pipefail

CERTIFICATE_NAME="Maccy Capture Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
existing_identity="$(security find-identity -v -p codesigning | awk -v name="$CERTIFICATE_NAME" 'index($0, "\"" name "\"") {print $2; exit}')"
if [[ -n "$existing_identity" ]]; then
  echo "The reusable local signing identity is already available."
  exit 0
fi

umask 077
workspace="$(mktemp -d /private/tmp/MaccyLocalSigning.XXXXXX)"
trap 'rm -f "$workspace/key.pem" "$workspace/certificate.pem" "$workspace/identity.p12" "$workspace/openssl.cnf"; rmdir "$workspace"' EXIT
cat > "$workspace/openssl.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = Maccy Capture Local Signing
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG
/usr/bin/openssl req -new -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
  -config "$workspace/openssl.cnf" \
  -keyout "$workspace/key.pem" -out "$workspace/certificate.pem" 2>/dev/null
password="$(/usr/bin/openssl rand -base64 32)"
/usr/bin/openssl pkcs12 -export -name "$CERTIFICATE_NAME" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -inkey "$workspace/key.pem" -in "$workspace/certificate.pem" \
  -out "$workspace/identity.p12" -passout "pass:$password"
/usr/bin/openssl pkcs12 -in "$workspace/identity.p12" -passin "pass:$password" -noout
security import "$workspace/identity.p12" -k "$KEYCHAIN" -P "$password" -T /usr/bin/codesign
unset password
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$workspace/certificate.pem"
identity="$(security find-identity -v -p codesigning | awk -v name="$CERTIFICATE_NAME" 'index($0, "\"" name "\"") {print $2; exit}')"
if [[ -z "$identity" ]]; then
  echo "The local signing identity is unavailable. Check Keychain Access before building." >&2
  exit 1
fi
echo "Reusable signing identity created in the login keychain with code-signing-only trust."
