# Recorded scrolling browser frames

ScreenCaptureKit captures of a local numbered-text page on macOS 26.6.2,
at 1× display scale. Each image is 1598×1174 pixels, from display rectangle
(1,25,1598,1174). No capture panel or selection overlay is present.

- `safari-toolbar-{before,after}.png`: scroll offsets 0 and 160 pixels;
  the top browser UI changes appearance while scrolling.
- `chrome-scrollbar-{before,after}.png`: scroll offsets 0 and 80 pixels;
  the right-edge scrollbar changes position.

The bottom 81 rows are fixed desktop/Dock pixels. The 15 rows above them
include stationary rounded browser-window corners. The reference image uses
a 45-row tail above the desktop to cover shading above the corners;
unobscured body rows are recovered from the next frame. Exact-output tests
retain the first image except for its bottom 126 rows, then append the last
`shift + 126` rows of the second image. The implementation may refresh a larger
tail within its 1/16-frame bound; additional unshaded rows are pixel-identical.
Exported-image checks also crop only
the confirmed changing scrollbar columns, consistently over the entire image.

## Sparse-content aliases

`solid-{chat,article,table,safari-table}-{before,jump,near}.png` are real
ScreenCaptureKit frames of local HTML in Chrome and Safari on the same 1× VM.
The capture region is (100,240,800,800), inside a 1000-pixel-wide browser.
An outside-selection gutter encodes document row positions; it is excluded
from these fixtures and the stitcher. Dense captures 64 pixels apart verify
every shared body row exactly before assembling pixel ground truth.

| Fixture | Browser | before → jump scrollY | near scrollY | Old accepted shift |
|---|---|---|---|---|
| chat | Chrome | 0 → 896 | 64 | 76 |
| article | Chrome | 0 → 2240 | 64 | 222 |
| table | Chrome | 0 → 1792 | 120 | 200 |
| safari-table | Safari | 64 → 1024 | 128 | 164 |

Chat has repeated messages, numbered coloured avatars and 500-pixel gaps.
The article has numbered sections, similar paragraphs and 550-pixel gaps.
The table has numbered rows, repeated bullets/borders and 400-pixel gaps.
The chat/table tests require rejection without mutation, then an exact 64/120-row
append from a nearby frame, including recovery after the rejected jump. The
article is a documented periodic exception: rows 225..<800 in its first frame
are pixel-identical to rows 3..<578 of the distant frame. Its test verifies
that identity rather than requiring the matcher to distinguish identical rows.

Scrollbar masks are right-only and capped near 2% of width, with a 16-pixel
minimum allowance and at least one signature bin. The Chrome fixture needs
two bins (13 pixels); the Safari toolbar fixture needs no scrollbar mask.
Confirmed stationary borders refresh at most a further 1/16-frame tail above
the existing footer; the refreshed tail remains bounded throughout capture.

`live-safari-{bands,text}-{before,after}.png` are full-window captures from the
same selection geometry. Their true shifts are 169 and 320 pixels. The bands
pair's last leading mismatch is row 122; the next matching informative row
is 181. Header inference stops at 123, retaining the intervening neutral rows.
The changing header removes 113 of 266 informative overlap rows (42.48%);
the text pair removes 118 of 419 (28.16%). The informative-mask allowance is
43% for a changing leading header accompanied by a confirmed right-edge mask,
the smallest whole-percentage budget covering both recordings. Other inferred
masks retain the 25% budget. Body matching still requires 95%, and inferred
headers remain bounded to 1/8 height. The minimum overlap retains its first
informative-row safeguard without treating intervening neutral rows as header.

`contrast-{chrome,safari}-{dim,low}-{start,next}.png` are 1120×800 browser
captures of native 20-pixel monospace text at offsets 0 and 160. The dim page
uses #060606 text on black; the light page uses #fafafa on #f8f8f8. Central
body contrast below 8 is amplified in signatures only. Source and exported
pixels remain unchanged, and ordinary-contrast frames use the original path.

`tail-{chrome,safari}-{0,160,320,480,640,800,960}.png` record a translucent 50-pixel
floating bar with rounded/shaded edges. It is present through offset 640 and
gone at 800. Stored tails may persist only with matching current static-edge
evidence. The 960 frame regains the uncompressed range; its exact 1760-pixel
output is checked against unoccluded rows from the recorded inputs.
Chrome's requested-320 input is byte-identical to its 160 input; the test
requires that duplicate to leave the canvas unchanged rather than advance it.
