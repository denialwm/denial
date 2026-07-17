#include "Runtime.hpp"
#include "RuntimeFlutterState.hpp"
#include "Wire.hpp"

#include "../src/debug/log/Logger.hpp"
#include "../src/managers/eventLoop/EventLoopManager.hpp"

#include <atomic>
#include <memory>
#include <utility>
#include <vector>

namespace Denial {

    uint64_t CRuntime::nextWireSequence() {
        const auto sequence = m_nextWireSequence.fetch_add(1, std::memory_order_relaxed);
        if (sequence != 0)
            return sequence;

        m_nextWireSequence.store(2, std::memory_order_relaxed);
        return 1;
    }

    bool CRuntime::sendWirePayload(flatbuffers::FlatBufferBuilder& builder, Wire::Payload payloadType, flatbuffers::Offset<void> payload, uint64_t requestId) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return false;

        const auto envelope = Wire::CreateEnvelope(builder, BridgeWire::PROTOCOL_VERSION, nextWireSequence(), requestId, payloadType, payload);
        Wire::FinishEnvelopeBuffer(builder, envelope);
        if (builder.GetSize() > BridgeWire::MAX_MESSAGE_BYTES)
            return false;

        return denial_engine_host_send_platform_message(m_flutter->host, BridgeWire::TO_FLUTTER_CHANNEL, builder.GetBufferPointer(), builder.GetSize());
    }

    void CRuntime::handleWireMessage(std::shared_ptr<const std::vector<uint8_t>> message) {
        if (!message)
            return;

        const auto* envelope = BridgeWire::envelopeFromOwned(*message);
        if (!envelope)
            return;

        switch (envelope->payload_type()) {
            case Wire::Payload_InputLayout: installInputLayoutSnapshot(std::move(message)); break;
            case Wire::Payload_WindowRequest:
                if (const auto* request = envelope->payload_as_WindowRequest())
                    handleWindowRequestMessage(*request, envelope->request_id());
                break;
            case Wire::Payload_KeyboardCommand:
                if (const auto* command = envelope->payload_as_KeyboardCommand())
                    handleKeyboardMessage(*command);
                break;
            case Wire::Payload_DesktopNotificationCommand:
                if (const auto* command = envelope->payload_as_DesktopNotificationCommand())
                    handleNotificationCommandMessage(*command);
                break;
            default: break;
        }
    }

    void CRuntime::handleWindowRequestMessage(const Wire::WindowRequest& request, uint64_t requestId) {
        if (secureSessionLocked() && request.kind() != Wire::WindowRequestKind_ListWindows && request.kind() != Wire::WindowRequestKind_GetDisplayLayout)
            return;

        switch (request.kind()) {
            case Wire::WindowRequestKind_ListWindows: sendWindowListResponse(requestId); break;
            case Wire::WindowRequestKind_GetDisplayLayout: sendDisplayLayoutResponse(requestId); break;
            case Wire::WindowRequestKind_CloseWindow: closeWindowById(request.window_id()); break;
            case Wire::WindowRequestKind_FocusWindow: focusWindowById(request.window_id()); break;
            case Wire::WindowRequestKind_ConfigureWindow:
                if (const auto* geometry = request.geometry())
                    configureWindowById(request.window_id(), CBox{geometry->x(), geometry->y(), geometry->width(), geometry->height()});
                break;
        }
    }

    void CRuntime::onWireMessage(const char* channel, const uint8_t* message, size_t messageSize, void* userData) {
        (void)channel;
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime)
            return;

        BridgeWire::ERejectReason reason = BridgeWire::ERejectReason::None;
        auto                      owned  = BridgeWire::verifyAndOwnIncoming(message, messageSize, reason);
        if (!owned) {
            const auto rejected = runtime->m_rejectedWireMessages.fetch_add(1, std::memory_order_relaxed) + 1;
            if (rejected == 1)
                Log::logger->log(Log::WARN, "Denial rejected wire message reason={} size={}", sc<uint8_t>(reason), messageSize);
            return;
        }

        // Input layout is the live routing snapshot used by pointer hit tests.
        // The former JSON input-regions channel installed it synchronously;
        // queueing it with commands makes routing lag behind Flutter's scene.
        const auto* envelope = BridgeWire::envelopeFromOwned(*owned);
        if (envelope && envelope->payload_type() == Wire::Payload_InputLayout) {
            runtime->installInputLayoutSnapshot(std::move(owned));
            return;
        }

        if (!g_pEventLoopManager) {
            runtime->handleWireMessage(std::move(owned));
            return;
        }

        g_pEventLoopManager->postToLoop([runtime, owned = std::move(owned)]() mutable { runtime->handleWireMessage(std::move(owned)); });
    }

} // namespace Denial
