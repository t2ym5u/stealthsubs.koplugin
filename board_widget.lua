local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local Blitbuffer     = require("ffi/blitbuffer")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText     = require("ui/rendertext")
local UIManager      = require("ui/uimanager")

local Board = lrequire("board")

local C_BG     = Blitbuffer.COLOR_WHITE
local C_FG     = Blitbuffer.COLOR_BLACK
local C_GRID   = Blitbuffer.COLOR_GRAY_B
local C_LAND   = Blitbuffer.COLOR_GRAY_5
local C_TRAIL  = Blitbuffer.COLOR_GRAY_7
local C_MAYBE  = Blitbuffer.COLOR_GRAY_D
local C_SECTOR = Blitbuffer.COLOR_GRAY_7
local C_NUMBER = Blitbuffer.COLOR_GRAY_B

local function bsearchFont(lo, hi, max_w, max_h, sample)
    local best = lo
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local m = RenderText:sizeUtf8Text(0, math.huge, Font:getFace("cfont", mid), sample, true, false)
        if m.x <= max_w and (m.y_top + m.y_bottom) <= max_h then
            best, lo = mid, mid + 1
        else
            hi = mid - 1
        end
    end
    return best
end

local function centeredText(bb, text, face, cx, cy, color)
    local m = RenderText:sizeUtf8Text(0, math.huge, face, text, true, false)
    RenderText:renderUtf8Text(bb, cx - math.floor(m.x / 2), cy + math.floor((m.y_top - m.y_bottom) / 2),
        face, text, true, false, color or C_FG)
end

local function cross(bb, x, y, size, thick, color)
    local pad = math.floor(size * 0.25)
    for i = 0, size - 2 * pad do
        bb:paintRect(x + pad + i, y + pad + i, thick, thick, color)
        bb:paintRect(x + size - pad - i - thick, y + pad + i, thick, thick, color)
    end
end

-- ---------------------------------------------------------------------------
-- SeaMap — the sea with A.. / 1.. labels and the four sectors.
--   view = "me":   islands, my trail and my submarine
--   view = "them": islands, where the enemy can be, my torpedoes
-- ---------------------------------------------------------------------------

local SeaMap = InputContainer:extend{
    board      = nil,
    view       = "me",
    show_candidates = true,
    max_width  = 0,
    max_height = 0,
    getSelected  = nil,   -- function() -> r, c
    onCellTapped = nil,
}

function SeaMap:init()
    local n = self.board.n
    local cell = math.floor(math.min(self.max_width, self.max_height) / (n + 0.7))
    self.cell = math.max(cell, 14)
    self.band = math.floor(self.cell * 0.7)
    local side = self.band + n * self.cell
    self.dimen = Geom:new{ w = side, h = side }
    local fit = math.floor(self.band * 0.75)
    self.label_face = Font:getFace("cfont", bsearchFont(6, math.max(6, self.band), fit, fit, "10"))
    local sfit = math.floor(self.cell * 1.2)
    self.sector_face = Font:getFace("cfont", bsearchFont(8, math.max(8, 2 * self.cell), sfit, sfit, "4"))
    self.ges_events = {
        TapCell = { GestureRange:new{ ges = "tap", range = function() return self.paint_rect end } },
    }
end

function SeaMap:onTapCell(_, ges)
    if not self.paint_rect then return false end
    local c = math.floor((ges.pos.x - self.paint_rect.x - self.band) / self.cell) + 1
    local r = math.floor((ges.pos.y - self.paint_rect.y - self.band) / self.cell) + 1
    local n = self.board.n
    if r >= 1 and r <= n and c >= 1 and c <= n and self.onCellTapped then
        self.onCellTapped(r, c)
    end
    return true
end

function SeaMap:paintTo(bb, x, y)
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }
    local b, n, cell, band = self.board, self.board.n, self.cell, self.band
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)
    for i = 1, n do
        centeredText(bb, string.char(64 + i), self.label_face,
            x + band + (i - 1) * cell + math.floor(cell / 2), y + math.floor(band / 2))
        centeredText(bb, tostring(i), self.label_face,
            x + math.floor(band / 2), y + band + (i - 1) * cell + math.floor(cell / 2))
    end
    local gx, gy = x + band, y + band

    local dot = math.max(2, math.floor(cell / 9))
    for r = 1, n do
        for c = 1, n do
            local cx, cy = gx + (c - 1) * cell, gy + (r - 1) * cell
            if b.sea.land[r][c] then
                bb:paintRect(cx, cy, cell, cell, C_LAND)
            elseif self.view == "me" then
                if b.trail[r * 100 + c] then
                    bb:paintCircle(cx + math.floor(cell / 2), cy + math.floor(cell / 2), dot, C_TRAIL)
                end
            elseif self.show_candidates and b:isCandidate(r, c) then
                bb:paintRect(cx + 1, cy + 1, cell - 2, cell - 2, C_MAYBE)
                bb:paintCircle(cx + math.floor(cell / 2), cy + math.floor(cell / 2), dot, C_FG)
            end
        end
    end

    -- Sector numbers, faint, in the middle of each quarter (over the
    -- islands, so none is ever hidden).
    local half = n / 2
    for s = 1, 4 do
        local qr = s > 2 and 1 or 0
        local qc = (s % 2 == 0) and 1 or 0
        centeredText(bb, tostring(s), self.sector_face,
            gx + math.floor((qc + 0.5) * half * cell), gy + math.floor((qr + 0.5) * half * cell), C_NUMBER)
    end

    -- My torpedoes, on the opponent's map.
    local thick = math.max(2, math.floor(cell / 12))
    if self.view == "them" then
        for _, shot in ipairs(b.my_shots) do
            cross(bb, gx + (shot.c - 1) * cell, gy + (shot.r - 1) * cell, cell, thick, C_FG)
        end
    elseif b.pos then
        -- My submarine: a hull with a tower.
        local cx, cy = gx + (b.pos[2] - 1) * cell, gy + (b.pos[1] - 1) * cell
        local mx = cx + math.floor(cell / 2)
        local hw, hh = math.floor(cell * 0.3), math.floor(cell * 0.26)
        local hy = cy + math.floor(cell * 0.5)
        bb:paintRect(mx - hw, hy, 2 * hw, hh, C_FG)
        bb:paintCircle(mx - hw, hy + math.floor(hh / 2), math.floor(hh / 2), C_FG)
        bb:paintCircle(mx + hw, hy + math.floor(hh / 2), math.floor(hh / 2), C_FG)
        bb:paintRect(mx - math.floor(cell * 0.12), cy + math.floor(cell * 0.28), math.floor(cell * 0.2), math.floor(cell * 0.24), C_FG)
        bb:paintRect(mx - math.floor(cell * 0.02), cy + math.floor(cell * 0.18), math.max(2, math.floor(cell / 20)), math.floor(cell * 0.12), C_FG)
    end

    -- Grid, sector lines, frame.
    for i = 0, n do
        local edge = i == 0 or i == n
        local mid = i == n / 2
        local w = (edge or mid) and 2 or 1
        local color = edge and C_FG or (mid and C_SECTOR or C_GRID)
        local off = i == n and w - 1 or 0
        bb:paintRect(gx + i * cell - off, gy, w, n * cell, color)
        bb:paintRect(gx, gy + i * cell - off, n * cell, w, color)
    end

    local r, c
    if self.getSelected then r, c = self.getSelected() end
    if r then
        local frame = math.max(3, math.floor(cell / 8))
        bb:paintBorder(gx + (c - 1) * cell - 1, gy + (r - 1) * cell - 1, cell + 2, cell + 2, frame, C_FG)
    end
end

function SeaMap:refresh()
    UIManager:setDirty(self, function()
        return "ui", self.paint_rect or self.dimen
    end)
end

return SeaMap
