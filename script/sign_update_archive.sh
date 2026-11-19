#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${MACCY_DERIVED_DATA:?Expected the packaged application Derived Data directory}"
: "${MACCY_DIST_DIR:?Expected the package directory}"
REVISION="${GITHUB_SHA:-$(git -C "$PROJECT_ROOT" rev-parse HEAD)}"
APP="$MACCY_DERIVED_DATA/Build/Products/Release/Maccy.app"
SIGN_UPDATE="$MACCY_DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
shopt -s nullglob
PACKAGES=("$MACCY_DIST_DIR"/Maccy-Capture-*-"${REVISION:0:12}"-universal.zip)
if [[ "${#PACKAGES[@]}" -ne 1 ]]; then
  echo "Expected exactly one update archive for the built revision." >&2
  exit 2
fi
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  SIGNATURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - -p "${PACKAGES[0]}")"
elif [[ "${GITHUB_ACTIONS:-}" != true && -n "${MACCY_UPDATE_SIGNING_ACCOUNT:-}" ]]; then
  SIGNATURE="$("$SIGN_UPDATE" --account "$MACCY_UPDATE_SIGNING_ACCOUNT" -p "${PACKAGES[0]}")"
else
  echo "A dedicated update-signing key is required; unsigned updates cannot be published." >&2
  exit 2
fi
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$APP/Contents/Info.plist")"
env -u SPARKLE_PRIVATE_KEY xcrun swift "$PROJECT_ROOT/script/verify_update_signature.swift" \
  "$PUBLIC_KEY" "${PACKAGES[0]}" "$SIGNATURE"
env -u SPARKLE_PRIVATE_KEY python3 "$PROJECT_ROOT/script/generate_update_feed.py" metadata \
  --archive "${PACKAGES[0]}" --app "$APP" --signature "$SIGNATURE" --revision "$REVISION" \
  --output "$MACCY_DIST_DIR/UPDATE-METADATA.json"
(
  cd "$MACCY_DIST_DIR"
  PACKAGE_NAME="$(basename "${PACKAGES[0]}" .zip)"
  shasum -a 256 "$PACKAGE_NAME.zip" "$PACKAGE_NAME.dmg" BUILD-INFO.txt UPDATE-METADATA.json > SHA256SUMS.txt
)
echo "Signed and verified the update archive; no private key is included in the artifacts."
