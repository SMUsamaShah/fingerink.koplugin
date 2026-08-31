# Finger Ink

Draw handwritten notes on KOReader pages with your finger. Designed for touch
e-readers without a stylus, including Kindle Paperwhite.

https://github.com/user-attachments/assets/c9c4f543-999a-47e8-8ae3-d14274997e5f

<details>
<summary>(FFMPEG commands that compressed this video 35MB -> 3MB)</summary>

```
ffmpeg -y -i input.mp4 -c:v libx264 -b:v 600k -pass 1 -an -f null NUL
ffmpeg -i input.mp4 -c:v libx264 -b:v 600k -pass 2 -c:a aac -b:a 128k output.mp4
```
</details>

Your ink is saved per page in KOReader's sidecar data, where it can be undone
or erased. For PDFs, you can optionally export the ink as native PDF
annotations so it is visible in Acrobat, Preview, and other PDF readers.

PDF export is one-way: after export, Finger Ink can no longer undo or erase
those strokes.

## Requirements

- KOReader 2026.03 or newer for drawing
- KOReader 2026.07 or newer for PDF export

## Install

### AppStore or Storefront

Finger Ink is structured for KOReader's AppStore and Storefront plugins. Find
**Finger Ink** in the store and install it, then restart KOReader. The store can
compare the stable GitHub release with the version in `_meta.lua` and offer
future updates.

### Manual installation

Download `fingerink.koplugin.zip` from the
[latest release](https://github.com/SMUsamaShah/fingerink.koplugin/releases/latest),
extract it, and copy the resulting `fingerink.koplugin` directory into
KOReader's `plugins` directory:

```sh
scp -r fingerink.koplugin root@<kindle>:/mnt/us/koreader/plugins/
```

The final path should be:

```text
koreader/plugins/fingerink.koplugin/main.lua
```

Restart KOReader after installing.

## KOReader setup

No gesture setup is required. You do not need to assign or disable KOReader's
long-press gesture.

If Finger Ink is disabled in KOReader's plugin manager, enable it and restart
KOReader. Then open a document and use **Top menu → More tools → Finger Ink**.
The optional `Finger Ink: ...` actions exposed to KOReader's gesture manager
are shortcuts only; the plugin works without assigning any of them.

## Use

Open:

```text
Top menu → More tools → Finger Ink
```

Use **Start drawing** to enable the toolbar.

- **Draw / Stop** — enable or disable drawing
- **Pen / Eraser** — change tool
- **Undo** — remove the last stroke on the current page
- **Hide** — stop drawing and hide the toolbar

The toolbar uses compact text buttons by default. In **Finger Ink → Toolbar
style**, choose **Icons** for an even narrower toolbar. Long-press anywhere on
the toolbar and drag it to a more convenient place; its position is remembered.

One finger draws. Two-finger gestures continue to work normally.

## Export ink into a PDF

From the Finger Ink menu, choose:

- **Save this page into PDF**
- **Save whole document into PDF**

For reliable export, use page view. Continuous PDF view is supported when
each stroke stays within one page. Strokes crossing the gap between pages are
not exported.

Ink drawn while reflow or page rotation is enabled may not be exportable.
Those strokes remain in the sidecar and the plugin explains what to correct.

## Limitations

- No palm rejection.
- Changing layout after writing can move text while leaving ink behind,
  especially in reflowable books such as EPUBs.
- Exported PDF ink cannot be edited by Finger Ink.
- Fast refresh may look grainy or leave temporary ghosting.

## Documentation

- `spec.md` — implementation details
- `decisions.md` — design decisions
- `requirements.md` — original requirements

## Releases

Every version change merged to `main` is tested and packaged automatically as
a stable GitHub release. The release ZIP contains only the installable
`fingerink.koplugin` directory; repository documentation and development files
remain outside it.
