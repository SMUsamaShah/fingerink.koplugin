--[[--
The always-reachable side toolbar.

A real KOReader widget, so the buttons render and behave natively. It sits
above ReaderUI in the UIManager stack, which means taps land on it before
anything else — including while the plugin is swallowing single-finger input,
because the capture handler passes through any contact that starts inside
`self.dimen`. See ADR-8.

Being the topmost window also means UIManager offers it *every* input event and
nothing else gets a look in, so input that misses the bar is forwarded to the
window underneath by hand. See ADR-10.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Screen = Device.screen

local TEXT_WIDTH_RATIO = 0.13
local TEXT_FONT_SIZE = 16
local ICON_SIZE = Screen:scaleBySize(24)
local ICON_BUTTON_WIDTH = Screen:scaleBySize(36)

-- These are all part of KOReader's built-in mdlight icon set, so the plugin
-- does not need to ship or install any image assets of its own.
local ICONS = {
    draw = "edit",
    stop = "close",
    pen = "appbar.tools",
    eraser = "cancel",
    undo = "back.top",
    hide = "exit",
}

-- Handlers for events that arrive through UIManager:sendEvent, which offers
-- them to one window only. Everything else reaches every window already.
local INPUT_HANDLERS = {
    onGesture = true,
    onKeyPress = true,
    onKeyRepeat = true,
    onKeyRelease = true,
}

local InkBar = WidgetContainer:extend{
    plugin = nil,   -- the FingerInk instance
    side = "right",
    style = "text",
    position = nil,
}

-- Keep the toolbar's outer widget stable, and report the resulting absolute
-- position back to FingerInk after every completed move.
local MovableBar = MovableContainer:extend{}

function MovableBar:_moveBy(dx, dy, restrict_to_screen)
    MovableContainer._moveBy(self, dx, dy, restrict_to_screen)
    if self.on_move then
        self.on_move(self)
    end
end

function InkBar:mkButton(text, icon, width, cb)
    local button = {
        width = width,
        radius = Size.radius.button,
        show_parent = self,
        callback = cb,
        -- Let a hold bubble up to MovableBar. Taps are still handled by the
        -- Button itself, while a long-press on any part of the panel moves it.
        readonly = true,
        padding = Size.padding.small,
    }
    if self.style == "icons" then
        button.icon = icon
        button.icon_width = ICON_SIZE
        button.icon_height = ICON_SIZE
    else
        button.text = text
        button.text_font_face = "smallinfofont"
        button.text_font_size = TEXT_FONT_SIZE
        button.text_font_bold = false
    end
    return Button:new(button)
end

function InkBar:init()
    local p = self.plugin
    self.style = self.style == "icons" and "icons" or "text"
    local w = self.style == "icons"
        and ICON_BUTTON_WIDTH
        or math.floor(Screen:getWidth() * TEXT_WIDTH_RATIO)

    self.button_width = w
    self.draw_btn = self:mkButton(
        p.drawing and _("Stop") or _("Draw"),
        p.drawing and ICONS.stop or ICONS.draw,
        w, function()
        p:setDrawing(not p.drawing)
    end)
    self.tool_btn = self:mkButton(
        p.eraser and _("Eraser") or _("Pen"),
        p.eraser and ICONS.eraser or ICONS.pen,
        w, function()
        p:setEraser(not p.eraser)
    end)
    self.undo_btn = self:mkButton(_("Undo"), ICONS.undo, w, function()
        p:onFingerInkUndo()
    end)
    self.hide_btn = self:mkButton(_("Hide"), ICONS.hide, w, function()
        p:setBarShown(false)
    end)

    local frame = FrameContainer:new{
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

    local size = frame:getSize()
    local pad = Size.padding.large
    local default_x = (self.side == "left") and pad
        or (Screen:getWidth() - size.w - pad)
    local default_y = math.floor((Screen:getHeight() - size.h) / 2)

    self.dimen = Geom:new{
        x = default_x,
        y = default_y,
        w = size.w,
        h = size.h,
    }

    local x, y = default_x, default_y
    if self.position and type(self.position.x) == "number"
       and type(self.position.y) == "number" then
        x, y = self:clampPosition(self.position.x, self.position.y)
    end

    self.movable = MovableBar:new{
        frame,
        dimen = Geom:new{
            x = default_x,
            y = default_y,
            w = size.w,
            h = size.h,
        },
        on_move = function(movable)
            -- _moveBy updates the offset before this callback, while dimen's
            -- x/y are refreshed on the following paint pass.
            local moved_x = (movable._orig_x or default_x)
                + movable._moved_offset_x
            local moved_y = (movable._orig_y or default_y)
                + movable._moved_offset_y
            local clamped_x, clamped_y = self:clampPosition(moved_x, moved_y)
            if clamped_x ~= moved_x or clamped_y ~= moved_y then
                movable:setMovedOffset(Geom:new{
                    x = clamped_x - default_x,
                    y = clamped_y - default_y,
                })
            end
            p:setBarPosition(clamped_x, clamped_y)
        end,
    }
    self.movable:setMovedOffset(Geom:new{ x = x - default_x, y = y - default_y })
    self[1] = self.movable

    self:update(false)
end

function InkBar:clampPosition(x, y)
    local max_x = math.max(0, Screen:getWidth() - self.dimen.w)
    local max_y = math.max(0, Screen:getHeight() - self.dimen.h)
    if x < 0 then x = 0 elseif x > max_x then x = max_x end
    if y < 0 then y = 0 elseif y > max_y then y = max_y end
    return x, y
end

function InkBar:getVisibleDimen()
    if not self.movable then return self.dimen end
    local d = self.movable.dimen
    -- MovableContainer updates dimen during paint, but its offset changes
    -- during the gesture event itself. Keep hit testing correct in that small
    -- interval too (and before the first paint of a restored position).
    d.x = (self.movable._orig_x or self.dimen.x)
        + (self.movable._moved_offset_x or 0)
    d.y = (self.movable._orig_y or self.dimen.y)
        + (self.movable._moved_offset_y or 0)
    return d
end

function InkBar:getSize()
    return self.dimen
end

function InkBar:paintTo(bb, x, y)
    -- Keep the outer widget at its original position. MovableBar applies its
    -- saved offset while painting and exposes the actual hit-test rectangle.
    self.movable:paintTo(bb, self.dimen.x, self.dimen.y)
end

--- Relabel or re-icon the two stateful buttons. Pass true to also repaint.
function InkBar:update(refresh)
    local p = self.plugin
    if self.style == "icons" then
        self.draw_btn:setIcon(
            p.drawing and ICONS.stop or ICONS.draw,
            self.button_width)
        self.tool_btn:setIcon(
            p.eraser and ICONS.eraser or ICONS.pen,
            self.button_width)
    else
        self.draw_btn:setText(
            p.drawing and _("Stop") or _("Draw"),
            self.button_width)
        self.tool_btn:setText(
            p.eraser and _("Eraser") or _("Pen"),
            self.button_width)
    end
    if refresh then
        UIManager:setDirty(self, "ui", self:getVisibleDimen())
    end
end

function InkBar:contains(x, y)
    local d = self:getVisibleDimen()
    return x >= d.x and x < d.x + d.w and y >= d.y and y < d.y + d.h
end

-- --------------------------------------------------------------- forwarding

--[[--
The window that would be taking input if the bar were not up: the reader
normally, a menu or dialog when one is open on top of it.

Toasts are skipped because UIManager never lets them consume input either.
]]
function InkBar:windowBelow()
    local stack = UIManager._window_stack
    for i = #stack, 1, -1 do
        local widget = stack[i].widget
        if widget ~= self and not widget.toast then return widget end
    end
end

--[[--
Swallow gestures that land on the bar but miss every button — the border, the
padding, the gaps between buttons. Without this they would be forwarded and
turn a page under the toolbar.
]]
function InkBar:onGesture(ges)
    if ges.pos and self:contains(ges.pos.x, ges.pos.y) then
        return true
    end
end

--[[--
Input nothing in the bar wanted goes to the window below.

UIManager:sendEvent only ever offers an input event to the topmost non-toast
window, so a bar that just returns false still leaves the reader — and any menu
opened underneath it — completely deaf.

Returning the callee's own result rather than a blanket true keeps UIManager's
follow-up pass over `is_always_active` and `active_widgets` windows intact.
]]
function InkBar:handleEvent(event)
    if WidgetContainer.handleEvent(self, event) then return true end
    if INPUT_HANDLERS[event.handler] then
        local below = self:windowBelow()
        if below then return below:handleEvent(event) end
    end
end

return InkBar
