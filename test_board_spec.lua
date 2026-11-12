package.path = "./?.lua;./common/?.lua;" .. package.path
local Board = dofile("board.lua")

local function waterCells(b)
    local t = {}
    for r = 1, b.n do
        for c = 1, b.n do
            if Board.isWater(b.sea, r, c) then t[#t + 1] = { r, c } end
        end
    end
    return t
end

-- A legal random walk for a placed submarine: returns the directions.
local function randomWalk(b, steps, rnd)
    local dirs = {}
    for _i = 1, steps do
        local options = {}
        for _, d in ipairs(Board.DIR_ORDER) do
            if b:canMove(d) then options[#options + 1] = d end
        end
        if #options == 0 then break end
        local d = options[rnd(#options)]
        assert.is_true(b:move(d))
        dirs[#dirs + 1] = d
    end
    return dirs
end

describe("sea", function()
    it("has the islands it should, all water connected, the same on both readers", function()
        for variant, v in ipairs(Board.VARIANTS) do
            for seed = 0, 40 do
                local a = Board.new{ seed = seed, variant = variant }
                local b = Board.new{ seed = seed, variant = variant }
                assert.same(a.sea, b.sea)
                local land = v.n * v.n - #waterCells(a)
                assert.is_true(land >= v.islands and land <= v.islands + 2, "land " .. land)
                -- every water cell reachable: candidates start as all water
                assert.equals(#waterCells(a), #a.candidates)
            end
        end
    end)

    it("numbers the sectors 1..4 by quarter", function()
        assert.equals(1, Board.sector(10, 1, 1))
        assert.equals(2, Board.sector(10, 5, 6))
        assert.equals(3, Board.sector(10, 6, 5))
        assert.equals(4, Board.sector(10, 10, 10))
    end)
end)

describe("my submarine", function()
    local function placed(seed)
        local b = Board.new{ seed = seed or 1, variant = 2 }
        local w = waterCells(b)
        assert.is_true(b:place(w[math.floor(#w / 2)][1], w[math.floor(#w / 2)][2]))
        return b
    end

    it("cannot start on land or cross its own trail", function()
        local b = Board.new{ seed = 1, variant = 2 }
        for r = 1, b.n do
            for c = 1, b.n do
                if not Board.isWater(b.sea, r, c) then
                    assert.is_false(b:place(r, c))
                    break
                end
            end
        end
        b = placed(1)
        local rnd = require("duo").rng(3):fn()
        local dirs = randomWalk(b, 4, rnd)
        local back = ({ n = "s", s = "n", e = "w", w = "e" })[dirs[#dirs]]
        local ok, why = b:move(back)
        assert.is_false(ok)
        assert.equals("trail", why)
        local ok2, sector = b:surface()
        assert.is_true(ok2)
        assert.equals(Board.sector(b.n, b.pos[1], b.pos[2]), sector)
        assert.is_true(b:canMove(back) or select(2, b:canMove(back)) == "blocked")
    end)

    it("needs three moves to load a torpedo, and checks its range", function()
        local b = placed(2)
        local r, c = b.pos[1], b.pos[2]
        local ok, why = b:fire(r, c)
        assert.is_false(ok)
        assert.equals("charging", why)
        randomWalk(b, Board.RECHARGE, require("duo").rng(4):fn())
        assert.is_true(b:torpedoReady())
        local far
        for _, p in ipairs(waterCells(b)) do
            if math.abs(p[1] - b.pos[1]) + math.abs(p[2] - b.pos[2]) > Board.TORPEDO_RANGE then far = p break end
        end
        assert.equals("range", select(2, b:fire(far[1], far[2])))
        local fired, self_dmg = b:fire(b.pos[1], b.pos[2])
        assert.is_true(fired)
        assert.equals(2, self_dmg)
        assert.equals(2, b.damage_taken)
        assert.is_true(b:awaitingResult())
        assert.is_false(b:move("n"))
        assert.is_true(b:recordResult("miss"))
        assert.is_false(b:torpedoReady())
    end)

    it("takes damage from enemy torpedoes and sinks at zero hull", function()
        local b = placed(3)
        assert.equals(2, b:theyFire(b.pos[1], b.pos[2]))
        assert.equals(1, b:theyFire(b.pos[1] + 1, b.pos[2] + 1))
        assert.equals(0, b:theyFire(b.pos[1] + 2, b.pos[2]))
        assert.is_false(b:isSunk())
        b:theyFire(b.pos[1], b.pos[2] - 1)
        assert.is_true(b:isSunk())
        assert.is_true(b:undo())
        assert.is_false(b:isSunk())
    end)
end)

describe("tracking the opponent", function()
    -- Plays a hidden opponent on its own board, feeding its announcements to
    -- ours: the real position must always stay among the candidates.
    it("never loses the real position", function()
        local duo = require("duo")
        for seed = 0, 25 do
            for variant = 1, 2 do
                local rnd = duo.rng(seed, "spec"):fn()
                local enemy = Board.new{ seed = seed, variant = variant }
                local me = Board.new{ seed = seed, variant = variant }
                local w = waterCells(enemy)
                local start = w[rnd(#w)]
                enemy:place(start[1], start[2])
                local w2 = waterCells(me)
                local s2 = w2[rnd(#w2)]
                me:place(s2[1], s2[2])
                for _turn = 1, 40 do
                    local roll = rnd(10)
                    if enemy:stuck() or roll == 1 then
                        local _, sector = enemy:surface()
                        me:theySurface(sector)
                    elseif roll == 2 and enemy:torpedoReady() then
                        local p = waterCells(enemy)[rnd(#w)]
                        if enemy:canFire(p[1], p[2]) then
                            enemy:fire(p[1], p[2])
                            enemy:recordResult("miss")
                            me:theyFire(p[1], p[2])
                        end
                    else
                        local options = {}
                        for _, d in ipairs(Board.DIR_ORDER) do
                            if enemy:canMove(d) then options[#options + 1] = d end
                        end
                        local d = options[rnd(#options)]
                        enemy:move(d)
                        me:theyMove(d)
                    end
                    assert.is_true(me:isCandidate(enemy.pos[1], enemy.pos[2]),
                        "seed " .. seed .. " lost the enemy")
                end
                assert.is_true(#me.candidates >= 1)
            end
        end
    end)

    it("narrows down with torpedo answers", function()
        local b = Board.new{ seed = 5, variant = 2 }
        local w = waterCells(b)
        b:place(w[1][1], w[1][2])
        local rnd = require("duo").rng(6):fn()
        randomWalk(b, 3, rnd)
        local before = #b.candidates
        b:fire(b.pos[1], b.pos[2] + (Board.isWater(b.sea, b.pos[1], b.pos[2] + 1) and 1 or 0))
        b:recordResult("near")
        assert.is_true(#b.candidates < before)
        assert.equals(1, b.damage_dealt)
        for _, cd in ipairs(b.candidates) do
            assert.equals(1, Board.damage(b.my_shots[1].r, b.my_shots[1].c, cd.r, cd.c))
        end
    end)

    it("saves the log and rebuilds the same state", function()
        local b = Board.new{ seed = 8, variant = 1, code = "12345" }
        local w = waterCells(b)
        b:place(w[3][1], w[3][2])
        b:theyMove("n")
        b:theySurface(2)
        local b2 = Board.load(b:serialize())
        assert.same(b.pos, b2.pos)
        assert.equals(#b.candidates, #b2.candidates)
        assert.is_nil(Board.load({ seed = 1, variant = 1 }))
    end)
end)
