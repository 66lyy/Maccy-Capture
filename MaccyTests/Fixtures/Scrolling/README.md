# Recorded scrolling browser frames

ScreenCaptureKit captures of a local numbered-text page on macOS 26.6.2,
at 1× display scale. Each image is 1598×1174 pixels, from display rectangle
(1,25,1598,1174). No capture panel or selection overlay is present.

- `safari-toolbar-{before,after}.png`: scroll offsets 0 and 160 pixels;
  the top browser UI changes appearance while scrolling.
- `chrome-scrollbar-{before,after}.png`: scroll offsets 0 and 80 pixels;
  the right-edge scrollbar changes position.

The bottom 81 rows are fixed desktop/Dock pixels. The 15 rows above them
include rounded browser-window corners; trailing-footer inference replaces
those rows with unobscured content from the next frame. Exact-output tests
therefore retain the first image except for its bottom 96 rows, then append
the last `shift + 96` rows of the second image. No colour or pixel filtering
is applied to the expected output.
