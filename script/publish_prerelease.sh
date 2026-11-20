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
## English

Unofficial Maccy Capture test build based on [p0deje/Maccy](https://github.com/p0deje/Maccy).
This is a test build of commit \`${GITHUB_SHA:0:12}\`.

- Source revision and changes: [\`${GITHUB_SHA:0:12}\`](https://github.com/$GH_REPO/commit/$GITHUB_SHA).
- Universal macOS application for Apple Silicon and Intel; requires macOS 14 or later.
- Download the ZIP or DMG below, extract or open it, and move \`Maccy Capture.app\` to Applications.
- \`SHA256SUMS.txt\` verifies the downloads; \`BUILD-INFO.txt\` records build and signing details.
- In-app updates use this repository's \`capture-appcast.xml\` and independently Ed25519-signed ZIP.
- Install Update restarts the running modified app so the update takes effect immediately.
- Packages include the upstream MIT license, English and Simplified Chinese distribution notices, and third-party licenses.
- Ad-hoc signed, not Developer ID signed or notarized. Gatekeeper may block first launch, and permissions may need to be granted again.
- This is not an official upstream release or a stable production release.

## 简体中文

这是基于 [p0deje/Maccy](https://github.com/p0deje/Maccy) 的 Maccy Capture 非官方测试版。
这是提交 \`${GITHUB_SHA:0:12}\` 的测试构建。

- 源码版本与变更：[\`${GITHUB_SHA:0:12}\`](https://github.com/$GH_REPO/commit/$GITHUB_SHA)。
- 通用版支持 Apple 芯片和 Intel Mac，要求 macOS 14 或更高版本。
- 下载下方 ZIP 或 DMG，解压或打开后，将 \`Maccy Capture.app\` 移到「应用程序」。
- 使用 \`SHA256SUMS.txt\` 校验下载；\`BUILD-INFO.txt\` 记录构建和签名信息。
- 应用内更新使用本仓库的 \`capture-appcast.xml\` 和独立 Ed25519 签名的 ZIP。
- 安装更新后会重启正在运行的修改版，让更新立即生效。
- 安装包包含上游 MIT 许可证、英中分发说明及第三方许可证。
- 应用采用 Ad Hoc 签名，未使用 Developer ID 签名，也未通过 Apple 公证。首次启动可能被安全机制拦截，部分权限可能需要重新授权。
- 这不是上游官方版本，也不是稳定版。
NOTES

upload_immutable_asset() {
  local tag="$1" file="$2" name state digest expected
  name="$(basename "$file")"
  state="$(jq -r --arg name "$name" '.assets[] | select(.name == $name) | .state' <<< "$RELEASE")"
  case "$state" in
    "")
      ;;
    starter)
      gh release delete-asset "$tag" "$name" --yes
      ;;
    uploaded)
      digest="$(jq -r --arg name "$name" '.assets[] | select(.name == $name) | .digest' <<< "$RELEASE")"
      expected="sha256:$(python3 -c 'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "$file")"
      if [[ "$digest" == "$expected" ]]; then
        return
      fi
      echo "Published asset does not match $name; refusing to replace it." >&2
      return 2
      ;;
    *)
      echo "Unexpected upload state for $name." >&2
      return 2
      ;;
  esac
  gh release upload "$tag" "$file"
}

SHORT_VERSION="$(jq -r '.shortVersion' "$DIST_DIR/UPDATE-METADATA.json")"
BUILD_VERSION="$(jq -r '.version' "$DIST_DIR/UPDATE-METADATA.json")"
if [[ ! "$SHORT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ||
  ! "$BUILD_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "Expected numeric release and build versions." >&2
  exit 2
fi
RELEASE_TAG="maccy-capture-v$SHORT_VERSION-build$BUILD_VERSION"
TITLE="Maccy Capture $SHORT_VERSION test build $BUILD_VERSION"
PREVIOUS_TAG="$(gh api "repos/$GH_REPO/releases?per_page=30" | jq -r --arg tag "$RELEASE_TAG" \
  '[.[] | select(.draft == false and (.tag_name | startswith("maccy-capture-v")) and .tag_name != $tag)] | max_by(.published_at) | .tag_name // empty')"
printf '\n## Changes / 更新内容\n\n' >> "$NOTES_FILE"
COMPARE=''
if [[ -n "$PREVIOUS_TAG" ]]; then
  COMPARE="$(gh api "repos/$GH_REPO/compare/$PREVIOUS_TAG...$GITHUB_SHA" 2>/dev/null || true)"
fi
python3 - "$GH_REPO" "$GITHUB_SHA" "$PREVIOUS_TAG" "$COMPARE" >> "$NOTES_FILE" <<'PY'
import json, subprocess, sys
repo, revision, previous, comparison = sys.argv[1:]
try:
    commits = [c for c in json.loads(comparison)['commits'] if len(c['parents']) < 2][::-1]
except (ValueError, KeyError, TypeError):
    commits = []
if not commits:
    subject = subprocess.check_output(['git', 'show', '-s', '--format=%s', revision], text=True).strip()
    commits = [{'sha': revision, 'commit': {'message': subject}}]
for commit in commits[:50]:
    sha = commit['sha']
    subject = commit['commit']['message'].splitlines()[0]
    print(f'- {subject} ([`{sha[:12]}`](https://github.com/{repo}/commit/{sha}))')
if len(commits) > 50:
    print(f'- [and {len(commits) - 50} more / 更多更新](https://github.com/{repo}/compare/{previous}...{revision})')
PY

if ! gh release view "$RELEASE_TAG" --json tagName >/dev/null 2>&1; then
  gh release create "$RELEASE_TAG" --target "$GITHUB_SHA" --title "$TITLE" \
    --notes-file "$NOTES_FILE" --draft --prerelease --latest=false
fi
RELEASE_API="$(gh release view "$RELEASE_TAG" --json apiUrl --jq .apiUrl)"
RELEASE="$(gh api "$RELEASE_API")"
upload_immutable_asset "$RELEASE_TAG" "${ZIP_PACKAGES[0]}"
upload_immutable_asset "$RELEASE_TAG" "${DMG_PACKAGES[0]}"
RELEASE="$(gh api "$RELEASE_API")"
ZIP_NAME="$(basename "${ZIP_PACKAGES[0]}")"
ASSET_ID="$(jq -r --arg name "$ZIP_NAME" '.assets[] | select(.name == $name and .state == "uploaded") | .id' <<< "$RELEASE")"
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
for name in BUILD-INFO.txt UPDATE-METADATA.json capture-appcast.xml SHA256SUMS.txt; do
  upload_immutable_asset "$RELEASE_TAG" "$DIST_DIR/$name"
done
gh release edit "$RELEASE_TAG" --title "$TITLE" --notes-file "$NOTES_FILE" \
  --draft=false --prerelease --latest=false
gh release view "$RELEASE_TAG" --json url --jq '.url'
