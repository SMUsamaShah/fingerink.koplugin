--[[--
Per-page stroke storage.

pages = { [page] = { stroke, stroke, ... } }
stroke = { n = <points>, w = <width>, t = <transform>,
           pdf_block = <reason>, x1, y1, x2, y2, ... }

`t` is the screen-to-page mapping in force when the stroke was drawn,
`{ z = zoom, x = , y = }`, used to turn the stroke into PDF page coordinates
later. See FingerInk:pageTransform. It is absent for strokes drawn in a view
that has no safe page mapping (for example reflow, rotation, or a stroke across
a page gap). `pdf_block` records why so the save notice can explain the remedy;
old strokes without either field are reported as legacy ink.

This table goes straight into the document sidecar, so it must stay made of
plain numbers and plain tables.
]]

local Store = {}
Store.__index = Store

function Store.new(pages)
    return setmetatable({ pages = pages or {} }, Store)
end

function Store:get(page)
    return self.pages[page]
end

function Store:add(page, stroke)
    local list = self.pages[page]
    if not list then
        list = {}
        self.pages[page] = list
    end
    list[#list + 1] = stroke
end

--- Remove and return the last stroke on a page, or nil.
function Store:pop(page)
    local list = self.pages[page]
    if not list then return nil end
    local n = #list
    if n == 0 then return nil end
    local s = list[n]
    list[n] = nil
    if n == 1 then self.pages[page] = nil end
    return s
end

function Store:removeAt(page, idx)
    local list = self.pages[page]
    if not list or not list[idx] then return false end
    table.remove(list, idx)
    if #list == 0 then self.pages[page] = nil end
    return true
end

function Store:clearPage(page)
    if not self.pages[page] then return false end
    self.pages[page] = nil
    return true
end

function Store:clearAll()
    self.pages = {}
end

function Store:isEmpty()
    return next(self.pages) == nil
end

--- Page numbers that hold ink, ascending.
function Store:pageList()
    local pages = {}
    for page in pairs(self.pages) do
        pages[#pages + 1] = page
    end
    table.sort(pages)
    return pages
end

function Store:countPages()
    local n = 0
    for _ in pairs(self.pages) do n = n + 1 end
    return n
end

--[[--
Index of the topmost stroke with a stored point within r of (x,y), or nil.
Squared distance, back to front, no allocation. Point-based, not
segment-based — see ADR-7.
]]
function Store.hit(list, x, y, r)
    if not list then return nil end
    local r2 = r * r
    for i = #list, 1, -1 do
        local s = list[i]
        for j = 1, s.n * 2, 2 do
            local dx = s[j] - x
            local dy = s[j + 1] - y
            if dx * dx + dy * dy <= r2 then return i end
        end
    end
    return nil
end

return Store
