-- A lesson that can't be done. The game teaches Mind's Eye with a forced step (Xigu's BPF_XiGuMapGuide1): the player's
-- input sets are cut down to the one that holds the sense (IMC_OnlySense), a guide says to hold it, and the story waits
-- for the sense to start. The sense (GA_Player_Sense) won't start while the game counts the player in a fight
-- (CharacterState.InCombat, one for each enemy in combat with them), and online an enemy by them that a partner is
-- fighting keeps them counted: they could neither move nor do the one thing asked ("during tutorial when game asks you
-- to perform minds eye client get softlocked and cannot perform it", 11-11; on the bench then: a guest with an enemy 2 m
-- off, in a fight by the game's count, the sense's key does nothing).
--
-- So online, for either player: while that set is on the player's input and the game counts them in a fight, the count
-- is taken off, at every look, till the lesson's done and the set gone. Through the game's own container of that tag, the
-- camera's (one made by hand killed UE4SS: localcoop.lua's V.inCombatTags). The game counts them in again as the next
-- enemy comes into a fight with them.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local net = api.coop.net

    local lesson = {
        SET = "/Game/PBZContent/Input/IMC_OnlySense.IMC_OnlySense",
        LOOK_MS = 250,
        MOST = 16,              -- counts taken off at one look at most (the game keeps one for each enemy in the fight)
        up = false,             -- the sense-only set is on the player's input now
        freed = 0,              -- looks that took a count off
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

    local function look()
        if not net.enabled then
            lesson.up = false
            return
        end
        local pc, pawn = api.getPlayer1()
        if not (valid(pc) and valid(pawn)) or game.isDead(pawn) then
            lesson.up = false
            return
        end
        local up = lesson.senseOnly(pc)
        if up ~= lesson.up then
            lesson.up, lesson.told = up, false
        end
        if not (up and game.inCombat(pawn)) then
            return
        end
        local tags = combatTags(pawn)
        if not tags then
            return
        end
        local lib = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
        local n = 0
        while n < lesson.MOST and game.inCombat(pawn) do
            lib:RemoveLooseGameplayTags(pawn, tags, false)
            n = n + 1
        end
        lesson.freed = lesson.freed + 1
        if not lesson.told then
            lesson.told = true
            log(string.format("The Mind's Eye lesson holds your controls, and the game counted you in a fight (%d): taken "
                .. "off, so the sense can start.", n))
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
