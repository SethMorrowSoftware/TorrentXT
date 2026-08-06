/* enx_handle_table.h — generation-tagged integer handle table, carried verbatim
 * from TorrentXT (btx_handle_table.h), which carried it from Box2Dxt/OSC's
 * DEFINE_PTR_TABLE. One tested implementation, shared behaviour across the
 * whole extension family: a stale handle is ALWAYS a harmless no-op.
 *
 * A handle is a POSITIVE 32-bit int that packs a generation counter above a
 * slot index. Every handle is validated before use, so a stale / removed /
 * never-created handle is a HARMLESS NO-OP (get() returns nullptr; the shim
 * then returns 0/empty/-error) — never a crash, and never silently addressing
 * a recycled slot, because freeing a slot bumps its generation and so
 * invalidates every handle that still names the old generation.
 *
 * ENet is threadless, so unlike the datachannelxt sibling there is no
 * cross-thread hazard here — but the stale-handle rule earns its keep anyway:
 * script can hold a peer handle across a disconnect (the slot is freed at
 * drain time), and any later use of that handle must be a harmless no-op,
 * never a touch of a recycled slot. Events carry handle IDS (ints), never
 * pointers. The table is not thread-safe and does not need to be: every
 * access happens on the engine's single script thread.
 *
 *   bit layout (31 usable bits; sign bit stays 0 so handles are positive):
 *     [ 30..16 : generation (15 bits, 1..32767) ][ 15..0 : slot index (16 bits) ]
 *
 * Header-only and ENet-free, so it is unit-tested standalone under
 * ASan/UBSan (tests/record_handle_test.cpp). The shim instantiates one table
 * for hosts and one for peers.
 */
#ifndef ENX_HANDLE_TABLE_H
#define ENX_HANDLE_TABLE_H

#include <cstdint>
#include <utility>
#include <vector>

namespace enx {

template <typename T>
class HandleTable {
public:
    /* Store `obj`, returning a fresh positive handle, or 0 if the table is full
     * (> 65535 simultaneously-live entries — far beyond any real use). */
    int alloc(T obj) {
        uint32_t idx;
        if (!free_.empty()) {
            idx = free_.back();
            free_.pop_back();
        } else {
            if (slots_.size() > SLOT_MASK) return 0;  /* table exhausted */
            idx = static_cast<uint32_t>(slots_.size());
            slots_.push_back(Slot{});
        }
        Slot &s = slots_[idx];
        if (s.gen == 0) s.gen = 1;       /* generation is never 0 for a live slot */
        s.obj = std::move(obj);
        s.live = true;
        ++liveCount_;
        return encode(s.gen, idx);
    }

    /* Pointer to the stored object, or nullptr if the handle is not live (stale
     * generation, freed slot, or out of range). The caller must not retain the
     * pointer across a free()/alloc() of the same table. */
    T *get(int handle) {
        Slot *s = slot_of(handle);
        return s ? &s->obj : nullptr;
    }
    const T *get(int handle) const {
        const Slot *s = slot_of(handle);
        return s ? &s->obj : nullptr;
    }

    /* Invalidate a handle and release its object. Bumps the slot generation so
     * the just-freed handle (and any copy of it) is now stale. Returns false
     * (a no-op) for a handle that was not live — making free() idempotent. */
    bool free(int handle) {
        Slot *s = slot_of(handle);
        if (!s) return false;
        s->obj = T{};
        s->live = false;
        s->gen = (s->gen >= GEN_MAX) ? 1u : s->gen + 1u;  /* wrap 32767 -> 1 */
        free_.push_back(decode_idx(handle));
        --liveCount_;
        return true;
    }

    size_t live_count() const { return liveCount_; }

    /* Append the currently-live handles to `out`, in slot order. Used by the
     * teardown sweep (enx_host_destroy / enx_deinitialize free every live
     * peer riding a host). */
    void collect_live(std::vector<int> &out) const {
        for (uint32_t i = 0; i < slots_.size(); ++i)
            if (slots_[i].live) out.push_back(encode(slots_[i].gen, i));
    }

private:
    struct Slot {
        T obj{};
        uint32_t gen = 0;
        bool live = false;
    };

    static const uint32_t SLOT_BITS = 16;
    static const uint32_t SLOT_MASK = (1u << SLOT_BITS) - 1u;  /* 0xFFFF */
    static const uint32_t GEN_MAX   = 0x7FFFu;                 /* 15 bits */

    static int encode(uint32_t gen, uint32_t idx) {
        return static_cast<int>((gen << SLOT_BITS) | (idx & SLOT_MASK));
    }
    static uint32_t decode_gen(int h) {
        return (static_cast<uint32_t>(h) >> SLOT_BITS) & GEN_MAX;
    }
    static uint32_t decode_idx(int h) {
        return static_cast<uint32_t>(h) & SLOT_MASK;
    }

    Slot *slot_of(int handle) {
        if (handle <= 0) return nullptr;
        uint32_t idx = decode_idx(handle);
        if (idx >= slots_.size()) return nullptr;
        Slot &s = slots_[idx];
        if (!s.live || s.gen != decode_gen(handle)) return nullptr;
        return &s;
    }
    const Slot *slot_of(int handle) const {
        if (handle <= 0) return nullptr;
        uint32_t idx = decode_idx(handle);
        if (idx >= slots_.size()) return nullptr;
        const Slot &s = slots_[idx];
        if (!s.live || s.gen != decode_gen(handle)) return nullptr;
        return &s;
    }

    std::vector<Slot> slots_;
    std::vector<uint32_t> free_;
    size_t liveCount_ = 0;
};

}  // namespace enx

#endif /* ENX_HANDLE_TABLE_H */
