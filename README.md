# Finger Ink

https://github.com/user-attachments/assets/66a1f825-9707-4755-bf09-310789dac2b5

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

## Saving ink into the PDF

Menu → **Save this page into PDF** or **Save whole document into PDF** writes
the ink as a real PDF ink annotation (`/Subtype /Ink`), appearance stream and
all. It then opens in Acrobat, Preview, or anything else — not only in KOReader.
The file is updated incrementally, so this stays quick on a large PDF.

This is one way. Saved ink becomes an ordinary annotation and is no longer the
plugin's, so Undo and the eraser cannot touch it; remove it in a PDF editor
instead. The whole-document action asks first.

Strokes drawn in a view that has no mapping back onto the page — scroll mode, a
reflowed PDF, a rotated page — are reported as skipped and left in the sidecar
rather than being placed in the wrong spot.

## Menu and gestures

Top menu → More tools → Finger Ink: start drawing, show/hide the toolbar, put
it on the left instead, pen width, refresh quality, save into PDF, clear page,
clear document. "Start drawing" closes the menu on purpose — an open menu is
useless once single-finger taps are going to ink.

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
- Saving into PDF needs a KOReader whose koreader-base has
  `page:addInkAnnotation`. On an older build the menu action says so rather than
  failing obscurely, and the ink stays in the sidecar.

## Tests

```sh
luajit test.lua
```

Runs against stubbed KOReader modules, so nothing needs a running KOReader.

Covers toolbar input forwarding (a tap on the page reaches the reader or an open
menu, a tap on a button does not leak past it, broadcast events are not
forwarded twice) and PDF ink export (screen-to-page conversion, bucketing by pen
width, unmappable strokes skipped rather than misplaced, and that a failed write
loses no ink).

Not yet covered: rasterisation, the stroke store and hit test, the rotation
transform, the `feedEvent` wrapper, and the one/two-finger arbitration state
machine.

## Docs

`requirements.md` — what this is for. `spec.md` — how it works, source of truth.
`decisions.md` — why it works that way.
