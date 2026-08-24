-- Screen-to-PDF-page mapping captured when a stroke ends.

local Transform = {}

-- Returns transform, page, or nil when the stroke cannot stay on one page.
function Transform.fromStroke(view, stroke)
    local position
    if view.page_scroll then
        if not view.getScrollPagePosition then return end
        position = function(x, y)
            return view:getScrollPagePosition({ x = x, y = y })
        end
    else
        if not view.getSinglePagePosition then return end
        position = function(x, y)
            return view:getSinglePagePosition({ x = x, y = y })
        end
    end

    local first = position(stroke[1], stroke[2])
    if not first or not first.zoom or first.rotation ~= 0 then return end

    for i = 2, stroke.n do
        local p = position(stroke[i * 2 - 1], stroke[i * 2])
        if not p or p.page ~= first.page or p.zoom ~= first.zoom
                or p.rotation ~= first.rotation then
            return
        end
    end

    return {
        z = first.zoom,
        x = first.x * first.zoom - stroke[1],
        y = first.y * first.zoom - stroke[2],
    }, first.page
end

return Transform
