local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local ButtonDialog    = require("ui/widget/buttondialog")
local ConfirmBox      = require("ui/widget/confirmbox")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local Duo        = require("duo")
local ScreenBase = require("screen_base")

local Board      = lrequire("board")
local SeaMap     = lrequire("board_widget")

local RULES_EN = [[
Silent Subs — two readers, two hidden submarines

Each player has a reader. Both show the same sea with its islands. Each player hides a submarine on their own reader. Find the enemy submarine and sink it first!

Starting
• One player taps New game → Start a game and reads the code aloud. The other taps New game → Join a game and types it.
• Each player taps a water cell to hide their submarine there, then Dive.

Taking turns — do one thing and say it aloud
• Move one cell (arrows): say only the direction, "North!". You cannot cross an island, leave the sea, or go back over your own trail (the dots).
• Torpedo: once you have moved 3 times since the last one, tap Torpedo, then a water cell at most 3 steps away (counting north, south, east, west). Say the cell, "Torpedo at C5!". Your opponent's reader tells them the damage and they answer: direct hit, near hit or miss. Enter their answer.
• Surface: clears your trail, but you must say which quarter of the sea you are in (1 top left, 2 top right, 3 bottom left, 4 bottom right). If you are stuck, you have to surface.

Listening to your opponent
• Open Opponent and enter what they say: the direction they moved, the quarter they surfaced in, or the cell they fired at (tap Torpedo, then the cell). For a torpedo, your reader gives you the answer to read out.
• Your reader shades every cell where the enemy can still be.

Damage: a direct hit does 2, a hit on one of the 8 cells around does 1 — your own torpedo can hurt you too. A submarine with 4 damage sinks. Undo takes back the last thing entered.
]]

local RULES_FR = [[
Sous-marins furtifs — deux liseuses, deux sous-marins cachés

Chaque joueur a une liseuse. Les deux affichent la même mer avec ses îles. Chaque joueur cache un sous-marin sur sa liseuse. Trouvez le sous-marin adverse et coulez-le le premier !

Pour commencer
• Un joueur touche Nouvelle partie → Lancer une partie et lit le code à voix haute. L'autre touche Nouvelle partie → Rejoindre une partie et le saisit.
• Chacun touche une case d'eau pour y cacher son sous-marin, puis Plonger.

Chacun son tour — faites une seule chose et annoncez-la
• Avancer d'une case (flèches) : annoncez seulement la direction, « Nord ! ». Impossible de traverser une île, de sortir de la mer ou de repasser sur votre propre sillage (les points).
• Torpille : après 3 déplacements depuis la dernière, touchez Torpille, puis une case d'eau à 3 pas au plus (en comptant nord, sud, est, ouest). Annoncez la case, « Torpille en C5 ! ». La liseuse de l'adversaire lui donne les dégâts et il répond : touché direct, touché de près ou raté. Saisissez sa réponse.
• Faire surface : efface votre sillage, mais vous devez dire dans quel quart de la mer vous êtes (1 en haut à gauche, 2 en haut à droite, 3 en bas à gauche, 4 en bas à droite). Si vous êtes bloqué, vous devez faire surface.

Écouter l'adversaire
• Ouvrez Adversaire et saisissez ce qu'il annonce : la direction de son déplacement, le quart où il fait surface, ou la case qu'il vise (touchez Torpille, puis la case). Pour une torpille, votre liseuse vous donne la réponse à lire.
• Votre liseuse grise toutes les cases où l'adversaire peut encore être.

Dégâts : un touché direct fait 2, une des 8 cases autour fait 1 — votre propre torpille peut vous toucher aussi. Un sous-marin qui a 4 dégâts coule. Annuler reprend la dernière saisie.
]]

local VARIANT_NAMES = { "Small sea (8×8)", "Open sea (10×10)" }
local DIR_WORDS = { n = "North!", s = "South!", e = "East!", w = "West!" }
local SECTOR_WORDS = {
    "Quarter 1 (top left)", "Quarter 2 (top right)", "Quarter 3 (bottom left)", "Quarter 4 (bottom right)",
}

local SubsScreen = ScreenBase:extend{}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function SubsScreen:init()
    self.board = Board.load(self.plugin:loadState())
    self.view = "me"
    ScreenBase.init(self)
end

function SubsScreen:serializeState()
    return self.board and self.board:serialize() or nil
end

function SubsScreen:save()
    self.plugin:saveState(self:serializeState())
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function SubsScreen:isRoundOver()
    return not self.board or self.board:isOver()
end

local function arrows(cb)
    return {
        { text = "←", callback = function() cb("w") end },
        { text = "↑", callback = function() cb("n") end },
        { text = "↓", callback = function() cb("s") end },
        { text = "→", callback = function() cb("e") end },
    }
end

function SubsScreen:actionRows()
    local b = self.board
    if not b then return {} end
    if not b:isPlaced() then
        return { { { text = _("Dive"), callback = function() self:onDive() end } } }
    end
    local tabs = {
        { text = (self.view == "me" and "▸ " or "") .. _("My submarine"),
          callback = function() self:setView("me") end },
        { text = (self.view == "them" and "▸ " or "") .. _("Opponent"),
          callback = function() self:setView("them") end },
    }
    if self.view == "me" then
        if b:awaitingResult() then
            return { tabs, {
                { text = _("Direct hit"), callback = function() self:onResult("direct") end },
                { text = _("Near hit"),   callback = function() self:onResult("near") end },
                { text = _("No hit"),     callback = function() self:onResult("miss") end },
            } }
        end
        return { tabs, arrows(function(d) self:onMove(d) end), {
            { text = _("Torpedo"), callback = function() self:startTargeting("fire") end },
            { text = _("Surface"), callback = function() self:onSurface() end },
            { text = _("Undo"),    callback = function() self:onUndo() end },
        } }
    end
    return { tabs, arrows(function(d) self:onTheyMove(d) end), {
        { text = _("Torpedo"), callback = function() self:startTargeting("incoming") end },
        { text = _("Surface"), callback = function() self:onTheySurface() end },
        { text = _("Undo"),    callback = function() self:onUndo() end },
    } }
end

function SubsScreen:buildLayout()
    local title_bar = self:buildTitleBar(_("Silent Subs"), function()
        local items = {
            { text = _("New game"), callback = function() self:onNewGame() end },
            { text = T(_("Sea: %1"), _(VARIANT_NAMES[self.plugin:getSetting("variant", 2)])),
              callback = function() self:openVariantMenu() end },
            { text = self.plugin:getSetting("show_candidates", true)
                    and _("Shade where the enemy can be: on") or _("Shade where the enemy can be: off"),
              callback = function() self:toggleCandidates() end },
        }
        if self.board then
            items[#items + 1] = { text = _("Show the game code"), callback = function() self:showCode() end }
        end
        items[#items + 1] = self:makeRulesButtonConfig(RULES_EN, RULES_FR)
        return items
    end)

    self.status_text:setMaxWidth(self:getControlsWidth())
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        self:buildActionBar(self:actionRows()),
    }

    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    local content
    if self.board then
        self.map = SeaMap:new{
            board = self.board, view = self.view, max_width = budget_w, max_height = budget_h,
            show_candidates = self.plugin:getSetting("show_candidates", true),
            getSelected  = function()
                if self.sel then return self.sel[1], self.sel[2] end
            end,
            onCellTapped = function(r, c) self:onCellTapped(r, c) end,
        }
        self.board_widget = self.map
        content = self.map
    else
        self.map, self.board_widget = nil, nil
        content = TextBoxWidget:new{
            text = _("Each player needs a reader with this game. One starts a game and reads the code aloud; the other joins with that code."),
            face = Font:getFace("infofont"),
            width = math.min(budget_w, Device.screen:scaleBySize(500)),
            alignment = "center",
        }
    end
    local frame = FrameContainer:new{ padding = 0, margin = 0, bordersize = 0, content }

    if self:isLandscape() then
        self:buildLandscapeLayout(title_bar, HorizontalGroup:new{
            align = "center", frame, HorizontalSpan:new{ width = self:getGutter() }, controls,
        })
    else
        self:buildPortraitLayout(title_bar, frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

function SubsScreen:rebuild()
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function SubsScreen:updateStatus(message)
    local b = self.board
    local status = message
    if not status then
        if not b then
            status = _("Start or join a game.")
        elseif b:isSunk() then
            status = _("Your submarine is sunk. Your opponent wins.")
        elseif b:enemySunk() then
            status = _("You sank the enemy submarine. You win!")
        elseif not b:isPlaced() then
            status = self.sel and T(_("Hide your submarine in %1? Tap Dive."), Board.cellName(self.sel[1], self.sel[2]))
                or _("Tap a water cell to hide your submarine.")
        elseif self.targeting == "fire" then
            status = _("Tap the cell to fire at (3 steps at most).")
        elseif self.targeting == "incoming" then
            status = _("Tap the cell your opponent fired at.")
        elseif self.view == "me" then
            if b:awaitingResult() then
                status = _("What did your opponent answer?")
            else
                status = self:joinStatus(
                    T(_("Hull: %1/%2"), b:hull(), Board.HULL),
                    b:torpedoReady() and _("Torpedo: ready")
                        or T(_("Torpedo: %1 more move(s)"), Board.RECHARGE - b.charge))
            end
        else
            local k = #b.candidates
            status = self:joinStatus(
                T(_("Enemy hull: %1/%2"), b:enemyHull(), Board.HULL),
                k == 0 and _("No cell fits: check with Undo") or T(_("Possible cells: %1"), k))
        end
    end
    ScreenBase.updateStatus(self, status)
end

-- Something to say aloud: shown big, for a moment.
function SubsScreen:announce(text)
    self:showMessage(text, 3)
end

function SubsScreen:after()
    self.sel, self.targeting = nil, nil
    self:save()
    self:rebuild()
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function SubsScreen:onCellTapped(r, c)
    local b = self.board
    if b:isOver() then return end
    if not b:isPlaced() then
        if not Board.isWater(b.sea, r, c) then
            self:updateStatus(_("That is an island: pick a water cell."))
            return
        end
        self.sel = { r, c }
        self.map:refresh()
        self:updateStatus()
        return
    end
    if self.targeting == "fire" then
        local ok, why = b:canFire(r, c)
        if not ok then
            self:updateStatus(why == "range" and _("Too far: 3 steps at most.")
                or why == "land" and _("That is an island: pick a water cell.")
                or _("You cannot fire now."))
            return
        end
        self.sel = { r, c }
        self.map:refresh()
        local name = Board.cellName(r, c)
        UIManager:show(ConfirmBox:new{
            text = T(_("Fire a torpedo at %1?"), name),
            ok_text = _("Fire"),
            ok_callback = function()
                local _ok, self_damage = b:fire(r, c)
                self:after()
                local text = T(_("Say: \"Torpedo at %1!\""), name)
                if self_damage > 0 then
                    text = text .. "\n" .. T(_("Your own torpedo hits you: %1 damage."), self_damage)
                end
                self:announce(text)
            end,
            cancel_callback = function()
                self.sel = nil
                self.map:refresh()
            end,
        })
    elseif self.targeting == "incoming" then
        local dmg = b:theyFire(r, c)
        self:after()
        local name = Board.cellName(r, c)
        local answer = dmg == 2 and _("Direct hit!") or dmg == 1 and _("Near hit!") or _("Miss!")
        local text = T(_("Torpedo at %1: answer \"%2\""), name, answer)
        if b:isSunk() then text = text .. "\n" .. _("Your submarine is sunk.") end
        self:announce(text)
    end
end

function SubsScreen:onDive()
    local b = self.board
    if not self.sel then
        self:updateStatus(_("Tap a water cell to hide your submarine."))
        return
    end
    b:place(self.sel[1], self.sel[2])
    self.view = "me"
    self:after()
    self:showMessage(_("Dived! Hide your screen from your opponent."), 3)
end

-- ---------------------------------------------------------------------------
-- My turn
-- ---------------------------------------------------------------------------

function SubsScreen:setView(view)
    if self.view == view then return end
    self.view = view
    self.sel, self.targeting = nil, nil
    self:rebuild()
end

function SubsScreen:onMove(d)
    local b = self.board
    local ok, why = b:move(d)
    if not ok then
        if why == "trail" then
            self:updateStatus(b:stuck() and _("You are stuck: you must surface.")
                or _("You cannot go back over your trail."))
        elseif why == "blocked" then
            self:updateStatus(b:stuck() and _("You are stuck: you must surface.")
                or _("An island or the edge blocks the way."))
        end
        return
    end
    self:after()
    self:announce(T(_("Say: \"%1\""), _(DIR_WORDS[d])))
end

function SubsScreen:startTargeting(kind)
    local b = self.board
    if b:isOver() then return end
    if kind == "fire" and not b:torpedoReady() then
        self:updateStatus(T(_("Torpedo: %1 more move(s)"), Board.RECHARGE - b.charge))
        return
    end
    self.targeting = self.targeting ~= kind and kind or nil
    self.sel = nil
    self:updateStatus()
end

function SubsScreen:onSurface()
    local b = self.board
    UIManager:show(ConfirmBox:new{
        text = _("Surface? Your trail is cleared, but you must say which quarter you are in."),
        ok_text = _("Surface"),
        ok_callback = function()
            local ok, sector = b:surface()
            if not ok then return end
            self:after()
            self:announce(T(_("Say: \"Surfacing in %1\""), _(SECTOR_WORDS[sector])))
        end,
    })
end

function SubsScreen:onResult(result)
    local b = self.board
    b:recordResult(result)
    self:after()
    if b:enemySunk() then
        self:showMessage(_("You sank the enemy submarine. You win!"), 5)
    end
end

-- ---------------------------------------------------------------------------
-- The opponent's turn
-- ---------------------------------------------------------------------------

function SubsScreen:onTheyMove(d)
    self.board:theyMove(d)
    self:after()
end

function SubsScreen:onTheySurface()
    local dlg
    local buttons = {}
    for s = 1, 4 do
        buttons[#buttons + 1] = { {
            text = _(SECTOR_WORDS[s]),
            callback = function()
                UIManager:close(dlg)
                self.board:theySurface(s)
                self:after()
            end,
        } }
    end
    dlg = ButtonDialog:new{ title = _("Which quarter did your opponent surface in?"), buttons = buttons }
    UIManager:show(dlg)
end

function SubsScreen:onUndo()
    if not self.board:undo() then
        self:updateStatus(_("Nothing to undo."))
        return
    end
    self:after()
end

-- ---------------------------------------------------------------------------
-- New game and settings
-- ---------------------------------------------------------------------------

function SubsScreen:onNewGame()
    Duo.newGameDialog{
        title     = _("Silent Subs"),
        nvariants = #Board.VARIANTS,
        variant   = self.plugin:getSetting("variant", 2),
        variant_text = function(v) return T(_("Sea: %1"), _(VARIANT_NAMES[v])) end,
        on_start = function(game)
            self.board = Board.new{ seed = game.seed, variant = game.variant, code = game.code }
            self.view, self.sel, self.targeting = "me", nil, nil
            self:save()
            self:rebuild()
        end,
    }
end

function SubsScreen:showCode()
    local b = self.board
    self:showMessage(T(_("Game code: %1"), Duo.format(b.code)) .. "\n"
        .. T(_("Sea: %1"), _(VARIANT_NAMES[b.variant])), 6)
end

function SubsScreen:openVariantMenu()
    local dlg
    local buttons = {}
    for i, name in ipairs(VARIANT_NAMES) do
        buttons[#buttons + 1] = { {
            text = _(name),
            callback = function()
                UIManager:close(dlg)
                self.plugin:saveSetting("variant", i)
            end,
        } }
    end
    dlg = ButtonDialog:new{ title = _("Sea of the games you start"), buttons = buttons }
    UIManager:show(dlg)
end

function SubsScreen:toggleCandidates()
    self.plugin:saveSetting("show_candidates", not self.plugin:getSetting("show_candidates", true))
    if self.board then self:rebuild() end
end

return SubsScreen
