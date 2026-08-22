--[[--
Touch capture for devices with no stylus.

KOReader v2026.03 has no API for observing parsed touch slots, so the only
device-agnostic place to see finger contacts is GestureDetector:feedEvent.
We wrap it, and only while drawing mode is on.

The original is always called so the detector's own state stays consistent;
we only decide whether its gesture events reach the app. See ADR-2.
]]

local Device = require("device")

local Capture = {
    installed = false,
    original = nil,
}

--- Install the wrapper. handler(slots) returns true to let gestures through.
function Capture:install(handler)
    if self.installed then return true end
    local gd = Device.input and Device.input.gesture_detector
    if not gd or not gd.feedEvent then return false end

    local original = gd.feedEvent
    self.original = original
    gd.feedEvent = function(gd_self, slots)
        local emit = handler(slots)
        local evs = original(gd_self, slots)
        if emit then return evs end
        for i = #evs, 1, -1 do
            evs[i] = nil
        end
        return evs
    end
    self.installed = true
    return true
end

function Capture:remove()
    if not self.installed then return end
    Device.input.gesture_detector.feedEvent = self.original
    self.original = nil
    self.installed = false
end

--[[--
Slot coordinates are pre-rotation; GestureDetector applies the transform after
detection, so we have to do it ourselves. Returns two numbers, no table.
]]
function Capture.toScreen(x, y)
    local screen = Device.screen
    local mode = screen:getRotationMode()
    if mode == screen.DEVICE_ROTATED_UPRIGHT then
        return x, y
    elseif mode == screen.DEVICE_ROTATED_CLOCKWISE then
        return screen:getWidth() - y, x
    elseif mode == screen.DEVICE_ROTATED_UPSIDE_DOWN then
        return screen:getWidth() - x, screen:getHeight() - y
    else -- DEVICE_ROTATED_COUNTER_CLOCKWISE
        return y, screen:getHeight() - x
    end
end

return Capture
