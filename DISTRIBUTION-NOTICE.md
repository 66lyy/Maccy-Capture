# Maccy Capture — Unofficial Distribution Notice

**English** | [简体中文](DISTRIBUTION-NOTICE.zh-CN.md)

## Source and Copyright

This software is a modified version of [p0deje/Maccy](https://github.com/p0deje/Maccy).
The original copyright notice and complete MIT License remain unchanged in the accompanying `LICENSE`.
New code in this version is also provided under MIT.
Attribution for this modified version does not replace the original author's copyright notice.

Added features include capture, pinned images, wheel and trackpad zoom, local image annotation,
language settings, a separate application identifier, and a customized build process.
The upstream author is not responsible for this version's features, quality, or support.
This is not an official release and does not imply sponsorship, approval, or endorsement
by the upstream author.

The fork's purple viewfinder icon is a new drawing inspired by the upstream feather.
Its editable source is `artwork/capture-icon.svg`; it is not the original Maccy icon.

The Maccy name identifies the upstream source; this project claims no exclusive rights
to the upstream name, trademarks, or icons.
The code license should not be treated as authorization to use all branding, icons, or other assets.
Review those rights separately before public promotion, and prefer an independent name and original icons.
This notice is not legal advice and does not guarantee the absence of other rights disputes.

## Included Files

Automatically generated ZIP and DMG packages include:

- `LICENSE`: the unmodified upstream MIT copyright notice and full license text.
- `DISTRIBUTION-NOTICE.md`: this notice in English.
- `DISTRIBUTION-NOTICE.zh-CN.md`: this notice in Simplified Chinese.
- `ThirdPartyLicenses/`: third-party licenses, notices, and source records collected from `Package.resolved`.

These files are also included in `Maccy Capture.app/Contents/Resources/`,
so they remain with the app after it is dragged into Applications.
Do not remove applicable copyright, license, or notice files when redistributing.
Third-party components retain their own licenses; including those licenses does not mean
every component is MIT licensed.
Review the applicable requirements again whenever dependencies or assets change.

## Signing and Local Data

Published builds use a dedicated self-signed certificate when configured; other automated builds are ad-hoc signed.
Neither uses the upstream author's signing identity or includes any private key.
Neither signature is Apple Developer ID signing, notarization, or App Store review.

Source and distribution packages must not include real clipboard history, screenshots,
personal information, databases, keys, or certificate private keys.
Regression tests use only generated images and simulated input;
real user data must not be used for testing, training, or uploads to third parties.
