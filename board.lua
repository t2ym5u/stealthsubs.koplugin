-- ---------------------------------------------------------------------------
-- board.lua — Silent Subs: two submarines on one sea, one reader each.
-- Pure Lua.
--
-- Both readers build the same sea (islands) from the game code (common/
-- duo.lua). Each player hides a submarine on their own reader and, turn by
-- turn, announces only part of what they do:
--   move     one cell north/south/east/west: say the direction only
--   torpedo  at a water cell at most TORPEDO_RANGE steps away: say the cell
--   surface  say the sector you are in; your trail is cleared
-- A submarine may not cross an island, leave the sea, or go back over its
-- own trail (since it last surfaced): when stuck, it must surface.
-- A torpedo hits the cell it lands on (2 damage) and the 8 around it (1);
-- it can hurt its own submarine too. After a torpedo, the launcher needs
-- RECHARGE moves before the next one. A submarine with HULL damage sinks.
--
-- The reader keeps a log of everything its player entered, about their own
-- submarine ("me") and about the opponent's announcements ("them"). The
-- whole state is rebuilt from that log, so Undo is just dropping its last
-- entry. From the opponent's announcements the reader works out where the
-- enemy submarine can be (`candidates`).
-- ---------------------------------------------------------------------------

local Duo = require("duo")

local Board = {}
Board.__index = Board

Board.HULL = 4
Board.TORPEDO_RANGE = 3
Board.RECHARGE = 3

Board.VARIANTS = {
    { n = 8,  islands = 7 },
    { n = 10, islands = 12 },
}

Board.DIRS = { n = { -1, 0 }, s = { 1, 0 }, w = { 0, -1 }, e = { 0, 1 } }
Board.DIR_ORDER = { "n", "e", "s", "w" }

-- ---------------------------------------------------------------------------
-- The sea
-- ---------------------------------------------------------------------------

local function waterConnected(sea)
    local n = sea.n
    local start
    local total = 0
    for r = 1, n do
        for c = 1, n do
            if not sea.land[r][c] then
                total = total + 1
                start = start or { r, c }
            end
        end
    end
    local seen, queue, head = { [start[1] * 100 + start[2]] = true }, { start }, 1
    while head <= #queue do
        local p = queue[head]
        head = head + 1
        for _, d in ipairs(Board.DIR_ORDER) do
            local r, c = p[1] + Board.DIRS[d][1], p[2] + Board.DIRS[d][2]
            if r >= 1 and r <= n and c >= 1 and c <= n and not sea.land[r][c] and not seen[r * 100 + c] then
                seen[r * 100 + c] = true
                queue[#queue + 1] = { r, c }
            end
        end
    end
    return #queue == total
end

-- Islands for (seed, variant): small blobs, never cutting the sea in two.
function Board.generate(seed, variant)
    local v = Board.VARIANTS[variant] or Board.VARIANTS[2]
    local rng = Duo.rng(seed, "stealthsubs")
    local n = v.n
    local sea = { n = n, land = {} }
    for r = 1, n do
        sea.land[r] = {}
        for c = 1, n do sea.land[r][c] = false end
    end
    local placed = 0
    local guard = 0
    while placed < v.islands and guard < 500 do
        guard = guard + 1
        local r, c = rng:random(n), rng:random(n)
        local size = rng:random(3)
        local cells = { { r, c } }
        for _i = 2, size do
            local last = cells[#cells]
            local d = Board.DIRS[rng:pick(Board.DIR_ORDER)]
            cells[#cells + 1] = { last[1] + d[1], last[2] + d[2] }
        end
        local ok = true
        for _, p in ipairs(cells) do
            if p[1] < 1 or p[1] > n or p[2] < 1 or p[2] > n then ok = false end
        end
        if ok then
            local added = {}
            for _, p in ipairs(cells) do
                if not sea.land[p[1]][p[2]] then
                    sea.land[p[1]][p[2]] = true
                    added[#added + 1] = p
                end
            end
            if waterConnected(sea) then
                placed = placed + #added
            else
                for _, p in ipairs(added) do sea.land[p[1]][p[2]] = false end
            end
        end
    end
    return sea
end

local function isWater(sea, r, c)
    return r >= 1 and r <= sea.n and c >= 1 and c <= sea.n and not sea.land[r][c]
end
Board.isWater = isWater

-- Sector 1..4 of (r, c): 1 top left, 2 top right, 3 bottom left, 4 bottom right.
function Board.sector(n, r, c)
    local half = n / 2
    return (r > half and 2 or 0) + (c > half and 2 or 1)
end

local function manhattan(r1, c1, r2, c2)
    return math.abs(r1 - r2) + math.abs(c1 - c2)
end

-- Damage a torpedo at (tr, tc) does to a submarine at (r, c).
function Board.damage(tr, tc, r, c)
    local d = math.max(math.abs(tr - r), math.abs(tc - c))
    if d == 0 then return 2 end
    if d == 1 then return 1 end
    return 0
end

-- ---------------------------------------------------------------------------
-- Game state, rebuilt from the log
-- ---------------------------------------------------------------------------

function Board.new(o)
    local self = setmetatable({}, Board)
    self.seed    = o.seed or 0
    self.variant = Board.VARIANTS[o.variant] and o.variant or 2
    self.code    = o.code
    self.sea     = Board.generate(self.seed, self.variant)
    self.n       = self.sea.n
    self.log     = o.log or {}
    self:replay()
    return self
end

function Board:serialize()
    return { seed = self.seed, variant = self.variant, code = self.code, log = self.log }
end

function Board.load(t)
    if type(t) ~= "table" or type(t.seed) ~= "number" or not Board.VARIANTS[t.variant]
       or type(t.log) ~= "table" then return nil end
    return Board.new(t)
end

local function key(r, c) return r * 100 + c end

function Board:replay()
    local sea = self.sea
    -- My submarine.
    self.pos, self.trail = nil, {}
    self.damage_taken = 0
    self.charge = 0
    -- Theirs: every place it can be, with its trail since it last surfaced.
    local cands = {}
    for r = 1, self.n do
        for c = 1, self.n do
            if isWater(sea, r, c) then cands[#cands + 1] = { r = r, c = c, trail = { [key(r, c)] = true } } end
        end
    end
    self.damage_dealt = 0
    self.my_shots = {}
    for _, ev in ipairs(self.log) do
        if ev.who == "me" then
            if ev.kind == "start" then
                self.pos = { ev.r, ev.c }
                self.trail = { [key(ev.r, ev.c)] = true }
            elseif ev.kind == "move" then
                local d = Board.DIRS[ev.d]
                self.pos = { self.pos[1] + d[1], self.pos[2] + d[2] }
                self.trail[key(self.pos[1], self.pos[2])] = true
                self.charge = self.charge + 1
            elseif ev.kind == "surface" then
                self.trail = { [key(self.pos[1], self.pos[2])] = true }
            elseif ev.kind == "torpedo" then
                self.damage_taken = self.damage_taken + Board.damage(ev.r, ev.c, self.pos[1], self.pos[2])
                self.charge = 0
                self.my_shots[#self.my_shots + 1] = { r = ev.r, c = ev.c }
            elseif ev.kind == "result" then
                -- What the opponent answered to my last torpedo.
                local shot = self.my_shots[#self.my_shots]
                shot.result = ev.result
                local want = ev.result == "direct" and 2 or ev.result == "near" and 1 or 0
                self.damage_dealt = self.damage_dealt + want
                local keep = {}
                for _, cd in ipairs(cands) do
                    if Board.damage(shot.r, shot.c, cd.r, cd.c) == want then keep[#keep + 1] = cd end
                end
                cands = keep
            end
        else -- them
            if ev.kind == "move" then
                local d = Board.DIRS[ev.d]
                local keep = {}
                for _, cd in ipairs(cands) do
                    local r, c = cd.r + d[1], cd.c + d[2]
                    if isWater(sea, r, c) and not cd.trail[key(r, c)] then
                        local trail = {}
                        for k in pairs(cd.trail) do trail[k] = true end
                        trail[key(r, c)] = true
                        keep[#keep + 1] = { r = r, c = c, trail = trail }
                    end
                end
                cands = keep
            elseif ev.kind == "surface" then
                local keep = {}
                for _, cd in ipairs(cands) do
                    if Board.sector(self.n, cd.r, cd.c) == ev.sector then
                        keep[#keep + 1] = { r = cd.r, c = cd.c, trail = { [key(cd.r, cd.c)] = true } }
                    end
                end
                cands = keep
            elseif ev.kind == "torpedo" then
                -- They fired at (r, c): it hits me, and tells me they are
                -- within range of it.
                if self.pos then
                    self.damage_taken = self.damage_taken + Board.damage(ev.r, ev.c, self.pos[1], self.pos[2])
                end
                local keep = {}
                for _, cd in ipairs(cands) do
                    if manhattan(cd.r, cd.c, ev.r, ev.c) <= Board.TORPEDO_RANGE then keep[#keep + 1] = cd end
                end
                cands = keep
            end
        end
    end
    self.candidates = cands
end

function Board:push(ev)
    self.log[#self.log + 1] = ev
    self:replay()
end

function Board:undo()
    if #self.log == 0 then return false end
    -- The starting cell is only taken back from the setup screen.
    if #self.log == 1 and self.log[1].kind == "start" then return false end
    table.remove(self.log)
    self:replay()
    return true
end

function Board:isPlaced()
    return self.pos ~= nil
end

function Board:isSunk()
    return self.damage_taken >= Board.HULL
end

function Board:enemySunk()
    return self.damage_dealt >= Board.HULL
end

function Board:isOver()
    return self:isSunk() or self:enemySunk()
end

function Board:hull()
    return math.max(0, Board.HULL - self.damage_taken)
end

function Board:enemyHull()
    return math.max(0, Board.HULL - self.damage_dealt)
end

-- Is a torpedo of mine waiting for the opponent's answer?
function Board:awaitingResult()
    local shot = self.my_shots[#self.my_shots]
    return shot ~= nil and shot.result == nil
end

-- ---------------------------------------------------------------------------
-- My actions. Each returns true, or false and a reason.
-- ---------------------------------------------------------------------------

function Board:place(r, c)
    if self.pos then return false, "placed" end
    if not isWater(self.sea, r, c) then return false, "land" end
    self:push({ who = "me", kind = "start", r = r, c = c })
    return true
end

function Board:canMove(d)
    local dd = Board.DIRS[d]
    local r, c = self.pos[1] + dd[1], self.pos[2] + dd[2]
    if not isWater(self.sea, r, c) then return false, "blocked" end
    if self.trail[key(r, c)] then return false, "trail" end
    return true
end

-- Can the submarine move at all? If not, it must surface.
function Board:stuck()
    for _, d in ipairs(Board.DIR_ORDER) do
        if self:canMove(d) then return false end
    end
    return true
end

function Board:move(d)
    if self:isOver() or self:awaitingResult() then return false, "wait" end
    local ok, why = self:canMove(d)
    if not ok then return false, why end
    self:push({ who = "me", kind = "move", d = d })
    return true
end

function Board:surface()
    if self:isOver() or self:awaitingResult() then return false, "wait" end
    self:push({ who = "me", kind = "surface" })
    return true, Board.sector(self.n, self.pos[1], self.pos[2])
end

function Board:torpedoReady()
    return self.charge >= Board.RECHARGE
end

function Board:canFire(r, c)
    if self:isOver() or self:awaitingResult() then return false, "wait" end
    if not self:torpedoReady() then return false, "charging" end
    if not isWater(self.sea, r, c) then return false, "land" end
    if manhattan(r, c, self.pos[1], self.pos[2]) > Board.TORPEDO_RANGE then return false, "range" end
    return true
end

-- Fires; returns true and the damage done to my own submarine.
function Board:fire(r, c)
    local ok, why = self:canFire(r, c)
    if not ok then return false, why end
    self:push({ who = "me", kind = "torpedo", r = r, c = c })
    return true, Board.damage(r, c, self.pos[1], self.pos[2])
end

-- result: "direct" | "near" | "miss", as the opponent answered.
function Board:recordResult(result)
    if not self:awaitingResult() then return false end
    self:push({ who = "me", kind = "result", result = result })
    return true
end

-- ---------------------------------------------------------------------------
-- What the opponent announced
-- ---------------------------------------------------------------------------

function Board:theyMove(d)
    if not Board.DIRS[d] then return false end
    self:push({ who = "them", kind = "move", d = d })
    return true
end

function Board:theySurface(sector)
    self:push({ who = "them", kind = "surface", sector = sector })
    return true
end

-- They fire at (r, c): returns the damage to my submarine (0, 1 or 2).
function Board:theyFire(r, c)
    local before = self.damage_taken
    self:push({ who = "them", kind = "torpedo", r = r, c = c })
    return self.damage_taken - before
end

function Board:isCandidate(r, c)
    for _, cd in ipairs(self.candidates) do
        if cd.r == r and cd.c == c then return true end
    end
    return false
end

function Board.cellName(r, c)
    return string.char(64 + c) .. r
end

return Board
