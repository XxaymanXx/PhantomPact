-- A partner's hits on enemies, heard and seen: the game's own hit sound and blood on everyone's copy of the enemy. And
-- their swings, heard: each swing's own sounds on their figure, hit or miss (see "a partner's swings" below).
--
-- A player's own hit plays its sound and blood through the game's hit-effect chooser, asked with the attack's type, its
-- strength and the body's material (BP_HitEffectPlayer_Chooser:GetEffectData: the hero's blade landing a light hit on flesh
-- is SFX_Combat_Hit_SlashTangBlade_Meat_Light and three blood systems). The partner's figure only replays moves (montages,
-- no abilities), so its blade never lands, and their hits made no sound on the other PC (player report 11-09: "it feels
-- like they are hitting air"; bench 11-10: the guest's 12 hits played nothing on the host, the host's 3 nothing on the guest).
--
-- So each PC notes what its chooser was asked for its own hits (a hook: GetEffectData is a Blueprint function, which the
-- script layer sees), and when the mod counts one of those hits on an enemy (a guest's report on the host's enemy, or a
-- health drop on an enemy this game runs), it sends "HX <enemy> <type> <strength> <material>". Everyone else asks their own
-- chooser the same and plays its sound on their copy of that enemy, and its blood where the figure's blade meets the body.
--
-- Not the hitter's slow-down, camera shake or rumble: those are theirs. Not an enemy's deflect of the swing: the game plays
-- deflects through another effect system, not this chooser (asked for a deflect, it gave nothing on the bench). Not in PvP
-- (hits are real there), nor local co-op (player 2's are real too). Older versions drop HX (unknown events are), so with
-- one of those it stays as it was. PartnerHitSounds = On (the ini ships it On; left out, nothing changes).
--
-- The guard (413). A call into the game that goes wrong ends the game then and there: no error for the mod to catch,
-- no line in the log. Players say just that of this file on 1.7.3 and 1.7.4 ("when PartnerHitSounds is enabled, every
-- time a player swings/attacks, the other player crashes"; "only attack/weapon swing trigger crash"), and the bench
-- has never seen it (eight weapons, hundreds of swings, the same game and UE4SS builds). So what is handed to the game
-- here is checked for its class first, and each kind of call leaves a note in a file before its first few of a
-- session and takes it out a moment after. A session that finds a note left was ended inside that call: that one
-- thing is done another way from then on, or no more, and the log says so (see "the guard" below).

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop
    local net = coop.net

    local CHOOSER_FN = "/PBZCombatAsset/Prototypes/Hitreact/BP_HitEffectPlayer_Chooser.BP_HitEffectPlayer_Chooser_C:GetEffectData"
    local CHOOSER = "/PBZCombatAsset/Config/HitReact/HitEffect/PBZ_HitreactEffectPlayer_Chooser.PBZ_HitreactEffectPlayer_Chooser"
    local CHOOSER_BASE = "/Script/PBZCombatAsset.HitreactEffectPlayer_PBZBase"     -- (the class that has GetEffectData)
    local HITREACT = "/Script/SGameCombatSystem.HitreactComponent"
    local AK = "/Script/AkAudio.Default__AkGameplayStatics"
    local NIAGARA = "/Script/Niagara.Default__NiagaraFunctionLibrary"
    local AK_EVENT = "/Script/AkAudio.AkAudioEvent"
    local NIAGARA_SYSTEM = "/Script/Niagara.NiagaraSystem"
    local SCENE = "/Script/Engine.SceneComponent"
    local ACTOR = "/Script/Engine.Actor"

    -- The game's own tags, sent without these heads. (Its attack types are spelled HitReact, the rest Hitreact.)
    local TYPE = "HitReact.AttackType."
    local STRENGTH = "Hitreact.Strength.Income."
    local MATERIAL = "Hitreact.Material."

    local KEEP_S = 0.4          -- a hit's effect waits this long here for the mod to count that hit on an enemy
    local MAX_KEPT = 8
    local OWN_S = 1.5           -- a drop on an enemy this game runs is this player's hit with one of their moves this recent
    local SEEN_S = 1.0          -- a health seen longer ago than this is no measure of a hit (the enemy was away, or not ours)
    local HEAR_CM = 6000        -- a partner's hit is played on an enemy this near this player
    local GAP_S = 0.05          -- one enemy's effects at least this far apart
    local MAX_PER_S = 24        -- partners' effects played per second, at most
    local TOWARD_CM = 25        -- the blood: from the body's bone this far toward the hitter
    local MAX_BLOOD = 4
    local RETRY_S = 5           -- until the chooser is loaded (with the first enemies), the hook is tried this often

    local hitfx = { on = false, sent = 0, played = 0, refused = 0, swings = 0, swingsDropped = 0, learnMaxMs = 0 }
    local kept = {}             -- this player's hits' effects, oldest first: { t, kind, strength, material }
    local hpSeen, addrSeen, atSeen = {}, {}, {}     -- enemies this game runs: name -> health, address and when, last seen
    local lastPlayed, playedN = {}, 0   -- enemy address -> when an effect was last played on it
    local second, inSecond = 0, 0
    local hooked, triedAt = false, -math.huge
    local playing = false       -- this PC asking its chooser for a partner's hit: the hook isn't this player's then

    ------------------------------------------------------------------ the guard

    -- Each kind of call this file makes into the game says so in a file (hitfx_guard.txt, by the mod's own) before its
    -- first few of a session, and its note is taken out GUARD_HOLD_S later. A session that finds a note left was ended
    -- inside that call, or by what it set off, and takes that kind a step on, for good:
    --   swing (a partner's swing sound on their figure), hit (a hit's sound on an enemy): 1 posted on the actor, 2 at
    --   the actor's place (a call that makes no component of the sound engine's on the body and takes no callback),
    --   3 not at all.
    --   blood, ask (the hit-effect chooser), learn (the reading of a partner's weapon): 1, or 2 not at all. A weapon
    --   whose reading ended a session is passed over; GUARD_WEAPONS of those, and none is read.
    -- (The game ending for another reason inside those seconds counts the same. So only a kind's first GUARD_FIRST
    -- calls of a session leave a note: seconds of a session, not all of it.)
    local GUARD_FILE = "hitfx_guard.txt"
    local GUARD_EPOCH = "epoch 1"   -- (its number goes up when these calls are made another way: every PC starts over)
    local GUARD_KINDS = { "swing", "hit", "blood", "ask", "learn" }
    local GUARD_LAST = { swing = 3, hit = 3, blood = 2, ask = 2, learn = 2 }
    local GUARD_INSIDE = { swing = "a partner's swing sound", hit = "a partner's hit sound",
        blood = "the blood of a partner's hit", ask = "the game's choice of a hit's sound and blood",
        learn = "the reading of a partner's weapon" }
    local GUARD_FIRST = 6
    local GUARD_HOLD_S = 2.0
    local GUARD_WEAPONS = 2
    local guard = { way = {}, skip = {}, busy = {}, order = {}, count = {}, noClass = {}, clearAt = 0 }
    for _, kind in ipairs(GUARD_KINDS) do
        guard.way[kind] = 1
    end
    hitfx.guard = guard

    local function guardSkipped()
        local list = {}
        for path in pairs(guard.skip) do
            list[#list + 1] = path
        end
        table.sort(list)
        return list
    end

    -- The file as things stand: each kind past its first way, the weapons passed over, the notes. Nothing to say: no
    -- file.
    local function guardWrite()
        local lines = {}
        for _, kind in ipairs(GUARD_KINDS) do
            if guard.way[kind] > 1 then
                lines[#lines + 1] = kind .. " " .. guard.way[kind]
            end
        end
        for _, path in ipairs(guardSkipped()) do
            lines[#lines + 1] = "skip " .. path
        end
        for _, key in ipairs(guard.order) do
            lines[#lines + 1] = "busy " .. key
        end
        local path = api.modDir() .. GUARD_FILE
        if #lines == 0 then
            if guard.onDisk then
                pcall(os.remove, path)
                guard.onDisk = false
            end
            return
        end
        local f = io.open(path, "w")
        if f then
            f:write(GUARD_EPOCH .. "\n" .. table.concat(lines, "\n") .. "\n")
            f:close()
            guard.onDisk = true
        end
    end

    local function guardSettle()
        local left = guard.clearAt - os.clock()
        if left > 0 then
            game.after(left + 0.05, guardSettle)
            return
        end
        guard.settling, guard.busy, guard.order = false, {}, {}
        guardWrite()
    end

    -- Before a call of that kind: its note. what: the sound or weapon it is about, for the log of the session after
    -- (words, or a function that gives them, asked only if a note is written). always: however many of its kind were
    -- noted (a weapon's reading: every weapon, its note held for as long as it is read).
    local function guardEnter(kind, what, always)
        if not always and (guard.count[kind] or 0) >= GUARD_FIRST then
            return
        end
        if type(what) == "function" then
            what = what()
        end
        local words = tostring(what):gsub("[\r\n]", " ")
        local key = kind .. " " .. words
        if guard.busy[key] then
            if always then
                guard.clearAt = os.clock() + GUARD_HOLD_S
            end
            return
        end
        guard.count[kind] = (guard.count[kind] or 0) + 1
        guard.busy[key], guard.order[#guard.order + 1] = true, key
        guard.clearAt = os.clock() + GUARD_HOLD_S
        guardWrite()
        if not guard.settling then
            guard.settling = true
            game.after(GUARD_HOLD_S + 0.05, guardSettle)
        end
    end

    local function guardNow(kind)
        if kind == "swing" or kind == "hit" then
            local whose = kind == "swing" and "A partner's swing sounds" or "A partner's hit sounds"
            return guard.way[kind] == 2 and (whose .. " are played at their place from now on, by another call of the game's.")
                or (whose .. " are off on this PC from now on.")
        elseif kind == "blood" then
            return "The blood of a partner's hits is off on this PC from now on."
        elseif kind == "ask" then
            return "A partner's hit sounds and blood are off on this PC from now on."
        end
        return guard.way.learn > 1 and "A partner's swing sounds are off on this PC from now on."
            or "That weapon's swing sounds are left out on this PC from now on."
    end

    -- The file as the last session left it, read once as the mod starts.
    local function guardLoad()
        local f = io.open(api.modDir() .. GUARD_FILE, "r")
        if not f then
            return
        end
        local text = f:read("a") or ""
        f:close()
        guard.onDisk = true
        local lines, ended = {}, {}
        for line in text:gmatch("[^\r\n]+") do
            lines[#lines + 1] = line
        end
        if lines[1] == GUARD_EPOCH then
            for i = 2, #lines do
                local word, rest = lines[i]:match("^(%a+) (.+)$")
                if word == "skip" then
                    guard.skip[rest] = true
                elseif word == "busy" then
                    local kind, what = rest:match("^(%a+) (.+)$")
                    if kind and GUARD_LAST[kind] then
                        ended[kind] = what      -- (a kind's last note: the call nearest the end)
                    end
                elseif word and GUARD_LAST[word] and rest:match("^%d$") and tonumber(rest) <= GUARD_LAST[word] then
                    guard.way[word] = math.max(1, tonumber(rest))
                end
            end
        end
        for _, kind in ipairs(GUARD_KINDS) do
            if ended[kind] and kind == "learn" then
                guard.skip[ended[kind]] = true
            elseif ended[kind] then
                guard.way[kind] = math.min(guard.way[kind] + 1, GUARD_LAST[kind])
            end
        end
        if #guardSkipped() >= GUARD_WEAPONS then
            guard.way.learn = 2
        end
        for _, kind in ipairs(GUARD_KINDS) do
            local what = ended[kind]
            if what then
                log(string.format("Partner hit sounds: the last session ended inside %s (%s). %s To start over, delete %s in the mod's folder.",
                    GUARD_INSIDE[kind], what:sub(1, 1) == "/" and what:match("([^./]+)$") or what, guardNow(kind), GUARD_FILE))
            end
        end
        guardWrite()        -- (without the notes; a file of another epoch, or with nothing left to say, goes)
    end
    do
        local ok, err = pcall(guardLoad)
        if not ok then
            log("Partner hit sounds: the guard's file can't be read (" .. tostring(err) .. ").")
        end
    end

    -- What the guard holds back on this PC, for the setting's line in the log: nothing said while nothing is.
    local function guardSays()
        local parts = {}
        for _, kind in ipairs(GUARD_KINDS) do
            if guard.way[kind] > 1 then
                parts[#parts + 1] = kind .. " " .. guard.way[kind]
            end
        end
        local skipped = #guardSkipped()
        if skipped > 0 then
            parts[#parts + 1] = skipped .. " weapon" .. (skipped > 1 and "s" or "") .. " left out"
        end
        if #parts == 0 then
            return ""
        end
        return " Held back on this PC after a session that ended inside one of its calls (" .. table.concat(parts, ", ")
            .. "): delete " .. GUARD_FILE .. " in the mod's folder to start over."
    end

    local function pathOf(o)
        local s
        pcall(function() s = o:GetFullName():gsub("^%S+ ", "") end)
        return s
    end

    -- An object of that class of the game's (by the class's path), and of no other kind: a call into the game handed
    -- the wrong kind of object is one it doesn't come back from. (A class this game hasn't got at all checks nothing,
    -- as it was before there was a check: said once.)
    local function isA(o, classPath)
        if not valid(o) then
            return false
        end
        local c = StaticFindObject(classPath)
        if not valid(c) then
            if not guard.noClass[classPath] then
                guard.noClass[classPath] = true
                log("Partner hit sounds: the game has no class " .. classPath .. " here: nothing is checked against it.")
            end
            return true
        end
        local ok, yes = pcall(function() return o:IsA(c) end)
        return ok and yes == true
    end

    -- One sound of the game's on an actor, of that kind (swing, hit), the way its guard stands at: on the actor (the
    -- sound engine makes a component of its own on the body for it, the first time), or at the actor's place (a call
    -- that makes none, and takes no callback). The playing's id; nil if nothing was posted. name: the event's path if
    -- it is known, for the note.
    local function post(kind, ev, actor, name)
        local way = guard.way[kind]
        if way >= 3 or not (isA(ev, AK_EVENT) and isA(actor, ACTOR)) then
            return nil
        end
        local ak = StaticFindObject(AK)
        if not valid(ak) then
            return nil
        end
        local id
        local function what()
            return name or pathOf(ev) or "?"
        end
        if way == 1 then
            guardEnter(kind, what)
            pcall(function() id = ak:PostEvent(ev, actor, 0, {}, false) end)
            return id
        end
        if guard.placeArgs == false then
            return nil
        end
        local at, turn
        if not pcall(function()
            local l, r = actor:K2_GetActorLocation(), actor:K2_GetActorRotation()
            at, turn = { X = l.X, Y = l.Y, Z = l.Z }, { Pitch = 0.0, Yaw = r.Yaw, Roll = 0.0 }
        end) then
            return nil
        end
        guardEnter(kind, what)
        -- (The sound engine's call for a place takes the world's object last, and by its build a name for the event
        -- before that or not. The one that fits this game is found by trying: the other is refused as its values are
        -- set, before any call is made.)
        if guard.placeArgs ~= 5 and pcall(function() id = ak:PostEventAtLocation(ev, at, turn, actor) end) then
            guard.placeArgs = 4
            return id
        end
        if guard.placeArgs ~= 4 and pcall(function() id = ak:PostEventAtLocation(ev, at, turn, "", actor) end) then
            guard.placeArgs = 5
            return id
        end
        if guard.placeArgs == nil then
            guard.placeArgs = false
            log("Partner hit sounds: this game's sound engine has no call for a sound at a place that fits: those stay silent.")
        end
        return nil
    end

    local function tagOf(param)
        local s
        pcall(function() s = param:get().TagName:ToString() end)
        return s
    end

    -- What the chooser was asked for here: an attack's hit on something that isn't a player (an enemy, once the mod counts
    -- it). (Lua only: no game call inside the hook.)
    local function note(kind, strength, material)
        if not (kind and strength and material) or kind:sub(1, #TYPE) ~= TYPE or strength:sub(1, #STRENGTH) ~= STRENGTH
            or material:sub(1, #MATERIAL) ~= MATERIAL or material:find("Player", 1, true) then
            return
        end
        if #kept >= MAX_KEPT then
            table.remove(kept, 1)
        end
        kept[#kept + 1] = { t = os.clock(), kind = kind:sub(#TYPE + 1), strength = strength:sub(#STRENGTH + 1),
            material = material:sub(#MATERIAL + 1) }
    end

    -- (A hook on a Blueprint function, which takes no interface parameter: a hook on one with an interface once killed the
    -- host. Hooks on the hit-react component's own calls crashed the bench copy on 11-10: none of those. The hook fires on
    -- the mod's own asks too (hitfx.play): those are a partner's hits, never this player's, and sent back they came twice.)
    local function hook()
        if hooked or os.clock() - triedAt < RETRY_S then
            return
        end
        triedAt = os.clock()
        if not valid(StaticFindObject(CHOOSER_FN)) then
            return
        end
        local ok, err = pcall(RegisterHook, CHOOSER_FN, function(_, kind, strength, material)
            if hitfx.on and not playing and not net.pvp then
                note(tagOf(kind), tagOf(strength), tagOf(material))
            end
        end)
        hooked = ok
        if ok then
            log("Partner hit sounds: this player's hits are watched.")
        else
            triedAt = math.huge
            log("Partner hit sounds: the game's hits can't be watched here (" .. tostring(err) .. ").")
        end
    end

    -- Each enemy's turn (coop.lua syncEnemy): the hook goes in once the game has loaded its chooser, before this player's
    -- first hit.
    function hitfx.ready()
        if hitfx.on and not hooked then
            hook()
        end
    end

    -- A hit of this player's on an enemy, as the mod counts it (a guest's report in coop.lua, a drop seen by hitfx.runs): the
    -- newest effect played here for it, fresh enough, goes to everyone else. id: the enemy's name on the wire (the host's).
    function hitfx.ownHit(id, actor)
        if not hitfx.on or net.pvp or not id then
            return
        end
        hook()
        local r = kept[#kept]
        if r and os.clock() - r.t <= KEEP_S then
            kept[#kept] = nil
            coop.sendEvent("HX", id, r.kind, r.strength, r.material)
            hitfx.sent = hitfx.sent + 1
        end
    end

    -- Each turn of an enemy this game runs (coop.lua: the host's in shareEnemy, a guest's own far from the host in
    -- handover.share): a health drop with one of this player's moves just before is this player's hit. (A partner's blow
    -- written here takes itself off first: see handlers.D below.) theirs: one a guest's game runs that the host's copy
    -- follows, written down to the guest's lines: only noted (the host's hits on it go by reportHit).
    function hitfx.runs(name, actor, addr, hp, theirs)
        if not hitfx.on or net.pvp then
            return
        end
        if not hooked then
            hook()
        end
        local now = os.clock()
        local was = addrSeen[name] == addr and now - (atSeen[name] or -math.huge) <= SEEN_S and hpSeen[name] or nil
        hpSeen[name], addrSeen[name], atSeen[name] = hp, addr, now
        if was and hp < was - 0.5 and not theirs and kept[1] and game.localMoveRecent(OWN_S) then
            hitfx.ownHit(name, actor)
        end
    end

    -- A partner's reported blow (handlers.D, on the host and on a guest for one it runs) lowers the enemy's health here: not
    -- this player's hit, so it comes off what runs() last saw, and only the rest of a drop counts.
    local partnerBlow = coop.handlers.D
    coop.handlers.D = function(rest, from)
        if not hitfx.on or net.pvp then
            return partnerBlow(rest, from)
        end
        local name = (rest or ""):match("^(%S+)")
        local actor = name and coop.enemyActor(name)
        local before = valid(actor) and game.getHealth and game.getHealth(actor) or nil
        partnerBlow(rest, from)
        if before and valid(actor) and addrSeen[name] == actor:GetAddress() and hpSeen[name] then
            local after = game.getHealth(actor)
            if after and after < before then
                hpSeen[name] = hpSeen[name] - (before - after)
            end
        end
    end

    -- Where the blow lands: the body's bone moved toward the hitter, facing away from them (the blood flies on from there).
    local function landing(mesh, bone, from)
        local at = mesh:GetSocketLocation(bone)
        local dx, dy = 1, 0
        if from then
            dx, dy = from.X - at.X, from.Y - at.Y
            local len = math.sqrt(dx * dx + dy * dy)
            if len < 1 then
                dx, dy = 1, 0
            else
                dx, dy = dx / len, dy / len
            end
        end
        return { X = at.X + dx * TOWARD_CM, Y = at.Y + dy * TOWARD_CM, Z = at.Z },
            { Pitch = 0.0, Yaw = math.deg(math.atan(-dy, -dx)), Roll = 0.0 }
    end

    -- The body's own chooser if it has one of the kind that answers GetEffectData (an override, then its own), else the
    -- game's common one. (Others, the dragon pillar's say, are of a class without it.)
    local function chooserOf(comp)
        local base = StaticFindObject(CHOOSER_BASE)
        if not valid(base) then
            if not hitfx.saidNoBase then
                hitfx.saidNoBase = true
                log("Partner hit sounds: the game's hit-effect class isn't here (" .. CHOOSER_BASE .. "): partners' hits stay silent.")
            end
            return nil
        end
        local function fits(c)
            local ok, yes = pcall(function() return valid(c) and c:IsA(base) end)
            return ok and yes
        end
        local c = comp.HitEffectPlayerOverride
        if not fits(c) then
            c = comp.EffectPlayer
        end
        if not fits(c) then
            c = StaticFindObject(CHOOSER)
        end
        return fits(c) and c or nil
    end

    -- The game's own effect for these tags on this body: its sound on it, its blood where the blow lands (from: where the
    -- hitter stands). True if anything played.
    function hitfx.play(actor, kind, strength, material, from)
        if not valid(actor) then
            return false
        end
        local class = StaticFindObject(HITREACT)
        if guard.way.ask > 1 or not valid(class) then
            return false
        end
        local comp = actor:GetComponentByClass(class)
        if not valid(comp) then
            return false
        end
        local chooser = chooserOf(comp)
        if not chooser then
            return false
        end
        local particles, slomo, shake, sound = {}, {}, {}, {}
        guardEnter("ask", kind .. " " .. strength .. " " .. material)
        playing = true
        local asked = pcall(function()
            chooser:GetEffectData({ TagName = FName(TYPE .. kind) }, { TagName = FName(STRENGTH .. strength) },
                { TagName = FName(MATERIAL .. material) }, particles, slomo, shake, sound)
        end)
        playing = false
        if not asked then
            return false
        end
        local played = post("hit", sound.HitSound, actor) ~= nil
        local list, n = particles.Particles, 0
        pcall(function() n = #list end)
        local mesh, niagara = actor.Mesh, StaticFindObject(NIAGARA)
        if guard.way.blood == 1 and n > 0 and isA(mesh, SCENE) and valid(niagara) then
            local body = {}
            pcall(function() comp:GetMainBodyData(body) end)
            local bone = body.bone
            local okAt, where, turn = false, nil, nil
            if bone ~= nil then
                okAt, where, turn = pcall(landing, mesh, bone, from)
            end
            for i = 1, okAt and math.min(n, MAX_BLOOD) or 0 do
                pcall(function()
                    local e = list[i]
                    e = (type(e) == "userdata" and e.get) and e:get() or e
                    local system = e.Particle
                    if isA(system, NIAGARA_SYSTEM) then
                        guardEnter("blood", function() return pathOf(system) or "?" end)
                        niagara:SpawnSystemAttached(system, mesh, bone, where, turn, 1, true, true, 0, true)
                        played = true
                    end
                end)
            end
        end
        return played
    end

    local function sane(s, pattern)
        return s ~= nil and #s <= 80 and s:match(pattern) ~= nil
    end

    -- A partner's hit on an enemy: the same effect here, on this PC's copy of it.
    coop.handlers.HX = function(rest, from)
        if not hitfx.on or net.pvp or os.clock() < (net.quietUntil or 0) then
            return
        end
        local id, kind, strength, material = (rest or ""):match("^(%S+) (%S+) (%S+) (%S+)$")
        if not (id and sane(kind, "^[%w_%.]+$") and sane(strength, "^[%w_%.]+$") and sane(material, "^[%w_]+$")) then
            hitfx.refused = hitfx.refused + 1
            return
        end
        local now = os.clock()
        if now - second >= 1 then
            second, inSecond = now, 0
        end
        if inSecond >= MAX_PER_S then
            hitfx.refused = hitfx.refused + 1
            return
        end
        local actor = coop.enemyActor(id)
        if not valid(actor) then
            return
        end
        local addr = actor:GetAddress()
        if now - (lastPlayed[addr] or -math.huge) < GAP_S then
            return
        end
        local at = actor:K2_GetActorLocation()
        local pawn = coop.localPawn()
        local here = valid(pawn) and pawn:K2_GetActorLocation() or nil
        if here and (at.X - here.X) ^ 2 + (at.Y - here.Y) ^ 2 + (at.Z - here.Z) ^ 2 > HEAR_CM * HEAR_CM then
            return
        end
        local p = coop.peerOf(from)
        local figure = p and p.ghost
        inSecond = inSecond + 1
        if playedN > 200 then
            lastPlayed, playedN = {}, 0
        end
        lastPlayed[addr], playedN = now, playedN + 1
        if hitfx.play(actor, kind, strength, material, valid(figure) and figure:K2_GetActorLocation() or here) then
            hitfx.played = hitfx.played + 1
        end
    end

    ------------------------------------------------------------------ a partner's swings

    -- A player's own swing sounds through its attack's ability, not its montage: the light attack's montage
    -- (AM_Hun_Tang_A) has no notifies at all, and its ability's timeline has the swing's sound steps (bench 11-12: their
    -- shout SFX_Combat_VO_Hun_ChuZhao_02 0.253 s in, the blade's whoosh SFX_Combat_Hun_Common_Wave_Light 0.273 s, cloth
    -- 0.277 s; some moves name the weapon's own sound by a tag instead, GAA_PBZWeaponSound_C, through the weapon config's
    -- Sounds table). A partner's figure only replays their montages (moves.lua), never their abilities, so their swings
    -- that hit nothing made no sound here (player report on 1.7.1: "they want air swings (non-hit) audible"; a hit has its
    -- sound from HX above). (The whoosh alone is quiet, on one's own swings too: what's heard of a swing is mostly the shout
    -- with it. Bench, the host's sound metered: the whoosh posted on the figure 2.5 m off rose as high as 46 of 500 random
    -- moments did, the shout as 1 of 500.)
    -- So each PC reads, from the game's own data, the moves of the weapons a partner holds (W and E, moves.lua): the
    -- montage each timeline plays, and its sound steps against that montage's start. When their figure plays one of those
    -- montages, each step's sound is posted on the figure as its montage gets there, once a play. Nothing new goes over the
    -- network, so a partner on an older version is heard too. Only steps of the character, the body or the weapon, played
    -- whole on the figure: not one stopped at its step's end, a loop or a stop (nothing here would stop the one, and the
    -- other could stop this player's own), a menu, music or controller event (bench 11-12: a deflect has a menu one, and
    -- dodges shake the pad), one posted at this player's place or a fixed one, nor the kinds that set a surface or battle
    -- switch first. Not in PvP: the figure plays their abilities there (M), and those make their own sounds.
    local WEAPON_SOUND = "GAA_PBZWeaponSound_C"
    local PLAIN_SOUNDS = { GAA_PlaySound_Opt_C = true, LGAAction_PlaySoundDefault = true }
    local PLAY_MONTAGE = "/Script/LegoAbility.LGAAction_PlayMontage"
    local KINDS = { [0] = true, [1] = true, [2] = true }    -- (EPlaySoundType: Character, Bodypart, Weapon; not 3, InteractWeapon)
    local NOT_EVENTS = { "^/Game/Wwise/Events/UI/", "^/Game/Wwise/Events/Mus", "^/Game/Wwise/Events/Motion/",
        "^/Game/Wwise/Events/Stop/", "_[Ll]oop", "_[Ss]top[%._]" }
    local SOUND_FIELD = "Sound_21_D6348F8E4FAA4263E62C63AFE8750487"      -- (FWeaponSoundData's, a Blueprint struct)
    local ABILITY_LISTS = { "Equip Abilities", "Owning Abilities" }
    local LATE_S = 0.25         -- a step the figure's montage started past by up to this much still plays, at once
    local NEW_PLAY_S = 0.1      -- told from further in than this, a montage they're still in is the same play (see swung)
    local LEARN_BUDGET_S = 0.001    -- a weapon's moves are learned a timeline at a time, for this long a step at most
    local LEARN_MAX = 2         -- (and so many timelines: 6 took 2-4 ms a step on the bench; the sword's 93, 1.5 s or so)
    local LEARN_EVERY_S, LEARN_WAIT_S = 0.025, 1.0  -- a step this often; looked at again this often for one not loaded yet
    local LEARN_AFTER_LOAD_S = 10.0 -- a weapon this PC had to load is read no sooner than this after (see tooNew)
    local MAX_SWINGS_PER_S = 30 -- one partner's swing sounds played per second, at most
    local weapons = {}          -- weapon config path -> what's learned of it (strings and numbers only), see learn

    local function size(t)
        local n = 0
        for _ in pairs(t) do
            n = n + 1
        end
        return n
    end

    -- A play-sound step heard on the body, played whole: its event's path, else nil.
    local function soundStep(a)
        local kind, stops, ev, atPlayer, fixed
        pcall(function() kind, stops, ev = a.PlaySoundType, a.StopOnEnd, a.AkEvent end)
        pcall(function() atPlayer, fixed = a.PostAtPlayerLocation, a.PostAtFixedLocation end)
        if not KINDS[kind] or stops ~= false or atPlayer == true or fixed == true or not isA(ev, AK_EVENT) then
            return nil
        end
        local path = pathOf(ev)
        for _, no in ipairs(NOT_EVENTS) do
            if not path or path:find(no) then
                return nil
            end
        end
        return path
    end

    -- A class's timelines, its own or else its nearest parent's (looked up each time: nothing kept).
    local function timelinesOf(classPath)
        local c, list = StaticFindObject(classPath), {}
        for _ = 1, 8 do
            if not valid(c) then
                break
            end
            pcall(function()
                c.AbilityTimelines:ForEach(function(_, e)
                    local t = e:get()
                    if valid(t) then
                        list[#list + 1] = t
                    end
                end)
            end)
            if #list > 0 then
                break
            end
            local up
            pcall(function() up = c:GetSuperStruct() end)
            c = up
        end
        return list
    end

    -- One timeline: the montages it plays and its sound steps, each step under the montage last started before it, kept
    -- as w.montages[montage path] = { { at = seconds into the montage, ev = its event's path, or tag = the weapon's own
    -- sound's }... }, from the first timeline that has steps for that montage.
    local function learnTimeline(w, t, playMontage)
        local plays, steps = {}, {}
        pcall(function()
            t.Actions:ForEach(function(_, e)
                pcall(function()
                    local ev = e:get()
                    local a, at = ev.Action, ev.StartTime
                    if not (valid(a) and type(at) == "number") then
                        return
                    end
                    local cn = a:GetClass():GetFName():ToString()
                    if cn == WEAPON_SOUND then
                        steps[#steps + 1] = { t = at, tag = a["Sound Tag"].TagName:ToString() }
                    elseif PLAIN_SOUNDS[cn] then
                        local path = soundStep(a)
                        if path then
                            steps[#steps + 1] = { t = at, ev = path }
                        end
                    elseif a:IsA(playMontage) and valid(a.MontageToPlay) then
                        local rate = tonumber(a.PlayRate) or 1
                        plays[#plays + 1] = { t = at, path = pathOf(a.MontageToPlay), rate = rate > 0 and rate or 1 }
                    end
                end)
            end)
        end)
        table.sort(plays, function(x, y) return x.t < y.t end)
        local found = {}
        for _, s in ipairs(steps) do
            local m
            for _, p in ipairs(plays) do
                if p.t <= s.t then
                    m = p
                end
            end
            if m and m.path and not w.montages[m.path] then
                found[m.path] = found[m.path] or {}
                table.insert(found[m.path], { at = (s.t - m.t) * m.rate, ev = s.ev, tag = s.tag })
            end
        end
        for path, list in pairs(found) do
            table.sort(list, function(x, y) return x.at < y.at end)
            w.montages[path] = list
        end
    end

    -- What's learned of one weapon of a partner's, a little each call: first its sounds by tag (the event's path) and its
    -- abilities' paths, then their timelines (learnTimeline). Nil while this game hasn't loaded it (moves.lua loads a
    -- partner's to hand it to their figure): nothing is loaded for this.
    local function learn(path)
        local w = weapons[path]
        if w and w.done then
            return w
        end
        local cfg, playMontage = StaticFindObject(path), StaticFindObject(PLAY_MONTAGE)
        if not (valid(cfg) and valid(playMontage)) then
            return nil
        end
        guardEnter("learn", path, true)     -- (the note that this weapon is being read: there till 2 s after its last step)
        if not w then
            w = { sounds = {}, montages = {}, abilities = {}, next = 1, part = 1 }
            weapons[path] = w
            pcall(function()
                cfg.Sounds:ForEach(function(k, v)
                    local ev = v:get()[SOUND_FIELD]
                    if isA(ev, AK_EVENT) then
                        w.sounds[k:get().TagName:ToString()] = pathOf(ev)
                    end
                end)
            end)
            for _, list in ipairs(ABILITY_LISTS) do
                pcall(function()
                    cfg[list]:ForEach(function(_, e)
                        local c = e:get()
                        if valid(c) then
                            w.abilities[#w.abilities + 1] = pathOf(c)
                        end
                    end)
                end)
            end
            return w
        end
        -- (Bench 11-12: a whole ability a tick took up to 6.7 ms in one; a stance has 15 timelines.)
        local began, n = os.clock(), 0
        while n < LEARN_MAX and os.clock() - began < LEARN_BUDGET_S do
            local classPath = w.abilities[w.next]
            if classPath == nil then
                w.done = true
                log(string.format("Partner swing sounds: %s learned (%d moves with a sound, %d of its own sounds).",
                    path:match("([^.]+)$") or path, size(w.montages), size(w.sounds)))
                break
            end
            local timelines = timelinesOf(classPath)
            if timelines[w.part] then
                learnTimeline(w, timelines[w.part], playMontage)
                n = n + 1
            end
            if w.part >= #timelines then
                w.next, w.part = w.next + 1, 1
            else
                w.part = w.part + 1
            end
        end
        return w
    end

    -- The weapons a partner holds, as their figure is dressed (moves.lua's W and E).
    local function heldBy(p)
        local g = p.gear
        local out = {}
        for _, path in ipairs({ g and g.partnerPath, g and g.edgePath }) do
            if path and path ~= "-" then
                out[#out + 1] = path
            end
        end
        return out
    end

    -- The weapons partners hold learned a step at a time, on the mod's timer, from when one is said (W, E) till all are:
    -- one weapon a step, one not loaded here yet passed over (waited on, it held up everyone's after it) and looked at
    -- again a while later. Not in the quiet after a load. (Not a tick of its own: a new one changed the order the others
    -- ran in, game calls and all.)
    -- A weapon this PC has only just loaded for a partner, or one of a figure only just made: not read yet. Its classes
    -- can still be on their way, and what's read through nothing takes the game with it, no line in the log; the figure
    -- itself waits for such a weapon (moves.lua's weaponConfig, 358: a report on 1.7.3, the host's game gone seconds
    -- after a guest was back). This read began 0.7 s after the load (the bench, run126), and at a sync's start by
    -- itself, the only work of PartnerHitSounds that does: a report on 1.7.3, 11-19, the game gone seconds after two
    -- players linked over Steam, and not with the setting off. A partner with no figure here yet isn't settled either:
    -- at a link their W comes a second or so before the figure is made (the bench, run126: 0.1 s and 1.1 s), and
    -- moves.settled, asked of no figure, says yes (no time of one, or the last figure's): a weapon this PC already
    -- had was read then, 1.7.3's moment. The review of 399.
    local function tooNew(p, path)
        local m = api.moves
        if not m then
            return false
        end
        local ago = m.loadedAgo and m.loadedAgo(path)
        return (ago ~= nil and ago < LEARN_AFTER_LOAD_S) or (m.settled ~= nil and not (valid(p.ghost) and m.settled(p)))
    end

    local learning = false
    local function learnStep()
        learning = false
        if not hitfx.on or net.pvp or net.arena or not net.enabled or guard.way.learn > 1 or guard.way.swing >= 3 then
            return
        end
        local waiting = os.clock() < (net.quietUntil or 0)
        if not waiting then
            for _, p in ipairs(coop.partners()) do
                for _, path in ipairs(heldBy(p)) do
                    local w = weapons[path]
                    if not (w and w.done) and not guard.skip[path] then
                        local began = os.clock()
                        if not tooNew(p, path) and learn(path) then
                            hitfx.learnMaxMs = math.max(hitfx.learnMaxMs, (os.clock() - began) * 1000)
                            learning = true
                            game.after(LEARN_EVERY_S, learnStep)
                            return
                        end
                        waiting = true
                    end
                end
            end
        end
        if waiting then
            learning = true
            game.after(LEARN_WAIT_S, learnStep)
        end
    end

    local function learnSoon()
        if hitfx.on and not learning then
            learning = true
            game.after(LEARN_EVERY_S, learnStep)
        end
    end

    local heardWeapon = coop.handlers.W
    local heardEdge = coop.handlers.E
    coop.handlers.W = function(rest, from)
        heardWeapon(rest, from)
        learnSoon()
    end
    coop.handlers.E = function(rest, from)
        heardEdge(rest, from)
        learnSoon()
    end

    -- One step's sound, on their figure, if it still plays that play of their montage: not after a newer move of theirs,
    -- its end, their figure hidden or made anew (s: play, addr, figure, born, step).
    local function whoosh(p, s, evPath)
        if not hitfx.on or net.pvp or p.swingPlay ~= s.play or not p.ghostMoveAt or p.ghostAt ~= s.born then
            return
        end
        -- (Not in the quiet after a load, as a partner's hit's sound isn't, HX: the world is still coming in.)
        if os.clock() < (net.quietUntil or 0) then
            return
        end
        local figure = p.ghost
        if not valid(figure) or figure:GetAddress() ~= s.figure or p.ghostHidden
            or not (valid(p.ghostMontage) and p.ghostMontage:GetAddress() == s.addr) then
            return
        end
        p.swingDone[s.step] = true          -- (its moment came in this play: not again in it)
        local pawn = coop.localPawn()
        local at, here = figure:K2_GetActorLocation(), valid(pawn) and pawn:K2_GetActorLocation() or nil
        if here and (at.X - here.X) ^ 2 + (at.Y - here.Y) ^ 2 + (at.Z - here.Z) ^ 2 > HEAR_CM * HEAR_CM then
            return
        end
        local now = os.clock()
        if now - (p.swingSecond or -math.huge) >= 1 then
            p.swingSecond, p.swingsInSecond = now, 0
        end
        if p.swingsInSecond >= MAX_SWINGS_PER_S then
            hitfx.swingsDropped = hitfx.swingsDropped + 1
            return
        end
        local id = post("swing", StaticFindObject(evPath), figure, evPath)
        if id ~= nil and id ~= 0 then
            p.swingsInSecond = p.swingsInSecond + 1
            hitfx.swings = hitfx.swings + 1
        end
    end

    -- Their figure has just started one of their montages, start seconds in (moves.playOn: as heard, or held till it could;
    -- told: as far in as they said it was): its sound steps from there on are set to sound as the montage gets to each,
    -- and one just passed at once.
    function hitfx.swung(p, m, path, start, told)
        if not hitfx.on or net.pvp or net.arena or guard.way.swing >= 3 then
            return
        end
        -- (A montage they're still in, told again from further in, is the same play: told again after someone joined, or a
        -- part of it that loops. Its steps already played aren't played again: their own game played each once.)
        if not (p.swingOpen and p.swingPath == path and (told or start or 0) > NEW_PLAY_S) then
            p.swingDone = {}
        end
        p.swingPlay = (p.swingPlay or 0) + 1
        p.swingOpen, p.swingPath = true, path
        local steps, sounds
        for _, wpath in ipairs(heldBy(p)) do
            local w = weapons[wpath]
            if w and w.montages[path] then
                steps, sounds = w.montages[path], w.sounds
                break
            elseif not (w and w.done) then
                learnSoon()
            end
        end
        local figure = p.ghost
        if not (steps and valid(figure)) then
            return
        end
        local play, addr, figAddr, born = p.swingPlay, m:GetAddress(), figure:GetAddress(), p.ghostAt
        for i, step in ipairs(steps) do
            local evPath = step.ev or sounds[step.tag]
            local wait = step.at - (start or 0)
            if evPath and not p.swingDone[i] and wait >= -LATE_S then
                local s = { play = play, addr = addr, figure = figAddr, born = born, step = i }
                game.after(math.max(0, wait), function()
                    whoosh(p, s, evPath)
                end)
            end
        end
    end

    -- Their move is over (moves.lua: "U - 0", or their place says so): a montage of theirs started after it is a new play.
    local moveEnded = api.moves.endMove
    api.moves.endMove = function(p)
        p.swingOpen = nil
        return moveEnded(p)
    end

    -- Someone started sync anew: what this game saw before is no measure of what comes.
    local syncStarted = coop.handlers.S
    coop.handlers.S = function(...)
        kept, hpSeen, addrSeen, atSeen = {}, {}, {}, {}
        return syncStarted(...)
    end

    -- hitsounds on | off   (read at start from PartnerHitSounds)
    function hitfx.command(args)
        local v = (args or ""):lower():match("^%s*(%a+)")
        if v == "on" or v == "off" then
            hitfx.on = v == "on"
            learnSoon()
        end
        log(string.format("Partner hit sounds: %s%s", hitfx.on
            and "on (a partner's swings play their sounds here, and their hits on enemies the game's hit sound and blood)."
            or "off.", guardSays()))
    end

    return hitfx
end
