--[[--
Tests that need no running KOReader.

The plugin modules are loaded for real; the KOReader modules they pull in are
stubbed below, just far enough to reproduce the behaviour under test — Widget's
event dispatch, and a PdfDocument that records what it was asked to write.

    luajit test.lua
]]

package.path = "fingerink.koplugin/?.lua;" .. package.path

-- ------------------------------------------------------------------- stubs

--[[--
Widget and WidgetContainer, verbatim in behaviour from KOReader: a container
offers an event to its children first and only handles it itself if none of
them consumed it.
]]
package.preload["ui/widget/container/widgetcontainer"] = function()
    local Widget = {}

    function Widget:extend(subclass_prototype)
        local o = subclass_prototype or {}
        setmetatable(o, self)
        self.__index = self
        return o
    end

    function Widget:new(o)
        o = self:extend(o)
        if o.init then o:init() end
        return o
    end

    function Widget:handleEvent(event)
        if self[event.handler] then
            return self[event.handler](self, unpack(event.args, 1, event.argc))
        end
    end

    local WidgetContainer = Widget:extend{}

    function WidgetContainer:propagateEvent(event)
        for _, widget in ipairs(self) do
            if widget:handleEvent(event) then return true end
        end
        return false
    end

    function WidgetContainer:handleEvent(event)
        if not self:propagateEvent(event) then
            return Widget.handleEvent(self, event)
        else
            return true
        end
    end

    return WidgetContainer
end

package.preload["ui/event"] = function()
    local Event = {}
    function Event:new(handler, ...)
        local o = { handler = "on" .. handler, args = {...}, argc = select("#", ...) }
        setmetatable(o, self)
        self.__index = self
        return o
    end
    return Event
end

--- Consumes a tap only inside its own rectangle, as a real Button does.
package.preload["ui/widget/button"] = function()
    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    local Button = WidgetContainer:extend{}
    function Button:init() self.dimen = self.dimen or { x = 0, y = 0, w = 0, h = 0 } end
    function Button:setText(text) self.text = text end
    function Button:getSize() return { w = self.width, h = 60 } end
    function Button:onGesture(ges)
        local d = self.dimen
        if ges.pos and ges.pos.x >= d.x and ges.pos.x < d.x + d.w
           and ges.pos.y >= d.y and ges.pos.y < d.y + d.h then
            self.callback()
            return true
        end
    end
    return Button
end

package.preload["ui/widget/container/framecontainer"] = function()
    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    local FrameContainer = WidgetContainer:extend{}
    function FrameContainer:getSize() return { w = 160, h = 260 } end
    return FrameContainer
end

package.preload["ui/widget/verticalgroup"] = function()
    return require("ui/widget/container/widgetcontainer"):extend{}
end

package.preload["ui/uimanager"] = function()
    return { _window_stack = {}, setDirty = function() end,
             show = function() end, close = function() end }
end

package.preload["ui/geometry"] = function()
    local Geom = {}
    function Geom:new(o)
        o = o or {}
        setmetatable(o, self)
        self.__index = self
        return o
    end
    return Geom
end

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = "white", COLOR_BLACK = "black" }
end

package.preload["device"] = function()
    return { screen = { getWidth = function() return 1000 end,
                        getHeight = function() return 1400 end } }
end

package.preload["ui/size"] = function()
    return { radius = { button = 2, window = 4 }, border = { window = 2 },
             padding = { small = 2, large = 8 } }
end

package.preload["gettext"] = function()
    return function(s) return s end
end

package.preload["logger"] = function()
    local noop = function() end
    return { warn = noop, info = noop, dbg = noop, err = noop }
end

-- ------------------------------------------------------------------ runner

local failures, total = 0, 0

local function check(name, got, want)
    total = total + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %-44s got %-26s want %s",
                            name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %-44s %s", name, tostring(got)))
    end
end

local function section(name)
    print("\n== " .. name .. " ==")
end

-- ------------------------------------------------- toolbar input forwarding

section("toolbar input forwarding (ADR-10)")

do
    local Event = require("ui/event")
    local UIManager = require("ui/uimanager")
    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    local InkBar = require("ink_bar")

    local log = {}

    local Reader = WidgetContainer:extend{}     -- stands in for ReaderUI
    function Reader:onGesture() log[#log+1] = "reader:gesture"; return true end
    function Reader:onKeyPress() log[#log+1] = "reader:key"; return true end
    function Reader:onSuspend() log[#log+1] = "reader:suspend"; return true end

    local Menu = WidgetContainer:extend{}       -- stands in for TouchMenu
    function Menu:onGesture() log[#log+1] = "menu:closed"; return true end

    local Toast = WidgetContainer:extend{ toast = true }   -- Notification
    function Toast:onGesture() log[#log+1] = "toast:gesture"; return true end

    local plugin = { drawing = false, eraser = false }
    function plugin:setDrawing() log[#log+1] = "plugin:draw" end
    function plugin:setEraser() log[#log+1] = "plugin:eraser" end
    function plugin:onFingerInkUndo() log[#log+1] = "plugin:undo" end
    function plugin:setBarShown() log[#log+1] = "plugin:hide" end

    local bar = InkBar:new{ plugin = plugin }
    local d = bar.dimen
    local by = d.y
    for _, b in ipairs({ bar.draw_btn, bar.tool_btn, bar.undo_btn, bar.hide_btn }) do
        b.dimen = { x = d.x, y = by, w = d.w, h = 60 }
        by = by + 60
    end

    local reader, menu, toast = Reader:new{}, Menu:new{}, Toast:new{}

    -- Mirrors UIManager:sendEvent: toasts are notified but never consume, and
    -- only the topmost non-toast window is offered the event for real.
    local function sendEvent(event)
        local stack = UIManager._window_stack
        for i = #stack, 1, -1 do
            local widget = stack[i].widget
            if widget.toast then
                widget:handleEvent(event)
            else
                return widget:handleEvent(event)
            end
        end
    end

    local function tap(x, y)
        log = {}
        sendEvent(Event:new("Gesture", { ges = "tap", pos = { x = x, y = y } }))
        return table.concat(log, ",")
    end

    UIManager._window_stack = { { widget = reader }, { widget = bar } }
    check("tap on Undo runs its callback", tap(d.x + 5, d.y + 125), "plugin:undo")
    check("tap on the page reaches the reader", tap(10, 10), "reader:gesture")
    check("tap on the bar's border is swallowed", tap(d.x + 5, d.y + d.h - 5), "")

    -- The reported bug: toolbar shown from an open menu left it unclosable.
    UIManager._window_stack = { { widget = reader }, { widget = menu }, { widget = bar } }
    check("tap on the page reaches the menu", tap(10, 10), "menu:closed")
    check("bar buttons still work over a menu", tap(d.x + 5, d.y + 5), "plugin:draw")

    UIManager._window_stack = { { widget = reader }, { widget = bar }, { widget = toast } }
    check("a toast does not absorb the forward", tap(10, 10), "toast:gesture,reader:gesture")

    UIManager._window_stack = { { widget = reader }, { widget = bar } }
    log = {}
    bar:handleEvent(Event:new("KeyPress", "RPgFwd"))
    check("keypresses forward to the reader", table.concat(log, ","), "reader:key")

    log = {}
    bar:handleEvent(Event:new("Suspend"))
    check("broadcast events are not forwarded", table.concat(log, ","), "")

    -- FingerInk:dialogOnTop, which makes drawing yield while a dialog is up.
    local function dialogOnTop()
        local below = bar:windowBelow()
        return below ~= nil and below ~= reader
    end
    UIManager._window_stack = { { widget = reader }, { widget = bar } }
    check("reader alone is not a dialog", tostring(dialogOnTop()), "false")
    UIManager._window_stack = { { widget = reader }, { widget = menu }, { widget = bar } }
    check("an open menu is a dialog", tostring(dialogOnTop()), "true")
    UIManager._window_stack = { { widget = reader }, { widget = bar }, { widget = toast } }
    check("a toast is not a dialog", tostring(dialogOnTop()), "false")
end

-- ------------------------------------------------------- PDF ink annotations

section("PDF ink annotations (ADR-11)")

do
    local Store = require("ink_store")
    local InkPdf = require("ink_pdf")
    local Transform = require("ink_transform")

    --- A stroke as the plugin stores it: flat pairs, plus n, w and the
    --- view transform captured at endStroke.
    local function stroke(w, t, ...)
        local s = { n = select("#", ...) / 2, w = w, t = t }
        for i = 1, select("#", ...) do s[i] = (select(i, ...)) end
        return s
    end

    local function fakeDoc(opts)
        opts = opts or {}
        local doc = {
            is_pdf = opts.is_pdf ~= false,
            file = "/mnt/us/book.pdf",
            writes = 0,
            cache_resets = 0,
            annots = {},
        }
        function doc:_checkIfWritable() return opts.writable ~= false end
        function doc:writeDocument()
            if opts.write_fails then error("MuPDF: could not write document", 0) end
            self.writes = self.writes + 1
        end
        function doc:resetTileCacheValidity() self.cache_resets = self.cache_resets + 1 end
        doc._document = {
            openPage = function(_, pageno)
                local page = {}
                if not opts.no_ink_api then
                    function page:addInkAnnotation(strokes, color, width, opacity)
                        doc.annots[#doc.annots+1] = {
                            page = pageno, strokes = strokes, width = width,
                            color = color, opacity = opacity,
                        }
                    end
                end
                function page:close() self.closed = true end
                return page
            end,
        }
        return doc
    end

    local T1 = { z = 2, x = -30, y = -10 }   -- page = (screen + t) / 2

    -- Capture mappings through KOReader's real single/continuous-view API
    -- shape. Continuous view used to be rejected unconditionally.
    local sample = stroke(4, nil, 130, 110, 230, 210)
    local single_view = {
        getSinglePagePosition = function(_, pos)
            return { x = (pos.x - 30) / 2, y = (pos.y - 10) / 2,
                     page = 7, zoom = 2, rotation = 0 }
        end,
    }
    local t, page = Transform.fromStroke(single_view, sample)
    check("single-page transform page", page, 7)
    check("single-page transform x", t.x, -30)
    check("single-page transform y", t.y, -10)

    local scroll_view = {
        page_scroll = true,
        getScrollPagePosition = function(_, pos)
            if pos.y >= 300 and pos.y < 320 then return end -- page gap
            local p = pos.y < 300 and 4 or 5
            local y = p == 4 and pos.y or pos.y - 320
            return { x = pos.x / 2, y = y / 2, page = p,
                     zoom = 2, rotation = 0 }
        end,
    }
    sample = stroke(4, nil, 20, 20, 40, 40)
    t, page = Transform.fromStroke(scroll_view, sample)
    check("continuous-view transform page", page, 4)
    check("continuous-view transform captured", t.z, 2)
    sample = stroke(4, nil, 20, 290, 40, 330)
    local rejected, _, block = Transform.fromStroke(scroll_view, sample)
    check("cross-page stroke rejected", rejected, nil)
    check("cross-page reason", block, "page_boundary")
    sample = stroke(4, nil, 20, 20, 40, 40)
    single_view.getSinglePagePosition = function(_, pos)
        return { x = pos.x, y = pos.y, page = 7, zoom = 1, rotation = 90 }
    end
    rejected, _, block = Transform.fromStroke(single_view, sample)
    check("rotated stroke rejected", rejected, nil)
    check("rotated reason", block, "rotation")

    -- Conversion is ReaderView:getSinglePagePosition, inverted.
    local store = Store.new()
    store:add(7, stroke(4, T1, 130, 110, 230, 210))
    local doc = fakeDoc()
    local written, skipped = InkPdf.save({ document = doc }, store, {7})
    check("one stroke written", written, 1)
    check("none skipped", skipped, 0)
    check("one annotation created", #doc.annots, 1)
    check("on the right page", doc.annots[1].page, 7)
    check("first point x", doc.annots[1].strokes[1][1].x, (130 - 30) / 2)
    check("first point y", doc.annots[1].strokes[1][1].y, (110 - 10) / 2)
    check("last point x", doc.annots[1].strokes[1][2].x, (230 - 30) / 2)
    check("border width is pen width / zoom", doc.annots[1].width, 2)
    check("ink is black", doc.annots[1].color.r + doc.annots[1].color.g
                          + doc.annots[1].color.b, 0)
    check("written once, incrementally", doc.writes, 1)
    check("tile cache invalidated", doc.cache_resets, 1)
    check("saved strokes leave the store", store:get(7), nil)

    -- One annotation per pen width, not per stroke.
    store = Store.new()
    store:add(1, stroke(4, T1, 0, 0, 10, 10))
    store:add(1, stroke(4, T1, 20, 20, 30, 30))
    store:add(1, stroke(7, T1, 40, 40, 50, 50))
    doc = fakeDoc()
    check("all three written", (InkPdf.save({ document = doc }, store, {1})), 3)
    check("bucketed into two annotations", #doc.annots, 2)
    check("first holds two ink lists", #doc.annots[1].strokes, 2)
    check("second holds one", #doc.annots[2].strokes, 1)

    -- Strokes from a view with no page mapping stay put rather than landing wrong.
    store = Store.new()
    store:add(3, stroke(4, T1, 0, 0, 10, 10))
    store:add(3, stroke(4, nil, 20, 20, 30, 30))
    doc = fakeDoc()
    local skip_reasons
    written, skipped, skip_reasons = InkPdf.save({ document = doc }, store, {3})
    check("mappable stroke written", written, 1)
    check("unmappable stroke skipped", skipped, 1)
    check("unmapped legacy reason", skip_reasons.legacy, 1)
    check("skipped stroke kept", #store:get(3), 1)
    check("and it is the untransformed one", store:get(3)[1].t, nil)

    -- A failed write must lose no ink.
    store = Store.new()
    store:add(2, stroke(4, T1, 0, 0, 10, 10))
    doc = fakeDoc{ write_fails = true }
    local reason
    written, reason = InkPdf.save({ document = doc }, store, {2})
    check("failure reported", written, nil)
    check("actionable write reason", reason,
          "KOReader could not save changes to this PDF. Check that the file is writable and is not damaged or password-protected, then try again.")
    check("ink still in the store", #store:get(2), 1)
    check("no cache reset on failure", doc.cache_resets, 0)

    -- An older build without the MuPDF ink API fails before writing anything.
    store = Store.new()
    store:add(2, stroke(4, T1, 0, 0, 10, 10))
    doc = fakeDoc{ no_ink_api = true }
    written, reason = InkPdf.save({ document = doc }, store, {2})
    check("refused without the ink API", written, nil)
    check("explains why", reason,
          "PDF ink export requires KOReader 2026.07 or newer. Update KOReader, restart it, then try again.")
    check("ink kept", #store:get(2), 1)
    check("nothing written", doc.writes, 0)

    -- Documents that cannot take annotations are refused up front.
    store = Store.new()
    store:add(1, stroke(4, T1, 0, 0, 10, 10))
    written, reason = InkPdf.save({ document = fakeDoc{ is_pdf = false } }, store, {1})
    check("epub refused", written, nil)
    check("epub reason", reason,
          "PDF ink export only works with PDF files. Open a PDF, then try again.")
    written, reason = InkPdf.save({ document = fakeDoc{ writable = false } }, store, {1})
    check("read-only pdf refused", written, nil)
    check("read-only reason", reason,
          "KOReader cannot modify this PDF. Check its file permissions, or copy it to writable local storage, then try again.")
    check("ink untouched by either", #store:get(1), 1)

    -- Whole-document save walks every inked page, in order, writing once.
    store = Store.new()
    store:add(9, stroke(4, T1, 0, 0, 10, 10))
    store:add(2, stroke(4, T1, 0, 0, 10, 10))
    store:add(5, stroke(4, T1, 0, 0, 10, 10))
    check("page list is sorted", table.concat(store:pageList(), ","), "2,5,9")
    doc = fakeDoc()
    check("every page written", (InkPdf.save({ document = doc }, store, store:pageList())), 3)
    check("one annotation per page", #doc.annots, 3)
    check("in page order", doc.annots[1].page .. "," .. doc.annots[2].page
                           .. "," .. doc.annots[3].page, "2,5,9")
    check("store emptied", tostring(store:isEmpty()), "true")
    check("a single incremental write", doc.writes, 1)

    -- Nothing to save is not an error.
    doc = fakeDoc()
    written, skipped = InkPdf.save({ document = doc }, Store.new(), {4})
    check("nothing written", written, 0)
    check("nothing skipped", skipped, 0)
    check("no pointless write", doc.writes, 0)
end

-- ----------------------------------------------------------------- summary

print("")
if failures == 0 then
    print(total .. " checks, all passed")
else
    print(total .. " checks, " .. failures .. " FAILED")
end
os.exit(failures == 0 and 0 or 1)
