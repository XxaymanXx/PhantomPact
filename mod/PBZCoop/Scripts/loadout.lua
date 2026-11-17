-- Local co-op (Role = Local): what player 2 wears and holds is theirs. The bag (the game's one backpack) stays everyone's, as
-- on a couch: they pick out of it in the game's own menu, opened with their own Options button, which wears a PLAYER 2 badge
-- while it's theirs. Their outfit, main weapons, Phantom Edges, the weapon in hand and their talismans are their own;
-- medicines stay the shared slots (their gourd has charges of its own: localcoop.lua).
--
-- What it takes, as the game's equip code knows one player (the bench, 11-11):
-- - The bag sends every change to every Soul: that's how player 2 came to copy player 1's gear. So after any change their
--   gear is put back on their body, and a new body (back from down, a map load) gets it too. A weapon goes on by the Soul's
--   weapons component: its moves come with it (the game swaps the whole set), and its hits land as that weapon's.
-- - The menu shows the bag and "the player". While player 2's is up the bag holds their set (pushed in the game's own way, as
--   a PvP match does) and player 1's controller points at their body, as for their drinks; saves are held off meanwhile, so
--   their set never reaches the save. Closing it, what they chose is kept, player 1's set goes back, and they're dressed.
-- - A talisman's effects go on "player 0's" body as it's put on: in player 2's menu, theirs. Each one's effects are noted as
--   the menu's close takes it off again, and put on their body by hand from then on. One talisman, one wearer.
-- - Their weapon switch also sets the bag's weapon in hand, which the save keeps: player 1's goes back there.
-- Kept in localcoop_gear.txt (the game's own ids and paths), and checked against what this save owns.
-- Written for player n: local co-op has one more player now, player 2.

return function(api)
    local log, valid, game, state = api.log, api.valid, api.game, api.state

    local MAIN, EDGE = "Weapon.Slot.Main", "Weapon.Slot.Shachi"
    local APPEARANCE = "/Script/ProjectPBZ.PBZAppearanceComponent"
    local KEEP_S = 0.25             -- how often a player's body is checked against their gear
    local SETTLE_S = 6.0            -- a new body is left alone this long: a weapon given to a body still loading its classes
                                    -- was a crash on arrival (moves.lua, the online figures)
    local OPEN_WAIT_S = 2.0         -- the menu asked for and not up after this: the game said no, and the bag goes back
    local RETRY_S = 10.0            -- a menu's end with no bag to put back is tried again this long, saves held meanwhile
    local WRITE_AFTER_S = 5.0       -- their weapon switch is written to the file this long after
    local VIEW_S = 2.0              -- player 1's camera is watched this long after their menu closes (viewBack)
    -- GameplayFlow (the quiet autosave) and ModeGate (bells and trips), as a PvP match holds them.
    local HOLD_SAVES = { { "PhantomPactPlayerMenu", 0 }, { "PhantomPactPlayerMenu2", 2 } }
    local FILE = "localcoop_gear.txt"
    local WEAPON_PATH = "^/PBZCombatAsset/ActorData/Players/[%w_/]+%.[%w_]+$"
    local EFFECT_PATH = "^/[%w_/]+%.GE_[%w_]+_C$"
    local BADGE_Z = 399
    local BADGE_W = 0.13            -- of player 1's screen's width
    local BADGE_ASPECT = 96 / 384   -- the picture's height / width
    local BADGE_X, BADGE_Y = 0.085, 0.075       -- its middle, in player 1's screen (the game's menu leaves that corner empty)

    local loadout = {}
    local gear = {}                 -- player number -> what's theirs (strings and numbers only), once they've chosen
    local bodies = {}               -- player number -> { addr, at, effects = the handles of what was put on that body }
    local session = nil             -- a player's own menu while it's up: { n, at, opened, p1 = player 1's set, pushed }
    local nextKeep = 0
    local viewUntil, viewOf = 0, 0  -- player 1's camera watched till then, against the body their menu pointed at (viewBack)
    local loaded = false
    local badgeWidget, badgeFitted = nil, false
    local menuTipped = false

    local function slot(tag)
        return { TagName = FName(tag) }
    end

    local function bodyOf(n)
        return n == 2 and state.p2Pawn or nil
    end

    -- Player 1's own body, even while their controller points at another (AcknowledgedPawn stays theirs: the bench, 11-11).
    local function ownBody(pc)
        local ok, p = pcall(function() return pc.AcknowledgedPawn end)
        if ok and valid(p) then
            return p
        end
        return not state.pointedMenu and valid(pc.Pawn) and pc.Pawn or nil
    end

    local function weaponsOf(body)
        local ok, c = pcall(function() return body["Character Weapons Component"] end)
        return ok and valid(c) and c or nil
    end

    local function lookOf(body)
        local ok, c = pcall(function() return body:GetComponentByClass(StaticFindObject(APPEARANCE)) end)
        return ok and valid(c) and c or nil
    end

    local function abilitiesOf(body)
        local ok, a = pcall(function()
            return StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"):GetAbilitySystemComponent(body)
        end)
        return ok and valid(a) and a or nil
    end

    local function tip(text)
        log(text)
        if api.status and api.status.notify then
            pcall(api.status.notify, "localcoop", text)
        end
    end

    -- The names in a list the game hands back ("None" for an empty place).
    local function names(list)
        local out = {}
        pcall(function()
            for _, v in ipairs(list) do
                local okG, got = pcall(function() return v:get() end)
                local n = okG and got or v
                local okS, s = pcall(function() return n:ToString() end)
                out[#out + 1] = okS and type(s) == "string" and s or "None"
            end
        end)
        return out
    end

    -- The bag's equipped set: weapon ids by place, the one in hand, and the talismans worn (by place).
    local function bagSet(bp)
        local s = { main = {}, edge = {}, mainAt = 0, edgeAt = 0, worn = {} }
        pcall(function() s.main = names(bp:GetEquipmentNormalWeapons()) end)
        pcall(function() s.edge = names(bp:GetShaqiWeapons()) end)
        pcall(function() s.mainAt = bp:GetCurrentMainWeaponIndex() end)
        pcall(function() s.edgeAt = bp:GetCurrentShaqiWeaponIndex() end)
        pcall(function()
            local place = 0
            bp.AssemblyAccessory:ForEach(function(_, e)
                local id = e:get():ToString()
                if id ~= "None" and id ~= "" then
                    s.worn[#s.worn + 1] = { slot = place, id = id }
                end
                place = place + 1
            end)
        end)
        return s
    end

    -- A story's own weapons (the prologue's bare hands, a forced loadout) are everyone's: player 2's stay off meanwhile.
    local function forced(bp)
        local ok, yes = pcall(function() return bp:HasForcedWeaponLoadout() == true or bp.bZlgwBareMode == true end)
        return ok and yes
    end

    -- What a body holds in a slot: the game's path of each weapon, by place ("-": none there).
    local function heldPaths(body, tag)
        local out = {}
        local cwc = weaponsOf(body)
        pcall(function()
            for i = 0, cwc:GetSlotWeapons(slot(tag)) - 1 do
                local data = {}
                cwc:GetSlotWeapon(slot(tag), i, data)
                out[#out + 1] = valid(data.WeaponConfig) and (data.WeaponConfig:GetFullName():gsub("^%S+ ", "")) or "-"
            end
        end)
        return out
    end

    -- The effects on a body now, "path@level", as its ability system lists them.
    local function effectsOn(body)
        local out = {}
        local a = abilitiesOf(body)
        pcall(function()
            a.ActiveGameplayEffects.GameplayEffects_Internal:ForEach(function(_, e)
                pcall(function()
                    local spec = e:get().Spec
                    out[#out + 1] = (spec.Def:GetClass():GetFullName():gsub("^%S+ ", "")) .. "@" .. tostring(spec.Level)
                end)
            end)
        end)
        return out
    end

    -- What's in before and not in after (each counted).
    local function minus(before, after)
        local left, out = {}, {}
        for _, e in ipairs(after) do
            left[e] = (left[e] or 0) + 1
        end
        for _, e in ipairs(before) do
            if (left[e] or 0) > 0 then
                left[e] = left[e] - 1
            else
                out[#out + 1] = e
            end
        end
        return out
    end

    local function holdSaves(on)
        local saves = FindFirstOf("PBZSaveLoadSubsystem")
        if not valid(saves) then
            return
        end
        for _, v in ipairs(HOLD_SAVES) do
            pcall(function()
                if on then
                    saves:EnterSaveVeto(FName(v[1]), v[2])
                else
                    saves:ExitSaveVeto(FName(v[1]))
                end
            end)
        end
    end

    -- Player 1's controller on a body: for the game, "the player" is that body. main.lua's getPlayer1 knows (pointedMenu)
    -- and keeps answering the mod with player 1's own.
    local function point(pc, body, on)
        pc.Pawn = body
        pc.Character = body
        state.pointedMenu = on or nil
    end

    -- The Appearance page moves player 1's camera to its preview point and, leaving, hands it to the body the controller
    -- points at: player 2's, and then both halves of the screen showed player 2 (the user's pads, 11-11). Back on player 1's
    -- own from there; any other camera (a scene's) is left alone. addr: the body the menu pointed at.
    local function viewBack(pc, p1, addr)
        pcall(function()
            local view = pc:GetViewTarget()
            if not valid(view) or view:GetAddress() == p1:GetAddress() then
                return
            end
            if view:GetAddress() == addr or view:GetClass():GetFName():ToString():find("AppearancePreviewPoint", 1, true) then
                pc:SetViewTargetWithBlend(p1, 0, 0, 0, false)
                log("Player 1's camera back on them after player 2's menu.")
            end
        end)
    end

    local function config(path)
        if not (type(path) == "string" and path:match(WEAPON_PATH)) then
            return nil
        end
        local cfg = StaticFindObject(path)
        if not valid(cfg) and type(LoadAsset) == "function" then
            pcall(LoadAsset, path)
            cfg = StaticFindObject(path)
        end
        return valid(cfg) and cfg or nil
    end

    ------------------------------------------------------------------ the file

    local function filePath()
        return api.modDir() .. FILE
    end

    local function list(text)
        local out = {}
        for item in ((text or "") .. ","):gmatch("([^,]*),") do
            out[#out + 1] = item
        end
        if #out == 1 and out[1] == "" then
            return {}
        end
        return out
    end

    function loadout.read()
        loaded = true
        local f = io.open(filePath(), "r")
        if not f then
            return
        end
        for line in f:lines() do
            local n, key, value = line:match("^p(%d+)%.(%a+)%s*=%s*(.-)%s*$")
            n = tonumber(n)
            if n and n >= 2 and n <= 8 then
                local g = gear[n] or { main = {}, mainPaths = {}, edge = {}, edgePaths = {}, worn = {}, effects = {} }
                gear[n] = g
                if key == "outfit" and value:match("^[%w_]+$") then
                    g.outfit = value
                elseif key == "hat" then
                    g.hatHidden = value == "off"
                elseif key == "skin" then
                    g.skin = math.floor(tonumber(value) or 0)
                elseif key == "main" or key == "edge" then
                    g[key] = list(value)
                    g.hasWeapons = true
                elseif key == "mainpaths" or key == "edgepaths" then
                    g[key == "mainpaths" and "mainPaths" or "edgePaths"] = list(value)
                elseif key == "mainat" or key == "edgeat" then
                    g[key == "mainat" and "mainAt" or "edgeAt"] = math.floor(tonumber(value) or 0)
                elseif key == "talisman" then
                    local place, id = value:match("^(%d+):([%w_]+)$")
                    if place then
                        g.worn[#g.worn + 1] = { slot = tonumber(place), id = id }
                    end
                elseif key == "effect" then
                    local id, path, level = value:match("^([%w_]+)=(.-)@([%d.]+)$")
                    if id and path:match(EFFECT_PATH) then
                        g.effects[#g.effects + 1] = { id = id, path = path, level = tonumber(level) or 1 }
                    end
                end
            end
        end
        f:close()
        for n in pairs(gear) do
            log(string.format("Player %d's own gear read from %s.", n, FILE))
        end
    end

    function loadout.write()
        local f = io.open(filePath(), "w")
        if not f then
            return
        end
        f:write("; Local co-op: what each player after player 1 wears and holds, chosen in the game's menu from their own\n")
        f:write("; controller (Options). Written as that menu closes. The game's own ids and paths; one this save hasn't is left out.\n")
        for n, g in pairs(gear) do
            local p = "p" .. n .. "."
            if g.outfit then
                f:write(p .. "outfit = " .. g.outfit .. "\n")
                f:write(p .. "hat = " .. (g.hatHidden and "off" or "on") .. "\n")
                f:write(p .. "skin = " .. tostring(g.skin or 0) .. "\n")
            end
            f:write(p .. "main = " .. table.concat(g.main or {}, ",") .. "\n")
            f:write(p .. "mainpaths = " .. table.concat(g.mainPaths or {}, ",") .. "\n")
            f:write(p .. "mainat = " .. tostring(g.mainAt or 0) .. "\n")
            f:write(p .. "edge = " .. table.concat(g.edge or {}, ",") .. "\n")
            f:write(p .. "edgepaths = " .. table.concat(g.edgePaths or {}, ",") .. "\n")
            f:write(p .. "edgeat = " .. tostring(g.edgeAt or 0) .. "\n")
            for _, t in ipairs(g.worn or {}) do
                f:write(p .. "talisman = " .. t.slot .. ":" .. t.id .. "\n")
            end
            for _, e in ipairs(g.effects or {}) do
                f:write(p .. "effect = " .. e.id .. "=" .. e.path .. "@" .. tostring(e.level) .. "\n")
            end
        end
        f:close()
    end

    ------------------------------------------------------------------ the badge

    local function dropBadge()
        if valid(badgeWidget) then
            pcall(function() badgeWidget:RemoveFromParent() end)
        end
        badgeWidget, badgeFitted = nil, false
    end

    -- Where it goes: the top left of player 1's screen (the whole window, or their monitor while it's spread over two).
    local function badgeSpot()
        local pc = api.getPlayer1()
        local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        local size, scale = lib:GetViewportSize(pc), lib:GetViewportScale(pc)
        local vw, vh = size.X / scale, size.Y / scale
        local x, y, w, h = 0, 0, vw, vh
        if api.localcoop and api.localcoop.playerOneArea then
            x, y, w, h = api.localcoop.playerOneArea(vw, vh)
        end
        local bw = w * BADGE_W
        return x + w * BADGE_X, y + h * BADGE_Y, bw, bw * BADGE_ASPECT
    end

    -- The badge's picture, in English or Arabic (local co-op's words have no Chinese). The Arabic one only if it's in
    -- the mod: a new one stays out of it, in art/unchecked, till the mod's author has checked it, and the English badge
    -- is shown meanwhile.
    function loadout.badgePicture(n)
        local name = "player_menu_" .. n .. ".png"
        if api.lang and api.lang.arabic and api.lang.arabic() then
            local f = io.open(api.modRoot() .. "art/panel/ar_" .. name, "rb")
            if f then
                f:close()
                return "panel/ar_" .. name
            end
        end
        return "panel/" .. name
    end

    local function showBadge(n)
        dropBadge()
        local ok, err = pcall(function()
            local x, y, w, h = badgeSpot()
            badgeWidget = api.hud.newImage(loadout.badgePicture(n), w, h, BADGE_Z)
            if badgeWidget then
                badgeWidget:SetPositionInViewport({ X = x, Y = y }, false)
            end
        end)
        if not ok then
            log("Player menu badge: " .. tostring(err))
        end
    end

    -- (A widget has no size until a frame after it's made: scaled to its size once it has one.)
    local function fitBadge()
        if badgeFitted or not (api.status and api.status.onScreen(badgeWidget)) then
            return
        end
        local _, _, w, h = badgeSpot()
        badgeFitted = api.hud.fit(badgeWidget, w, h)
    end

    ------------------------------------------------------------------ the menu

    -- Their weapons into the bag, empty places left out (the one in hand counted among the rest).
    local function pushSet(bp, s)
        local function packed(ids, at)
            local out, hand = {}, 0
            for i, id in ipairs(ids or {}) do
                if id ~= "None" and id ~= "" then
                    out[#out + 1] = FName(id)
                    if i - 1 == (at or 0) then
                        hand = #out - 1
                    end
                end
            end
            return out, hand
        end
        local m, mainAt = packed(s.main, s.mainAt)
        local e, edgeAt = packed(s.edge, s.edgeAt)
        return (pcall(function() bp:PushEquippedWeapons(m, e, mainAt, edgeAt) end))
    end

    -- Their talisman effects off their body (each put on by hand: see putEffects), or forgotten with a body that's gone.
    local function dropEffects(n)
        local b, body = bodies[n], bodyOf(n)
        if not (b and b.effects) then
            return
        end
        local a = valid(body) and body:GetAddress() == b.addr and abilitiesOf(body) or nil
        for _, handle in ipairs(a and b.effects or {}) do
            pcall(function() a:RemoveActiveGameplayEffect(handle, -1) end)
        end
        b.effects = nil
    end

    -- Player n's Options button: the game's menu opens as theirs. False when it can't be: it opens shared, as before.
    function loadout.begin(n)
        if not loaded then
            loadout.read()
        end
        if session then
            return false
        end
        local pc, p1 = api.getPlayer1()
        local body = bodyOf(n)
        if not (valid(pc) and valid(p1) and valid(body)) then
            return false
        end
        local bp = game.backpackOf(p1)
        local okS, busy = pcall(function() return bp:HasEquippedWeaponsSnapshot() end)
        if not bp or forced(bp) or not okS or busy then
            return false
        end
        local s = { n = n, at = os.clock(), p1 = bagSet(bp) }
        local g = gear[n]
        -- (Nothing of their own yet: they start from player 1's weapons, as they hold them now, and no talismans. None at
        -- all is theirs too, once chosen.)
        local want = (g and g.hasWeapons) and g or s.p1
        -- A session from the first change on: whatever goes wrong below, its end puts everything back (finish).
        session = s
        holdSaves(true)
        local ok, err = pcall(function()
            -- Player 1's talismans come off (their effects off player 1), and player 2's weapons go into the bag.
            for i = #s.p1.worn, 1, -1 do
                pcall(function() bp:TakeOffAccessory(s.p1.worn[i].slot) end)
            end
            s.pushed = pushSet(bp, want)
            if not s.pushed then
                error("the bag wouldn't take their set")
            end
            -- Their talismans: the hand-put effects off, then worn in the bag on their body, which the game takes for the
            -- player.
            dropEffects(n)
            point(pc, body, true)
            for _, t in ipairs(g and g.worn or {}) do
                pcall(function() bp:AssembleAccessory(FName(t.id), t.slot) end)
            end
            -- Their look follows the menu's wardrobe while it's up, held out of the save first: the wardrobe's pick goes into
            -- the save through the body it's made on, and a player 2 never dressed by the mod had a look the save took
            -- (player 1 came back in it after a restart: the bench, 11-11).
            local look = lookOf(body)
            if look then
                pcall(function() look:BeginSuppressAppearanceSave() end)
                pcall(function() look:SetUseConfiguredAppearance(false) end)
            end
        end)
        if not ok then
            log(string.format("Player %d's menu: %s; the menu opens shared.", n, tostring(err)))
            loadout.finish("couldn't begin")
            return false
        end
        showBadge(n)
        log(string.format("Player %d's menu: their set in the bag (%d weapon(s), %d talisman(s)).", n, #(want.main or {}),
            #(g and g.worn or {})))
        if not menuTipped then
            menuTipped = true
            tip("player 2's menu: what's equipped here is player 2's own.")
        end
        return true
    end

    -- The menu is up (localcoop.lua's look at the screens): from now on its close ends the session.
    function loadout.opened()
        if session then
            session.opened = true
        end
    end

    function loadout.inMenu()
        return session ~= nil
    end

    -- Player n's menu closed, or has to end (a map load, single player): what's in the bag is theirs now, player 1's set goes
    -- back, and the next keep dresses their body.
    function loadout.finish(why)
        local s = session
        if not s then
            return
        end
        local pc = api.getPlayer1()
        local p1 = valid(pc) and ownBody(pc) or nil
        local bp = valid(p1) and game.backpackOf(p1) or nil
        if not bp then
            -- (Player 1's own body or the bag isn't to be had this moment: the session stays, saves still held, and the next
            -- look tries again. Past RETRY_S the world it was in is gone, a new one with the save's own set: it's let go.)
            s.retryAt = s.retryAt or os.clock()
            s.ending = why
            if os.clock() - s.retryAt < RETRY_S then
                return
            end
            session = nil
            dropBadge()
            state.pointedMenu = nil
            holdSaves(false)
            log(string.format("Player %d's menu ended (%s) with no bag to put back.", s.n, tostring(why)))
            return
        end
        session = nil
        dropBadge()
        local body = bodyOf(s.n)
        -- What they chose: read only, so anything that fails here is left out and the rest still runs.
        local got = nil
        if s.opened and valid(body) then
            local ok, err = pcall(function()
                got = bagSet(bp)
                got.mainPaths, got.edgePaths = heldPaths(body, MAIN), heldPaths(body, EDGE)
                got.outfit, got.hatHidden, got.skin = game.ownLook(body)
                got.hasWeapons = true
            end)
            if not ok then
                got = nil
                log(string.format("Player %d's menu: what they chose couldn't be read (%s).", s.n, tostring(err)))
            end
        end
        -- Every talisman the bag wears now is theirs (player 1's came off as it began): each comes off, its effects noted
        -- as they leave their body, at which the controller still points.
        local worn, effects = bagSet(bp).worn, {}
        for i = #worn, 1, -1 do
            local before = valid(body) and effectsOn(body) or {}
            pcall(function() bp:TakeOffAccessory(worn[i].slot) end)
            if valid(body) then
                for _, e in ipairs(minus(before, effectsOn(body))) do
                    local path, level = e:match("^(.-)@(.+)$")
                    if path and path:match(EFFECT_PATH) then
                        effects[#effects + 1] = { id = worn[i].id, path = path, level = tonumber(level) or 1 }
                    end
                end
            end
        end
        point(pc, p1, false)
        viewOf = valid(body) and body:GetAddress() or 0
        viewUntil = os.clock() + VIEW_S
        viewBack(pc, p1, viewOf)
        if s.pushed then
            pcall(function() bp:PopEquippedWeapons() end)
        end
        -- Player 1's talismans back on: one player 2 put on is theirs now.
        local theirs, gave = {}, false
        for _, t in ipairs(got and worn or {}) do
            theirs[t.id] = true
        end
        for _, t in ipairs(s.p1.worn) do
            if theirs[t.id] then
                gave = true
            else
                pcall(function() bp:AssembleAccessory(FName(t.id), t.slot) end)
            end
        end
        if gave then
            tip("player 2 took a talisman player 1 was wearing: it's player 2's now.")
        end
        holdSaves(false)
        -- (Their talisman effects go on again by hand at the next look, whatever came of it.)
        if bodies[s.n] then
            bodies[s.n].effects = nil
        end
        -- (A menu that never came up chose nothing: what they had stays, and without anything of their own they go on
        -- holding the bag's, as before.)
        if got then
            got.worn, got.effects, got.checked = worn, effects, true
            gear[s.n] = got
            pcall(loadout.write)
        end
        log(string.format("Player %d's menu closed (%s)%s.", s.n, tostring(why),
            got and string.format(": %d weapon(s), %d talisman(s), %s", #got.main, #got.worn, tostring(got.outfit)) or ""))
    end

    ------------------------------------------------------------------ their body

    -- Only what this save owns: a weapon, outfit or talisman it hasn't (another save) is left out, and the bag's is used there.
    -- One player 1 wears stays player 1's.
    local function checkOwned(g, bp, p1, body)
        local mains, edges, charms = {}, {}, {}
        pcall(function()
            for _, id in ipairs(names(bp:GetAllNormalWeapons())) do mains[id] = true end
        end)
        pcall(function()
            for _, id in ipairs(names(bp:GetAllShaqiWeapons())) do edges[id] = true end
        end)
        pcall(function()
            bp.Accessories:ForEach(function(k) charms[k:get():ToString()] = true end)
        end)
        for _, w in ipairs({ { g.main, g.mainPaths, mains }, { g.edge, g.edgePaths, edges } }) do
            for i, id in ipairs(w[1] or {}) do
                if id ~= "None" and not w[3][id] then
                    log("Player 2's own gear: this save hasn't " .. id .. ".")
                    w[1][i] = "None"
                    if w[2] then
                        w[2][i] = "-"
                    end
                end
            end
        end
        if g.outfit then
            local look = lookOf(body)
            local okO, has = pcall(function() return look:IsOutfitOwned(FName(g.outfit)) end)
            local mine = game.ownLook(p1)
            if not (okO and has) and g.outfit ~= mine then
                log("Player 2's own gear: this save hasn't " .. g.outfit .. ".")
                g.outfit = nil
            end
        end
        local worn1 = {}
        for _, t in ipairs(bagSet(bp).worn) do
            worn1[t.id] = true
        end
        local keep, gone = {}, {}
        for _, t in ipairs(g.worn or {}) do
            if charms[t.id] and not worn1[t.id] then
                keep[#keep + 1] = t
            else
                gone[t.id] = true
            end
        end
        g.worn = keep
        local effects = {}
        for _, e in ipairs(g.effects or {}) do
            if not gone[e.id] then
                effects[#effects + 1] = e
            end
        end
        g.effects = effects
        g.checked = true
    end

    -- The bag's weapon in hand back to player 1's: the save keeps it, and player 2's switch had set it. Written as the
    -- bag's own fields, which moves nobody's hand (the bench, 11-11).
    local function keepPlayer1Hand(p1, bp)
        local cwc = weaponsOf(p1)
        if not cwc then
            return
        end
        pcall(function()
            local mine = cwc:GetCurrentWeaponIndex(slot(MAIN), false)
            if type(mine) == "number" and mine >= 0 and bp:GetCurrentMainWeaponIndex() ~= mine then
                local ids = names(bp:GetEquipmentNormalWeapons())
                bp.CurrentWeaponIndex = mine
                bp.CurrentMainWeaponID = FName(ids[mine + 1] or "None")
            end
        end)
        pcall(function()
            local mine = cwc:GetCurrentWeaponIndex(slot(EDGE), false)
            if type(mine) == "number" and mine >= 0 and bp:GetCurrentShaqiWeaponIndex() ~= mine then
                bp.CurrentShaqiWeaponIndex = mine
            end
        end)
    end

    -- One slot of their body back to their own weapons: by place, emptied where theirs is empty, and the one in hand theirs.
    -- The same weapons with another in hand is their own switch: noted as theirs. True when the bag's hand needs putting back.
    local function dressSlot(body, tag, g, pathsKey, atKey, b)
        local paths = g[pathsKey]
        local cwc = weaponsOf(body)
        if not (paths and cwc) then
            return false
        end
        local okT, moving = pcall(function() return cwc:IsInWeaponTransition() end)
        if okT and moving then
            return false
        end
        local have = heldPaths(body, tag)
        local changed = false
        for i = 1, math.max(#have, #paths) do
            local want = paths[i] or "-"
            if (have[i] or "-") ~= want then
                local cfg = want ~= "-" and config(want) or nil
                if want == "-" or cfg then
                    changed = pcall(function() cwc:SetSlotWeapon(slot(tag), i - 1, cfg) end) or changed
                end
            end
        end
        local okI, idx = pcall(function() return cwc:GetCurrentWeaponIndex(slot(tag), false) end)
        if not (okI and type(idx) == "number") then
            return changed
        end
        if changed or b[atKey] == nil then
            -- (Their weapons put back, or a new body: the one in hand is theirs too, when that place holds one. Taken as in
            -- hand only once the body says so: one that didn't take is tried again at the next look, not taken for a switch.)
            local at = g[atKey]
            if at and idx ~= at and paths[at + 1] and paths[at + 1] ~= "-" then
                changed = pcall(function() cwc:SetCurrentWeapon(slot(tag), at) end) or changed
                local okN, now = pcall(function() return cwc:GetCurrentWeaponIndex(slot(tag), false) end)
                idx = okN and type(now) == "number" and now or idx
            end
            b[atKey] = (at == nil or idx == at) and idx or nil
            if changed and not b.said then
                b.said = true
                log("Player 2's own weapons back on them.")
            end
            return changed
        end
        if idx >= 0 and idx ~= b[atKey] then
            b[atKey], g[atKey] = idx, idx       -- (their own switch: kept, and written a moment later)
            g.changedAt = g.changedAt or os.clock()
            return true
        end
        return false
    end

    -- One talisman, one wearer: one player 1 has put on since (their own menu shows player 2's as free) is theirs now, its
    -- effects off player 2.
    local function keepOneWearer(n, g, bp, b)
        if #(g.worn or {}) == 0 then
            return
        end
        local worn1 = {}
        for _, t in ipairs(bagSet(bp).worn) do
            worn1[t.id] = true
        end
        local keep, lost = {}, false
        for _, t in ipairs(g.worn) do
            if worn1[t.id] then
                lost = true
            else
                keep[#keep + 1] = t
            end
        end
        if not lost then
            return
        end
        local effects = {}
        for _, e in ipairs(g.effects or {}) do
            if not worn1[e.id] then
                effects[#effects + 1] = e
            end
        end
        dropEffects(n)
        g.worn, g.effects = keep, effects
        b.effects = nil
        pcall(loadout.write)
        tip("player 1 put on a talisman player 2 was wearing: it's player 1's now.")
    end

    local function putEffects(g, body, b)
        b.effects = {}
        local a = abilitiesOf(body)
        if not a then
            return
        end
        for _, e in ipairs(g.effects or {}) do
            local cls = StaticFindObject(e.path)
            if not valid(cls) and type(LoadAsset) == "function" then
                pcall(LoadAsset, e.path)
                cls = StaticFindObject(e.path)
            end
            if valid(cls) then
                local ok, handle = pcall(function() return a:BP_ApplyGameplayEffectToSelf(cls, e.level, a:MakeEffectContext()) end)
                if ok then
                    b.effects[#b.effects + 1] = handle
                end
            end
        end
    end

    -- Every look (localcoop.lua's 100 ms loop): their gear back on them after the bag dressed everyone, the bag's hand back to
    -- player 1's after their switch. held: nothing of theirs is touched now (a scene, a menu, down, single player).
    function loadout.keep(n, held)
        if not loaded then
            loadout.read()
        end
        local now = os.clock()
        if now < viewUntil and not session and not held then
            -- (The game may hand the camera over a moment after the menu's close: looked at again for a while.)
            local pc, p1 = api.getPlayer1()
            if valid(pc) and valid(p1) then
                viewBack(pc, p1, viewOf)
            end
        end
        if session then
            fitBadge()
            if session.ending then
                loadout.finish(session.ending)       -- (an end that had no bag to put back: again)
            elseif session.n == n and not session.opened and now - session.at > OPEN_WAIT_S then
                loadout.finish("the menu didn't open")
            end
            return
        end
        if now < nextKeep then
            return
        end
        nextKeep = now + KEEP_S
        local body = bodyOf(n)
        if not valid(body) then
            return
        end
        local addr = body:GetAddress()
        local b = bodies[n]
        if not b or b.addr ~= addr then
            b = { addr = addr, at = now }
            bodies[n] = b
        end
        local _, p1 = api.getPlayer1()
        local bp = valid(p1) and game.backpackOf(p1) or nil
        if not bp or held or now - b.at < SETTLE_S then
            return
        end
        local g = gear[n]
        local hand = false
        if g and not forced(bp) then
            if not g.checked then
                checkOwned(g, bp, p1, body)
            end
            keepOneWearer(n, g, bp, b)
            if g.outfit then
                pcall(game.dressGhost, body, g.outfit, g.hatHidden == true, g.skin or 0)
            end
            hand = dressSlot(body, MAIN, g, "mainPaths", "mainAt", b)
            hand = dressSlot(body, EDGE, g, "edgePaths", "edgeAt", b) or hand
            if not b.effects then
                putEffects(g, body, b)
            end
        else
            -- (Nothing of their own: they hold the bag's, and only their switch is looked for.)
            local cwc = weaponsOf(body)
            local okI, idx = pcall(function() return cwc:GetCurrentWeaponIndex(slot(MAIN), false) end)
            if okI and type(idx) == "number" and idx ~= b.mainAt then
                hand = b.mainAt ~= nil
                b.mainAt = idx
            end
        end
        if hand then
            keepPlayer1Hand(p1, bp)
        end
        -- (Their switch, kept for the next start: written once things have been still a few seconds.)
        if g and g.changedAt and now - g.changedAt > WRITE_AFTER_S then
            g.changedAt = nil
            pcall(loadout.write)
        end
    end

    -- A player's own body is gone (single player, a map load): their menu ends, and the effects went with the body.
    function loadout.leave(n, why)
        loadout.finish(why)
        bodies[n] = nil
    end

    return loadout
end
