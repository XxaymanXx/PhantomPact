# Online co-op: how it works now

Protocol 3 (written 2026-11-01). Replaces the file-based relay and the JSON packets of 1.4.1 and earlier. Both players
need this version.

## Why it was rewritten

Measured on a Ryzen 5900X and RTX 4090, 11 enemies around, nobody connected:

| | 1.4.1 | now |
|---|---|---|
| Sync on, in a crowd | 38 FPS | 54-55 FPS, the same as sync off |
| Sync off, same spot, same run | 60 FPS | 52-54 FPS |
| Game-thread time used by the mod | about 300 ms/s | about 45 ms/s |
| Writing a snapshot on exFAT | 5.2 ms a time | no file at all |
| Positions sent per second | 10 (at 60 FPS; the code assumed 20) | up to 60 |

The lag players felt was mostly the mod slowing their own game: `getPlayer1()` cost a full object search about 110 times a
second, a snapshot was written through files on the game thread, and all enemies were read in one frame. The wrong
snapshot rate also doubled the speed used for prediction, which made the ghost overshoot.

Two real copies on one PC, loopback:

| | now |
|---|---|
| Ghost's distance to the real player, walking | 0-2 cm typical, 33 cm at the 95th percentile |
| Same in a moving fight | 19 cm typical, 36 cm at worst |
| Same on a bad link (100 ms ping, 20 ms jitter, 2% loss, 250 ms stall every 7 s) | 1 cm typical, 35 cm at worst, no jumps |
| Host's kill to the guest's copy | 18 ms |
| Guest's killing blow, there and back | 24 ms |
| Enemy position, host's copy against guest's, standing | 0 cm typical |

## The pieces

- `native/relay.hpp`: the relay thread in main.dll, the Mailbox between it and the game thread, the packets.
- `native/lanes.hpp`: the sure lane (arrives, once, in order, resent by acknowledgement) and the quick lane (sent three
  times, played once, dropped if late).
- `native/timeline.hpp`: plays the partner a little in the past, just far enough that three samples in four are there in
  time, following the connection; the rest of the time it guesses ahead from the sender's own speed, which is also the
  speed the ghost is told to walk at.
- `native/lua_link.hpp`: direct calls from Lua (`api.link`, opened by `openLink` in main.lua). UE4SS doesn't export Lua's C
  API, but it exports its own wrapper class for C++ mods, and that is what's called.
- `mod/PBZCoop/Scripts/coop.lua`: one `tick` every frame. `readPartner`, `steerGhost` and `sendPlayer` run each frame
  (`sendPlayer` at most 125 times a second); enemies take turns over `ENEMY_ROUND_S`; `watchSlowly` runs ten times a second.

Nothing on the hot path touches a file. `net_start.txt` starts the relay, `pp_stop` ends it (the socket closes, the Mailbox
empties, and another start can follow with another role), and `net_status.txt` is rewritten once a second
for people and tools to read.

## Packets

Little-endian, at most 1100 bytes before signing (`MAX_PACKET`), so a signed packet stays under Tailscale's 1280.

Header: marker 0xA3, protocol 5, flags (1 = from the host), session, the partner's session as we know it, sequence, sender's
time in ms, the partner's time echoed back, how long we held it, sure-lane acknowledgement (next id expected, plus a bitmap
of the 32 after it). Round trip comes from the echo, so no ping packets are needed.

Sections follow: state (40 bytes), sure event, quick event, enemy line, hello (version, map, shared settings), and with more than
two players another player (a slot and 40 bytes).

The state's flags, set by the mod: 1 walking, 2 in a scene, 4 falling, 8 flying (ladders, wall runs); 0x10 and 0x20 how they move
(1 walk, 2 jog, 3 sprint; none from an older version), 0x40 in the guard stance, 0x80 in a move, 0x100 to 0x2000 the posture's
share of its top, 1 to 63 (0: not said; from 1.7.0, for a foe's gold strip on the boss bar). The relay's own: 0x4000 this
sample teleported, 0x8000 nothing new for longer than it guesses ahead.

A session is the sender's clock in ms, always moving on, new per `link.reset()`, so a late packet of an older session can be
told from a new start. A packet's sure and quick sections count only if its "partner's session" is ours.
Seeing a new session from the partner restarts both lanes and hands the mod an `S` event.

## Events

`coop.lua`'s header lists them. `sendEvent` picks the lane: U, M, A, H, Z, SHOT, NQ, HEAL and HX are quick; the rest are
sure. (`HX <enemy> <type> <strength> <material>`: a hit's sound and blood, `hitfx.lua`. Older versions drop it, as they
drop any event they don't know.)

Enemy lines don't carry names: an `N` event gives each enemy a number first.

## More than two players

Only a host with `PartySize` 4 or 6 (or `FourPlayers = On`) runs this (`native/party.hpp`, written from EXACG's design in PR #11). It runs one `Relay` per
guest on one socket, each with its own Mailbox for what goes out, so a guest's end is the same as with two players. Packets go to
the Relay already talking to that address, else a free slot, else one silent for 3 s. All of it is on the relay thread.

| | |
|---|---|
| Hello to a guest | adds `players=4` and `slot=<n>` |
| What the game posts | copied to each guest's Mailbox, or one guest's (`link.send_to`) |
| What a guest says | to the game as `@<slot> <event>`, and to the other guests the same way. `D` stays with the host |
| Where a guest is | to the game by slot (`link.player`), and to the others in `SEC_PLAYER`, at most 60 times a second |
| Status line | adds `players`, `slot`, `guests`, `turned_away`, `upload_kb_s`, `map<slot>`, `other_versions`. `mismatch` covers every guest |

Three guests, bots on one PC:

| | clean link | 40 ms delay, 20 ms jitter, 2% loss |
|---|---|---|
| Host sees a guest behind by, typically | 27 ms | 78 ms |
| A guest sees another guest behind by, typically | 52 ms | 145 ms |
| Host's upload, no enemies | 43 KB/s | |
| With 8 enemies, 20 times a second | 62 KB/s | |
| With 30 | 107 KB/s | |

On the game thread four players cost about a third more calls into the game each frame than two: a ghost's place is read from
memory, and a hidden ghost costs nothing (`luasim.py four` counts them).

## How far behind the partner is shown

Measured with `relay_cli latency` (`native/latency.hpp`): the whole way from the sender's frame to the ghost on the other
screen, in simulated time, against where the sender really was every millisecond. The sender's motion is made from what
recordings of the real game show: starts take a quarter of a second, a stop takes one frame, turns run at about 25 degrees a
frame, frames come unevenly and the mod's tick a few ms into each. Played over loopback, a real recording's partner shows
24 ms behind on the bench and was 23 ms behind in the real game.

Mixed play (runs, sudden stops, turns, footwork, dodges), mean over every RTT of 30/80/150 ms, jitter 0/10/30 ms, loss
0/2/5% and the sender at 30/60/120 FPS; behind as p50 / p95 / p99:

| | 1.6.0 as it was | now |
|---|---|---|
| The path played, behind the real one: RTT 30 / 80 / 150 ms | 59 / 84 / 119 ms | 44 / 69 / 104 ms |
| ... with the sender at 30 / 60 / 120 FPS | 94 / 86 / 82 ms | 87 / 70 / 61 ms |
| ... at the 95th / 99th percentile, all connections | 90 / 92 ms | 74 / 75 ms |
| The ghost on screen, behind, p50 / p95 / p99 | 87 / 118 / 132 ms | 72 / 102 / 116 ms |
| The ghost's speed off the real one, running and stopping, 95th percentile | 70 cm/s | 17 cm/s |
| A sudden stop: how far the played path runs on past it, worst per connection | 0.8 cm | 1.4 cm |
| ... and the ghost | 12.2 cm | 12.6 cm |

Through real sockets and netem (`bench.ps1`), the bot sending every frame: RTT 30 clean 34 -> 30 ms, RTT 80 with 10 ms jitter
and 2% loss 68 -> 64 ms, RTT 150 with 30 ms jitter and 5% loss 122 -> 110 ms (p50). `all.ps1`'s bad link (250 ms stalls
every 3 s): 136 -> 73 ms at the 95th percentile.

What made the difference:

- `sendPlayer` sends every frame, at most 125 a second. The gap of 1/62 s it used to wait after a send skipped a frame in four
  at 60 FPS (the tick's moment in the frame wanders a few ms), and one gap in ten was a whole extra frame for the partner to
  wait out. Above 60 FPS it sent every second frame.
- The Timeline plays just far enough behind that three samples in four are there in time, counting a sample's gap from the one
  before together with its lateness, and guesses the last 3 ms from the sender's speed: a stop slides further than that. It
  used to add the average gap, the 90th percentile of lateness and 2 ms, which also put a stall into the delay for 1.5 s.
- The ghost is told the sender's own speed, eased between samples. Worked out from two samples' stamps it swung by a fifth from
  sample to sample, because the stamp is when the tick ran, not when the game moved the player, and the ghost walks at that
  speed. When the path disagrees with those speeds (the sender carried by something), it's the path's speed.

Tried and not kept:

- Showing the partner where they probably are now (guessing ahead by the whole delay): 5 ms ahead, but every sudden stop ran
  on 31 cm (45 at worst) and walked back; easing the correction over 100 ms changed nothing, the overshoot comes before the
  stop is known. Half of it: 38 ms behind, 8 cm (20 at worst). 10 ms ahead: 5 ms less, the worst stop 1.6 cm further. Every
  ms guessed past the newest sample costs about 0.6 cm at a stop at running speed, once it's past the stop's own slide.
- Leaving the gap between samples out of the delay: 20 ms less, but a stop overshot 18 cm at 30 FPS.
- Through a stall, slowing the guess down instead of running on at full speed: a stall with a stop in it overshoots 15 cm instead
  of 80, but every other stall then stops the ghost and makes it sprint to catch up (its speed off by 490 cm/s instead of 200).
  Stalls are mostly the partner just running on, so the guess runs on as before, for at most 160 ms.
- Sending from the relay thread at a fixed rate: the game has one new position a frame, so a timer only adds waiting. On a
  60 Hz timer the partner showed 11 ms further behind than with each frame sent at once, on a 125 Hz one 5 ms.

Enemy copies (`puppets.lua` carries the host's last line forward from when it was read): measured where a copy is steered to,
10 lines a second today, they show 61 ms behind and run on 19 cm past a stop typically (59 at worst). Carrying the line on by
half the round trip shows them 11 ms behind but doubles that overshoot; 20 lines a second cuts it to 7 cm (45 at worst) at no
delay; 30 a second with half the round trip is 10 ms behind, about as smooth as today (24 cm past a stop typically against
19, 41 cm back at worst against 49). A line rate above 10 is more work for every enemy on the host's game thread each turn,
so that needs the real game's frame time first (`PERF.stages`), and nothing about enemies changed here.

Since then (11-05, six-players): **30 lines a second**, no carrying on. `run_enemy` over RTT 30/80/150/250 ms, 10 ms jitter,
1% loss, six enemy paths each: the delay stays where it was (56 ms behind at RTT 80), and a stop runs on 3-4 cm typically
instead of 18-21 (20 a second: 6 cm), 29-50 cm at worst instead of 67-71. Carrying the line on by half the round trip still
doubles the overshoot at every rate, so it stays off. On the bench host (host and guest copies on one PC, 12 thugs spawned
around the host, `PERF.frames` and `PERF.profile` for 12 s at each rate, twice): `link.enemy` went from about 1,300 calls to
3,500, the enemy work from about 4.5 to 6.8 ms of game thread a second, and the frames didn't move (59-60 FPS, 16-17 ms
typical, 23-25 at the 99th percentile, none over 50 ms at 30 a second). `net.enemyRoundS` overrides the rate from a dev eval.

## Moves over a long, lossy link (11-05)

**A move starts as far in as it really is old.** A move (`U`, `A`, an edge weapon's `Z`) used to start at its position plus half
the round trip from the status line: that missed the wait for the game's next tick (about 9 ms, always), each packet's jitter,
and a repeat sent because the first copy was lost. Now the relay works out each quick event's age when it lands: how long the
sender held it (its age on the wire), how much later this packet came than the fastest lately, and half the shortest round
trip; the Mailbox adds its own wait and hands it over as `~<ms> <event>`, and `net.moveAge()` is what the montage starts from.
Measured through real sockets and netem, the bots knowing the true age from the clock they share (`bench.ps1`, p50 / p95 / p99
of how far off):

| | half the round trip (before) | the move's own age (now) |
|---|---|---|
| RTT 150, clean | 0.9 / 15 / 16 ms | 0.5 / 1.2 / 1.3 ms |
| RTT 150, 10 ms jitter, 2% loss | 10 / 25 / 27 ms | 0.7 / 1.7 / 1.9 ms |
| RTT 150, 30 ms jitter, 5% loss | 11 / 30 / 32 ms | 1.7 / 4.4 / 6.0 ms |
| RTT 200, 30 ms jitter, 5% loss | 14 / 19 / 31 ms | 2.1 / 3.0 / 8.0 ms |
| RTT 250, 10 ms jitter, 2% loss | 6 / 20 / 22 ms | 1.3 / 2.4 / 2.7 ms |
| RTT 250, 30 ms jitter, 5% loss | 10 / 27 / 40 ms | 2.0 / 2.7 / 3.1 ms |

In the real game (two bench copies through netem: RTT 220 ms, 20 ms jitter, 2% loss; `badnet.ps1` with the montages recorded,
`move_report.py`), seven attacks each way: the ghost's montage was 2.7 and 1.4 ms behind the real player's on average, 7.8 ms
at worst. The same moves started at half the round trip would have been 11.6 and 13.1 ms behind, 27.5 at worst: each came 116-135
ms old, against the 110 that half the round trip said. `processEvents` costs 1.0 ms of game thread a second, 0.017 ms a call.

A route slower one way than the other stays a guess for both: no echo can tell which way the time went (a model with one way
taking 70% of the round trip: 30-50 ms off at RTT 150-250, either way). A party's host passes a guest's move on with the age it
has, and the next hop counts on from there.

Enemy attacks don't start further in: an ability replays from its own start on the guest's copy, so the guest sees the whole
wind-up, and a dodge, guard or parry is judged against that copy on their own PC, at any ping. Starting it by its age would cut
up to 125 ms of the telegraph at RTT 250. Only a montage the ability doesn't play, or a later step of a chain, starts by its age.

**A move's three copies go at 0, 40 and 120 ms, not a frame apart.** Wi-Fi loses packets in bursts: one longer than two frames
took all three. Through netem, losing 5% of the time in bursts, 50 moves a second for 15 s each way, RTT 80:

| bursts of about | a frame apart (before) | 40 ms apart | 0, 40, 120 ms (now) |
|---|---|---|---|
| 20 ms | 0 of 420 lost | | |
| 50 ms | 6 lost (1.4%) | 0 | 0 |
| 100 ms | 16 lost (3.8%) | 9 | 0 |
| 200 ms (a stall, really) | 27 lost (6.4%) | 14-15 | 17 |

The same three copies, so no more bytes. A move that only gets through on a later copy starts that much further in, so it's still
in step. The sure lane lost nothing in these runs (it resent after 1.5 round trips plus 15 ms: 194 ms at the 95th percentile
here); for its resends since, see the next part.

**Bandwidth, enemies 30 times a second.** The host's upload (`party-bench.ps1`, bots, 12 s): 3 guests with 8 enemies 61 KB/s at
20 a second, 68 at 30; with 30 enemies 112 and 139. Six players (5 guests) at 30 a second: 153 KB/s with 8 enemies, 265 with 30,
about 2.1 Mbit/s up. Two players with 30 enemies is about 0.5 Mbit/s.

**An enemy line goes when it says something new.** In recordings of real fights 88-99% of enemy samples said what the one
before did (most enemies stand most of the time), and each still went out 30 times a second. Now a line that says the same
as the last goes again only every 0.25 s (`net.enemySameS`), and a changed one at once, so a moving or hit enemy is no later.
The guest lets a copy go after `ENEMY_STALE_S` plus two of those gaps without a line, or one standing still was let go just
before a quiet link counted as quiet. Two players standing by two enemies in the Lua sim: the host's enemy lines 52.8 a
second, 2.1 KB/s, before; 7.2 a second, 0.3 KB/s, now. With the recordings' share of standing enemies, a party's upload in a
fight should fall by most of its enemy part (about 150 of the 265 KB/s with 6 players and 30 enemies; the party bench's bots
send their lines by themselves, so that is worked out, not measured).

**A guest's hit.** The guest's own hit already shows at once on their copy: the game's own flinch, sparks, sound and health bar,
and the bar isn't pulled back while the host catches up (`healTicks`). What waits a round trip is a kill: the copy is held at 1
health till the host says `K`, about RTT + 50 ms (200 ms at RTT 150). Showing a death before the host says so would let a guest
decide one, so nothing changed; a dying pose held till `K` comes is for the real game to try.

**Steam's route.** When Steam relays the connection, the player is told once a game that it adds delay and that SteamDirect = On
on both PCs gives a direct one where routers allow (`status.lua`). Relay against direct ping needs two real accounts.

## What goes with the place, and what the lanes carry (1.6.5)

Measured in the Lua sim (`luasim four` checks, each one failing on the code before) and, for the sure lane, through real sockets
and netem. Frames are 60 FPS frames.

**The place goes first in a frame.** `sendPlayer` runs before the partner's events and enemies are handled: a costly event (a
montage loaded, a search) no longer holds this frame's place back and stamps it late.

**Health, gait, guard stance and "in a move" ride on every place.** Health comes from the same read as the place (`game.read`
returned it all along), not from ten slow reads a second: a guest knows the host's hit 4.0 frames after it in the sim, every
time, where it was 7.3 on average and 10 at worst (the 4 are the sim relay's own 20 ms). Gait and the guard stance went as sure
events (`GAIT`, `ST`), ahead of the steps they belong to or, after a loss, well behind them, and in the queue ahead of deaths;
now they are bits of the state's flags, played in step with the place, and a lost packet is made good by the next. A stance
heard after its enter's own hold was due (it comes with the place, played behind) is held from where the enter is. Bit 0x80
says the player is in a move: should all three copies of a move's end (`U - 0`) be lost in a burst, a move that began before
it ends once that bit has been off for 0.3 s (longer than the place is played behind, so a move whose `U` came first isn't
cut). No new event: an older version's places say none of this and change nothing, and its `GAIT`/`ST` are still taken.

**Moves and staggers go in the frame they start.** The move watch ran every other frame and the hit state ten times a second;
both run every frame now (whose hit component it is is still checked ten times a second). From start to send, 60 tries each:

| | before: mean / worst | now |
|---|---|---|
| a move (`U`) | 0.42 / 1 frame | 0 / 0 |
| a stagger (`H`) | 2.70 / 5 frames | 0 / 0 |
| health on the partner's PC | 7.32 / 10 frames | 4.00 / 4 |

A move's position already said how far in it was, so this is a move's start skipped less, up to a frame. `H` now uses its age:
the ghost's copy of a stagger is held for what's left of the partner's 0.9 s, and one already over isn't played. The cost: two
game calls more a frame (a party of 2: host 94.2 -> 96.2, guest 134.3 -> 136.3).

**Told when it changes.** The host's rules (`RULES`, every 5 s) and what each player wears (`LOOK`, every 30 s) went again on a
timer the sure lane made pointless; they go when they change and to whoever starts sync or joins (an `S` reaches the host). A
guest joining a party followed the host's rules 1.62 s after joining (the next of those tellings), 0.05 s now, and in 31 s with
nothing changed nothing goes again (9 tellings before). Kept on purpose: `F` in a boss fight every 5 s (the host's own re-tell
after a gap is the host's alone, and a guest's fight after a one-way outage the host counted as gone has only this), `HAS` (a
question whose answer changes), `STORYPT`/`GSTORY` (the receiver acts only on a point heard in the last 150 s).

**Shots.** A shot's end goes by the sure lane, the shot by the quick one: with its first copies lost, the end could come first,
find nothing, and the copy then looped for 30 s. An end that finds nothing is kept 2 s and its shot isn't fired. A look's ends
go as one `SHOTEND id id ...` (eight ending together: one event, was eight); a weapon of flowers put up to 40 a second on the
sure lane, now at most 10. An older version reads only a single id, and its copies of the rest end after 30 s.

**A lost sure event goes again about a round trip after it was sent.** It waited for `retry_s` (1.5 round trips and 15 ms),
however soon the partner's acknowledgement showed the gap; `lanes.hpp`'s header already said it didn't. Now an event the
acknowledgement passes over (something sent after it confirmed, it not) goes again once `lost_after_s` has gone by since it was
sent: 1.125 round trips, and at least the round trip and 10 ms, so a packet merely overtaken on the way by up to an eighth of a
round trip isn't sent twice. With nothing sent after it to show the gap, it still waits for `retry_s`. The status line has
`resent_early=`. Through netem, events 40 a second, 60 s a run, the old and new relay taking turns (`bench.ps1`, two rounds
each; the quick lane is the control and didn't move), sure event lateness p95 / p99:

| | before | now |
|---|---|---|
| RTT 150, 10 ms jitter, 2% loss | 279-288 / 350 ms | 224-227 / 287-290 ms |
| RTT 80, 10 ms jitter, 5% loss | 198-210 / 275-294 ms | 167 / 198 ms |
| RTT 150, 100 ms bursts 2% of the time | 107-272 / 347-367 ms | 141-185 / 276-319 ms |
| RTT 30, 3 ms jitter, 2% loss | 46 / 106-107 ms | 46 / 106 ms |

At RTT 30 the next event's acknowledgement comes about when `retry_s` does anyway, so nothing changes there. Resends: 418 in
the eight minutes of the old relay's runs, 497 in the new one's, some of them copies of an event only overtaken under 10 ms of
jitter: a few bytes a second.

**Findings 1, 3 and 9, looked at again.** What was kept and what was put right, each fix with a `luasim four` check that
fails on the code before it:
- 1, a re-told death handled before returns at once. Right for a copy back alive near this player (it's in `enemyByName`
  under its own id, so it goes the whole way), and the batch's spawner map keys as the search did. Put right: a load from the
  title screen now puts the host's kills down again as their copies load (as this player's death did), where a copy back
  alive out of reach at the re-tell was passed over and stood for good (the old whole way had left a pending death for it);
  the batch's map takes the first live spawner of an id, not one still listed as its level goes; and a batch never ended is
  let go after half a second instead of being used by the next turn that asks.
- 3, the revive gauge. `G` goes when the partner's ring would change: a step of the bars, a step of the timer, a strike, and
  once a second at least. By whole seconds and 3% of the gauge, the partner's timer ring jumped one step or two once a second
  (24, 22, 21, 19, 17, 16 over 5 s), where the downed player's own went a step every 0.625 s; now a step at a time, 10 `G` in
  the first 6 s down where it was 6 (and 30 before that, five a second). The time and gauge go to a hundredth, or a step just
  taken read as the one before it. A down's first `STRIKE` counts whole: timed by the striker from a swing at the down before,
  0.3 s before, it counted 6 points of 20. A huge `STRIKE` time is capped at a whole hit, and an older version's bare one is
  timed by arrival, as it was.
- 9, `NQ`: kept as it is. A number always stands for the same enemy (`enemyNumbers` is never cleared, and an `S` only has
  them told again), a quick copy from before a restart never gets past the relay's session check, `N` after `NQ` says the
  same thing again, and in a party only the host numbers enemies (handover is two players only).

**No lane of its own for values only the newest of which counts.** The idea was to take `G`, `GAIT`, `ST`, `LOOK`, `F` and
`RULES` off the ordered lane, so that a lost one holds up no death. After the changes above there is next to nothing left to
take: in the Lua sim, four players fighting by a dozen enemies for 40 s sent 12 of these in 141 sure events (8.5%; `RULES` was 8
of the host's own 21) before, and 0 in 129 now. `GAIT` and `ST` are bits of the place, `RULES` and `LOOK` go when they change.
`F` must stay in order with `B` and `K`: an `F 0` overtaking a held-up `B` leaves a boss bar up for good (`handlers.F` tells of
that very case). `G` only goes with `Revive = On` while a player is down, and then that player has few other events of their
own to hold up. A lane for it would have meant protocol 5, a path through the party's hub and another call from Lua.

## What a lost packet costs (after 1.7.3)

Measured with `tools/netlab/netsim.ps1`: the real relay, both ends, in simulated time, so an hour of play takes seconds and
the old and new code meet the same connection, made from the same seed. The traffic is the mod's as the Lua sim and
recordings count it: a place every frame at 60 FPS, two sure and four quick events a second from each player, eight enemies
that move 15% of the time and change health every two seconds each. What was found on 1.7.3, two players, an hour each:

| | no loss | 2% loss |
|---|---|---|
| A sure event (a kill, a hit, a pickup), typical / slowest 1%, ping 80 | 54 / 72 ms | 54 / 206 ms |
| ... ping 150 | 89 / 106 ms | 89 / 347 ms |
| ... ping 250 | 149 / 170 ms | 150 / 580 ms |
| A move (quick), slowest 5%, ping 80 | 64 ms | 65 ms |
| The partner's figure behind, ping 80 | 64 ms | 64 ms |
| An enemy's health on the guest, typical / slowest 1%, ping 80 | 79 / 134 ms | 80 / 337 ms |
| An enemy copy's run past a stop, typical / worst 1%, ping 80 | 3 / 29 cm | 3 / 70 cm |

The typical numbers are the trip and the wait for the next frame, and nothing is left to take off them. What loss costs is in
the last column: the place and the moves shrug it off (the next place, three copies), a sure event and an enemy's line don't.

**A sure event goes again before any loss is known.** In a fight a player's sure events come one at a time, a second or more
apart (141 in 40 s from four players), so nothing sent after a lost one shows the gap, and it waited out `retry_s`: a round
trip and a half and 15 ms, with the guest's copy of a dying enemy standing at 1 health meanwhile. Now, while eight or fewer
wait, an unconfirmed event goes again 14, 42 and 98 ms after it was sent (`SURE_COPY_GAP`, `SURE_COPIES`): the first under a
frame at 60 FPS, so it rides in the next frame's packet, the last far enough out to outlast a burst of Wi-Fi loss. A copy
rides in a packet that goes anyway (alone it waits 20 ms more), and the acknowledgement for an event that came before waits
for the next frame's packet too (`ACK_WAIT_AGAIN`), so the copies add no packets, only their 47 bytes. They are on top of
what was there and change none of it: when an event is taken for lost still counts from when it was sent, and the relay
asks for the copies last, after everything else a packet carries, so a copy takes only the room that's left, never starts a
packet while it rides, and holds nothing up (`SureSender::for_each_copy`). Only an event of 400 bytes or less has copies
(`SURE_COPY_BYTES`): a guest's hit with the flinch it made (`D`: the montage's path and the hit state) is 190-280 bytes, and
a long one is a list told at a join, whose copies would be packets of their own. (At 200, till 11-16, that hit had none.) A long queue (a join, a re-tell) goes once each as before: its gaps show in the acknowledgements at once.
An older version drops a copy as it drops any event it has had, so copies alone would mix with 1.7.3. The protocol is 5
all the same from this version on: a party's enemy line says "asleep" in its boss field (2, and 3 for a boss), which a
1.7.3 guest read as a thug's and brought a beaten boss back by, and a boss's win goes out whole, which a 1.7.3 guest on
another level marked done where it stood (BUGHUNT 302). So 1.7.3 and this version don't link. A host of this version
answers a 1.7.3 guest's knock with its own header, once a second at most, so both are told that both PCs need the same
version (BUGHUNT 334); a guest of this version at a 1.7.3 host hears nothing back (that host is told), and is told to
check the address. (While they did, the review of 11-13 counted 3.5-8.8% more packets from the 1.7.3 side of a mixed
pair: a 1.7.3 partner hurries an acknowledgement for each copy.)

Two players, an hour of simulated play on each connection, 1.7.3 against this (sure events, host to guest):

| ping, jitter, loss | slowest 1% | slowest 0.1% | worst | over 30 ms late | bytes a second, host / guest |
|---|---|---|---|---|---|
| 30 ms, 3 ms, none | 40 -> 39 ms | 122 -> 122 | 137 -> 137 | 0.7 -> 0.7% | 11.9 -> 12.0 / 7.3 -> 7.4 KB |
| 30 ms, 3 ms, 2% | 95 -> 49 ms | 125 -> 122 | 158 -> 137 | 2.8 -> 0.7% | 11.9 -> 12.0 / 7.3 -> 7.4 KB |
| 80 ms, 10 ms, 1% | 162 -> 80 ms | 219 -> 137 | 324 -> 172 | 1.8 -> 0.6% | 11.9 -> 12.1 / 7.3 -> 7.5 KB |
| 80 ms, 10 ms, 2% | 206 -> 82 ms | 219 -> 137 | 375 -> 172 | 2.7 -> 0.6% | 11.9 -> 12.1 / 7.3 -> 7.5 KB |
| 80 ms, 10 ms, 5% | 214 -> 94 ms | 363 -> 141 | 512 -> 188 | 6.7 -> 0.8% | 11.9 -> 12.1 / 7.3 -> 7.5 KB |
| 150 ms, 10 ms, 2% | 347 -> 114 ms | 360 -> 188 | 617 -> 213 | 3.9 -> 0.6% | 11.9 -> 12.2 / 7.3 -> 7.6 KB |
| 150 ms, 30 ms, 5% | 400 -> 134 ms | 681 -> 192 | 953 -> 213 | 7.6 -> 0.6% | 11.9 -> 12.2 / 7.3 -> 7.6 KB |
| 250 ms, 30 ms, 2% | 580 -> 175 ms | 612 -> 243 | 1349 -> 273 | 4.0 -> 0.4% | 11.9 -> 12.2 / 7.3 -> 7.6 KB |
| 80 ms, bursts of 60 ms 3% of the time | 211 -> 137 ms | 222 -> 179 | 368 -> 231 | 4.5 -> 2.7% | 11.9 -> 12.1 / 7.3 -> 7.5 KB |
| 150 ms, bursts of 100 ms 2% of the time | 347 -> 196 ms | 363 -> 342 | 612 -> 360 | 3.5 -> 2.2% | 11.9 -> 12.2 / 7.3 -> 7.6 KB |
| 80 ms, 20 ms, 2%, a 250 ms stall every 7 s | 256 -> 243 ms | 313 -> 298 | 462 -> 329 | 5.4 -> 3.6% | 11.9 -> 12.1 / 7.3 -> 7.5 KB |

("Over 30 ms late": read more than 30 ms after the slowest trip and a frame's wait.) With 5% loss the slowest twentieth
moves too: 195 -> 67 ms at ping 80, 305 -> 117 at ping 150. The typical event, the quick lane and the partner's figure don't
move, nor does the number of packets (103 a second from the host, 74 from the guest). With events one at a time, two hours each (`-Set lone`): 208 -> 82 ms at ping 80 with 2% loss,
350 -> 113 at 150, 585 -> 177 at 250. A stall is the one thing copies can't help: everything sent in it waits for its end.

Through real sockets and netem, the 1.7.3 relay and this one side by side, an event every half second for five minutes
(`bench.ps1 -EventEvery 0.5`, the code as it stands after the review): ping 160 with 2% loss, the slowest 1% 344 -> 100 ms
and the worst 344 -> 116; ping 92 with 5% loss, the slowest 5% 208 -> 60, the slowest 1% 210 -> 76 and the worst 360 -> 110.
Packets sent by the guest's end in the five minutes: 20,171 and 19,988 on the first connection, 20,087 and 20,169 on the
second.

The status line has `copied=`: copies sent, which `resent=` doesn't count.

**An enemy's line goes again after it said something new.** A line goes once, and a lost one isn't sent again. While an
enemy moves, the next turn's line makes a lost one good. But the last line of a change (it stopped; it was hit as it stood)
had only the line every quarter second after it (`net.enemySameS`): with 2% loss, one stop in a hundred ran on 70 cm on the
guest's screen and came back, and one change of health in a hundred showed a third of a second late. Now a line that says
the same as the last goes again the turn after it first went, and once more two turns after that (`net.enemyAgain`), and
only then is left to the quarter second. It's three lines for a change where there was one, so more lines only where
something happened: 55 -> 61 a second in netsim's fight of eight enemies, 12.1 -> 12.5 KB/s from the host. The guest reads
a line that says the same as it reads any other: nothing changes there, and an older version takes them as it is.

netsim, an hour each, eight enemies that move 15% of the time and change health every two seconds; the rule in `netsim.cpp`
is the Lua's (`--enemy-rule 0` and `1`), and the Lua itself is in `luasim four`'s part. 1.7.3's rule -> this:

| ping, jitter, loss | a copy past its stop, worst 1% | ... worst | a change of health shows, slowest 1% | ... slowest |
|---|---|---|---|---|
| 30 ms, 3 ms, none | 27 -> 25 cm | 75 -> 75 cm | 102 -> 101 ms | 230 -> 230 ms |
| 30 ms, 3 ms, 2% | 74 -> 30 cm | 141 -> 97 cm | 302 -> 116 ms | 605 -> 230 ms |
| 80 ms, 10 ms, 1% | 62 -> 29 cm | 137 -> 113 cm | 180 -> 140 ms | 436 -> 237 ms |
| 80 ms, 10 ms, 2% | 76 -> 31 cm | 151 -> 87 cm | 344 -> 145 ms | 602 -> 246 ms |
| 80 ms, 10 ms, 5% | 81 -> 40 cm | 150 -> 96 cm | 368 -> 155 ms | 927 -> 263 ms |
| 150 ms, 10 ms, 2% | 76 -> 31 cm | 151 -> 109 cm | 372 -> 180 ms | 671 -> 284 ms |
| 150 ms, 30 ms, 5% | 93 -> 44 cm | 149 -> 117 cm | 412 -> 201 ms | 713 -> 512 ms |
| 250 ms, 30 ms, 2% | 72 -> 37 cm | 152 -> 72 cm | 440 -> 244 ms | 752 -> 347 ms |
| 80 ms, bursts of 60 ms 3% of the time | 76 -> 46 cm | 147 -> 87 cm | 352 -> 176 ms | 904 -> 463 ms |
| 150 ms, bursts of 100 ms 2% of the time | 68 -> 53 cm | 151 -> 149 cm | 378 -> 220 ms | 690 -> 594 ms |
| 80 ms, 20 ms, 2%, a 250 ms stall every 7 s | 75 -> 55 cm | 146 -> 138 cm | 347 -> 252 ms | 684 -> 361 ms |

(The connections' numbers above and below were run again on the code as it stands after the review, `notes/netcode/73` on
the branch: the same within a few ms.)

The typical stop (3 cm past) and the typical change of health (the trip, a turn and a frame: 80 ms at ping 80) don't move,
nor how far behind a copy is played (57 ms at ping 80). One repeat instead of two gave the same worst 1% but not the
worst: at ping 80 with 2% loss a change of health 410 ms late at worst against 246, a stop 139 cm past against 87.
Found on the way: a turn comes every 1/30 s only when two frames add up to it, which at a steady 60 FPS they do half
the time, so a moving enemy's lines are nearer 24 a second than 30 (20 in the Lua sim, whose frames are exact). Left as
it is: the turn's cost on the host was measured at that rate.

**Where the other guests are rides in the host's own packets.** A party's host passes each guest's place on to the others
"at most 60 times a second: it mostly rides along", but it only went once `PLAYERS_EVERY` had passed since the last, riding
or not, and so mostly in a packet of its own: 59 bytes of headers, 60 times a second, to every guest. Now it goes in any
packet that goes anyway (the host's own place each frame, an enemy line, an event), and by itself only when none has gone
for `PLAYERS_EVERY`, as with the host's game standing in a load. A place waits less for its ride than it waited for its
turn, so a guest sees another guest sooner.

Each guest's place still goes on 60 times a second at most, by a budget of its own that fills 60 times a second and holds
two (`PLAYERS_SAVED`: the trip bunches a 60 FPS guest's places, and two close together both go). The first form of this
change (e82c253) let every place ride: at 60 FPS, where all of it was measured, that is 60 a second, but a guest above 60
FPS sends up to 125, and the host's upload with six players at 120 FPS went from 174 to 205 KB/s. The review of 11-13 found
it; with the budget it is 175, and a place that has none left waits, the newest in its place, for the next packet.

netsim, five minutes each, ping 80 with 10 ms jitter and 1% loss, 8 enemies, every player at the same frame rate, 1.7.3 ->
now (with the copies and the enemy lines' repeats, which are what the upload gains at 60 FPS):

| players, FPS | packets a second from the host | the host's upload | a guest's figure on another guest's screen, behind |
|---|---|---|---|
| 3, 60 | 295 -> 276 | 34.7 -> 35.4 KB/s | 122 -> 116 ms |
| 3, 120 | 416 -> 396 | 46.9 -> 47.5 KB/s | 117 -> 116 ms |
| 4, 60 | 475 -> 405 | 61.6 -> 61.9 KB/s | 124 -> 119 ms |
| 4, 120 | 664 -> 599 | 81.4 -> 81.5 KB/s | 118 -> 116 ms |
| 6, 60 | 906 -> 762 | 137.0 -> 140.3 KB/s | 124 -> 118 ms |
| 6, 90 | 1100 -> 944 | 158.3 -> 159.9 KB/s | 119 -> 117 ms |
| 6, 120 | 1248 -> 1100 | 174.0 -> 175.0 KB/s | 117 -> 116 ms |
| 6, 144 | 1275 -> 1124 | 175.5 -> 176.9 KB/s | 118 -> 117 ms |

A guest's sure event reaches another guest sooner too, the copies working on both hops: the slowest 1% 252 -> 124-132 ms.
The figure's speed is as steady as it was (off by 103 cm/s at the 95th percentile, 102 before), the host's figure on a
guest's screen and a guest's on the host's are where they were (64 ms), and a guest's upload is 7.3 -> 7.5 KB/s at any
size. The host's upload is still what a big party costs: each guest gets every other guest's place, 42 bytes, 60 times a
second, 10 KB/s a guest with six players. A shorter place would take a new protocol.

**In the real game** (two copies on the bench, 11-13, 1.7.3's scripts and main.dll against these, the guest through
`relay_cli netem` at 75 ms each way, 10 ms jitter, 5% loss; both copies on one PC's clock). The host's game sent 600 sure
events about 0.3 s apart through the mod's own `sendEvent`, and took the nearest enemy's health down a little 400 times about
half a second apart, a hit on an enemy that stands; the guest's game timed each as it read it:

| | 1.7.3 | now |
|---|---|---|
| A sure event, typical / slowest 5% / slowest 1% / worst | 84 / 113 / 351 / 616 ms | 84 / 100 / 106 / 132 ms |
| ... over 60 ms later than the typical one | 29 of 600 (4.8%) | none |
| ... sent again by the relay for a loss, and copies | 31, none | 1, 1,890 |
| A change of an enemy's health, typical / slowest 5% / slowest 1% / worst | 123 / 153 / 400 / 433 ms | 121 / 154 / 184 / 274 ms |
| ... over a quarter second late | 15 of 400 (3.8%) | 1 (0.2%) |
| Enemy lines in a minute: saying something new / the same; of those within 150 ms of the one before | 121 / 586; 0 | 118 / 776; 231 |
| The mod's net loop on the game thread, host / guest (`PERF.stages`, a minute of walking and swinging) | 80.0 / 89.8 ms/s | 80.3 / 88.7 ms/s |
| Frames, typical / 95th / 99th percentile, host; guest | 17 / 21 / 24; 17 / 20 / 25 ms | 17 / 21 / 25; 17 / 21 / 25 ms |

On a clean link (loopback, 1 ms): a kill by the host reached the guest's copy in 19 ms (18 in 1.5.0's table), the ghost kept
within 2-3 cm of its path typically (12-14 at worst), and no copy was sent at all in the session (`copied=0`): the
confirmation is back before the first is due. No error from the mod in any run. A party of four (the host's copy with
`PartySize = 4`, the guest's, and two `relay_cli bot client` players walking beside them, loopback): the host sent a guest
114 packets a second before and 101 now, and 31 KB/s in all both times. Loopback has no jitter, so two guests' places kept
their moments in the host's frame and half still went by themselves; through netem's jitter (40 ms each way, 10 ms jitter,
1% loss, bots, `party-bench.ps1`) it was 163 -> 141 a second with three guests and 205 -> 179 with five.

What the copies cost shows where sure events are many: those bots say ten a second each, far over a fight's, and there
the host's upload rose by a tenth (145 -> 160 KB/s with five guests). At netsim's two a second from each player a party of
six sends 140.3 KB/s where 1.7.3 sent 137.0, the enemy lines' repeats counted in (the table above).

The bench ran the branch as it was before the review of 11-13 (the copies went with the sure events at the front of a
packet, and every guest's place rode): what changed since is where in a packet a copy goes, which events have one, and
how often a place goes on above 60 FPS. netsim's numbers for two players are the same before and after.

**What the frames cost, measured on the way** (`PERF.stages`, 1.7.3, three thugs near, both players walking and swinging):
80 ms of game thread a second on the host and 90 on the guest, 1.3-1.5 ms a frame at 60 FPS. The enemies' turns take 20 and
17 ms/s, the slow watch 15 and 16 (1.7 ms nine times a second, 37-45 ms at worst: the pickup and chest searches), steering
the partner's figure 15 and 15 (a quarter millisecond a frame for three calls into the game), the move watch 6 and 7, the
guest's copies 7. None of that changed here: it's the next thing to take up, a stage at a time, on the bench.

## Testing

See `tools/netlab/README.md`. `relay_cli test` is the logic, `tools/netlab/netsim.ps1` is the relay over bad connections in
simulated time, an old version beside a new one, `tools/netlab/bench.ps1` is two relays through a bad connection in real
time, and `tools/netlab/bench\` drives real game copies from a separate install.
