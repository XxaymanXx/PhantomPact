// What gets across and how, apart from the position. Two lanes:
//   Sure   every event arrives, once, in order (a death, a hit, loot). Several travel at a time, and a lost one is sent
//          again once the partner's acknowledgement shows the gap and a round trip has gone by since it was sent, so a loss
//          costs about one round trip. With nothing sent after it to show the gap, it goes again after retry_s. In play
//          they come one at a time, so a short one also goes again a frame later, and twice more after that, before any
//          loss can be known (copies): a lost packet then costs a frame, not a round trip and a half.
//   Quick  moves and hit reactions: each goes out in the next few packets, is played once, and is dropped once it's too
//          late to matter. An attack shown two seconds late is worse than none, and old ones must never hold up a death.
// Plain logic with no Windows calls, so relay_cli can test it against simulated connections.
#pragma once
#include <algorithm>
#include <cstdint>
#include <deque>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace relay {

constexpr size_t MAX_SURE_PENDING = 8192;     // events waiting for a partner who isn't there: the oldest go first
constexpr int SURE_COPIES = 3;                // a sure event goes again this many times before any loss is known...
constexpr size_t SURE_COPIES_UP_TO = 8;       // ...while this few wait: a long queue (a join, a re-tell) shows its gaps in the
                                              // acknowledgements at once, and copies would only make it four times as long
constexpr size_t SURE_COPY_BYTES = 400;       // ...and only one this short: a guest's hit with the flinch it made (D: a montage's
                                              // path, up to 256, and the hit state) is 190-280 bytes, and a long one is a list
                                              // told at a join (a bag's 600), whose copies would fill the packets they ride in.
                                              // (At 200 that hit had no copies: the fight's event they were built for.)

// In order or not at all: a lost event would hold back everything behind it forever. So once the queue has really dropped
// one, overflowed stays set, and the relay starts both sides over when the partner is back (Relay::flush).
class SureSender {
public:
    struct Item {
        uint32_t id = 0;
        std::string text;
        double sent_at = -1e9;
        int sends = 0;
        double copy_at = -1e9;  // its last copy (see for_each_copy): a copy changes nothing above
        int copies = 0;
        bool acked = false;
        bool passed = false;    // an acknowledgement confirmed something sent after this, and not this (see on_ack)
    };

    void push(std::string text) {
        Item item;
        item.id = next_id_++;
        item.text = std::move(text);
        pending_.push_back(std::move(item));
        if (pending_.size() > MAX_SURE_PENDING) {
            pending_.pop_front();
            overflowed = true;
        }
    }

    // Everything due now, oldest first: new events, and sent ones that have gone unconfirmed for retry_s. One passed over
    // by an acknowledgement is lost, not late: it's due again once lost_after_s has gone by since it was sent (about one
    // round trip), not retry_s (half as much again, and 15 ms). Negative lost_after_s: retry_s for both.
    template <typename Fn>
    void for_each_due(double now, double retry_s, Fn&& take, double lost_after_s = -1) {
        for (Item& item : pending_) {
            if (item.acked) continue;
            const double wait = item.passed && lost_after_s >= 0 ? std::min(lost_after_s, retry_s) : retry_s;
            if (now - item.sent_at < wait) continue;
            if (!take(static_cast<const Item&>(item))) return;
            if (item.sends) resent++;
            if (item.sends && item.passed && now - item.sent_at < retry_s) resent_early++;
            item.sent_at = now;
            item.sends++;
            item.passed = false;    // (sent again: only a confirmation of something sent after this counts now)
            item.copy_at = now;     // (and its copies start over: for_each_copy)
            item.copies = 0;
        }
    }

    // Copies: with few waiting, a short unconfirmed event goes again gap_s after it was sent, then twice and four times that
    // after each copy (SURE_COPIES), with no loss known. In a fight an event comes alone, a second or more from the next:
    // nothing sent after it shows that it was lost, and it waited out retry_s, the partner's enemy standing at 1 health
    // meanwhile. The relay asks for them after everything else a packet carries, so a copy takes only the room that's left
    // and holds nothing up; and a copy changes nothing of for_each_due's: when an event is taken for lost still counts from
    // sent_at. wait_s is added to each wait: the relay's, for a copy that would have to go in a packet of its own.
    template <typename Fn>
    void for_each_copy(double now, double gap_s, double wait_s, Fn&& take) {
        if (pending_.size() > SURE_COPIES_UP_TO) return;
        for (Item& item : pending_) {
            if (item.acked || !item.sends || item.copies >= SURE_COPIES || item.text.size() > SURE_COPY_BYTES) continue;
            if (now - item.copy_at < gap_s * (1 << item.copies) + wait_s) continue;
            if (!take(static_cast<const Item&>(item))) return;
            copied++;
            item.copy_at = now;
            item.copies++;
        }
    }

    // next: everything before it arrived. bits: bit n set = next + 1 + n arrived too.
    // What was sent before something confirmed now, and isn't confirmed itself, is marked passed: the partner's confirmation
    // of it would have come with that one's, unless a packet overtook it on the way, which lost_after_s allows for. (The
    // events go in a packet together, or the later ones in later packets: a send time only shows which went first.)
    void on_ack(uint32_t next, uint32_t bits) {
        if (static_cast<int32_t>(next - next_id_) > 0) return;      // past anything sent: not about these events
        double confirmed = -1e9;    // the last send of anything this confirms
        while (!pending_.empty() && static_cast<int32_t>(pending_.front().id - next) < 0) {
            confirmed = std::max(confirmed, pending_.front().sent_at);
            pending_.pop_front();
            acked++;
        }
        for (Item& item : pending_) {
            const int32_t past = static_cast<int32_t>(item.id - next) - 1;
            if (past >= 32) break;
            if (past >= 0 && (bits >> past) & 1) item.acked = true;
            if (item.acked) confirmed = std::max(confirmed, item.sent_at);
        }
        for (Item& item : pending_) {
            if (!item.acked && item.sends && item.sent_at < confirmed) item.passed = true;
        }
    }

    // A new partner: what's waiting was for the one who left, or for nobody (dust and rests from before they joined, a boss
    // fight long over). Numbers start from 1 again, and the mod tells them what they need to know (handlers.S).
    void forget() {
        pending_.clear();
        next_id_ = 1;
        overflowed = false;
    }

    size_t pending() const { return pending_.size(); }
    long long acked = 0, resent = 0, resent_early = 0;     // resent_early: sent again before retry_s, for being passed
    long long copied = 0;                                  // copies sent with no loss known: not counted as resent
    bool overflowed = false;

private:
    std::deque<Item> pending_;
    uint32_t next_id_ = 1;
};

class SureReceiver {
public:
    // Hands every event that's now next in line to deliver(text). If deliver says there's no room, that event stays
    // unconfirmed and the partner sends it again, so an acknowledgement always means the game will see it.
    template <typename Fn>
    void on_event(uint32_t id, std::string text, Fn&& deliver) {
        // Held ones next in line first: one the game had no room for when its turn came was never tried again, it being
        // acknowledged already (bits) and so never sent again, and every sure event behind it waited for good.
        drain(deliver);
        const int32_t ahead = static_cast<int32_t>(id - next_);
        if (ahead < 0 || ahead >= MAX_AHEAD) return;
        if (ahead > 0) {
            held_.emplace(id, std::move(text));
            return;
        }
        held_.erase(id);    // (one held before, now in by its resend: left behind, never read and never freed)
        if (!deliver(text)) return;
        next_++;
        count++;
        drain(deliver);
    }

    // The held events that are next in line, as far as the game takes them. Also for a quiet partner (Relay::flush).
    template <typename Fn>
    void drain(Fn&& deliver) {
        for (auto it = held_.find(next_); it != held_.end(); it = held_.find(next_)) {
            if (!deliver(it->second)) return;
            held_.erase(it);
            next_++;
            count++;
        }
    }

    uint32_t next() const { return next_; }

    uint32_t bits() const {
        uint32_t out = 0;
        for (const auto& [id, text] : held_) {
            const int32_t past = static_cast<int32_t>(id - next_) - 1;
            if (past >= 0 && past < 32) out |= 1u << past;
        }
        return out;
    }

    void restart() {
        next_ = 1;
        held_.clear();
    }

    long long count = 0;

private:
    static constexpr int32_t MAX_AHEAD = 4096;
    uint32_t next_ = 1;
    std::map<uint32_t, std::string> held_;
};

constexpr int QUICK_SENDS = 3;                // a burst of loss has to last from the first to the last to lose a move
constexpr double QUICK_MAX_AGE_S = 0.6;       // not sent any more after this
constexpr uint32_t QUICK_REPLAY_MS = 800;     // and not played if it took this long
constexpr double QUICK_WAIT_MS = 300;         // or if it then waited this long for a busy game thread

class QuickSender {
public:
    struct Item {
        uint32_t id = 0;
        std::string text;
        double born = 0, sent_at = -1e9;
        int sends = 0;
    };

    void push(std::string text, double now) {
        Item item;
        item.id = next_id_++;
        item.text = std::move(text);
        item.born = now;
        pending_.push_back(std::move(item));
    }

    // Each repeat waits twice as long as the one before it: gap_s, then twice that, so one burst of loss has to last that
    // long to take them all. (A move that comes on a later copy starts that much further in: it comes with its age.)
    template <typename Fn>
    void for_each(double now, double gap_s, Fn&& take) {
        expire(now);
        for (Item& item : pending_) {
            if (now - item.sent_at < gap_s * (item.sends > 1 ? 2 << (item.sends - 2) : 1)) continue;
            if (!take(static_cast<const Item&>(item), now - item.born)) break;
            item.sent_at = now;
            item.sends++;
        }
        expire(now);
    }

    // Runs with no partner too: moves made alone must neither pile up nor go out late, and the age on the wire is 16 bits.
    void expire(double now) {
        while (!pending_.empty() && (pending_.front().sends >= QUICK_SENDS || now - pending_.front().born > QUICK_MAX_AGE_S))
            pending_.pop_front();
    }

    bool empty() const { return pending_.empty(); }
    void restart() { pending_.clear(); }

private:
    std::deque<Item> pending_;
    uint32_t next_id_ = 1;
};

class QuickReceiver {
public:
    // True the first time this id is seen. A repeat, or a late straggler from before the window, is false.
    bool fresh(uint32_t id) {
        if (!any_) {
            any_ = true;
            newest_ = id;
            seen_ = 1;
            return true;
        }
        const int32_t ahead = static_cast<int32_t>(id - newest_);
        // Far off either way: taken only once a few in a row agree. One id far ahead moved the window there for good, and
        // every real one after it read as too old (the lane dead till the next session); a real jump, ids sent on through
        // a long outage, still comes through after three.
        if (ahead >= FAR_IDS || ahead <= -FAR_IDS) {
            const int32_t from_last = static_cast<int32_t>(id - far_);
            if (far_hits_ > 0 && from_last > 0 && from_last < 64) {
                far_hits_++;
            } else {
                far_hits_ = 1;
            }
            far_ = id;
            if (far_hits_ < FAR_AGREE) return false;
            far_hits_ = 0;
            newest_ = id;
            seen_ = 1;
            return true;
        }
        far_hits_ = 0;
        if (ahead > 0) {
            seen_ = ahead >= 64 ? 0 : seen_ << ahead;
            seen_ |= 1;
            newest_ = id;
            return true;
        }
        if (ahead <= -64) return false;
        const uint64_t bit = 1ull << -ahead;
        if (seen_ & bit) return false;
        seen_ |= bit;
        return true;
    }

    void restart() {
        any_ = false;
        far_hits_ = 0;
    }

private:
    static constexpr int32_t FAR_IDS = 4096;
    static constexpr int FAR_AGREE = 3;
    bool any_ = false;
    uint32_t newest_ = 0;
    uint64_t seen_ = 0;
    uint32_t far_ = 0;
    int far_hits_ = 0;
};

}  // namespace relay
