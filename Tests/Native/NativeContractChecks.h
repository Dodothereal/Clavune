#ifndef CLAVUNE_NATIVE_CONTRACT_CHECKS_H
#define CLAVUNE_NATIVE_CONTRACT_CHECKS_H
#include <cstdio>
#include <cstdlib>
// Always active, including if a caller supplies -DNDEBUG.
#define CONTRACT_CHECK(condition) do { \
    if (!(condition)) { \
        std::fprintf(stderr, "Contract check failed: %s (%s:%d)\n", #condition, __FILE__, __LINE__); \
        std::abort(); \
    } \
} while (false)
#endif
