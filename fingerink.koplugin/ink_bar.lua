--[[--
The always-reachable side toolbar.

A real KOReader widget, so the buttons render and behave natively. It sits
above ReaderUI in the UIManager stack, which means taps land on it before
anything else — including while the plugin is swallowing single-finger input,
because the capture handler passes through any contact that starts inside
`self.dimen`. See ADR-8.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Screen = Device.screen

local InkBar = WidgetContainer:extend{
    plugin = nil,   -- the FingerInk instance
    side = "right",
}

function InkBar:mkButton(text, width, cb)
    return Button:new{
        text = text,
        width = width,
        radius = Size.radius.button,
        show_parent = self,
        callback = cb,
    }
end

function InkBar:init()
    local p = self.plugin
    local w = math.floor(Screen:getWidth() * 0.15)

    self.draw_btn = self:mkButton(_("Draw"), w, function()
        p:setDrawing(not p.drawing)
    end)
    self.tool_btn = self:mkButton(_("Pen"), w, function()
        p:setEraser(not p.eraser)
    end)
    self.undo_btn = self:mkButton(_("Undo"), w, function()
        p:onFingerInkUndo()
    end)
    self.hide_btn = self:mkButton(_("Hide"), w, function()
        p:setBarShown(false)
    end)

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.small,
        margin = 0,
        VerticalGroup:new{
            align = "center",
            self.draw_btn,
            self.tool_btn,
            self.undo_btn,
            self.hide_btn,
        },
    }

    local size = self[1]:getSize()
    local pad = Size.padding.large
    local x = (self.side == "left") and pad
        or (Screen:getWidth() - size.w - pad)
    self.dimen = Geom:new{
        x = x,
        y = math.floor((Screen:getHeight() - size.h) / 2),
        w = size.w,
        h = size.h,
    }
    self:update(false)
end

function InkBar:getSize()
    return self.dimen
end

function InkBar:paintTo(bb, x, y)
    self[1]:paintTo(bb, self.dimen.x, self.dimen.y)
end

--- Relabel the two stateful buttons. Pass true to also repaint.
function InkBar:update(refresh)
    local p = self.plugin
    self.draw_btn:setText(p.drawing and _("Stop") or _("Draw"), self.draw_btn.width)
    self.tool_btn:setText(p.eraser and _("Eraser") or _("Pen"), self.tool_btn.width)
    if refresh then
        UIManager:setDirty(self, "ui", self.dimen)
    end
end

function InkBar:contains(x, y)
    local d = self.dimen
    return x >= d.x and x < d.x + d.w and y >= d.y and y < d.y + d.h
end

return InkBar
