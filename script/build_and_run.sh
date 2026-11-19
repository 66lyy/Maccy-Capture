#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${MACCY_DERIVED_DATA:-/private/tmp/MaccyDerivedData}"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/Maccy.app"
INSTALLED_APP="${MACCY_INSTALL_BUNDLE:-/Applications/Maccy Capture.app}"
INSTALLED_APP="$(cd "$(dirname "$INSTALLED_APP")" && pwd -P)/$(basename "$INSTALLED_APP")"
BUILD_LOG="$DERIVED_DATA/maccy-local-build.log"

case "$MODE" in
  run|--build-only|--debug|--logs|--telemetry|--verify) ;;
  *)
    echo "Usage: $0 [--build-only|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

LOCAL_SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk '/"Maccy Capture Local Signing"/ {print $2; exit}')"
SIGNING_IDENTITY="${MACCY_SIGNING_IDENTITY:-$LOCAL_SIGNING_IDENTITY}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "No reusable local signing identity. Run: bash script/setup_local_signing.sh" >&2
  exit 4
fi
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Warning: ad-hoc signing is only for tests; a rebuilt app may require authorization again." >&2
fi
HARDENED_RUNTIME=YES
if [[ "$SIGNING_IDENTITY" == "$LOCAL_SIGNING_IDENTITY" ||
      "$SIGNING_IDENTITY" == "Maccy Capture Local Signing" ||
      "$SIGNING_IDENTITY" == "-" ]]; then
  HARDENED_RUNTIME=NO
fi

mkdir -p "$DERIVED_DATA"
if ! xcodebuild -project "$PROJECT_ROOT/Maccy.xcodeproj" -scheme Maccy \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=YES \
  OTHER_CODE_SIGN_FLAGS=--timestamp=none ENABLE_HARDENED_RUNTIME="$HARDENED_RUNTIME" \
  build > "$BUILD_LOG" 2>&1; then
  tail -80 "$BUILD_LOG" >&2
  exit 1
fi

codesign --verify --deep --strict "$APP_BUNDLE"
echo "Built and verified: $APP_BUNDLE"
if [[ "$MODE" == "--build-only" ]]; then
  exit 0
fi

while IFS= read -r process_id; do
  command_path="$(ps -p "$process_id" -o comm=)"
  if [[ "$command_path" == "$INSTALLED_APP/Contents/MacOS/Maccy" ||
        "$command_path" == "$APP_BUNDLE/Contents/MacOS/Maccy" ]]; then
    running_bundle="${command_path%/Contents/MacOS/Maccy}"
    osascript -e 'on run arguments' -e 'tell application (item 1 of arguments) to quit' -e 'end run' "$running_bundle"
    for attempt in {1..100}; do
      if ! kill -0 "$process_id" 2>/dev/null; then break; fi
      sleep 0.1
    done
    if kill -0 "$process_id" 2>/dev/null; then
      echo "Maccy did not quit; the installed app was not replaced." >&2
      exit 5
    fi
  else
    echo "Another copy of Maccy is running. Quit it first to avoid shortcut conflicts." >&2
    exit 3
  fi
done < <(pgrep -x Maccy || true)

if [[ -d "$INSTALLED_APP" ]]; then
  BACKUP="/private/tmp/Maccy-before-local-update-$(date +%Y%m%d-%H%M%S)-$$.app.disabled"
  ditto "$INSTALLED_APP" "$BACKUP"
  echo "Previous app backed up: $BACKUP"
fi
if ! ditto "$APP_BUNDLE" "$INSTALLED_APP" ||
   ! codesign --verify --deep --strict "$INSTALLED_APP"; then
  if [[ -n "${BACKUP:-}" ]]; then ditto "$BACKUP" "$INSTALLED_APP"; fi
  echo "Installation failed; any previous app was restored." >&2
  exit 6
fi
LAUNCH_SERVICES="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LAUNCH_SERVICES" -u "$APP_BUNDLE" || true
"$LAUNCH_SERVICES" -f "$INSTALLED_APP"

if [[ "$MODE" == "--debug" ]]; then
  exec lldb -- "$INSTALLED_APP/Contents/MacOS/Maccy"
fi

open -n "$INSTALLED_APP"
case "$MODE" in
  --logs|--telemetry)
    exec /usr/bin/log stream --level info --style compact --predicate 'process == "Maccy"'
    ;;
  --verify)
    sleep 1
    pgrep -fl "$INSTALLED_APP/Contents/MacOS/Maccy"
    ;;
esac
