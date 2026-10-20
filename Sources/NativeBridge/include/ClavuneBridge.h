#ifndef OPENWISPR_BRIDGE_H
#define OPENWISPR_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct ow_ring ow_ring;
typedef struct {
    uint32_t frames;
    uint64_t host_time;
    int64_t sample_time;
    uint64_t sequence;
    uint8_t host_valid;
    uint8_t sample_valid;
} ow_block;
ow_ring * ow_ring_create(uint32_t slots, uint32_t max_frames);
void ow_ring_destroy(ow_ring *);
// Exactly one producer. Bounded copy, no allocation or lock. False means loss.
int ow_ring_push(ow_ring *, const float *, uint32_t frames, uint64_t host_time,
                 int64_t sample_time, uint8_t host_valid, uint8_t sample_valid);
// Adapt one possibly larger callback into <=max_frames slots, with one publication.
// native_sample_rate and host_ticks_per_second are validated/precomputed off callback.
// Requires room for the entire callback; any rejection publishes no partial buffer.
// Work is bounded by the configured ring slots; no allocation or lock is performed.
int ow_ring_push_buffer(ow_ring *, const float *, uint32_t frames, uint64_t host_time,
                        int64_t sample_time, uint8_t host_valid, uint8_t sample_valid,
                        double native_sample_rate, double host_ticks_per_second);
// Exactly one consumer; output capacity must be at least max_frames.
int ow_ring_pop(ow_ring *, float * output, uint32_t capacity, ow_block *);
void ow_ring_close(ow_ring *);
uint64_t ow_ring_losses(const ow_ring *);
uint64_t ow_ring_first_host(const ow_ring *);

typedef struct ow_engine ow_engine;
typedef struct ow_cancel ow_cancel;
typedef struct ow_result ow_result;
// Only the manifest-approved whisper.cpp CPU/Metal path is enabled.
// Presence (including empty values) of either optional ANEForge variable is rejected.
// Pure predicate for isolated configuration regression tests; runtime checks getenv itself.
int ow_backend_environment_allowed(const char * aneforge_encoder, const char * aneforge_dylib);
// Link-time/runtime proof that the pinned upstream exception-ownership patch is present.
int ow_backend_state_ownership_patch_revision(void);
// Digest of exact static archives and dependency/patch lock used by this link.
const char * ow_backend_fingerprint(void);
ow_cancel * ow_cancel_create(void);
void ow_cancel_set(ow_cancel *);
void ow_cancel_destroy(ow_cancel *);
ow_engine * ow_engine_create(const char * path, int use_gpu);
void ow_engine_destroy(ow_engine *);
// Serial caller owns engine. Cancellation token may be set concurrently.
// PCM is finite, immutable mono Float32 at exactly 16 kHz for this call.
ow_result * ow_engine_decode(ow_engine *, ow_cancel *, const float * pcm,
                             size_t count, int sample_rate, const char * language,
                             int threads);
int ow_result_status(const ow_result *); // 0 success, 1 cancelled, 2 invalid, 3 backend
const char * ow_result_text(const ow_result *);
int ow_result_language(const ow_result *);
void ow_result_destroy(ow_result *);
#ifdef __cplusplus
}
#endif
#endif
