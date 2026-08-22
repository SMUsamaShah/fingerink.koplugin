# Finger Ink

![demo](demo.mp4)

Draw on book pages with your **finger** in KOReader, on e-readers that have no
stylus — Kindle Paperwhite included.

Built against KOReader **v2026.03**. No core files are patched; it is a plain
drop-in plugin folder.

## Install

Copy `fingerink.koplugin` into KOReader's `plugins` directory. Over SSH:

```sh
scp -r fingerink.koplugin root@<kindle>:/mnt/us/koreader/plugins/
```

You should end up with `koreader/plugins/fingerink.koplugin/main.lua` — not a
doubled `fingerink.koplugin/fingerink.koplugin/`. Restart KOReader.

## Using it

A four-button toolbar sits on the right edge of the screen. It is always
tappable, including while drawing is on — that is the whole point of it.

| Button | Does |
| --- | --- |
| **Draw** / **Stop** | start and stop drawing |
| **Pen** / **Eraser** | switch tool (also starts drawing if it is off) |
| **Undo** | remove the last stroke on this page |
| **Hide** | stop drawing and hide the toolbar |

Then:

- **One finger** draws, anywhere except on the toolbar.
- **Two fingers** work exactly as they normally do — page turn, menus,
  gestures. Landing a second finger cancels the stroke in progress.
- Eraser removes a whole stroke you touch, not part of one.
- Dragging a stroke onto the toolbar ends it at the edge instead of scribbling
  over the buttons.

You can never end up drawing with no toolbar on screen: starting to draw shows
it, and hiding it stops drawing.

Ink is saved into the book's sidecar, per page, when KOReader flushes settings.

## Menu and gestures

Top menu → More tools → Finger Ink: start drawing, show/hide the toolbar, put
it on the left instead, pen width, refresh quality, clear page, clear document.
"Start drawing" closes the menu on purpose — an open menu is useless once
single-finger taps are going to ink.

Optional Gesture Manager actions: *toggle drawing*, *toggle eraser*, *undo
stroke*, *toggle toolbar*. A two-finger tap is a good fit for any of them,
since two-finger gestures keep working while drawing.

## Known limits

- **Set your layout before you write.** Strokes are stored in screen
  coordinates against a page number, so changing font size, margins or rotation
  in an EPUB moves the text and leaves the ink behind. Same caveat
  `pencil.koplugin` carries.
- Single-page view only. Scroll mode is not handled.
- Fast refresh uses the DU waveform: grainy, and ghosting builds up until the
  next page turn. Turn it off in the menu if you would rather have clean strokes
  slowly.
- No palm rejection. There is no tool-type data on this hardware to do it with.
  A palm landing as a second contact cancels the stroke in progress.
- The toolbar takes about 15% of the screen width. Hide it when you are just
  reading.

## Tests

```sh
luajit test.lua
```

Covers rasterisation, the stroke store and hit test, the rotation transform, the
`feedEvent` wrapper, the one/two-finger arbitration state machine, and toolbar
reachability — that a tap starting on the bar passes through and inks nothing,
and that a stroke dragged onto it is truncated rather than painted over the
buttons. Nothing that needs a running KOReader.

## Docs

`requirements.md` — what this is for. `spec.md` — how it works, source of truth.
`decisions.md` — why it works that way.
