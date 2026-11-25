#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${GH_REPO:?GH_REPO must identify the destination repository}"
: "${MACCY_DEFAULT_BRANCH:?MACCY_DEFAULT_BRANCH must identify the default branch}"
: "${MACCY_RELEASE_TAG:?MACCY_RELEASE_TAG must name the stable release tag}"

if [[ "${GITHUB_ACTIONS:-}" != "true" ]] || ! {
  [[ "${GITHUB_EVENT_NAME:-}" == "push" && "${GITHUB_REF:-}" == "refs/tags/$MACCY_RELEASE_TAG" ]] ||
  [[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" && "${GITHUB_REF:-}" == "refs/heads/$MACCY_DEFAULT_BRANCH" ]]
}; then
  echo "Stable releases require a matching tag push or a manual run on the default branch." >&2
  exit 2
fi
if [[ ! "$MACCY_RELEASE_TAG" =~ ^maccy-capture-v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  echo "Expected a tag like maccy-capture-v1.2.3." >&2
  exit 2
fi
VERSION="${BASH_REMATCH[1]}"
NOTES="$SCRIPT_DIR/../docs/releases/$VERSION.md"
if [[ ! -s "$NOTES" ]]; then
  echo "Missing release notes docs/releases/$VERSION.md." >&2
  exit 2
fi
if gh api "repos/$GH_REPO/releases/tags/$MACCY_RELEASE_TAG" >/dev/null 2>&1; then
  echo "A release for $MACCY_RELEASE_TAG already exists." >&2
  exit 2
fi

# Only a manual run may tag the default branch head.
if SHA="$(gh api "repos/$GH_REPO/commits/tags/$MACCY_RELEASE_TAG" --jq .sha 2>/dev/null)"; then
  TARGET=(--verify-tag)
elif [[ "$GITHUB_EVENT_NAME" == "workflow_dispatch" ]]; then
  SHA="$(gh api "repos/$GH_REPO/commits/heads/$MACCY_DEFAULT_BRANCH" --jq .sha)"
  TARGET=(--target "$SHA")
else
  echo "Could not resolve the release tag $MACCY_RELEASE_TAG." >&2
  exit 2
fi
if [[ ! "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Could not resolve the release commit." >&2
  exit 2
fi
STATUS="$(gh api "repos/$GH_REPO/compare/$SHA...$MACCY_DEFAULT_BRANCH" --jq .status)"
if [[ "$STATUS" != "identical" && "$STATUS" != "ahead" ]]; then
  echo "$SHA is not on $MACCY_DEFAULT_BRANCH." >&2
  exit 2
fi

RUNS_URL="repos/$GH_REPO/actions/workflows/build-capture.yml/runs?branch=$MACCY_DEFAULT_BRANCH&event=push&head_sha=$SHA&per_page=100"
for ((attempt = 1; ; attempt++)); do
  if ! run="$(gh api "$RUNS_URL" --jq '.workflow_runs | (map(select(.conclusion == "success"))[0] // .[0] // empty) | [.id, .run_number, .status, (.conclusion // "-")] | @tsv')"; then
    echo "Could not query build-capture for $SHA (attempt $attempt)." >&2
  elif [[ -z "$run" ]]; then
    echo "Waiting for the $MACCY_DEFAULT_BRANCH push build of $SHA to appear (attempt $attempt)." >&2
  else
    read -r RUN_ID RUN_NUMBER status conclusion <<< "$run"
    if [[ ! "$RUN_ID" =~ ^[0-9]+$ || ! "$RUN_NUMBER" =~ ^[0-9]+$ ]]; then
      echo "Invalid build-capture run identifiers for $SHA." >&2
      exit 2
    fi
    if [[ "$status" == completed ]]; then
      if [[ "$conclusion" == success ]]; then break; fi
      echo "Build-capture run $RUN_ID for $SHA finished with $conclusion; not publishing." >&2
      exit 2
    fi
    echo "Waiting for build-capture run $RUN_ID ($status, attempt $attempt)." >&2
  fi
  if (( attempt == 66 )); then
    echo "Timed out waiting for a successful push build of $SHA on $MACCY_DEFAULT_BRANCH." >&2
    exit 2
  fi
  sleep 60
done

WORK_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/MaccyCapture-stable.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
DIST_DIR="$WORK_DIR/packages"
ARTIFACT="Maccy-Capture-macOS-universal-$RUN_NUMBER"
for ((attempt = 1; ; attempt++)); do
  if gh run download "$RUN_ID" -n "$ARTIFACT" -D "$DIST_DIR"; then break; fi
  if (( attempt == 6 )); then
    echo "Could not download $ARTIFACT from run $RUN_ID after $attempt attempts; not publishing." >&2
    exit 2
  fi
  echo "Retrying download of $ARTIFACT from run $RUN_ID in 30 seconds (attempt $attempt failed)." >&2
  rm -rf "$DIST_DIR"
  sleep 30
done
cd "$DIST_DIR"
sha256sum --check SHA256SUMS.txt
grep -Fxq "Source revision: $SHA" BUILD-INFO.txt
grep -Fxq "Version: $VERSION" BUILD-INFO.txt
shopt -s nullglob
ZIPS=(Maccy-Capture-"$VERSION"-*-"${SHA:0:12}"-universal.zip)
DMGS=(Maccy-Capture-"$VERSION"-*-"${SHA:0:12}"-universal.dmg)
if [[ "${#ZIPS[@]}" -ne 1 || "${#DMGS[@]}" -ne 1 ]]; then
  echo "Expected one ZIP and one DMG for $VERSION at $SHA." >&2
  exit 2
fi
ZIP="${ZIPS[0]}"
DMG="${DMGS[0]}"
if [[ "$(jq -r .sourceRevision UPDATE-METADATA.json)" != "$SHA" ||
  "$(jq -r .filename UPDATE-METADATA.json)" != "$ZIP" ]]; then
  echo "Update metadata does not match the archive." >&2
  exit 2
fi

gh release create "$MACCY_RELEASE_TAG" --draft "${TARGET[@]}" --title "Maccy Capture $VERSION" \
  --notes-file "$NOTES" "$ZIP" "$DMG" BUILD-INFO.txt UPDATE-METADATA.json
ASSET_ID="$(gh release view "$MACCY_RELEASE_TAG" --json assets \
  --jq ".assets[] | select(.name == \"$ZIP\") | .apiUrl" | sed 's#.*/##')"
if [[ ! "$ASSET_ID" =~ ^[0-9]+$ ]]; then
  echo "Could not resolve the uploaded update archive." >&2
  exit 2
fi
python3 "$SCRIPT_DIR/generate_update_feed.py" appcast \
  --metadata UPDATE-METADATA.json --repository "$GH_REPO" \
  --asset-id "$ASSET_ID" --archive "$ZIP" --output capture-appcast.xml
sha256sum "$ZIP" "$DMG" BUILD-INFO.txt UPDATE-METADATA.json capture-appcast.xml > SHA256SUMS.txt
gh release upload "$MACCY_RELEASE_TAG" capture-appcast.xml SHA256SUMS.txt
gh release edit "$MACCY_RELEASE_TAG" --draft=false --latest
gh release view "$MACCY_RELEASE_TAG" --json url --jq .url
