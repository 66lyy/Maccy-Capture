#!/usr/bin/env bash
set -euo pipefail

: "${GH_REPO:?GH_REPO must identify the destination repository}"
: "${GITHUB_SHA:?GITHUB_SHA must identify the built commit}"
: "${MACCY_DEFAULT_BRANCH:?MACCY_DEFAULT_BRANCH must identify the default branch}"
: "${MACCY_DIST_DIR:?MACCY_DIST_DIR must identify the downloaded packages}"

if [[ "${GITHUB_ACTIONS:-}" != "true" ||
  "${GITHUB_REF:-}" != "refs/heads/$MACCY_DEFAULT_BRANCH" ||
  ( "${GITHUB_EVENT_NAME:-}" != "push" && "${GITHUB_EVENT_NAME:-}" != "workflow_dispatch" ) ]]; then
  echo "Prereleases can only be published by default-branch push or manual workflow runs." >&2
  exit 2
fi
if [[ ! "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Expected a full source commit SHA." >&2
  exit 2
fi

DIST_DIR="$(cd "$MACCY_DIST_DIR" && pwd)"
RELEASE_TAG="capture-latest"
shopt -s nullglob
ZIP_PACKAGES=("$DIST_DIR"/Maccy-Capture-*-"${GITHUB_SHA:0:12}"-universal.zip)
DMG_PACKAGES=("$DIST_DIR"/Maccy-Capture-*-"${GITHUB_SHA:0:12}"-universal.dmg)
if [[ "${#ZIP_PACKAGES[@]}" -ne 1 || "${#DMG_PACKAGES[@]}" -ne 1 ||
  ! -f "$DIST_DIR/SHA256SUMS.txt" || ! -f "$DIST_DIR/BUILD-INFO.txt" ]]; then
  echo "Expected exactly one ZIP, one DMG, checksums, and build information for the built commit." >&2
  exit 2
fi
grep -Fxq "Source revision: $GITHUB_SHA" "$DIST_DIR/BUILD-INFO.txt"
(
  cd "$DIST_DIR"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum --check SHA256SUMS.txt
  else
    shasum -a 256 -c SHA256SUMS.txt
  fi
)

NOTES_FILE="$(mktemp "${TMPDIR:-/tmp}/MaccyCaptureReleaseNotes.XXXXXX")"
trap 'rm -f "$NOTES_FILE"' EXIT
cat > "$NOTES_FILE" <<NOTES
Unofficial Maccy Capture test build based on [p0deje/Maccy](https://github.com/p0deje/Maccy).
This rolling prerelease is updated after successful default-branch builds.

- Source revision: \`$GITHUB_SHA\`
- Universal macOS application for Apple Silicon and Intel; requires macOS 14 or later.
- Download the ZIP or DMG below. The ZIP contains \`Maccy Capture.app\`.
- \`SHA256SUMS.txt\` verifies the downloads; \`BUILD-INFO.txt\` records build and signing details.
- Packages include the upstream MIT license, English and Simplified Chinese distribution notices, and third-party licenses.
- Ad-hoc signed, not Developer ID signed or notarized. Gatekeeper may block first launch, and permissions may need to be granted again.
- This is not an official upstream release or a stable production release.
NOTES

if ! gh release view "$RELEASE_TAG" --json tagName >/dev/null 2>&1; then
  gh release create "$RELEASE_TAG" \
    --target "$GITHUB_SHA" \
    --title "Latest test build" \
    --notes-file "$NOTES_FILE" \
    --prerelease \
    --draft
fi

gh release upload "$RELEASE_TAG" \
  "${ZIP_PACKAGES[0]}" "${DMG_PACKAGES[0]}" \
  "$DIST_DIR/SHA256SUMS.txt" "$DIST_DIR/BUILD-INFO.txt" \
  --clobber

ASSET_NAMES="$(gh release view "$RELEASE_TAG" --json assets --jq '.assets[].name')"
while IFS= read -r asset_name; do
  case "$asset_name" in
    Maccy-Capture-*-universal.zip|Maccy-Capture-*-universal.dmg)
      if [[ ! -f "$DIST_DIR/$asset_name" ]]; then
        gh release delete-asset "$RELEASE_TAG" "$asset_name" --yes
      fi
      ;;
  esac
done <<< "$ASSET_NAMES"

if gh api "repos/$GH_REPO/git/ref/tags/$RELEASE_TAG" >/dev/null 2>&1; then
  gh api --method PATCH "repos/$GH_REPO/git/refs/tags/$RELEASE_TAG" \
    -f sha="$GITHUB_SHA" -F force=true >/dev/null
else
  gh api --method POST "repos/$GH_REPO/git/refs" \
    -f ref="refs/tags/$RELEASE_TAG" -f sha="$GITHUB_SHA" >/dev/null
fi

gh release edit "$RELEASE_TAG" \
  --title "Latest test build" \
  --notes-file "$NOTES_FILE" \
  --prerelease \
  --draft=false
gh release view "$RELEASE_TAG" --json url --jq '.url'
