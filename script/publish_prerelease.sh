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
  ! -f "$DIST_DIR/SHA256SUMS.txt" || ! -f "$DIST_DIR/BUILD-INFO.txt" ||
  ! -f "$DIST_DIR/UPDATE-METADATA.json" ]]; then
  echo "Expected ZIP, DMG, checksums, build information and signed update metadata." >&2
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
- In-app updates use this repository's \`capture-appcast.xml\` and independently Ed25519-signed ZIP.
- Install Update restarts the running modified app so the update takes effect immediately.
- Private repositories require a repository-limited Contents: Read-only token saved only in the client's Keychain.
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
  "$DIST_DIR/BUILD-INFO.txt" "$DIST_DIR/UPDATE-METADATA.json" \
  --clobber

ZIP_NAME="$(basename "${ZIP_PACKAGES[0]}")"
ASSET_ID="$(gh api "repos/$GH_REPO/releases/tags/$RELEASE_TAG" \
  --jq ".assets[] | select(.name == \"$ZIP_NAME\") | .id")"
if [[ ! "$ASSET_ID" =~ ^[0-9]+$ ]]; then
  echo "Could not resolve the uploaded update archive." >&2
  exit 2
fi
python3 "$(dirname "${BASH_SOURCE[0]}")/generate_update_feed.py" appcast \
  --metadata "$DIST_DIR/UPDATE-METADATA.json" --repository "$GH_REPO" \
  --asset-id "$ASSET_ID" --archive "${ZIP_PACKAGES[0]}" --output "$DIST_DIR/capture-appcast.xml"
(
  cd "$DIST_DIR"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$ZIP_NAME" "$(basename "${DMG_PACKAGES[0]}")" \
      BUILD-INFO.txt UPDATE-METADATA.json capture-appcast.xml > SHA256SUMS.txt
  else
    shasum -a 256 "$ZIP_NAME" "$(basename "${DMG_PACKAGES[0]}")" \
      BUILD-INFO.txt UPDATE-METADATA.json capture-appcast.xml > SHA256SUMS.txt
  fi
)
gh release upload "$RELEASE_TAG" "$DIST_DIR/SHA256SUMS.txt" --clobber
gh release upload "$RELEASE_TAG" "$DIST_DIR/capture-appcast.xml" --clobber

STALE_ASSETS="$(gh api "repos/$GH_REPO/releases/tags/$RELEASE_TAG" --jq \
  '[.assets[] | select(.name | test("^Maccy-Capture-.*-universal\\.(zip|dmg)$"))]
  | sort_by(.created_at) | reverse | .[6:][] | .name')"
while IFS= read -r asset_name; do
  if [[ -n "$asset_name" && ! -f "$DIST_DIR/$asset_name" ]]; then
    gh release delete-asset "$RELEASE_TAG" "$asset_name" --yes
  fi
done <<< "$STALE_ASSETS"

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
