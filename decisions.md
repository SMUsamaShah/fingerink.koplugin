# decisions.md — Finger Ink

## ADR-1 — Hook `GestureDetector:feedEvent`, not the stylus callback

**Context.** `pencil.koplugin` and `stylus-annotations.koplugin` both route
through `Input:registerStylusCallback` / `Input:routeStylusEvents`. That path
filters on `slot.tool == TOOL_TYPE_PEN/ERASER` or `slot.slot == Input.pen_slot`
(`pen_slot = main_finger_slot + 4`). A Kindle touch panel reports neither: no
`ABS_MT_TOOL_TYPE`, contacts in slots 0/1. The callback can never fire for a
finger. `registerStylusCallback` also does not exist in v2026.03.

**Decision.** Wrap `Device.input.gesture_detector.feedEvent`, the same hook
`notes.koplugin` uses. It is the only place in v2026.03 where fully parsed MT
slots — finger included — are observable without patching core.

**Consequences.** Monkey-patching a core object. Mitigated by installing only
while drawing mode is on and removing on every exit path. Will need revisiting
if a real touch-observer API lands upstream.

## ADR-2 — Always call the original `feedEvent`, gate only its output

**Context.** Swallowing frames outright keeps GestureDetector from seeing a
consistent contact sequence, so the two-finger exit gesture would intermittently
fail to fire (its first finger's down was never delivered).

**Decision.** Call `original(gd_self, slots)` on every frame. Clear the returned
event list in place when the plugin is consuming the sequence.

**Consequences.** GestureDetector does redundant work during ink strokes. Cheap
relative to the e-ink refresh, and clearing in place adds no allocation.

## ADR-3 — Single finger inks, two fingers pass through *(superseded in part by ADR-8)*

**Context.** Something has to turn drawing off while single-finger touch is
being consumed, on a device with no buttons but power. A floating toolbar means
a widget, hit-test passthrough, and text rendering. Invisible hot corners are
undiscoverable.

**Decision.** Contact count is the modifier. One contact draws; two or more
latch passthrough for the rest of the sequence. Toggle is a Dispatcher action
the user maps to a two-finger tap.

**Consequences.** No toolbar to build or maintain. Costs the two-finger gesture
set while drawing is on, and aborts a stroke if a second finger lands mid-line
(palm contact). Acceptable — there is no palm rejection to be had anyway.

**Outcome.** Wrong. A two-finger tap on an IR panel while a palm rests on the
screen is unreliable, the toggle was buried in a menu that itself becomes
unusable once taps are swallowed, and the only dependable exit turned out to be
the power button. The contact-count rule is kept as a convenience; the exit
route is now ADR-8.

## ADR-4 — Flat number arrays for strokes

**Decision.** `{ n, w, x1, y1, x2, y2, ... }` rather than an array of point
tables. Two array slots per point, one table per stroke.

**Consequences.** Zero allocation while a stroke is being drawn after the
initial table, and the hot loops (render, hit test) touch only numbers.
Indexing is `i*2-1 / i*2` arithmetic, which is the one place the code is less
obvious than it could be.

## ADR-5 — Absolute screen coordinates, keyed by page number

**Decision.** Store raw post-rotation screen pixels. Key by
`self.view.state.page`.

**Consequences.** Simple and exact for PDFs at a fixed zoom. In EPUBs, changing
font size, margins or rotation moves the text and leaves the ink where it was.
Same limitation `pencil.koplugin` documents. Set your layout before you write.
Rejected for v1: xpointer anchoring (large), layout-signature invalidation
(hides ink without explaining why).

## ADR-6 — Direct `Screen.bb` paint plus `refreshFast` for live feedback

**Context.** `notes.koplugin` calls `UIManager:setDirty(self, "ui", region)` per
stroke segment. `"ui"` is a quality partial refresh, and `setDirty` repaints the
widget stack — both far too slow per point on a PW4.

**Decision.** Paint the new segment straight into `Screen.bb` and
`Screen:refreshFast` its padded bounding box (DU waveform, 1-bit, ~100 ms).
`paintTo` remains the authoritative redraw.

**Consequences.** DU ghosting builds up; the next page turn's full refresh
clears it. Direct framebuffer painting is outside UIManager's model, so any
repaint the plugin does not trigger itself must still produce correct output —
hence `paintTo` replays everything rather than trusting the framebuffer.

## ADR-7 — Stroke-level erase, point-based hit test

**Decision.** Erase removes a whole stroke; hit test scans stored points, not
interpolated segments.

**Consequences.** Long fast strokes sampled sparsely have gaps that do not
respond to the eraser. Segment-distance hit testing is the fix if it becomes
annoying; it is ~15 more lines and was not worth it before seeing real strokes.

## ADR-8 — An always-visible toolbar, reached by geometric passthrough *(see also ADR-10)*

**Context.** ADR-3 left no dependable way out of drawing mode. What was needed
was an on-screen control that keeps working while the plugin owns single-finger
input.

**Decision.** A real KOReader widget (`ink_bar.lua`) shown through
`UIManager:show`, so it renders natively and sits above ReaderUI in the widget
stack. Input is handled geometrically rather than by wiring the widget into the
capture path: a contact whose first point lands inside `bar.dimen` latches
passthrough for the whole sequence, GestureDetector emits a normal tap, and the
Button handles it as it would any other.

Two invariants make the stuck state unreachable: turning drawing on shows the
bar; hiding the bar turns drawing off.

**Consequences.**

- The visuals are KOReader's — no hand-painted rects, no guessing at icon names
  or glyph coverage in the Kindle font stack. Text labels for the same reason.
- No hook is needed while drawing is off. The bar is an ordinary widget then and
  gets taps the ordinary way, so requirement 4 survives intact.
- The bar occupies ~15% of screen width. It is hideable, and side-switchable for
  left-handers.
- A stroke dragged onto the bar is truncated at the edge rather than drawn under
  it. `draw_slot = SUSPENDED` parks the contact until lift so it cannot resume
  in the middle of a line.
- Position is computed once from screen size, so rotation and resize have to
  rebuild it.

Rejected: hand-painting the toolbar into `Screen.bb` inside `paintTo` and
hit-testing it ourselves. Fewer moving parts on paper, but it means owning text
rendering, pressed states and refresh regions — more code, worse looking.

## ADR-9 — "Start drawing" closes the menu

**Context.** The menu item toggled drawing and called `updateItems()`, leaving
the menu open on top of a reader that no longer responds to single-finger taps.

**Decision.** The item is one-way (`Start drawing`, disabled once on) and lets
the menu close. Stopping is the toolbar's job.

**Consequences.** Slightly asymmetric menu. Correct, though: the menu is only
usable in the state where drawing is off, so it should only offer the action
that is valid in that state.

## ADR-10 — The toolbar forwards input it does not want

**Context.** ADR-8 assumed that sitting on top of the widget stack only affected
what the bar *receives*. It also decides what everything else receives.
`UIManager:sendEvent` offers an input event to exactly one window — the topmost
non-toast one — and its fallback pass afterwards reaches only widgets flagged
`is_always_active` or registered as someone's `active_widgets`. ReaderUI is
neither, and neither is TouchMenu.

So while the bar was up, it was the only thing on screen that could be touched.
Page turns did nothing. Worse, showing the bar from the menu left the menu open
and unclosable: tapping outside it is the only way to dismiss one, and those
taps stopped at the bar. The only escape was Hide, which is what the bug report
described.

Drawing mode had the same hole one layer down: the `feedEvent` hook eats
single-finger contacts before UIManager sees them at all, so an open menu stayed
stuck even once the bar started forwarding.

**Decision.** Two guards, one per layer.

`InkBar:handleEvent` forwards to `self:windowBelow()` — the topmost non-toast
window that is not the bar — but only for the four handlers that arrive through
`sendEvent` (`onGesture`, `onKeyPress`, `onKeyRepeat`, `onKeyRelease`).
Everything else is broadcast to every window already and would be delivered
twice. `InkBar:onGesture` swallows gestures that land on the bar but miss every
button, so its border and padding do not turn pages.

`FingerInk:dialogOnTop` reports whether the window under the bar is something
other than ReaderUI. When it is, `onTouchFrame` latches passthrough for the
contact sequence instead of inking, so any menu or dialog can always be
dismissed. It re-latches per sequence, so drawing resumes on its own once the
dialog is gone.

**Consequences.**

- Reading with the bar shown works: taps, swipes and hardware keys all reach the
  reader.
- Forwarding returns the callee's own result rather than a blanket `true`, so
  UIManager's `is_always_active` / `active_widgets` pass still runs on a miss.
  A widget below that is itself always-active may see one unhandled event twice;
  it returned false the first time, so the second changes nothing.
- Reaches into `UIManager._window_stack`. It is private by name only — stable
  across releases and already poked at by plugins — but it is the one part of
  this that a KOReader refactor could break.
- Drawing yields entirely while a dialog is up. Deliberate: an undismissable
  dialog is a worse failure than a dropped stroke.

Rejected: making the bar a `toast`. Toasts do pass input through, which is half
of what is wanted, but they can never consume it — the bar's own buttons would
have fired *and* turned a page underneath.

Rejected: dropping the window entirely and painting the bar from `paintTo` with
ReaderUI touch zones for input. Architecturally the tidiest, and how ReaderFooter
does it, but the zones have to name every reader zone they override
(`tap_forward`, `readerhighlight_tap`, and so on) — a brittle list, for a bigger
change than the bug warrants.

## Deferred

- Scroll view mode (`paintTo` offset and page identity both change).
- Segment-distance eraser (ADR-7).
- Layout-change detection for EPUBs (ADR-5).
- Save-on-stroke instead of `onSaveSettings`, if crash loss turns out to matter.
- Draggable toolbar (`MovableContainer`) if the fixed centred position gets in
  the way of a particular book's layout.
