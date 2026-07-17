#include "Runtime.hpp"
#include "RuntimeFlutterState.hpp"
#include "RuntimeInternal.hpp"
#include "RuntimeLog.hpp"
#include "Wire.hpp"

#include "../src/Compositor.hpp"
#include "../src/debug/log/Logger.hpp"
#include "../src/desktop/state/FocusState.hpp"
#include "../src/desktop/view/Window.hpp"
#include "../src/helpers/Monitor.hpp"
#include "../src/layout/algorithm/Algorithm.hpp"
#include "../src/layout/space/Space.hpp"
#include "../src/layout/target/Target.hpp"
#include "../src/managers/input/InputManager.hpp"

#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>
#include <optional>
#include <ranges>
#include <string>
#include <string_view>

namespace Denial {

    using RuntimeInternal::inputLayoutFromBuffer;

    void CRuntime::notifyClientWindowActivated(TWindowId windowId) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host) || windowId == 0)
            return;

        flatbuffers::FlatBufferBuilder builder(128);
        const auto                     event = Wire::CreateWindowEvent(builder, Wire::WindowEventKind_Activated, windowId);
        if (!sendWirePayload(builder, Wire::Payload_WindowEvent, event.Union()))
            Log::logger->log(Log::WARN, "Denial failed to notify Dart activated window_id={}", windowId);
    }

    void CRuntime::onWindowMapped(TWindowId windowId) {
        (void)windowId;
        notifyWindowObjectsChanged();
    }

    void CRuntime::onSurfaceTreeChanged(TWindowId windowId) {
        (void)windowId;
        notifyWindowObjectsChanged();
    }

    void CRuntime::onWindowStateChanged(TWindowId windowId) {
        (void)windowId;
        notifyWindowObjectsChanged();
    }

    void CRuntime::onWindowGeometryChanged(TWindowId windowId, const Vector2D& position, const Vector2D& size) {
        // This path mirrors compositor-owned X11 popup motion into the Flutter
        // scene. It is an observation, not a configure request, and therefore
        // must not begin a shell drag or request keyboard focus.
        if (!g_pCompositor)
            return;

        for (const auto& window : g_pCompositor->m_windows) {
            if (!window || window->m_stableID != windowId)
                continue;
            sendClientWindowPlacement(window, CBox{position, size}, EClientWindowPlacementPhase::End, EClientWindowPlacementChange::Move);
            return;
        }
    }

    void CRuntime::notifyClientWindowPlacement(PHLWINDOW window, EClientWindowPlacementPhase phase, EClientWindowPlacementChange change) {
        if (!window)
            return;
        const auto target = window->layoutTarget();
        if (!target)
            return;
        sendClientWindowPlacement(window, target->position(), phase, change);
    }

    void CRuntime::sendClientWindowPlacement(PHLWINDOW window, const CBox& geometry, EClientWindowPlacementPhase phase, EClientWindowPlacementChange change) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host) || !window || window->m_stableID == 0 || geometry.w < 1.0 || geometry.h < 1.0)
            return;

        const auto monitor   = window->m_monitor.lock();
        const auto workspace = window->m_workspace;
        if (!monitor || !workspace)
            return;

        Vector2D sceneOrigin;
        {
            std::lock_guard<std::mutex> lock(m_renderTargetMutex);
            sceneOrigin = m_displayLayout.globalOrigin;
        }
        const auto local      = geometry.pos() - sceneOrigin;
        const auto wireChange = change == EClientWindowPlacementChange::Move ? BridgeWire::EPlacementChange::Move : BridgeWire::EPlacementChange::Resize;
        const auto packet     = BridgeWire::encodePlacement(BridgeWire::SPlacementPacket{
            .sequence    = nextWireSequence(),
            .windowId    = window->m_stableID,
            .monitorId   = monitor->m_id,
            .workspaceId = workspace->m_id,
            .phase       = phase == EClientWindowPlacementPhase::Begin ? BridgeWire::EPlacementPhase::Begin :
                phase == EClientWindowPlacementPhase::End              ? BridgeWire::EPlacementPhase::End :
                                                                         BridgeWire::EPlacementPhase::Update,
            .change      = wireChange,
            .x           = local.x,
            .y           = local.y,
            .width       = geometry.w,
            .height      = geometry.h,
        });
        // Placement, activation, snapshots, actions, and cursor state were one
        // ordered stream before the binary migration. Keep the compact packet,
        // but send it on that same stream: Flutter only guarantees FIFO within
        // a channel, and the global wire sequence is otherwise not mergeable.
        if (!packet || !denial_engine_host_send_platform_message(m_flutter->host, BridgeWire::TO_FLUTTER_CHANNEL, packet->data(), packet->size()))
            Log::logger->log(Log::WARN, "Denial failed to notify Dart placement window_id={} phase={}", window->m_stableID, sc<uint8_t>(phase));
    }

    void CRuntime::notifyCursorShape(const std::string& shape) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host) || shape == m_lastCursorShape)
            return;

        if (shape.empty() || shape.size() > BridgeWire::MAX_STRING_BYTES)
            return;

        flatbuffers::FlatBufferBuilder builder(128);
        const auto                     shapeValue = builder.CreateString(shape);
        const auto                     cursor     = Wire::CreateCursorShape(builder, shapeValue);
        if (!sendWirePayload(builder, Wire::Payload_CursorShape, cursor.Union())) {
            Log::logger->log(Log::WARN, "Denial failed to notify Dart cursor shape={}", shape);
            return;
        }
        m_lastCursorShape = shape;
        DENIAL_HOT_LOG(Log::INFO, "Denial CURSOR_TRACE platform_cursor_shape shape={} software_cursor={} sent=true", shape,
                       shape == "none" || shape == "hidden" ? "hidden" : "visible");
    }

    void CRuntime::notifyCursorPosition(MONITORID monitorId, const Vector2D& outputLogical) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return;

        const auto SCENE = mapOutputLogicalToSceneLogical(monitorId, outputLogical);
        if (!std::isfinite(SCENE.x) || !std::isfinite(SCENE.y))
            return;

        flatbuffers::FlatBufferBuilder builder(96);
        const auto                     cursor = Wire::CreateCursorPosition(builder, SCENE.x, SCENE.y);
        if (!sendWirePayload(builder, Wire::Payload_CursorPosition, cursor.Union()))
            DENIAL_HOT_LOG(Log::WARN, "Denial failed to notify Dart cursor position monitor={} scene={}", monitorId, SCENE);
    }

    void CRuntime::notifyDragIconSurface(SP<CWLSurfaceResource> surface) {
        const auto SURFACE_ID = surface ? sc<TSurfaceId>(rc<uintptr_t>(surface.get())) : 0;
        if (SURFACE_ID == m_dragIconSurfaceId)
            return;

        m_dragIconSurfaceId = SURFACE_ID;
        if (surface)
            m_surfaceRegistry.trackDragIcon(surface);
        else
            m_surfaceRegistry.clearDragIcon();
        publishDragIconState();
    }

    bool CRuntime::publishDragIconState() {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return false;

        BridgeWire::SDragIconPacket state{
            .sequence = nextWireSequence(),
        };
        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            const auto                  record = m_externalTextures.find(m_dragIconSurfaceId);
            if (m_dragIconSurfaceId != 0 && record != m_externalTextures.end() && record->second && record->second->dragIcon && !record->second->closing &&
                record->second->textureId > 0) {
                const auto& icon          = *record->second;
                state.active              = true;
                state.surfaceId           = icon.surfaceId;
                state.textureId           = sc<uint64_t>(icon.textureId);
                state.width               = icon.width;
                state.height              = icon.height;
                state.transform           = icon.transform;
                state.scale120            = icon.scale120;
                state.offsetX             = icon.surfaceX;
                state.offsetY             = icon.surfaceY;
                state.surfaceWidth        = icon.surfaceWidth;
                state.surfaceHeight       = icon.surfaceHeight;
                state.textureSourceX      = icon.textureSourceX;
                state.textureSourceY      = icon.textureSourceY;
                state.textureSourceWidth  = icon.textureSourceWidth;
                state.textureSourceHeight = icon.textureSourceHeight;
            }
        }

        const auto packet = BridgeWire::encodeDragIcon(state);
        if (!packet) {
            Log::logger->log(Log::WARN, "Denial rejected its drag-icon state surface={} active={}", state.surfaceId, state.active);
            return false;
        }
        if (!denial_engine_host_send_platform_message(m_flutter->host, BridgeWire::TO_FLUTTER_CHANNEL, packet->data(), packet->size())) {
            Log::logger->log(Log::WARN, "Denial failed to notify Dart drag-icon state surface={} active={}", state.surfaceId, state.active);
            return false;
        }
        return true;
    }

    bool CRuntime::sendWindowAction(TWindowId windowId, std::string_view action) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host) || windowId == 0)
            return false;

        Wire::WindowActionKind kind;
        if (action == "minimize")
            kind = Wire::WindowActionKind_Minimize;
        else if (action == "maximize")
            kind = Wire::WindowActionKind_Maximize;
        else if (action == "restore")
            kind = Wire::WindowActionKind_Restore;
        else if (action == "toggle_maximize")
            kind = Wire::WindowActionKind_ToggleMaximize;
        else if (action == "toggle_fullscreen")
            kind = Wire::WindowActionKind_ToggleFullscreen;
        else
            return false;

        flatbuffers::FlatBufferBuilder builder(128);
        const auto                     event = Wire::CreateWindowEvent(builder, Wire::WindowEventKind_Action, windowId, kind);
        return sendWirePayload(builder, Wire::Payload_WindowEvent, event.Union());
    }

    bool CRuntime::sendShellAction(std::string_view action, std::optional<MONITORID> monitorId) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return false;

        Wire::ShellActionKind kind;
        if (action == "applications")
            kind = Wire::ShellActionKind_Applications;
        else if (action == "overview")
            kind = Wire::ShellActionKind_Overview;
        else if (action == "window_switcher_next")
            kind = Wire::ShellActionKind_WindowSwitcherNext;
        else if (action == "window_switcher_end")
            kind = Wire::ShellActionKind_WindowSwitcherEnd;
        else
            return false;

        flatbuffers::FlatBufferBuilder builder(128);
        const auto                     event = Wire::CreateShellAction(builder, kind, monitorId.value_or(-1), monitorId.has_value());
        return sendWirePayload(builder, Wire::Payload_ShellAction, event.Union());
    }

    bool CRuntime::shellExclusiveMode() const {
        return secureSessionLocked() || m_flutterShellExclusive.load(std::memory_order_acquire);
    }

    bool CRuntime::windowGeometryLocked(TWindowId windowId) {
        if (windowId == 0)
            return false;

        std::shared_ptr<const std::vector<uint8_t>> layoutBuffer;
        {
            std::lock_guard<std::mutex> lock(m_inputRegionMutex);
            layoutBuffer = m_inputLayoutBuffer;
        }
        const auto* layout = inputLayoutFromBuffer(layoutBuffer);
        if (!layout || !layout->windows())
            return false;

        return std::ranges::any_of(*layout->windows(), [windowId](const auto* window) {
            return window && window->window_id() == windowId && (window->flags() & BridgeWire::INPUT_WINDOW_GEOMETRY_LOCKED) != 0;
        });
    }

    PHLWINDOW CRuntime::windowById(TWindowId windowId) const {
        if (!g_pCompositor || windowId == 0)
            return nullptr;

        for (const auto& window : g_pCompositor->m_windows) {
            if (!window || window->m_stableID != windowId || !window->m_isMapped)
                continue;

            return window;
        }

        return nullptr;
    }

    bool CRuntime::closeWindowById(TWindowId windowId) {
        const auto window = windowById(windowId);
        if (!window) {
            Log::logger->log(Log::WARN, "Denial close_window missing window_id={}", windowId);
            return false;
        }

        Log::logger->log(Log::INFO, "Denial close_window window_id={} title={} app_id={}", windowId, window->m_title, window->m_class);
        window->sendClose();
        return true;
    }

    bool CRuntime::focusWindowById(TWindowId windowId) {
        const auto window = windowById(windowId);
        if (!window || !Desktop::focusState())
            return false;

        const bool alreadyFocused = Desktop::focusState()->window() == window;
        Desktop::focusState()->fullWindowFocus(window, Desktop::FOCUS_REASON_DESKTOP_STATE_CHANGE);
        if (Desktop::focusState()->window() != window) {
            Log::logger->log(Log::INFO, "Denial focus_window refused by compositor window_id={} title={} app_id={}", windowId, window->m_title, window->m_class);
            return false;
        }

        // Selecting the window that was focused before Overview does not
        // produce a normal focus transition. Treat this explicit selection as
        // that transition so a grab released by SUPER+A can be acquired again.
        if (alreadyFocused)
            g_pInputManager->reactivateFocusedMouseGrab();

        g_pCompositor->changeWindowZOrder(window, true);
        notifyClientWindowActivated(windowId);
        Log::logger->log(Log::INFO, "Denial focus_window raised window_id={} title={} app_id={}", windowId, window->m_title, window->m_class);
        return true;
    }

    bool CRuntime::configureWindowById(TWindowId windowId, const CBox& geometry) {
        auto window = windowById(windowId);
        if (!window || geometry.w < 64.0 || geometry.h < 64.0)
            return false;

        const CBox globalGeometry{
            m_displayLayout.globalOrigin + geometry.pos(),
            geometry.size(),
        };
        auto monitor = g_pCompositor ? g_pCompositor->getMonitorFromVector(globalGeometry.middle()) : nullptr;
        if (!monitor && g_pCompositor)
            monitor = g_pCompositor->getMonitorFromID(m_displayLayout.tickerMonitorId);
        if (!monitor)
            return false;

        if (monitor->m_activeWorkspace && window->m_workspace != monitor->m_activeWorkspace)
            g_pCompositor->moveWindowToWorkspaceSafe(window, monitor->m_activeWorkspace);

        const auto target = window->layoutTarget();
        if (!target)
            return false;

        if (window->isFullscreen())
            g_pCompositor->setWindowFullscreenInternal(window, FSMODE_NONE);

        if (!target->floating()) {
            const auto space = target->space();
            if (!space || !space->algorithm())
                return false;
            space->algorithm()->setFloating(target, true);
        }

        target->rememberFloatingSize(globalGeometry.size());
        target->setPositionGlobal(globalGeometry);
        Log::logger->log(Log::INFO, "Denial configure_window window_id={} geometry={}x{}+{},{}", windowId, globalGeometry.w, globalGeometry.h, globalGeometry.x, globalGeometry.y);
        return true;
    }

} // namespace Denial
