#pragma once

#include "../../protocol/generated/cpp/denial_generated.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <vector>

namespace Denial::BridgeWire {

    constexpr uint16_t    PROTOCOL_VERSION  = 1;
    constexpr size_t      MAX_MESSAGE_BYTES = 1024 * 1024;
    constexpr size_t      MAX_WINDOWS       = 4096;
    constexpr size_t      MAX_REGIONS       = 8192;
    constexpr size_t      MAX_SURFACES      = 32768;
    constexpr size_t      MAX_STRING_BYTES  = 4096;

    constexpr const char* TO_NATIVE_CHANNEL  = "denial/wire/to_native";
    constexpr const char* TO_FLUTTER_CHANNEL = "denial/wire/to_flutter";

    constexpr uint32_t    INPUT_LAYOUT_KEYBOARD_CAPTURE = 1U << 0;
    constexpr uint32_t    INPUT_LAYOUT_EXCLUSIVE_SHELL  = 1U << 1;
    constexpr uint32_t    INPUT_LAYOUT_FLAGS_MASK       = INPUT_LAYOUT_KEYBOARD_CAPTURE | INPUT_LAYOUT_EXCLUSIVE_SHELL;

    constexpr uint32_t    INPUT_WINDOW_VISIBLE           = 1U << 0;
    constexpr uint32_t    INPUT_WINDOW_HIT_TEST_DISABLED = 1U << 1;
    constexpr uint32_t    INPUT_WINDOW_GEOMETRY_LOCKED   = 1U << 2;
    constexpr uint32_t    INPUT_WINDOW_FLAGS_MASK        = INPUT_WINDOW_VISIBLE | INPUT_WINDOW_HIT_TEST_DISABLED | INPUT_WINDOW_GEOMETRY_LOCKED;

    constexpr uint32_t    KEYBOARD_CTRL       = 1U << 0;
    constexpr uint32_t    KEYBOARD_FLAGS_MASK = KEYBOARD_CTRL;

    enum class ERejectReason : uint8_t {
        None,
        Size,
        FlatBuffer,
        Version,
        Sequence,
        Payload,
        Direction,
        Count,
        Identity,
        Enumeration,
        Geometry,
        Flags,
        Ordering,
        String,
        RequestId,
    };

    const Wire::Envelope*                       verifyIncoming(const uint8_t* data, size_t size, ERejectReason& reason);
    std::shared_ptr<const std::vector<uint8_t>> verifyAndOwnIncoming(const uint8_t* data, size_t size, ERejectReason& reason);
    const Wire::Envelope*                       envelopeFromOwned(const std::vector<uint8_t>& data);

    enum class EPlacementPhase : uint8_t {
        Begin  = 0,
        Update = 1,
        End    = 2,
    };

    enum class EPlacementChange : uint8_t {
        Move   = 0,
        Resize = 1,
    };

    struct SPlacementPacket {
        uint64_t         sequence    = 0;
        uint64_t         windowId    = 0;
        int64_t          monitorId   = -1;
        int64_t          workspaceId = -1;
        EPlacementPhase  phase       = EPlacementPhase::Update;
        EPlacementChange change      = EPlacementChange::Move;
        double           x           = 0.0;
        double           y           = 0.0;
        double           width       = 0.0;
        double           height      = 0.0;
    };

    constexpr size_t                                          PLACEMENT_PACKET_SIZE = 80;

    std::optional<std::array<uint8_t, PLACEMENT_PACKET_SIZE>> encodePlacement(const SPlacementPacket& packet);
    std::optional<SPlacementPacket>                           decodePlacement(const uint8_t* data, size_t size);

    struct SDragIconPacket {
        uint64_t sequence            = 0;
        bool     active              = false;
        uint64_t surfaceId           = 0;
        uint64_t textureId           = 0;
        uint32_t width               = 0;
        uint32_t height              = 0;
        uint32_t transform           = 0;
        uint32_t scale120            = 120;
        double   offsetX             = 0.0;
        double   offsetY             = 0.0;
        double   surfaceWidth        = 0.0;
        double   surfaceHeight       = 0.0;
        double   textureSourceX      = 0.0;
        double   textureSourceY      = 0.0;
        double   textureSourceWidth  = 0.0;
        double   textureSourceHeight = 0.0;
    };

    constexpr size_t                                          DRAG_ICON_PACKET_SIZE = 128;

    std::optional<std::array<uint8_t, DRAG_ICON_PACKET_SIZE>> encodeDragIcon(const SDragIconPacket& packet);
    std::optional<SDragIconPacket>                            decodeDragIcon(const uint8_t* data, size_t size);

} // namespace Denial::BridgeWire
