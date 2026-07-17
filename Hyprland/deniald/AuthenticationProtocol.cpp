#include "AuthenticationProtocol.hpp"

#include <algorithm>
#include <array>

namespace Denial::AuthenticationProtocol {

    namespace {
        constexpr std::array<uint8_t, 4> MAGIC = {'D', 'A', 'U', 'T'};

        uint16_t                         read16(const uint8_t* bytes) {
            return static_cast<uint16_t>(bytes[0]) | (static_cast<uint16_t>(bytes[1]) << 8);
        }

        uint32_t read32(const uint8_t* bytes) {
            uint32_t value = 0;
            for (size_t index = 0; index < sizeof(value); ++index)
                value |= static_cast<uint32_t>(bytes[index]) << (index * 8);
            return value;
        }

        uint64_t read64(const uint8_t* bytes) {
            uint64_t value = 0;
            for (size_t index = 0; index < sizeof(value); ++index)
                value |= static_cast<uint64_t>(bytes[index]) << (index * 8);
            return value;
        }

        void write16(uint8_t* bytes, uint16_t value) {
            bytes[0] = static_cast<uint8_t>(value & 0xffu);
            bytes[1] = static_cast<uint8_t>((value >> 8) & 0xffu);
        }

        void write32(uint8_t* bytes, uint32_t value) {
            for (size_t index = 0; index < sizeof(value); ++index)
                bytes[index] = static_cast<uint8_t>((value >> (index * 8)) & 0xffu);
        }

        void write64(uint8_t* bytes, uint64_t value) {
            for (size_t index = 0; index < sizeof(value); ++index)
                bytes[index] = static_cast<uint8_t>((value >> (index * 8)) & 0xffu);
        }

        bool knownKind(uint8_t raw) {
            switch (static_cast<EKind>(raw)) {
                case EKind::Sync:
                case EKind::Lock:
                case EKind::Begin:
                case EKind::Respond:
                case EKind::Cancel:
                case EKind::State:
                case EKind::Prompt:
                case EKind::Result: return true;
            }
            return false;
        }
    } // namespace

    std::optional<SPacketView> decode(const uint8_t* bytes, size_t size) {
        if (!bytes || size < HEADER_SIZE || size > MAX_PACKET_BYTES || !std::equal(MAGIC.begin(), MAGIC.end(), bytes) || read16(bytes + 4) != VERSION)
            return {};

        const auto rawKind       = bytes[6];
        const auto payloadLength = read32(bytes + 20);
        if (!knownKind(rawKind) || payloadLength > MAX_PAYLOAD_BYTES || HEADER_SIZE + payloadLength != size)
            return {};

        const auto payload = std::string_view{reinterpret_cast<const char*>(bytes + HEADER_SIZE), payloadLength};
        // PAM responses are C strings. Reject embedded NULs instead of silently
        // authenticating a truncated credential.
        if (payload.find('\0') != std::string_view::npos)
            return {};

        return SPacketView{
            .kind      = static_cast<EKind>(rawKind),
            .flags     = bytes[7],
            .attemptId = read64(bytes + 8),
            .argument  = read32(bytes + 16),
            .payload   = payload,
        };
    }

    std::vector<uint8_t> encode(EKind kind, uint8_t flags, uint64_t attemptId, uint32_t argument, std::string_view payload) {
        if (payload.size() > MAX_PAYLOAD_BYTES || payload.find('\0') != std::string_view::npos || !knownKind(static_cast<uint8_t>(kind)))
            return {};

        std::vector<uint8_t> packet(HEADER_SIZE + payload.size(), 0);
        std::copy(MAGIC.begin(), MAGIC.end(), packet.begin());
        write16(packet.data() + 4, VERSION);
        packet[6] = static_cast<uint8_t>(kind);
        packet[7] = flags;
        write64(packet.data() + 8, attemptId);
        write32(packet.data() + 16, argument);
        write32(packet.data() + 20, static_cast<uint32_t>(payload.size()));
        std::copy(payload.begin(), payload.end(), packet.begin() + HEADER_SIZE);
        return packet;
    }

} // namespace Denial::AuthenticationProtocol
