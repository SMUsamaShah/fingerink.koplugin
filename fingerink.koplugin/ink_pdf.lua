--[[--
Writing ink into the PDF itself.

PDF has a native freehand annotation (`/Subtype /Ink`) and koreader-base
exposes MuPDF's constructor for it as `page:addInkAnnotation`, which also
synthesises the `/AP` appearance stream desktop viewers need. Ink saved this
way is a normal annotation: it shows up in Acrobat, Preview and everything
else, not just in KOReader. See ADR-11.

Saving is one way. koreader-base exposes ink setters but no getters, so a
saved annotation cannot be found again or read back — which is why saved
strokes leave the store rather than staying alongside it.
]]

local logger = require("logger")
local _ = require("gettext")

local InkPdf = {}

-- Black, matching the ink the plugin paints on screen.
local INK_RGB = { r = 0, g = 0, b = 0 }
local OPACITY = 1.0

--- Why ink cannot be written into this document, or nil if it can.
function InkPdf.blocker(ui)
    local doc = ui and ui.document
    if not doc or not doc.is_pdf then
        return _("Ink can only be saved into PDF documents")
    end
    -- Caches after the first call, so this is cheap enough for a menu.
    if doc:_checkIfWritable() ~= true then
        return _("This PDF cannot be written to")
    end
end

--[[--
One stroke's screen pixels as PDF page coordinates.

Every stroke carries the view transform that was in force when it was drawn
(see `FingerInk:pageTransform`), so this stays exact however the view has been
zoomed or panned since, and works for pages other than the one on screen.
Strokes drawn in a view with no page mapping at all carry no transform and are
the ones this returns nil for.
]]
local function toPagePoints(s)
    local t = s.t
    if not t then return nil end
    local pts = {}
    for i = 1, s.n do
        pts[i] = {
            x = (s[i * 2 - 1] + t.x) / t.z,
            y = (s[i * 2] + t.y) / t.z,
        }
    end
    return pts
end

--[[--
Strokes bucketed by line width, because border width belongs to the annotation
rather than to each ink list within it.

A page of handwriting is one or two buckets, so this writes a couple of
annotation objects per page instead of one per stroke.
]]
local function bucketByWidth(list)
    local widths, buckets, skipped = {}, {}, 0
    for i = 1, #list do
        local s = list[i]
        local pts = toPagePoints(s)
        if not pts then
            skipped = skipped + 1
        else
            -- Rounded, so strokes drawn at fractionally different zoom levels
            -- still share a bucket instead of each getting its own annotation.
            local w = math.floor(s.w / s.t.z * 100 + 0.5) / 100
            local bucket = buckets[w]
            if not bucket then
                bucket = {}
                buckets[w] = bucket
                widths[#widths + 1] = w
            end
            bucket[#bucket + 1] = pts
        end
    end
    return widths, buckets, skipped
end

--- Add one page's ink to the in-memory document. Returns written, skipped.
local function addPage(doc, store, page)
    local list = store:get(page)
    if not list or #list == 0 then return 0, 0 end

    local widths, buckets, skipped = bucketByWidth(list)
    if #widths == 0 then return 0, skipped end

    local pg = doc._document:openPage(page)
    if not pg.addInkAnnotation then
        pg:close()
        error(_("This KOReader build cannot write ink annotations"), 0)
    end
    for i = 1, #widths do
        local w = widths[i]
        pg:addInkAnnotation(buckets[w], INK_RGB, w, OPACITY)
    end
    pg:close()

    return #list - skipped, skipped
end

--- Forget strokes that are now in the PDF, so paintTo stops drawing them on
--- top of the annotation MuPDF renders.
local function dropSaved(store, page)
    local list = store:get(page)
    if not list then return end
    for i = #list, 1, -1 do
        if list[i].t then store:removeAt(page, i) end
    end
end

--[[--
Write the ink on `pages` into the PDF file.

Returns written, skipped — or nil and a reason. Nothing leaves the store until
the file itself has been written, so a failure anywhere loses no ink.

The write is deliberately immediate rather than setting `is_edited` and leaving
it to `PdfDocument:close`: ReaderUI discards pending document edits on close
unless the unrelated "save highlights into PDF" setting happens to be on.
]]
function InkPdf.save(ui, store, pages)
    local blocked = InkPdf.blocker(ui)
    if blocked then return nil, blocked end

    local doc = ui.document
    local written, skipped, saved_pages = 0, 0, {}

    local ok, err = pcall(function()
        for i = 1, #pages do
            local n, s = addPage(doc, store, pages[i])
            if n > 0 then saved_pages[#saved_pages + 1] = pages[i] end
            written = written + n
            skipped = skipped + s
        end
        -- Same filename, so MuPDF appends an incremental update rather than
        -- rewriting the whole file.
        if written > 0 then doc:writeDocument() end
    end)

    if not ok then
        logger.warn("FingerInk: could not write ink into", doc.file, "-", err)
        return nil, type(err) == "string" and err or _("Could not write to the PDF")
    end

    for i = 1, #saved_pages do
        dropSaved(store, saved_pages[i])
    end
    if written > 0 then
        -- The ink is part of the page now; the rendered tiles are stale.
        doc:resetTileCacheValidity()
    end
    return written, skipped
end

return InkPdf
