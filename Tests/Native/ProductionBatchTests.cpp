#include "NativeContractChecks.h"
#include "whisper.h"
#include "whisper-init-ownership.h"
#include <algorithm>
#include <cstring>
#include <limits>

namespace {
struct Allocation { void * pointer; size_t bytes; };
Allocation live[16]{};
size_t observed_sizes[16]{};
int live_count = 0;
int attempts = 0;
int frees = 0;
int fail_at = -1;

void * batch_test_allocate(size_t bytes) {
    CONTRACT_CHECK(bytes > 0 && bytes <= 256);
    CONTRACT_CHECK(attempts < 16);
    observed_sizes[attempts] = bytes;
    if (attempts++ == fail_at) return nullptr;
    CONTRACT_CHECK(live_count < 16);
    void * pointer = std::malloc(bytes);
    CONTRACT_CHECK(pointer);
    // The production table-zeroing statement must repair nonzero pointer bytes.
    std::memset(pointer, 0xa5, bytes);
    live[live_count++] = {pointer, bytes};
    return pointer;
}
void batch_test_free(void * pointer) {
    CONTRACT_CHECK(pointer); // Production guards all nullable fields itself.
    int index = 0;
    while (index < live_count && live[index].pointer != pointer) ++index;
    CONTRACT_CHECK(index < live_count); // Check identity before invalid/double free.
    live[index] = live[--live_count];
    ++frees;
    std::free(pointer);
}
size_t allocation_size(void * pointer) {
    for (int index = 0; index < live_count; ++index) {
        if (live[index].pointer == pointer) return live[index].bytes;
    }
    CONTRACT_CHECK(false);
    return 0;
}
void reset_case(int failing_allocation) {
    CONTRACT_CHECK(live_count == 0);
    attempts = 0;
    frees = 0;
    fail_at = failing_allocation;
    std::fill_n(observed_sizes, 16, size_t(0));
}
}

// Only these two allocation boundaries are replaced. The generated include is
// byte-for-byte production struct/prototype/init/free source, including its own
// owner, size checks, table initialization, loop, release and cleanup order.
#define whisper_checked_malloc(bytes) whisper_checked_malloc((bytes), batch_test_allocate)
#define free(pointer) batch_test_free(pointer)
#include "ClavuneProductionBatch.inc"
#undef free
#undef whisper_checked_malloc

static void allocation_failures(int cycle) {
    for (int site = 0; site < 10; ++site) {
        reset_case(site);
        bool caught = false;
        try {
            (void)whisper_batch_init(5, 3);
        } catch (const std::bad_alloc &) { caught = true; }
        CONTRACT_CHECK(caught);
        CONTRACT_CHECK(attempts == site + 1);
        CONTRACT_CHECK(frees == site && live_count == 0);
        std::printf("B%02d cycle=%d injected_allocation=%d expected=bad_alloc observed=bad_alloc attempts=%d frees=%d live=%d\n",
                    site + 1, cycle, site, attempts, frees, live_count);
    }
}
static void success_and_real_typed_sizes(int cycle) {
    reset_case(-1);
    auto batch = whisper_batch_init(5, 3);
    CONTRACT_CHECK(attempts == 10 && live_count == 10 && frees == 0);
    CONTRACT_CHECK(batch.n_tokens == 0 && batch.seq_id[5] == nullptr);
    CONTRACT_CHECK(allocation_size(batch.token) == 5 * sizeof(whisper_token));
    CONTRACT_CHECK(allocation_size(batch.pos) == 5 * sizeof(whisper_pos));
    CONTRACT_CHECK(allocation_size(batch.n_seq_id) == 5 * sizeof(int32_t));
    CONTRACT_CHECK(allocation_size(batch.seq_id) == 6 * sizeof(whisper_seq_id *));
    CONTRACT_CHECK(allocation_size(batch.logits) == 5 * sizeof(int8_t));
    for (int row = 0; row < 5; ++row) {
        CONTRACT_CHECK(allocation_size(batch.seq_id[row]) == 3 * sizeof(whisper_seq_id));
        batch.token[row] = whisper_token(row);
        batch.pos[row] = whisper_pos(100 + row);
        batch.n_seq_id[row] = 3;
        batch.logits[row] = int8_t(row == 4);
        for (int seq = 0; seq < 3; ++seq) batch.seq_id[row][seq] = whisper_seq_id(seq);
    }
    // Exact request order includes all rows before the logits allocation.
    const size_t expected[] = {5 * sizeof(whisper_token), 5 * sizeof(whisper_pos),
        5 * sizeof(int32_t), 6 * sizeof(whisper_seq_id *), 3 * sizeof(whisper_seq_id),
        3 * sizeof(whisper_seq_id), 3 * sizeof(whisper_seq_id), 3 * sizeof(whisper_seq_id),
        3 * sizeof(whisper_seq_id), 5 * sizeof(int8_t)};
    for (int site = 0; site < 10; ++site) CONTRACT_CHECK(observed_sizes[site] == expected[site]);
    whisper_batch_free(batch);
    CONTRACT_CHECK(frees == 10 && live_count == 0);
    std::printf("B11 cycle=%d typed_success allocations=%d frees=%d live=%d\n", cycle, attempts, frees, live_count);
}
static void empty_cleanup_and_invalid_dimensions(int cycle) {
    reset_case(-1);
    whisper_batch_free(whisper_batch{});
    CONTRACT_CHECK(attempts == 0 && frees == 0 && live_count == 0);
    const int32_t dimensions[][2] = {{0, 3}, {-1, 3}, {5, 0}, {5, -1},
        {std::numeric_limits<int32_t>::min(), 3}, {5, std::numeric_limits<int32_t>::min()}};
    int dimension_case = 0;
    for (const auto & values : dimensions) {
        bool caught = false;
        try { (void)whisper_batch_init(values[0], values[1]); }
        catch (const std::bad_alloc &) { caught = true; }
        CONTRACT_CHECK(caught && attempts == 0 && frees == 0 && live_count == 0);
        std::printf("B12-%d cycle=%d dimensions=%d,%d expected=bad_alloc observed=bad_alloc attempts=%d live=%d\n",
                    dimension_case++, cycle, values[0], values[1], attempts, live_count);
    }
}
int main() {
    for (int cycle = 0; cycle < 4; ++cycle) {
        allocation_failures(cycle);
        success_and_real_typed_sizes(cycle);
        empty_cleanup_and_invalid_dimensions(cycle);
    }
    std::puts("Exact production batch init/free passed: 10 allocation failures, typed success, empty cleanup, 6 invalid dimensions; 4 cycles.");
}
