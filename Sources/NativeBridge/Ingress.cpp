#include "ClavuneBridge.h"
#include <atomic>
#include <cmath>
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
static int reject_buffer(ow_ring * r) {
    r->losses.fetch_add(1, std::memory_order_relaxed);
    return 0;
}
extern "C" int ow_ring_push_buffer(ow_ring * r, const float * input, uint32_t frames,
                                   uint64_t host, int64_t sample, uint8_t hv, uint8_t sv,
                                   double native_rate, double host_ticks_per_second) {
    if (!r || !r->accepting.load(std::memory_order_acquire)) return 0;
    if (!input || frames == 0 || !std::isfinite(native_rate) || native_rate <= 0 ||
        !std::isfinite(host_ticks_per_second) || host_ticks_per_second <= 0) {
        return reject_buffer(r);
    }
    const uint64_t chunks = (uint64_t(frames) + r->max_frames - 1) / r->max_frames;
    const auto w = r->write.load(std::memory_order_relaxed);
    const auto rd = r->read.load(std::memory_order_acquire);
    const uint64_t occupied = w - rd;
    if (chunks > r->slots || occupied > r->slots || chunks > r->slots - occupied) {
        return reject_buffer(r);
    }

    // Validate all timestamp arithmetic before touching any unpublished slot.
    // The consumer also advances each block's sample position by its frame count.
    if (sv && sample > std::numeric_limits<int64_t>::max() - int64_t(frames)) {
        return reject_buffer(r);
    }
    const long double ticks_per_frame =
        static_cast<long double>(host_ticks_per_second) / native_rate;
    if (!std::isfinite(ticks_per_frame) || ticks_per_frame <= 0) return reject_buffer(r);
    const uint64_t last_offset = (chunks - 1) * r->max_frames;
    if (hv) {
        const long double last_ticks = std::round(last_offset * ticks_per_frame);
        // Use an exclusive power-of-two bound: some platforms' long double is double.
        constexpr long double uint64_exclusive_bound = 18446744073709551616.0L;
        if (!std::isfinite(last_ticks) || last_ticks < 0 ||
            last_ticks >= uint64_exclusive_bound) return reject_buffer(r);
        const auto last_delta = static_cast<uint64_t>(last_ticks);
        if (host > std::numeric_limits<uint64_t>::max() - last_delta) return reject_buffer(r);
    }

    uint64_t offset = 0;
    for (uint64_t chunk = 0; chunk < chunks; ++chunk) {
        const auto remaining = uint64_t(frames) - offset;
        const auto amount = static_cast<uint32_t>(
            remaining < r->max_frames ? remaining : r->max_frames);
        const auto slot = (w + chunk) % r->slots;
        const auto chunk_host = hv
            ? host + static_cast<uint64_t>(std::round(offset * ticks_per_frame)) : host;
        const auto chunk_sample = sv ? sample + static_cast<int64_t>(offset) : sample;
        std::memcpy(r->samples.get() + slot * r->max_frames, input + offset,
                    size_t(amount) * sizeof(float));
        r->metadata[slot] = {amount, chunk_host, chunk_sample, w + chunk, hv, sv};
        offset += amount;
    }
    if (hv && w == 0) r->first_host.store(host, std::memory_order_release);
    // The consumer sees every adapted slot together, never a partially published callback.
    r->write.store(w + chunks, std::memory_order_release);
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
