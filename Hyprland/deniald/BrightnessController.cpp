#include "BrightnessController.hpp"

#include "../src/debug/log/Logger.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#if defined(DENIAL_WITH_DDCUTIL)
#include <ddcutil_c_api.h>
#endif

namespace Denial {

    class CBrightnessController::CImpl {
      public:
        explicit CImpl(TStateCallback stateCallback) : m_stateCallback(std::move(stateCallback)), m_worker([this] { run(); }) {}

        ~CImpl() {
            {
                std::lock_guard<std::mutex> lock(m_commandMutex);
                m_stopping = true;
            }
            m_commandCondition.notify_one();
            if (m_worker.joinable())
                m_worker.join();
        }

        void adjustLevel(const std::string& connector, int64_t monitorId, double delta) {
            if (connector.empty() || monitorId < 0 || !std::isfinite(delta) || delta == 0.0)
                return;

            std::optional<double> targetToPublish;
            {
                std::lock_guard<std::mutex> lock(m_commandMutex);
                const auto                  generation = ++m_nextGeneration;
                auto&                       pending    = m_pending[connector];
                pending.monitorId                      = monitorId;
                pending.generation                     = generation;

                if (auto desired = m_desired.find(connector); desired != m_desired.end()) {
                    desired->second.level      = std::clamp(desired->second.level + delta, 0.0, 1.0);
                    desired->second.generation = generation;
                    pending.targetLevel        = desired->second.level;
                    pending.unresolvedDelta    = 0.0;
                    targetToPublish            = desired->second.level;
                } else {
                    pending.targetLevel.reset();
                    pending.unresolvedDelta = std::clamp(pending.unresolvedDelta + delta, -1.0, 1.0);
                }
            }

            // The target is presentation state, not an I2C acknowledgement.
            // Publishing it here keeps the OSD locked to the physical wheel
            // even while a previous monitor transaction is still in flight.
            if (targetToPublish && m_stateCallback)
                m_stateCallback(monitorId, *targetToPublish);
            m_commandCondition.notify_one();
        }

        void setLevel(const std::string& connector, int64_t monitorId, double level) {
            if (connector.empty() || monitorId < 0 || !std::isfinite(level))
                return;

            const auto target = std::clamp(level, 0.0, 1.0);
            {
                std::lock_guard<std::mutex> lock(m_commandMutex);
                const auto                  generation = ++m_nextGeneration;
                auto&                       pending    = m_pending[connector];
                pending.monitorId                      = monitorId;
                pending.targetLevel                    = target;
                pending.unresolvedDelta                = 0.0;
                pending.generation                     = generation;
                m_desired[connector]                   = SDesiredLevel{.level = target, .generation = generation};
            }

            if (m_stateCallback)
                m_stateCallback(monitorId, target);
            m_commandCondition.notify_one();
        }

      private:
        using CClock = std::chrono::steady_clock;

        struct SPendingAdjustment {
            int64_t               monitorId       = -1;
            double                unresolvedDelta = 0.0;
            std::optional<double> targetLevel;
            uint64_t              generation = 0;
        };

        struct SDesiredLevel {
            double   level      = 0.0;
            uint64_t generation = 0;
        };

#if defined(DENIAL_WITH_DDCUTIL)
        struct SDisplayState {
            DDCA_Display_Ref reference = nullptr;
            uint16_t         current   = 0;
            uint16_t         maximum   = 0;
            bool             known     = false;
        };

        struct SVerification {
            CClock::time_point deadline;
            int64_t            monitorId  = -1;
            uint64_t           generation = 0;
        };

        static constexpr DDCA_Vcp_Feature_Code BRIGHTNESS_FEATURE = 0x10;
        static constexpr auto                  COALESCE_WINDOW    = std::chrono::milliseconds(24);
        static constexpr auto                  VERIFY_IDLE_DELAY  = std::chrono::milliseconds(320);

        static std::string                     connectorFromDdcName(std::string_view name) {
            // libddcutil reports e.g. "card2-DP-4" while Hyprland uses
            // "DP-4". Keep connector names containing dashes intact.
            if (name.starts_with("card")) {
                const auto separator = name.find('-');
                if (separator != std::string_view::npos && separator + 1 < name.size())
                    name.remove_prefix(separator + 1);
            }
            return std::string{name};
        }

        static uint16_t combineBytes(uint8_t high, uint8_t low) {
            return static_cast<uint16_t>((static_cast<uint16_t>(high) << 8) | low);
        }

        static const char* statusDescription(DDCA_Status status) {
            const auto* description = ddca_rc_desc(status);
            return description ? description : "unknown libddcutil error";
        }

        static double levelOf(uint16_t current, uint16_t maximum) {
            return maximum == 0 ? 0.0 : std::clamp(static_cast<double>(current) / maximum, 0.0, 1.0);
        }

        bool ensureDdcReady() {
            if (!m_ddcInitialized) {
                const auto status = ddca_init2(nullptr, DDCA_SYSLOG_NEVER, DDCA_INIT_OPTIONS_DISABLE_CONFIG_FILE, nullptr);
                if (status != 0) {
                    Log::logger->log(Log::WARN, "Denial DDC initialization failed: {}", statusDescription(status));
                    return false;
                }
                m_ddcInitialized = true;
                Log::logger->log(Log::INFO, "Denial brightness connected through native libddcutil");
            }

            return !m_displays.empty() || refreshDisplays(false);
        }

        bool refreshDisplays(bool redetect) {
            if (redetect) {
                const auto status = ddca_redetect_displays();
                if (status != 0) {
                    Log::logger->log(Log::WARN, "Denial DDC display redetection failed: {}", statusDescription(status));
                    return false;
                }
            }

            DDCA_Display_Ref* references = nullptr;
            const auto        status     = ddca_get_display_refs(false, &references);
            if (status != 0 || !references) {
                Log::logger->log(Log::WARN, "Denial DDC display enumeration failed: {}", statusDescription(status));
                return false;
            }

            std::unordered_map<std::string, SDisplayState> displays;
            for (size_t index = 0; references[index] != nullptr; ++index) {
                DDCA_Display_Info2* info = nullptr;
                if (ddca_get_display_info2(references[index], &info) != 0 || !info)
                    continue;

                const auto connector = connectorFromDdcName(info->drm_card_connector);
                if (!connector.empty()) {
                    SDisplayState state{.reference = references[index]};
                    if (!redetect) {
                        if (const auto previous = m_displays.find(connector); previous != m_displays.end()) {
                            state.current = previous->second.current;
                            state.maximum = previous->second.maximum;
                            state.known   = previous->second.known;
                        }
                    }
                    displays[connector] = state;
                }
                ddca_free_display_info2(info);
            }

            m_displays = std::move(displays);
            return !m_displays.empty();
        }

        bool readBrightness(DDCA_Display_Handle handle, uint16_t& current, uint16_t& maximum, DDCA_Status& status) const {
            DDCA_Non_Table_Vcp_Value value{};
            status = ddca_get_non_table_vcp_value(handle, BRIGHTNESS_FEATURE, &value);
            if (status != 0)
                return false;

            current = combineBytes(value.sh, value.sl);
            maximum = combineBytes(value.mh, value.ml);
            return maximum > 0;
        }

        bool openDisplay(const std::string& connector, DDCA_Display_Handle& handle, bool allowRedetect, DDCA_Status& status) {
            auto display = m_displays.find(connector);
            if (display == m_displays.end() && allowRedetect && refreshDisplays(true))
                display = m_displays.find(connector);
            if (display == m_displays.end()) {
                status = 0;
                return false;
            }

            status = ddca_open_display2(display->second.reference, false, &handle);
            if ((status != 0 || !handle) && allowRedetect && refreshDisplays(true)) {
                display = m_displays.find(connector);
                if (display != m_displays.end())
                    status = ddca_open_display2(display->second.reference, false, &handle);
            }
            return status == 0 && handle;
        }

        void warmDisplayLevels() {
            std::vector<std::string> connectors;
            connectors.reserve(m_displays.size());
            for (const auto& [connector, _] : m_displays)
                connectors.emplace_back(connector);

            for (const auto& connector : connectors) {
                DDCA_Status         status = 0;
                DDCA_Display_Handle handle = nullptr;
                if (!openDisplay(connector, handle, false, status))
                    continue;

                uint16_t   current = 0;
                uint16_t   maximum = 0;
                const bool read    = readBrightness(handle, current, maximum, status);
                ddca_close_display(handle);
                if (!read)
                    continue;

                auto& display   = m_displays[connector];
                display.current = current;
                display.maximum = maximum;
                display.known   = true;

                std::lock_guard<std::mutex> lock(m_commandMutex);
                if (!m_desired.contains(connector) && !m_pending.contains(connector))
                    m_desired[connector] = SDesiredLevel{.level = levelOf(current, maximum)};
            }
        }

        void absorbUnresolvedInput(const std::string& connector, SPendingAdjustment& adjustment) {
            std::lock_guard<std::mutex> lock(m_commandMutex);
            const auto                  newer = m_pending.find(connector);
            if (newer == m_pending.end() || newer->second.targetLevel)
                return;

            adjustment.monitorId       = newer->second.monitorId;
            adjustment.unresolvedDelta = std::clamp(adjustment.unresolvedDelta + newer->second.unresolvedDelta, -1.0, 1.0);
            adjustment.generation      = newer->second.generation;
            m_pending.erase(newer);
        }

        void applyAdjustment(const std::string& connector, SPendingAdjustment adjustment) {
            if (!ensureDdcReady())
                return;

            DDCA_Status         status = 0;
            DDCA_Display_Handle handle = nullptr;
            if (!openDisplay(connector, handle, true, status)) {
                logFailureOnce(connector, "could not open DDC display", status);
                return;
            }

            auto& display = m_displays[connector];
            if (!display.known && !readBrightness(handle, display.current, display.maximum, status)) {
                ddca_close_display(handle);
                display.known = false;
                logFailureOnce(connector, "could not read VCP 0x10", status);
                return;
            }
            display.known = true;

            if (!adjustment.targetLevel) {
                // This only occurs if input arrived before the asynchronous
                // startup read completed. Fold any newer unresolved detents in
                // before deriving the first absolute target.
                absorbUnresolvedInput(connector, adjustment);
                adjustment.targetLevel = std::clamp(levelOf(display.current, display.maximum) + adjustment.unresolvedDelta, 0.0, 1.0);
                {
                    std::lock_guard<std::mutex> lock(m_commandMutex);
                    m_desired[connector] = SDesiredLevel{.level = *adjustment.targetLevel, .generation = adjustment.generation};
                }
                if (m_stateCallback)
                    m_stateCallback(adjustment.monitorId, *adjustment.targetLevel);
            }

            const auto target = static_cast<uint16_t>(std::lround(std::clamp(*adjustment.targetLevel, 0.0, 1.0) * display.maximum));
            if (target != display.current) {
                status = ddca_set_non_table_vcp_value2(handle, BRIGHTNESS_FEATURE, static_cast<uint8_t>(target >> 8), static_cast<uint8_t>(target & 0xff));
                if (status != 0) {
                    const auto writeStatus   = status;
                    const auto previousLevel = levelOf(display.current, display.maximum);
                    uint16_t   actual        = 0;
                    uint16_t   actualMaximum = 0;
                    if (readBrightness(handle, actual, actualMaximum, status)) {
                        display.current = actual;
                        display.maximum = actualMaximum;
                        display.known   = true;
                    } else
                        display.known = false;
                    ddca_close_display(handle);

                    const auto correction        = display.known ? levelOf(display.current, display.maximum) : previousLevel;
                    bool       publishCorrection = false;
                    {
                        std::lock_guard<std::mutex> lock(m_commandMutex);
                        if (auto desired = m_desired.find(connector); desired != m_desired.end() && desired->second.generation == adjustment.generation) {
                            desired->second.level = correction;
                            publishCorrection     = true;
                        }
                    }
                    if (publishCorrection && m_stateCallback)
                        m_stateCallback(adjustment.monitorId, correction);
                    logFailureOnce(connector, "could not write VCP 0x10", writeStatus);
                    return;
                }
            }
            ddca_close_display(handle);

            display.current            = target;
            display.known              = true;
            m_failureLogged[connector] = false;
            m_verifications[connector] = SVerification{
                .deadline   = CClock::now() + VERIFY_IDLE_DELAY,
                .monitorId  = adjustment.monitorId,
                .generation = adjustment.generation,
            };
        }

        void verifyBrightness(const std::string& connector, const SVerification& verification) {
            DDCA_Status         status = 0;
            DDCA_Display_Handle handle = nullptr;
            if (!openDisplay(connector, handle, true, status)) {
                logFailureOnce(connector, "could not open DDC display for reconciliation", status);
                return;
            }

            uint16_t   current = 0;
            uint16_t   maximum = 0;
            const bool read    = readBrightness(handle, current, maximum, status);
            ddca_close_display(handle);
            if (!read) {
                m_displays[connector].known = false;
                logFailureOnce(connector, "could not reconcile VCP 0x10", status);
                return;
            }

            auto& display              = m_displays[connector];
            display.current            = current;
            display.maximum            = maximum;
            display.known              = true;
            m_failureLogged[connector] = false;

            const auto actual            = levelOf(current, maximum);
            bool       publishCorrection = false;
            {
                std::lock_guard<std::mutex> lock(m_commandMutex);
                const auto                  desired = m_desired.find(connector);
                if (desired != m_desired.end() && desired->second.generation == verification.generation && !m_pending.contains(connector)) {
                    publishCorrection     = std::abs(desired->second.level - actual) >= 0.005;
                    desired->second.level = actual;
                }
            }
            if (publishCorrection && m_stateCallback)
                m_stateCallback(verification.monitorId, actual);
        }

        void logFailureOnce(const std::string& connector, std::string_view operation, DDCA_Status status) {
            if (m_failureLogged[connector])
                return;
            m_failureLogged[connector] = true;
            if (status == 0)
                Log::logger->log(Log::WARN, "Denial brightness {} {}", connector, operation);
            else
                Log::logger->log(Log::WARN, "Denial brightness {} {}: {}", connector, operation, statusDescription(status));
        }
#endif

        void run() {
#if defined(DENIAL_WITH_DDCUTIL)
            // Bus detection and initial VCP reads stay off compositor startup
            // and establish the target cache used by latency-free input.
            if (ensureDdcReady())
                warmDisplayLevels();
#endif

            while (true) {
                std::optional<std::pair<std::string, SPendingAdjustment>> adjustment;
#if defined(DENIAL_WITH_DDCUTIL)
                std::optional<std::pair<std::string, SVerification>> verification;
#endif
                {
                    std::unique_lock<std::mutex> lock(m_commandMutex);
                    while (!m_stopping && m_pending.empty()) {
#if defined(DENIAL_WITH_DDCUTIL)
                        if (!m_verifications.empty()) {
                            const auto next = std::min_element(m_verifications.begin(), m_verifications.end(),
                                                               [](const auto& lhs, const auto& rhs) { return lhs.second.deadline < rhs.second.deadline; });
                            if (!m_commandCondition.wait_until(lock, next->second.deadline, [this] { return m_stopping || !m_pending.empty(); })) {
                                verification = *next;
                                m_verifications.erase(next);
                                break;
                            }
                            continue;
                        }
#endif
                        m_commandCondition.wait(lock, [this] {
#if defined(DENIAL_WITH_DDCUTIL)
                            return m_stopping || !m_pending.empty() || !m_verifications.empty();
#else
                            return m_stopping || !m_pending.empty();
#endif
                        });
                    }
                    if (m_stopping)
                        break;

#if defined(DENIAL_WITH_DDCUTIL)
                    if (!verification && !m_pending.empty()) {
#else
                    if (!m_pending.empty()) {
#endif
                        const auto deadline = CClock::now()
#if defined(DENIAL_WITH_DDCUTIL)
                            + COALESCE_WINDOW;
#else
                            + std::chrono::milliseconds(24);
#endif
                        while (!m_stopping && m_commandCondition.wait_until(lock, deadline) != std::cv_status::timeout) {}
                        if (m_stopping)
                            break;

                        auto pending = m_pending.begin();
                        adjustment   = *pending;
                        m_pending.erase(pending);
                    }
                }

#if defined(DENIAL_WITH_DDCUTIL)
                if (adjustment)
                    applyAdjustment(adjustment->first, adjustment->second);
                else if (verification)
                    verifyBrightness(verification->first, verification->second);
#else
                (void)adjustment;
#endif
            }
        }

        TStateCallback                                      m_stateCallback;
        std::thread                                         m_worker;
        std::mutex                                          m_commandMutex;
        std::condition_variable                             m_commandCondition;
        std::unordered_map<std::string, SPendingAdjustment> m_pending;
        std::unordered_map<std::string, SDesiredLevel>      m_desired;
        uint64_t                                            m_nextGeneration = 0;
        bool                                                m_stopping       = false;
#if defined(DENIAL_WITH_DDCUTIL)
        bool                                           m_ddcInitialized = false;
        std::unordered_map<std::string, SDisplayState> m_displays;
        std::unordered_map<std::string, SVerification> m_verifications;
        std::unordered_map<std::string, bool>          m_failureLogged;
#endif
    };

    CBrightnessController::CBrightnessController(TStateCallback stateCallback) : m_impl(std::make_unique<CImpl>(std::move(stateCallback))) {}

    CBrightnessController::~CBrightnessController() = default;

    void CBrightnessController::adjustLevel(const std::string& connector, int64_t monitorId, double delta) {
        m_impl->adjustLevel(connector, monitorId, delta);
    }

    void CBrightnessController::setLevel(const std::string& connector, int64_t monitorId, double level) {
        m_impl->setLevel(connector, monitorId, level);
    }
}
