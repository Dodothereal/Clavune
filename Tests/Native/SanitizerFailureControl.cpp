// A separate, test-only diagnostic control. Never link into a contract target,
// production library or app. The runner requires the diagnostic at this site.
#include <cstdio>
#include <limits>

int main() {
    std::fputs("UBSAN_CONTROL_START signed_integer_overflow\n", stderr);
    std::fflush(stderr);
    volatile int maximum = std::numeric_limits<int>::max();
    volatile int one = 1;
    const int overflow = maximum + one; // UBSAN_CONTROL_SITE
    std::fprintf(stderr, "UBSAN_CONTROL_UNEXPECTED_SURVIVAL %d\n", overflow);
    return 0; // Recovering/absent UBSan must fail the runner's control gate.
}
