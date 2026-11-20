#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${MACCY_DERIVED_DATA:-$PROJECT_ROOT/build/ReleaseDerivedData}"
DIST_DIR="${MACCY_DIST_DIR:-$PROJECT_ROOT/dist}"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Release/Maccy.app"
BUILD_LOG="$DERIVED_DATA/maccy-release-build.log"

release_signing_identity=
case "${1:-}" in
  "") ;;
  --ci-sign)
    release_signing_identity="${MACCY_RELEASE_SIGNING_IDENTITY:-}"
    if [[ -z "$release_signing_identity" ]]; then
      echo "::warning::MACCY_RELEASE_SIGNING_IDENTITY is missing; this release will use ad-hoc signing."
    fi
    ;;
  *) echo "Usage: $0 [--ci-sign]" >&2; exit 2 ;;
esac
unset MACCY_RELEASE_SIGNING_IDENTITY

sign_published_app() (
  umask 077
  fail_signing() {
    printf 'Release signing failed: %s\n' "$1" >&2
    exit 1
  }

  [[ "$release_signing_identity" == ?*:?* ]] || fail_signing "expected a password and a Base64 PKCS#12 payload."
  p12_password="${release_signing_identity%%:*}"
  encoded_identity="$(printf '%s' "${release_signing_identity#*:}" | LC_ALL=C tr -d '[:space:]')" ||
    fail_signing "could not normalize the Base64 payload."
  [[ "$encoded_identity" =~ ^[A-Za-z0-9+/]+={0,2}$ && $(("${#encoded_identity}" % 4)) -eq 0 ]] ||
    fail_signing "the payload is not valid Base64."

  signing_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/MaccyCaptureSigning.XXXXXX")" ||
    fail_signing "could not create a private temporary directory."
  signing_keychain="$signing_dir/signing.keychain-db"
  identity_file="$signing_dir/identity.p12"
  certificate_file="$signing_dir/certificate.pem"
  restore_keychains=0
  cleanup_signing() {
    if [[ "$restore_keychains" -eq 1 ]]; then
      /usr/bin/security list-keychains -d user -s "$@" ||
        echo "::warning::Could not restore the original user keychain search list." >&2
    fi
    if [[ -f "$signing_keychain" ]]; then
      /usr/bin/security delete-keychain "$signing_keychain" >/dev/null 2>&1 || true
    fi
    rm -rf "$signing_dir"
  }
  trap 'cleanup_signing "$@"' EXIT

  printf '%s\n' "$encoded_identity" | fold -w 64 | /usr/bin/openssl base64 -d > "$identity_file" ||
    fail_signing "could not decode the Base64 payload."
  P12_PASSWORD="$p12_password" /usr/bin/openssl pkcs12 -in "$identity_file" -clcerts -nokeys \
    -passin env:P12_PASSWORD -out "$certificate_file" 2>/dev/null ||
    fail_signing "the decoded PKCS#12 identity or its password is invalid."
  fingerprint="$(/usr/bin/openssl x509 -in "$certificate_file" -outform DER 2>/dev/null |
    /usr/bin/shasum -a 1 | awk '{print toupper($1)}')" ||
    fail_signing "could not read the signing certificate."

  keychain_list="$(/usr/bin/security list-keychains -d user)" ||
    fail_signing "could not read the user keychain search list."
  while IFS= read -r entry; do
    if [[ "$entry" == *\"*\" ]]; then
      entry="${entry#*\"}"
      set -- "$@" "${entry%\"}"
    fi
  done <<< "$keychain_list"

  keychain_password="$(/usr/bin/openssl rand -base64 32)" ||
    fail_signing "could not generate a temporary keychain password."
  /usr/bin/security create-keychain -p "$keychain_password" "$signing_keychain" ||
    fail_signing "could not create the temporary keychain."
  /usr/bin/security unlock-keychain -p "$keychain_password" "$signing_keychain" ||
    fail_signing "could not unlock the temporary keychain."
  /usr/bin/security import "$identity_file" -k "$signing_keychain" -t cert -f pkcs12 \
    -P "$p12_password" -T /usr/bin/codesign ||
    fail_signing "could not import the PKCS#12 identity."
  /usr/bin/security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" \
    "$signing_keychain" >/dev/null ||
    fail_signing "could not grant codesign access to the temporary keychain."

  # codesign also needs the temporary keychain in the user search list.
  restore_keychains=1
  /usr/bin/security list-keychains -d user -s "$signing_keychain" "$@" ||
    fail_signing "could not add the temporary keychain to the search list."

  requirement="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$fingerprint\""
  codesign --force --sign "$fingerprint" --keychain "$signing_keychain" --timestamp=none \
    --preserve-metadata=entitlements --requirements "=designated => $requirement" "$PACKAGED_APP" ||
    fail_signing "codesign could not use the configured certificate."
  codesign --verify --deep --strict --all-architectures --test-requirement "=$requirement" "$PACKAGED_APP" ||
    fail_signing "the resulting signature does not satisfy the certificate requirement."
)

mkdir -p "$DERIVED_DATA" "$DIST_DIR"
BUILD_OPTIONS=('ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO)
if [[ -n "${MACCY_BUILD_VERSION:-}" ]]; then
  if [[ ! "$MACCY_BUILD_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "Expected a numeric, monotonically increasing build version." >&2
    exit 2
  fi
  BUILD_OPTIONS+=("CURRENT_PROJECT_VERSION=$MACCY_BUILD_VERSION")
fi
OPTIMIZATION="project default"
if [[ "$(xcrun swiftc --version)" == *"Apple Swift version 6.3.3 "* ]]; then
  BUILD_OPTIONS+=(SWIFT_OPTIMIZATION_LEVEL=-Onone)
  OPTIMIZATION="-Onone for arm64 and x86_64; Swift 6.3.3 optimizer crash workaround"
  printf 'Applying optimizer workaround for Apple Swift 6.3.3 on arm64 and x86_64.\n'
fi
if ! xcodebuild \
  -project "$PROJECT_ROOT/Maccy.xcodeproj" \
  -scheme Maccy \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipMacroValidation \
  "${BUILD_OPTIONS[@]}" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  CODE_SIGNING_ALLOWED=YES \
  OTHER_CODE_SIGN_FLAGS=--timestamp=none \
  ENABLE_HARDENED_RUNTIME=NO \
  build > "$BUILD_LOG" 2>&1; then
  tail -100 "$BUILD_LOG" >&2
  exit 1
fi

codesign --verify --deep --strict "$APP_BUNDLE"
ARCHITECTURES="$(xcrun lipo -archs "$APP_BUNDLE/Contents/MacOS/Maccy")"
for architecture in arm64 x86_64; do
  if [[ " $ARCHITECTURES " != *" $architecture "* ]]; then
    echo "Missing required architecture: $architecture" >&2
    exit 2
  fi
done
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"
if [[ "$BUNDLE_ID" != "local.maccy.capture" ]]; then
  echo "Refusing to package an application without the customized bundle identity." >&2
  exit 2
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
REVISION="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
PACKAGE_NAME="Maccy-Capture-${VERSION}-build${BUILD_VERSION}-${REVISION:0:12}-universal"
WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/MaccyCapturePackage.XXXXXX")"
trap 'rm -rf "$WORKSPACE"' EXIT

PACKAGED_APP="$WORKSPACE/Maccy Capture.app"
ditto "$APP_BUNDLE" "$PACKAGED_APP"
ditto "$PROJECT_ROOT/LICENSE" "$WORKSPACE/LICENSE"
ditto "$PROJECT_ROOT/DISTRIBUTION-NOTICE.md" "$WORKSPACE/DISTRIBUTION-NOTICE.md"
ditto "$PROJECT_ROOT/DISTRIBUTION-NOTICE.zh-CN.md" "$WORKSPACE/DISTRIBUTION-NOTICE.zh-CN.md"
mkdir -p "$WORKSPACE/ThirdPartyLicenses"
RESOLVED_PACKAGES="$PROJECT_ROOT/Maccy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PACKAGE_INDEX=0
while PACKAGE_IDENTITY="$(/usr/bin/plutil -extract "pins.$PACKAGE_INDEX.identity" raw -o - "$RESOLVED_PACKAGES" 2>/dev/null)"; do
  PACKAGE_DIRECTORY="$(find "$DERIVED_DATA/SourcePackages/checkouts" -mindepth 1 -maxdepth 1 \
    -type d -iname "$PACKAGE_IDENTITY" -print)"
  if [[ -z "$PACKAGE_DIRECTORY" || ! -d "$PACKAGE_DIRECTORY" ]]; then
    echo "Missing dependency checkout for license collection: $PACKAGE_IDENTITY" >&2
    exit 2
  fi
  NOTICE_DIRECTORY="$WORKSPACE/ThirdPartyLicenses/$PACKAGE_IDENTITY"
  mkdir -p "$NOTICE_DIRECTORY"
  LICENSE_COUNT=0
  for license_file in "$PACKAGE_DIRECTORY"/[Ll][Ii][Cc][Ee][Nn][Ss][Ee]* \
    "$PACKAGE_DIRECTORY"/[Cc][Oo][Pp][Yy][Ii][Nn][Gg]*; do
    [[ -f "$license_file" ]] || continue
    ditto "$license_file" "$NOTICE_DIRECTORY/$(basename "$license_file")"
    LICENSE_COUNT=$((LICENSE_COUNT + 1))
  done
  if [[ "$LICENSE_COUNT" -eq 0 ]]; then
    echo "Missing license text for dependency: $PACKAGE_IDENTITY" >&2
    exit 2
  fi
  for notice_file in "$PACKAGE_DIRECTORY"/[Nn][Oo][Tt][Ii][Cc][Ee]*; do
    [[ -f "$notice_file" ]] || continue
    ditto "$notice_file" "$NOTICE_DIRECTORY/$(basename "$notice_file")"
  done
  {
    printf 'Package: %s\nSource: ' "$PACKAGE_IDENTITY"
    /usr/bin/plutil -extract "pins.$PACKAGE_INDEX.location" raw -o - "$RESOLVED_PACKAGES"
    printf '\nRevision: '
    /usr/bin/plutil -extract "pins.$PACKAGE_INDEX.state.revision" raw -o - "$RESOLVED_PACKAGES"
    printf '\n\n'
  } >> "$WORKSPACE/ThirdPartyLicenses/SOURCES.txt"
  PACKAGE_INDEX=$((PACKAGE_INDEX + 1))
done
if [[ "$PACKAGE_INDEX" -eq 0 ]]; then
  echo "No locked dependency licenses were collected." >&2
  exit 2
fi
APP_RESOURCES="$PACKAGED_APP/Contents/Resources"
ditto "$WORKSPACE/LICENSE" "$APP_RESOURCES/LICENSE"
ditto "$WORKSPACE/DISTRIBUTION-NOTICE.md" "$APP_RESOURCES/DISTRIBUTION-NOTICE.md"
ditto "$WORKSPACE/DISTRIBUTION-NOTICE.zh-CN.md" "$APP_RESOURCES/DISTRIBUTION-NOTICE.zh-CN.md"
ditto "$WORKSPACE/ThirdPartyLicenses" "$APP_RESOURCES/ThirdPartyLicenses"
if [[ -n "$release_signing_identity" ]] && sign_published_app; then
  SIGNING_DESCRIPTION="fixed self-signed certificate; not Developer ID signed or notarized"
  SIGNING_NOTICE="The first update from an older signing identity may require granting screen recording permission again."
else
  if [[ -n "$release_signing_identity" ]]; then
    echo "::warning::MACCY_RELEASE_SIGNING_IDENTITY is unusable; this release will use ad-hoc signing."
  fi
  codesign --force --sign - --timestamp=none --preserve-metadata=entitlements,flags "$PACKAGED_APP"
  SIGNING_DESCRIPTION="ad-hoc; not Developer ID signed or notarized"
  SIGNING_NOTICE="Updates from ad-hoc builds may require granting screen recording permission again."
fi
unset release_signing_identity
codesign --verify --deep --strict "$PACKAGED_APP"
printf 'Release app signing: %s\n' "$SIGNING_DESCRIPTION"
ditto -c -k --sequesterRsrc \
  "$WORKSPACE" "$DIST_DIR/$PACKAGE_NAME.zip"
ln -s /Applications "$WORKSPACE/Applications"
hdiutil create -quiet -ov -format UDZO -fs HFS+ \
  -volname "Maccy Capture" -srcfolder "$WORKSPACE" "$DIST_DIR/$PACKAGE_NAME.dmg"

cat > "$DIST_DIR/BUILD-INFO.txt" <<INFO
Product: Maccy Capture
Version: $VERSION
Build version: $BUILD_VERSION
Bundle identifier: $BUNDLE_ID
Source revision: $REVISION
Architectures: arm64, x86_64
Optimization: $OPTIMIZATION
Minimum macOS: 14.0
Signing: $SIGNING_DESCRIPTION

This is a customized build, not an official Maccy release.
No private key, clipboard history or screenshots are included.
Gatekeeper may block first launch. $SIGNING_NOTICE
INFO

(
  cd "$DIST_DIR"
  shasum -a 256 "$PACKAGE_NAME.zip" "$PACKAGE_NAME.dmg" BUILD-INFO.txt > SHA256SUMS.txt
)
printf 'Packaged: %s/%s.zip\nPackaged: %s/%s.dmg\n' "$DIST_DIR" "$PACKAGE_NAME" "$DIST_DIR" "$PACKAGE_NAME"
