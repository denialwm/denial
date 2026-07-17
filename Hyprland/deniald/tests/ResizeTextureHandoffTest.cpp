#include "../ResizeTextureHandoff.hpp"

#include <cassert>

int main() {
    using namespace Denial::ResizeTextureHandoff;

    constexpr SSize SOURCE{.width = 1000.0, .height = 700.0};
    constexpr SSize TARGET{.width = 1600.0, .height = 900.0};
    constexpr SSize SURFACE{.width = 1000.0, .height = 700.0};

    assert(resizeActive(TARGET, SOURCE));
    assert(!resizeActive(SOURCE, SOURCE));

    const auto expected = expectedSurfaceSize(SURFACE, TARGET, SOURCE);
    assert(expected.has_value());
    assert(approximatelyEqual(expected->width, 1600.0));
    assert(approximatelyEqual(expected->height, 900.0));

    // A client can allocate a larger pixel buffer while its logical viewport
    // is still old. Readiness follows logical surface geometry, not allocation.
    assert(!surfaceMatchesTarget(SURFACE, SOURCE, TARGET, SOURCE));
    assert(surfaceMatchesTarget(SURFACE, *expected, TARGET, SOURCE));

    constexpr uint64_t START    = 1'000'000;
    constexpr uint64_t DEADLINE = START + MAX_WAIT_US;
    assert(!candidateReady(START, DEADLINE, START + CONTENT_SETTLE_US - 1));
    assert(candidateReady(START, DEADLINE, START + CONTENT_SETTLE_US));
    assert(candidateReady(0, DEADLINE, DEADLINE));
    assert(nextWakeUs(START, DEADLINE) == START + CONTENT_SETTLE_US);
    return 0;
}
