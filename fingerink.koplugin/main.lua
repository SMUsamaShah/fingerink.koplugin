--[[--
Finger Ink — draw on book pages with a finger.

Single finger inks. Two fingers behave normally, which is how you get back out
of drawing mode on a device with no buttons. See spec.md.
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

local Capture = require("ink_capture")
local Render = require("ink_render")
local Store = require("ink_store")

local Screen = Device.screen
local INK = Blitbuffer.COLOR_BLACK

local PEN_THIN, PEN_MEDIUM, PEN_THICK = 2, 4, 7
local ERASER_RADIUS = 18
local SETTING_KEY = "fingerink_strokes"

local FingerInk = WidgetContainer:extend{
    name = "fingerink",
    is_doc_only = true,
}

-- ---------------------------------------------------------------- lifecycle

function FingerInk:init()
    self.drawing = false
    self.eraser = false
    self.pen_width = G_reader_settings:readSetting("fingerink_pen_width") or PEN_MEDIUM
    self.live_fast = G_reader_settings:readSetting("fingerink_live_fast") ~= false

    self.contacts = {}
    self.n_contacts = 0
    self.passthrough = false
    self.draw_slot = nil
    self.stroke = nil

    self.store = Store.new(self.ui.doc_settings:readSetting(SETTING_KEY))

    self:registerDispatcher()
    self.ui.menu:registerToMainMenu(self)
    self.view:registerViewModule("fingerink", self)
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
end

function FingerInk:onCloseDocument()
    self:setDrawing(false)
end

function FingerInk:onCloseWidget()
    Capture:remove()
end

function FingerInk:onSuspend()
    self:setDrawing(false)
end

function FingerInk:onSaveSettings()
    if self.store:isEmpty() then
        self.ui.doc_settings:delSetting(SETTING_KEY)
    else
        self.ui.doc_settings:saveSetting(SETTING_KEY, self.store.pages)
    end
end

-- ------------------------------------------------------------------- state

function FingerInk:notify(text)
    UIManager:show(Notification:new{ text = text })
end

function FingerInk:currentPage()
    return self.view.state.page or 1
end

function FingerInk:setDrawing(on)
    on = on and true or false
    if on == self.drawing then return end

    if on then
        local ok = Capture:install(function(slots) return self:onTouchFrame(slots) end)
        if not ok then
            logger.warn("FingerInk: no gesture_detector to hook")
            self:notify(_("Finger Ink: cannot hook touch input"))
            return
        end
        self.drawing = true
        self:notify(_("Drawing on — two fingers for normal gestures"))
    else
        self:abortStroke()
        Capture:remove()
        self:resetContacts()
        self.drawing = false
        self:notify(_("Drawing off"))
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
    self.eraser = not self.eraser
    self:notify(self.eraser and _("Eraser") or _("Pen"))
    return true
end

-- ------------------------------------------------------------------- input

--[[--
Called on every touch frame while drawing mode is on, before GestureDetector
sees it. Returns true if the frame's gesture events should reach the app.
]]
function FingerInk:onTouchFrame(slots)
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
    if self.draw_slot == nil then
        self.draw_slot = slot
    elseif self.draw_slot ~= slot then
        return
    end

    local x, y = Capture.toScreen(raw_x, raw_y)

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

function FingerInk:repaint()
    UIManager:setDirty(self.ui, "ui")
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

function FingerInk:addToMainMenu(menu_items)
    menu_items.fingerink = {
        text = _("Finger Ink"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Drawing"),
                checked_func = function() return self.drawing end,
                check_callback_updates_menu = true,
                callback = function(touchmenu_instance)
                    self:setDrawing(not self.drawing)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                help_text = _([[While drawing is on, one finger draws and two fingers work as usual. Map "Finger Ink: toggle drawing" to a two-finger tap in Gesture Manager so you can switch it off without opening this menu.]]),
            },
            {
                text = _("Eraser"),
                checked_func = function() return self.eraser end,
                check_callback_updates_menu = true,
                callback = function(touchmenu_instance)
                    self.eraser = not self.eraser
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            {
                text = _("Pen width"),
                separator = true,
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
                text = _("Undo last stroke"),
                keep_menu_open = true,
                callback = function() self:onFingerInkUndo() end,
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
                    local n = self.store:countPages()
                    if n == 0 then
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
