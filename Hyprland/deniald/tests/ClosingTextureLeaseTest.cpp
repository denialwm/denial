#include "../ClosingTextureLease.hpp"

#include <array>
#include <cassert>
#include <cstdint>

int main() {
    using namespace Denial::ClosingTextureLease;

    static_assert(estimateBufferBytes(1920, 1080) == 1920U * 1080U * 4U);
    static_assert(estimateBufferBytes(0, 1080) == 0);
    static_assert(MAX_ACTIVE_LEASES > 0);
    static_assert(MAX_ESTIMATED_BUFFER_BYTES >= estimateBufferBytes(7680, 4320));
    static_assert(WATCHDOG_TIMEOUT_US > 400'000);

    const std::array<uint8_t, COMPLETION_MESSAGE_SIZE> valid   = {0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01};
    const auto                                         decoded = decodeCompletion(valid.data(), valid.size());
    assert(decoded.has_value());
    assert(*decoded == 0x0102030405060708ULL);

    const std::array<uint8_t, COMPLETION_MESSAGE_SIZE> zero = {};
    assert(!decodeCompletion(zero.data(), zero.size()));
    assert(!decodeCompletion(valid.data(), valid.size() - 1));
    assert(!decodeCompletion(nullptr, valid.size()));
    return 0;
}
