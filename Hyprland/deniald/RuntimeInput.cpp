#include "Runtime.hpp"
#include "RuntimeFlutterState.hpp"
#include "RuntimeInternal.hpp"
#include "RuntimeLog.hpp"

#include "../src/desktop/view/Window.hpp"
#include "../src/protocols/core/Compositor.hpp"

#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string_view>
#include <utility>
#include <vector>

namespace Denial {

    using RuntimeInternal::inputLayoutFromBuffer;
    using RuntimeInternal::inputRectFromWire;

    bool CRuntime::hitTest(MONITORID monitorId, const Vector2D& outputLogical, SInputHit& hit) {
        const auto* viewport     = outputViewport(monitorId);
        const auto  sceneLogical = viewport ? viewport->logicalRect.pos() + outputLogical : outputLogical;
        hit                      = {};
        hit.missReason           = EInputHitMissReason::InputLayoutUnavailable;

        // The lock boundary lives outside the Flutter isolate. Even while its
        // input snapshot is absent or being reconstructed, every output is a
        // compositor-owned shell target and can never fall through to a
        // client surface.
        if (secureSessionLocked()) {
            hit.kind  = EInputHitKind::FlutterShell;
            hit.local = sceneLogical;
            return true;
        }

        std::shared_ptr<const std::vector<uint8_t>> layoutBuffer;
        {
            std::lock_guard<std::mutex> lock(m_inputRegionMutex);
            layoutBuffer = m_inputLayoutBuffer;
        }

        const auto* layout = inputLayoutFromBuffer(layoutBuffer);
        if (!layout)
            return false;

        if (const auto* shellRegions = layout->shell_regions()) {
            for (const auto* region : *shellRegions) {
                if (!region || !inputRectFromWire(*region).contains(sceneLogical))
                    continue;

                hit       = {};
                hit.kind  = EInputHitKind::FlutterShell;
                hit.local = sceneLogical;
                return true;
            }
        }

        const auto* windows = layout->windows();
        if (!windows) {
            hit.missReason = EInputHitMissReason::WindowRegionsUnavailable;
            return false;
        }

        hit.missReason = EInputHitMissReason::NoRegionAtPoint;

        for (const auto* window : *windows) {
            if (!window)
                continue;

            const auto rect       = inputRectFromWire(window->rect());
            const auto sourceRect = inputRectFromWire(window->source_rect());
            if (!rect.contains(sceneLogical))
                continue;

            hit            = {};
            hit.objectId   = window->object_id();
            hit.surfaceId  = window->surface_id();
            hit.windowId   = window->window_id();
            hit.inputFlags = window->flags();
            hit.rect       = rect;
            hit.sourceRect = sourceRect;

            if ((window->flags() & BridgeWire::INPUT_WINDOW_VISIBLE) == 0) {
                hit.missReason = EInputHitMissReason::CandidateNotVisible;
                continue;
            }

            if ((window->flags() & BridgeWire::INPUT_WINDOW_HIT_TEST_DISABLED) != 0) {
                hit.missReason = EInputHitMissReason::CandidateHitTestDisabled;
                continue;
            }

            PHLWINDOW              WINDOW;
            SP<CWLSurfaceResource> TARGET_SURFACE;
            ESurfaceLayerRole      surfaceRole        = ESurfaceLayerRole::Root;
            TSurfaceId             popupRootSurfaceId = 0;
            if (!m_surfaceRegistry.resolveSurface(window->surface_id(), WINDOW, TARGET_SURFACE, surfaceRole, popupRootSurfaceId)) {
                hit.missReason = EInputHitMissReason::ExternalTextureUnavailable;
                continue;
            }

            auto inputSurface     = TARGET_SURFACE;
            auto inputTreeRoot    = TARGET_SURFACE;
            auto inputLocal       = rect.mapTo(sourceRect, sceneLogical);
            auto routedSourceRect = sourceRect;

            // An input-layout region identifies the root of a surface tree,
            // not necessarily the leaf that receives pointer focus. Popup
            // regions already name their xdg_popup root. Main-window regions
            // must likewise descend from the xdg_toplevel root so interactive
            // subsurfaces (Chromium's restore-pages bubble, for example) can
            // receive hover and button events instead of falling through to
            // the root page surface.
            if (popupRootSurfaceId == 0 && WINDOW->wlSurface() && WINDOW->wlSurface()->resource())
                inputTreeRoot = WINDOW->wlSurface()->resource();

            if (inputTreeRoot) {
                auto [resolvedSurface, resolvedLocal] = inputTreeRoot->at(inputLocal, true);
                if (resolvedSurface) {
                    routedSourceRect.x += resolvedLocal.x - inputLocal.x;
                    routedSourceRect.y += resolvedLocal.y - inputLocal.y;
                    inputSurface = resolvedSurface;
                    inputLocal   = resolvedLocal;
                } else {
                    // Preserve the existing rectangular-region fallback for
                    // clients that have not committed an input region yet.
                    inputSurface = inputTreeRoot;
                }
            }

            hit            = {};
            hit.kind       = EInputHitKind::ClientWindow;
            hit.objectId   = window->object_id();
            hit.surfaceId  = window->surface_id();
            hit.windowId   = WINDOW->m_stableID;
            hit.inputFlags = window->flags();
            hit.window     = WINDOW;
            hit.surface    = inputSurface;
            hit.rect       = rect;
            if (viewport) {
                hit.rect.x -= viewport->logicalRect.x;
                hit.rect.y -= viewport->logicalRect.y;
            }
            hit.sourceRect = routedSourceRect;
            hit.local      = inputLocal;
            DENIAL_HOT_LOG(Log::INFO,
                           "Denial input hit: window={} object={} target_surface={:x} tree_root={:x} input_surface={:x} target_root={} output={} local={} rect={}x{}+{},{} "
                           "source={}x{}+{},{}",
                           hit.windowId, hit.objectId, rc<uintptr_t>(TARGET_SURFACE.get()), rc<uintptr_t>(inputTreeRoot.get()), rc<uintptr_t>(inputSurface.get()),
                           surfaceRole == ESurfaceLayerRole::Root, sceneLogical, hit.local, hit.rect.w, hit.rect.h, hit.rect.x, hit.rect.y, hit.sourceRect.w, hit.sourceRect.h,
                           hit.sourceRect.x, hit.sourceRect.y);
            return true;
        }

        return false;
    }

    bool CRuntime::sendFlutterTouchDown(uint32_t timeMs, int32_t touchId, MONITORID monitorId, const Vector2D& outputLogical) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return false;

        const auto PIXELS = mapFlutterShellInputToEnginePixels(monitorId, outputLogical);
        const bool SENT   = denial_engine_host_touch_down(m_flutter->host, timeMs, touchId, PIXELS.x, PIXELS.y);
        return SENT;
    }

    bool CRuntime::sendFlutterTouchMotion(uint32_t timeMs, int32_t touchId, MONITORID monitorId, const Vector2D& outputLogical) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return false;

        const auto PIXELS = mapFlutterShellInputToEnginePixels(monitorId, outputLogical);
        const bool SENT   = denial_engine_host_touch_motion(m_flutter->host, timeMs, touchId, PIXELS.x, PIXELS.y);
        return SENT;
    }

    bool CRuntime::sendFlutterTouchUp(uint32_t timeMs, int32_t touchId) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return false;

        const bool SENT = denial_engine_host_touch_up(m_flutter->host, timeMs, touchId);
        return SENT;
    }

    bool CRuntime::sendFlutterTouchCancel() {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return false;

        const bool SENT = denial_engine_host_touch_cancel(m_flutter->host);
        return SENT;
    }

    bool CRuntime::sendFlutterPointerMove(MONITORID monitorId, const Vector2D& outputLogical) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return false;

        const auto PIXELS = mapFlutterShellInputToEnginePixels(monitorId, outputLogical);
        return denial_engine_host_pointer_move(m_flutter->host, PIXELS.x, PIXELS.y);
    }

    bool CRuntime::sendFlutterPointerDown(MONITORID monitorId, const Vector2D& outputLogical, EFlutterPointerButton button) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return false;

        const auto PIXELS = mapFlutterShellInputToEnginePixels(monitorId, outputLogical);
        return denial_engine_host_pointer_down(m_flutter->host, PIXELS.x, PIXELS.y, sc<uint64_t>(button));
    }

    bool CRuntime::sendFlutterPointerUp(MONITORID monitorId, const Vector2D& outputLogical, EFlutterPointerButton button) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return false;

        const auto PIXELS = mapFlutterShellInputToEnginePixels(monitorId, outputLogical);
        return denial_engine_host_pointer_up(m_flutter->host, PIXELS.x, PIXELS.y, sc<uint64_t>(button));
    }

    bool CRuntime::sendFlutterPointerLeave() {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return false;

        return denial_engine_host_pointer_leave(m_flutter->host);
    }

    bool CRuntime::sendFlutterPointerScroll(MONITORID monitorId, const Vector2D& outputLogical, const Vector2D& delta) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return false;

        const auto PIXELS = mapFlutterShellInputToEnginePixels(monitorId, outputLogical);
        return denial_engine_host_pointer_scroll(m_flutter->host, PIXELS.x, PIXELS.y, delta.x, delta.y);
    }

    bool CRuntime::flutterKeyboardCapture() const {
        return secureSessionLocked() || m_flutterKeyboardCapture.load(std::memory_order_acquire);
    }

    bool CRuntime::sendFlutterKeyboardKey(const SFlutterKeyboardEvent& event) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return false;

        return denial_engine_host_key_event(m_flutter->host, event.keycode, event.pressed);
    }

    bool CRuntime::sendFlutterKeyboardModifiers(const SFlutterKeyboardModifiers& modifiers) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return false;

        return denial_engine_host_key_modifiers(m_flutter->host, modifiers.depressed, modifiers.latched, modifiers.locked, modifiers.group);
    }

    bool CRuntime::sendFlutterKeyboardKeymap(std::string_view keymap) {
        if (keymap.empty() || !m_flutter || !denial_engine_host_running(m_flutter->host))
            return false;

        return denial_engine_host_keymap(m_flutter->host, keymap.data(), keymap.size());
    }

    Vector2D CRuntime::mapOutputLogicalToSceneLogical(MONITORID monitorId, const Vector2D& outputLogical) const {
        const auto* viewport = outputViewport(monitorId);
        return viewport ? viewport->logicalRect.pos() + outputLogical : outputLogical;
    }

    Vector2D CRuntime::mapFlutterShellInputToEnginePixels(MONITORID monitorId, const Vector2D& outputLogical) {
        std::optional<SFlutterRenderTarget> target;
        {
            std::lock_guard<std::mutex> lock(m_renderTargetMutex);
            target = currentRenderTargetSnapshotLocked();
        }
        const double   scale   = target ? target->scale : 1.0;
        const Vector2D desired = mapOutputLogicalToSceneLogical(monitorId, outputLogical) * scale;
        const Vector2D bounds  = target ? target->size : Vector2D{};
        if (bounds.x <= 0 || bounds.y <= 0)
            return desired;

        // The Denial Flutter view applies GetPointerRotation() before sending touch
        // events to Flutter. Shell events are already in Hypr/output space, so
        // feed the inverse transform and let the engine land on |desired|.
        switch (m_options.flutterOutputTransform) {
            case 1: // rotate-90
                return {bounds.y - desired.y, desired.x};
            case 2: // rotate-180
                return {bounds.x - desired.x, bounds.y - desired.y};
            case 3: // rotate-270
                return {desired.y, bounds.x - desired.x};
            case 4: // flip-x
                return {bounds.x - desired.x, desired.y};
            case 5: // flip-y
                return {desired.x, bounds.y - desired.y};
            default: return desired;
        }
    }

    bool CRuntime::installInputLayoutSnapshot(std::shared_ptr<const std::vector<uint8_t>> message) {
        const auto* layout = inputLayoutFromBuffer(message);
        if (!layout)
            return false;

        const bool keyboardCapture    = (layout->flags() & BridgeWire::INPUT_LAYOUT_KEYBOARD_CAPTURE) != 0;
        const bool exclusiveShellMode = (layout->flags() & BridgeWire::INPUT_LAYOUT_EXCLUSIVE_SHELL) != 0;

        {
            std::lock_guard<std::mutex> lock(m_inputRegionMutex);
            m_inputLayoutBuffer = std::move(message);
        }

        m_flutterKeyboardCapture.store(keyboardCapture, std::memory_order_release);
        m_flutterShellExclusive.store(exclusiveShellMode, std::memory_order_release);
        return true;
    }

} // namespace Denial
