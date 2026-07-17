#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <vector>

namespace Denial::AuthenticationProtocol {

    inline constexpr char     TO_NATIVE_CHANNEL[]  = "denial/authentication";
    inline constexpr char     TO_FLUTTER_CHANNEL[] = "denial/authentication_state";
    inline constexpr size_t   HEADER_SIZE          = 24;
    inline constexpr size_t   MAX_PAYLOAD_BYTES    = 4096;
    inline constexpr size_t   MAX_PACKET_BYTES     = HEADER_SIZE + MAX_PAYLOAD_BYTES;
    inline constexpr uint16_t VERSION              = 1;

    enum class EKind : uint8_t {
        Sync    = 1,
        Lock    = 2,
        Begin   = 3,
        Respond = 4,
        Cancel  = 5,
        State   = 0x81,
        Prompt  = 0x82,
        Result  = 0x83,
    };

    enum EStateFlag : uint8_t {
        STATE_LOCKED       = 1u << 0,
        STATE_AVAILABLE    = 1u << 1,
        STATE_BUSY         = 1u << 2,
        STATE_RATE_LIMITED = 1u << 3,
    };

    enum EResultFlag : uint8_t {
        RESULT_SUCCESS   = 1u << 4,
        RESULT_CANCELLED = 1u << 5,
    };

    inline constexpr uint8_t PROMPT_STYLE_SHIFT = 4;

    struct SPacketView {
        EKind            kind      = EKind::Sync;
        uint8_t          flags     = 0;
        uint64_t         attemptId = 0;
        uint32_t         argument  = 0;
        std::string_view payload;
    };

    std::optional<SPacketView> decode(const uint8_t* bytes, size_t size);
    std::vector<uint8_t>       encode(EKind kind, uint8_t flags, uint64_t attemptId, uint32_t argument, std::string_view payload = {});

} // namespace Denial::AuthenticationProtocol
