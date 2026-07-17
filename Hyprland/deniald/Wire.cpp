#include "Wire.hpp"

#include <bit>
#include <cmath>
#include <cstring>
#include <limits>

namespace Denial::BridgeWire {

    namespace {
        constexpr std::array<uint8_t, 4> PLACEMENT_MAGIC = {'D', 'E', 'N', 'P'};
        constexpr uint16_t               PLACEMENT_KIND  = 2;
        constexpr std::array<uint8_t, 4> DRAG_ICON_MAGIC = {'D', 'E', 'N', 'D'};
        constexpr uint16_t               DRAG_ICON_KIND  = 3;
        constexpr uint32_t               DRAG_ICON_ACTIVE = 1U << 0;

        bool finitePositiveRect(const Wire::WireRect& rect) {
            return std::isfinite(rect.x()) && std::isfinite(rect.y()) && std::isfinite(rect.width()) && std::isfinite(rect.height()) && rect.width() > 0.0 && rect.height() > 0.0;
        }

        bool finitePositiveRect(const Wire::WireRect* rect) {
            return rect && finitePositiveRect(*rect);
        }

        bool finiteRectAtLeast(const Wire::WireRect* rect, double minimumSize) {
            return rect && std::isfinite(rect->x()) && std::isfinite(rect->y()) && std::isfinite(rect->width()) && std::isfinite(rect->height()) && rect->width() >= minimumSize &&
                rect->height() >= minimumSize;
        }

        bool validString(const flatbuffers::String* value, bool allowEmpty = false) {
            return value && value->size() <= MAX_STRING_BYTES && (allowEmpty || !value->empty());
        }

        bool validEnum(uint8_t value, uint8_t minimum, uint8_t maximum) {
            return value >= minimum && value <= maximum;
        }

        bool validateInputLayout(const Wire::InputLayout* layout, ERejectReason& reason) {
            if (!layout) {
                reason = ERejectReason::Payload;
                return false;
            }

            const auto* shellRegions = layout->shell_regions();
            const auto* windows      = layout->windows();
            const auto* visibleSurfaceIds = layout->visible_surface_ids();
            if ((shellRegions && shellRegions->size() > MAX_REGIONS) || (windows && windows->size() > MAX_REGIONS) ||
                (visibleSurfaceIds && visibleSurfaceIds->size() > MAX_SURFACES)) {
                reason = ERejectReason::Count;
                return false;
            }

            if (shellRegions) {
                for (const auto* rect : *shellRegions) {
                    if (!finitePositiveRect(rect)) {
                        reason = ERejectReason::Geometry;
                        return false;
                    }
                }
            }

            if (windows) {
                const Wire::InputWindowRegion* previous = nullptr;
                for (const auto* window : *windows) {
                    if (!window || window->object_id() == 0 || window->surface_id() == 0 || window->window_id() == 0) {
                        reason = ERejectReason::Identity;
                        return false;
                    }
                    if (!finitePositiveRect(window->rect()) || !finitePositiveRect(window->source_rect())) {
                        reason = ERejectReason::Geometry;
                        return false;
                    }
                    if (previous && (previous->z() < window->z() || (previous->z() == window->z() && previous->surface_id() < window->surface_id()))) {
                        reason = ERejectReason::Ordering;
                        return false;
                    }
                    previous = window;
                }
            }

            if (visibleSurfaceIds) {
                for (const auto surfaceId : *visibleSurfaceIds) {
                    if (surfaceId == 0) {
                        reason = ERejectReason::Identity;
                        return false;
                    }
                }
            }

            return true;
        }

        bool validateWindowRequest(const Wire::Envelope& envelope, const Wire::WindowRequest* request, ERejectReason& reason) {
            if (!request) {
                reason = ERejectReason::Payload;
                return false;
            }

            const auto rawKind = static_cast<uint8_t>(request->kind());
            if (!validEnum(rawKind, Wire::WindowRequestKind_MIN, Wire::WindowRequestKind_MAX)) {
                reason = ERejectReason::Enumeration;
                return false;
            }

            switch (request->kind()) {
                case Wire::WindowRequestKind_ListWindows:
                case Wire::WindowRequestKind_GetDisplayLayout:
                    if (envelope.request_id() == 0) {
                        reason = ERejectReason::RequestId;
                        return false;
                    }
                    return true;
                case Wire::WindowRequestKind_CloseWindow:
                case Wire::WindowRequestKind_FocusWindow:
                    if (request->window_id() == 0) {
                        reason = ERejectReason::Identity;
                        return false;
                    }
                    return true;
                case Wire::WindowRequestKind_ConfigureWindow: {
                    const auto* geometry = request->geometry();
                    if (request->window_id() == 0) {
                        reason = ERejectReason::Identity;
                        return false;
                    }
                    if (!finiteRectAtLeast(geometry, 64.0) || geometry->x() < 0.0 || geometry->y() < 0.0 || geometry->x() > 16384.0 || geometry->y() > 16384.0 ||
                        geometry->width() > 16384.0 || geometry->height() > 16384.0) {
                        reason = ERejectReason::Geometry;
                        return false;
                    }
                    return true;
                }
            }

            reason = ERejectReason::Enumeration;
            return false;
        }

        bool validateKeyboardCommand(const Wire::KeyboardCommand* command, ERejectReason& reason) {
            if (!command) {
                reason = ERejectReason::Payload;
                return false;
            }

            const auto rawKind = static_cast<uint8_t>(command->kind());
            if (!validEnum(rawKind, Wire::KeyboardCommandKind_MIN, Wire::KeyboardCommandKind_MAX)) {
                reason = ERejectReason::Enumeration;
                return false;
            }
            if ((command->flags() & ~KEYBOARD_FLAGS_MASK) != 0) {
                reason = ERejectReason::Flags;
                return false;
            }

            const auto* value = command->kind() == Wire::KeyboardCommandKind_Text ? command->text() : command->key();
            if (!validString(value)) {
                reason = ERejectReason::String;
                return false;
            }
            return true;
        }

        bool validateNotificationCommand(const Wire::DesktopNotificationCommand* command, ERejectReason& reason) {
            if (!command) {
                reason = ERejectReason::Payload;
                return false;
            }

            const auto rawKind = static_cast<uint8_t>(command->kind());
            if (!validEnum(rawKind, Wire::DesktopNotificationCommandKind_MIN, Wire::DesktopNotificationCommandKind_MAX)) {
                reason = ERejectReason::Enumeration;
                return false;
            }
            if (command->notification_id() == 0) {
                reason = ERejectReason::Identity;
                return false;
            }

            const auto* actionKey = command->action_key();
            if (command->kind() == Wire::DesktopNotificationCommandKind_InvokeAction) {
                if (!validString(actionKey)) {
                    reason = ERejectReason::String;
                    return false;
                }
            } else if (actionKey && !actionKey->empty()) {
                reason = ERejectReason::String;
                return false;
            }
            return true;
        }

        uint16_t readUint16LE(const uint8_t* bytes) {
            return static_cast<uint16_t>(bytes[0]) | (static_cast<uint16_t>(bytes[1]) << 8);
        }

        uint32_t readUint32LE(const uint8_t* bytes) {
            uint32_t value = 0;
            for (size_t index = 0; index < sizeof(value); ++index)
                value |= static_cast<uint32_t>(bytes[index]) << (index * 8);
            return value;
        }

        uint64_t readUint64LE(const uint8_t* bytes) {
            uint64_t value = 0;
            for (size_t index = 0; index < sizeof(value); ++index)
                value |= static_cast<uint64_t>(bytes[index]) << (index * 8);
            return value;
        }

        double readDoubleLE(const uint8_t* bytes) {
            return std::bit_cast<double>(readUint64LE(bytes));
        }

        void writeUint16LE(uint8_t* bytes, uint16_t value) {
            for (size_t index = 0; index < sizeof(value); ++index)
                bytes[index] = static_cast<uint8_t>((value >> (index * 8)) & 0xff);
        }

        void writeUint32LE(uint8_t* bytes, uint32_t value) {
            for (size_t index = 0; index < sizeof(value); ++index)
                bytes[index] = static_cast<uint8_t>((value >> (index * 8)) & 0xff);
        }

        void writeUint64LE(uint8_t* bytes, uint64_t value) {
            for (size_t index = 0; index < sizeof(value); ++index)
                bytes[index] = static_cast<uint8_t>((value >> (index * 8)) & 0xff);
        }

        void writeDoubleLE(uint8_t* bytes, double value) {
            writeUint64LE(bytes, std::bit_cast<uint64_t>(value));
        }
    } // namespace

    const Wire::Envelope* verifyIncoming(const uint8_t* data, size_t size, ERejectReason& reason) {
        reason = ERejectReason::None;
        if (!data || size < 12 || size > MAX_MESSAGE_BYTES) {
            reason = ERejectReason::Size;
            return nullptr;
        }

        flatbuffers::Verifier::Options options;
        options.max_depth  = 16;
        options.max_tables = 16384;
        options.max_size   = MAX_MESSAGE_BYTES + 1;
        flatbuffers::Verifier verifier(data, size, options);
        if (!Wire::VerifyEnvelopeBuffer(verifier)) {
            reason = ERejectReason::FlatBuffer;
            return nullptr;
        }

        const auto* envelope = Wire::GetEnvelope(data);
        if (!envelope || envelope->protocol_version() != PROTOCOL_VERSION) {
            reason = ERejectReason::Version;
            return nullptr;
        }
        if (envelope->sequence() == 0) {
            reason = ERejectReason::Sequence;
            return nullptr;
        }

        const auto payloadType = envelope->payload_type();
        switch (payloadType) {
            case Wire::Payload_InputLayout: return validateInputLayout(envelope->payload_as_InputLayout(), reason) ? envelope : nullptr;
            case Wire::Payload_WindowRequest: return validateWindowRequest(*envelope, envelope->payload_as_WindowRequest(), reason) ? envelope : nullptr;
            case Wire::Payload_KeyboardCommand: return validateKeyboardCommand(envelope->payload_as_KeyboardCommand(), reason) ? envelope : nullptr;
            case Wire::Payload_DesktopNotificationCommand: return validateNotificationCommand(envelope->payload_as_DesktopNotificationCommand(), reason) ? envelope : nullptr;
            case Wire::Payload_NONE: reason = ERejectReason::Payload; return nullptr;
            default: reason = ERejectReason::Direction; return nullptr;
        }
    }

    std::shared_ptr<const std::vector<uint8_t>> verifyAndOwnIncoming(const uint8_t* data, size_t size, ERejectReason& reason) {
        if (!verifyIncoming(data, size, reason))
            return nullptr;
        return std::make_shared<const std::vector<uint8_t>>(data, data + size);
    }

    const Wire::Envelope* envelopeFromOwned(const std::vector<uint8_t>& data) {
        return data.empty() ? nullptr : Wire::GetEnvelope(data.data());
    }

    std::optional<std::array<uint8_t, PLACEMENT_PACKET_SIZE>> encodePlacement(const SPlacementPacket& packet) {
        if (packet.sequence == 0 || packet.windowId == 0 || !std::isfinite(packet.x) || !std::isfinite(packet.y) || !std::isfinite(packet.width) || !std::isfinite(packet.height) ||
            packet.width < 1.0 || packet.height < 1.0 || packet.monitorId < 0 || packet.workspaceId == -1 ||
            static_cast<uint8_t>(packet.phase) > static_cast<uint8_t>(EPlacementPhase::End) || static_cast<uint8_t>(packet.change) > static_cast<uint8_t>(EPlacementChange::Resize))
            return {};

        std::array<uint8_t, PLACEMENT_PACKET_SIZE> bytes = {};
        std::memcpy(bytes.data(), PLACEMENT_MAGIC.data(), PLACEMENT_MAGIC.size());
        writeUint16LE(bytes.data() + 4, PROTOCOL_VERSION);
        writeUint16LE(bytes.data() + 6, PLACEMENT_KIND);
        writeUint32LE(bytes.data() + 8, PLACEMENT_PACKET_SIZE);
        writeUint64LE(bytes.data() + 12, packet.sequence);
        writeUint64LE(bytes.data() + 20, packet.windowId);
        writeUint64LE(bytes.data() + 28, std::bit_cast<uint64_t>(packet.monitorId));
        writeUint64LE(bytes.data() + 36, std::bit_cast<uint64_t>(packet.workspaceId));
        bytes[44] = static_cast<uint8_t>(packet.phase);
        bytes[45] = static_cast<uint8_t>(packet.change);
        writeDoubleLE(bytes.data() + 48, packet.x);
        writeDoubleLE(bytes.data() + 56, packet.y);
        writeDoubleLE(bytes.data() + 64, packet.width);
        writeDoubleLE(bytes.data() + 72, packet.height);
        return bytes;
    }

    std::optional<SPlacementPacket> decodePlacement(const uint8_t* data, size_t size) {
        if (!data || size != PLACEMENT_PACKET_SIZE || !std::equal(PLACEMENT_MAGIC.begin(), PLACEMENT_MAGIC.end(), data) || readUint16LE(data + 4) != PROTOCOL_VERSION ||
            readUint16LE(data + 6) != PLACEMENT_KIND || readUint32LE(data + 8) != PLACEMENT_PACKET_SIZE || data[46] != 0 || data[47] != 0)
            return {};

        SPlacementPacket packet{
            .sequence    = readUint64LE(data + 12),
            .windowId    = readUint64LE(data + 20),
            .monitorId   = std::bit_cast<int64_t>(readUint64LE(data + 28)),
            .workspaceId = std::bit_cast<int64_t>(readUint64LE(data + 36)),
            .phase       = static_cast<EPlacementPhase>(data[44]),
            .change      = static_cast<EPlacementChange>(data[45]),
            .x           = readDoubleLE(data + 48),
            .y           = readDoubleLE(data + 56),
            .width       = readDoubleLE(data + 64),
            .height      = readDoubleLE(data + 72),
        };
        if (packet.sequence == 0 || packet.windowId == 0 || packet.monitorId < 0 || packet.workspaceId == -1 || data[44] > static_cast<uint8_t>(EPlacementPhase::End) ||
            data[45] > static_cast<uint8_t>(EPlacementChange::Resize) || !std::isfinite(packet.x) || !std::isfinite(packet.y) || !std::isfinite(packet.width) ||
            !std::isfinite(packet.height) || packet.width < 1.0 || packet.height < 1.0)
            return {};
        return packet;
    }

    std::optional<std::array<uint8_t, DRAG_ICON_PACKET_SIZE>> encodeDragIcon(const SDragIconPacket& packet) {
        if (packet.sequence == 0)
            return {};

        if (packet.active &&
            (packet.surfaceId == 0 || packet.textureId == 0 || packet.width == 0 || packet.height == 0 || packet.transform > 7 || packet.scale120 == 0 || !std::isfinite(packet.offsetX) ||
             !std::isfinite(packet.offsetY) || !std::isfinite(packet.surfaceWidth) || !std::isfinite(packet.surfaceHeight) || !std::isfinite(packet.textureSourceX) ||
             !std::isfinite(packet.textureSourceY) || !std::isfinite(packet.textureSourceWidth) || !std::isfinite(packet.textureSourceHeight) || packet.surfaceWidth <= 0.0 ||
             packet.surfaceHeight <= 0.0 || packet.textureSourceX < 0.0 || packet.textureSourceY < 0.0 || packet.textureSourceWidth <= 0.0 ||
             packet.textureSourceHeight <= 0.0 || packet.textureSourceX + packet.textureSourceWidth > packet.width ||
             packet.textureSourceY + packet.textureSourceHeight > packet.height))
            return {};

        std::array<uint8_t, DRAG_ICON_PACKET_SIZE> bytes = {};
        std::memcpy(bytes.data(), DRAG_ICON_MAGIC.data(), DRAG_ICON_MAGIC.size());
        writeUint16LE(bytes.data() + 4, PROTOCOL_VERSION);
        writeUint16LE(bytes.data() + 6, DRAG_ICON_KIND);
        writeUint32LE(bytes.data() + 8, DRAG_ICON_PACKET_SIZE);
        writeUint64LE(bytes.data() + 12, packet.sequence);
        writeUint32LE(bytes.data() + 20, packet.active ? DRAG_ICON_ACTIVE : 0);
        writeUint64LE(bytes.data() + 28, packet.surfaceId);
        writeUint64LE(bytes.data() + 36, packet.textureId);
        writeUint32LE(bytes.data() + 44, packet.width);
        writeUint32LE(bytes.data() + 48, packet.height);
        writeUint32LE(bytes.data() + 52, packet.transform);
        writeUint32LE(bytes.data() + 56, packet.scale120);
        writeDoubleLE(bytes.data() + 64, packet.offsetX);
        writeDoubleLE(bytes.data() + 72, packet.offsetY);
        writeDoubleLE(bytes.data() + 80, packet.surfaceWidth);
        writeDoubleLE(bytes.data() + 88, packet.surfaceHeight);
        writeDoubleLE(bytes.data() + 96, packet.textureSourceX);
        writeDoubleLE(bytes.data() + 104, packet.textureSourceY);
        writeDoubleLE(bytes.data() + 112, packet.textureSourceWidth);
        writeDoubleLE(bytes.data() + 120, packet.textureSourceHeight);
        return bytes;
    }

    std::optional<SDragIconPacket> decodeDragIcon(const uint8_t* data, size_t size) {
        if (!data || size != DRAG_ICON_PACKET_SIZE || !std::equal(DRAG_ICON_MAGIC.begin(), DRAG_ICON_MAGIC.end(), data) || readUint16LE(data + 4) != PROTOCOL_VERSION ||
            readUint16LE(data + 6) != DRAG_ICON_KIND || readUint32LE(data + 8) != DRAG_ICON_PACKET_SIZE || readUint32LE(data + 24) != 0 ||
            readUint32LE(data + 60) != 0)
            return {};

        const auto FLAGS = readUint32LE(data + 20);
        if ((FLAGS & ~DRAG_ICON_ACTIVE) != 0)
            return {};

        SDragIconPacket packet{
            .sequence            = readUint64LE(data + 12),
            .active              = (FLAGS & DRAG_ICON_ACTIVE) != 0,
            .surfaceId           = readUint64LE(data + 28),
            .textureId           = readUint64LE(data + 36),
            .width               = readUint32LE(data + 44),
            .height              = readUint32LE(data + 48),
            .transform           = readUint32LE(data + 52),
            .scale120            = readUint32LE(data + 56),
            .offsetX             = readDoubleLE(data + 64),
            .offsetY             = readDoubleLE(data + 72),
            .surfaceWidth        = readDoubleLE(data + 80),
            .surfaceHeight       = readDoubleLE(data + 88),
            .textureSourceX      = readDoubleLE(data + 96),
            .textureSourceY      = readDoubleLE(data + 104),
            .textureSourceWidth  = readDoubleLE(data + 112),
            .textureSourceHeight = readDoubleLE(data + 120),
        };
        if (packet.sequence == 0)
            return {};
        if (!packet.active)
            return packet;

        if (packet.surfaceId == 0 || packet.textureId == 0 || packet.width == 0 || packet.height == 0 || packet.transform > 7 || packet.scale120 == 0 || !std::isfinite(packet.offsetX) ||
            !std::isfinite(packet.offsetY) || !std::isfinite(packet.surfaceWidth) || !std::isfinite(packet.surfaceHeight) || !std::isfinite(packet.textureSourceX) ||
            !std::isfinite(packet.textureSourceY) || !std::isfinite(packet.textureSourceWidth) || !std::isfinite(packet.textureSourceHeight) || packet.surfaceWidth <= 0.0 ||
            packet.surfaceHeight <= 0.0 || packet.textureSourceX < 0.0 || packet.textureSourceY < 0.0 || packet.textureSourceWidth <= 0.0 ||
            packet.textureSourceHeight <= 0.0 || packet.textureSourceX + packet.textureSourceWidth > packet.width ||
            packet.textureSourceY + packet.textureSourceHeight > packet.height)
            return {};
        return packet;
    }

} // namespace Denial::BridgeWire
