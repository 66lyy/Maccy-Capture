# Capture, Pinning, and Local Development

**English** | [简体中文](SCREENSHOT-DEVELOPMENT.zh-CN.md)

## Language and Shortcuts

The Language option at the top of Settings → General supports System Default,
Simplified Chinese, English, Traditional Chinese, and the other translations included in the app.
The selection is saved only in this version's own `AppleLanguages` preference.
It does not change the macOS language or the original Maccy's settings.
Language names appear in their native scripts so you can switch back from an unfamiliar language.
After making a selection, click Restart to Apply to update menus, settings, and capture messages.
This internal restart preserves clipboard history but closes temporary pinned images held only in memory.

Settings → Shortcuts lets you customize shortcuts for opening the history, pinning and
deleting history items, toggling the preview, capturing the main display,
capturing a region, capturing and pinning, and pinning a clipboard image.
Each row has a shortcut recorder; run capture actions from the Capture menu instead.
Click anywhere on an in-window group header to expand it and change keys for selection, annotation,
and pinned images. When recording a shortcut or restoring its default, only that combination is
checked against assignments in overlapping contexts, app menu shortcuts, and known macOS shortcuts.
This does not detect every third-party shortcut.
Pinning a clipboard image has no shortcut by default; assign one if needed.
Quit the original Maccy before running this version to avoid competing shortcuts.
At startup, this version checks whether another copy is running and exits with a message
if it detects one, without clearing history.

The Capture menu at the bottom of the history list provides the same four actions,
with crop, display, pin, and image icons.
The history panel, settings window, selection notices, preview controls, annotation, and OCR panels
use Liquid Glass on macOS 26 or newer, with frosted material on earlier releases. Settings use
glass surfaces over a softly coloured window backdrop so the desktop does not show through the text.
Settings use solid surfaces if Reduce Transparency is enabled. The sidebar stays visible while the
detail pane scrolls. Ignore shows full category names and a compact message for empty rule lists.
Clipboard and capture shortcuts use the same
single-column layout with right-aligned recorders. Glass does not alter the pinned image itself or exported pixels.

## Capture Previews and Region Selection

Main-display capture opens inline annotation directly; ordinary region capture first lets you adjust the box.
The captured image stays at its original screen position, with a compact floating tool strip beside it,
instead of opening a separate titled editor. Nothing is copied or added to history until you confirm
Copy or Pin. Cancel discards the new capture.

After confirming Copy, a compact preview of the
actual image appears in the lower-right corner of the target display, up to 220 × 150 points.
It includes small close, annotation, and pin buttons instead of a large text notification.
The preview does not take keyboard focus and disappears after 2 seconds, even while hovered.
Click its pin button to keep the image on screen.
Capture and Pin creates a pinned image directly, without an additional preview.
Starting another capture first closes the old preview so it is not included in the next screenshot.
Previews are held only in memory.
The success sound can be disabled in General settings; canceled and failed captures do not play it.

Region capture uses the app's own crosshair and selection overlay.
After releasing the mouse, drag inside the box to move it or drag a corner to resize.
Arrow keys move the pointer before selection, or the box after selection, by one screen point;
hold Shift to move by ten. Hold Option over a window to preview its bounds;
with Accessibility permission, Option-Tab moves to a parent and Option-Shift-Tab returns to a finer hovered element.
Click the highlighted element to select it. Apps without accessible elements fall back to their window.
Releasing the selection shows drawing, undo/redo, OCR, Cancel, Copy, Pin, and Save PNG on one toolbar.
Click a drawing tool to start in the same selection, or press E to select the arrow.
Move or resize the selection before choosing a tool.
Press Enter or ⌘C to copy, P to pin, or ⌘S to save; press Esc or ⌘W to cancel.
Right-click cancels; while entering text, Esc first discards that text.
The toolbar is placed below the image when space allows, above it near the screen edge,
or inside the available display area for full-screen captures. It is never part of the exported PNG.
Drag its grip or empty background to move it away from content you want to annotate.
The Capture and Pin shortcut captures and pins immediately when you release the mouse.

Editing, OCR, or saving captures the selected region in memory with ScreenCaptureKit, excluding the selection windows.
When copying or pinning directly without editing, the app first closes all selection windows, waits 120 milliseconds,
then silently captures the selected rectangle with `/usr/sbin/screencapture -R... -x`.
Neither path launches the system's interactive screenshot interface.
Each display uses its Core Graphics coordinates, including secondary displays above or to the left
of the main display. Only one capture can run at a time.
An unfinished selection expires after 120 seconds; once the editing image is ready, that timer stops.
Quitting terminates the task.
Only the temporary selection windows use the Core Graphics overlay level to appear above system search and
other floating panels without activating the app. They can participate in other apps' full-screen Spaces
and Stage Manager sets. Keyboard focus goes to the display under the pointer, falling back to the first display.
The windows draw only a 12% shadow outside the selection and use neither the screen-saver level nor an opaque background.
All selection windows close on completion, cancellation, timeout, display changes, Space changes, or app exit.

Captures are temporarily stored locally in a directory with `0700` permissions.
Temporary files are cleaned up on completion, cancellation, and failure.
Successful capture output is copied to the clipboard and saved to local Maccy history.
If the history write fails after the clipboard succeeds, the preview or pinned image still appears,
and the app warns about the history write error. Pinned windows keep their images only in memory.
Images and recognized text are not sent to network services.

## Pinned Images and Zoom

Pinned images support dragging, mouse-wheel zoom, and two-finger trackpad pinch gestures,
without zoom buttons.
Scrolling up enlarges the image and scrolling down reduces it, regardless of Natural Scrolling.
Precise scrolling has reduced sensitivity, and momentum scrolling is ignored
so zoom stops when you lift your fingers.
Only the image under the pointer receives these events; no global event monitor or extra permission is used.

Zoom preserves the aspect ratio and tries to keep the pointer position fixed.
Near a display edge, the image is repositioned to keep it fully visible.
Its maximum size is limited by both five times the original logical image size
and the current display's visible area.
Zoom changes only the display size; it does not resample the source image or rewrite the clipboard.
Pinned images retain right-click Copy, a close button, double-click to close,
and Esc / ⌘W to close or ⌘C to copy when the window has keyboard focus.
The initial pinned size also fits within the current display's visible area.

This local version currently does not enable App Sandbox because its capture backend launches
the system `screencapture` tool.
This does not mean global shortcuts require the sandbox to be disabled;
there was no evidence for the earlier assumption that sandboxing caused shortcut failures.
An App Store version would need a separate sandbox-compatible capture backend.

## Build Locally

```sh
bash script/setup_local_signing.sh
./script/build_and_run.sh --build-only
```

The signing setup creates a reusable self-signed identity named `Maccy Capture Local Signing`
in the login keychain. It is trusted only for code signing by the current user,
not for website trust or public distribution. Its private key is not uploaded.
Subsequent builds reuse this identity rather than defaulting to a new ad-hoc signature.
The upstream author's private key is not needed.
To use your own existing developer identity, set `MACCY_SIGNING_IDENTITY`.
Use `MACCY_SIGNING_IDENTITY=-` only for temporary tests, not everyday installed builds.

A local self-signed identity has no Apple Team ID and cannot satisfy Hardened Runtime's
same-team library validation.
The script therefore disables Hardened Runtime only for local self-signed and ad-hoc debug builds.
The project's distribution settings are unchanged; builds signed with an Apple developer identity
retain Hardened Runtime.
Local self-signing is not Developer ID signing or notarization.

Build output:
`/private/tmp/MaccyDerivedData/Build/Products/Debug/Maccy.app`.
Override the build directory with `MACCY_DERIVED_DATA`.
Running the build script without `--build-only` builds the app, backs up the old modified version,
installs it at `/Applications/Maccy Capture.app`, and launches it from that fixed path.
Set `MACCY_INSTALL_BUNDLE` to override the install path for local debugging.
Use `--build-only` to leave the installed app untouched, and use **Check Now** in the app's
software update settings for routine updates.
It does not modify `/Applications/Maccy.app`.
If another Maccy is running from a different path, the script asks you to quit it
instead of running two versions together.

## GitHub Actions Packaging

The workflow is `.github/workflows/build-capture.yml`.
It runs on pushes to `master` / `main`, `capture-v*` tags, pull requests, and manual dispatch.
The build job has read-only source permissions.
After a successful default-branch build, a separate publishing job updates the
`capture-latest` prerelease. Only that publishing job can write repository contents.
Pull requests never publish. In-app updates require the release to be publicly accessible.

Branch pushes and pull requests that change only Markdown, `docs/`, `LICENSE`,
issue or pull request templates, `.gitignore`, or `.gitattributes` do not trigger builds.
Changes that also affect code still trigger a build.
Version tags and manual dispatch are not subject to this documentation filter.

The pipeline uses Xcode 26.6 on GitHub's hosted `macos-26` runner.
It first runs the six regression suites listed below using generated images and simulated input,
without accessing the developer's desktop, clipboard, history, or keychain.
On this runner, Apple Swift 6.3.3's Release optimizer has been observed to crash
in the upstream `FloatingPanel` deinitializer on both `arm64` and `x86_64`.
Only when that compiler version is detected, the packaging script passes `-Onone`
for both architectures.
Other compiler versions retain the project's default optimization settings.
This workaround may reduce application performance and is recorded in the build information.
It does not remove features, change window lifecycles, or weaken permission checks.

After tests pass, `script/package_release.sh` builds a universal Release application
and verifies its signature, modified bundle identifier, and `arm64` / `x86_64` architectures.
It produces:

- `Maccy-Capture-VERSION-buildBUILD-REVISION-universal.zip`: `Maccy Capture.app` and license files.
- A matching `.dmg`: the app, an Applications shortcut, and license files.
- `SHA256SUMS.txt`: SHA-256 checksums for both packages and the build information.
- `BUILD-INFO.txt`: version, source revision, architectures, and signing limitations.
- `UPDATE-METADATA.json`: archive length, SHA-256, build version, and public Ed25519 signature
  for default-branch updates; never a signing secret.

The ZIP, DMG, and app itself retain the original upstream `LICENSE`,
`DISTRIBUTION-NOTICE.md` in English, `DISTRIBUTION-NOTICE.zh-CN.md` in Simplified Chinese,
and the third-party license directory.
Packaging checks each locked dependency and fails if its checkout or full license text is missing,
rather than silently omitting it.
Source records include dependency repositories and locked revisions.
After copying these resources, the staged app is re-signed and verified.
The packages do not include private keys, and packaging does not modify the installed app.

Successful artifacts are retained for 14 days and failure diagnostics for 7 days.
Successful default-branch builds also update Releases → Latest test build (`capture-latest`)
with the ZIP, DMG, `SHA256SUMS.txt`, and `BUILD-INFO.txt`.
The `capture-appcast.xml` update feed is activated only after the signed ZIP and supporting files upload.
The newest three ZIP/DMG pairs are retained for in-flight updates.
Promote a verified default-branch build to stable by creating a separate draft Release with a
`maccy-capture-vMAJOR.MINOR.PATCH` tag at its source commit. Upload the unchanged signed ZIP and DMG
with their build information and update metadata. Use `script/generate_update_feed.py appcast`
with the **stable Release's ZIP asset ID**, not the preview asset ID, and upload the new appcast and
checksums before publishing as Latest (not a prerelease). Default-branch builds never replace that release.

Open Actions → Build Maccy Capture in this repository to view runs and download artifacts;
select Run workflow to build manually.
Manual builds on the default branch also update the test release;
other branches, version tags, and pull requests provide artifacts only.
Private-repository macOS builds may count against GitHub Actions usage;
consult your account's current limits and billing settings.

Default-branch packages reuse the configured CI-only self-signed certificate, with a designated requirement
that matches the bundle identifier and certificate fingerprint. Other CI artifacts and local
packages are ad-hoc signed. Neither signature is Developer ID signing or notarization.
The first update from an older signing identity can require granting permissions again.

To enable fixed signing for published builds, authenticate GitHub CLI as a repository administrator
and run `bash script/setup_release_signing.sh OWNER/REPO`. It configures the
`MACCY_RELEASE_SIGNING_IDENTITY` repository Actions Secret without using the local development certificate.
Keep the backup file printed by the script offline and private: it contains the release signing key.
Reuse this identity for both preview and stable packages; replacing it changes the identity
that macOS uses to recognize the app. A missing secret warns in CI and publishes an ad-hoc build;
an invalid configured secret fails the build. Only release packaging gets this secret; it is not passed to Xcode,
tests, pull requests, or package artifacts.

`SPARKLE_PRIVATE_KEY` is separate and used only to authenticate update archives after packaging.
Public distribution requires your own Developer ID signing, notarization, and credential management;
do not use the upstream author's certificate or upload local private keys to impersonate an official build.

To create downloadable packages locally without installing or restarting the app:

```sh
bash script/package_release.sh
```

Output defaults to `dist/` within the source directory, with intermediates in `build/ReleaseDerivedData/`.
Override these with `MACCY_DIST_DIR` and `MACCY_DERIVED_DATA`.
Dependencies are locked in `Maccy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Third-party GitHub Actions are pinned to verified full commit hashes.
`.codex/`, build output, environment files, and common certificate or private-key formats
are excluded by `.gitignore`.
Do not commit real screenshots, clipboard databases, personal information, or signing materials.

## Application Identity and Permissions

This version appears as `Maccy Capture` and uses the separate bundle identifier `local.maccy.capture`.
It avoids sharing the original identifier, which could cause macOS to relaunch the wrong application.
On first launch, the app locally migrates upstream preferences without overwriting existing
preferences in this version or deleting the originals.
History continues to use the existing local Maccy database.
The official automatic updater remains disabled; the separate repository updater cannot install
official releases over customized features.

## Repository Updates

`SoftwareUpdater` is a single application-lifetime Sparkle controller started after normal launch.
The application's own preference controls a single automatic check at launch. Manual checks remain available.
Each check anonymously resolves the configured channel. Stable (default) accepts only a published
`maccy-capture-vMAJOR.MINOR.PATCH` release from GitHub's Latest Release endpoint; Preview accepts
only the rolling `capture-latest` prerelease. Channel changes do not downgrade the app.
Each check confirms `capture-appcast.xml` exists and loads it from the public download URL.
The attachment ID varies the download URL when a new release replaces the file, avoiding a stale cached redirect.
Sparkle requests RSS; the GitHub asset API can respond with JSON instead of the file to that request.
Background discovery is skipped during capture or annotation; repeated checks cannot overlap.
Sparkle's independent scheduler and automatic installation-on-quit are disabled.
The user confirms installation, which then restarts the running host bundle at its existing path.
That restart bypasses Clear History on Quit, just like the existing internal restart.
Temporary pins and unsaved annotations do not survive restart.

Repository discovery refuses redirects; Sparkle's archive URLs must exactly match asset IDs and lengths
from the resolved repository release. External release notes and system profiling are disabled.
An unavailable or invalid release, mismatched package, or signature failure leaves the existing app intact.

The update archive is signed after all packaging modifications with a dedicated Ed25519 key.
`SUPublicEDKey` is committed in the app's Info.plist, and `SUVerifyUpdateBeforeExtraction` is enabled.
The signing script independently verifies the signature with that pinned public key before publishing.
The local update key uses Sparkle Keychain account `local.maccy.capture.updates`;
only this dedicated key is also stored as the repository's `SPARKLE_PRIVATE_KEY` Actions Secret.
Do not rotate it casually: already-installed clients trust the original public key.
The existing `Maccy Capture Local Signing` certificate and private key stay on the local Mac.
Update authentication is separate from application code signing and notarization.

CI assigns `CFBundleVersion` as `1000 + GITHUB_RUN_NUMBER`, followed by the run attempt.
For example `1042.1` and `1042.2` are different upgradable builds even when the marketing version remains `2.8.0`.
Local developer builds default to build `1000`; `MACCY_BUILD_VERSION` can override packaged build numbers.
Keep the workflow's build counter monotonic; do not reset it or reuse the same version for different archives.
The unsigned legacy upstream `appcast.xml` is not used by this modified app.
Clients without the new updater need one manual installation before subsequent in-app upgrades.

After the bundle identifier changes, grant screen recording and any required accessibility permissions
to `Maccy Capture` again.
The app actively requests screen recording permission at most once per process.
The first request is not immediately followed by the app's own permission explanation.
The settings prompt appears only on a later capture attempt if permission is still unavailable.
Restart This Version waits for the current process to exit and then launches the current app's full path,
not an app found by name or by the upstream identifier.
An internal restart does not run Clear History on Quit.
A persistent local signature cannot guarantee that macOS will never request permission again;
system policy, signature changes, and installation paths still require real-device validation.

## Regression Tests

```sh
xcodebuild -project Maccy.xcodeproj -scheme Maccy -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/MaccyCaptureAgentTests \
  -only-testing:MaccyTests/AppIdentityTests \
  -only-testing:MaccyTests/SoftwareUpdaterTests \
  -only-testing:MaccyTests/AppLanguageTests \
  -only-testing:MaccyTests/ScreenshotCaptureTests \
  -only-testing:MaccyTests/ScreenshotAnnotationTests \
  -only-testing:MaccyTests/ScreenshotSelectionTests -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=YES \
  ENABLE_HARDENED_RUNTIME=NO test
```

Tests use generated PNGs and simulated processes to cover cancellation, launch failures, invalid files,
temporary directory permissions and cleanup, timeouts, unresponsive processes, repeated triggers,
task cancellation, negative-coordinate displays, and pinned-window cleanup.
They do not start a real capture or read or modify the user's clipboard.

Zoom tests use generated images, simulated wheel and pinch events, and virtual display rectangles.
They cover actual image-view event forwarding, Natural Scrolling, zoom anchors, aspect ratios,
size limits, negative coordinates, extreme aspect ratios, and rejection of momentum or invalid input.
They do not show test windows, send global input events, or read the desktop.
Real trackpad behavior still needs manual verification.

Preview tests cover the default 2-second timeout, actual image binding, pin callbacks,
non-activating windows, and multiple-display bounds.
Selection tests use virtual displays and injected callbacks without showing windows.
They cover moving and resizing, coordinate conversion, inline annotation and immediate pinning on mouse release,
keyboard actions, empty selections, repeated triggers, cancellation, timeouts,
and cleanup after display changes, without reading the desktop.
Identity and permission tests use simulated authorization callbacks and an isolated preference domain.
They cover request deduplication, reentrancy, externally granted permissions, preference migration,
the separate identifier, disabled official updates, and full-path restart arguments.

Tests use ad-hoc signing in a separate Derived Data directory.
They do not overwrite the daily build's signature or replace or restart the installed app.
These tests do not replace real-machine checks for screen recording permissions,
shortcut conflicts, and selection interactions.

## Image Annotation

All annotation entry points use a borderless in-place overlay, not a separate editor window:

- Choose a drawing tool right beside the selected region, or capture the main display.
  Region editing keeps the original selection window and the toolbar in place.
  The original remains in memory without first entering the clipboard or history.
- Click the pencil button in the 2-second preview after copying. The inline overlay opens and the preview closes
  immediately; its original automatic timeout is not extended.
- Right-click a pinned image and choose Annotate…, or press ⌘E while it has keyboard focus.
  Edit over that image's current screen rectangle and apply changes back to the same pin.
  Only one annotation session is allowed at a time; repeated capture shortcuts bring it forward.

Tools include arrows, rectangles, ellipses, a freehand brush, single-line text,
and opaque solid-color covers.
The toolbar and OCR results use native Liquid Glass on macOS 26 or later and frosted material on earlier versions.
Both follow the system appearance. Dividers separate drawing, undo/redo, and output
actions, and the active tool uses the system accent color. The toolbar still wraps on narrower displays.
Click a swatch or open the adjacent color picker to set the color for new marks, including covers. Drag the size slider
to adjust stroke width (1–40 pt) or, with the text tool selected, font size (10–120 pt).
Click to enter text, press Enter to confirm, then drag the text with the text tool to move it.
Esc cancels the current input or drag, and a completed move can be undone or redone.
Undo and redo support ⌘Z / ⇧⌘Z.
Line width and text size are chosen relative to the displayed canvas,
while annotations are stored in original-image pixel coordinates.
The image keeps its capture rectangle and native aspect ratio; there is no independently resizable editor.
Export retains the original pixel resolution regardless of the screen's backing scale.
The compact toolbar groups drawing tools on the left and output actions on the right, with a second
row for the palette and the contextual size slider.
Narrow displays wrap the controls; display-configuration changes close the overlay without exporting.

Copy and Finish writes only the flattened PNG to the local clipboard and history;
when editing a pinned image, it also updates that image.
For a new capture, Pin to Screen exports the flattened image, adds it to local history,
and creates a pinned image.
For an existing pinned image, Apply to Current Pin updates only that image in memory
without overwriting the clipboard.
Save PNG opens a local save panel; ⌘S is also supported.
Canceling the save does not close the editor.
Canceling or closing the editor leaves the original unchanged.
Closing its source pin also closes the editor so edits cannot be applied to an invalid target.
Reopening a completed pinned image uses the flattened result as the new base;
editable undo layers do not persist across sessions.

Rendering uses the original `CGImage` pixel dimensions.
Export creates a new flattened PNG without embedding the original or removable cover layers.
Covers use the selected color at full opacity, align to whole pixels, and are drawn after all other annotations.
Changing color opacity or adding text later cannot reveal the image beneath a cover.
The text-recognition button runs Vision on the **flattened** image, including covers, with support for
English and available Chinese models. Narrow crops get a background-colored margin and are enlarged for OCR only.
This does not change the screenshot or recover strokes outside the selected area; include whole characters when framing text.
If the first pass finds no text, the app retries with enlarged pixels when possible and without language correction.
Results stay next to the toolbar in a scrollable card.
Select and copy a passage or click **Copy All Text**; nothing is copied automatically.
This is not automatic redaction. No image or recognized text is sent to a
server, network API, or training service.

The original behind a capture preview or pinned image may already be in the clipboard and history.
Adding a cover later does not retroactively delete that original.
To cover sensitive content before it enters history, use Capture → Annotate In Place → Copy / Pin / Save,
or save only to a local file.
Canceling an annotate-first session discards it; its temporary capture files are still cleaned up
by the original capture session.

Annotation tests use only generated color-block images and virtual windows.
They cover PNG resolution and orientation, all tools, opaque cover pixels, undo and redo,
invalid input, canvas coordinates and text entry, injected export callbacks,
preserving edits after cancellation or failure, preview and pin entry points,
the selection annotation branch, and window cleanup. Inline-overlay tests also cover screen-coordinate
placement, borderless non-activating panels, full-screen and negative-coordinate displays, narrow-display
toolbars, direct copy/pin buttons, keyboard completion, and display-change cancellation.
Tests do not read the real clipboard, history, or desktop.
The editor layout preview is rendered only from a hidden test window
to `/private/tmp/maccy-annotation-editor-synthetic.png`.
