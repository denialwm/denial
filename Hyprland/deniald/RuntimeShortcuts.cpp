#include "Runtime.hpp"

#include "AudioController.hpp"
#include "AuthenticationController.hpp"
#include "BrightnessController.hpp"

#include "../src/Compositor.hpp"
#include "../src/desktop/state/FocusState.hpp"
#include "../src/desktop/view/Window.hpp"
#include "../src/helpers/Monitor.hpp"
#include "../src/layout/algorithm/Algorithm.hpp"
#include "../src/layout/space/Space.hpp"
#include "../src/layout/target/Target.hpp"
#include "../src/managers/input/InputManager.hpp"

#include <atomic>
#include <optional>
#include <string>
#include <string_view>

namespace Denial {

    bool CRuntime::dispatchShortcutAction(const std::string& action, std::string& error) {
        if (action == "session:lock") {
            if (!m_authenticationController) {
                error = "Native authentication controller is unavailable";
                return false;
            }

            // Lock is an idempotent security action. Avoid disturbing an
            // authentication conversation if another native caller repeats it.
            if (!m_authenticationController->locked())
                m_authenticationController->lock();
            return true;
        }

        if (secureSessionLocked()) {
            error = "Action disabled while the session is locked";
            return false;
        }

        if (action == "brightness:up" || action == "brightness:down") {
            if (!m_brightnessController) {
                error = "Native DDC brightness controller is unavailable";
                return false;
            }

            const auto monitor = g_pCompositor ? g_pCompositor->getMonitorFromCursor() : nullptr;
            if (!monitor) {
                error = "No monitor under the cursor";
                return false;
            }

            m_brightnessController->adjustLevel(monitor->m_name, monitor->m_id, action == "brightness:up" ? 0.05 : -0.05);
            return true;
        }

        if (action == "audio:volume-up" || action == "audio:volume-down" || action == "audio:mute") {
            if (!m_audioController) {
                error = "Native audio controller is unavailable";
                return false;
            }

            if (action == "audio:volume-up")
                m_audioController->adjustLevel(0.05);
            else if (action == "audio:volume-down")
                m_audioController->adjustLevel(-0.05);
            else
                m_audioController->toggleMute();
            return true;
        }

        if (action == "shell:overview") {
            // SUPER+A is both the normal Overview shortcut and the emergency
            // escape from application-owned pointer constraints. Release any
            // active grab first so Overview always receives a usable cursor.
            g_pInputManager->releaseMouseGrab();

            const auto monitor = g_pCompositor ? g_pCompositor->getMonitorFromCursor() : nullptr;
            if (sendShellAction("overview", monitor ? std::optional<MONITORID>{monitor->m_id} : std::nullopt))
                return true;

            error = "Flutter shell did not accept the overview action";
            return false;
        }

        if (action == "shell:window-switch-next") {
            // A constrained application must never be able to trap the user
            // away from the compositor-owned window switcher.
            g_pInputManager->releaseMouseGrab();
            const auto monitor = g_pCompositor ? g_pCompositor->getMonitorFromCursor() : nullptr;
            if (sendShellAction("window_switcher_next", monitor ? std::optional<MONITORID>{monitor->m_id} : std::nullopt))
                return true;

            error = "Flutter shell did not accept the window switch action";
            return false;
        }

        if (action == "shell:window-switch-end") {
            if (sendShellAction("window_switcher_end"))
                return true;

            error = "Flutter shell did not accept the window switch end action";
            return false;
        }

        if (shellExclusiveMode()) {
            error = "Action disabled while the Flutter overview is active";
            return false;
        }

        if (action == "shell:applications") {
            m_flutterKeyboardCapture.store(true, std::memory_order_release);
            if (sendShellAction("applications"))
                return true;

            m_flutterKeyboardCapture.store(false, std::memory_order_release);
            error = "Flutter shell did not accept the applications action";
            return false;
        }

        const auto window = Desktop::focusState() ? Desktop::focusState()->window() : nullptr;
        if (!window || !window->m_isMapped) {
            error = "No focused window";
            return false;
        }

        if (action == "window:close") {
            window->sendClose();
            return true;
        }

        if (action == "window:minimize") {
            if (!sendWindowAction(window->m_stableID, "minimize")) {
                error = "Flutter shell did not accept the window action";
                return false;
            }

            window->setMinimized(true);
            return true;
        }

        std::optional<Math::eDirection> monitorDirection;
        if (action == "window:move-monitor-left")
            monitorDirection = Math::DIRECTION_LEFT;
        else if (action == "window:move-monitor-right")
            monitorDirection = Math::DIRECTION_RIGHT;

        if (monitorDirection) {
            const auto sourceMonitor = window->m_monitor.lock();
            if (!sourceMonitor) {
                error = "Focused window has no monitor";
                return false;
            }

            const auto targetMonitor = g_pCompositor->getMonitorInDirection(sourceMonitor, *monitorDirection);
            if (!targetMonitor)
                return true;

            const auto targetWorkspace = targetMonitor->m_activeSpecialWorkspace ? targetMonitor->m_activeSpecialWorkspace : targetMonitor->m_activeWorkspace;
            if (!targetWorkspace) {
                error = "Target monitor has no active workspace";
                return false;
            }

            const auto target = window->layoutTarget();
            if (!target) {
                error = "Focused window has no layout target";
                return false;
            }

            const bool shellFullscreen = windowGeometryLocked(window->m_stableID);
            g_pCompositor->moveWindowToWorkspaceSafe(window, targetWorkspace);
            if (window->m_monitor.lock() != targetMonitor)
                return true;

            if (shellFullscreen)
                target->setPositionGlobal(targetMonitor->logicalBox());

            target->warpPositionSize();
            Desktop::focusState()->rawMonitorFocus(targetMonitor);
            notifyClientWindowPlacement(window, EClientWindowPlacementPhase::End, EClientWindowPlacementChange::Move);
            return true;
        }

        std::string_view semanticAction;
        if (action == "window:toggle-maximize")
            semanticAction = "toggle_maximize";
        else if (action == "window:toggle-fullscreen")
            semanticAction = "toggle_fullscreen";
        else if (action == "window:maximize")
            semanticAction = "maximize";
        else if (action == "window:restore")
            semanticAction = "restore";
        else {
            error = "Unknown Denial action: " + action;
            return false;
        }

        if (!sendWindowAction(window->m_stableID, semanticAction)) {
            error = "Flutter shell did not accept the window action";
            return false;
        }

        if (action == "window:restore")
            window->setMinimized(false);
        return true;
    }

} // namespace Denial
