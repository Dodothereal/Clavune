// This TU supplies only the entry points referenced by the actual bridge TU.
// Declarations come from pinned real headers; no Whisper/GGML archive is linked.
#include "NativeContractChecks.h"
#include "ClavuneBridge.h"
#include "whisper.h"
#include <cmath>
#include <cstring>
#include <limits>
#include <initializer_list>
#include <new>

namespace {
struct HeapEntry { void * pointer; size_t bytes; };
HeapEntry heap[128]{};
int heap_live = 0;
bool fail_next_new = false;
void * tracked_new(size_t bytes) {
    if (fail_next_new) { fail_next_new = false; throw std::bad_alloc(); }
    CONTRACT_CHECK(heap_live < 128);
    void * pointer = std::malloc(bytes == 0 ? 1 : bytes);
    if (!pointer) throw std::bad_alloc();
    for (int i = 0; i < heap_live; ++i) CONTRACT_CHECK(heap[i].pointer != pointer);
    heap[heap_live++] = {pointer, bytes};
    return pointer;
}
void tracked_delete(void * pointer) noexcept {
    if (!pointer) return;
    int i = 0;
    while (i < heap_live && heap[i].pointer != pointer) ++i;
    CONTRACT_CHECK(i < heap_live);
    heap[i] = heap[--heap_live];
    std::free(pointer);
}
}
void * operator new(size_t bytes) { return tracked_new(bytes); }
void * operator new[](size_t bytes) { return tracked_new(bytes); }
void * operator new(size_t bytes, const std::nothrow_t &) noexcept {
    try { return tracked_new(bytes); } catch (...) { return nullptr; }
}
void * operator new[](size_t bytes, const std::nothrow_t &) noexcept {
    try { return tracked_new(bytes); } catch (...) { return nullptr; }
}
void operator delete(void * pointer) noexcept { tracked_delete(pointer); }
void operator delete[](void * pointer) noexcept { tracked_delete(pointer); }
void operator delete(void * pointer, size_t) noexcept { tracked_delete(pointer); }
void operator delete[](void * pointer, size_t) noexcept { tracked_delete(pointer); }
void operator delete(void * pointer, const std::nothrow_t &) noexcept { tracked_delete(pointer); }
void operator delete[](void * pointer, const std::nothrow_t &) noexcept { tracked_delete(pointer); }

// Complete the real header's opaque types only in the fake implementation TU.
// These are test resources, not layouts or mirrored initializers from whisper.cpp.
struct whisper_context { unsigned identity; };
struct whisper_state { unsigned identity; unsigned context_identity; };
namespace {
enum class Failure {
    none, model_null, model_throw, engine_allocation, state_null, state_throw,
    decode_error, decode_throw, language_throw, segments_throw, text_throw,
    text_allocation, cancel_during_decode,
};
Failure failure = Failure::none;
int patch_revision = 1;
whisper_context context_resource{};
whisper_state state_resource{};
bool context_live = false;
bool state_live = false;
unsigned context_generation = 0;
unsigned state_generation = 0;
int model_calls = 0;
int context_frees = 0;
int state_calls = 0;
int state_frees = 0;
int decode_calls = 0;
int log_calls = 0;
int defaults_calls = 0;
// Test-only trigger: cancellation is raised after a successful fake state acquire.
ow_cancel * state_init_cancel_target = nullptr;
const char * expected_language = "auto";
int expected_threads = 2;
int expected_samples = 3;
bool expected_gpu = true;
char segments[3][256]{};
const float pcm[] = {0.0f, 0.25f, -0.25f};
const char expected_text[] = "Grüße, nicht löschen. Keep 42 and code_x.";

void reset_segments() {
    std::snprintf(segments[0], sizeof(segments[0]), "%s", "Grüße, nicht löschen. ");
    std::snprintf(segments[1], sizeof(segments[1]), "%s", "Keep 42 and code_x.");
    segments[2][0] = '\0';
}
void reset_case() {
    CONTRACT_CHECK(!context_live && !state_live && heap_live == 0 && !fail_next_new);
    failure = Failure::none;
    patch_revision = 1;
    model_calls = context_frees = state_calls = state_frees = decode_calls = 0;
    log_calls = defaults_calls = 0;
    state_init_cancel_target = nullptr;
    expected_language = "auto";
    expected_threads = 2;
    expected_samples = 3;
    expected_gpu = true;
    reset_segments();
}
void check_result(ow_result * result, int status, const char * text = "") {
    CONTRACT_CHECK(result && ow_result_status(result) == status);
    CONTRACT_CHECK(std::strcmp(ow_result_text(result), text) == 0);
}
void check_quiescent() {
    CONTRACT_CHECK(!context_live && !state_live && heap_live == 0 && !fail_next_new);
}
ow_engine * create_engine() {
    auto * engine = ow_engine_create("fixture-model.bin", expected_gpu ? 1 : 0);
    CONTRACT_CHECK(engine && context_live && !state_live);
    return engine;
}
ow_result * decode(ow_engine * engine, ow_cancel * cancel) {
    return ow_engine_decode(engine, cancel, pcm, size_t(expected_samples), 16000,
                            expected_language, expected_threads);
}
void clear_optional_environment() {
    // Affects only this standalone fixture process; parent/host env is unchanged.
    CONTRACT_CHECK(unsetenv("ANEFORGE_ENCODER") == 0);
    CONTRACT_CHECK(unsetenv("ANEFORGE_DYLIB") == 0);
}
}

extern "C" int whisper_clavune_state_ownership_patch_revision(void) { return patch_revision; }
extern "C" void whisper_log_set(ggml_log_callback callback, void * user_data) {
    ++log_calls;
    CONTRACT_CHECK(callback && !user_data);
}
extern "C" whisper_context_params whisper_context_default_params(void) {
    whisper_context_params params{};
    params.use_gpu = true;
    params.flash_attn = true;
    return params;
}
extern "C" whisper_context * whisper_init_from_file_with_params_no_state(
        const char * path, whisper_context_params params) {
    ++model_calls;
    CONTRACT_CHECK(path && std::strcmp(path, "fixture-model.bin") == 0);
    CONTRACT_CHECK(params.use_gpu == expected_gpu && !params.flash_attn);
    CONTRACT_CHECK(!context_live);
    if (failure == Failure::model_null) return nullptr;
    if (failure == Failure::model_throw) throw 17;
    context_live = true;
    context_resource.identity = ++context_generation;
    if (failure == Failure::engine_allocation) fail_next_new = true;
    return &context_resource;
}
extern "C" void whisper_free(whisper_context * context) {
    CONTRACT_CHECK(context == &context_resource && context_live && !state_live);
    context_live = false;
    ++context_frees;
}
extern "C" whisper_state * whisper_init_state(whisper_context * context) {
    ++state_calls;
    CONTRACT_CHECK(context == &context_resource && context_live && !state_live);
    if (failure == Failure::state_null) return nullptr;
    if (failure == Failure::state_throw) throw 23;
    state_live = true;
    state_resource = {++state_generation, context->identity};
    if (state_init_cancel_target) ow_cancel_set(state_init_cancel_target);
    return &state_resource;
}
extern "C" void whisper_free_state(whisper_state * state) {
    CONTRACT_CHECK(state == &state_resource && state_live);
    CONTRACT_CHECK(state->context_identity == context_resource.identity && context_live);
    state_live = false;
    ++state_frees;
}
extern "C" whisper_full_params whisper_full_default_params(whisper_sampling_strategy strategy) {
    ++defaults_calls;
    CONTRACT_CHECK(strategy == WHISPER_SAMPLING_GREEDY);
    whisper_full_params params{};
    params.strategy = strategy;
    // Relevant real defaults, not the bridge's desired effective values:
    // whisper.cpp d1be6fde11ac6e0407606b4e42fe72d34add8037,
    // src/whisper.cpp::whisper_full_default_params (including its greedy branch).
    // The pinned source/header hashes are checked by prepare-native-contract-inputs.py.
    // Other unused defaults remain inert; this is not a simulated decoder.
    params.print_progress = true;
    params.print_timestamps = true;
    params.temperature_inc = 0.2f;
    params.greedy.best_of = 5;
    return params;
}
extern "C" int whisper_full_with_state(whisper_context * context, whisper_state * state,
        whisper_full_params params, const float * samples, int count) {
    ++decode_calls;
    CONTRACT_CHECK(context == &context_resource && context_live && state == &state_resource && state_live);
    CONTRACT_CHECK(samples == pcm && count == expected_samples);
    CONTRACT_CHECK(params.strategy == WHISPER_SAMPLING_GREEDY && params.n_threads == expected_threads);
    CONTRACT_CHECK(params.language && std::strcmp(params.language, expected_language) == 0);
    CONTRACT_CHECK(!params.detect_language && !params.translate && params.no_context);
    CONTRACT_CHECK(!params.print_progress);
    CONTRACT_CHECK(!params.print_timestamps);
    CONTRACT_CHECK(!params.print_realtime && !params.print_special);
    CONTRACT_CHECK(!params.no_timestamps && !params.token_timestamps && !params.single_segment);
    CONTRACT_CHECK(params.max_tokens == 0 && params.audio_ctx == 0 && !params.debug_mode);
    CONTRACT_CHECK(!params.initial_prompt && !params.prompt_tokens && params.prompt_n_tokens == 0 && !params.carry_initial_prompt);
    CONTRACT_CHECK(params.temperature_inc == 0.0f);
    CONTRACT_CHECK(params.temperature == 0.0f && params.greedy.best_of == 1);
    CONTRACT_CHECK(!params.vad && !params.vad_model_path);
    CONTRACT_CHECK(params.abort_callback && params.abort_callback_user_data);
    CONTRACT_CHECK(params.encoder_begin_callback && params.encoder_begin_callback_user_data == params.abort_callback_user_data);
    if (state_init_cancel_target) {
        // Regression-observation path: allow a missing bridge guard to return so
        // the named test fails specifically on unexpected full-decode admission.
        CONTRACT_CHECK(params.abort_callback(params.abort_callback_user_data));
        return 0;
    }
    CONTRACT_CHECK(!params.abort_callback(params.abort_callback_user_data));
    CONTRACT_CHECK(params.encoder_begin_callback(context, state, params.encoder_begin_callback_user_data));
    if (failure == Failure::cancel_during_decode) {
        ow_cancel_set(static_cast<ow_cancel *>(params.abort_callback_user_data));
        CONTRACT_CHECK(params.abort_callback(params.abort_callback_user_data));
        CONTRACT_CHECK(!params.encoder_begin_callback(context, state, params.encoder_begin_callback_user_data));
        return 0; // Bridge cancellation must win even over a success return.
    }
    if (failure == Failure::decode_throw) throw 29;
    return failure == Failure::decode_error ? 4 : 0;
}
// Test-only trigger after decode has returned success and the first segment
// has already been copied into the bridge-owned result.
namespace {
ow_cancel * segment_cancel_target = nullptr;
int segment_cancel_fires = 0;
}
extern "C" int whisper_full_lang_id_from_state(whisper_state * state) {
    CONTRACT_CHECK(state == &state_resource && state_live);
    if (failure == Failure::language_throw) throw 31;
    return 7;
}
extern "C" int whisper_full_n_segments_from_state(whisper_state * state) {
    CONTRACT_CHECK(state == &state_resource && state_live);
    if (failure == Failure::segments_throw) throw 37;
    return 3;
}
extern "C" const char * whisper_full_get_segment_text_from_state(whisper_state * state, int index) {
    CONTRACT_CHECK(state == &state_resource && state_live && index >= 0 && index < 3);
    if (failure == Failure::text_throw) throw 41;
    if (failure == Failure::text_allocation && index == 0) fail_next_new = true;
    if (segment_cancel_target && index == 1) {
        ++segment_cancel_fires;
        ow_cancel_set(segment_cancel_target);
    }
    return index == 2 ? nullptr : segments[index];
}

static void adversarial_decoder_defaults() {
    reset_case();
    const auto upstream = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    CONTRACT_CHECK(upstream.print_progress && upstream.print_timestamps);
    CONTRACT_CHECK(upstream.temperature_inc == 0.2f && upstream.greedy.best_of == 5);
    reset_case();
    auto * engine = create_engine();
    auto * cancel = ow_cancel_create();
    CONTRACT_CHECK(cancel);
    auto * result = decode(engine, cancel); // Assertions inspect the effective fake decode parameters.
    check_result(result, 0, expected_text);
    CONTRACT_CHECK(defaults_calls == 1 && decode_calls == 1);
    ow_result_destroy(result);
    ow_cancel_destroy(cancel);
    ow_engine_destroy(engine);
    check_quiescent();
}
static void creation_and_allocation_failures() {
    reset_case();
    CONTRACT_CHECK(!ow_engine_create(nullptr, 1) && model_calls == 0 && log_calls == 0);
    for (int revision : {0, 2}) {
        patch_revision = revision;
        CONTRACT_CHECK(!ow_engine_create("fixture-model.bin", 1) && model_calls == 0);
    }
    patch_revision = 1;
    for (Failure mode : {Failure::model_null, Failure::model_throw, Failure::engine_allocation}) {
        failure = mode;
        int prior_frees = context_frees;
        CONTRACT_CHECK(!ow_engine_create("fixture-model.bin", 1));
        CONTRACT_CHECK(context_frees == prior_frees + (mode == Failure::engine_allocation ? 1 : 0));
        check_quiescent();
        std::printf("R01 creation_failure=%d observed=null contexts_freed=%d live_heap=%d\n", int(mode), context_frees, heap_live);
    }
    fail_next_new = true;
    CONTRACT_CHECK(!ow_cancel_create() && !fail_next_new);
    failure = Failure::none;
    expected_gpu = false;
    auto * engine = create_engine();
    ow_engine_destroy(engine);
    check_quiescent();
}
static void actual_environment_call_sites() {
    for (const char * name : {"ANEFORGE_ENCODER", "ANEFORGE_DYLIB"}) {
        for (const char * value : {"", "fixture-unapproved"}) {
            reset_case();
            CONTRACT_CHECK(setenv(name, value, 1) == 0);
            CONTRACT_CHECK(!ow_engine_create("fixture-model.bin", 1) && model_calls == 0);
            CONTRACT_CHECK(unsetenv(name) == 0);
            auto * engine = create_engine();
            auto * cancel = ow_cancel_create();
            CONTRACT_CHECK(cancel);
            CONTRACT_CHECK(setenv(name, value, 1) == 0);
            auto * result = decode(engine, cancel);
            check_result(result, 3);
            CONTRACT_CHECK(state_calls == 0 && decode_calls == 0);
            CONTRACT_CHECK(unsetenv(name) == 0);
            ow_result_destroy(result);
            ow_cancel_destroy(cancel);
            ow_engine_destroy(engine);
            check_quiescent();
            std::printf("R02 environment_gate expected_status=3 observed_status=3 state_calls=%d decode_calls=%d live_heap=%d\n",
                        state_calls, decode_calls, heap_live);
        }
    }
}
static void admission_and_result_allocation() {
    reset_case();
    auto * engine = create_engine();
    auto * cancel = ow_cancel_create();
    CONTRACT_CHECK(cancel);
    const int baseline_heap = heap_live;
    int admission_case = 0;
    auto invalid = [&](ow_engine * candidate_engine, ow_cancel * candidate_cancel,
                       const float * samples, size_t count, int rate, const char * language, int threads) {
        auto * result = ow_engine_decode(candidate_engine, candidate_cancel, samples, count, rate, language, threads);
        check_result(result, 2);
        CONTRACT_CHECK(ow_result_language(result) == -1 && state_calls == 0 && decode_calls == 0);
        ow_result_destroy(result);
        CONTRACT_CHECK(heap_live == baseline_heap);
        std::printf("R03-%d admission expected_status=2 observed_status=2 state_calls=%d decode_calls=%d owned_heap=%d\n",
                    admission_case++, state_calls, decode_calls, heap_live);
    };
    invalid(nullptr, cancel, pcm, 3, 16000, "auto", 2);
    invalid(engine, nullptr, pcm, 3, 16000, "auto", 2);
    invalid(engine, cancel, nullptr, 3, 16000, "auto", 2);
    invalid(engine, cancel, pcm, 0, 16000, "auto", 2);
    invalid(engine, cancel, pcm, 3, 24000, "auto", 2);
    invalid(engine, cancel, pcm, size_t(16000 * 120) + 1, 16000, "auto", 2);
    invalid(engine, cancel, pcm, size_t(std::numeric_limits<int>::max()) + 1, 16000, "auto", 2);
    invalid(engine, cancel, pcm, 3, 16000, nullptr, 2);
    invalid(engine, cancel, pcm, 3, 16000, "fr", 2);
    invalid(engine, cancel, pcm, 3, 16000, "auto", 0);
    invalid(engine, cancel, pcm, 3, 16000, "auto", 9);
    const float nan_pcm[] = {0.0f, std::numeric_limits<float>::quiet_NaN()};
    const float infinity_pcm[] = {std::numeric_limits<float>::infinity()};
    invalid(engine, cancel, nan_pcm, 2, 16000, "auto", 2);
    invalid(engine, cancel, infinity_pcm, 1, 16000, "auto", 2);
    fail_next_new = true;
    CONTRACT_CHECK(!decode(engine, cancel));
    CONTRACT_CHECK(!fail_next_new && heap_live == baseline_heap && state_calls == 0);
    ow_cancel_set(cancel);
    auto * result = decode(engine, cancel);
    check_result(result, 1);
    CONTRACT_CHECK(state_calls == 0 && decode_calls == 0);
    ow_result_destroy(result);
    ow_cancel_destroy(cancel);
    ow_engine_destroy(engine);
    check_quiescent();
}
static void cancellation_after_state_acquisition_skips_full_decode() {
    reset_case();
    auto * engine = create_engine();
    auto * cancel = ow_cancel_create();
    CONTRACT_CHECK(cancel);
    const int baseline_heap = heap_live;
    state_init_cancel_target = cancel;
    auto * result = decode(engine, cancel);
    state_init_cancel_target = nullptr;

    check_result(result, 1);
    CONTRACT_CHECK(ow_result_language(result) == -1);
    CONTRACT_CHECK(decode_calls == 0); // Exact one-site mutation oracle.
    CONTRACT_CHECK(defaults_calls == 0);
    CONTRACT_CHECK(state_calls == 1 && state_frees == 1 && !state_live);
    CONTRACT_CHECK(context_live && context_frees == 0 && model_calls == 1);
    const int cancelled_full_calls = decode_calls;
    const int cancelled_state_frees = state_frees;
    ow_result_destroy(result);
    CONTRACT_CHECK(heap_live == baseline_heap);
    ow_cancel_destroy(cancel);

    // A fresh independent request still uses the retained model normally.
    auto * next_cancel = ow_cancel_create();
    CONTRACT_CHECK(next_cancel);
    auto * next_result = decode(engine, next_cancel);
    check_result(next_result, 0, expected_text);
    CONTRACT_CHECK(state_calls == 2 && state_frees == 2 && !state_live);
    CONTRACT_CHECK(decode_calls == 1 && defaults_calls == 1);
    CONTRACT_CHECK(context_live && context_frees == 0 && model_calls == 1);
    ow_result_destroy(next_result);
    ow_cancel_destroy(next_cancel);
    ow_engine_destroy(engine);
    CONTRACT_CHECK(context_frees == 1);
    check_quiescent();
    std::printf("E1 post_state_cancel expected_full_calls=0 observed_full_calls=%d cancelled_state_frees=%d retained_model_calls=%d final_live_heap=%d\n", cancelled_full_calls, cancelled_state_frees, model_calls, heap_live);
}

static void cancellation_during_result_extraction_discards_partial_copy() {
    reset_case();
    CONTRACT_CHECK(segment_cancel_target == nullptr);
    segment_cancel_fires = 0;
    auto * engine = create_engine();
    auto * cancel = ow_cancel_create();
    CONTRACT_CHECK(cancel);
    const int baseline_heap = heap_live;
    segment_cancel_target = cancel;
    auto * result = decode(engine, cancel);
    segment_cancel_target = nullptr;

    CONTRACT_CHECK(segment_cancel_fires == 1);
    check_result(result, 1); // First segment was copied before cancellation.
    CONTRACT_CHECK(ow_result_language(result) == -1);
    CONTRACT_CHECK(state_calls == 1 && state_frees == 1 && !state_live);
    CONTRACT_CHECK(decode_calls == 1 && context_live && context_frees == 0);
    ow_result_destroy(result);
    CONTRACT_CHECK(heap_live == baseline_heap);
    ow_cancel_destroy(cancel);

    // Cancellation is per request; the retained model remains usable.
    auto * next_cancel = ow_cancel_create();
    CONTRACT_CHECK(next_cancel);
    auto * next_result = decode(engine, next_cancel);
    check_result(next_result, 0, expected_text);
    CONTRACT_CHECK(ow_result_language(next_result) == 7);
    ow_result_destroy(next_result);
    ow_cancel_destroy(next_cancel);
    ow_engine_destroy(engine);
    CONTRACT_CHECK(context_frees == 1);
    check_quiescent();
}

static void state_decode_and_result_failure_cleanup() {
    const Failure modes[] = {Failure::state_null, Failure::state_throw, Failure::decode_error,
        Failure::decode_throw, Failure::language_throw, Failure::segments_throw,
        Failure::text_throw, Failure::text_allocation, Failure::cancel_during_decode};
    for (Failure mode : modes) {
        reset_case();
        auto * engine = create_engine();
        auto * cancel = ow_cancel_create();
        CONTRACT_CHECK(cancel);
        const int baseline_heap = heap_live;
        failure = mode;
        if (mode == Failure::text_allocation) {
            std::memset(segments[0], 'x', sizeof(segments[0]) - 1);
            segments[0][sizeof(segments[0]) - 1] = '\0';
        }
        auto * result = decode(engine, cancel);
        check_result(result, mode == Failure::cancel_during_decode ? 1 : 3);
        CONTRACT_CHECK(ow_result_language(result) == -1);
        CONTRACT_CHECK(state_calls == 1 && !state_live);
        const bool state_acquired = mode != Failure::state_null && mode != Failure::state_throw;
        CONTRACT_CHECK(state_frees == (state_acquired ? 1 : 0));
        CONTRACT_CHECK(decode_calls == (state_acquired ? 1 : 0));
        CONTRACT_CHECK(defaults_calls == (state_acquired ? 1 : 0));
        CONTRACT_CHECK(context_live && context_frees == 0 && !fail_next_new);
        ow_result_destroy(result);
        CONTRACT_CHECK(heap_live == baseline_heap);
        ow_cancel_destroy(cancel);
        ow_engine_destroy(engine);
        CONTRACT_CHECK(context_frees == 1);
        check_quiescent();
        std::printf("R04 mode=%d expected_status=%d observed_status=%d state_calls=%d state_frees=%d context_frees=%d live_heap=%d\n",
                    int(mode), mode == Failure::cancel_during_decode ? 1 : 3,
                    mode == Failure::cancel_during_decode ? 1 : 3, state_calls, state_frees, context_frees, heap_live);
    }
}
static void successful_copy_and_independent_lifetimes() {
    reset_case();
    auto * engine = create_engine();
    auto * cancel = ow_cancel_create();
    CONTRACT_CHECK(cancel);
    ow_result * results[3]{};
    const char * languages[] = {"auto", "de", "en"};
    const int threads[] = {1, 2, 8};
    unsigned previous_state_generation = state_generation;
    for (int index = 0; index < 3; ++index) {
        expected_language = languages[index];
        expected_threads = threads[index];
        results[index] = decode(engine, cancel);
        check_result(results[index], 0, expected_text);
        CONTRACT_CHECK(ow_result_language(results[index]) == 7);
        CONTRACT_CHECK(state_generation > previous_state_generation && !state_live && context_live);
        previous_state_generation = state_generation;
    }
    CONTRACT_CHECK(state_calls == 3 && state_frees == 3 && decode_calls == 3 && defaults_calls == 3);
    // Overwrite all upstream text storage, then destroy context and token. Each
    // actual ow_result must retain its own copied text and language.
    std::memset(segments, 0, sizeof(segments));
    ow_engine_destroy(engine);
    ow_cancel_destroy(cancel);
    CONTRACT_CHECK(!context_live && context_frees == 1);
    for (auto * result : results) {
        check_result(result, 0, expected_text);
        CONTRACT_CHECK(ow_result_language(result) == 7);
        ow_result_destroy(result);
    }
    check_quiescent();
}
static void null_boundary_and_provenance() {
    CONTRACT_CHECK(ow_result_status(nullptr) == 3 && ow_result_language(nullptr) == -1);
    CONTRACT_CHECK(std::strcmp(ow_result_text(nullptr), "") == 0);
    ow_result_destroy(nullptr);
    ow_engine_destroy(nullptr);
    ow_cancel_set(nullptr);
    ow_cancel_destroy(nullptr);
    CONTRACT_CHECK(ow_backend_state_ownership_patch_revision() == 1);
    CONTRACT_CHECK(std::strcmp(ow_backend_fingerprint(),
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") == 0);
}
int main(int argc, char ** argv) {
    struct Test { const char * name; void (*run)(); };
    const Test tests[] = {
        {"BridgeContractTests.adversarial_decoder_defaults", adversarial_decoder_defaults},
        {"BridgeContractTests.null_boundary_and_provenance", null_boundary_and_provenance},
        {"BridgeContractTests.creation_and_allocation_failures", creation_and_allocation_failures},
        {"BridgeContractTests.actual_environment_call_sites", actual_environment_call_sites},
        {"BridgeContractTests.admission_and_result_allocation", admission_and_result_allocation},
        {"BridgeContractTests.cancellation_after_state_acquisition_skips_full_decode", cancellation_after_state_acquisition_skips_full_decode},
        {"BridgeContractTests.cancellation_during_result_extraction_discards_partial_copy", cancellation_during_result_extraction_discards_partial_copy},
        {"BridgeContractTests.state_decode_and_result_failure_cleanup", state_decode_and_result_failure_cleanup},
        {"BridgeContractTests.successful_copy_and_independent_lifetimes", successful_copy_and_independent_lifetimes},
    };
    const char * selected = nullptr;
    if (argc == 3 && std::strcmp(argv[1], "--test") == 0) selected = argv[2];
    else if (argc == 2 && std::strcmp(argv[1], "--list-tests") == 0) {
        for (const auto & test : tests) std::puts(test.name);
        return 0;
    } else if (argc != 1) {
        std::fputs("Usage: bridge-contract [--test exact-name | --list-tests]\n", stderr);
        return 2;
    }
    int count = 0;
    for (const auto & test : tests) {
        if (!selected || std::strcmp(selected, test.name) == 0) ++count;
    }
    if (count == 0) {
        std::fputs("No exact native test selected.\n", stderr);
        return 2;
    }
    clear_optional_environment();
    std::fprintf(stderr, "NATIVE_TEST_COUNT %d\n", count);
    for (const auto & test : tests) {
        if (selected && std::strcmp(selected, test.name) != 0) continue;
        // The flushed START and exact source-bound CONTRACT_CHECK diagnostic bind
        // an intentional abort to this named case, not to an earlier test's log.
        std::fprintf(stderr, "NATIVE_TEST_START %s\n", test.name);
        std::fflush(stderr);
        test.run();
        check_quiescent();
        std::fprintf(stderr, "NATIVE_TEST_PASS %s\n", test.name);
        std::fflush(stderr);
    }
    std::fprintf(stderr, "NATIVE_TEST_COMPLETE %d\n", count);
    std::puts("Actual bridge contract passed under fake Whisper entry points; no backend/model linked.");
}
