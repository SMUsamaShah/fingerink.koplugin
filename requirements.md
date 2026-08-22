# requirements.md — Finger Ink

## Goal

Scribble on book pages with a **finger** in KOReader on a **Kindle Paperwhite 10th gen**,
where there is no stylus and no `ABS_MT_TOOL_TYPE` reporting.

## Must have

1. Draw freehand ink over the page of the book currently being read.
2. Work with finger input only. No stylus, no eraser end, no side button.
3. Work on KOReader **v2026.03** — no dependency on `Input:registerStylusCallback`
   (added upstream after that release).
4. Leave normal reading completely untouched when drawing mode is off:
   no input hooks installed, no per-event cost, no changed gestures. The
   toolbar may stay visible; it must not alter input handling while idle.
5. An **always-reachable on-screen control** to start and stop drawing and to
   erase. It must keep working while single-finger touch is being swallowed.
   Reaching for the power button is not an exit route.
6. Ink persists per document, per page, across sessions.
7. Undo, erase, clear page, clear document.
8. Stroke feedback fast enough to be usable on e-ink — segment-level DU refresh,
   not a full-page repaint per point.

9. It must not be possible to reach a state where drawing is on and there is
   no visible way to turn it off.

## Must not

- Replace or patch any KOReader core file. Drop-in plugin folder only.
- Allocate per touch point in the draw / render / hit-test paths.
- Leave input hooks installed after drawing mode is turned off.

## Out of scope for v1

- Scroll (continuous) view mode.
- Reflow-stable anchoring: strokes are keyed by page number, so changing font
  size or margins in an EPUB moves the text out from under the ink.
- Pressure, tilt, palm rejection (no hardware for any of it).
- Vector export, PDF flattening, colour.
- A separate notes canvas (that is what `notes.koplugin` already does).
