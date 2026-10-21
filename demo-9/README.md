# Demo 9 — XNeko

<p align="center">
  <a href="../screenshots/09-xneko.png">
    <img src="../screenshots/09-xneko.png" alt="XNeko" />
  </a><br/>
</p>

A Common Lisp port of the classic X11 `neko` / `oneko` demo. A small animated cat runs across your screen, chasing the mouse pointer or the currently focused window, cycling through 18 expressive animation states (running in 8 directions, scratching, yawning, playing, and sleeping).

The demo ships with multiple sprite variants: cat (`:neko`), dog (`:dog`), BSD Daemon (`:bsd`), Sakura (`:sakura`), and Tomoyo (`:tomoyo`).

## Technical Highlights

- **Window kind**: `:override-redirect`.
- **SHAPE Clipping**: Clips the override-redirect cat window to the active sprite's 1-bit transparency mask using the X11 `SHAPE` extension, giving the cat a transparent silhouette without rectangular borders.
- **Root Cursor Theming**: Just like classic `oneko`, the desktop cursor is changed to represent the animal's prey (e.g. a mouse for the cat, a bone for the dog, a BSD trident, or a cherry blossom petal). The desktop's original cursor is cleanly restored on exit.
- **Target Tracking**: Supports chasing either the pointer cursor (default) or the active focused window (`:tofocus t`).

> [!NOTE]
> Like XSnow and XRoach, this demo requires a real X11 server (Xephyr or Xvfb are OK). It will not work properly under pure Wayland and  XWayland due to pointer query restrictions.

## Loading in REPL

```lisp
;; Load the demos system
(asdf:load-system "clxcb-demos")

;; Start classic neko
(demo9:run)

;; Start dog variant with custom speed
(demo9:run :variant :dog :speed 15)

;; Start BSD daemon variant
(demo9:run :variant :bsd)

;; Cleanly stop the demo from the REPL
(demo9:stop)
```

## Running with Makefile

```bash
# Run Demo 9
make demo9

# Or using friendly alias:
make xneko

# Pass options:
make demo9 ARGS="--variant dog --speed 16"
make demo9 ARGS="--variant bsd"
make demo9 ARGS="--tofocus"
make demo9 ARGS="--help"
```

## Options

`:variant` (`:neko`, `:dog`, `:bsd`, `:sakura`, `:tomoyo`, default: `:neko`) — Character variant to run.
`:foreground` / `:background` (color string, default: `"black"` / `"white"`) — Foreground and background colour of the sprite.
`:speed` (number > 0, default: variant default) — Movement distance in pixels per step (e.g. 13 for neko, 10 for dog, 16 for bsd).
`:idle` (number >= 0, default: variant default) — Idle distance threshold before stopping or sleeping.
`:interval` (integer >= 1, default: variant default) — Microseconds per animation frame (125,000 µs = 8 FPS; 300,000 µs for bsd).
`:shape` (boolean, default: `t`) — Use X11 SHAPE extension for non-rectangular sprite outline (`--shape` / `--no-shape`).
`:root-cursor` (boolean, default: `t`) — Set desktop root cursor to the animal's prey (`--root-cursor` / `--no-root-cursor`).
`:tofocus` (boolean, default: `nil`) — Chase the currently focused window instead of the mouse pointer.
`:x-offset` / `:y-offset` (integer, default: variant default) — Horizontal and vertical offset from the target.
`:verbose` (boolean, default: `t`) — Print diagnostic information to standard output.

## Quit:

- `Alt+q` or `Ctrl+q` (restores original desktop root cursor)
- Stop from the REPL with `(demo9:stop)`
