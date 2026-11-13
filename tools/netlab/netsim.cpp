// What a connection does to what the mod sends, in simulated time, with the real relay: netsim.ps1 builds this against two
// versions of native/ and runs the same sessions on both, so a change shows as numbers on the same connections, seed for seed.
//
// Every player has a game thread (frames as the real game's come, coop.lua's order inside one) and a relay thread (woken by a
// post or a packet, else every TICK), and between each guest and the host a connection with delay, jitter, loss, bursts of
// loss and stalls. The relay's own clock is this file's: an hour of play runs in seconds, and the same seed gives the same
// run. What it measures, against the truth it made up itself:
//   sure / quick   how long after the sender's game posted an event the receiver's game read it
//   partner        which moment of a player's true path their figure shows on another PC (latency.hpp's measure)
//   enemy          where a guest's copy is steered to against where the host's enemy is, how far it runs on past a stop,
//                  and how long a change of health takes to show
//   bytes          what each player sends, with the 28 bytes UDP and IP add to every packet
// The traffic is a model of the mod's: the rates below are from recordings and the Lua sim, and each can be set.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

// The relay asks Windows for the time through these two: here they tell this file's time.
namespace sim {
inline double clock_s = 1000.0;
inline BOOL counter(LARGE_INTEGER* c) {
    c->QuadPart = static_cast<LONGLONG>(clock_s * 1e7 + 0.5);
    return TRUE;
}
inline BOOL frequency(LARGE_INTEGER* f) {
    f->QuadPart = 10000000;
    return TRUE;
}
}  // namespace sim
#define QueryPerformanceCounter sim::counter
#define QueryPerformanceFrequency sim::frequency

#include "relay.hpp"
#include "latency.hpp"

#include <queue>
#include <random>

namespace {

using relay::Addr;

constexpr double STEP_S = 0.00025;          // the simulation's own step
constexpr double UDP_IP_BYTES = 28;
constexpr double ENEMY_ROUND_S = 1.0 / 30;  // coop.lua's
constexpr double ENEMY_AHEAD_S = 0.2;       // puppets.lua's AHEAD_S
constexpr double SEND_RATE = 125;           // coop.lua's
constexpr double WORLD_X = -103000, WORLD_Y = 245000, WORLD_Z = 1234;   // a place as far from the origin as the game's are

struct Options {
    int players = 2, enemies = 8;
    double seconds = 300, fps = 60;
    double rtt = 80, jitter = 10, loss = 0, burst_loss = 0, burst_ms = 50, stall_every = 0, stall_ms = 250, dup = 0;
    double sure_s = 2, quick_s = 4;        // events a second from each player
    double busy = 0.15;                    // the share of its time an enemy moves
    double hits_s = 0.5;                   // changes of health a second, each enemy
    int enemy_rule = 0;                    // how a line that says nothing new goes again: 0 as 1.7.3, 1 soon after a change too
    double same_s = 0.25;                  // coop.lua's net.enemySameS
    uint32_t seed = 1;
    bool lone = false;                     // sure events come one at a time, far apart: nothing after one to show a gap
};

double opt(int argc, char** argv, const char* name, double fallback) {
    for (int i = 1; i + 1 < argc; i++)
        if (std::strcmp(argv[i], name) == 0) return std::atof(argv[i + 1]);
    return fallback;
}

Addr at(uint32_t ip) {
    Addr a;
    a.ip = ip;
    a.port = 1000;
    return a;
}

// A star: every connection is between the host (ip 1) and one guest (its ip is its slot).
struct Net {
    struct Packet {
        double at;
        long long order;
        Addr from;
        std::string data;
        bool operator<(const Packet& o) const { return at != o.at ? at > o.at : order > o.order; }
    };
    struct Line {
        std::mt19937 rng;
        double burst_from = 1e18, burst_until = 0, stall_until = 0, next_stall = 1e18;
    };

    Options o;
    double now = 0;
    long long order = 0;
    std::map<uint32_t, std::priority_queue<Packet>> wires;    // by who it's for
    std::map<uint32_t, Line> lines;                           // by the guest's ip
    std::map<uint32_t, double> bytes, packets;                // by sender, since counting began
    bool counting = false;

    static double unit(std::mt19937& rng) { return std::uniform_real_distribution<double>(0, 1)(rng); }

    Line& line_of(uint32_t guest) {
        auto [it, fresh] = lines.try_emplace(guest);
        Line& l = it->second;
        if (fresh) {
            l.rng.seed(o.seed * 7919u + guest * 104729u);
            if (o.burst_loss > 0) l.burst_from = now + next_burst(l);
            if (o.stall_every > 0) l.next_stall = now + o.stall_every * (0.5 + unit(l.rng));
        }
        return l;
    }

    // Bursts start at random, as often as it takes for them to cover burst_loss of the time (relay_cli's netem does the same).
    double next_burst(Line& l) {
        const double burst_s = o.burst_ms / 1000, between = burst_s / (o.burst_loss / 100) - burst_s;
        return std::exponential_distribution<double>(1 / std::max(between, 1e-3))(l.rng);
    }

    void send(const Addr& from, const Addr& to, const std::string& data) {
        if (counting) {
            bytes[from.ip] += data.size() + UDP_IP_BYTES;
            packets[from.ip] += 1;
        }
        Line& l = line_of(from.ip == 1 ? to.ip : from.ip);
        while (now >= l.burst_from) {
            l.burst_until = l.burst_from + o.burst_ms / 1000 * (0.5 + unit(l.rng));
            l.burst_from = l.burst_until + next_burst(l);
        }
        while (now >= l.next_stall) {
            l.stall_until = l.next_stall + o.stall_ms / 1000;
            l.next_stall += o.stall_every;
        }
        if (unit(l.rng) * 100 < o.loss || now < l.burst_until) return;
        double arrive = now + (o.rtt / 2 + unit(l.rng) * o.jitter) / 1000;
        arrive = std::max(arrive, l.stall_until + o.rtt / 2000);
        wires[to.ip].push({arrive, order++, from, data});
        if (unit(l.rng) * 100 < o.dup) wires[to.ip].push({arrive + unit(l.rng) * 0.02, order++, from, data});
    }

    bool waiting(uint32_t ip) {
        auto it = wires.find(ip);
        return it != wires.end() && !it->second.empty() && it->second.top().at <= now;
    }

    std::vector<std::pair<Addr, std::string>> take(uint32_t ip) {
        std::vector<std::pair<Addr, std::string>> out;
        auto& wire = wires[ip];
        while (!wire.empty() && wire.top().at <= now) {
            out.emplace_back(wire.top().from, wire.top().data);
            wire.pop();
        }
        return out;
    }
};

class SimLink : public relay::Link {
public:
    SimLink(Net& net, const Addr& me, std::optional<Addr> host) : net_(net), me_(me) { peer = host; }
    void send(const Addr& to, const std::string& data) override { net_.send(me_, to, data); }
    std::vector<std::pair<Addr, std::string>> receive() override { return net_.take(me_.ip); }
    void wait(double, HANDLE) override {}
    std::string describe(const Addr& a) override { return "pc" + std::to_string(a.ip); }
    std::string describe_self() override { return "pc" + std::to_string(me_.ip); }
    const char* via() override { return "sim"; }

private:
    Net& net_;
    Addr me_;
};

struct Stat {
    std::vector<double> v;
    void add(double x) { v.push_back(x); }
    double pick(double p) {
        if (v.empty()) return 0;
        std::sort(v.begin(), v.end());
        return v[std::min(v.size() - 1, static_cast<size_t>(v.size() * p))];
    }
    double over(double limit) const {
        if (v.empty()) return 0;
        return 100.0 * static_cast<double>(std::count_if(v.begin(), v.end(), [&](double x) { return x > limit; })) / static_cast<double>(v.size());
    }
};

void into(lab::Pct& all, lab::Pct& one) { all.v.insert(all.v.end(), one.v.begin(), one.v.end()); }

void into(lab::Measures& all, lab::Measures& one) {
    into(all.behind, one.behind);
    into(all.now, one.now);
    into(all.path, one.path);
    into(all.step, one.step);
    into(all.speed, one.speed);
    into(all.overshoot, one.overshoot);
    into(all.back, one.back);
}

// An enemy as the host's game moves it: mostly it stands; now and then it chases, sidesteps, dashes and stops dead.
lab::Path enemy_path(double seconds, double busy, std::mt19937& rng) {
    const auto pick = [&](double a, double b) { return std::uniform_real_distribution<double>(a, b)(rng); };
    std::vector<lab::Leg> legs;
    double total = 0, heading = 0;
    const auto add = [&](lab::Leg leg) {
        legs.push_back(leg);
        total += leg.ms;
    };
    add({pick(200, 3000), 0, 0, lab::START, lab::HARD});
    while (total < seconds * 1000) {
        double moved = 0;
        heading = pick(-180, 180);
        const double chase = pick(1000, 2500);
        add({chase, heading, pick(350, 450), 3000, lab::QUICK, pick(-30, 30)});
        moved += chase;
        if (pick(0, 1) < 0.3) {
            const double side = pick(300, 500);
            add({side, heading + (pick(0, 1) < 0.5 ? 90 : -90), 200, lab::QUICK, lab::QUICK});
            moved += side;
        }
        if (pick(0, 1) < 0.2) {
            const double dash = pick(250, 350);
            add({dash, heading, 800, 20000, 20000});
            moved += dash;
        }
        // It stands for as long as keeps its moving share at busy, a little more or less each time.
        add({moved * (1 - busy) / std::max(busy, 0.01) * pick(0.6, 1.4), heading, 0, lab::START, lab::HARD});
    }
    return lab::walk_legs(legs);
}

struct Enemy {
    lab::Path path;
    std::vector<std::pair<double, double>> health;     // ms, the health from then on (the host's truth)
    size_t health_at = 0;
    double hp = 2000;
    // The host's side of coop.lua's net.sendEnemyLine.
    std::string last_text;
    double last_sent = -1e9;
    int repeats = 0;
};

// What one guest knows of one enemy (coop.lua's readEnemies, puppets.lua's steer).
struct Copy {
    bool have = false;
    double x = 0, y = 0, vx = 0, vy = 0, hp = 0, read_at = 0;
    std::vector<lab::Shown> shown;
    size_t health_seen = 0;       // how many of the enemy's changes of health have shown here
};

struct Player {
    int slot = 1;                 // which player this is here: 1 the host, then the guests in the order they were made
    int seat = 0;                 // a party's guest: the slot the host's hello gave it, which goes by who it heard first
    uint32_t ip = 1;
    relay::Mailbox box;
    std::unique_ptr<relay::Relay> relay;
    std::unique_ptr<relay::Party> party;
    lab::Frames frames{60, 1};
    std::mt19937 rng;
    lab::Path path;
    double next_frame = 0, rest_at = -1, last_frame = -1, frame_dt = 16.7, last_relay = 0, budget = 1, last_stamp = 0;
    bool woken = false;
    long long sure_sent = 0, quick_sent = 0;
    double next_lone = 0;
    std::map<int, std::vector<lab::Shown>> seen;           // by slot: where that player's figure was shown, frame by frame
    std::map<int, lab::Ghost> ghosts;
    std::map<int, std::vector<lab::Shown>> walked;         // and where the ghost walking after it was
    std::map<int, long long> next_sure;                    // by sender: the next sure event's number, to see order kept
    std::vector<Copy> copies;                              // a guest's: by enemy
    std::vector<std::pair<double, double>> hitches;
    // The host's enemy round (coop.lua's enemyTurns).
    size_t round_at = 0;
    double round_started = -1e9;
};

struct Results {
    Stat sure[3], quick[3], age_off;          // 0 host to guest, 1 guest to host, 2 guest to guest
    long long quick_lost[2] = {}, wrong_order = 0;
    lab::Measures partner[3], ghost[3];
    lab::Measures enemy;
    Stat enemy_hp;
    long long enemy_lines = 0;
};

int kind_of(int from, int to) { return from == 1 ? 0 : to == 1 ? 1 : 2; }

struct World {
    Options o;
    Net net;
    std::vector<std::unique_ptr<Player>> players;
    std::vector<Enemy> enemies;
    Results r;
    double start = 0;       // sim seconds at path time 0
    std::map<std::pair<int, long long>, int> quick_out;     // (sender, number) -> how many players have read it
    std::map<int, int> seated;                              // a party's slot -> which player has it

    // Which player the relay means by a slot: with two players the other one, in a party whoever the host gave it to.
    int player_at(int seat, const Player& asker) const {
        if (o.players == 2) return asker.slot == 1 ? 2 : 1;
        if (seat == 1) return 1;
        auto it = seated.find(seat);
        return it == seated.end() ? 0 : it->second;
    }

    double path_ms() const { return (sim::clock_s - start) * 1000; }

    explicit World(const Options& opts) : o(opts) {
        net.o = o;
        std::mt19937 rng(o.seed);
        relay::Ini ini;
        if (o.players > 2) ini["partysize"] = o.players > 4 ? "6" : "4";
        for (int slot = 1; slot <= o.players; slot++) {
            auto p = std::make_unique<Player>();
            p->slot = slot;
            p->ip = static_cast<uint32_t>(slot);
            p->rng.seed(o.seed * 1000003u + slot * 7u);
            p->frames = lab::Frames(o.fps, o.seed * 31 + slot * 3);
            p->path = lab::make_path("mix", o.seconds + 5, o.seed * 17 + slot);
            const auto log = [](const std::string&) {};
            if (slot == 1 && o.players > 2) {
                p->party = std::make_unique<relay::Party>(L".", std::make_unique<SimLink>(net, at(1), std::nullopt), nullptr, ini, "netsim", log, p->box);
            } else {
                p->relay = std::make_unique<relay::Relay>(slot == 1 ? "host" : "client", L".",
                                                          std::make_unique<SimLink>(net, at(p->ip), slot == 1 ? std::nullopt : std::optional<Addr>(at(1))),
                                                          nullptr, ini, "netsim", log, p->box);
            }
            p->copies.resize(o.enemies);
            players.push_back(std::move(p));
        }
        for (int i = 0; i < o.enemies; i++) {
            Enemy e;
            e.path = enemy_path(o.seconds + 5, o.busy, rng);
            double t = 0, hp = 2000;
            e.health.emplace_back(0, hp);
            std::exponential_distribution<double> next(o.hits_s > 0 ? o.hits_s : 1);
            while (o.hits_s > 0 && t < (o.seconds + 5) * 1000) {
                t += next(rng) * 1000;
                hp = hp > 200 ? hp - std::floor(std::uniform_real_distribution<double>(20, 120)(rng)) : 2000;
                e.health.emplace_back(t, hp);
            }
            enemies.push_back(std::move(e));
        }
    }

    void tick_relay(Player& p) {
        if (p.party) p.party->tick(sim::clock_s);
        else p.relay->tick(sim::clock_s);
        p.last_relay = sim::clock_s;
        p.woken = false;
    }

    // The first part of coop.lua's tick: this player's place goes out, then what has come is read.
    void frame(Player& p) {
        const double ms = path_ms();
        p.frame_dt = p.last_frame < 0 ? 1000 / o.fps : ms - p.last_frame;
        if (p.frame_dt > 35) p.hitches.emplace_back(p.last_frame, ms);
        // (The game moved the player at the frame's start; the mod's tick comes a few ms in, and that's the stamp.)
        const double stamp_off = std::min(p.frames.tick_offset(), p.frame_dt);
        p.budget = std::min(1.5, p.budget + (ms - p.last_stamp) * SEND_RATE / 1000);
        p.last_stamp = ms;
        if (p.budget >= 1) {
            p.budget -= 1;
            double x, y, vx, vy;
            p.path.at(ms - stamp_off, x, y);
            p.path.velocity(ms - stamp_off, vx, vy);
            relay::Sample s;
            s.ms = static_cast<uint32_t>(relay::clock_ms());
            s.x = static_cast<float>(x + WORLD_X);
            s.y = static_cast<float>(y + WORLD_Y);
            s.z = static_cast<float>(WORLD_Z);
            s.vx = static_cast<float>(vx);
            s.vy = static_cast<float>(vy);
            s.hp = 850;
            s.max_hp = 850;
            s.map = 77;
            s.flags = relay::FLAG_GROUNDED;
            p.box.post_sample(s);
            p.woken = true;
        }
        if (o.players > 2 && p.slot != 1 && !p.seat) {
            int size = 0, seat = 0;
            if (p.box.party(size, seat)) {
                p.seat = seat;
                seated[seat] = p.slot;
            }
        }
        read_events(p, ms);
        read_players(p, ms);
        if (p.slot != 1) read_enemies(p, ms);
        p.last_frame = ms;
        p.rest_at = sim::clock_s + std::uniform_real_distribution<double>(0.0003, 0.0012)(p.rng);
    }

    void read_events(Player& p, double ms) {
        const std::string text = p.box.take_events(relay::clock_ms());
        for (size_t pos = 0; pos < text.size();) {
            size_t end = text.find('\n', pos);
            if (end == std::string::npos) end = text.size();
            std::string line = text.substr(pos, end - pos);
            pos = end + 1;
            double age = -1;
            if (line.size() > 1 && line[0] == '~') {
                age = std::atof(line.c_str() + 1);
                line.erase(0, line.find(' ') + 1);
            }
            int from = p.slot == 1 ? 2 : 1;
            if (line.size() > 3 && line[0] == '@') {
                from = player_at(line[1] - '0', p);
                line.erase(0, 3);
            }
            if (!from || line.size() < 3 || (line[0] != 'E' && line[0] != 'Q')) continue;
            char* rest = nullptr;
            const long long number = std::strtoll(line.c_str() + 2, &rest, 10);
            const double posted = std::atof(rest);
            const double late = ms - posted;
            const int kind = kind_of(from, p.slot);
            if (line[0] == 'E') {
                auto& next = p.next_sure[from];
                if (next && number != next) r.wrong_order++;
                next = number + 1;
                if (posted >= 3000) r.sure[kind].add(late);
            } else {
                auto it = quick_out.find({from, number});
                if (it == quick_out.end()) continue;
                it->second++;
                r.quick[kind].add(late);
                if (age >= 0) r.age_off.add(std::fabs(age - late));
            }
        }
    }

    void read_players(Player& p, double ms) {
        // The relay's slots: with two players the partner; in a party the host is the partner of a guest, and everyone else
        // goes by the slot the host gave them.
        for (int seat = 1; seat <= o.players; seat++) {
            relay::Sample s;
            double silence = 0, delay = 0;
            bool got;
            int who;
            if (o.players == 2) {
                if (seat != 1) break;
                who = p.slot == 1 ? 2 : 1;
                got = p.box.partner(relay::clock_ms(), s, silence, delay);
            } else if (seat == 1) {
                if (p.slot == 1) continue;
                who = 1;
                got = p.box.partner(relay::clock_ms(), s, silence, delay);
            } else {
                who = player_at(seat, p);
                if (!who || who == p.slot) continue;
                got = p.box.player(seat, relay::clock_ms(), s, silence, delay);
            }
            lab::Ghost& ghost = p.ghosts[who];
            if (ghost.placed) {
                ghost.move(p.frame_dt);
                p.walked[who].push_back({ms, ghost.x, ghost.y});
            }
            if (!got) continue;
            s.x = static_cast<float>(s.x - WORLD_X);
            s.y = static_cast<float>(s.y - WORLD_Y);
            p.seen[who].push_back({ms, s.x, s.y});
            ghost.steer(s);
        }
    }

    void read_enemies(Player& p, double ms) {
        const std::string text = p.box.take_enemies();
        for (size_t pos = 0; pos < text.size();) {
            size_t end = text.find('\n', pos);
            if (end == std::string::npos) end = text.size();
            const std::string line = text.substr(pos, end - pos);
            pos = end + 1;
            int n = 0;
            double x, y, z, yaw, vx, vy, hp, max_hp;
            if (sscanf_s(line.c_str(), "%d %lf %lf %lf %lf %lf %lf %lf %lf", &n, &x, &y, &z, &yaw, &vx, &vy, &hp, &max_hp) != 9) continue;
            if (n < 0 || n >= o.enemies) continue;
            Copy& c = p.copies[n];
            c.have = true;
            c.x = x - WORLD_X, c.y = y - WORLD_Y, c.vx = vx, c.vy = vy, c.hp = hp, c.read_at = ms;
        }
        for (int i = 0; i < o.enemies; i++) {
            Copy& c = p.copies[i];
            if (!c.have) continue;
            const double ahead = std::min((ms - c.read_at) / 1000, ENEMY_AHEAD_S);
            c.shown.push_back({ms, c.x + c.vx * ahead, c.y + c.vy * ahead});
            // Each change of health on the host, once this copy's health says it. One the next change overtook before it
            // ever showed here isn't timed.
            Enemy& e = enemies[i];
            while (c.health_seen + 1 < e.health.size() && e.health[c.health_seen + 1].first <= ms) {
                const auto& change = e.health[c.health_seen + 1];
                const bool overtaken = c.health_seen + 2 < e.health.size() && e.health[c.health_seen + 2].first <= ms;
                const bool shows = std::fabs(c.hp - change.second) < 0.06;
                if (!shows && !overtaken) break;
                if (shows && change.first > 3000) r.enemy_hp.add(ms - change.first);
                c.health_seen++;
            }
        }
    }

    // The rest of the tick, a moment later: the events it made, and the host's enemies' turns.
    void rest(Player& p) {
        const double ms = path_ms();
        const double dt = p.frame_dt / 1000;
        const auto pick = [&](double a, double b) { return std::uniform_real_distribution<double>(a, b)(p.rng); };
        const auto event = [&](char lane, long long number) {
            char head[64];
            std::snprintf(head, sizeof head, "%c %lld %.3f ", lane, number, ms);
            std::string text = head;
            text.resize(std::max(text.size(), static_cast<size_t>(pick(20, 60))), 'x');
            return text;
        };
        if (o.lone) {
            if (ms >= p.next_lone) {
                p.next_lone = ms + pick(1500, 2500);
                p.box.post_sure(event('E', ++p.sure_sent));
                p.woken = true;
            }
        } else {
            for (int n = std::poisson_distribution<int>(o.sure_s * dt)(p.rng); n > 0; n--) {
                p.box.post_sure(event('E', ++p.sure_sent));
                p.woken = true;
            }
        }
        for (int n = std::poisson_distribution<int>(o.quick_s * dt)(p.rng); n > 0; n--) {
            p.box.post_quick(event('Q', ++p.quick_sent));
            p.woken = true;
            if (ms >= 3000 && ms < o.seconds * 1000 - 2000) quick_out[{p.slot, p.quick_sent}] = 0;
        }
        if (p.slot == 1 && !enemies.empty()) enemy_turns(p, ms, dt);
    }

    void enemy_turns(Player& p, double ms, double dt) {
        const size_t n = enemies.size();
        if (p.round_at >= n && ms - p.round_started >= ENEMY_ROUND_S * 1000) {
            p.round_at = 0;
            p.round_started = ms;
        }
        const size_t turns = static_cast<size_t>(std::ceil(static_cast<double>(n) * std::max(dt, 0.004) / ENEMY_ROUND_S));
        for (size_t i = 0; i < turns && p.round_at < n; i++, p.round_at++) {
            const int number = static_cast<int>(p.round_at);
            Enemy& e = enemies[p.round_at];
            // (Where the game put it this frame.)
            double x, y, vx, vy;
            e.path.at(p.last_frame, x, y);
            e.path.velocity(p.last_frame, vx, vy);
            while (e.health_at + 1 < e.health.size() && e.health[e.health_at + 1].first <= p.last_frame) e.health_at++;
            e.hp = e.health[e.health_at].second;
            const double yaw = std::hypot(vx, vy) > 1 ? std::atan2(vy, vx) * 180 / lab::PI : 0;
            char text[160];
            std::snprintf(text, sizeof text, "%d %.0f %.0f %.0f %.0f %.0f %.0f %.1f %.1f %d %s", number, x + WORLD_X, y + WORLD_Y, WORLD_Z, yaw, vx, vy,
                          e.hp, 2000.0, 0, "55.0");
            send_enemy_line(e, text, ms);
        }
    }

    // coop.lua's net.sendEnemyLine. Rule 0 (1.7.3): a line goes when it says something new, and one that doesn't every same_s.
    // Rule 1: one that says nothing new goes again one turn and then three turns after the change too, so a change lost on
    // the way is made good in a turn or two, not in same_s. Rule 2: one turn after only.
    void send_enemy_line(Enemy& e, const std::string& text, double ms) {
        if (text == e.last_text) {
            bool due = ms - e.last_sent >= o.same_s * 1000;
            if (o.enemy_rule >= 1 && e.repeats < (o.enemy_rule == 2 ? 1 : 2) && ms - e.last_sent >= ENEMY_ROUND_S * 1000 * (e.repeats == 0 ? 0.9 : 1.9)) {
                due = true;
                e.repeats++;
            }
            if (!due) return;
        } else {
            e.last_text = text;
            e.repeats = 0;
        }
        e.last_sent = ms;
        players[0]->box.post_enemy(text);
        r.enemy_lines++;
    }

    void run() {
        const double settle_ms = 3000;
        start = sim::clock_s;
        net.now = sim::clock_s;
        for (auto& p : players) p->next_frame = sim::clock_s + std::uniform_real_distribution<double>(0, 0.016)(p->rng);
        const long long steps = static_cast<long long>(o.seconds / STEP_S);
        const double t0 = sim::clock_s;
        for (long long i = 1; i <= steps; i++) {
            sim::clock_s = t0 + static_cast<double>(i) * STEP_S;
            net.now = sim::clock_s;
            if (!net.counting && path_ms() >= settle_ms) net.counting = true;
            for (auto& p : players) {
                if (sim::clock_s >= p->next_frame) {
                    frame(*p);
                    p->next_frame += p->frames.next() / 1000;
                    if (p->next_frame < sim::clock_s) p->next_frame = sim::clock_s;
                }
                if (p->rest_at >= 0 && sim::clock_s >= p->rest_at) {
                    p->rest_at = -1;
                    rest(*p);
                }
            }
            for (auto& p : players)
                if (p->woken || net.waiting(p->ip) || sim::clock_s - p->last_relay >= relay::TICK) tick_relay(*p);
        }
        // What was seen, against the truth.
        for (auto& p : players) {
            for (auto& [slot, shown] : p->seen) {
                const int kind = kind_of(slot, p->slot);
                lab::Measures m, g;
                lab::measure(players[slot - 1]->path, shown, m, settle_ms, players[slot - 1]->hitches);
                lab::measure(players[slot - 1]->path, p->walked[slot], g, settle_ms, players[slot - 1]->hitches);
                into(r.partner[kind], m);
                into(r.ghost[kind], g);
            }
            if (p->slot == 1) continue;
            for (int i = 0; i < o.enemies; i++) {
                lab::Measures m;
                lab::measure(enemies[i].path, p->copies[i].shown, m, settle_ms);
                into(r.enemy, m);
            }
        }
        for (const auto& [key, read] : quick_out) r.quick_lost[key.first == 1 ? 0 : 1] += o.players - 1 - read;
    }

    void print() {
        const double counted = o.seconds - 3;
        static const char* const WAY[] = {"host_to_guest", "guest_to_host", "guest_to_guest"};
        std::printf("players=%d enemies=%d rtt=%.0f jitter=%.0f loss=%.1f burst=%.1f%%x%.0fms stall=%.0fms/%.0fs fps=%.0f seconds=%.0f seed=%u enemy_rule=%d lone=%d\n",
                    o.players, o.enemies, o.rtt, o.jitter, o.loss, o.burst_loss, o.burst_ms, o.stall_every > 0 ? o.stall_ms : 0.0, o.stall_every, o.fps,
                    o.seconds, o.seed, o.enemy_rule, o.lone ? 1 : 0);
        const double usual = o.rtt / 2 + o.jitter + 1000 / o.fps;      // the trip at its slowest and a whole frame's wait to be read
        for (int k = 0; k < 3; k++) {
            if (r.sure[k].v.empty()) continue;
            std::printf("sure.%s n=%zu p50=%.1f p95=%.1f p99=%.1f p999=%.1f max=%.1f late_pct=%.2f\n", WAY[k], r.sure[k].v.size(), r.sure[k].pick(0.5),
                        r.sure[k].pick(0.95), r.sure[k].pick(0.99), r.sure[k].pick(0.999), r.sure[k].pick(1.0), r.sure[k].over(usual * (k == 2 ? 2 : 1) + 30));
        }
        for (int k = 0; k < 3; k++) {
            if (r.quick[k].v.empty()) continue;
            std::printf("quick.%s n=%zu p50=%.1f p95=%.1f p99=%.1f max=%.1f\n", WAY[k], r.quick[k].v.size(), r.quick[k].pick(0.5), r.quick[k].pick(0.95),
                        r.quick[k].pick(0.99), r.quick[k].pick(1.0));
        }
        std::printf("quick.lost from_host=%lld from_guests=%lld of=%zu age_off_p95=%.1f sure.wrong_order=%lld\n", r.quick_lost[0], r.quick_lost[1],
                    quick_out.size() * (o.players - 1), r.age_off.pick(0.95), r.wrong_order);
        for (int k = 0; k < 3; k++) {
            if (r.partner[k].behind.v.empty()) continue;
            lab::Measures& m = r.partner[k];
            lab::Measures& g = r.ghost[k];
            std::printf("partner.%s behind_p50=%.1f behind_p95=%.1f behind_p99=%.1f stop_p50=%.1f stop_max=%.1f speed_p95=%.1f ghost_behind_p50=%.1f ghost_behind_p95=%.1f"
                        " ghost_stop_p50=%.1f ghost_speed_p95=%.1f\n",
                        WAY[k], m.behind(0.5), m.behind(0.95), m.behind(0.99), m.overshoot(0.5), m.overshoot(1.0), m.speed(0.95), g.behind(0.5), g.behind(0.95),
                        g.overshoot(0.5), g.speed(0.95));
        }
        if (o.enemies) {
            lab::Measures& m = r.enemy;
            std::printf("enemy behind_p50=%.1f behind_p95=%.1f off_p50=%.1f off_p95=%.1f off_p99=%.1f off_max=%.1f stop_p50=%.1f stop_p95=%.1f stop_p99=%.1f stop_max=%.1f"
                        " back_p95=%.1f back_max=%.1f stops=%zu\n",
                        m.behind(0.5), m.behind(0.95), m.now(0.5), m.now(0.95), m.now(0.99), m.now(1.0), m.overshoot(0.5), m.overshoot(0.95), m.overshoot(0.99),
                        m.overshoot(1.0), m.back(0.95), m.back(1.0), m.overshoot.v.size());
            std::printf("enemy.health n=%zu p50=%.1f p95=%.1f p99=%.1f max=%.1f lines_s=%.1f\n", r.enemy_hp.v.size(), r.enemy_hp.pick(0.5), r.enemy_hp.pick(0.95),
                        r.enemy_hp.pick(0.99), r.enemy_hp.pick(1.0), static_cast<double>(r.enemy_lines) / o.seconds);
        }
        double guests_bytes = 0, guests_packets = 0;
        for (int slot = 2; slot <= o.players; slot++) {
            guests_bytes += net.bytes[slot];
            guests_packets += net.packets[slot];
        }
        std::printf("bytes host_up_kb_s=%.2f host_packets_s=%.1f guest_up_kb_s=%.2f guest_packets_s=%.1f\n", net.bytes[1] / counted / 1024,
                    net.packets[1] / counted, guests_bytes / (o.players - 1) / counted / 1024, guests_packets / (o.players - 1) / counted);
    }
};

}  // namespace

int main(int argc, char** argv) {
    Options o;
    o.players = static_cast<int>(opt(argc, argv, "--players", o.players));
    o.enemies = static_cast<int>(opt(argc, argv, "--enemies", o.enemies));
    o.seconds = opt(argc, argv, "--seconds", o.seconds);
    o.fps = opt(argc, argv, "--fps", o.fps);
    o.rtt = opt(argc, argv, "--rtt", o.rtt);
    o.jitter = opt(argc, argv, "--jitter", o.jitter);
    o.loss = opt(argc, argv, "--loss", o.loss);
    o.burst_loss = opt(argc, argv, "--burst-loss", o.burst_loss);
    o.burst_ms = opt(argc, argv, "--burst-ms", o.burst_ms);
    o.stall_every = opt(argc, argv, "--stall-every", o.stall_every);
    o.stall_ms = opt(argc, argv, "--stall-ms", o.stall_ms);
    o.dup = opt(argc, argv, "--dup", o.dup);
    o.sure_s = opt(argc, argv, "--sure", o.sure_s);
    o.quick_s = opt(argc, argv, "--quick", o.quick_s);
    o.busy = opt(argc, argv, "--busy", o.busy);
    o.hits_s = opt(argc, argv, "--hits", o.hits_s);
    o.enemy_rule = static_cast<int>(opt(argc, argv, "--enemy-rule", o.enemy_rule));
    o.same_s = opt(argc, argv, "--same", o.same_s);
    o.seed = static_cast<uint32_t>(opt(argc, argv, "--seed", o.seed));
    o.lone = opt(argc, argv, "--lone", 0) != 0;
    if (o.players < 2 || o.players > 6 || o.enemies < 0 || o.enemies > 64) {
        std::fputs("netsim: 2 to 6 players, up to 64 enemies\n", stderr);
        return 2;
    }
    relay::clock_ms();      // (the relay's clock starts here, at this file's time)
    World world(o);
    world.run();
    world.print();
    return 0;
}

// This tool has no game around it, so no Steam.
std::unique_ptr<relay::Link> relay::make_steam_link(const std::string&, const std::string&) {
    throw std::runtime_error("netsim has no Steam");
}
