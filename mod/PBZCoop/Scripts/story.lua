-- Online, the host's story is the party's. Each player keeps their own save, so a guest can be chapters behind the host, or
-- ahead. The world the two play in is the host's, so a guest who is behind is brought up to the host's point: the quest steps
-- the host's world has done and theirs hasn't, applied with the game's own story table (the one its QA tools use), and the
-- unlocks and dialogue marks that come between the two points. Nothing goes back: a guest who is ahead stays ahead, and what
-- a guest found and where they rang bells stays theirs. Bosses the host has beaten follow in coop.lua (BEATEN).
-- FollowHostStory = Off in PhantomPact.ini keeps a guest's story their own.
--
-- The host reads its point while someone is linked and tells it (STORYPT) when it moves; a guest catches up at a quiet moment.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop

    local story = { follow = true }

    -- The table is our own copy (storydata.lua): the game's update of 2026-11-04 took its QA story tables out of the game,
    -- and the catch-up that applied their rows did nothing from then on (1.6.1 to 1.6.3), saying so only in the log.
    local DATA = api.storyData
    local FINISH = "完成任务"        -- the table's quest steps end in this (a branch completed) or 开启任务 (a branch started)

    local LOOK_S = 20               -- host: its point is read this often while someone is linked
    local TELL_S = 60               -- and told again this often, moved or not
    local QUESTS_PER_TICK = 4       -- a read takes this many quests a tick: a whole list at once was 10 ms on a full save
    local CALM_S = 20               -- guest: catches up once this long has passed with nothing going on, and a load long over
    local NEXT_S = 2                -- and the next batch this long after one
    local TAKE_TRIES = 3            -- a step that didn't take is asked this often in all before it's left till a load
    local AGAIN_S = 10              -- and again this long after
    local BATCH = 40                -- table rows applied in one go: the QA tools apply forty without a hitch
    local FRESH_S = 150             -- a host's point heard longer ago than this isn't acted on

    local BITS = { 1, 2, 4, 8 }

    local rows = nil                -- the table as followed, read once: false if it couldn't be, until RETRY_S later
    local RETRY_S = 60
    local rowsFailedAt = -1e9

    -- "MainCh1-NiLiuErShang_1_完成任务, XueRouHua_1_开启任务": quest, branch id (the branch's ID, "1" or "S1"), step.
    local function steps(list)
        local needs = {}
        for entry in list:gsub("，", ","):gmatch("[^,]+") do
            entry = entry:match("^%s*(.-)%s*$")
            local quest, branch, step = entry:match("^(.+)_([^_]+)_([^_]+)$")
            if not quest then
                return nil
            end
            needs[#needs + 1] = { quest = quest, branch = branch, finish = step == FINISH }
        end
        return #needs > 0 and needs or nil
    end

    -- One column of our copy of the table, as text, by row.
    local function column(key)
        local out = {}
        for i, r in ipairs(DATA and DATA.rows or {}) do
            local v = r[key]
            out[i] = v == true and "True" or v or ""
        end
        return out
    end

    -- Which rows are followed. A row with quest steps is followed when the host's world has done all of them; the host only
    -- needs these (two columns, read once, kept as text).
    local function readTable()
        if rows or (rows == false and os.clock() - rowsFailedAt < RETRY_S) then
            return rows
        end
        rows, rowsFailedAt = false, os.clock()
        if not (DATA and DATA.rows and #DATA.rows > 0) then
            log("Story: no story table: each player's story stays their own.")
            return rows
        end
        local quests, optional = column("q"), column("o")
        local out = { count = #DATA.rows, quests = {}, marks = nil, check = #DATA.rows }
        for i = 1, out.count do
            local needs = (quests[i] or "") ~= "" and steps(quests[i])
            if needs then
                out.quests[#out.quests + 1] = { i = i, needs = needs, optional = optional[i] == "True" }
                for b in quests[i]:gmatch(".") do
                    out.check = (out.check * 31 + b:byte()) % 2147483647
                end
            end
        end
        out.optional, out.questText = optional, quests
        rows = out
        return rows
    end

    -- A guest's: the rows without quest steps that only set dialogue marks, world flags, unlocks or a region's map and aren't
    -- optional. They're followed when they lie between the two points. Rows that hand out items, weapons, loot or bells are a
    -- player's own finds, and aren't.
    local function readMarks()
        if rows.marks then
            return rows.marks
        end
        local marks = { column("t"), column("g"), column("m"), column("u") }
        local finds = { column("f"), column("b") }
        local function any(cols, i)
            for _, c in ipairs(cols) do
                if (c[i] or "") ~= "" then
                    return true
                end
            end
            return false
        end
        -- (Never an ending's condition, "结局条件": whether a player has met one is their own play's to say. Followed by
        -- its place in the table, the Soul Cliff's "bloodline awakening" was set on any guest whose host was past it.)
        local function ending(i)
            for _, c in ipairs(marks) do
                if (c[i] or ""):find("结局条件", 1, true) then
                    return true
                end
            end
            return false
        end
        rows.marks = {}
        for i = 1, rows.count do
            if rows.optional[i] ~= "True" and (rows.questText[i] or "") == "" and any(marks, i) and not any(finds, i)
                and not ending(i) then
                rows.marks[#rows.marks + 1] = { i = i }
            end
        end
        log(string.format("Story: %d quest steps and %d marks followed, of %d rows.", #rows.quests, #rows.marks, rows.count))
        return rows.marks
    end

    -- The narrative component, once the game has its quests in: right after a load the list is still being filled.
    local function narrative()
        local nc = FindFirstOf("PBZNarrativeComponent")
        if not valid(nc) then
            return nil
        end
        local ok, loaded = pcall(function() return nc.bCompleteLoad end)
        return (ok and loaded == true) and nc or nil
    end

    -- quest name -> branch ID -> the branch's state: 0 not yet, 1 under way, 2 done. Read a few quests a tick: start with
    -- readQuests(true), then call it each tick until it hands back the states. A finished quest has no current state, so only
    -- branches are read: a call on a missing object is a crash in UE4SS, not a Lua error.
    -- (over: the quests the game calls complete, by name, as of the last read: pastTaking.)
    local reading = nil
    local over = {}
    local function readQuests(start)
        if start then
            local nc = narrative()              -- (found once a read: a search of every object is the dear part)
            reading = nc and { i = 1, states = {}, over = {}, nc = nc } or nil
            return nil
        end
        if reading == nil then
            return nil
        end
        local nc = reading.nc
        local ok, loaded = pcall(function() return valid(nc) and nc.bCompleteLoad end)
        if not (ok and loaded == true) then
            reading = nil                       -- a load came in between: the caller starts again
            return nil
        end
        local list = nc.QuestList
        local n = #list
        for _ = 1, QUESTS_PER_TICK do
            local i = reading.i
            if i > n then
                local states = reading.states
                over = reading.over
                reading = nil
                return states
            end
            reading.i = i + 1
            local q = list[i]
            pcall(function() q = q:get() end)
            if valid(q) then
                local name = q:GetClass():GetFName():ToString():gsub("_C$", "")
                local branches = reading.states[name] or {}
                reading.states[name] = branches
                local okC, complete = pcall(function() return q:IsQuestComplete() end)
                if okC and complete == true then
                    reading.over[name] = true
                end
                local bs = q.Branches
                for j = 1, #bs do
                    local b = bs[j]
                    pcall(function() b = b:get() end)
                    if valid(b) then
                        local ok, st = pcall(function() return b:GetBranchState() end)
                        branches[b.ID:ToString()] = ok and tonumber(st) or 0
                    end
                end
            end
        end
        return nil
    end

    local function rowDone(states, row)
        for _, need in ipairs(row.needs) do
            local q = states[need.quest]
            local st = q and q[need.branch]
            if st == nil or st < (need.finish and 2 or 1) then
                return false
            end
        end
        return true
    end

    -- The quest rows a world has done (by their place among quest rows), and its point: the last one done that isn't optional.
    local function pointOf(states)
        local done, point = {}, 0
        for k, row in ipairs(rows.quests) do
            if rowDone(states, row) then
                done[k] = true
                if not row.optional then
                    point = row.i
                end
            end
        end
        return done, point
    end

    local function encode(done, n)
        local out = {}
        for d = 0, math.ceil(n / 4) - 1 do
            local v = 0
            for b = 1, 4 do
                if done[d * 4 + b] then
                    v = v + BITS[b]
                end
            end
            out[#out + 1] = string.format("%x", v)
        end
        return table.concat(out)
    end

    local function decode(hex, n)
        local done = {}
        for d = 1, #hex do
            local v = tonumber(hex:sub(d, d), 16)
            for b = 1, 4 do
                local k = (d - 1) * 4 + b
                if k <= n and math.floor(v / BITS[b]) % 2 == 1 then
                    done[k] = true
                end
            end
        end
        return done
    end

    local function count(set)
        local n = 0
        for _ in pairs(set) do
            n = n + 1
        end
        return n
    end

    -- (Nor in a talk with an NPC: a story step applied under an open dialogue (both handing in to Yuer at once) finished
    -- what the talk was waiting for, and the talk stayed up with no way out.)
    local function calm(pawn)
        -- (sequenceOn, any sequence: the camera check of inCutscene is for joining fights, a step under a scene that
        -- keeps the camera on the player still finished it. Nor in the prologue: see flowsync.)
        return valid(pawn) and not game.isDead(pawn) and not (game.sequenceOn or game.inCutscene)()
            and not game.bossFightActive() and not (game.inDialogue and game.inDialogue())
            and not (game.inPrologue and game.inPrologue())
    end

    -- "a，b, c" -> { "a", "b", "c" }
    local function split(s)
        local out = {}
        for part in (s or ""):gsub("，", ","):gmatch("[^,]+") do
            part = part:match("^%s*(.-)%s*$")
            if part ~= "" then
                out[#out + 1] = part
            end
        end
        return out
    end

    -- A quest branch's state in this world: 0 not begun (or the quest not here), 1 under way, 2 done.
    local function branchState(nc, quest, branch)
        local state = 0
        pcall(function()
            local list = nc.QuestList
            for i = 1, #list do
                local q = list[i]
                pcall(function() q = q:get() end)
                if valid(q) and q:GetClass():GetFName():ToString() == quest .. "_C" then
                    local bs = q.Branches
                    for j = 1, #bs do
                        local b = bs[j]
                        pcall(function() b = b:get() end)
                        if valid(b) and b.ID:ToString() == branch then
                            state = tonumber(b:GetBranchState()) or 0
                        end
                    end
                    return
                end
            end
        end)
        return state
    end

    -- The flags a branch's own tasks wait for, as text ("xg.营地玉儿.药材1" to 3: Yuer's three herbs, one for each found). A
    -- branch the game finishes itself has them; one finished here with FinishQuestBranch didn't, and what waits on the same
    -- flags never opened: the map said the herbs were in, and Yuer wouldn't take them (a player report on 1.7.1). Her
    -- hand-in reads the flags, not the bag. (A task waiting for a flag to be gone, "Not", is no flag to raise.)
    local function branchFlags(nc, quest, branch)
        local out = {}
        pcall(function()
            local list = nc.QuestList
            for i = 1, #list do
                local q = list[i]
                pcall(function() q = q:get() end)
                if valid(q) and q:GetClass():GetFName():ToString() == quest .. "_C" then
                    local bs = q.Branches
                    for j = 1, #bs do
                        local b = bs[j]
                        pcall(function() b = b:get() end)
                        if valid(b) and b.ID:ToString() == branch then
                            local ts = b.QuestTasks
                            for k = 1, #ts do
                                local t = ts[k]
                                pcall(function() t = t:get() or t end)
                                if valid(t) and t:GetClass():GetFName():ToString() == "BPT_HasTag_C" and t.Not ~= true then
                                    pcall(function()
                                        t.Tags.GameplayTags:ForEach(function(_, g)
                                            out[#out + 1] = g:get().TagName:ToString()
                                        end)
                                    end)
                                end
                            end
                        end
                    end
                    return
                end
            end
        end)
        return out
    end

    -- Those of the flags this world hasn't got, raised: how many were, and the ones whose call failed (tag -> true).
    local function raiseFlags(ep, tags)
        local failed = {}
        if #tags == 0 or not valid(ep) then
            return 0, failed
        end
        local have, n = {}, 0
        pcall(function()
            ep.GlobalTags.GameplayTags:ForEach(function(_, t)
                have[t:get().TagName:ToString()] = true
            end)
        end)
        for _, tag in ipairs(tags) do
            if tag ~= "" and tag ~= "None" and not have[tag] then
                if pcall(function() ep:AddTagsByString(tag) end) then
                    have[tag] = true
                    n = n + 1
                else
                    failed[tag] = true
                end
            end
        end
        return n, failed
    end

    -- A quest's class, by our table's path for it (loaded: a quest this world hasn't begun isn't in memory).
    local classes = {}
    local function questClass(quest)
        local c = classes[quest]
        if valid(c) then
            return c
        end
        local path = DATA and DATA.paths and DATA.paths[quest]
        if not path then
            return nil
        end
        c = StaticFindObject(path)
        if not valid(c) then
            pcall(function() c = LoadAsset(path) end)
        end
        classes[quest] = valid(c) and c or nil
        return classes[quest]
    end

    -- One row, by the game's own calls, as its QA tool's table did it: the quest steps (a branch begun, or finished, begun
    -- first if it wasn't), the tags (bells woken by the story come as "bell." tags), the flow nodes marked done, the UI
    -- shown. Not a row's maps (its "m", rows like 庞镇-地图解锁, "Pangzhen map unlocked"): ActivateAllBellsByMaps on them
    -- rang every bell of the region on arrival, fast travel to all of them and the progression gone (a player report, 11-06).
    -- A bell is the player's to ring, or comes by its own id (b) or tag. What a row hands out (weapons, items, loot) isn't: a player's own finds, and what
    -- the story needs comes with the host's bag. Returns how many of its parts the game took, and how many it was given.
    -- A branch it finishes leaves the flags its tasks wait for in owed (branchFlags), raised after the batch.
    local function applyRow(row, nc, ep, bells, ui, owed)
        local took, tried = 0, 0
        local function try(f)
            tried = tried + 1
            if pcall(f) then
                took = took + 1
            end
        end
        for _, step in ipairs(row.q and steps(row.q) or {}) do
            local cls = questClass(step.quest)
            if cls and nc then
                local branches = { FName(step.branch) }
                local st = branchState(nc, step.quest, step.branch)
                if st < 1 then
                    try(function() nc:BeginQuestAndActiveBranch(cls, branches) end)
                end
                if step.finish and st < 2 then
                    try(function() nc:FinishQuestBranch(cls, branches, true) end)
                    for _, tag in ipairs(branchFlags(nc, step.quest, step.branch)) do
                        owed[#owed + 1] = tag
                    end
                end
            else
                tried = tried + 1
            end
        end
        if valid(ep) then
            for _, tag in ipairs(split(row.t)) do
                try(function() ep:AddTagsByString(tag) end)
            end
            for _, guid in ipairs(split(row.g)) do
                try(function() ep.ExecuteNodeGuid:Add(guid, true) end)
            end
        end
        if valid(bells) then
            for _, id in ipairs(split(row.b)) do
                try(function() bells:ActivateBellByID(FName(id)) end)
            end
        end
        if valid(ui) then
            for _, tag in ipairs(split(row.u)) do
                try(function() ui:ActivateUIVisibilityTag({ TagName = FName(tag) }) end)
            end
        end
        return took, tried
    end

    -- Table rows (by their number) applied with the game's own calls, in order. False if the game took none of it.
    local function applyRows(pawn, list, why)
        local nc = narrative()
        local ep, bells, ui = FindFirstOf("EventPipelineManager"), FindFirstOf("BellManager"), FindFirstOf("UIVisibilityManager")
        if not (nc and DATA and DATA.rows) then
            return false
        end
        local took, tried, owed = 0, 0, {}
        -- (What the rows hand out isn't sent on as found: the partner had it when they did the step.)
        game.granting = true
        for _, i in ipairs(list) do
            local row = DATA.rows[i]
            if row then
                local t, n = applyRow(row, nc, ep, bells, ui, owed)
                took, tried = took + t, tried + n
            end
        end
        raiseFlags(ep, owed)
        game.granting = false
        if tried > 0 and took < tried then
            log(string.format("Story: the game took %d of %d parts of %s.", took, tried, why))
        end
        return took > 0 or tried == 0
    end
    story.applyRows = applyRows

    -- storyjump <to> [from]: the table's rows from..to (from 1) applied here, as a catch-up would: a test save taken to a point
    -- in the story (the game's own QA jump went with its table).
    if game.commands then
        game.commands.storyjump = function(args)
            local to, from = (args or ""):match("^(%d+)%s*(%d*)$")
            to, from = tonumber(to), tonumber(from) or 1
            local _, pawn = api.getPlayer1()
            if not (to and DATA and DATA.rows and valid(pawn)) then
                log("Usage: storyjump <last row> [first row]")
                return
            end
            local list = {}
            for i = from, math.min(to, #DATA.rows) do
                list[#list + 1] = i
            end
            log(string.format("Story jump: rows %d to %d: %s.", from, to, tostring(applyRows(pawn, list, "the story jump"))))
        end
    end

    -- Steps an older mod finished in this world for another player never had their flags raised, and what waits on them
    -- stayed shut for good: the report's own save, Yuer's herbs "in" on the map and her hand-in never offered. Once a load,
    -- the finished steps of a quest still under way here get the flags their tasks wait for, if they're missing. Only steps
    -- the table has, the ones a catch-up or a partner's step could have finished; not a quest that's over, its flags done
    -- with. Called with a read of this world's quests (readQuests).
    -- (A step one of whose flags the game wouldn't take is mended again at the next read of the quests, MEND_TRIES times
    -- in all: marked mended first, a failed call left it short for that load. The review of 339d057.)
    local MEND_TRIES = 3
    local mended, mendedIn, mendTries = {}, nil, {}
    local function mend(states)
        local _, pawn = api.getPlayer1()
        local nc = narrative()
        if not (rows and nc and calm(pawn)) then
            return
        end
        local here = nc:GetAddress()
        if here ~= mendedIn then
            mended, mendedIn, mendTries = {}, here, {}      -- (a load: this world again from its save, or another)
        end
        local owed, owedBy = {}, {}
        for _, row in ipairs(rows.quests) do
            for _, need in ipairs(row.needs) do
                local q = states[need.quest]
                local key = need.quest .. " " .. need.branch
                if need.finish and q and q[need.branch] == 2 and not mended[key] then
                    local underWay = false
                    for _, st in pairs(q) do
                        underWay = underWay or st == 1
                    end
                    if underWay then
                        mended[key], mendTries[key] = true, (mendTries[key] or 0) + 1
                        for _, tag in ipairs(branchFlags(nc, need.quest, need.branch)) do
                            owed[#owed + 1] = tag
                            owedBy[tag] = key
                        end
                    end
                end
            end
        end
        if #owed == 0 then
            return
        end
        game.granting = true
        local n, failed = raiseFlags(FindFirstOf("EventPipelineManager"), owed)
        game.granting = false
        for tag in pairs(failed) do
            local key = owedBy[tag]
            if key and mendTries[key] < MEND_TRIES then
                mended[key] = nil
            end
        end
        if n > 0 then
            log(string.format("Story: %d flag%s of quest steps finished here before put back, for what waits on them.", n,
                n == 1 and "" or "s"))
        end
    end

    ------------------------------------------------------------------ host

    local told, toldAt, lookAt = nil, -1e9, -1e9

    -- A guest's quest steps come the other way too, the ones the host is on: a guest who finished the quest both have under
    -- way (the bow in the tower, early in Xigu) left the host to do it all over again. Only a quest the host's world has
    -- started: a guest who is further on doesn't take the host's story past its point, the host's world decides that.
    -- The step's things came already, as everything the game gives does; the game's own step that follows here gives
    -- nothing twice that can't be had twice (a weapon, an accessory).
    local guestDone = {}            -- who (0 for a lone guest) -> { done, at }
    local hostTried = {}            -- quest rows applied here for a guest this session: not tried again
    -- A row the host is on: each step it needs is a branch under way in the host's world (or done there already). A branch
    -- the host hasn't started isn't taken: by quest alone, a guest further on took the host through the whole quest, and
    -- into a branch its world didn't choose.
    local function questStarted(states, row)
        for _, need in ipairs(row.needs) do
            local st = (states[need.quest] or {})[need.branch]
            if not st or st < 1 then
                return false
            end
        end
        return true
    end
    local function takeGuestSteps(states, done, now)
        local _, pawn = api.getPlayer1()
        if not (story.follow and calm(pawn)) then
            return
        end
        local list, ks = {}, {}
        for k, row in ipairs(rows.quests) do
            if not done[k] and not hostTried[k] and questStarted(states, row) then
                for _, g in pairs(guestDone) do
                    if g.done[k] and now - g.at < FRESH_S and #list < BATCH then
                        list[#list + 1], ks[#ks + 1] = row.i, k
                        break
                    end
                end
            end
        end
        if #list == 0 then
            return
        end
        if applyRows(pawn, list, "a guest's story steps") then
            for _, k in ipairs(ks) do
                hostTried[k] = true         -- (only once the game took them: a failed look tries again)
            end
            log(string.format("Story: a guest finished %d step%s of quests you're on: done here too (rows %d to %d).", #list,
                #list == 1 and "" or "s", list[1], list[#list]))
            if api.status and api.status.notify then
                api.status.notify("story", "your partner finished a quest step you were on: done for you too.")
            end
            lookAt = -1e9           -- (read again: the point moved, and the guests hear it)
        end
    end

    coop.handlers.GSTORY = function(rest, from)
        -- A guest loaded another save: where they stand now is their new start. Kept, a guest who loaded a finished save
        -- while linked had every row past their first one counted as done together, and the host's quests finished by it.
        if coop.isHost() and rest == "reset" then
            -- (Rebased at their next report, keeping what they'd done while linked that the host hasn't taken yet: a
            -- respawn or a trip right after a step loads too, and forgotten, that step never reached the host.)
            local g = guestDone[from or 0]
            if g then
                g.rebase = true
            end
            return
        end
        if not coop.isHost() or type(rest) ~= "string" or #rest > 400 or not readTable() then
            return
        end
        local n, check, hex = rest:match("^(%d+) (%d+) (%x+)$")
        if n and tonumber(n) == #rows.quests and tonumber(check) == rows.check then
            -- Only steps the guest finishes while linked: the first report is where they stood, and counts for nothing.
            -- A guest far ahead (a finished NG+ save) otherwise finished a newcomer host's quests for them on joining.
            -- (The bow in the tower, done together, still counts: the user's rule, the host gives and the guest
            -- doesn't.)
            local all = decode(hex, #rows.quests)
            local g = guestDone[from or 0]
            if not g then
                g = { base = all, done = {} }
                guestDone[from or 0] = g
            end
            if g.rebase then
                g.rebase = nil
                local base = {}
                for k in pairs(all) do
                    if not g.done[k] then
                        base[k] = true
                    end
                end
                g.base = base
            end
            g.done, g.at = {}, os.clock()
            for k in pairs(all) do
                if not g.base[k] then
                    g.done[k] = true
                end
            end
            lookAt = math.min(lookAt, os.clock() - LOOK_S + 2)  -- (a look soon: there may be something to take)
        end
    end

    local function hostTick(now)
        if not coop.linked() then
            reading = nil
            guestDone = {}          -- (a guest's steps go with them: one who left, or the next who comes, isn't them)
            return
        end
        if reading == nil and now - lookAt >= LOOK_S and readTable() then
            lookAt = now
            readQuests(true)
            return
        end
        local states = readQuests()
        if states then
            local done, point = pointOf(states)
            local line = string.format("%d %d %d %s", #rows.quests, rows.check, point, encode(done, #rows.quests))
            if line ~= told then
                log(string.format("Story: your point is row %d, %d of %d quest steps done: guests behind it catch up.",
                    point, count(done), #rows.quests))
                told, toldAt = line, -1e9
            end
            takeGuestSteps(states, done, now)
            mend(states)
        end
        if told and now - toldAt >= TELL_S then
            toldAt = now
            coop.sendEvent("STORYPT", told)
        end
    end

    -- Someone (re)started sync: they hear the point at once.
    local syncStarted = coop.handlers.S
    coop.handlers.S = function(rest, from)
        syncStarted(rest, from)
        lookAt, toldAt = -1e9, -1e9
        guestDone[from or 0] = nil      -- (whoever starts sync anew tells their steps anew)
    end

    ------------------------------------------------------------------ guest

    local host = nil                -- { done, point, at, line, check }: the host's point as last heard; check = look again
    local calmSince, calmBody = nil, nil
    local waitUntil = 0
    local tried = {}                -- quest rows applied and not seen done: not tried again (one that didn't take TAKE_TRIES times: till a load)
    local misses = {}               -- quest row -> the times it was applied and didn't take
    local marked = {}               -- mark rows applied this session
    local batch = nil               -- quest rows of the last batch, checked on the next read
    -- Catching up now (a batch of the host's steps applied, not yet read back): flowsync waits, so a flag doesn't land in
    -- the middle of the steps it follows.
    function story.isBusy()
        return batch ~= nil
    end
    local caught, warned = 0, false
    -- The host started sync anew (another host, maybe): its old point isn't caught up to before the new one's comes.
    local guestSyncStarted = coop.handlers.S
    coop.handlers.S = function(rest, from)
        guestSyncStarted(rest, from)
        if not coop.isHost() and from == nil then
            host, tried, marked, misses = nil, {}, {}, {}
        end
    end

    coop.handlers.STORYPT = function(rest, from)
        -- (from: another guest's, passed on by the relay: only the host's point is caught up to, into this save for good.)
        if from ~= nil or coop.isHost() or type(rest) ~= "string" or #rest > 400 then
            return
        end
        local n, check, point, hex = rest:match("^(%d+) (%d+) (%d+) (%x+)$")
        if not (n and readTable()) then
            return
        end
        if tonumber(n) ~= #rows.quests or tonumber(check) ~= rows.check then
            if not warned then
                warned = true
                story.mismatch = true       -- (flowsync takes nothing either)
                log("Story: the host's game has another story table (another game version?): your story stays your own.")
            end
            return
        end
        if host and host.line == rest then
            host.at = os.clock()
            return
        end
        host = { done = decode(hex, #rows.quests), point = tonumber(point), at = os.clock(), line = rest, check = true }
    end

    -- A guest's own steps, for the host (GSTORY): when they change, and every TELL_S.
    local ownTold, ownToldAt, ownLookAt, ownReading = nil, -1e9, -1e9, false
    local function tellOwn(states, now)
        local done = pointOf(states)
        local line = string.format("%d %d %s", #rows.quests, rows.check, encode(done, #rows.quests))
        if line ~= ownTold or now - ownToldAt >= TELL_S then
            ownTold, ownToldAt = line, now
            coop.sendEvent("GSTORY", line)
        end
    end

    -- What a catch-up would apply now, in table order: { i (the table row), k (its place among quest rows) or mark }.
    -- A step of the other side of a choice this world made: a branch "4-A" when this world took "4-B". (Only lettered
    -- pairs are choices: the numbered and S branches are steps of one path, all of them done in a normal run.)
    local function otherChoice(states, row)
        for _, need in ipairs(row.needs) do
            local stem, letter = need.branch:match("^(.+)%-(%a)$")
            local q = stem and states and states[need.quest]
            if q and (q[need.branch] or 0) < 1 then
                for b, st in pairs(q) do
                    local s2, l2 = b:match("^(.+)%-(%a)$")
                    if s2 == stem and l2 ~= letter and st >= 1 then
                        return true
                    end
                end
            end
        end
        return false
    end

    -- A step this world can't take any more: every branch it's short of is a quest's that's over here, and the game
    -- changes no branch of a quest that's over (on the bench: begun and finished by hand, a side branch stood as it
    -- was). A side branch can be left under way so: the flag that ends its quest came by the story flow before the
    -- table's row did. On the bench, 11-17, "meet Xiong Zhang again" stood so on a guest, and its row was applied at
    -- every load from then on, never took, and the player was told "your story caught up with the host's: 1 step" each
    -- time.
    local function pastTaking(states, row)
        if not states then
            return false
        end
        for _, need in ipairs(row.needs) do
            local st = (states[need.quest] or {})[need.branch]
            if (st == nil or st < (need.finish and 2 or 1)) and not over[need.quest] then
                return false
            end
        end
        return true
    end

    local function todoFor(done, point, states)
        local todo = {}
        for k, row in ipairs(rows.quests) do
            if host.done[k] and not done[k] and not tried[k] and not otherChoice(states, row)
                and not pastTaking(states, row) then
                todo[#todo + 1] = { i = row.i, k = k }
            end
        end
        for _, row in ipairs(readMarks()) do
            if row.i > point and row.i < host.point and not marked[row.i] then
                todo[#todo + 1] = { i = row.i, mark = true }
            end
        end
        table.sort(todo, function(a, b) return a.i < b.i end)
        return todo
    end

    local function caughtUp()
        host.check = false
        if caught > 0 then
            log(string.format("Story: caught up with the host's (%d table rows).", caught))
            if api.status and api.status.notify then
                api.status.notify("story", string.format("your story caught up with the host's: %d step%s.", caught,
                    caught == 1 and "" or "s"))
            end
            caught = 0
        end
    end

    local function guestTick(now)
        local _, pawn = api.getPlayer1()
        local body = valid(pawn) and pawn:GetAddress() or nil
        if body ~= calmBody then
            calmBody, calmSince, reading, batch = body, nil, nil, nil
            if host and body then
                host.check = true                   -- a load: this world may be another save's
                tried, marked, misses = {}, {}, {}
            end
            if body and coop.linked() then
                coop.sendEvent("GSTORY", "reset")   -- (and for the host: its count of what this player did starts over)
            end
        end
        if not (story.follow and host and host.check and now - host.at < FRESH_S and coop.linked() and calm(pawn)) then
            -- (Calm is the player's: kept while nothing goes on, whether or not there's anything to take, so a new point
            -- heard after a quiet while is taken at once instead of after another 20 s.)
            calmSince = calm(pawn) and (calmSince or now) or nil
            -- Not catching up: this world's own steps are read now and then all the same, for the host.
            if story.follow and coop.linked() and calm(pawn) and readTable() then
                if not ownReading and now - ownLookAt >= LOOK_S then
                    ownLookAt, ownReading = now, true
                    readQuests(true)
                elseif ownReading then
                    local states = readQuests()
                    if states then
                        ownReading = false
                        tellOwn(states, now)
                        mend(states)
                    elseif reading == nil then
                        ownReading = false          -- (a load came in between)
                    end
                end
            else
                reading, ownReading = nil, false
            end
            return
        end
        ownReading = false
        calmSince = calmSince or now
        if now - calmSince < CALM_S or now < waitUntil then
            return
        end
        if reading == nil then
            readQuests(true)
            return
        end
        local states = readQuests()
        if not states then
            return
        end
        local done, point = pointOf(states)
        tellOwn(states, now)
        mend(states)
        if batch then
            -- (One that didn't take is asked again, AGAIN_S on, TAKE_TRIES times in all, and only then left as it is. On a
            -- PC out of breath, two copies of the game and four other jobs in 24 GB, five side-quest steps of the Crimson
            -- Forest didn't take at their one asking and stayed undone till the next load: the game's calls went
            -- through, and the steps weren't done two seconds on, or ever. With the PC to itself they all took.)
            local missed, again = 0, 0
            for _, k in ipairs(batch) do
                if done[k] then
                    tried[k], misses[k] = nil, nil
                else
                    misses[k] = (misses[k] or 0) + 1
                    if misses[k] < TAKE_TRIES then
                        tried[k] = nil
                        again = again + 1
                    else
                        missed = missed + 1
                    end
                end
            end
            caught = math.max(0, caught - missed - again)   -- (not caught up to: nothing to tell the player of)
            if missed > 0 then
                log(string.format("Story: %d of the host's story steps didn't take here: left as they are.", missed))
            end
            batch = nil
            if again > 0 then
                log(string.format("Story: %d of the host's story steps %s taken here yet: asked again in %d s.", again,
                    again == 1 and "hasn't" or "haven't", AGAIN_S))
                waitUntil = now + AGAIN_S
                reading = nil
                return
            end
        end
        local todo = todoFor(done, point, states)
        if #todo == 0 then
            caughtUp()
            return
        end
        local names = {}
        batch = {}
        -- (No more than 6 quests to load from disk in one go: each is a load on the game thread, and forty at once for a
        -- guest far behind could stall the game as they joined.)
        local loads, seenQuest = 0, {}
        for n = 1, math.min(BATCH, #todo) do
            local row = DATA.rows[todo[n].i]
            local q = row and row.q
            if type(q) == "string" and q ~= "" and not seenQuest[q] and not valid(classes[q]) then
                seenQuest[q] = true
                loads = loads + 1
                if loads > 6 and n > 1 then
                    break
                end
            end
            names[#names + 1] = todo[n].i
            if todo[n].mark then
                marked[todo[n].i] = true
            else
                tried[todo[n].k] = true          -- (cleared at the next read once it took)
                batch[#batch + 1] = todo[n].k
            end
        end
        local took = os.clock()
        if not applyRows(pawn, names, "the host's story steps") then
            log("Story: the game wouldn't take the host's story steps.")
            host.check, batch = false, nil
            return
        end
        caught = caught + #names
        log(string.format("Story: %d of the host's story rows applied here (rows %d to %d, %.0f ms).", #names, todo[1].i,
            todo[#names].i, (os.clock() - took) * 1000))
        waitUntil = now + NEXT_S
    end

    -- Every tick while a read is under way, else once a second.
    local nextTick = 0
    coop.extraTicks.story = function()
        local now = os.clock()
        if reading == nil and now < nextTick then
            return
        end
        nextTick = now + 1
        if coop.isHost() then
            hostTick(now)
        else
            guestTick(now)
        end
    end

    ------------------------------------------------------------------ scenes

    -- A scene the host's world plays as a fight ends or turns to its next phase plays in the guest's world too, from the
    -- game's own flow: the guest's copy of the boss dies the whole way (coop.lua). The host skipping it skips the same scene
    -- here, one that only starts a moment later included, so the two go on together. SCENE skip <sequence name>.
    local SCENE_S = 0.25
    local SKIPPED_S = 3                 -- a scene that ended this much before its length was skipped (its start can be seen up to
                                        -- 2 s late after a load, and a scene watched to its end mustn't read as skipped)
    local LATE_S = 10                   -- a skip still ends our scene that starts this long after it
    local mine, mineAt, mineLength = nil, 0, nil
    local nextScene = 0
    local hostSkipped = {}              -- sequence name -> when the host skipped it
    local ended = nil                   -- our scene already ended for the host's
    -- A bell's own scene (the crane bell's first ring: OnFirstTouchBell, then Seqs003-Seqs008-Seq038 5 s on, on the bench,
    -- 11-12) is each player's own: it plays for whoever rings that bell. It plays 18 s of a 213 s sequence, so the host's,
    -- watched to its end, read as skipped and was told: the guest's own scene of that bell, a moment behind, was cut
    -- (point 3 of a report on 1.7.1). A scene that begins within BELL_SCENE_S of this player's own first touch of a bell
    -- (game.firstTouchAt, before or after it) is that bell's, for as long as it plays: its skip isn't told, and a host's
    -- skip of it isn't taken. (Not a sit's: a boss's scene in the arena beside a bell came within seconds of one.)
    local BELL_SCENE_S = 10
    local touchHookAt = 0
    local function bellScene(startedAt)
        local at = game.firstTouchAt
        return at ~= nil and startedAt ~= nil and math.abs(startedAt - at) <= BELL_SCENE_S
    end
    local theirs, theirsAt = nil, 0     -- guest: the scene playing here and when it began

    -- Watching together. The user, 11-18: "why don't you make the scene for both play at the same time ... if they
    -- were both in the same place of the boss. like a synced movie people want to watch together and react together".
    -- Each world's game starts a place's scene as its own player stands in the story's box for it, so two players a
    -- few paces apart had it seconds apart, and one standing back had it only when they walked on, the other's fight
    -- begun by then. A scene that begins here is told with where this player stood just before it (SCENE on <name>
    -- <x> <y> <z> <map>: the scene itself moves its player). A partner within NEAR_CM of that spot, on that map,
    -- whose world plays nothing a moment later and has the story's box within BOX_CM of the spot, is set down in that
    -- box, for its own game to begin the same scene: once a scene, and not one its world has played since the game
    -- started. No box there, the world has had that scene, and nobody is moved. The one begun later then plays a
    -- little faster till both are at the same moment of it (SCENE at <name> <seconds>, a second apart).
    -- WatchTogether = Off in PhantomPact.ini keeps each player's scenes their own (story.together).
    -- (One table: this function's locals are for its story.)
    local tog = {
        NEAR_CM = 3000,                 -- "the same place": as near as a bell counts as stood by (flowsync.lua)
        BOX_CM = 1500,                  -- the story's box for it is looked for this near the spot told (the scene comes
                                        -- some 2 s after its box is stood in: a run's 12 m past it at most)
        JOIN_AFTER_S = 0.5,             -- a partner's scene told this long ago, and none here: set down in its box
        JOIN_WITHIN_S = 6,              -- and not one told longer ago than this
        AT_S = 1.0,                     -- where this world's scene is, told this often
        BEHIND_S = 0.3,                 -- this far behind the partner's, a scene is played faster
        CAUGHT_S = 0.1,                 -- till it's this near
        FASTEST = 1.5, LEAST = 1.15,    -- as fast as that at most, and by this much at least while it's behind (its last
                                        -- third of a second in two, not creeping up on it)
        last = nil, toldAt = 0,         -- this world's scene as last looked at, and when its place was last told
        stood = nil,                    -- where this player stood at the last look with no scene playing
        on = nil,                       -- a partner's scene as it began: { name, x, y, z, map, at }
        at = nil,                       -- and where it was when last told: { name, pos, at }
        joined = {}, played = {},       -- scene name -> true: this player was set down for it; this world played it
        fast = nil, gained = 0,         -- the scene played faster here now, and the seconds of it gained that way
        bell = nil,                     -- a partner's first ring of a bell: { bx, by, bz, x, y, z, map, at }
        bellTold = nil, rungFor = nil,  -- this player's own first ring as last told; when this world's was rung for a partner's
    }
    story.together = true

    local function mapWord()
        local net = coop.net
        return (tostring(net and net.localMap or "?"):gsub("%s", "_"))
    end

    coop.handlers.SCENE = function(rest, from)
        if type(rest) ~= "string" or #rest > 200 then
            return
        end
        local name = rest:match("^skip (%S+)$")
        if name then
            if from == nil and not coop.isHost() then       -- (the host's word alone)
                hostSkipped[name] = os.clock()
            end
            return
        end
        local on, x, y, z, map = rest:match("^on (%S+) (%S+) (%S+) (%S+) (%S+)$")
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        if on and x and y and z and math.abs(x) < 1e7 and math.abs(y) < 1e7 and math.abs(z) < 1e7 then
            tog.on = { name = on, x = x, y = y, z = z, map = map, at = os.clock() }
            return
        end
        local at, pos = rest:match("^at (%S+) (%S+)$")
        pos = tonumber(pos)
        if at and pos and pos >= 0 and pos < 7200 then
            tog.at = { name = at, pos = pos, at = os.clock() }
        end
    end

    -- This world's scene, told as it begins and a second apart while it plays.
    local function tellScene(now, name)
        local _, pawn = api.getPlayer1()
        if not name then
            if valid(pawn) then
                local l = pawn:K2_GetActorLocation()
                tog.stood = { X = l.X, Y = l.Y, Z = l.Z }
            end
        end
        if name ~= tog.last then
            tog.last, tog.fast, tog.gained = name, nil, 0
            if name then
                tog.played[name] = true
                local net = coop.net
                local l = tog.stood or (valid(pawn) and pawn:K2_GetActorLocation()) or nil
                if l and net and net.enabled and not net.pvp and not net.arena then
                    coop.sendEvent("SCENE", "on", name, string.format("%.0f %.0f %.0f", l.X, l.Y, l.Z), mapWord())
                end
                tog.toldAt = now
            end
        elseif name and now - tog.toldAt >= tog.AT_S then
            tog.toldAt = now
            local pos = game.scenePos and game.scenePos()
            if pos then
                coop.sendEvent("SCENE", "at", name, string.format("%.2f", pos))
            end
        end
    end

    -- Whether this player can be set down for a partner's scene now: up, in nothing of their own.
    local function mayJoin(controller, pawn)
        local net = coop.net
        if not (net and net.enabled and valid(pawn)) or game.isDead(pawn) or net.pvp or net.arena then
            return false
        end
        if (game.inDialogue and game.inDialogue()) or (api.qte and api.qte.active)
            or (game.inPrologue and game.inPrologue()) or (net.ownBosses and #net.ownBosses() > 0) then
            return false
        end
        local busy = false
        pcall(function()
            busy = api.gs():IsGamePaused(controller) == true
                or (api.localcoop ~= nil and (api.localcoop.bellMenuUp() or api.localcoop.screenUp()))
        end)
        return not busy
    end

    -- A partner's scene began beside this player and none plays here: set down in the story's box for it.
    local function joinScene(now, name)
        local s = tog.on
        if not s then
            return
        end
        if now - s.at > tog.JOIN_WITHIN_S then
            tog.on = nil
            return
        end
        if name or now - s.at < tog.JOIN_AFTER_S or story.together == false or tog.joined[s.name] or tog.played[s.name]
            or s.map ~= mapWord() or not game.storyBox then
            return
        end
        -- (A bell's own scene, this world's bell rung a moment ago for the partner's ring, joinBell: it comes by itself.)
        if tog.rungFor and now - tog.rungFor <= BELL_SCENE_S then
            return
        end
        local controller, pawn = api.getPlayer1()
        if not mayJoin(controller, pawn) then
            return
        end
        local l = pawn:K2_GetActorLocation()
        local d = math.sqrt((l.X - s.x) ^ 2 + (l.Y - s.y) ^ 2 + (l.Z - s.z) ^ 2)
        if d > tog.NEAR_CM then
            return
        end
        tog.on = nil                    -- (looked for once a scene: the boxes are a whole map's)
        local box = game.storyBox(s.x, s.y, s.z, tog.BOX_CM)
        if not box then
            log("Your partner's scene " .. s.name .. " began beside you: this world has no story box for it there (played before?), nothing done.")
            return
        end
        tog.joined[s.name] = true
        pawn:K2_SetActorLocation({ X = box.X, Y = box.Y, Z = box.Z + 60 }, false, {}, true)
        log(string.format("Your partner's scene %s began %.0f m from you: set down in the story's box for it, for this world's own to begin too.",
            s.name, d / 100))
    end

    -- This world's scene, behind the partner's same one: a little faster till it's where theirs is.
    local function keepPace(now, name)
        local a = tog.at
        local same = name ~= nil and a ~= nil and a.name == name and now - a.at <= 2.5 and story.together ~= false
            and game.scenePos ~= nil and game.sceneRate ~= nil and not (api.qte and api.qte.active)
        local pos = same and game.scenePos() or nil
        local behind = pos and a.pos + (now - a.at) - pos or 0
        if pos and behind > (tog.fast and tog.CAUGHT_S or tog.BEHIND_S) then
            local rate = math.max(tog.LEAST, math.min(tog.FASTEST, 1 + behind / 2))
            if game.sceneRate(rate) then
                if not tog.fast then
                    log(string.format("Scene %s is %.1f s behind your partner's: played a little faster till it's where theirs is.",
                        name, behind))
                end
                tog.fast = name
                tog.gained = tog.gained + (rate - 1) * SCENE_S
            end
        elseif tog.fast then
            if tog.fast == name and game.sceneRate then
                game.sceneRate(1)
                if pos then
                    log("Scene " .. name .. " is where your partner's is now.")
                end
            end
            tog.fast = nil
        end
    end

    -- A bell together. The user, 11-18: "the same goes for bell if they are near to each other ... if the guest
    -- presses it then also register for host if they are near each other ... same goes vise versa". This player's
    -- first ring of a bell is told with where the bell stands and where they stood (BELL ring <bell x y z> <x y z>
    -- <map>). A partner within NEAR_CM of that bell, on that map, in nothing of their own, whose world hasn't that bell
    -- woken, is set down a pace behind the ringer and their world's bell is rung for them as E rings it (game.bellAt):
    -- its first ring there too, the game's own, with its flags, its save and, at a crane bell, its scene, a moment
    -- after the ringer's and kept with it (keepPace). The host's world too: a bell rung there, not lit by word, has its
    -- first ring's flags and flow steps. One further off keeps the bell for their own first ring, as before
    -- (flowsync.lua).
    coop.handlers.BELL = function(rest)
        if type(rest) ~= "string" or #rest > 200 then
            return
        end
        local bx, by, bz, x, y, z, map = rest:match("^ring (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
        bx, by, bz, x, y, z = tonumber(bx), tonumber(by), tonumber(bz), tonumber(x), tonumber(y), tonumber(z)
        if bx and by and bz and x and y and z and math.max(math.abs(bx), math.abs(by), math.abs(bz), math.abs(x),
            math.abs(y), math.abs(z)) < 1e7 then
            tog.bell = { bx = bx, by = by, bz = bz, x = x, y = y, z = z, map = map, at = os.clock() }
        end
    end

    local function tellBell(now)
        local b = game.firstTouch and game.firstTouch.bell
        if not b or b.at == tog.bellTold then
            return
        end
        tog.bellTold = b.at
        -- (Not this world's ring made a moment ago for a partner's: theirs is told already.)
        if tog.rungFor and now - tog.rungFor <= BELL_SCENE_S then
            return
        end
        local _, pawn = api.getPlayer1()
        local net = coop.net
        if valid(pawn) and net and net.enabled and not net.pvp and not net.arena then
            local l = pawn:K2_GetActorLocation()
            coop.sendEvent("BELL", "ring", string.format("%.0f %.0f %.0f", b.X, b.Y, b.Z),
                string.format("%.0f %.0f %.0f", l.X, l.Y, l.Z), mapWord())
        end
    end

    local function joinBell(now, name)
        local b = tog.bell
        if not b then
            return
        end
        if now - b.at > tog.JOIN_WITHIN_S then
            tog.bell = nil
            return
        end
        if name or story.together == false or b.map ~= mapWord() or not game.bellAt then
            return
        end
        local controller, pawn = api.getPlayer1()
        if not mayJoin(controller, pawn) then
            return
        end
        tog.bell = nil
        local l = pawn:K2_GetActorLocation()
        local d = math.sqrt((l.X - b.bx) ^ 2 + (l.Y - b.by) ^ 2 + (l.Z - b.bz) ^ 2)
        if d > tog.NEAR_CM or game.bellAt(b.bx, b.by, b.bz) ~= "asleep" then
            return
        end
        -- (A pace behind where the ringer stands: their figure is at the bell. The bell's own walk up does the rest.)
        local dx, dy = b.x - b.bx, b.y - b.by
        local n = math.sqrt(dx * dx + dy * dy)
        if d > 400 and n > 1 then
            pawn:K2_SetActorLocation({ X = b.x + dx / n * 120, Y = b.y + dy / n * 120, Z = b.z }, false, {}, true)
        end
        if game.bellAt(b.bx, b.by, b.bz, pawn) == "rung" then
            tog.rungFor = now
            log(string.format("Your partner rang a bell %.0f m from you for the first time: rung in this world too, its first ring here.",
                d / 100))
        end
    end

    coop.extraTicks.scenes = function()
        local now = os.clock()
        if now < nextScene then
            return
        end
        nextScene = now + SCENE_S
        if now >= touchHookAt and game.hookFirstTouch then
            touchHookAt = now + 5
            if game.hookFirstTouch() then
                touchHookAt = math.huge         -- (hooked: once a game run)
            end
        end
        local name = game.sceneName()
        -- (What this world's last scene gained by playing faster, keepPace: it ended that much early, and that's no skip.)
        local gained = tog.gained
        tellScene(now, name)
        tellBell(now)
        joinScene(now, name)
        joinBell(now, name)
        keepPace(now, name)
        if coop.isHost() then
            if name ~= mine then
                if mine and mineLength and now - mineAt < mineLength - SKIPPED_S - gained
                    and not (game.inDialogue and game.inDialogue()) then
                    if bellScene(mineAt) then
                        log("Scene " .. mine .. " came with this player's own first ring of a bell: its end isn't told as a skip.")
                    else
                        coop.sendEvent("SCENE", "skip", mine)
                        log(string.format("Scene %s skipped after %.1f of %.1f s: the guest's too.", mine, now - mineAt,
                            mineLength))
                    end
                end
                mine, mineAt, mineLength = name, now, name and game.sceneLength()
            elseif mine and not mineLength then
                mineLength = game.sceneLength()       -- (its player can come a moment after the scene does)
            end
            return
        end
        if name ~= theirs then
            theirs, theirsAt = name, now
        end
        if not name then
            ended = nil
            return
        end
        local t = coop.net.target
        -- (Not while a QTE runs here: the host passing its own QTE ended its scene early, and the guest's same scene was sent
        -- to its end in the middle of theirs, leaving them stuck in it: 沐小葵's third phase, a Nexus report on 1.6.6.)
        if name ~= ended and not bellScene(theirsAt) and hostSkipped[name] and now - hostSkipped[name] <= LATE_S and t
            and t.Map == coop.net.localMap
            and not (game.inDialogue and game.inDialogue()) and not (api.qte and api.qte.active) and game.skipScene() then
            ended = name                        -- (until it takes: the scene's player can be found a moment after it starts)
            log("The host skipped " .. name .. ": skipped here too.")
        end
    end

    -- For tests and the eval command. point(): this world's point as the host would tell it, read all at once.
    function story.point()
        if not (readTable() and narrative()) then
            return nil
        end
        local saved = reading
        readQuests(true)
        local states
        repeat
            states = readQuests()
        until states or reading == nil
        reading = saved
        if not states then
            return nil
        end
        local done, point = pointOf(states)
        return point, count(done), encode(done, #rows.quests)
    end

    -- plan(): the table rows a catch-up would apply now, in order, as one text.
    function story.plan()
        if not (host and story.point()) then
            return "no host point"
        end
        local saved = reading
        readQuests(true)
        local states
        repeat
            states = readQuests()
        until states or reading == nil
        reading = saved
        local done, point = pointOf(states or {})
        local out = {}
        for _, t in ipairs(todoFor(done, point)) do
            out[#out + 1] = t.i .. (t.mark and "m" or "")
        end
        return "host " .. host.point .. ", here " .. point .. ": " .. table.concat(out, " ")
    end

    return story
end
