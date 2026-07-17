#include "Runtime.hpp"

#include "AuthenticationController.hpp"
#include "AuthenticationProtocol.hpp"
#include "RuntimeFlutterState.hpp"

#include "../src/Compositor.hpp"
#include "../src/debug/log/Logger.hpp"
#include "../src/managers/eventLoop/EventLoopManager.hpp"
#include "../src/managers/input/InputManager.hpp"
#include "../src/render/Renderer.hpp"

#include <algorithm>
#include <format>
#include <string>
#include <string_view>

namespace Denial {

    namespace {
        uint8_t stateFlags(const SAuthenticationSnapshot& state) {
            using namespace AuthenticationProtocol;
            uint8_t flags = 0;
            if (state.locked)
                flags |= STATE_LOCKED;
            if (state.available)
                flags |= STATE_AVAILABLE;
            if (state.busy)
                flags |= STATE_BUSY;
            if (state.cooldownMs > 0)
                flags |= STATE_RATE_LIMITED;
            return flags;
        }

        std::string_view commandArgument(std::string_view request) {
            constexpr std::string_view PREFIX = "denial-lock";
            if (!request.starts_with(PREFIX))
                return {};
            request.remove_prefix(PREFIX.size());
            while (!request.empty() && request.front() == ' ')
                request.remove_prefix(1);
            while (!request.empty() && request.back() == ' ')
                request.remove_suffix(1);
            return request;
        }
    } // namespace

    bool CRuntime::secureSessionLocked() const {
        return m_authenticationController && m_authenticationController->locked();
    }

    void CRuntime::handleAuthenticationMessage(const uint8_t* message, size_t messageSize) {
        if (!m_authenticationController)
            return;

        const auto packet = AuthenticationProtocol::decode(message, messageSize);
        if (!packet)
            return;

        using enum AuthenticationProtocol::EKind;
        switch (packet->kind) {
            case Sync:
                if (packet->payload.empty())
                    m_authenticationController->synchronize();
                break;
            case Lock:
                if (packet->payload.empty())
                    m_authenticationController->lock();
                break;
            case Begin:
                if (packet->payload.empty())
                    m_authenticationController->begin();
                break;
            case Respond: m_authenticationController->respond(packet->attemptId, packet->argument, CSecureString{packet->payload}); break;
            case Cancel:
                if (packet->payload.empty())
                    m_authenticationController->cancel(packet->attemptId);
                break;
            case State:
            case Prompt:
            case Result: break;
        }
    }

    void CRuntime::onAuthenticationMessage(const char* channel, const uint8_t* message, size_t messageSize, void* userData) {
        (void)channel;
        auto* runtime = static_cast<CRuntime*>(userData);
        if (!runtime)
            return;

        // Authentication responses contain credentials. Parse and transfer
        // them straight into the controller's scrubbed buffer; never copy the
        // packet into a compositor task, container, or log line.
        runtime->handleAuthenticationMessage(message, messageSize);
    }

    void CRuntime::publishAuthenticationEvent(const SAuthenticationEvent& event) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return;

        using namespace AuthenticationProtocol;
        EKind       kind     = EKind::State;
        uint8_t     flags    = stateFlags(event.state);
        uint32_t    argument = event.state.cooldownMs;
        std::string payload  = event.state.statusMessage;

        if (event.kind == SAuthenticationEvent::EKind::Prompt) {
            kind = EKind::Prompt;
            flags |= static_cast<uint8_t>(event.promptStyle) << PROMPT_STYLE_SHIFT;
            argument = event.promptSequence;
            payload  = event.message;
        } else if (event.kind == SAuthenticationEvent::EKind::Result) {
            kind = EKind::Result;
            if (event.success)
                flags |= RESULT_SUCCESS;
            if (event.cancelled)
                flags |= RESULT_CANCELLED;
            payload = event.message;
        }

        auto packet = encode(kind, flags, event.state.attemptId, argument, payload);
        if (packet.empty())
            return;
        denial_engine_host_send_platform_message(m_flutter->host, TO_FLUTTER_CHANNEL, packet.data(), packet.size());
    }

    void CRuntime::applyAuthenticationState(bool locked) {
        if (m_appliedSessionLocked == locked)
            return;
        m_appliedSessionLocked = locked;

        if (g_pInputManager)
            g_pInputManager->onDenialSessionLockChanged(locked);

        if (g_pCompositor && g_pHyprRenderer) {
            for (const auto& monitor : g_pCompositor->m_monitors) {
                if (monitor)
                    g_pHyprRenderer->damageMonitor(monitor);
            }
        }
        requestOutputFrame();
        Log::logger->log(Log::INFO, "Denial native session security state changed locked={}", locked);
    }

    std::string CRuntime::handleAuthenticationCommand(eHyprCtlOutputFormat format, std::string request) {
        if (!m_authenticationController)
            return format == FORMAT_JSON ? R"({"ok":false,"error":"authentication unavailable"})" : "authentication unavailable";

        const auto argument = commandArgument(request);
        if (argument == "lock") {
            m_authenticationController->lock();
            return format == FORMAT_JSON ? R"({"ok":true,"locked":true})" : "ok";
        }

        if (argument.empty() || argument == "status") {
            const auto state = m_authenticationController->snapshot();
            if (format == FORMAT_JSON)
                return std::format(R"({{"ok":true,"locked":{},"available":{},"busy":{},"cooldown_ms":{}}})", state.locked, state.available, state.busy, state.cooldownMs);
            return std::format("locked={} available={} busy={} cooldown_ms={}", state.locked, state.available, state.busy, state.cooldownMs);
        }

        return format == FORMAT_JSON ? R"({"ok":false,"error":"usage: denial-lock [lock|status]"})" : "usage: denial-lock [lock|status]";
    }

} // namespace Denial
