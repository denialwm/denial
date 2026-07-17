#include "InputManager.hpp"
#include "../SessionLockManager.hpp"
#include "../../protocols/SessionLock.hpp"
#include "../../Compositor.hpp"
#include "../../desktop/view/LayerSurface.hpp"
#include "../../desktop/state/FocusState.hpp"
#include "../../denial/InputRouter.hpp"
#include "../../config/ConfigValue.hpp"
#include "../../helpers/Monitor.hpp"
#include "../../devices/ITouch.hpp"
#include "../../event/EventBus.hpp"
#include "../SeatManager.hpp"
#include "debug/log/Logger.hpp"
#include "UnifiedWorkspaceSwipeGesture.hpp"

static Vector2D mapDenialTouchLocal(const Vector2D& coords, const STouchData& touchData) {
    if (touchData.denialRectSize.x <= 0 || touchData.denialRectSize.y <= 0)
        return coords - touchData.touchSurfaceOrigin;

    return {
        touchData.denialSourcePos.x + ((coords.x - touchData.denialRectPos.x) * touchData.denialSourceSize.x / touchData.denialRectSize.x),
        touchData.denialSourcePos.y + ((coords.y - touchData.denialRectPos.y) * touchData.denialSourceSize.y / touchData.denialRectSize.y),
    };
}

static bool touchMonitorUsable(PHLMONITOR monitor) {
    return monitor && monitor->m_output && monitor->m_enabled;
}

static void resetDenialTouchState(STouchData& touchData) {
    touchData.touchFocusFlutterShell   = false;
    touchData.touchFocusFlutterShellID = -1;
    touchData.touchFocusDenial         = false;
}

void CInputManager::onTouchDown(ITouch::SDownEvent e) {
    m_lastInputTouch = true;

    static auto PSWIPETOUCH  = CConfigValue<Config::INTEGER>("gestures:workspace_swipe_touch");
    static auto PGAPSOUTDATA = CConfigValue<Config::IComplexConfigValue>("general:gaps_out");
    auto* const PGAPSOUT     = sc<Config::CCssGapData*>((PGAPSOUTDATA.ptr()));
    // TODO: WORKSPACERULE.gapsOut.value_or()
    auto        gapsOut     = *PGAPSOUT;
    static auto PBORDERSIZE = CConfigValue<Config::INTEGER>("general:border_size");
    static auto PSWIPEINVR  = CConfigValue<Config::INTEGER>("gestures:workspace_swipe_touch_invert");

    auto        PMONITOR = g_pCompositor->getMonitorFromName(!e.device->m_boundOutput.empty() ? e.device->m_boundOutput : "");

    PMONITOR = PMONITOR ? PMONITOR : Desktop::focusState()->monitor();
    if (!touchMonitorUsable(PMONITOR))
        return;

    const auto TOUCH_COORDS        = PMONITOR->m_position + (e.pos * PMONITOR->m_size);
    const auto TOUCH_OUTPUT_COORDS = TOUCH_COORDS - PMONITOR->m_position;

    if (auto* const router = Denial::inputRouter(); router && router->secureSessionLocked()) {
        if (m_touchData.touchFocusFlutterShell)
            router->sendFlutterTouchCancel();
        else if (m_touchData.touchFocusSurface)
            g_pSeatManager->sendTouchCancel();
        resetDenialTouchState(m_touchData);
        m_touchData.touchFocusLockSurface.reset();
        m_touchData.touchFocusWindow.reset();
        m_touchData.touchFocusLS.reset();
        m_touchData.touchFocusSurface.reset();
        m_touchData.touchFocusMonitor        = PMONITOR;
        m_touchData.touchFocusFlutterShell   = true;
        m_touchData.touchFocusFlutterShellID = e.touchID;
        router->sendFlutterTouchDown(e.timeMs, e.touchID, PMONITOR->m_id, TOUCH_OUTPUT_COORDS);
        return;
    }

    if (PMONITOR != Desktop::focusState()->monitor())
        Desktop::focusState()->rawMonitorFocus(PMONITOR);

    Event::SCallbackInfo info;
    Event::bus()->m_events.input.touch.down.emit(e, info);
    if (info.cancelled)
        return;

    if (m_touchData.touchFocusFlutterShell) {
        if (auto* const ROUTER = Denial::inputRouter())
            ROUTER->sendFlutterTouchCancel();
        resetDenialTouchState(m_touchData);
    }

    if (m_clickBehavior == CLICKMODE_KILL) {
        IPointer::SButtonEvent e;
        e.state = WL_POINTER_BUTTON_STATE_PRESSED;
        g_pInputManager->processMouseDownKill(e);
        return;
    }

    if (!g_pSessionLockManager->isSessionLocked()) {
        Denial::SInputHit hit;
        auto* const       ROUTER = Denial::inputRouter();
        if (ROUTER && ROUTER->hitTest(PMONITOR->m_id, TOUCH_OUTPUT_COORDS, hit)) {
            if (hit.kind == Denial::EInputHitKind::FlutterShell) {
                m_touchData.touchFocusLockSurface.reset();
                m_touchData.touchFocusWindow.reset();
                m_touchData.touchFocusLS.reset();
                m_touchData.touchFocusSurface.reset();
                m_touchData.touchFocusMonitor        = PMONITOR;
                m_touchData.touchFocusFlutterShell   = true;
                m_touchData.touchFocusFlutterShellID = e.touchID;
                m_touchData.touchFocusDenial         = false;
                ROUTER->sendFlutterTouchDown(e.timeMs, e.touchID, PMONITOR->m_id, TOUCH_OUTPUT_COORDS);
                return;
            }

            if (hit.kind == Denial::EInputHitKind::ClientWindow && hit.window && hit.surface) {
                m_touchData.touchFocusLockSurface.reset();
                m_touchData.touchFocusLS.reset();
                m_touchData.touchFocusMonitor        = PMONITOR;
                m_touchData.touchFocusWindow         = hit.window;
                m_touchData.touchFocusSurface        = hit.surface;
                m_touchData.touchSurfaceOrigin       = TOUCH_OUTPUT_COORDS - hit.local;
                m_touchData.touchFocusFlutterShellID = -1;
                m_touchData.touchFocusFlutterShell   = false;
                m_touchData.touchFocusDenial         = true;
                m_touchData.denialRectPos            = {hit.rect.x, hit.rect.y};
                m_touchData.denialRectSize           = {hit.rect.w, hit.rect.h};
                m_touchData.denialSourcePos          = {hit.sourceRect.x, hit.sourceRect.y};
                m_touchData.denialSourceSize         = {hit.sourceRect.w, hit.sourceRect.h};

                Desktop::focusState()->rawWindowFocus(hit.window, Desktop::FOCUS_REASON_CLICK, hit.surface);
                g_pSeatManager->sendTouchDown(hit.surface, e.timeMs, e.touchID, hit.local);
                ROUTER->notifyClientWindowActivated(hit.windowId);
                return;
            }
        }
    }

    refocus(TOUCH_COORDS);
    resetDenialTouchState(m_touchData);

    // Don't propagate new touches when a workspace swipe is in progress.
    if (g_pUnifiedWorkspaceSwipe->isGestureInProgress()) {
        return;
        // TODO: Don't swipe if you touched a floating window.
    } else if (*PSWIPETOUCH && (m_foundLSToFocus.expired() || m_foundLSToFocus->m_layer <= 1) && !g_pSessionLockManager->isSessionLocked()) {
        const auto PWORKSPACE = PMONITOR->m_activeWorkspace;
        if (!PWORKSPACE)
            return;

        const auto   STYLE       = PWORKSPACE->m_renderOffset->getStyle();
        const bool   VERTANIMS   = STYLE == "slidevert" || STYLE.starts_with("slidefadevert");
        const double TARGETLEFT  = ((VERTANIMS ? gapsOut.m_top : gapsOut.m_left) + *PBORDERSIZE) / (VERTANIMS ? PMONITOR->m_size.y : PMONITOR->m_size.x);
        const double TARGETRIGHT = 1 - (((VERTANIMS ? gapsOut.m_bottom : gapsOut.m_right) + *PBORDERSIZE) / (VERTANIMS ? PMONITOR->m_size.y : PMONITOR->m_size.x));
        const double POSITION    = (VERTANIMS ? e.pos.y : e.pos.x);
        if (POSITION < TARGETLEFT || POSITION > TARGETRIGHT) {
            g_pUnifiedWorkspaceSwipe->begin();
            g_pUnifiedWorkspaceSwipe->m_touchID = e.touchID;
            // Set the initial direction based on which edge you started from
            if (POSITION > 0.5)
                g_pUnifiedWorkspaceSwipe->m_initialDirection = *PSWIPEINVR ? -1 : 1;
            else
                g_pUnifiedWorkspaceSwipe->m_initialDirection = *PSWIPEINVR ? 1 : -1;
            return;
        }
    }

    // could have abovelock surface, thus only use lock if no ls found
    if (g_pSessionLockManager->isSessionLocked() && m_foundLSToFocus.expired()) {
        m_touchData.touchFocusLockSurface = g_pSessionLockManager->getSessionLockSurfaceForMonitor(PMONITOR->m_id);
        if (!m_touchData.touchFocusLockSurface)
            Log::logger->log(Log::WARN, "The session is locked but can't find a lock surface");
        else
            m_touchData.touchFocusSurface = m_touchData.touchFocusLockSurface->surface->surface();
    } else {
        m_touchData.touchFocusLockSurface.reset();
        m_touchData.touchFocusWindow  = m_foundWindowToFocus;
        m_touchData.touchFocusSurface = m_foundSurfaceToFocus;
        m_touchData.touchFocusLS      = m_foundLSToFocus;
    }

    Vector2D local;

    if (m_touchData.touchFocusLockSurface) {
        local                          = TOUCH_COORDS - PMONITOR->m_position;
        m_touchData.touchSurfaceOrigin = TOUCH_COORDS - local;
    } else if (!m_touchData.touchFocusWindow.expired()) {
        if (m_touchData.touchFocusWindow->m_isX11) {
            local                          = (TOUCH_COORDS - m_touchData.touchFocusWindow->m_realPosition->goal()) * m_touchData.touchFocusWindow->m_X11SurfaceScaledBy;
            m_touchData.touchSurfaceOrigin = m_touchData.touchFocusWindow->m_realPosition->goal();
        } else {
            g_pCompositor->vectorWindowToSurface(TOUCH_COORDS, m_touchData.touchFocusWindow.lock(), local);
            m_touchData.touchSurfaceOrigin = TOUCH_COORDS - local;
        }
    } else if (!m_touchData.touchFocusLS.expired()) {
        PHLLS    foundSurf;
        Vector2D foundCoords;
        auto     surf = g_pCompositor->vectorToLayerPopupSurface(TOUCH_COORDS, PMONITOR, &foundCoords, &foundSurf);
        if (surf) {
            local                         = foundCoords;
            m_touchData.touchFocusSurface = surf;
        } else
            local = TOUCH_COORDS - m_touchData.touchFocusLS->m_geometry.pos();

        m_touchData.touchSurfaceOrigin = TOUCH_COORDS - local;
    } else
        return; // oops, nothing found.

    g_pSeatManager->sendTouchDown(m_touchData.touchFocusSurface.lock(), e.timeMs, e.touchID, local);
}

void CInputManager::onTouchUp(ITouch::SUpEvent e) {
    m_lastInputTouch = true;

    if (auto* const router = Denial::inputRouter(); router && router->secureSessionLocked()) {
        if (g_pUnifiedWorkspaceSwipe->isGestureInProgress())
            g_pUnifiedWorkspaceSwipe->cancel();
        if (m_touchData.touchFocusFlutterShell && m_touchData.touchFocusFlutterShellID == e.touchID)
            router->sendFlutterTouchUp(e.timeMs, e.touchID);
        else if (m_touchData.touchFocusSurface)
            g_pSeatManager->sendTouchCancel();
        resetDenialTouchState(m_touchData);
        return;
    }

    Event::SCallbackInfo info;
    Event::bus()->m_events.input.touch.up.emit(e, info);
    if (info.cancelled)
        return;

    if (g_pUnifiedWorkspaceSwipe->isGestureInProgress()) {
        // If there was a swipe from this finger, end it.
        if (e.touchID == g_pUnifiedWorkspaceSwipe->m_touchID)
            g_pUnifiedWorkspaceSwipe->end();
        return;
    }

    if (m_touchData.touchFocusFlutterShell) {
        if (m_touchData.touchFocusFlutterShellID != e.touchID)
            return;

        if (auto* router = Denial::inputRouter())
            router->sendFlutterTouchUp(e.timeMs, e.touchID);
        resetDenialTouchState(m_touchData);
        return;
    }

    if (m_touchData.touchFocusSurface)
        g_pSeatManager->sendTouchUp(e.timeMs, e.touchID);
    resetDenialTouchState(m_touchData);
}

void CInputManager::onTouchCancel(ITouch::SCancelEvent e) {
    m_lastInputTouch = true;

    if (auto* const router = Denial::inputRouter(); router && router->secureSessionLocked()) {
        if (g_pUnifiedWorkspaceSwipe->isGestureInProgress() && e.touchID == g_pUnifiedWorkspaceSwipe->m_touchID)
            g_pUnifiedWorkspaceSwipe->cancel();
        if (m_touchData.touchFocusFlutterShell)
            router->sendFlutterTouchCancel();
        else if (m_touchData.touchFocusSurface)
            g_pSeatManager->sendTouchCancel();
        resetDenialTouchState(m_touchData);
        return;
    }

    Event::SCallbackInfo info;
    Event::bus()->m_events.input.touch.cancel.emit(e, info);
    if (info.cancelled)
        return;

    if (g_pUnifiedWorkspaceSwipe->isGestureInProgress()) {
        if (e.touchID == g_pUnifiedWorkspaceSwipe->m_touchID)
            g_pUnifiedWorkspaceSwipe->end();
        return;
    }

    if (m_touchData.touchFocusFlutterShell) {
        if (auto* router = Denial::inputRouter())
            router->sendFlutterTouchCancel();
        resetDenialTouchState(m_touchData);
        return;
    }

    if (m_touchData.touchFocusSurface)
        g_pSeatManager->sendTouchCancel();
    resetDenialTouchState(m_touchData);
}

void CInputManager::onTouchMove(ITouch::SMotionEvent e) {
    m_lastInputTouch = true;

    m_lastCursorMovement.reset();

    if (auto* const router = Denial::inputRouter(); router && router->secureSessionLocked()) {
        if (g_pUnifiedWorkspaceSwipe->isGestureInProgress())
            g_pUnifiedWorkspaceSwipe->cancel();
        if (m_touchData.touchFocusFlutterShell && m_touchData.touchFocusFlutterShellID == e.touchID) {
            const auto monitor = m_touchData.touchFocusMonitor.lock();
            if (touchMonitorUsable(monitor))
                router->sendFlutterTouchMotion(e.timeMs, e.touchID, monitor->m_id, e.pos * monitor->m_size);
        } else {
            if (m_touchData.touchFocusSurface)
                g_pSeatManager->sendTouchCancel();
            resetDenialTouchState(m_touchData);
        }
        return;
    }

    Event::SCallbackInfo info;
    Event::bus()->m_events.input.touch.motion.emit(e, info);
    if (info.cancelled)
        return;

    if (g_pUnifiedWorkspaceSwipe->isGestureInProgress()) {
        // Do nothing if this is using a different finger.
        if (e.touchID != g_pUnifiedWorkspaceSwipe->m_touchID)
            return;

        const auto  ANIMSTYLE     = g_pUnifiedWorkspaceSwipe->m_workspaceBegin->m_renderOffset->getStyle();
        const bool  VERTANIMS     = ANIMSTYLE == "slidevert" || ANIMSTYLE.starts_with("slidefadevert");
        static auto PSWIPEINVR    = CConfigValue<Config::INTEGER>("gestures:workspace_swipe_touch_invert");
        static auto PSWIPEDIST    = CConfigValue<Config::INTEGER>("gestures:workspace_swipe_distance");
        const auto  SWIPEDISTANCE = std::clamp(*PSWIPEDIST, sc<int64_t>(1LL), sc<int64_t>(UINT32_MAX));
        // Handle the workspace swipe if there is one
        if (g_pUnifiedWorkspaceSwipe->m_initialDirection == -1) {
            if (*PSWIPEINVR)
                // go from 0 to -SWIPEDISTANCE
                g_pUnifiedWorkspaceSwipe->update(SWIPEDISTANCE * ((VERTANIMS ? e.pos.y : e.pos.x) - 1));
            else
                // go from 0 to -SWIPEDISTANCE
                g_pUnifiedWorkspaceSwipe->update(SWIPEDISTANCE * (-1 * (VERTANIMS ? e.pos.y : e.pos.x)));
        } else if (*PSWIPEINVR)
            // go from 0 to SWIPEDISTANCE
            g_pUnifiedWorkspaceSwipe->update(SWIPEDISTANCE * (VERTANIMS ? e.pos.y : e.pos.x));
        else
            // go from 0 to SWIPEDISTANCE
            g_pUnifiedWorkspaceSwipe->update(SWIPEDISTANCE * (1 - (VERTANIMS ? e.pos.y : e.pos.x)));
        return;
    }
    if (m_touchData.touchFocusFlutterShell) {
        if (m_touchData.touchFocusFlutterShellID != e.touchID)
            return;

        auto PMONITOR = m_touchData.touchFocusMonitor.lock();
        PMONITOR      = PMONITOR ? PMONITOR : Desktop::focusState()->monitor();
        if (!touchMonitorUsable(PMONITOR))
            return;

        const auto TOUCH_COORDS        = PMONITOR->m_position + (e.pos * PMONITOR->m_size);
        const auto TOUCH_OUTPUT_COORDS = TOUCH_COORDS - PMONITOR->m_position;
        if (auto* router = Denial::inputRouter())
            router->sendFlutterTouchMotion(e.timeMs, e.touchID, PMONITOR->m_id, TOUCH_OUTPUT_COORDS);
        return;
    }
    if (m_touchData.touchFocusLockSurface) {
        const auto PMONITOR = g_pCompositor->getMonitorFromID(m_touchData.touchFocusLockSurface->iMonitorID);
        if (!touchMonitorUsable(PMONITOR))
            return;

        const auto TOUCH_COORDS = PMONITOR->m_position + (e.pos * PMONITOR->m_size);
        const auto LOCAL        = TOUCH_COORDS - PMONITOR->m_position;
        g_pSeatManager->sendTouchMotion(e.timeMs, e.touchID, LOCAL);
    } else if (validMapped(m_touchData.touchFocusWindow)) {
        const auto PMONITOR = m_touchData.touchFocusWindow->m_monitor.lock();
        if (!touchMonitorUsable(PMONITOR))
            return;

        const auto TOUCH_COORDS        = PMONITOR->m_position + (e.pos * PMONITOR->m_size);
        const auto TOUCH_OUTPUT_COORDS = TOUCH_COORDS - PMONITOR->m_position;
        auto       local               = m_touchData.touchFocusDenial ? mapDenialTouchLocal(TOUCH_OUTPUT_COORDS, m_touchData) : TOUCH_COORDS - m_touchData.touchSurfaceOrigin;
        if (m_touchData.touchFocusWindow->m_isX11)
            local = local * m_touchData.touchFocusWindow->m_X11SurfaceScaledBy;

        g_pSeatManager->sendTouchMotion(e.timeMs, e.touchID, local);
    } else if (validMapped(m_touchData.touchFocusLS)) {
        const auto PMONITOR = m_touchData.touchFocusLS->m_monitor.lock();
        if (!touchMonitorUsable(PMONITOR))
            return;

        const auto TOUCH_COORDS = PMONITOR->m_position + (e.pos * PMONITOR->m_size);
        const auto LOCAL        = TOUCH_COORDS - m_touchData.touchSurfaceOrigin;

        g_pSeatManager->sendTouchMotion(e.timeMs, e.touchID, LOCAL);
    }
}
