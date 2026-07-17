#pragma once

#include "Wire.hpp"

#include "../src/defines.hpp"
#include "../src/denial/InputRouter.hpp"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace Denial::RuntimeInternal {

    inline uint64_t steadyUs() {
        return sc<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
    }

    inline uint64_t readUint64LE(const uint8_t* bytes) {
        uint64_t value = 0;
        for (size_t i = 0; i < sizeof(value); ++i)
            value |= sc<uint64_t>(bytes[i]) << (i * 8);
        return value;
    }

    inline uint32_t readUint32LE(const uint8_t* bytes) {
        uint32_t value = 0;
        for (size_t i = 0; i < sizeof(value); ++i)
            value |= sc<uint32_t>(bytes[i]) << (i * 8);
        return value;
    }

    inline void writeUint64LE(uint8_t* bytes, uint64_t value) {
        for (size_t i = 0; i < sizeof(value); ++i)
            bytes[i] = sc<uint8_t>((value >> (i * 8)) & 0xff);
    }

    inline void writeUint32LE(uint8_t* bytes, uint32_t value) {
        for (size_t i = 0; i < sizeof(value); ++i)
            bytes[i] = sc<uint8_t>((value >> (i * 8)) & 0xff);
    }

#if defined(DENIAL_ENABLE_DIAGNOSTICS)
    inline constexpr char     IMPORTED_FRAME_TIMING_CHANNEL[]         = "denial/imported_frame_timing";
    inline constexpr char     IMPORTED_FRAME_TIMING_CONTROL_CHANNEL[] = "denial/imported_frame_timing_control";
    inline constexpr uint64_t IMPORTED_FRAME_TIMING_BUCKET_US         = 200000;
    inline constexpr uint64_t IMPORTED_FRAME_TIMING_IDLE_FRAMES       = 8;
    inline constexpr size_t   IMPORTED_FRAME_TIMING_MESSAGE_SIZE      = sizeof(uint64_t) * 7;
#endif

    inline constexpr char           AUDIO_STATE_CHANNEL[]         = "denial/audio_state";
    inline constexpr char           AUDIO_STREAMS_STATE_CHANNEL[] = "denial/audio_streams_state";
    inline constexpr char           BRIGHTNESS_CHANNEL[]          = "denial/brightness";
    inline constexpr char           BRIGHTNESS_STATE_CHANNEL[]    = "denial/brightness_state";
    inline constexpr char           SYSTEM_COMMAND_CHANNEL[]      = "denial/system_command";
    inline constexpr size_t         SYSTEM_COMMAND_HEADER_SIZE    = 1 + sizeof(uint64_t) + sizeof(uint32_t);
    inline constexpr size_t         SYSTEM_COMMAND_MAX_SIZE       = 64 * 1024;
    inline constexpr uint32_t       SYSTEM_COMMAND_MAX_ARGS       = 64;
    inline constexpr uint32_t       SYSTEM_COMMAND_MAX_ARG_SIZE   = 4096;
    inline constexpr size_t         IMPORTED_FRAME_QUEUE_DEPTH    = 3;

    inline constexpr char           HAPTICS_SOCKET_PATH[]      = "/run/denia-hapticsd/socket";
    inline constexpr uint64_t       HAPTICS_MIN_GAP_US         = 18000;
    inline constexpr uint32_t       STATUS_COLOR_FALLBACK_ARGB = 0xff0f1115;

    inline const Wire::InputLayout* inputLayoutFromBuffer(const std::shared_ptr<const std::vector<uint8_t>>& buffer) {
        if (!buffer)
            return nullptr;
        const auto* envelope = BridgeWire::envelopeFromOwned(*buffer);
        return envelope ? envelope->payload_as_InputLayout() : nullptr;
    }

    inline SInputRect inputRectFromWire(const Wire::WireRect& rect) {
        return SInputRect{.x = rect.x(), .y = rect.y(), .w = rect.width(), .h = rect.height()};
    }

} // namespace Denial::RuntimeInternal
