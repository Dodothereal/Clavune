// Portable production ingress only. No AVAudioEngine, converter or hardware claim.
#include "ClavuneBridge.h"
#include <cassert>
#include <cstdio>

int main() {
    float samples[4] = {0.0f, 0.25f, 0.5f, 0.75f};
    float output[4]{};
    ow_block block{};
    auto * ring = ow_ring_create(2, 4);
    assert(ring);
    assert(ow_ring_push_buffer(ring, samples, 4, 1000, 0, 1, 1, 16000, 16000) == 1);
    ow_ring_close(ring);
    // Published prefix survives closure. Later callback is ignored, not a loss.
    assert(ow_ring_push_buffer(ring, samples, 4, 1004, 4, 1, 1, 16000, 16000) == 0);
    assert(ow_ring_losses(ring) == 0);
    assert(ow_ring_pop(ring, output, 4, &block) == 1);
    assert(block.frames == 4 && block.sample_time == 0 && block.host_time == 1000);
    for (unsigned i = 0; i < 4; ++i) assert(output[i] == samples[i]);
    assert(ow_ring_pop(ring, output, 4, &block) == 0);
    ow_ring_close(ring); // idempotent
    assert(ow_ring_push_buffer(ring, nullptr, 0, 0, 0, 0, 0, 0, 0) == 0);
    assert(ow_ring_losses(ring) == 0);
    ow_ring_destroy(ring);

    ring = ow_ring_create(2, 4);
    assert(ring);
    assert(ow_ring_push_buffer(ring, samples, 4, 1000, 0, 1, 1, 16000, 16000) == 1);
    assert(ow_ring_push_buffer(ring, samples, 4, 1004, 4, 1, 1, 16000, 16000) == 1);
    // Real overflow remains visible after closure; it is not normal completion.
    assert(ow_ring_push_buffer(ring, samples, 4, 1008, 8, 1, 1, 16000, 16000) == 0);
    assert(ow_ring_losses(ring) == 1);
    ow_ring_close(ring);
    assert(ow_ring_push_buffer(ring, samples, 4, 1012, 12, 1, 1, 16000, 16000) == 0);
    assert(ow_ring_losses(ring) == 1);
    assert(ow_ring_pop(ring, output, 4, &block) == 1 && block.sample_time == 0);
    assert(ow_ring_pop(ring, output, 4, &block) == 1 && block.sample_time == 4);
    assert(ow_ring_pop(ring, output, 4, &block) == 0);
    ow_ring_destroy(ring);
    std::puts("PASS: published prefix, post-close callbacks, idempotent close, genuine overflow");
}
