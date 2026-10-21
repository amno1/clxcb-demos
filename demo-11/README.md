# Demo 11 — XViewer

<p align="center">
  <a href="demo11.png">
    <img src="demo11.png" alt="XViewer" />
  </a><br/>
</p>

A fast, feature-rich image viewer and slideshow application for CLXCB. It scans a directory for image files, decodes them through pluggable image backends (currently only libpng), uploads bitmaps to X11 pixmaps via `xcb:put-image`, and renders them smoothly with `xcb:copy-area`.

Features interactive translucent navigation overlays, an integrated graphical directory selection dialog, dynamic aspect-ratio-preserving scaling, fullscreen presentation mode, on-screen help, and customizable slideshow auto-advance.

## Technical Highlights

- **Window kind**: `:managed`.
- **Image Pipeline**:
  - Image decoding via `xcb-demos.image-decoders` (pluggable decoder registry).
  - Client-side image upload via `xcb:put-image`.
  - Fast bilinear downscaling and aspect fitting to the window drawable.
  - Software alpha blending for translucent navigation arrow controls.
- **Dynamic UI Scaling**: UI overlays, font sizes, and controls scale reactively together via `xact:relate`.
- **Directory Picker**: Uses `file-select` on `Ctrl+o` to browse and select image folders via a native graphical file chooser.

## Loading in REPL

```lisp
;; Load the demos system
(asdf:load-system "clxcb-demos")

;; Start viewer in the current directory
(demo11:run)

;; Start viewer pointing to a specific folder in slideshow mode
(demo11:run :directory "~/Pictures" :slideshow t :interval 3.0)

;; Cleanly stop the demo from the REPL
(demo11:stop)
```

## Running with Makefile

```bash
# Run Demo 11
make demo11

# Or using friendly aliases:
make xviewer
make image-viewer

# Pass options:
make demo11 ARGS="--directory ~/Pictures --slideshow"
make demo11 ARGS="--no-controls --fit-fullscreen"
make demo11 ARGS="--help"
```

## Options

`:directory` (string / pathname, default: current directory or `screenshots/`) — Directory to scan for images.
`:interval` (number > 0, default: `4.0`) — Slideshow interval in seconds.
`:slideshow` (boolean, default: `nil`) — Start immediately with slideshow timer running.
`:controls` (boolean, default: `t`) — Show translucent prev/next overlay triangles (`--controls` / `--no-controls`).
`:grip` (boolean, default: `nil`) — Show corner resize grip in bottom-right corner.
`:fit-fullscreen` (boolean, default: `t`) — Scale images to fit the window while preserving aspect ratio.
`:shrink-only` (boolean, default: `nil`) — When fitting, do not upscale images that are smaller than the window.
`:max-width`  (integer >= 1, default: `1200`) — Maximum automatic window width when fitting to an image.
`:max-height` (integer >= 1, default: `900`) — Maximum automatic window height when fitting to an image.
`:width` (integer >= 1) — Initial window width in pixels.
`:height` (integer >= 1) — Initial window height in pixels.
`:x` (integer) — Initial window X position on screen.
`:y` (integer) — Initial window Y position on screen.
`:geometry` (string) — Standard window geometry string (e.g. `"1024x768+100+100"`).
`:font-family` (string) — Font family for help panel and overlays.
`:font-subfamily` (string) — Font subfamily style (e.g. `"Regular"`, `"Book"`).
`:font-size` (integer, default: `12`) — Help overlay font size in pixels.

## Controls

- `Space` / `Right` / `r` / `n` Advance to the **next** image.
- `Left` / `l` / `p`            Return to the **previous** image.
- Click Left / Right Triangle   Click translucent on-screen triangles to go previous / next.
- `s`                           **Stop** slideshow (displays static image).
- `Shift+r` (`R`)               **Run** slideshow auto-advance timer.
- `t`                           **Toggle** auto-advance timer on/off.
- `f` or `F11`                  Toggle **fullscreen** mode.
- `h`                           Toggle **translucent controls** (prev/next overlays) visible/hidden.
- `g`                           Toggle corner **resize grip** visible/hidden.
- `i`                           Toggle image **fit-to-window** vs. **native pixel size**.
- `c`                           Toggle **shrink-only** mode (prevent upscaling smaller images).
- `Ctrl+o`                      Open graphical directory selector dialog.
- `?`                           Toggle **help overlay** panel on/off.
- `Ctrl++` / `Ctrl+-` / `Ctrl+0` Make UI overlays and fonts **bigger**, **smaller**, or **reset** to default size (also `Alt-drag` / `Super-drag`).

## Quit:

- `q` or `Escape`
- Close the window via your window manager's title bar close button (`WM_DELETE_WINDOW`)
- Stop from the REPL with `(demo11:stop)`
