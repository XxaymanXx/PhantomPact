-- Co-op difficulty, Elden Ring style: while your partner is with you, enemies and bosses get more health and
-- posture (PhantomPact.ini CoopEnemyHealth / CoopEnemyPosture, in percent; 100 = off).
--
-- Both players' games scale the same enemies by the same factor, so the host's numbers (which the guest's copies
-- follow down) and the guest's own copies stay in step. Each enemy is scaled once, keeping its current share of
-- health; enemies that respawn (bell rest) are new actors and get scaled again. The guest's copies then take the host's
-- maximum anyway (coop.lua).
--
-- With 4 PLAYERS on, each person connected adds what the first did, wherever they are: another map, loading or down all count.
-- At the default 150 and 130 that's 200 and 160 with two connected, 250 and 190 with three (EXACG's numbers, PR #11), and 100
-- stays 100. An enemy only goes up: scaled again on the host when someone connects, where the guests' copies follow. It doesn't
-- go back down when someone leaves, or a boss would lose health as a player dropped out. New enemies get the number of the
-- moment. Someone who joins during a boss fight only watches, so that boss keeps its number until the fight is over.
-- It stops at four players (250 and 190): with five or six every enemy has a ghost twin instead (twins.lua), which is harder
-- enough. scaling.players() is how many are connected, for twins.lua.
--
-- Boss poise (CoopBossPoise, percent, 100 = off): posture above is the bar that opens an execution; being knocked out of
-- an attack is the game's other number, poise. Each hit takes poise off the move the boss is doing, and when it's gone the
-- move breaks. A boss here takes 100/CoopBossPoise of the poise damage (its TakenReductionMultiplier_Poise, 1 by default),
-- so at 200 it takes twice the hits to stagger out of a move. Bosses only, the same with any number of players, and only
-- while someone is with you, like the rest. Each PC sets its own: the host's bosses and each guest's copies.
--
-- Bosses' own health and posture (CoopBossHealth / CoopBossPosture, left out: CoopEnemyHealth / CoopEnemyPosture as
-- before), and how hard enemies and bosses hit (CoopEnemyDamage / CoopBossDamage, percent, 100 = off): a player report on
-- 1.6.9, "options to customize the boss's damage, as well as the mobs' health, posture, and damage". The damage is each
-- enemy's own multipliers of what it deals (scaleHits: its Attack made no difference on the bench), once a body and again
-- when the game sets them again (a difficulty switch), never on top of itself. Each PC sets its own: what its own player
-- takes, from its own enemies or its copies of the host's. Not with more players: the damage stays the same however many
-- are connected.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local net = api.coop.net

    local scaling = {
        health = 1.5,       -- CoopEnemyHealth / 100
        posture = 1.3,      -- CoopEnemyPosture / 100
        bossPoise = 2.0,    -- CoopBossPoise / 100
        bossArmor = false,  -- CoopBossArmor = On (the ini ships it On; left out, the game's own flinches)
        bossHealth = nil,   -- CoopBossHealth / 100, or nil: health
        bossPosture = nil,  -- CoopBossPosture / 100, or nil: posture
        damage = 1.0,       -- CoopEnemyDamage / 100
        bossDamage = 1.0,   -- CoopBossDamage / 100
        hitsSeen = nil,     -- { damage, bossDamage } as tick last saw them
        hitsBack = 0,       -- passes still to look at every body's hits after those changed (tick)
    }

    -- This enemy's health and posture numbers: a boss's own, where it has them, and whether they're a boss's. (The boss
    -- question only when they differ.)
    local function numbersFor(e, addr)
        if (scaling.bossHealth or scaling.bossPosture) and game.isBoss(e, addr) then
            return scaling.bossHealth or scaling.health, scaling.bossPosture or scaling.posture, true
        end
        return scaling.health, scaling.posture, false
    end
    local scaledAs = {}             -- enemy address -> { name, h, p, boss, players }: the numbers its scaling took

    local PASS_S = 1.0              -- a look over the enemies starts this often while the partner is here
    local LOOKS_PER_TICK = 16       -- enemies looked at per tick, and at most one scaled: that takes about 25 calls through
                                    -- UE4SS, and all those near a new player scaled in one frame was a 23 ms frame

    local scaled = {}               -- enemy address -> its name once scaled (an address comes back for a new actor, after a
                                    -- map change or a respawn, and that one wasn't scaled yet)
    local scaledFor = {}            -- more than two players: enemy address -> how many it's been scaled for
    local soloFights = {}           -- a boss's address -> true: its fight began with nobody else here, so whoever joins only
                                    -- watches it, and it keeps its number until that's over

    local function scaleAttr(set, name, maxName, factor)
        pcall(function()
            local mx, cur = set[maxName], set[name]
            local share = (mx.CurrentValue > 0) and (cur.CurrentValue / mx.CurrentValue) or 1
            local newMax = mx.CurrentValue * factor
            mx.BaseValue = newMax
            mx.CurrentValue = newMax
            cur.BaseValue = newMax * share
            cur.CurrentValue = newMax * share
        end)
    end

    -- Whether this is the actor scaled at that address: same name, and still the most health it was given. A placed enemy
    -- coming back (a rest, streaming in again) is a new actor with the old name, often on the old address, at base health:
    -- by name alone it was taken for done and fought at 100%.
    local scaledMax = {}            -- enemy address -> what it was scaled to: the most health on a host, posture on a guest
    -- (The host goes by health, a guest by posture: a guest's copies take the host's Health_Max, which isn't theirs to judge
    -- by, and nobody sets the most of their posture but this file. With no test of its own a guest took the new body on an
    -- old address for the one it had scaled, at every respawn of its own: its posture stood at the base's from then on, and
    -- one its game then ran for the host fought at the base's health. The audit of 11-15.)
    local function mostOf(e, health)
        local ok, v = pcall(function()
            local set = e.AttributeSetBase
            return health and set.Health_Max.CurrentValue or set.Shachi_Max.CurrentValue
        end)
        -- (A number only: on some actors the read hands back an object, and the comparison with it threw every pass, seen on
        -- the bench beside the forest's YuCong.)
        return ok and type(v) == "number" and v or nil
    end
    local function maxOf(e)
        return mostOf(e, api.coop.isHost())
    end
    -- (Both numbers are kept, with the role that one was taken in. A guest who hosts next in the same run of the game,
    -- from the panel with no load between, judged the bodies it had scaled as a guest by their guard bar's number
    -- against their health: the same for good, so one healed to its base by a difficulty set again, or a new body at
    -- that address after a rest, fought at the game's own numbers for the rest of that run. The seventh review, in the
    -- sim: 1.7.3 judged by health alone and kept co-op's health there.)
    local scaledOther = {}          -- enemy address -> { host, other }: the role scaledMax was taken in, the other number
    local function noteMax(addr, e)
        local host = api.coop.isHost()
        scaledMax[addr] = mostOf(e, host)
        scaledOther[addr] = { host = host, other = mostOf(e, not host) }
    end
    -- (Only a body below what it was given: one the game raises itself is still the one scaled.)
    local function same(e, addr, name)
        -- (Never, on the host, one the guest's game runs: its copy here takes the guest's numbers, scaled there. Read as a new
        -- body it was made tougher again each pass while the bar jumped, the log saying "1 enemy at 150% health" every second
        -- (the bench, 11-16); and one that came to this world already the guest's to run, a boss brought out as the host
        -- walked up, was scaled here on top and stood at 225% once the host took it back (12420 to 18630 on the bench).
        -- Known by its hold here (coop's heldAlive: on a host, only ever a copy the guest's game runs), and kept as scaled
        -- at what it has: by the guest's list it never was, that goes by the enemy's id and this file by the actor's name.)
        if api.coop.isHost() and net.heldAlive and net.heldAlive[addr] then
            scaled[addr] = name
            noteMax(addr, e)
            return true
        end
        if scaled[addr] ~= name then
            return false
        end
        local was, now = scaledMax[addr], maxOf(e)
        local o = scaledOther[addr]
        if o and o.host ~= api.coop.isHost() then
            was = o.other           -- (taken in the other role: this role's number, kept beside it)
        end
        return not (was and now and now < was * 0.99)
    end

    local MOST_SCALED = 4           -- players: past this, twins.lua adds enemies instead
    local function forPlayers(base, players)
        return base + (base - 1) * (math.min(players, MOST_SCALED) - 2)
    end

    -- A body's guard bar scaled for these numbers: by the whole of it for a new body, by what's missing (most often
    -- nothing) for one that still has the most posture it was given here. A boss's game can cut its health and its most
    -- back to its own, its posture left as it is: Xiao Xue's, at each blow of that world's own player while she had
    -- more health than her own most (the bench, 11-17 and 11-18; her rise is a new body). To the look above that's a
    -- new body, scaled again, and her guard bar was multiplied again at each cut: 34443 to 72 billion, a bar nobody
    -- breaks. (Her health since then: capped, below.)
    local scaledPosture = {}        -- enemy address -> { name, max, p, players }: what its most posture was scaled to
    local function scalePosture(set, addr, name, p, players, factor)
        local rec = scaledPosture[addr]
        local ok, now = pcall(function() return set.Shachi_Max.CurrentValue end)
        if rec and rec.name == name and ok and type(now) == "number" and now >= rec.max * 0.99 then
            factor = forPlayers(p, players) / forPlayers(rec.p, rec.players)
        end
        if math.abs(factor - 1) > 0.001 then
            scaleAttr(set, "Shachi", "Shachi_Max", factor)
        end
        ok, now = pcall(function() return set.Shachi_Max.CurrentValue end)
        scaledPosture[addr] = (ok and type(now) == "number") and { name = name, max = now, p = p, players = players } or nil
    end

    -- A boss whose game holds no more health than its own most. Xiao Xue's (the bench of 11-18, co-op off, her numbers
    -- written by hand): health over her own 16482 is cut to it at the next blow of that world's own player, and her
    -- most with it; under it a blow sticks and a most written over hers is left alone; her heals go by her own most.
    -- So co-op's share of her health can't be kept as health. To the look below the cut was a new body, scaled again
    -- with the share the cut left, a full one: every blow of the host's a heal to full, a fight nobody wins (the review
    -- of 369; in 1.7.3 too). Such a boss keeps its game's most from then on, its health the share it had of co-op's,
    -- and gives back co-op's part of every blow: a blow takes 1/f of what it did, from either player, which is what f
    -- times the health comes to. Known by the cut itself, between two ticks of its fight: its most back at what it was
    -- before this file raised it, its guard bar still what it was given (a difficulty set again writes both, and that
    -- body is scaled as new, below). On the host, for a body this game runs: a boss with its bar up is looked at every
    -- tick; an enemy with none at the pass's look (her summoned thugs have her rule: the bench of 11-18, run167, where
    -- every blow of the host's healed them to full). Every kept body is looked at before each of its lines to the
    -- guests, which still say co-op's numbers (coop.lua's shareEnemy), and a copy of it there is kept the same way at
    -- its own game's cut (syncEnemy). Given back: a drop, not a rise (its heals are its own, in its game's health: in
    -- co-op's number each counts f times, so her heal phases last longer than co-op's health alone would make them);
    -- not one that leaves it
    -- dead, or on a floor its game holds it at; not one of more than half its most at once, no blow (the game's set).
    local capped = {}               -- enemy address -> { name, most, f, hp }: its game's most, what it had at the last look
    local fought = {}               -- boss address -> { name, hp, max }: what it had at the last tick
    local BLOW_MOST = 0.5

    -- Whether its guard bar still has the most it was given here: the same body, whatever was written of its health.
    function scaling.guardKept(actor, addr)
        local rec = scaledPosture[addr]
        local ok, name, most = pcall(function()
            return actor:GetFName():ToString(), actor.AttributeSetBase.Shachi_Max.CurrentValue
        end)
        return rec ~= nil and ok and rec.name == name and type(most) == "number" and most >= rec.max * 0.99
    end

    -- The f of a body kept at its game's most, or nil: what its health stands for is f times it.
    function scaling.capped(actor, addr)
        local c = capped[addr]
        if not c then
            return nil
        end
        local ok, name = pcall(function() return actor:GetFName():ToString() end)
        if not ok or name ~= c.name then
            capped[addr] = nil
            return nil
        end
        return c.f
    end

    -- (addr, hp and max: what its line's turn has just read, coop.lua's shareEnemy; else read here.)
    local function watchBoss(boss, addr, hp, max)
        addr = addr or boss:GetAddress()
        if not (capped[addr] or scaledAs[addr]) then
            return
        end
        -- (Not a copy the guest's game runs: its numbers are the guest's line's.)
        if net.heldAlive and net.heldAlive[addr] then
            capped[addr], fought[addr] = nil, nil
            return
        end
        if not hp then
            hp, max = game.getHealth(boss)
        end
        if not (hp and max and max > 0) then
            return
        end
        local c, was = capped[addr], fought[addr]
        -- (As it was at the last tick: nothing to ask of it, its name neither.)
        if c and math.abs(max - c.most) <= c.most * 0.01 and math.abs(hp - c.hp) <= 0.5 then
            return
        end
        if not c and was and max >= was.max * 0.99 then
            was.hp, was.max = hp, max
            return
        end
        local name = boss:GetFName():ToString()
        if c and c.name ~= name then
            c, capped[addr] = nil, nil
        end
        if c then
            if not scaling.guardKept(boss, addr) then
                -- (Its guard bar no more what it was given: a new body there with the old name, or a difficulty set
                -- again. Looked at as new, below: by its health alone it's the one kept at its game's most.)
                capped[addr] = nil
                if scaled[addr] == name then
                    scaled[addr] = nil
                end
            elseif math.abs(max - c.most) > c.most * 0.01 then
                capped[addr] = nil      -- (its most set again, by a new count's scaling: as any body from here)
            else
                local drop = c.hp - hp
                -- (Not at its floor: a floor of its game's own, where what comes is its script's, or 0, where it's
                -- falling. One rule: said twice before, the second never asked. The eighth review.)
                if drop > 0.5 and drop <= c.most * BLOW_MOST and hp > game.healthFloor(boss) + 0.5 then
                    hp = hp + drop * (1 - 1 / c.f)
                    game.setHealth(boss, hp)
                end
                c.hp = hp
            end
        elseif was and was.name == name and max < was.max * 0.99 then
            local as = scaledAs[addr]
            local f = as and as.name == name and forPlayers(as.h, as.players or 2) or 1
            if f > 1.001 and math.abs(max - was.max / f) <= max * 0.01 and scaling.guardKept(boss, addr) then
                -- (Cut to its most: the share it had, less what it has lost since at 1/f. Under its own most before, its
                -- health was left as it was: that share.)
                -- (By its share only where that tells its game's cut: a boss, as before 385, or a body whose guard bar
                -- was raised here. With its guard its game's own (CoopEnemyPosture 100) one whose numbers the game wrote
                -- again, a difficulty set again, looks the same, and its old share stood for less than co-op's health:
                -- kept with what it has, as the pass's look kept one before 385. The ninth review.)
                local byShare = game.isBoss(boss, addr) or forPlayers(as.p, as.players or 2) * 0.99 > 1
                local keep = not byShare and hp
                    or was.hp > max + 0.5 and math.min(max, was.hp / f) - math.max(0, max - hp) / f or hp / f
                keep = math.max(1, keep)
                game.setHealth(boss, keep)
                hp = keep
                capped[addr] = { name = name, most = max, f = f, hp = keep }
                scaled[addr] = name
                noteMax(addr, boss)
                log(string.format("Co-op difficulty: %s's game holds no more than its own health (%.0f): kept at that, and a "
                    .. "blow takes %d%% of what it did instead.", name, max, math.floor(100 / f + 0.5)))
            end
        end
        was = was or {}
        was.name, was.hp, was.max = name, hp, max
        fought[addr] = was
    end

    scaling.look = watchBoss        -- (coop.lua's shareEnemy: before the line of any body scaled here goes)

    -- Whether its line looks at it first: any body scaled here. One with no bar was known at the pass's look alone and
    -- kept whole there: a guest's blows on it before the host's first, the cut's, were undone, its bar back at full on
    -- both screens (her summoned thugs: the eighth review, in run170's log).
    function scaling.watched(addr)
        return capped[addr] ~= nil or scaledAs[addr] ~= nil
    end

    -- A body with no bar isn't looked at every tick. In the host's round its line looks at it first (watched, above),
    -- and its cut is weighed there by what it had before it. One outside the round is known at the pass's look alone,
    -- by the most it was left at here, and kept with what it has then.
    local function cutAtLook(e, addr, name)
        if not api.coop.isHost() or capped[addr] or (net.heldAlive and net.heldAlive[addr]) then
            return false
        end
        -- (One its line looked at has what it had before the cut: kept with that share, as a boss is. The pass can
        -- come to it before its next line does.)
        if fought[addr] then
            watchBoss(e)
            if capped[addr] then
                return true
            end
        end
        local as, was, o = scaledAs[addr], scaledMax[addr], scaledOther[addr]
        if o and not o.host then
            was = o.other
        end
        local f = as and as.name == name and forPlayers(as.h, as.players or 2) or 1
        local hp, max = game.getHealth(e)
        if not (f > 1.001 and was and hp and max and max > 0 and hp > 0.5 and math.abs(max - was / f) <= max * 0.01
            and scaling.guardKept(e, addr)) then
            return false
        end
        capped[addr] = { name = name, most = max, f = f, hp = hp }
        scaled[addr] = name
        noteMax(addr, e)
        log(string.format("Co-op difficulty: %s's game holds no more than its own health (%.0f): kept at that, and a "
            .. "blow takes %d%% of what it did instead.", name, max, math.floor(100 / f + 0.5)))
        return true
    end

    -- A guest's copy judged a new body by its guard bar (its game wrote that back: a difficulty set again) can still
    -- have the most health it was given here, or the host's line's: put back at once by syncEnemy, or never touched.
    -- Scaled again it stood at f times what it had, a copy in a party guest's own fight for good (the sim, 11-18).
    -- So a guest gives a body its health only when it hasn't the most this file left it at.
    local scaledHealth = {}         -- a guest: enemy address -> { name, max }: the most health its scaling left it at
    local function scaleHealth(set, addr, name, factor)
        if api.coop.isHost() then
            return scaleAttr(set, "Health", "Health_Max", factor)
        end
        local rec = scaledHealth[addr]
        local ok, now = pcall(function() return set.Health_Max.CurrentValue end)
        if rec and rec.name == name and ok and type(now) == "number" and now >= rec.max * 0.99 then
            return
        end
        scaleAttr(set, "Health", "Health_Max", factor)
        ok, now = pcall(function() return set.Health_Max.CurrentValue end)
        scaledHealth[addr] = (ok and type(now) == "number") and { name = name, max = now } or nil
    end

    -- A guest: the most the host's line says for its copy, what scaledHealth and the other role's number keep. The line
    -- gives a copy its most before the scaling's first look as often as not (its turns go on in the quiet after a load,
    -- which the scaling waits out), and the scaling multiplied that again for a moment: 1350 noted of the line's 900.
    -- The copy was then given its health twice at a write of its guard bar (380), and taken for one its game cuts once
    -- this player hosted, 225% for two (379). The eighth review.
    function scaling.lineMost(addr, most)
        local rec, o = scaledHealth[addr], scaledOther[addr]
        if rec then
            rec.max = most
        end
        if o and not o.host then
            o.other = most
        end
    end

    local function playersConnected()
        local n = 1
        for _, p in ipairs(api.coop.partners()) do
            if p.lastRemoteAt and not p.partnerGone then
                n = n + 1
            end
        end
        return n
    end

    -- Everyone connected, this player too: a party's count, or 2 with a partner synced, else 1.
    function scaling.players()
        if net.party then
            return playersConnected()
        end
        return (net.enabled and net.target and not net.partnerGone) and 2 or 1
    end

    -- More than two players: true if this took a scaling, which is what a tick may spend.
    local function scaleForParty(e, addr, name, players)
        local before = same(e, addr, name) and (scaledFor[addr] or 2) or nil
        if before and (before >= players or not api.coop.isHost() or (game.bossFightActive() and game.isBoss(e, addr))) then
            return false
        end
        -- (Under the most it was given, by its own game's cut: kept at that, not scaled again. See capped.)
        if before == nil and scaled[addr] == name and not game.isDead(e) and cutAtLook(e, addr, name) then
            return false
        end
        -- (No attributes: a destroyed body still listed till collection. Nothing to write on: see tick.)
        if not valid(e.AttributeSetBase) then
            return false
        end
        if before == nil then
            fought[addr] = nil      -- (a new body: its line's record of the one there before it goes, see watchBoss)
        end
        scaled[addr], scaledFor[addr] = name, players
        if game.isDead(e) then
            return false
        end
        local set = e.AttributeSetBase
        local h, p, boss = numbersFor(e, addr)
        -- (A body that holds a boss's numbers rises by them and stays one, its bar down or not. By the enemies' it was
        -- promoted again at its next bar, a boss twice over: a guest's lost fight leaves the host's body so, and a player
        -- joined. The review of 11-10.)
        local was = scaledAs[addr]
        if before and not boss and was and was.name == name and was.boss then
            h, p, boss = was.h, was.p, true
        end
        local health, posture = forPlayers(h, players), forPlayers(p, players)
        if before then
            health, posture = health / forPlayers(h, before), posture / forPlayers(p, before)
        end
        -- (One kept at its game's most, see capped: a new count is what its health stands for, its most its game's.
        -- Its game numbers multiplied, it was dropped as kept and stood at 133% where three get 200%, or healed to
        -- full at the next cut. The eighth review.)
        local c = capped[addr]
        if before and c and c.name == name then
            c.f = forPlayers(h, players)
        else
            scaleHealth(set, addr, name, health)
        end
        scalePosture(set, addr, name, p, players, posture)
        noteMax(addr, e)
        scaledAs[addr] = { name = name, h = h, p = p, boss = boss, players = players }
        return true
    end

    -- A body scaled with the enemies' numbers that's a boss now (a story boss of an ordinary enemy's class is one only once
    -- its bar is up): the bosses' own numbers, once, its share of health kept. The review of 11-09: it kept the enemies'.
    -- (Only with bosses' own numbers set: CoopBossHealth / CoopBossPosture.)
    local function promoteBoss(e, addr, name)
        local was = scaledAs[addr]
        if not (was and was.name == name) or was.boss or game.isDead(e) or not game.isBoss(e, addr) then
            return false
        end
        local h, p = numbersFor(e, addr)
        local players, set = was.players or 2, e.AttributeSetBase
        scaleAttr(set, "Health", "Health_Max", forPlayers(h, players) / forPlayers(was.h, players))
        scalePosture(set, addr, name, p, players, forPlayers(p, players) / forPlayers(was.p, players))
        scaledAs[addr] = { name = name, h = h, p = p, boss = true, players = players }
        noteMax(addr, e)
        log(string.format("Co-op difficulty: %s is a boss: %d%% health, %d%% posture.", name,
            math.floor(forPlayers(h, players) * 100 + 0.5), math.floor(forPlayers(p, players) * 100 + 0.5)))
        return true
    end

    -- Bosses: the share of poise damage they take, set once per body (an address comes back for a new actor, so by name too).
    local poised = {}               -- boss address -> its name once set
    local function poiseBoss(e, addr, name)
        if poised[addr] == name or scaling.bossPoise == 1 or not game.isBoss(e, addr) then
            return false
        end
        -- (A guest's copy of the host's boss is puppets.lua's to set: next to nothing in the host's moves, this between them.)
        if api.puppets and api.puppets.follows and api.puppets.follows(addr) then
            return false
        end
        -- (Its attributes asked first: a destroyed body, still listed till collection, has none. Set on nothing no
        -- error came, and it was said as set. The bench, 11-18: a stand-in dropped 22 s before, run175.)
        local set = e.AttributeSetBase
        if not valid(set) then
            return false
        end
        poised[addr] = name
        local ok = pcall(function()
            local a = set.TakenReductionMultiplier_Poise
            a.BaseValue = 1 / scaling.bossPoise
            a.CurrentValue = 1 / scaling.bossPoise
        end)
        if ok then
            log(string.format("Co-op difficulty: boss %s at %d%% poise.", name, math.floor(scaling.bossPoise * 100 + 0.5)))
        end
        return ok
    end

    -- Boss super armour (CoopBossArmor, On as the ini ships; the user, 11-10: "the bosses should not be able to be knocked
    -- back ... if they get knocked back or react to hit they can't do anything"). While someone is with you, a boss this PC
    -- runs lets go of a flinch from a hit at once, with its reaction's montage, and takes up the move the hit cut where it
    -- was (puppets.resumeHost), so the hit neither stops it nor stuns it. Its guard break (State.Break) and an execution stay
    -- the game's. On the bench, 11-10, the Gold-Masked One with two players swinging spent 51% of the fight reacting
    -- without it and 4% with it (31% with one player). Its armour profile can't do this: the Gold-Masked One's,
    -- AbstractEndure_Minion, has none in its plain attacks, between moves or in the refill after a break, and every level
    -- put at 8 changed nothing. The host doesn't send a flinch it let go (puppets.watchHost), nor plays a partner's on an
    -- armoured boss (coop.lua's bossMayReact); a guest's copy gives its own reactions way (puppets.lua's armourCopy).
    -- The hit states let go (after "Hitreact."): the flinch family under State.Normal (light, heavy, knockback, counter,
    -- the loop) but its scripted Perform, a knock back on the ground, a poise stagger, and the poise levels Break.LvN. The
    -- Gold-Masked One's HitreactStatesConfig has 21 (bench, 11-10). Left to the game: the guard break (State.Break.*), an
    -- execution (State.Executing), death, Custom, being frozen, and the air and floor states (InAir, Air.Launchingback,
    -- Landing, Lying, Getup, Root): a body let go there could be left hanging. One not known here is logged once.
    local LEFT = {
        ["State.Break.Normal"] = true, ["State.Break.State"] = true, ["State.Executing"] = true, ["State.Dead"] = true,
        ["State.DeadLoop"] = true, ["State.Normal.Perform"] = true, ["State.Custom"] = true, ["State.Frozen"] = true,
        ["State.InAir"] = true, ["State.Air.Launchingback"] = true, ["State.Landing"] = true, ["State.Lying"] = true,
        ["State.Getup"] = true, ["State.Root"] = true,
    }
    local function lettable(kind)
        if LEFT[kind] then
            return false
        end
        return kind:find("^State%.Normal") ~= nil or kind == "State.Launchingback" or kind == "State.PoiseBreak"
            or kind:find("^Break%.Lv%d+$") ~= nil
    end
    local REACTION_WORDS = { "hit", "knock", "launch", "poise", "stagger", "react" }
    local unknownSaid, unknownN = {}, 0
    scaling.letGoCount = 0

    -- Someone with you as the rest of co-op difficulty means it: a partner's figure here (this map, alive, not in a scene)
    -- and this player up. (By the connection alone, a partner on another map or dead gave a boss fought alone its armour:
    -- the reviews of 11-10.)
    local function partnerHere()
        if net.deadSince ~= nil then
            return false
        end
        for _, p in ipairs(api.coop.partners()) do
            if valid(p.ghost) and not p.ghostHidden and not p.silent then
                return true
            end
        end
        return false
    end

    -- Whether this body, on this PC, wears it now: a boss or a boss's ghost twin that this PC runs, someone with you, and
    -- not a fight begun alone that someone only watches (it keeps its numbers too: soloFights).
    function scaling.armoured(actor, addr)
        if not scaling.bossArmor or not partnerHere() then
            return false
        end
        addr = addr or actor:GetAddress()
        if soloFights[addr] and game.bossFightActive() then
            return false
        end
        if api.puppets and api.puppets.follows and api.puppets.follows(addr) then
            return false            -- (a copy: the host's boss does what it does)
        end
        return game.isBoss(actor, addr) or (game.bossTwin and game.bossTwin(actor, addr)) or false
    end

    -- The letting go itself: a hit state of the flinch family ended, then its reaction montage stopped (not keep: the move
    -- it goes on with, an additive flinch over it). True if there was one. (ChangeHitState's third argument ends the
    -- reaction's strength task too, its push; game.clearHitState passes false, to drop a copy's tag alone.)
    local function letGoNow(actor, keep)
        local state, comp = game.hitStateOf(actor)
        local kind = comp and state and state:match("[Hh]it[Rr]eact%.(.+)$")
        if not kind or kind == "None" then
            return false
        end
        if not lettable(kind) then
            if not LEFT[kind] and not unknownSaid[kind] and unknownN < 40 then      -- (names off the game: capped)
                unknownSaid[kind], unknownN = true, unknownN + 1
                log("Super armour: a boss's hit state " .. kind .. " left to the game (not one known here).")
            end
            return false
        end
        if not pcall(function() comp:ChangeHitState({ TagName = FName("None") }, nil, true) end) then
            return false
        end
        pcall(function()
            local anim = api.moves.animOf(actor)
            local m = anim and anim:GetCurrentActiveMontage()
            if valid(m) and m:GetAddress() ~= keep then
                local n = (m:GetFName():ToString() .. " " .. tostring(api.moves.pathOf(m))):lower()
                for _, word in ipairs(REACTION_WORDS) do
                    if n:find(word, 1, true) then
                        anim:Montage_Stop(0.1, m)
                        break
                    end
                end
            end
        end)
        scaling.letGoCount = scaling.letGoCount + 1
        return true
    end

    -- An armoured boss's flinch let go, and the move it cut taken up again: true if it had one.
    function scaling.letGo(actor, addr)
        if not scaling.armoured(actor, addr) then
            return false
        end
        addr = addr or actor:GetAddress()
        local move = api.puppets and api.puppets.hostMoveOf and api.puppets.hostMoveOf(addr)
        if not letGoNow(actor, move and move.montage) then
            return false
        end
        if api.puppets and api.puppets.resumeHost then
            api.puppets.resumeHost(actor, addr)
        end
        return true
    end

    -- Whether a guest's copies of bosses wear it now (puppets.lua's armourCopy: a copy's own reaction to this player's hit
    -- gives way, as the host's armoured boss had none). By this PC's own CoopBossArmor, which both players should set the
    -- same: a host without it sends its boss's flinches as moves, and those play here as ever.
    function scaling.copiesArmoured()
        return scaling.bossArmor and partnerHere()
    end

    -- How hard it hits: the game's own multipliers of the damage it deals, each kind's (CoopEnemyDamage or CoopBossDamage).
    -- On the bench, 11-09, a Xigu elite's Attack at twice made no difference; DealtVulnerabilityMultiplier_<kind> at 2 doubled
    -- its hits (70 -> 140) and DealtReductionMultiplier_<kind> at 0.5 halved them (70 -> 35, a poison's tick 4 -> 2). Up by
    -- the first, down by the second. Not "Elemental": a poison's tick counts it as well as its own kind and went four times.
    -- A broken guard's blow (about 200) is neither's: it stays the game's. Each kind's base as this set it is kept, and a
    -- kind the game has set again is scaled again from the game's new number: a difficulty switch recomputes an enemy's
    -- numbers (the Coop session on the bench, 11-09: a thug's Attack 100 -> 70 at Wayfarer and back), and difficulty.lua
    -- raises the mode a second after a partner links, after this may have run; a body come back at that address too. One
    -- still at ours isn't, so it's never on top of itself: by its base, as an effect on top moves only the current, and gone
    -- again leaves ours. (The first kind looked at each pass, all of them only when it moved: a look is one read.) True if it
    -- took a scaling, which is what a tick spends.
    local KINDS = { "Physical", "PhysicalSharp", "PhysicalBlunt", "Fire", "Toxin", "Ice", "Aqua", "Lightning", "Blood", "Chaos" }
    local UP, DOWN = "DealtVulnerabilityMultiplier_", "DealtReductionMultiplier_"
    local hits = {}                 -- enemy address -> { name, f, prefix, given = { kind -> the base this set } }

    -- Its factor now: a boss's, a boss's ghost twin's (no boss to the mod, but it hits as one: by its class, as the game's
    -- codex has it), or an enemy's.
    local function hitFactor(e, addr)
        if scaling.bossDamage == scaling.damage then
            return scaling.damage
        end
        local boss = game.isBoss(e, addr)
        if not boss and game.isBossClass and game.twinId and game.twinId(addr, e) then
            local ok, cn = pcall(function() return e:GetClass():GetFName():ToString() end)
            boss = ok and game.isBossClass(cn) or false
        end
        return boss and scaling.bossDamage or scaling.damage
    end

    local function scaleHits(e, addr, name)
        local f = hitFactor(e, addr)
        local set = e.AttributeSetBase
        local was = hits[addr]
        if was and was.name ~= name then
            was = nil               -- (another body at that address)
        end
        if was and was.f == f then
            if f == 1 then
                return false
            end
            local ok, base = pcall(function() return set[was.prefix .. KINDS[1]].BaseValue end)
            if not ok or type(base) ~= "number" or (was.given[KINDS[1]] and math.abs(base - was.given[KINDS[1]]) <= 0.001) then
                return false        -- (ours still)
            end
            -- The game set it again (a difficulty switch): each kind not at ours, from the game's new number.
            local took = false
            for _, kind in ipairs(KINDS) do
                pcall(function()
                    local a = set[was.prefix .. kind]
                    local b = a.BaseValue
                    if not (was.given[kind] and math.abs(b - was.given[kind]) <= 0.001) then
                        a.BaseValue, a.CurrentValue = b * f, a.CurrentValue * f
                        was.given[kind] = b * f
                        took = true
                    end
                end)
            end
            return took
        end
        -- A new body, or its factor changed (a story boss known only once its bar is up, after it was scaled as an enemy; the
        -- hitscale command): what the old factor set, where it still stands, goes back to the game's number first, so the two
        -- never mix nor stack (the review of 11-09: up and down both on, or one on top of the other); then the new one.
        if was and was.f ~= 1 then
            for _, kind in ipairs(KINDS) do
                pcall(function()
                    local a = set[was.prefix .. kind]
                    if was.given[kind] and math.abs(a.BaseValue - was.given[kind]) <= 0.001 then
                        a.BaseValue, a.CurrentValue = a.BaseValue / was.f, a.CurrentValue / was.f
                    end
                end)
            end
        end
        local prefix = f >= 1 and UP or DOWN
        local given = {}
        hits[addr] = { name = name, f = f, prefix = prefix, given = given }
        if f == 1 then
            return was ~= nil       -- (one put back took its calls)
        end
        for _, kind in ipairs(KINDS) do
            pcall(function()
                local a = set[prefix .. kind]
                a.BaseValue, a.CurrentValue = a.BaseValue * f, a.CurrentValue * f
                given[kind] = a.BaseValue
            end)
        end
        return true
    end

    local function noteSoloFights()
        soloFights = {}
        if game.bossFightActive() then
            for _, boss in ipairs(game.bossActors()) do
                soloFights[boss:GetAddress()] = true
            end
        end
    end

    local function inSoloFight(addr)
        if soloFights[addr] and not game.bossFightActive() then
            soloFights[addr] = nil
        end
        return soloFights[addr] == true
    end

    -- While the partner is here: scale enemies we haven't scaled yet, a few looks a tick. The list is the one the net loop
    -- keeps: the search for enemies is its job, once a second, and two in one frame was part of the worst case.
    local next, todo, addrs, at, n, hitN = 0, {}, {}, 1, 0, 0
    local players = 2
    local function tick()
        -- (The numbers changed, to 100 too: one whole pass more looks at every body's hits, so the number before is taken
        -- back where it stands. At 100 none was looked at, and every body kept the one before, the ini's back at 100 and
        -- co-op started again from the panel too: the review of 11-10.)
        local seen = scaling.hitsSeen
        if not seen or seen[1] ~= scaling.damage or seen[2] ~= scaling.bossDamage then
            scaling.hitsSeen, scaling.hitsBack = { scaling.damage, scaling.bossDamage }, seen and 2 or 0
        end
        local hitting = scaling.damage ~= 1 or scaling.bossDamage ~= 1 or scaling.hitsBack > 0
        if scaling.health == 1 and scaling.posture == 1 and scaling.bossPoise == 1 and not hitting
            and (scaling.bossHealth or 1) == 1 and (scaling.bossPosture or 1) == 1 then
            return
        end
        if at > #todo then
            if n > 0 then
                log(string.format("Co-op difficulty: %d enem%s at %d%% health, %d%% posture.", n, n == 1 and "y" or "ies",
                    math.floor(forPlayers(scaling.health, players) * 100 + 0.5), math.floor(forPlayers(scaling.posture, players) * 100 + 0.5)))
                n = 0
            end
            if hitN > 0 then
                log(string.format("Co-op difficulty: %d enem%s hitting at %d%%, bosses at %d%%.", hitN, hitN == 1 and "y" or "ies",
                    math.floor(scaling.damage * 100 + 0.5), math.floor(scaling.bossDamage * 100 + 0.5)))
                hitN = 0
            end
            if os.clock() < next then
                return
            end
            next = os.clock() + PASS_S
            players = net.party and playersConnected() or 2
            if net.party then
                if players < 2 then
                    noteSoloFights()
                    return
                end
            -- "With you": synced and the partner's ghost is in this world (same map, alive).
            elseif not (net.enabled and net.target and valid(net.ghost) and not net.ghostHidden) then
                noteSoloFights()
                return
            end
            -- (A fight marked as fought alone is the partner's too once they're in it: walked in, or a blow of theirs landed,
            -- as their F 1 says. Any moment without their figure marks it, the second their health sat at 0 as well: a boss
            -- lost its super armour for the rest of the fight once the guest had died in it and come back. The audit of 11-15.
            -- One who only watches says no F 1, and the fight stays as it began.)
            if not net.party and net.partnerFighting then
                soloFights = {}
            end
            todo, addrs = game.enemiesSoFar()
            at = 1
            -- (A body kept at its game's most whose guard bar is no more what it was given is a new body there with
            -- the old name, or a difficulty set again: looked at as new, below. Whole at its game's most, nothing its
            -- own look sees had changed.)
            for i, a in ipairs(addrs) do
                local c = capped[a]
                if c and valid(todo[i]) and not scaling.guardKept(todo[i], a) then
                    capped[a] = nil
                    if scaled[a] == c.name then
                        scaled[a] = nil
                    end
                end
            end
            scaling.hitsBack = math.max(0, scaling.hitsBack - 1)
        end
        for _ = 1, LOOKS_PER_TICK do
            local e, addr = todo[at], addrs[at]
            if e == nil then
                return
            end
            at = at + 1
            local name = valid(e) and not inSoloFight(addr) and e:GetFName():ToString()
            -- (A body with no attributes is looked at for nothing: a destroyed one still listed till collection, the
            -- only kind the bench has shown (run175, a stand-in dropped 22 s before). Were a living body ever seen so,
            -- scaled then it would be marked done with nothing written, the game's own numbers for its whole fight:
            -- it's looked at again at the next pass instead. The eighth review.)
            if name and not valid(e.AttributeSetBase) then
                name = false
            end
            -- (How hard it hits, a ghost twin's too: twins.lua gives a twin its original's health and posture, already
            -- scaled, as it came, but not this; the review of 11-09, every twin at the game's own.)
            if name and hitting and not game.isDead(e) and scaleHits(e, addr, name) then
                hitN = hitN + 1
                return
            end
            -- (Nothing else for a ghost twin: it took its original's numbers as it came.)
            if name and game.twinId and game.twinId(addr, e) then
                name = false
            end
            if name and not game.isDead(e) and poiseBoss(e, addr, name) then
                return
            end
            if name and net.party then
                if scaleForParty(e, addr, name, players) then
                    n = n + 1
                    return
                end
            elseif name and not same(e, addr, name) then
                -- (Under the most it was given by its own game's cut: kept at that, not scaled again. See capped.)
                if scaled[addr] == name and not game.isDead(e) and cutAtLook(e, addr, name) then
                    return
                end
                scaled[addr], scaledMax[addr] = name, nil       -- (or it's dead, and nothing brings it back as the same actor)
                -- (Its line's record of the body there before it goes with it: kept, a body made at a dead one's address
                -- had the dead one's name in it, and its game's cut at the host's first blow wasn't weighed. The ninth review.)
                fought[addr] = nil
                if not game.isDead(e) then
                    local set = e.AttributeSetBase
                    local health, posture, boss = numbersFor(e, addr)
                    scaleHealth(set, addr, name, health)
                    scalePosture(set, addr, name, posture, 2, posture)
                    noteMax(addr, e)
                    scaledAs[addr] = { name = name, h = health, p = posture, boss = boss, players = 2 }
                    n = n + 1
                    return
                end
            end
            if name and (scaling.bossHealth or scaling.bossPosture) and promoteBoss(e, addr, name) then
                return
            end
        end
    end
    -- The bosses of the fights going on, every tick (EXTRA_S), before anything else here: their flinches let go. (A boss
    -- shared with a guest is also looked at in each snapshot, puppets.watchHost, before a flinch could go out as a move; a
    -- ghost twin only there.) Not a tick of its own: a new entry in coop's extraTicks changes the order they all run in.
    local function armourTick()
        local host = api.coop.isHost()
        if scaling.bossArmor or host then
            for _, boss in ipairs(game.bossActors()) do
                if scaling.bossArmor then
                    scaling.letGo(boss)
                end
                -- (Before the look at the enemies: one kept at its game's most is the body that look scaled.)
                if host then
                    watchBoss(boss)
                end
            end
        end
        return tick()
    end
    api.coop.extraTicks.scaling = armourTick

    -- scale <health %> [posture %]   (100 100 = normal enemies)
    function scaling.command(args)
        local h, p = (args or ""):match("^%s*(%d+)%s*(%d*)")
        if tonumber(h) then
            scaling.health = math.max(1.0, math.min(5.0, tonumber(h) / 100))
            scaling.posture = tonumber(p) and math.max(1.0, math.min(5.0, tonumber(p) / 100)) or scaling.posture
        end
        log(string.format("Co-op difficulty: enemies at %d%% health, %d%% posture while your partner is here.",
            math.floor(scaling.health * 100 + 0.5), math.floor(scaling.posture * 100 + 0.5)))
    end

    -- bosspoise <percent>   (100 = normal; read at start from CoopBossPoise). Bosses around take the new number on the next
    -- pass.
    function scaling.bossPoiseCommand(args)
        local v = tonumber((args or ""):match("^%s*(%d+)"))
        if v then
            scaling.bossPoise = math.max(1.0, math.min(10.0, v / 100))
            poised = {}
        end
        log(string.format("Co-op difficulty: bosses at %d%% poise while your partner is here.",
            math.floor(scaling.bossPoise * 100 + 0.5)))
    end

    -- bossarmor on | off   (read at start from CoopBossArmor)
    function scaling.bossArmorCommand(args)
        local v = (args or ""):lower():match("^%s*(%a+)")
        if v == "on" or v == "off" then
            scaling.bossArmor = v == "on"
        end
        log(string.format("Co-op difficulty: bosses %s while your partner is here.",
            scaling.bossArmor and "don't flinch from hits (super armour)" or "flinch from hits as the game has it"))
    end

    -- bossscale <health %> [posture %] | off   (read at start from CoopBossHealth / CoopBossPosture; off: bosses take scale's
    -- numbers). Bosses scaled already keep theirs.
    function scaling.bossCommand(args)
        if (args or ""):match("^%s*off") then
            scaling.bossHealth, scaling.bossPosture = nil, nil
        else
            local h, p = (args or ""):match("^%s*(%d+)%s*(%d*)")
            if tonumber(h) then
                scaling.bossHealth = math.max(1.0, math.min(5.0, tonumber(h) / 100))
                scaling.bossPosture = tonumber(p) and math.max(1.0, math.min(5.0, tonumber(p) / 100)) or scaling.bossPosture
            end
        end
        log(string.format("Co-op difficulty: bosses at %d%% health, %d%% posture while your partner is here.",
            math.floor((scaling.bossHealth or scaling.health) * 100 + 0.5),
            math.floor((scaling.bossPosture or scaling.posture) * 100 + 0.5)))
    end

    -- hitscale <enemies %> [bosses %]   (100 100 = as hard as the game has them; read at start from CoopEnemyDamage /
    -- CoopBossDamage; bosses left out: the enemies' number). Enemies about take the new number too, from the game's own:
    -- scaleHits takes the old one back first.
    function scaling.damageCommand(args)
        local m, b = (args or ""):match("^%s*(%d+)%s*(%d*)")
        if tonumber(m) then
            scaling.damage = math.max(0.1, math.min(5.0, tonumber(m) / 100))
            scaling.bossDamage = tonumber(b) and math.max(0.1, math.min(5.0, tonumber(b) / 100)) or scaling.damage
        end
        log(string.format("Co-op difficulty: enemies hit at %d%%, bosses at %d%% while your partner is here.",
            math.floor(scaling.damage * 100 + 0.5), math.floor(scaling.bossDamage * 100 + 0.5)))
    end

    return scaling
end
