-- A lesson that can't be done. The game teaches Mind's Eye with a forced step (Xigu's BPF_XiGuMapGuide1): the player's
-- input sets are cut down to the one that holds the sense (IMC_OnlySense), a guide says to hold it, and the story waits
-- for the sense to start. The sense (GA_Player_Sense) won't start while the game counts the player in a fight
-- (CharacterState.InCombat, one for each enemy in combat with them), and online a guest is counted in one by the copies
-- around them: a copy stands in a fight with them in their own game, never fights it and so never ends it. They could
-- neither move nor do the one thing asked ("during tutorial when game asks you to perform minds eye client get softlocked
-- and cannot perform it", 11-11).
--
-- So online, while that set is on the player's input: the copies by them that stand in a fight are put back to idle
-- (game.calmCopy), and what's left of the game's count is taken off, at every look, till the lesson's done and the set
-- gone. On the bench (11-16, a guest by three enemies of the host's): counted in, the sense's key did nothing; the
-- count alone taken off came straight back while one copy's own AI held its fight (eight times a look, and still
-- there), and stayed off where none did; with the copies put to idle the game took the count off itself and the key
-- started the sense in half a second, as it does for a player in no fight. The count goes through the game's own
-- container of that tag, the camera's (one made by hand killed UE4SS: localcoop.lua's V.inCombatTags).
-- On a guest: every enemy by them, one its own game runs too (a real fight, but the player can do nothing in it but
-- the lesson). On a host: only its copies of those a guest's game runs: its own enemies' fights are everyone's, and
-- putting one to idle would end it for all.
--
-- And a guest out of a fight nobody is fighting. Those same copies kept a guest counted in a fight for as long as the
-- enemies lived, lesson or no lesson: 60 m from a fight the host had long taken over, the count stood at 3 (the bench,
-- 11-16), the sense's key dead and the camera in its fight mode. So a guest counted in one with no boss bar up, whom
-- nothing of the host's has gone for (no move aimed at them: net.aimedAt) and who has lost no health for QUIET_S, has
-- the copies the host steers that stand in a fight put back to idle, and a count that no copy holds taken off. One that
-- goes for them again has them in a fight again at once.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local net = api.coop.net

    local lesson = {
        SET = "/Game/PBZContent/Input/IMC_OnlySense.IMC_OnlySense",
        LOOK_MS = 250,
        MOST = 16,              -- counts taken off at one look at most (the game keeps one for each enemy in the fight)
        CALM_CM = 8000,         -- copies this near the player are put back to idle
        CALM_S = 1.0,           -- each of them once in this long at most
        QUIET_S = 8,            -- a guest counted in a fight this long with nothing going for them is taken out of it
        up = false,             -- the sense-only set is on the player's input now
        freed = 0,              -- looks that took a count off
        idled = 0,              -- copies put back to idle
        calmed = {},            -- copy address -> os.clock() it was last put to idle
    }

    -- Whether the game has cut this player's input down to the sense alone: its sense-only set is on their input. (The
    -- set isn't even loaded till a lesson brings it: then nothing more is asked.)
    function lesson.senseOnly(pc)
        local set = StaticFindObject(lesson.SET)
        if not valid(set) then
            return false
        end
        local lib = StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary")
        local class = StaticFindObject("/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem")
        if not (valid(lib) and valid(class)) then
            return false
        end
        local input = lib:GetLocalPlayerSubSystemFromPlayerController(pc, class)
        return valid(input) and input:HasMappingContext(set, {}) == true
    end

    -- The game's own container of that one tag, the camera's. (Only while it holds that tag alone.)
    local function combatTags(pawn)
        local cam = pawn:GetComponentByClass(StaticFindObject("/Script/NBCamera.NBCameraComponent"))
        if not valid(cam) then
            return nil
        end
        local tags, n, only = cam.CombatModeTag.RequireTags, 0, nil
        tags.GameplayTags:ForEach(function(_, t)
            n = n + 1
            only = t:get().TagName:ToString()
        end)
        return (n == 1 and only == "CharacterState.InCombat") and tags or nil
    end

    -- The copies by this player that stand in a fight, put back to idle: how many. (From the list the net loop keeps:
    -- nothing is looked for here.) steered: only those the host steers, and how many others by this player stand in a
    -- fight: enemies this game runs itself, whose fight with this player is real.
    local function calmCopies(pawn, steered)
        local host = api.coop.isHost()
        local me = pawn:K2_GetActorLocation()
        local now, n, real = os.clock(), 0, 0
        local list, addrs = game.enemiesSoFar()
        for i, e in ipairs(list) do
            local addr = addrs[i]
            if valid(e) and now - (lesson.calmed[addr] or -1e9) >= lesson.CALM_S and not game.isDead(e) then
                local l = e:K2_GetActorLocation()
                local near = (l.X - me.X) ^ 2 + (l.Y - me.Y) ^ 2 + (l.Z - me.Z) ^ 2 <= lesson.CALM_CM ^ 2
                if near and steered and not (api.puppets and api.puppets.follows(addr)) then
                    local state = game.aiState(e)
                    if state and not state:find("Idle", 1, true) then
                        real = real + 1
                    end
                elseif near and (not host or (net.guestRuns and net.guestRuns[game.enemyId(e, addr)]))
                    and game.calmCopy(e) then
                    lesson.calmed[addr] = now
                    n = n + 1
                end
            end
        end
        return n, real
    end

    -- Taken off through the camera's container, till the game counts this player out or MOST times: how many.
    local function takeOff(pawn)
        local tags = combatTags(pawn)
        local n = 0
        local lib = tags and StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
        if tags and valid(lib) then
            while n < lesson.MOST and game.inCombat(pawn) do
                lib:RemoveLooseGameplayTags(pawn, tags, false)
                n = n + 1
            end
        end
        return n
    end

    -- A guest, no lesson up: out of a fight nobody is fighting (see the top).
    local function quiet(pawn)
        local now = os.clock()
        local hp = game.getHealth(pawn)
        if hp and lesson.hp and hp < lesson.hp - 0.5 then
            lesson.hurtAt = now
        end
        lesson.hp = hp
        if not game.inCombat(pawn) or game.bossFightActive() then
            lesson.countedSince = nil
            return
        end
        lesson.countedSince = lesson.countedSince or now
        local since = math.max(lesson.countedSince, lesson.hurtAt or -1e9, net.aimedAt or -1e9, lesson.sweptAt or -1e9)
        if now - since < lesson.QUIET_S then
            return
        end
        lesson.sweptAt = now
        -- (Not with an enemy this game runs standing in a fight by them: that fight is real, about to begin or going on,
        -- and the count is the game's. On the bench, 11-16, it was taken off as three such came for the guest.)
        local idled, real = calmCopies(pawn, true)
        local n = (idled == 0 and real == 0) and takeOff(pawn) or 0
        lesson.idled, lesson.swept = lesson.idled + idled, (lesson.swept or 0) + 1
        if (idled > 0 or n > 0) and now - (lesson.saidAt or -1e9) >= 60 then
            lesson.saidAt = now
            log(string.format("Counted in a fight with nothing going for you for %d s: %d cop%s standing in one put back to "
                .. "idle, the count taken off (%d).", lesson.QUIET_S, idled, idled == 1 and "y" or "ies", n))
        end
    end

    local function look()
        if not net.enabled then
            lesson.up = false
            return
        end
        -- (The quiet after a load or a trip, as every other slow job's: the enemies in hand may be the old area's.)
        if os.clock() < (net.quietUntil or 0) then
            return
        end
        local pc, pawn = api.getPlayer1()
        if not (valid(pc) and valid(pawn)) or game.isDead(pawn) then
            lesson.up = false
            return
        end
        local up = lesson.senseOnly(pc)
        if up ~= lesson.up then
            lesson.up, lesson.told, lesson.calmed = up, false, {}
        end
        if not up then
            if not api.coop.isHost() then
                quiet(pawn)
            end
            return
        end
        local idled = calmCopies(pawn)
        lesson.idled = lesson.idled + idled
        local n = game.inCombat(pawn) and takeOff(pawn) or 0
        if n > 0 then
            lesson.freed = lesson.freed + 1
        end
        if (idled > 0 or n > 0) and not lesson.told then
            lesson.told = true
            log(string.format("The Mind's Eye lesson holds your controls, and the game counted you in a fight: %d cop%s by "
                .. "you put back to idle, the count taken off (%d), so the sense can start.", idled, idled == 1 and "y" or "ies", n))
        end
    end

    LoopInGameThreadWithDelay(lesson.LOOK_MS, function()
        local ok, err = pcall(look)
        if not ok and err ~= lesson.lastError then
            lesson.lastError = err
            log("Lesson watch: " .. tostring(err))
        end
        return false
    end)

    return lesson
end
