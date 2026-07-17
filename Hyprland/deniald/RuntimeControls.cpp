#include "Runtime.hpp"
#include "RuntimeFlutterState.hpp"
#include "RuntimeInternal.hpp"
#include "Wire.hpp"

#include "AudioController.hpp"
#include "BrightnessController.hpp"
#include "NotificationServer.hpp"

#include "../src/Compositor.hpp"
#include "../src/config/supplementary/executor/Executor.hpp"
#include "../src/debug/log/Logger.hpp"
#include "../src/desktop/state/FocusState.hpp"
#include "../src/devices/IKeyboard.hpp"
#include "../src/helpers/Monitor.hpp"
#include "../src/helpers/time/Time.hpp"
#include "../src/managers/SeatManager.hpp"
#include "../src/managers/eventLoop/EventLoopManager.hpp"
#include "../src/managers/input/InputManager.hpp"

#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include <sys/socket.h>
#include <sys/un.h>

namespace Denial {

    using RuntimeInternal::AUDIO_STATE_CHANNEL;
    using RuntimeInternal::AUDIO_STREAMS_STATE_CHANNEL;
    using RuntimeInternal::BRIGHTNESS_STATE_CHANNEL;
    using RuntimeInternal::HAPTICS_MIN_GAP_US;
    using RuntimeInternal::HAPTICS_SOCKET_PATH;
    using RuntimeInternal::SYSTEM_COMMAND_HEADER_SIZE;
    using RuntimeInternal::SYSTEM_COMMAND_MAX_ARGS;
    using RuntimeInternal::SYSTEM_COMMAND_MAX_ARG_SIZE;
    using RuntimeInternal::SYSTEM_COMMAND_MAX_SIZE;
    using RuntimeInternal::readUint32LE;
    using RuntimeInternal::readUint64LE;
    using RuntimeInternal::steadyUs;
    using RuntimeInternal::writeUint32LE;
    using RuntimeInternal::writeUint64LE;

    namespace {
        std::string shellQuote(std::string_view value) {
            std::string quoted;
            quoted.reserve(value.size() + 2);
            quoted.push_back('\'');
            for (const char character : value) {
                if (character == '\'')
                    quoted += "'\"'\"'";
                else
                    quoted.push_back(character);
            }
            quoted.push_back('\'');
            return quoted;
        }

        class CDenialOskKeyboard : public IKeyboard {
          public:
            static SP<CDenialOskKeyboard> create() {
                auto keyboard    = SP<CDenialOskKeyboard>(new CDenialOskKeyboard());
                keyboard->m_self = keyboard;
                return keyboard;
            }

            bool isVirtual() override {
                return true;
            }

            SP<Aquamarine::IKeyboard> aq() override {
                return nullptr;
            }

          private:
            CDenialOskKeyboard() {
                m_deviceName      = "denial-osk";
                m_allowBinds      = false;
                m_shareStates     = false;
                m_shareStatesAuto = false;
                m_repeatRate      = 25;
                m_repeatDelay     = 400;
            }
        };

        struct SOskResolvedKey {
            uint32_t keycode = 0;
            uint32_t mods    = 0;
        };

        uint32_t xkbModMask(xkb_keymap* keymap, const char* name) {
            if (!keymap || !name)
                return 0;

            const auto index = xkb_keymap_mod_get_index(keymap, name);
            if (index == XKB_MOD_INVALID || index >= 32)
                return 0;

            return 1u << index;
        }

        size_t utf8CodepointSize(std::string_view text, size_t offset) {
            if (offset >= text.size())
                return 0;

            const auto byte = sc<unsigned char>(text[offset]);
            if ((byte & 0x80u) == 0)
                return 1;
            if ((byte & 0xE0u) == 0xC0u)
                return std::min<size_t>(2, text.size() - offset);
            if ((byte & 0xF0u) == 0xE0u)
                return std::min<size_t>(3, text.size() - offset);
            if ((byte & 0xF8u) == 0xF0u)
                return std::min<size_t>(4, text.size() - offset);
            return 1;
        }

        std::optional<SOskResolvedKey> resolveTextKey(IKeyboard& keyboard, std::string_view text) {
            if (!keyboard.m_xkbKeymap || text.empty())
                return {};

            const auto                    shiftMask  = xkbModMask(keyboard.m_xkbKeymap, XKB_MOD_NAME_SHIFT);
            const std::array<uint32_t, 2> candidates = {0, shiftMask};
            const auto                    minKeycode = xkb_keymap_min_keycode(keyboard.m_xkbKeymap);
            const auto                    maxKeycode = xkb_keymap_max_keycode(keyboard.m_xkbKeymap);

            for (const auto mods : candidates) {
                xkb_state* state = xkb_state_new(keyboard.m_xkbKeymap);
                if (!state)
                    continue;

                xkb_state_update_mask(state, mods, 0, 0, 0, 0, 0);
                for (xkb_keycode_t keycode = minKeycode; keycode <= maxKeycode; ++keycode) {
                    std::array<char, 16> buffer = {};
                    const auto           length = xkb_state_key_get_utf8(state, keycode, buffer.data(), buffer.size());
                    if (length <= 0 || sc<size_t>(length) != text.size())
                        continue;

                    if (std::string_view{buffer.data(), sc<size_t>(length)} == text) {
                        xkb_state_unref(state);
                        if (keycode < 8)
                            return {};
                        return SOskResolvedKey{.keycode = sc<uint32_t>(keycode - 8), .mods = mods};
                    }
                }

                xkb_state_unref(state);
            }

            return {};
        }

        std::optional<SOskResolvedKey> resolveNamedKey(IKeyboard& keyboard, std::string_view key) {
            if (!keyboard.m_xkbKeymap || key.empty())
                return {};

            const auto keysym = xkb_keysym_from_name(std::string(key).c_str(), XKB_KEYSYM_CASE_INSENSITIVE);
            if (keysym == XKB_KEY_NoSymbol)
                return {};

            const auto minKeycode = xkb_keymap_min_keycode(keyboard.m_xkbKeymap);
            const auto maxKeycode = xkb_keymap_max_keycode(keyboard.m_xkbKeymap);
            for (xkb_keycode_t keycode = minKeycode; keycode <= maxKeycode; ++keycode) {
                const auto found = xkb_state_key_get_one_sym(keyboard.m_xkbState, keycode);
                if (found != keysym)
                    continue;

                if (keycode < 8)
                    return {};
                return SOskResolvedKey{.keycode = sc<uint32_t>(keycode - 8), .mods = 0};
            }

            return {};
        }

    } // namespace

    void CRuntime::publishNotificationEvent(const SNotificationEvent& event) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return;

        const auto                                     imageBytes = event.notification.imageData ? event.notification.imageData->data.size() : 0;
        flatbuffers::FlatBufferBuilder                 builder(1024 + imageBytes);
        flatbuffers::Offset<Wire::DesktopNotification> notificationOffset;

        if (event.kind != ENotificationEventKind::Closed) {
            const auto&                                                       notification = event.notification;
            std::vector<flatbuffers::Offset<Wire::DesktopNotificationAction>> actions;
            actions.reserve(notification.actions.size());
            for (const auto& action : notification.actions) {
                actions.emplace_back(Wire::CreateDesktopNotificationAction(builder, builder.CreateString(action.key), builder.CreateString(action.label)));
            }

            flatbuffers::Offset<Wire::DesktopNotificationImageData> imageOffset;
            if (notification.imageData) {
                const auto& image = *notification.imageData;
                imageOffset = Wire::CreateDesktopNotificationImageData(builder, image.width, image.height, image.rowStride, image.hasAlpha, image.bitsPerSample, image.channels,
                                                                       builder.CreateVector(image.data));
            }

            const auto urgency = notification.urgency == ENotificationUrgency::Low ? Wire::DesktopNotificationUrgency_Low :
                notification.urgency == ENotificationUrgency::Critical             ? Wire::DesktopNotificationUrgency_Critical :
                                                                                     Wire::DesktopNotificationUrgency_Normal;
            notificationOffset = Wire::CreateDesktopNotification(
                builder, notification.id, builder.CreateString(notification.sender), builder.CreateString(notification.appName), builder.CreateString(notification.appIcon),
                builder.CreateString(notification.summary), builder.CreateString(notification.body), builder.CreateVector(actions), urgency,
                builder.CreateString(notification.category), builder.CreateString(notification.desktopEntry), builder.CreateString(notification.imagePath), imageOffset,
                notification.resident, notification.transient, notification.suppressSound, notification.actionIcons, builder.CreateString(notification.soundName),
                builder.CreateString(notification.soundFile), notification.x, notification.y, notification.hasPosition, notification.progress, notification.hasProgress,
                notification.expireTimeoutMs);
        }

        const auto kind      = event.kind == ENotificationEventKind::Replaced ? Wire::DesktopNotificationEventKind_Replaced :
            event.kind == ENotificationEventKind::Closed                      ? Wire::DesktopNotificationEventKind_Closed :
                                                                                Wire::DesktopNotificationEventKind_Added;
        const auto wireEvent = Wire::CreateDesktopNotificationEvent(builder, kind, notificationOffset, event.notificationId, event.closeReason);
        if (!sendWirePayload(builder, Wire::Payload_DesktopNotificationEvent, wireEvent.Union()))
            Log::logger->log(Log::WARN, "Denial failed to publish notification event id={}", event.notificationId);
    }

    bool CRuntime::ensureHapticsSocket() {
        if (m_hapticsSocketFd >= 0)
            return true;

        m_hapticsSocketFd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
        if (m_hapticsSocketFd < 0) {
            if (!m_hapticsSocketWarningLogged) {
                Log::logger->log(Log::WARN, "Denial haptics socket create failed errno={}", errno);
                m_hapticsSocketWarningLogged = true;
            }
            return false;
        }

        m_hapticsSocketWarningLogged = false;
        return true;
    }

    void CRuntime::closeHapticsSocket() {
        if (m_hapticsSocketFd < 0)
            return;

        close(m_hapticsSocketFd);
        m_hapticsSocketFd = -1;
    }

    bool CRuntime::sendHapticTap() {
        const auto nowUs = steadyUs();
        if (m_lastHapticTapUs != 0 && nowUs > m_lastHapticTapUs && nowUs - m_lastHapticTapUs < HAPTICS_MIN_GAP_US)
            return false;

        m_lastHapticTapUs = nowUs;
        if (!ensureHapticsSocket())
            return false;

        sockaddr_un addr = {};
        addr.sun_family  = AF_UNIX;
        std::snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", HAPTICS_SOCKET_PATH);

        constexpr char TAP[] = "tap";
        const auto     sent  = sendto(m_hapticsSocketFd, TAP, sizeof(TAP) - 1, MSG_NOSIGNAL, rc<sockaddr*>(&addr), sizeof(addr));
        if (sent == sc<ssize_t>(sizeof(TAP) - 1)) {
            m_hapticsSocketWarningLogged = false;
            return true;
        }

        if (!m_hapticsSocketWarningLogged) {
            Log::logger->log(Log::WARN, "Denial haptics tap send failed errno={}", errno);
            m_hapticsSocketWarningLogged = true;
        }

        if (errno == EBADF)
            closeHapticsSocket();
        return false;
    }

    void CRuntime::handleHapticsMessage(const uint8_t* message, size_t messageSize) {
        if (message && messageSize > 0 && message[0] == 0) {
            ensureHapticsSocket();
            return;
        }

        sendHapticTap();
    }

    void CRuntime::handleAudioMessage(const uint8_t* message, size_t messageSize) {
        if (!m_audioController || !message || messageSize == 0)
            return;

        if (message[0] == 0) {
            m_audioController->requestState();
            return;
        }

        if (message[0] == 1 && messageSize >= 2) {
            const auto requestSerial = messageSize >= 2 + sizeof(uint32_t) ? readUint32LE(message + 2) : 0;
            m_audioController->setLevel(sc<double>(std::min<uint8_t>(message[1], 100)) / 100.0, requestSerial);
            return;
        }

        if (message[0] == 2) {
            m_audioController->requestStreams();
            return;
        }

        if (message[0] == 3 && messageSize >= 1 + sizeof(uint32_t) + 1) {
            const auto streamId = readUint32LE(message + 1);
            const auto level    = sc<double>(std::min<uint8_t>(message[1 + sizeof(uint32_t)], 100)) / 100.0;
            m_audioController->setStreamLevel(streamId, level);
            return;
        }

        Log::logger->log(Log::WARN, "Denial ignored unknown audio message command={} size={}", message[0], messageSize);
    }

    void CRuntime::handleBrightnessMessage(const uint8_t* message, size_t messageSize) {
        if (!m_brightnessController || !message || messageSize != sizeof(uint64_t))
            return;

        const auto bits  = readUint64LE(message);
        double     level = 0.0;
        std::memcpy(&level, &bits, sizeof(level));
        if (!std::isfinite(level))
            return;

        const auto monitor = g_pCompositor ? g_pCompositor->getMonitorFromCursor() : nullptr;
        if (!monitor)
            return;

        m_brightnessController->setLevel(monitor->m_name, monitor->m_id, level);
    }

    void CRuntime::handleSystemCommandMessage(std::shared_ptr<const std::vector<uint8_t>> message) {
        if (secureSessionLocked() || !message || message->size() < SYSTEM_COMMAND_HEADER_SIZE || message->size() > SYSTEM_COMMAND_MAX_SIZE)
            return;

        const auto* bytes           = message->data();
        const auto  command         = bytes[0];
        const auto  launchRequestId = readUint64LE(bytes + 1);
        const auto  argumentCount   = readUint32LE(bytes + 1 + sizeof(uint64_t));
        if (argumentCount > SYSTEM_COMMAND_MAX_ARGS)
            return;

        std::vector<std::string> arguments;
        arguments.reserve(argumentCount);
        size_t offset = SYSTEM_COMMAND_HEADER_SIZE;
        for (uint32_t index = 0; index < argumentCount; ++index) {
            if (offset + sizeof(uint32_t) > message->size())
                return;
            const auto length = readUint32LE(bytes + offset);
            offset += sizeof(uint32_t);
            if (length == 0 || length > SYSTEM_COMMAND_MAX_ARG_SIZE || offset + length > message->size())
                return;

            std::string argument{rc<const char*>(bytes + offset), length};
            if (argument.find('\0') != std::string::npos)
                return;
            arguments.emplace_back(std::move(argument));
            offset += length;
        }
        if (offset != message->size())
            return;

        std::string commandLine;
        switch (command) {
            case 0: {
                if (arguments.empty())
                    return;
                commandLine = "XDG_CURRENT_DESKTOP=Denial:Hyprland XDG_SESSION_DESKTOP=Denial XDG_SESSION_TYPE=wayland";
                if (launchRequestId != 0)
                    commandLine += " DENIA_LAUNCH_REQUEST_ID=" + std::to_string(launchRequestId);
                commandLine += " exec";
                for (const auto& argument : arguments)
                    commandLine += " " + shellQuote(argument);
                break;
            }
            case 1:
                if (launchRequestId != 0 || !arguments.empty())
                    return;
                commandLine = "/usr/bin/pkill -USR2 -x wvkbd-mobintl || exec /usr/local/sbin/denia-toggle-osk";
                break;
            case 2:
                if (launchRequestId != 0 || !arguments.empty())
                    return;
                commandLine = "DENIA_SCREENSHOT_OUTPUT=\"${DENIA_SCREENSHOT_OUTPUT:-DSI-1}\" exec /usr/local/sbin/denia-screenshot --quiet";
                break;
            case 3:
                if (launchRequestId != 0 || !arguments.empty() || !g_pCompositor || g_pCompositor->m_isShuttingDown)
                    return;
                // Logout is compositor-owned session teardown, not an engine
                // reload and not an external system command. Returning from
                // the Wayland loop reaches deniald's normal runtime shutdown
                // and CCompositor::cleanup sequence.
                g_pCompositor->stopCompositor();
                return;
            default: Log::logger->log(Log::WARN, "Denial ignored unknown system command={} size={}", command, message->size()); return;
        }

        const auto process = Config::Supplementary::executor()->spawnRaw(commandLine);
        if (!process || *process == 0)
            Log::logger->log(Log::WARN, "Denial failed to launch native system command={}", command);
    }

    void CRuntime::publishAudioLevel(double level, uint32_t requestSerial) {
        if (!m_initialized || !m_flutter || !m_flutter->host)
            return;

        std::array<uint8_t, 1 + sizeof(uint32_t)> payload{};
        payload[0] = sc<uint8_t>(std::lround(std::clamp(level, 0.0, 1.0) * 100.0));
        writeUint32LE(payload.data() + 1, requestSerial);
        if (!denial_engine_host_send_platform_message(m_flutter->host, AUDIO_STATE_CHANNEL, payload.data(), payload.size()))
            Log::logger->log(Log::WARN, "Denial failed to publish native audio state");
    }

    void CRuntime::publishAudioStreams(const std::vector<SAudioStream>& streams) {
        if (!m_initialized || !m_flutter || !m_flutter->host)
            return;

        constexpr size_t     MAX_STREAMS    = 1024;
        constexpr size_t     MAX_NAME_BYTES = std::numeric_limits<uint16_t>::max();
        const auto           count          = std::min(streams.size(), MAX_STREAMS);
        std::vector<uint8_t> payload;
        payload.reserve(sizeof(uint32_t) + count * 24);

        const auto appendUint16 = [&payload](uint16_t value) {
            payload.push_back(sc<uint8_t>(value & 0xff));
            payload.push_back(sc<uint8_t>((value >> 8) & 0xff));
        };
        const auto appendUint32 = [&payload](uint32_t value) {
            for (size_t i = 0; i < sizeof(value); ++i)
                payload.push_back(sc<uint8_t>((value >> (i * 8)) & 0xff));
        };

        appendUint32(sc<uint32_t>(count));
        for (size_t i = 0; i < count; ++i) {
            const auto& stream     = streams[i];
            const auto  nameLength = std::min(stream.name.size(), MAX_NAME_BYTES);
            appendUint32(stream.id);
            payload.push_back(sc<uint8_t>(std::lround(std::clamp(stream.level, 0.0, 1.0) * 100.0)));
            payload.push_back(stream.muted ? 1 : 0);
            appendUint16(sc<uint16_t>(nameLength));
            payload.insert(payload.end(), stream.name.begin(), stream.name.begin() + nameLength);
        }

        if (!denial_engine_host_send_platform_message(m_flutter->host, AUDIO_STREAMS_STATE_CHANNEL, payload.data(), payload.size()))
            Log::logger->log(Log::WARN, "Denial failed to publish native audio streams");
    }

    void CRuntime::publishBrightnessLevel(MONITORID monitorId, double level) {
        if (!m_initialized || !m_flutter || !m_flutter->host || monitorId < 0)
            return;

        std::array<uint8_t, sizeof(uint64_t) + 1> payload{};
        writeUint64LE(payload.data(), static_cast<uint64_t>(monitorId));
        payload[sizeof(uint64_t)] = sc<uint8_t>(std::lround(std::clamp(level, 0.0, 1.0) * 100.0));
        if (!denial_engine_host_send_platform_message(m_flutter->host, BRIGHTNESS_STATE_CHANNEL, payload.data(), payload.size()))
            Log::logger->log(Log::WARN, "Denial failed to publish native brightness state");
    }

    bool CRuntime::ensureOskKeyboard() {
        if (!g_pInputManager || !g_pSeatManager)
            return false;

        if (!m_oskKeyboard) {
            auto keyboard = CDenialOskKeyboard::create();
            g_pInputManager->newKeyboard(keyboard);
            g_pInputManager->updateCapabilities();

            IKeyboard::SStringRuleNames rules;
            rules.rules  = "evdev";
            rules.model  = "pc105";
            rules.layout = "us";
            keyboard->setKeymap(rules);

            m_oskKeyboard = keyboard;
            Log::logger->log(Log::INFO, "Denial internal OSK keyboard created");
        }

        if (!m_oskKeyboard || !m_oskKeyboard->m_xkbKeymap || !m_oskKeyboard->m_xkbState) {
            Log::logger->log(Log::WARN, "Denial OSK keyboard unavailable: missing keymap");
            return false;
        }

        return true;
    }

    bool CRuntime::sendOskKeycode(uint32_t keycode, uint32_t mods) {
        if (!ensureOskKeyboard())
            return false;

        auto surface = g_pSeatManager->m_state.keyboardFocus.lock();
        if (!surface)
            surface = Desktop::focusState()->surface();

        if (!surface) {
            Log::logger->log(Log::WARN, "Denial OSK key dropped: no keyboard focus surface");
            return false;
        }

        g_pSeatManager->setKeyboard(m_oskKeyboard);
        g_pSeatManager->setKeyboardFocus(surface);

        const auto timeMs = sc<uint32_t>(Time::millis(Time::steadyNow()));
        if (mods != 0)
            g_pSeatManager->sendKeyboardMods(mods, 0, 0, 0);

        g_pSeatManager->sendKeyboardKey(timeMs, keycode, WL_KEYBOARD_KEY_STATE_PRESSED);
        g_pSeatManager->sendKeyboardKey(timeMs, keycode, WL_KEYBOARD_KEY_STATE_RELEASED);

        if (mods != 0)
            g_pSeatManager->sendKeyboardMods(0, 0, 0, 0);

        return true;
    }

    bool CRuntime::sendOskText(const std::string& text) {
        if (!ensureOskKeyboard() || text.empty())
            return false;

        bool sentAny = false;
        for (size_t offset = 0; offset < text.size();) {
            const auto size = utf8CodepointSize(text, offset);
            if (size == 0)
                break;

            const std::string_view unit{text.data() + offset, size};
            const auto             resolved = resolveTextKey(*m_oskKeyboard, unit);
            if (!resolved) {
                Log::logger->log(Log::WARN, "Denial OSK text unit unresolved size={}", size);
                offset += size;
                continue;
            }

            sentAny = sendOskKeycode(resolved->keycode, resolved->mods) || sentAny;
            offset += size;
        }

        return sentAny;
    }

    bool CRuntime::sendOskNamedKey(const std::string& key, bool ctrl) {
        if (!ensureOskKeyboard() || key.empty())
            return false;

        const auto resolved = resolveNamedKey(*m_oskKeyboard, key);
        if (!resolved) {
            Log::logger->log(Log::WARN, "Denial OSK named key unresolved key={}", key);
            return false;
        }

        auto mods = resolved->mods;
        if (ctrl)
            mods |= xkbModMask(m_oskKeyboard->m_xkbKeymap, XKB_MOD_NAME_CTRL);

        return sendOskKeycode(resolved->keycode, mods);
    }

    void CRuntime::handleKeyboardMessage(const Wire::KeyboardCommand& command) {
        if (command.kind() == Wire::KeyboardCommandKind_Text && command.text()) {
            sendOskText(command.text()->str());
        } else if (command.kind() == Wire::KeyboardCommandKind_Key && command.key()) {
            sendOskNamedKey(command.key()->str(), (command.flags() & BridgeWire::KEYBOARD_CTRL) != 0);
        }
    }

    void CRuntime::handleNotificationCommandMessage(const Wire::DesktopNotificationCommand& command) {
        if (secureSessionLocked() || !m_notificationServer)
            return;

        bool queued = false;
        switch (command.kind()) {
            case Wire::DesktopNotificationCommandKind_Dismiss: queued = m_notificationServer->dismiss(command.notification_id()); break;
            case Wire::DesktopNotificationCommandKind_InvokeDefault: queued = m_notificationServer->invokeAction(command.notification_id(), "default"); break;
            case Wire::DesktopNotificationCommandKind_InvokeAction:
                if (command.action_key())
                    queued = m_notificationServer->invokeAction(command.notification_id(), command.action_key()->str());
                break;
        }
        if (!queued)
            Log::logger->log(Log::WARN, "Denial could not queue notification command id={}", command.notification_id());
    }

    void CRuntime::onHapticsMessage(const char* channel, const uint8_t* message, size_t messageSize, void* userData) {
        (void)channel;
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime)
            return;

        const auto command = message && messageSize > 0 ? message[0] : sc<uint8_t>(1);
        if (!g_pEventLoopManager) {
            runtime->handleHapticsMessage(&command, 1);
            return;
        }

        g_pEventLoopManager->postToLoop([runtime, command]() { runtime->handleHapticsMessage(&command, 1); });
    }

    void CRuntime::onAudioMessage(const char* channel, const uint8_t* message, size_t messageSize, void* userData) {
        (void)channel;
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime || !message || messageSize == 0)
            return;

        std::array<uint8_t, 2 + sizeof(uint32_t)> payload{};
        const size_t                              payloadSize = std::min<size_t>(messageSize, payload.size());
        std::copy_n(message, payloadSize, payload.begin());
        if (!g_pEventLoopManager) {
            runtime->handleAudioMessage(payload.data(), payloadSize);
            return;
        }

        g_pEventLoopManager->postToLoop([runtime, payload, payloadSize]() { runtime->handleAudioMessage(payload.data(), payloadSize); });
    }

    void CRuntime::onBrightnessMessage(const char* channel, const uint8_t* message, size_t messageSize, void* userData) {
        (void)channel;
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime || !message || messageSize != sizeof(uint64_t))
            return;

        std::array<uint8_t, sizeof(uint64_t)> payload{};
        std::copy_n(message, payload.size(), payload.begin());
        if (!g_pEventLoopManager) {
            runtime->handleBrightnessMessage(payload.data(), payload.size());
            return;
        }

        g_pEventLoopManager->postToLoop([runtime, payload]() { runtime->handleBrightnessMessage(payload.data(), payload.size()); });
    }

    void CRuntime::onSystemCommandMessage(const char* channel, const uint8_t* message, size_t messageSize, void* userData) {
        (void)channel;
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime || !message || messageSize < SYSTEM_COMMAND_HEADER_SIZE || messageSize > SYSTEM_COMMAND_MAX_SIZE)
            return;

        auto owned = std::make_shared<const std::vector<uint8_t>>(message, message + messageSize);
        if (!g_pEventLoopManager) {
            runtime->handleSystemCommandMessage(std::move(owned));
            return;
        }

        g_pEventLoopManager->postToLoop([runtime, owned = std::move(owned)]() { runtime->handleSystemCommandMessage(std::move(owned)); });
    }

} // namespace Denial
