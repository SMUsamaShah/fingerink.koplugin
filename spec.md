# spec.md — Finger Ink (source of truth)

## Layout

```
fingerink.koplugin/
  _meta.lua        plugin manifest
  main.lua         plugin object: state machine, menu, persistence, paintTo
  ink_bar.lua      always-reachable side toolbar widget
  ink_capture.lua  GestureDetector:feedEvent wrapper + rotation transform
  ink_pdf.lua      writing stored ink out as PDF ink annotations
  ink_render.lua   allocation-free segment/stroke rasterisation
  ink_store.lua    per-page stroke list, hit test
```

Module names are prefixed `ink_` so plugin-local `require` cannot shadow a core
module (`require("input")` would collide with `device/input`).

## Input capture

KOReader v2026.03 exposes no API for reading parsed touch slots. The only
device-agnostic hook is `Device.input.gesture_detector.feedEvent`, which the
plugin wraps **only while drawing mode is on**:

```lua
gd.feedEvent = function(gd_self, slots)
    local emit = handler(slots)      -- ours, runs first, on untouched slots
    local evs  = original(gd_self, slots)
    if emit then return evs end
    for i = #evs, 1, -1 do evs[i] = nil end
    return evs
end
```

The original is **always** called, so GestureDetector's internal state stays
consistent; the plugin only decides whether the resulting gesture events reach
the app. Without this, a swallowed finger-down would desynchronise the detector
and the two-finger exit gesture would not fire.

A slot table is `{ slot, id, x, y, tool, timev }`. `id >= 0` is a contact,
`id == -1` is a lift. `x`/`y` may be absent on lift frames.

Coordinates are pre-rotation; `Capture.toScreen(x, y)` applies the same
transform GestureDetector applies after detection, and returns two numbers.

## Contact arbitration

| Active contacts | Behaviour |
| --- | --- |
| 1 | ink; gesture events discarded |
| ≥ 2 | passthrough for the remainder of the sequence; in-progress stroke aborted |

`passthrough` latches on the second contact and clears when contact count
returns to 0. The lift frame that completes a two-finger gesture is emitted
because the return value is `self.passthrough or was_passthrough`.

**Single finger draws. Two fingers behave normally.** Two-finger gestures are a
convenience, not the exit route — the toolbar is.

## Toolbar

`ink_bar.lua` is a plain KOReader widget (`FrameContainer` > `VerticalGroup` >
four `Button`s) shown via `UIManager:show`, so it sits above ReaderUI in the
widget stack and receives taps before anything else. Its position is fixed:
vertically centred, `Size.padding.large` in from the chosen edge.

Buttons, top to bottom:

| Button | Label | Action |
| --- | --- | --- |
| 1 | Draw / **Stop** | toggle capture |
| 2 | Pen / **Eraser** | current tool; switches capture on if off |
| 3 | Undo | drop last stroke on this page |
| 4 | Hide | switch drawing off, then hide the bar |

`InkBar:update(refresh)` relabels buttons 1 and 2 from plugin state. Called
from every path that changes `drawing` or `eraser`.

### Reachability

Four rules together guarantee the bar is always usable, and that having it up
never costs the reader its own input:

1. `setDrawing(true)` shows the bar first if it is hidden.
2. `setBarShown(false)` calls `setDrawing(false)` first.
3. A contact whose **first** point falls inside `bar.dimen` latches
   `passthrough`, so GestureDetector produces the tap and the Button fires.
4. `InkBar:handleEvent` forwards input the bar did not want to
   `self:windowBelow()`, the topmost non-toast window that is not the bar.

Rules 1 and 2 make "drawing on, no bar" unreachable. Rule 3 makes the bar work
while every other single-finger touch is being consumed.

Rule 4 exists because `UIManager:sendEvent` offers an input event to exactly one
window, the topmost non-toast one, and its follow-up pass reaches only
`is_always_active` and `active_widgets` widgets — which neither ReaderUI nor
TouchMenu is. Without forwarding, the bar being up meant nothing else on screen
responded to touch at all. Only the four handlers that arrive through
`sendEvent` are forwarded (`onGesture`, `onKeyPress`, `onKeyRepeat`,
`onKeyRelease`); everything else is broadcast to every window already. A gesture
that lands on the bar but misses every button is swallowed rather than
forwarded, so the bar's border does not turn pages.

The same hole exists one layer down, since `feedEvent` eats single-finger
contacts before UIManager sees them. `FingerInk:dialogOnTop` reports whether the
window under the bar is something other than ReaderUI; while it is,
`onTouchFrame` latches `passthrough` instead of inking, so an open menu or
dialog can always be dismissed. It re-latches per contact sequence, so drawing
resumes by itself once the dialog is gone.

A stroke that starts off the bar and is **dragged onto** it is ended at the
edge and the contact is parked at `draw_slot = SUSPENDED` (-1) until it lifts,
so ink is never painted over the buttons and never resumes mid-drag.

Rotation and `onScreenResize` rebuild the bar, since its position is computed
once from screen dimensions.

## Stroke data

```lua
stroke = { n = <point count>, w = <pen width px>, t = <transform>, x1, y1, ... }
transform = { z = <zoom>, x = <offset>, y = <offset> }   -- or absent
```

Flat number array, two slots per point. No per-point table. Serialises
directly into the document sidecar under `fingerink_strokes`, keyed by page:

```lua
pages = { [17] = { stroke, stroke }, [23] = { stroke } }
```

Coordinates are absolute screen pixels. `paintTo` therefore ignores its `x, y`
arguments — ReaderView is full-screen, so the view origin is always `0, 0`.

`t` is written once per stroke by `endStroke`, from `FingerInk:pageTransform`,
and is only read when saving into a PDF. It inverts
`ReaderView:getSinglePagePosition`:

```lua
page_x = (screen_x + t.x) / t.z    -- t.x = visible_area.x - state.offset.x
page_y = (screen_y + t.y) / t.z    -- t.z = state.zoom
```

Recording it per stroke rather than reading the live view state at save time is
what makes whole-document export correct: zoom and offset differ per page, and
the view may have been zoomed or panned since the stroke was drawn.
`pageTransform` returns nil, and `t` is absent, for strokes whose coordinates do
not map safely onto one PDF page: reflowable documents, reflowed PDFs, rotated
pages, and strokes crossing a page gap. Continuous view is mapped through
`ReaderView:getScrollPagePosition`.

## Rendering

- `Render.segment` walks a DDA between two points painting `w × w` rects.
  Integer locals only, no table allocation, no `math.abs` on the hot path.
- Live feedback paints straight into `Screen.bb` and calls
  `Screen:refreshFast(x, y, w, h)` (DU) over the padded segment bounding box,
  clamped to screen bounds. `refreshPartial` if the user prefers quality.
- `paintTo(bb)` replays every stroke on the current page. This is the
  authoritative path — direct `Screen.bb` painting is only a latency shortcut
  and is always recoverable by a repaint.

## Erasing

Stroke-level. `Store.hit(list, x, y, r)` scans points back-to-front and returns
the index of the first stroke with a point within `r` (default 18 px). Squared
distance, no `sqrt`. Whole stroke is removed, then a `"ui"` repaint.

Point-based, not segment-based: a long straight stroke drawn in two samples has
an unerasable middle. Accepted for v1.

## Persistence

`onSaveSettings` writes `pages` to `doc_settings`, or deletes the key when
empty. No write on every stroke.

## Saving into PDF

`ink_pdf.lua` turns stored strokes into native PDF ink annotations
(`/Subtype /Ink`) via koreader-base's `page:addInkAnnotation(strokes, colour,
width, opacity)`, which also calls `pdf_update_annot` to synthesise the `/Rect`
and `/AP` appearance stream desktop viewers need. `fz_run_page` draws
annotations, so saved ink renders as part of the page from then on.

`InkPdf.save(ui, store, pages)` returns `written, skipped`, or `nil, reason`.

1. `InkPdf.blocker` rejects non-PDF and non-writable documents up front.
2. Each page's strokes are converted through their own `t` and bucketed by line
   width, since border width belongs to the annotation rather than to each ink
   list inside it. A page emits one annotation per pen width, not one per
   stroke. Strokes with no `t` are counted as skipped and left alone.
3. `doc:writeDocument()` writes the file. Same filename, so MuPDF appends an
   incremental update instead of rewriting.
4. Only then do saved strokes leave the store, followed by
   `resetTileCacheValidity()`.

Order matters: nothing is dropped until the file has been written, so a failure
anywhere loses no ink.

The write is immediate rather than setting `is_edited` and leaving it to
`PdfDocument:close`, because `ReaderUI:closeDocument` discards pending document
edits unless the unrelated `highlight_write_into_pdf` setting is on.

Saving is one way. koreader-base exposes ink setters but no getters, and
`getEmbeddedAnnotations` filters to markup types 8-11, so a saved annotation
cannot be found again or read back. Dropping saved strokes from the store is
also what stops `paintTo` painting them a second time over what MuPDF now
renders.

## Lifecycle

`onCloseDocument`, `onCloseWidget` and `onSuspend` all call `Capture:remove()`.
The wrapper is never left installed.

## Menu

Top menu → Finger Ink:

- Start drawing (disabled while already on; **closes the menu**, because an
  open menu is unusable once single-finger taps are being swallowed)
- Show toolbar (toggle, default on, persisted)
- Toolbar side: left / right
- Pen width: thin (2) / medium (4) / thick (7)
- Fast refresh while drawing (toggle, default on)
- Save this page into PDF
- Save whole document into PDF (confirms first)
- Clear this page
- Clear whole document

Stop, tool and undo live on the toolbar, not in the menu — reaching them
through the menu is exactly the thing that does not work while drawing.

Dispatcher actions for Gesture Manager: `fingerink_toggle`, `fingerink_undo`,
`fingerink_eraser`, `fingerink_bar`.
