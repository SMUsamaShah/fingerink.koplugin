# spec.md — Finger Ink (source of truth)

## Layout

```
fingerink.koplugin/
  _meta.lua        plugin manifest
  main.lua         plugin object: state machine, menu, persistence, paintTo
  ink_bar.lua      always-reachable side toolbar widget
  ink_capture.lua  GestureDetector:feedEvent wrapper + rotation transform
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

Three rules together guarantee the bar is always usable:

1. `setDrawing(true)` shows the bar first if it is hidden.
2. `setBarShown(false)` calls `setDrawing(false)` first.
3. A contact whose **first** point falls inside `bar.dimen` latches
   `passthrough`, so GestureDetector produces the tap and the Button fires.

Rules 1 and 2 make "drawing on, no bar" unreachable. Rule 3 makes the bar
work while every other single-finger touch is being consumed.

A stroke that starts off the bar and is **dragged onto** it is ended at the
edge and the contact is parked at `draw_slot = SUSPENDED` (-1) until it lifts,
so ink is never painted over the buttons and never resumes mid-drag.

Rotation and `onScreenResize` rebuild the bar, since its position is computed
once from screen dimensions.

## Stroke data

```lua
stroke = { n = <point count>, w = <pen width px>, x1, y1, x2, y2, ... }
```

Flat number array, two slots per point. No per-point table. Serialises
directly into the document sidecar under `fingerink_strokes`, keyed by page:

```lua
pages = { [17] = { stroke, stroke }, [23] = { stroke } }
```

Coordinates are absolute screen pixels. `paintTo` therefore ignores its `x, y`
arguments — ReaderView is full-screen, so the view origin is always `0, 0`.

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
- Clear this page
- Clear whole document

Stop, tool and undo live on the toolbar, not in the menu — reaching them
through the menu is exactly the thing that does not work while drawing.

Dispatcher actions for Gesture Manager: `fingerink_toggle`, `fingerink_undo`,
`fingerink_eraser`, `fingerink_bar`.
