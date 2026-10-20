#include "ClavuneBridge.h"
#include "whisper.h"
#include "ClavuneBackendFingerprint.h"
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <memory>
#include <string>

struct ow_engine { whisper_context * context; };
struct ow_cancel { std::atomic<bool> cancelled{false}; };
struct ow_result { int status = 3; std::string text; int language = -1; };
extern "C" const char * ow_backend_fingerprint(void) { return CLAVUNE_BACKEND_FINGERPRINT; }
extern "C" int ow_backend_environment_allowed(const char * encoder, const char * dylib) {
    // Upstream treats a non-null getenv result as opt-in, even if the string is empty.
    // Do not silently opt into a second encoder or caller-selected dlopen path.
    return encoder == nullptr && dylib == nullptr;
}
extern "C" int ow_backend_state_ownership_patch_revision(void) {
    return whisper_clavune_state_ownership_patch_revision();
}
static bool process_backend_environment_allowed() {
    return ow_backend_environment_allowed(std::getenv("ANEFORGE_ENCODER"),
                                          std::getenv("ANEFORGE_DYLIB")) != 0;
}
static void discard_log(ggml_log_level, const char *, void *) {}
static bool aborted(void * opaque) {
    return static_cast<ow_cancel *>(opaque)->cancelled.load(std::memory_order_relaxed);
}
static bool before_encoder(whisper_context *, whisper_state *, void * opaque) { return !aborted(opaque); }
extern "C" ow_cancel * ow_cancel_create() { return new (std::nothrow) ow_cancel; }
extern "C" void ow_cancel_set(ow_cancel * c) { if(c) c->cancelled.store(true, std::memory_order_relaxed); }
extern "C" void ow_cancel_destroy(ow_cancel * c) { delete c; }
extern "C" ow_engine * ow_engine_create(const char * path, int gpu) {
    if (!path || !process_backend_environment_allowed() ||
        whisper_clavune_state_ownership_patch_revision() != 1) return nullptr;
    try {
        whisper_log_set(discard_log, nullptr);
        auto params = whisper_context_default_params();
        params.use_gpu = gpu != 0;
        params.flash_attn = false; // Quality baseline; changes require measured gates.
        auto ctx = whisper_init_from_file_with_params_no_state(path, params);
        if (!ctx) return nullptr;
        auto engine = new (std::nothrow) ow_engine{ctx};
        if (!engine) whisper_free(ctx);
        return engine;
    } catch (...) { return nullptr; }
}
extern "C" void ow_engine_destroy(ow_engine * e) {
    if (e) { whisper_free(e->context); delete e; }
}
extern "C" ow_result * ow_engine_decode(ow_engine * e, ow_cancel * cancel,
                                       const float * pcm, size_t count, int rate,
                                       const char * language, int threads) {
    auto result = std::unique_ptr<ow_result>(new (std::nothrow) ow_result);
    if (!result) return nullptr;
    try {
        if (!e || !cancel || !pcm || rate != 16000 || count == 0 ||
            count > 16000 * 120 || count > size_t(std::numeric_limits<int>::max()) ||
            threads < 1 || threads > 8 || !language ||
            (std::string(language) != "auto" && std::string(language) != "de" && std::string(language) != "en")) {
            result->status = 2; return result.release();
        }
        for (size_t i = 0; i < count; ++i) if (!std::isfinite(pcm[i])) {
            result->status = 2; return result.release();
        }
        if (aborted(cancel)) { result->status = 1; return result.release(); }
        // Recheck immediately before decoder state creation, where pinned upstream
        // reads ANEFORGE_ENCODER and may dlopen ANEFORGE_DYLIB. No env values are logged.
        if (!process_backend_environment_allowed()) return result.release();
        // Weights survive between requests; decoder state is private to this session.
        std::unique_ptr<whisper_state, decltype(&whisper_free_state)>
            state(whisper_init_state(e->context), whisper_free_state);
        if (!state) return result.release();
        auto p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        p.n_threads = threads; p.language = language; p.detect_language = false;
        p.translate = false; p.no_context = true;
        p.print_progress = false; p.print_realtime = false;
        p.print_special = false; p.print_timestamps = false;
        p.no_timestamps = false; p.token_timestamps = false; p.single_segment = false;
        p.max_tokens = 0; p.audio_ctx = 0; p.debug_mode = false;
        p.initial_prompt = nullptr; p.prompt_tokens = nullptr; p.prompt_n_tokens = 0;
        p.carry_initial_prompt = false;
        p.temperature = 0.0f; p.temperature_inc = 0.0f; p.greedy.best_of = 1;
        p.vad = false; p.vad_model_path = nullptr;
        p.abort_callback = aborted; p.abort_callback_user_data = cancel;
        p.encoder_begin_callback = before_encoder; p.encoder_begin_callback_user_data = cancel;
        const int rc = whisper_full_with_state(e->context, state.get(), p, pcm, int(count));
        if (aborted(cancel)) { result->status = 1; return result.release(); }
        if (rc != 0) return result.release();
        result->language = whisper_full_lang_id_from_state(state.get());
        for (int i = 0; i < whisper_full_n_segments_from_state(state.get()); ++i) {
            const char * text = whisper_full_get_segment_text_from_state(state.get(), i);
            if (text) result->text += text;
        }
        result->status = 0;
    } catch (...) { result->text.clear(); result->status = 3; }
    return result.release();
}
extern "C" int ow_result_status(const ow_result * r) { return r ? r->status : 3; }
extern "C" const char * ow_result_text(const ow_result * r) { return r ? r->text.c_str() : ""; }
extern "C" int ow_result_language(const ow_result * r) { return r ? r->language : -1; }
extern "C" void ow_result_destroy(ow_result * r) { delete r; }
