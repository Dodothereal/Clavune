// Isolated fault injection of the exact ownership helpers applied to whisper.cpp.
// Counting fakes do not initialize a model, GGML backend, GPU or microphone.
#include "whisper-init-ownership.h"
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <stdexcept>

static bool fail_next_allocation = false;
void * operator new(std::size_t bytes) {
    if (fail_next_allocation) {
        fail_next_allocation = false;
        throw std::bad_alloc();
    }
    if (void * result = std::malloc(bytes == 0 ? 1 : bytes)) return result;
    throw std::bad_alloc();
}
void operator delete(void * memory) noexcept { std::free(memory); }
void operator delete(void * memory, std::size_t) noexcept { std::free(memory); }

static int live_handles = 0;
static int freed_states = 0;
static void * handles[64]{};
struct NativeHandle {
    NativeHandle() {
        assert(live_handles < 64);
        handles[live_handles++] = this;
    }
    ~NativeHandle() {
        int index = 0;
        while (index < live_handles && handles[index] != this) ++index;
        assert(index < live_handles); // Every free must match one live acquisition.
        handles[index] = handles[--live_handles];
    }
};
static void destroy_handle(NativeHandle * value) { delete value; }

// These raw members intentionally have no default initializers. The production
// factory must make partial cleanup safe before any resource acquisition.
struct PartialState {
    NativeHandle * first;
    NativeHandle * second;
    // Synthetic sites stand for logits, 5 decoder reserves, and 4 graph metadata
    // reserves. Injection exercises real std::vector allocation, not real graphs.
    std::vector<float> workspaces[10];
};
static void destroy_state(PartialState * state) {
    delete state->first;
    delete state->second;
    ++freed_states;
    delete state;
}

static void state_allocation_failure() {
    freed_states = 0;
    fail_next_allocation = true;
    try {
        auto state = whisper_make_init_owner<PartialState, destroy_state>();
        (void)state;
        assert(false);
    } catch (const std::bad_alloc &) {}
    assert(!fail_next_allocation && freed_states == 0 && live_handles == 0);
}

static PartialState * empty_backend_failure() {
    auto state = whisper_make_init_owner<PartialState, destroy_state>();
    assert(!state->first && !state->second);
    return nullptr;
}

static void all_reserve_failure_stages() {
    for (int acquired = 0; acquired <= 2; ++acquired) {
        for (int stage = 0; stage < 10; ++stage) {
            freed_states = 0;
            bool caught = false;
            try {
                auto state = whisper_make_init_owner<PartialState, destroy_state>();
                assert(!state->first && !state->second);
                if (acquired > 0) state->first = new NativeHandle;
                if (acquired > 1) state->second = new NativeHandle;
                for (int site = 0; site < 10; ++site) {
                    if (site == stage) fail_next_allocation = true;
                    state->workspaces[site].reserve(16);
                }
            } catch (const std::bad_alloc &) { caught = true; }
            assert(caught && !fail_next_allocation);
            assert(freed_states == 1 && live_handles == 0);
        }
    }
}

static void backend_first_vector_insertion_failure() {
    bool caught = false;
    try {
        whisper_owned_handles<NativeHandle *, destroy_handle> backends;
        auto * acquired = new NativeHandle;
        fail_next_allocation = true; // Empty vector must acquire storage.
        backends.push_back(acquired);
    } catch (const std::bad_alloc &) { caught = true; }
    assert(caught && !fail_next_allocation && live_handles == 0);
}

// This destination fails deterministically at the requested insertion. The same
// production adoption helper is used with std::vector in the actual backend.
struct FaultDestination {
    std::vector<NativeHandle *> values;
    bool fail = false;
    ~FaultDestination() { for (auto * handle : values) destroy_handle(handle); }
    void emplace_back(NativeHandle * handle) {
        if (fail) throw std::bad_alloc();
        values.emplace_back(handle);
    }
};
static void backend_gpu_and_cpu_adoption_failures() {
    for (int insertion = 0; insertion < 2; ++insertion) {
        bool caught = false;
        try {
            FaultDestination backends;
            if (insertion == 1) {
                whisper_adopt_handle<NativeHandle *, destroy_handle>(backends, new NativeHandle);
            }
            backends.fail = true;
            whisper_adopt_handle<NativeHandle *, destroy_handle>(backends, new NativeHandle);
        } catch (const std::bad_alloc &) { caught = true; }
        assert(caught && live_handles == 0);
    }
}
static void backend_cpu_failure_after_gpu() {
    bool caught = false;
    try {
        whisper_owned_handles<NativeHandle *, destroy_handle> backends;
        backends.push_back(new NativeHandle);
        throw std::runtime_error("injected CPU initializer failure");
    } catch (const std::runtime_error &) { caught = true; }
    assert(caught && live_handles == 0);
}
static void backend_success_transfer() {
    std::vector<NativeHandle *> caller_owned;
    {
        whisper_owned_handles<NativeHandle *, destroy_handle> backends;
        backends.push_back(new NativeHandle);
        backends.push_back(new NativeHandle);
        caller_owned = backends.release();
    }
    assert(caller_owned.size() == 2 && live_handles == 2);
    for (auto * handle : caller_owned) destroy_handle(handle);
    assert(live_handles == 0);
}

static bool kv_init_fixture(PartialState & state, int failure_stage) {
    auto context = whisper_own_handle<NativeHandle *, destroy_handle>(
        failure_stage == 0 ? nullptr : new NativeHandle);
    if (!context) return false;
    if (failure_stage == 1) return false; // Backend buffer returned null.
    state.first = new NativeHandle; // Adopted buffer is owned by outer state.
    if (failure_stage == 2) throw std::bad_alloc();
    return true;
}
static PartialState * guarded_kv_fixture(int failure_stage) noexcept {
    try {
        auto owner = whisper_make_init_owner<PartialState, destroy_state>();
        if (!kv_init_fixture(*owner, failure_stage)) return nullptr;
        return owner.release();
    } catch (...) { return nullptr; }
}
static void kv_null_and_throw_failures() {
    for (int stage = 0; stage < 3; ++stage) {
        freed_states = 0;
        assert(guarded_kv_fixture(stage) == nullptr);
        assert(freed_states == 1 && live_handles == 0);
    }
    auto * success = guarded_kv_fixture(-1);
    assert(success && live_handles == 1); // Temporary context already freed.
    destroy_state(success);
    assert(live_handles == 0);
}

static int malloc_calls = 0;
static int malloc_failure = -1;
static int live_blocks = 0;
static void * blocks[64]{};
static void * fault_malloc(size_t bytes) {
    if (malloc_calls++ == malloc_failure) return nullptr;
    void * memory = std::malloc(bytes);
    assert(memory && live_blocks < 64);
    std::memset(memory, 0xa5, bytes); // Detect uninitialized row table cleanup.
    blocks[live_blocks++] = memory;
    return memory;
}
static void free_block(void * memory) {
    if (!memory) return;
    int index = 0;
    while (index < live_blocks && blocks[index] != memory) ++index;
    assert(index < live_blocks); // Assert before an invalid/double free occurs.
    blocks[index] = blocks[--live_blocks];
    std::free(memory);
}
struct BatchFixture {
    char * token;
    char * position;
    char * sequence_count;
    char ** rows;
    char * logits;
};
static void destroy_batch(BatchFixture batch) {
    free_block(batch.token);
    free_block(batch.position);
    free_block(batch.sequence_count);
    if (batch.rows) {
        int row = 0;
        while (batch.rows[row]) {
            assert(row < 5);
            free_block(batch.rows[row++]);
        }
        free_block(batch.rows);
    }
    free_block(batch.logits);
}
static BatchFixture allocate_batch_fixture() {
    whisper_init_value_owner<BatchFixture, destroy_batch> owner;
    auto & batch = owner.get();
    batch.token = static_cast<char *>(whisper_checked_malloc(5, fault_malloc));
    batch.position = static_cast<char *>(whisper_checked_malloc(5, fault_malloc));
    batch.sequence_count = static_cast<char *>(whisper_checked_malloc(5, fault_malloc));
    batch.rows = static_cast<char **>(whisper_checked_malloc(
        whisper_checked_allocation_size(6, sizeof(char *)), fault_malloc));
    std::fill_n(batch.rows, 6, nullptr); // Includes sentinel before row allocation.
    for (int row = 0; row < 5; ++row) {
        batch.rows[row] = static_cast<char *>(whisper_checked_malloc(8, fault_malloc));
    }
    batch.logits = static_cast<char *>(whisper_checked_malloc(5, fault_malloc));
    return owner.release();
}
static void every_batch_malloc_failure() {
    for (int site = 0; site < 10; ++site) {
        malloc_calls = 0;
        malloc_failure = site;
        bool caught = false;
        try { (void)allocate_batch_fixture(); }
        catch (const std::bad_alloc &) { caught = true; }
        assert(caught && malloc_calls == site + 1 && live_blocks == 0);
    }
    malloc_calls = 0;
    malloc_failure = -1;
    auto batch = allocate_batch_fixture();
    assert(malloc_calls == 10 && live_blocks == 10 && !batch.rows[5]);
    destroy_batch(batch);
    assert(live_blocks == 0);
    bool caught = false;
    try { (void)whisper_checked_allocation_size(std::numeric_limits<size_t>::max(), 2); }
    catch (const std::bad_alloc &) { caught = true; }
    assert(caught);
    assert(whisper_checked_allocation_size(5, 8) == 40);
}

static void repeated_failure_then_success_ownership() {
    for (int cycle = 0; cycle < 16; ++cycle) {
        freed_states = 0;
        assert(!empty_backend_failure());
        assert(freed_states == 1 && live_handles == 0);
        assert(!guarded_kv_fixture(cycle % 3));
        assert(freed_states == 2 && live_handles == 0);
        // No pointer from a failed initialization escapes to an unload caller.
        auto * state = guarded_kv_fixture(-1);
        assert(state && state->first && !state->second);
        destroy_state(state);
        assert(freed_states == 3 && live_handles == 0 && live_blocks == 0);
    }
}


// Adjacent model-load coverage uses the same factory, native guard and adoption
// helper as the patched loader. This is not execution of whisper_model_load.
static int freed_models = 0;
static int loader_close_calls = 0;
struct ModelFixture {
    std::vector<NativeHandle *> contexts;
    std::vector<NativeHandle *> buffers;
    PartialState * state;
    std::string path;
};
static void destroy_model(ModelFixture * model) {
    for (auto * context : model->contexts) destroy_handle(context);
    for (auto * buffer : model->buffers) destroy_handle(buffer);
    if (model->state) destroy_state(model->state);
    ++freed_models;
    delete model;
}
struct VectorFaultView {
    std::vector<NativeHandle *> & destination;
    void emplace_back(NativeHandle * handle) {
        assert(!destination.empty() && handle);
        throw std::bad_alloc();
    }
};
static bool populate_model_fixture(ModelFixture & model, int stage) {
    assert(!model.state);
    // Already-adopted allocations must also be freed after a later failure.
    whisper_adopt_handle<NativeHandle *, destroy_handle>(model.contexts, new NativeHandle);
    whisper_adopt_handle<NativeHandle *, destroy_handle>(model.buffers, new NativeHandle);
    auto context = whisper_own_handle<NativeHandle *, destroy_handle>(
        stage == 1 ? nullptr : new NativeHandle);
    if (!context) return false;
    std::map<int, NativeHandle *> context_map;
    if (stage == 2) fail_next_allocation = true;
    context_map.emplace(1, context.get()); // Real map insertion can throw.
    if (stage == 3) {
        VectorFaultView destination{model.contexts};
        whisper_adopt_handle<NativeHandle *, destroy_handle>(destination, context.release());
    } else {
        whisper_adopt_handle<NativeHandle *, destroy_handle>(model.contexts, context.release());
    }
    {
        auto temporary = whisper_own_handle<NativeHandle *, destroy_handle>(
            stage == 4 ? nullptr : new NativeHandle);
        if (!temporary) return false;
        std::vector<float> metadata;
        if (stage == 5) fail_next_allocation = true;
        metadata.reserve(16);
    }
    auto * buffer = stage == 6 ? nullptr : new NativeHandle;
    if (!buffer) return false;
    if (stage == 7) {
        VectorFaultView destination{model.buffers};
        whisper_adopt_handle<NativeHandle *, destroy_handle>(destination, buffer);
    } else {
        whisper_adopt_handle<NativeHandle *, destroy_handle>(model.buffers, buffer);
    }
    if (stage == 8) return false; // Failure after multiple successful adoptions.
    if (stage == 11) throw 7; // Non-standard exception stays inside fake C boundary.
    return true;
}
static ModelFixture * guarded_model_fixture(int stage) noexcept {
    bool close_attempted = false;
    auto close_loader = [&]() {
        if (!close_attempted) {
            close_attempted = true;
            ++loader_close_calls;
            if (stage == 10) throw std::runtime_error("injected close failure");
        }
    };
    try {
        if (stage == 0) fail_next_allocation = true;
        auto owner = whisper_make_init_owner<ModelFixture, destroy_model>();
        if (!populate_model_fixture(*owner, stage)) {
            close_loader();
            return nullptr;
        }
        close_loader();
        return owner.release();
    } catch (...) {
        try { close_loader(); } catch (...) {}
        return nullptr;
    }
}
static ModelFixture * guarded_file_model_fixture(int stage) noexcept {
    try {
        auto owner = whisper_own_handle<ModelFixture *, destroy_model>(guarded_model_fixture(stage));
        if (owner) {
            if (stage == 9) fail_next_allocation = true;
            // Longer than a small-string buffer; assignment acquires real storage.
            owner->path = "a-deliberately-long-fixture-model-path-to-force-string-storage-"
                          "allocation-for-the-post-load-assignment-failure-check.bin";
        }
        return owner.release();
    } catch (...) { return nullptr; }
}
static void model_partial_cleanup_and_path_assignment() {
    for (int cycle = 0; cycle < 8; ++cycle) {
        for (int stage = 0; stage <= 11; ++stage) {
            freed_models = 0;
            loader_close_calls = 0;
            assert(!guarded_file_model_fixture(stage));
            assert(!fail_next_allocation && loader_close_calls == 1);
            assert(freed_models == (stage == 0 ? 0 : 1));
            assert(live_handles == 0 && live_blocks == 0);
        }
        freed_models = 0;
        loader_close_calls = 0;
        auto * success = guarded_file_model_fixture(-1);
        assert(success && !success->state && !success->path.empty());
        assert(loader_close_calls == 1 && live_handles == 4);
        destroy_model(success);
        assert(freed_models == 1 && live_handles == 0 && live_blocks == 0);
    }
}

int main() {
    state_allocation_failure();
    all_reserve_failure_stages();
    backend_first_vector_insertion_failure();
    backend_gpu_and_cpu_adoption_failures();
    backend_cpu_failure_after_gpu();
    backend_success_transfer();
    kv_null_and_throw_failures();
    every_batch_malloc_failure();
    repeated_failure_then_success_ownership();
    model_partial_cleanup_and_path_assignment();
    std::puts("Native ownership helper matrix passed: state allocation, 30 reserve failures, backend adoption/CPU failure, KV null/throw, 10 malloc failures, overflow, success transfer, 16 state recovery cycles, 12 model failure stages across 8 recovery cycles.");
}
