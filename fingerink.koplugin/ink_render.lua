--[[--
Stroke rasterisation. Numbers only on every hot path — no tables are created
here, by anything, ever.
]]

local floor = math.floor

local Render = {}

--- Paint a w-wide segment from (x0,y0) to (x1,y1) into bb.
function Render.segment(bb, x0, y0, x1, y1, w, color)
    local half = floor(w / 2)
    local dx = x1 - x0
    local dy = y1 - y0
    local adx = dx >= 0 and dx or -dx
    local ady = dy >= 0 and dy or -dy
    local steps = adx > ady and adx or ady

    if steps < 1 then
        bb:paintRect(floor(x0) - half, floor(y0) - half, w, w, color)
        return
    end

    steps = floor(steps)
    local sx = dx / steps
    local sy = dy / steps
    local x, y = x0, y0
    for _ = 0, steps do
        bb:paintRect(floor(x) - half, floor(y) - half, w, w, color)
        x = x + sx
        y = y + sy
    end
end

--- Replay a whole stroke. ox/oy let a caller shift it; both are 0 today.
function Render.stroke(bb, s, ox, oy, color)
    local n = s.n
    local w = s.w
    if n < 1 then return end
    if n == 1 then
        local half = floor(w / 2)
        bb:paintRect(ox + s[1] - half, oy + s[2] - half, w, w, color)
        return
    end
    for i = 1, (n - 1) * 2, 2 do
        Render.segment(bb, ox + s[i], oy + s[i + 1],
                           ox + s[i + 2], oy + s[i + 3], w, color)
    end
end

return Render
