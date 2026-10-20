#include "ClavuneBridge.h"
#include <atomic>
#include <cstring>
#include <limits>
#include <memory>
#include <new>

static_assert(std::atomic<uint64_t>::is_always_lock_free, "Requires lock-free arm64 atomics");
struct ow_ring {
    uint32_t slots, max_frames;
    std::unique_ptr<float[]> samples;
    std::unique_ptr<ow_block[]> metadata;
    alignas(64) std::atomic<uint64_t> write{0};
    alignas(64) std::atomic<uint64_t> read{0};
    std::atomic<uint64_t> losses{0}, first_host{0};
    std::atomic<bool> accepting{true};
};
extern "C" ow_ring * ow_ring_create(uint32_t slots, uint32_t max_frames) {
    if (slots < 2 || slots > 1024 || max_frames == 0 || max_frames > 65536) return nullptr;
    try {
        auto ring = std::make_unique<ow_ring>();
        ring->slots = slots; ring->max_frames = max_frames;
        ring->samples = std::make_unique<float[]>(size_t(slots) * max_frames);
        ring->metadata = std::make_unique<ow_block[]>(slots);
        return ring.release();
    } catch (...) { return nullptr; }
}
extern "C" void ow_ring_destroy(ow_ring * r) { delete r; }
extern "C" void ow_ring_close(ow_ring * r) { r->accepting.store(false, std::memory_order_release); }
extern "C" uint64_t ow_ring_losses(const ow_ring * r) { return r->losses.load(std::memory_order_relaxed); }
extern "C" uint64_t ow_ring_first_host(const ow_ring * r) { return r->first_host.load(std::memory_order_acquire); }
extern "C" int ow_ring_push(ow_ring * r, const float * input, uint32_t frames,
                            uint64_t host, int64_t sample, uint8_t hv, uint8_t sv) {
    if (!r->accepting.load(std::memory_order_acquire)) return 0;
    auto w = r->write.load(std::memory_order_relaxed);
    auto rd = r->read.load(std::memory_order_acquire);
    if (!input || frames == 0 || frames > r->max_frames || w - rd >= r->slots) {
        r->losses.fetch_add(1, std::memory_order_relaxed); return 0;
    }
    const auto slot = w % r->slots;
    std::memcpy(r->samples.get() + slot * r->max_frames, input, size_t(frames) * sizeof(float));
    r->metadata[slot] = {frames, host, sample, w, hv, sv};
    if (hv && w == 0) r->first_host.store(host, std::memory_order_release);
    r->write.store(w + 1, std::memory_order_release);
    return 1;
}
extern "C" int ow_ring_pop(ow_ring * r, float * output, uint32_t capacity, ow_block * block) {
    const auto rd = r->read.load(std::memory_order_relaxed);
    if (rd == r->write.load(std::memory_order_acquire)) return 0;
    const auto slot = rd % r->slots;
    const auto m = r->metadata[slot];
    if (!output || !block || capacity < m.frames) return -1;
    std::memcpy(output, r->samples.get() + slot * r->max_frames, size_t(m.frames) * sizeof(float));
    *block = m;
    r->read.store(rd + 1, std::memory_order_release);
    return 1;
}
