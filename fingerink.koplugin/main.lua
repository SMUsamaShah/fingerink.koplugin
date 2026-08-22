--[[--
Finger Ink — draw on book pages with a finger.

The side toolbar is the control surface: it is a normal widget sitting above
ReaderUI, and the capture handler passes through any contact that starts inside
it, so Draw/Stop stays reachable even while every other single-finger touch is
being swallowed. Drawing can never be on without the toolbar visible.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Capture = require("ink_capture")
local InkBar = require("ink_bar")
local InkPdf = require("ink_pdf")
local Render = require("ink_render")
local Store = require("ink_store")

local Screen = Device.screen
local INK = Blitbuffer.COLOR_BLACK

local PEN_THIN, PEN_MEDIUM, PEN_THICK = 2, 4, 7
local ERASER_RADIUS = 18
local SETTING_KEY = "fingerink_strokes"
local SUSPENDED = -1   -- draw_slot sentinel: ignore this contact until it lifts

local FingerInk = WidgetContainer:extend{
    name = "fingerink",
    is_doc_only = true,
}

-- ---------------------------------------------------------------- lifecycle

function FingerInk:init()
    self.drawing = false
    self.eraser = false
    self.bar = nil
    self.pen_width = G_reader_settings:readSetting("fingerink_pen_width") or PEN_MEDIUM
    self.live_fast = G_reader_settings:readSetting("fingerink_live_fast") ~= false
    self.bar_side = G_reader_settings:readSetting("fingerink_bar_side") or "right"

    self.contacts = {}
    self.n_contacts = 0
    self.passthrough = false
    self.draw_slot = nil
    self.stroke = nil

    self.store = Store.new(self.ui.doc_settings:readSetting(SETTING_KEY))

    self:registerDispatcher()
    self.ui.menu:registerToMainMenu(self)
    self.view:registerViewModule("fingerink", self)

    if G_reader_settings:readSetting("fingerink_bar_shown") ~= false then
        UIManager:nextTick(function() self:setBarShown(true) end)
    end
end

function FingerInk:registerDispatcher()
    Dispatcher:registerAction("fingerink_toggle", {
        category = "none", event = "FingerInkToggle", reader = true,
        title = _("Finger Ink: toggle drawing"),
    })
    Dispatcher:registerAction("fingerink_eraser", {
        category = "none", event = "FingerInkEraser", reader = true,
        title = _("Finger Ink: toggle eraser"),
    })
    Dispatcher:registerAction("fingerink_undo", {
        category = "none", event = "FingerInkUndo", reader = true,
        title = _("Finger Ink: undo stroke"),
    })
    Dispatcher:registerAction("fingerink_bar", {
        category = "none", event = "FingerInkBar", reader = true,
        title = _("Finger Ink: toggle toolbar"),
    })
end

function FingerInk:onCloseDocument()
    self:teardown()
end

function FingerInk:onCloseWidget()
    self:teardown()
end

function FingerInk:onSuspend()
    self:setDrawing(false)
end

function FingerInk:teardown()
    Capture:remove()
    self.drawing = false
    if self.bar then
        UIManager:close(self.bar)
        self.bar = nil
    end
end

function FingerInk:onSaveSettings()
    if self.store:isEmpty() then
        self.ui.doc_settings:delSetting(SETTING_KEY)
    else
        self.ui.doc_settings:saveSetting(SETTING_KEY, self.store.pages)
    end
end

--- Rotation and resize invalidate the bar's fixed position; rebuild it.
function FingerInk:rebuildBar()
    if not self.bar then return end
    UIManager:close(self.bar)
    self.bar = nil
    UIManager:nextTick(function() self:setBarShown(true) end)
end

function FingerInk:onScreenResize()
    self:rebuildBar()
end

function FingerInk:onSetRotationMode()
    self:rebuildBar()
end

-- ----------------------------------------------------------------- toolbar

function FingerInk:setBarShown(on)
    on = on and true or false
    G_reader_settings:saveSetting("fingerink_bar_shown", on)

    if on then
        if self.bar then return end
        self.bar = InkBar:new{ plugin = self, side = self.bar_side }
        UIManager:show(self.bar, "ui", self.bar.dimen)
    else
        -- Invariant: drawing is never on without a way to turn it off.
        self:setDrawing(false)
        if not self.bar then return end
        local dimen = self.bar.dimen
        UIManager:close(self.bar)
        self.bar = nil
        UIManager:setDirty(self.ui, "ui", dimen)
    end
end

function FingerInk:onFingerInkBar()
    self:setBarShown(self.bar == nil)
    return true
end

function FingerInk:inBar(x, y)
    return self.bar ~= nil and self.bar:contains(x, y)
end

--[[--
True while a menu or dialog is open over the reader.

Drawing mode eats single-finger touches before UIManager ever sees them, which
would otherwise make an open menu impossible to dismiss — tapping outside it is
the only way to close one. So drawing yields for as long as one is up.
]]
function FingerInk:dialogOnTop()
    local below = self.bar and self.bar:windowBelow()
    return below ~= nil and below ~= self.ui
end

-- ------------------------------------------------------------------- state

function FingerInk:notify(text)
    UIManager:show(Notification:new{ text = text })
end

function FingerInk:currentPage()
    return self.view.state.page or 1
end

--[[--
The screen-to-page mapping in force right now, or nil if this view has none.

`page = (screen + t) / t.z`, the inverse of ReaderView:getSinglePagePosition.
Recorded with every stroke so that ink can be turned into PDF page coordinates
later on — whatever the view has been zoomed or panned to since, and for pages
other than the one on screen, whose zoom and offset differ. See ADR-11.

nil for the views whose coordinates do not map back to a PDF page at all:
reflowable documents, reflowed PDFs, scroll mode and rotated pages.
]]
function FingerInk:pageTransform()
    local doc = self.ui.document
    if not doc.is_pdf or not self.ui.paging then return end
    if self.view.page_scroll then return end
    if doc.configurable and doc.configurable.text_wrap == 1 then return end

    local state = self.view.state
    if state.rotation ~= 0 then return end

    local area, offset = self.view.visible_area, state.offset
    if not area or not offset then return end
    return { z = state.zoom, x = area.x - offset.x, y = area.y - offset.y }
end

function FingerInk:setDrawing(on)
    on = on and true or false
    if on == self.drawing then return end

    if on then
        if not self.bar then self:setBarShown(true) end
        local ok = Capture:install(function(slots) return self:onTouchFrame(slots) end)
        if not ok then
            logger.warn("FingerInk: no gesture_detector to hook")
            self:notify(_("Finger Ink: cannot hook touch input"))
            return
        end
        self.drawing = true
    else
        self:abortStroke()
        Capture:remove()
        self:resetContacts()
        self.drawing = false
    end
    if self.bar then self.bar:update(true) end
end

function FingerInk:setEraser(on)
    self.eraser = on and true or false
    if self.eraser and not self.drawing then
        self:setDrawing(true)   -- also updates the bar
    elseif self.bar then
        self.bar:update(true)
    end
end

function FingerInk:resetContacts()
    for slot in pairs(self.contacts) do
        self.contacts[slot] = nil
    end
    self.n_contacts = 0
    self.passthrough = false
    self.draw_slot = nil
end

function FingerInk:onFingerInkToggle()
    self:setDrawing(not self.drawing)
    return true
end

function FingerInk:onFingerInkEraser()
    self:setEraser(not self.eraser)
    return true
end

-- ------------------------------------------------------------------- input

--[[--
Called on every touch frame while drawing mode is on, before GestureDetector
sees it. Returns true if the frame's gesture events should reach the app.
]]
function FingerInk:onTouchFrame(slots)
    if not self.passthrough and self:dialogOnTop() then
        -- Latches for the whole contact sequence, and re-latches on the next
        -- one, so drawing resumes by itself once the dialog is gone.
        self.passthrough = true
        self:abortStroke()
    end

    local was_passthrough = self.passthrough

    for i = 1, #slots do
        local ev = slots[i]
        local slot = ev.slot or 0
        local id = ev.id

        if id and id >= 0 then
            if not self.contacts[slot] then
                self.contacts[slot] = true
                self.n_contacts = self.n_contacts + 1
                if self.n_contacts > 1 and not self.passthrough then
                    self.passthrough = true
                    self:abortStroke()
                end
            end
            if not self.passthrough and ev.x and ev.y then
                self:onContactPoint(slot, ev.x, ev.y)
            end
        else
            if self.contacts[slot] then
                self.contacts[slot] = nil
                self.n_contacts = self.n_contacts - 1
            end
            if self.n_contacts <= 0 then
                self.n_contacts = 0
                if not self.passthrough then
                    self:endStroke()
                end
                self.passthrough = false
                self.draw_slot = nil
            end
        end
    end

    return self.passthrough or was_passthrough
end

function FingerInk:onContactPoint(slot, raw_x, raw_y)
    local x, y = Capture.toScreen(raw_x, raw_y)

    if self.draw_slot == nil then
        if self:inBar(x, y) then
            -- Contact started on the toolbar: hand the whole sequence to
            -- GestureDetector so the button gets its tap.
            self.passthrough = true
            self:abortStroke()
            return
        end
        self.draw_slot = slot
    elseif self.draw_slot ~= slot then
        return
    end

    if self:inBar(x, y) then
        -- Dragged onto the toolbar. End the stroke at the edge rather than
        -- painting over the buttons.
        self:endStroke()
        self.draw_slot = SUSPENDED
        return
    end

    if self.eraser then
        self:eraseAt(x, y)
    elseif self.stroke then
        self:addPoint(x, y)
    else
        self:startStroke(x, y)
    end
end

-- ------------------------------------------------------------------ stroke

function FingerInk:startStroke(x, y)
    self.stroke = { n = 1, w = self.pen_width, x, y }
end

function FingerInk:addPoint(x, y)
    local s = self.stroke
    local i = s.n * 2
    local px, py = s[i - 1], s[i]
    if px == x and py == y then return end

    s[i + 1] = x
    s[i + 2] = y
    s.n = s.n + 1

    Render.segment(Screen.bb, px, py, x, y, s.w, INK)
    self:refreshBox(px, py, x, y, s.w)
end

function FingerInk:endStroke()
    local s = self.stroke
    self.stroke = nil
    self.draw_slot = nil
    if not s then return end

    if s.n == 1 then -- a dot: never painted live, paint it now
        Render.stroke(Screen.bb, s, 0, 0, INK)
        self:refreshBox(s[1], s[2], s[1], s[2], s.w)
    end
    s.t = self:pageTransform()
    self.store:add(self:currentPage(), s)
end

function FingerInk:abortStroke()
    if not self.stroke then
        self.draw_slot = nil
        return
    end
    self.stroke = nil
    self.draw_slot = nil
    self:repaint()
end

function FingerInk:eraseAt(x, y)
    local page = self:currentPage()
    local list = self.store:get(page)
    local idx = Store.hit(list, x, y, ERASER_RADIUS)
    if not idx then return end
    self.store:removeAt(page, idx)
    self:repaint()
end

-- ------------------------------------------------------------------ output

function FingerInk:paintTo(bb, x, y)
    local list = self.store:get(self:currentPage())
    if not list then return end
    for i = 1, #list do
        Render.stroke(bb, list[i], 0, 0, INK)
    end
end

function FingerInk:repaint(refresh)
    UIManager:setDirty(self.ui, refresh or "ui")
end

--- DU refresh over the padded bounding box of one segment, clamped to screen.
function FingerInk:refreshBox(x0, y0, x1, y1, w)
    local pad = w + 2
    local x = (x0 < x1 and x0 or x1) - pad
    local y = (y0 < y1 and y0 or y1) - pad
    local bw = (x0 < x1 and x1 - x0 or x0 - x1) + 2 * pad
    local bh = (y0 < y1 and y1 - y0 or y0 - y1) + 2 * pad

    if x < 0 then bw = bw + x; x = 0 end
    if y < 0 then bh = bh + y; y = 0 end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    if x + bw > sw then bw = sw - x end
    if y + bh > sh then bh = sh - y end
    if bw <= 0 or bh <= 0 then return end

    if self.live_fast then
        Screen:refreshFast(x, y, bw, bh)
    else
        Screen:refreshPartial(x, y, bw, bh)
    end
end

-- -------------------------------------------------------------------- menu

function FingerInk:onFingerInkUndo()
    local page = self:currentPage()
    if not self.store:pop(page) then
        self:notify(_("Nothing to undo on this page"))
        return true
    end
    self:repaint()
    return true
end

--[[--
Hand the ink on `pages` to the PDF and say what happened.

Strokes drawn in a view that does not map onto a page are counted as skipped
and stay in the store, so nothing is silently lost.
]]
function FingerInk:saveInk(pages)
    local written, skipped = InkPdf.save(self.ui, self.store, pages)
    if written == nil then
        self:notify(skipped)   -- on failure the second value is the reason
        return
    end
    if written == 0 then
        self:notify(skipped > 0
            and _("This ink cannot be placed on a page, nothing saved")
            or _("No ink to save"))
        return
    end

    -- The ink is drawn by MuPDF now, so the whole page has to come back.
    self:repaint("full")
    self:notify(skipped > 0
        and T(_("Saved %1 strokes into the PDF, %2 skipped"), written, skipped)
        or T(_("Saved %1 strokes into the PDF"), written))
end

function FingerInk:setPenWidth(w)
    self.pen_width = w
    G_reader_settings:saveSetting("fingerink_pen_width", w)
end

function FingerInk:penItem(text, w)
    return {
        text = text,
        checked_func = function() return self.pen_width == w end,
        radio = true,
        callback = function() self:setPenWidth(w) end,
    }
end

function FingerInk:sideItem(text, side)
    return {
        text = text,
        checked_func = function() return self.bar_side == side end,
        radio = true,
        callback = function()
            if self.bar_side == side then return end
            self.bar_side = side
            G_reader_settings:saveSetting("fingerink_bar_side", side)
            self:rebuildBar()
        end,
    }
end

function FingerInk:addToMainMenu(menu_items)
    menu_items.fingerink = {
        text = _("Finger Ink"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                -- Deliberately closes the menu: turning drawing on swallows
                -- single-finger taps, so an open menu would be unusable.
                text = _("Start drawing"),
                enabled_func = function() return not self.drawing end,
                callback = function() self:setDrawing(true) end,
                help_text = _([[Use the Draw/Stop button on the side toolbar to switch drawing off again. Two fingers also work as usual while drawing is on.]]),
            },
            {
                text = _("Show toolbar"),
                checked_func = function() return self.bar ~= nil end,
                check_callback_updates_menu = true,
                callback = function(touchmenu_instance)
                    self:setBarShown(self.bar == nil)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            {
                text = _("Toolbar side"),
                separator = true,
                sub_item_table = {
                    self:sideItem(_("Left"), "left"),
                    self:sideItem(_("Right"), "right"),
                },
            },
            {
                text = _("Pen width"),
                sub_item_table = {
                    self:penItem(_("Thin"), PEN_THIN),
                    self:penItem(_("Medium"), PEN_MEDIUM),
                    self:penItem(_("Thick"), PEN_THICK),
                },
            },
            {
                text = _("Fast refresh while drawing"),
                checked_func = function() return self.live_fast end,
                callback = function()
                    self.live_fast = not self.live_fast
                    G_reader_settings:saveSetting("fingerink_live_fast", self.live_fast)
                end,
                help_text = _([[On: strokes appear with the DU waveform — quick, but grainy and it leaves ghosting until the next page turn. Off: slower, cleaner.]]),
                separator = true,
            },
            {
                text = _("Save this page into PDF"),
                keep_menu_open = true,
                callback = function()
                    self:saveInk({ self:currentPage() })
                end,
                help_text = _([[Writes the ink as a real PDF ink annotation, so it shows up in any PDF reader rather than only here. It stops being Finger Ink's, so it can no longer be undone or erased with the eraser — clear it in a PDF editor instead.]]),
            },
            {
                text = _("Save whole document into PDF"),
                keep_menu_open = true,
                separator = true,
                callback = function()
                    local blocked = InkPdf.blocker(self.ui)
                    if blocked then
                        self:notify(blocked)
                        return
                    end
                    local pages = self.store:pageList()
                    if #pages == 0 then
                        self:notify(_("No ink in this document"))
                        return
                    end
                    UIManager:show(ConfirmBox:new{
                        text = _("Write all ink into the PDF? It becomes a normal annotation and can no longer be undone or erased here."),
                        ok_text = _("Save"),
                        ok_callback = function() self:saveInk(pages) end,
                    })
                end,
            },
            {
                text = _("Clear this page"),
                keep_menu_open = true,
                callback = function()
                    if self.store:clearPage(self:currentPage()) then
                        self:repaint()
                    else
                        self:notify(_("No ink on this page"))
                    end
                end,
            },
            {
                text = _("Clear whole document"),
                keep_menu_open = true,
                callback = function()
                    if self.store:countPages() == 0 then
                        self:notify(_("No ink in this document"))
                        return
                    end
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete all ink in this document?"),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            self.store:clearAll()
                            self:repaint()
                        end,
                    })
                end,
            },
        },
    }
end

return FingerInk
