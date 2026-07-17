#pragma once

#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>

namespace Denial::ClosingTextureLease {

    inline constexpr char          COMPLETION_CHANNEL[]       = "denial/window_close_complete";
    inline constexpr size_t        COMPLETION_MESSAGE_SIZE    = sizeof(uint64_t);
    inline constexpr uint64_t      WATCHDOG_TIMEOUT_US        = 1'500'000;
    inline constexpr size_t        MAX_ACTIVE_LEASES          = 8;
    inline constexpr size_t        MAX_ESTIMATED_BUFFER_BYTES = 256U * 1024U * 1024U;

    inline std::optional<uint64_t> decodeCompletion(const uint8_t* message, size_t messageSize) {
        if (!message || messageSize != COMPLETION_MESSAGE_SIZE)
            return std::nullopt;

        uint64_t windowId = 0;
        for (size_t index = 0; index < COMPLETION_MESSAGE_SIZE; ++index)
            windowId |= static_cast<uint64_t>(message[index]) << (index * 8U);

        return windowId == 0 ? std::nullopt : std::optional<uint64_t>{windowId};
    }

    inline constexpr size_t estimateBufferBytes(uint32_t width, uint32_t height) {
        if (width == 0 || height == 0)
            return 0;

        constexpr size_t BYTES_PER_PIXEL = 4;
        if (static_cast<size_t>(width) > std::numeric_limits<size_t>::max() / static_cast<size_t>(height) / BYTES_PER_PIXEL)
            return std::numeric_limits<size_t>::max();

        return static_cast<size_t>(width) * static_cast<size_t>(height) * BYTES_PER_PIXEL;
    }

} // namespace Denial::ClosingTextureLease
