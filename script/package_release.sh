#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${MACCY_DERIVED_DATA:-$PROJECT_ROOT/build/ReleaseDerivedData}"
DIST_DIR="${MACCY_DIST_DIR:-$PROJECT_ROOT/dist}"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Release/Maccy.app"
BUILD_LOG="$DERIVED_DATA/maccy-release-build.log"

mkdir -p "$DERIVED_DATA" "$DIST_DIR"
BUILD_OPTIONS=('ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO)
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
REVISION="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
PACKAGE_NAME="Maccy-Capture-${VERSION}-${REVISION:0:12}-universal"
WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/MaccyCapturePackage.XXXXXX")"
trap 'rm -rf "$WORKSPACE"' EXIT

ditto "$APP_BUNDLE" "$WORKSPACE/Maccy Capture.app"
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
APP_RESOURCES="$WORKSPACE/Maccy Capture.app/Contents/Resources"
ditto "$WORKSPACE/LICENSE" "$APP_RESOURCES/LICENSE"
ditto "$WORKSPACE/DISTRIBUTION-NOTICE.md" "$APP_RESOURCES/DISTRIBUTION-NOTICE.md"
ditto "$WORKSPACE/DISTRIBUTION-NOTICE.zh-CN.md" "$APP_RESOURCES/DISTRIBUTION-NOTICE.zh-CN.md"
ditto "$WORKSPACE/ThirdPartyLicenses" "$APP_RESOURCES/ThirdPartyLicenses"
codesign --force --sign - --timestamp=none --preserve-metadata=entitlements,flags \
  "$WORKSPACE/Maccy Capture.app"
codesign --verify --deep --strict "$WORKSPACE/Maccy Capture.app"
ditto -c -k --sequesterRsrc \
  "$WORKSPACE" "$DIST_DIR/$PACKAGE_NAME.zip"
ln -s /Applications "$WORKSPACE/Applications"
hdiutil create -quiet -ov -format UDZO -fs HFS+ \
  -volname "Maccy Capture" -srcfolder "$WORKSPACE" "$DIST_DIR/$PACKAGE_NAME.dmg"

cat > "$DIST_DIR/BUILD-INFO.txt" <<INFO
Product: Maccy Capture
Version: $VERSION
Bundle identifier: $BUNDLE_ID
Source revision: $REVISION
Architectures: arm64, x86_64
Optimization: $OPTIMIZATION
Minimum macOS: 14.0
Signing: ad-hoc; not Developer ID signed or notarized

This is a customized build, not an official Maccy release.
No local signing identity, private key, clipboard history or screenshots are included.
Gatekeeper may block first launch, and updates may require screen recording permission again.
For a stable local signing identity, build from source with script/build_and_run.sh.
INFO

(
  cd "$DIST_DIR"
  shasum -a 256 "$PACKAGE_NAME.zip" "$PACKAGE_NAME.dmg" BUILD-INFO.txt > SHA256SUMS.txt
)
printf 'Packaged: %s/%s.zip\nPackaged: %s/%s.dmg\n' "$DIST_DIR" "$PACKAGE_NAME" "$DIST_DIR" "$PACKAGE_NAME"
