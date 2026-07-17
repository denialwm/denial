#include "AudioController.hpp"

#include "../src/debug/log/Logger.hpp"

#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>

#if defined(DENIAL_WITH_PULSE)
#include <pulse/pulseaudio.h>
#include <pulse/thread-mainloop.h>
#endif

namespace Denial {

    class CAudioController::CImpl {
      public:
        explicit CImpl(TStateCallback stateCallback, TStreamsCallback streamsCallback) :
            m_stateCallback(std::move(stateCallback)), m_streamsCallback(std::move(streamsCallback)), m_worker([this] { run(); }) {}

        ~CImpl() {
            {
                std::lock_guard<std::mutex> lock(m_commandMutex);
                m_stopping = true;
            }
            m_commandCondition.notify_one();
            if (m_worker.joinable())
                m_worker.join();
        }

        void requestState() {
            {
                std::lock_guard<std::mutex> lock(m_commandMutex);
                m_stateRequested = true;
            }
            m_commandCondition.notify_one();
        }

        void setLevel(double level, uint32_t requestSerial) {
            {
                std::lock_guard<std::mutex> lock(m_commandMutex);
                m_pendingLevel         = std::clamp(level, 0.0, 1.0);
                m_pendingAdjustment    = 0.0;
                m_pendingRequestSerial = requestSerial;
                m_stateRequested       = true;
            }
            m_commandCondition.notify_one();
        }

        void adjustLevel(double delta) {
            {
                std::lock_guard<std::mutex> lock(m_commandMutex);
                if (m_pendingLevel)
                    m_pendingLevel = std::clamp(*m_pendingLevel + delta, 0.0, MAX_AMPLIFIED_LEVEL);
                else
                    m_pendingAdjustment = std::clamp(m_pendingAdjustment + delta, -MAX_AMPLIFIED_LEVEL, MAX_AMPLIFIED_LEVEL);
                m_pendingRequestSerial = 0;
                m_stateRequested       = true;
            }
            m_commandCondition.notify_one();
        }

        void toggleMute() {
            {
                std::lock_guard<std::mutex> lock(m_commandMutex);
                m_pendingMuteToggle = !m_pendingMuteToggle;
                m_stateRequested    = true;
            }
            m_commandCondition.notify_one();
        }

        void requestStreams() {
            {
                std::lock_guard<std::mutex> lock(m_commandMutex);
                m_streamsRequested = true;
            }
            m_commandCondition.notify_one();
        }

        void setStreamLevel(uint32_t streamId, double level) {
            {
                std::lock_guard<std::mutex> lock(m_commandMutex);
                m_pendingStreamLevels[streamId] = std::clamp(level, 0.0, 1.0);
                m_streamsRequested              = true;
            }
            m_commandCondition.notify_one();
        }

      private:
        static constexpr double MAX_AMPLIFIED_LEVEL = 1.4;

#if defined(DENIAL_WITH_PULSE)
        struct SServerQuery {
            CImpl*      owner   = nullptr;
            bool        done    = false;
            bool        success = false;
            std::string defaultSink;
        };

        struct SSinkQuery {
            CImpl*     owner    = nullptr;
            bool       done     = false;
            bool       success  = false;
            pa_cvolume volume   = {};
            uint8_t    channels = 0;
            bool       muted    = false;
        };

        struct SSuccessQuery {
            CImpl* owner   = nullptr;
            bool   done    = false;
            bool   success = false;
        };

        struct SSinkState {
            std::string name;
            pa_cvolume  volume   = {};
            uint8_t     channels = 0;
            bool        muted    = false;
        };

        struct SSinkInputQuery {
            CImpl*     owner    = nullptr;
            bool       done     = false;
            bool       success  = false;
            pa_cvolume volume   = {};
            uint8_t    channels = 0;
            bool       muted    = false;
        };

        struct SSinkInputListQuery {
            CImpl*                    owner   = nullptr;
            bool                      done    = false;
            bool                      success = false;
            std::vector<SAudioStream> streams;
        };

        static void onContextState(pa_context*, void* userData) {
            auto* self = static_cast<CImpl*>(userData);
            if (self && self->m_mainloop)
                pa_threaded_mainloop_signal(self->m_mainloop, 0);
        }

        static void onSubscriptionEvent(pa_context*, pa_subscription_event_type_t eventType, uint32_t, void* userData) {
            auto* self = static_cast<CImpl*>(userData);
            if (!self)
                return;

            const auto facility = eventType & PA_SUBSCRIPTION_EVENT_FACILITY_MASK;
            if (facility == PA_SUBSCRIPTION_EVENT_SINK || facility == PA_SUBSCRIPTION_EVENT_SERVER)
                self->requestState();
            if (facility == PA_SUBSCRIPTION_EVENT_SINK_INPUT)
                self->requestStreams();
        }

        static void onServerInfo(pa_context*, const pa_server_info* info, void* userData) {
            auto* query = static_cast<SServerQuery*>(userData);
            if (!query || !query->owner)
                return;

            if (info && info->default_sink_name && *info->default_sink_name) {
                query->defaultSink = info->default_sink_name;
                query->success     = true;
            }
            query->done = true;
            pa_threaded_mainloop_signal(query->owner->m_mainloop, 0);
        }

        static void onSinkInfo(pa_context*, const pa_sink_info* info, int endOfList, void* userData) {
            auto* query = static_cast<SSinkQuery*>(userData);
            if (!query || !query->owner)
                return;

            if (endOfList < 0) {
                query->done = true;
            } else if (endOfList > 0) {
                query->done = true;
            } else if (info) {
                query->volume   = info->volume;
                query->channels = info->channel_map.channels > 0 ? info->channel_map.channels : info->volume.channels;
                query->muted    = info->mute != 0;
                query->success  = query->channels > 0;
            }

            if (query->done)
                pa_threaded_mainloop_signal(query->owner->m_mainloop, 0);
        }

        static std::string streamName(const pa_sink_input_info* info) {
            if (!info)
                return "Unknown application";

            constexpr std::array<const char*, 3> PROPERTIES = {
                "application.name",
                "media.name",
                "application.id",
            };
            if (info->proplist) {
                for (const auto* property : PROPERTIES) {
                    const auto* value = pa_proplist_gets(info->proplist, property);
                    if (value && *value)
                        return value;
                }
            }
            if (info->name && *info->name)
                return info->name;
            return "Unknown application";
        }

        static void onSinkInputInfo(pa_context*, const pa_sink_input_info* info, int endOfList, void* userData) {
            auto* query = static_cast<SSinkInputQuery*>(userData);
            if (!query || !query->owner)
                return;

            if (endOfList != 0) {
                query->done = true;
            } else if (info) {
                query->volume   = info->volume;
                query->channels = info->channel_map.channels > 0 ? info->channel_map.channels : info->volume.channels;
                query->muted    = info->mute != 0;
                query->success  = query->channels > 0;
            }

            if (query->done)
                pa_threaded_mainloop_signal(query->owner->m_mainloop, 0);
        }

        static void onSinkInputList(pa_context*, const pa_sink_input_info* info, int endOfList, void* userData) {
            auto* query = static_cast<SSinkInputListQuery*>(userData);
            if (!query || !query->owner)
                return;

            if (endOfList < 0) {
                query->done = true;
            } else if (endOfList > 0) {
                query->done    = true;
                query->success = true;
            } else if (info) {
                const auto average = pa_cvolume_avg(&info->volume);
                query->streams.push_back(SAudioStream{
                    .id    = info->index,
                    .name  = streamName(info),
                    .level = std::clamp(static_cast<double>(average) / PA_VOLUME_NORM, 0.0, 1.0),
                    .muted = info->mute != 0,
                });
            }

            if (query->done)
                pa_threaded_mainloop_signal(query->owner->m_mainloop, 0);
        }

        static void onSuccess(pa_context*, int success, void* userData) {
            auto* query = static_cast<SSuccessQuery*>(userData);
            if (!query || !query->owner)
                return;

            query->success = success != 0;
            query->done    = true;
            pa_threaded_mainloop_signal(query->owner->m_mainloop, 0);
        }

        bool contextReadyLocked() const {
            return m_context && pa_context_get_state(m_context) == PA_CONTEXT_READY;
        }

        std::string pulseError() const {
            return m_context ? pa_strerror(pa_context_errno(m_context)) : "context unavailable";
        }

        bool connectPulse() {
            if (m_context && pa_context_get_state(m_context) == PA_CONTEXT_READY)
                return true;

            disconnectPulse();
            m_mainloop = pa_threaded_mainloop_new();
            if (!m_mainloop)
                return false;

            m_context = pa_context_new(pa_threaded_mainloop_get_api(m_mainloop), "Denial");
            if (!m_context) {
                disconnectPulse();
                return false;
            }

            pa_context_set_state_callback(m_context, &CImpl::onContextState, this);
            pa_context_set_subscribe_callback(m_context, &CImpl::onSubscriptionEvent, this);
            if (pa_context_connect(m_context, nullptr, PA_CONTEXT_NOFLAGS, nullptr) < 0 || pa_threaded_mainloop_start(m_mainloop) < 0) {
                Log::logger->log(Log::WARN, "Denial audio failed to connect to PulseAudio: {}", pulseError());
                disconnectPulse();
                return false;
            }
            m_mainloopStarted = true;

            pa_threaded_mainloop_lock(m_mainloop);
            while (true) {
                const auto state = pa_context_get_state(m_context);
                if (state == PA_CONTEXT_READY)
                    break;
                if (!PA_CONTEXT_IS_GOOD(state)) {
                    pa_threaded_mainloop_unlock(m_mainloop);
                    Log::logger->log(Log::WARN, "Denial audio context failed: {}", pulseError());
                    disconnectPulse();
                    return false;
                }
                pa_threaded_mainloop_wait(m_mainloop);
            }
            pa_threaded_mainloop_unlock(m_mainloop);

            pa_threaded_mainloop_lock(m_mainloop);
            SSuccessQuery subscriptionQuery{.owner = this};
            const auto    subscriptionMask      = static_cast<pa_subscription_mask_t>(PA_SUBSCRIPTION_MASK_SINK | PA_SUBSCRIPTION_MASK_SERVER | PA_SUBSCRIPTION_MASK_SINK_INPUT);
            auto*         subscriptionOperation = pa_context_subscribe(m_context, subscriptionMask, &CImpl::onSuccess, &subscriptionQuery);
            const bool    subscribed            = waitForSuccess(subscriptionOperation, subscriptionQuery);
            pa_threaded_mainloop_unlock(m_mainloop);
            if (!subscribed) {
                Log::logger->log(Log::WARN, "Denial audio event subscription failed: {}", pulseError());
                disconnectPulse();
                return false;
            }

            Log::logger->log(Log::INFO, "Denial audio connected through native libpulse");
            return true;
        }

        void disconnectPulse() {
            if (m_context && m_mainloopStarted) {
                pa_threaded_mainloop_lock(m_mainloop);
                pa_context_disconnect(m_context);
                pa_threaded_mainloop_unlock(m_mainloop);
            }
            if (m_mainloop && m_mainloopStarted)
                pa_threaded_mainloop_stop(m_mainloop);
            m_mainloopStarted = false;

            if (m_context)
                pa_context_unref(m_context);
            m_context = nullptr;
            if (m_mainloop)
                pa_threaded_mainloop_free(m_mainloop);
            m_mainloop = nullptr;
        }

        bool queryDefaultSink(std::string& sink) {
            SServerQuery query{.owner = this};
            pa_threaded_mainloop_lock(m_mainloop);
            auto* operation = pa_context_get_server_info(m_context, &CImpl::onServerInfo, &query);
            if (!operation) {
                pa_threaded_mainloop_unlock(m_mainloop);
                return false;
            }
            while (!query.done && contextReadyLocked())
                pa_threaded_mainloop_wait(m_mainloop);
            pa_operation_unref(operation);
            pa_threaded_mainloop_unlock(m_mainloop);

            if (!query.success)
                return false;
            sink = std::move(query.defaultSink);
            return true;
        }

        bool querySinkState(SSinkState& state) {
            if (!queryDefaultSink(state.name))
                return false;

            SSinkQuery query{.owner = this};
            pa_threaded_mainloop_lock(m_mainloop);
            auto* operation = pa_context_get_sink_info_by_name(m_context, state.name.c_str(), &CImpl::onSinkInfo, &query);
            if (!operation) {
                pa_threaded_mainloop_unlock(m_mainloop);
                return false;
            }
            while (!query.done && contextReadyLocked())
                pa_threaded_mainloop_wait(m_mainloop);
            pa_operation_unref(operation);
            pa_threaded_mainloop_unlock(m_mainloop);

            if (!query.success)
                return false;
            state.volume   = query.volume;
            state.channels = query.channels;
            state.muted    = query.muted;
            return true;
        }

        bool waitForSuccess(pa_operation* operation, SSuccessQuery& query) {
            if (!operation)
                return false;
            while (!query.done && contextReadyLocked())
                pa_threaded_mainloop_wait(m_mainloop);
            pa_operation_unref(operation);
            return query.success;
        }

        bool applySinkLevel(const SSinkState& sink, double level, bool unmute) {
            // Sink volumes use PulseAudio's cubic UI scale. Converting the
            // slider percentage to a linear gain first makes the low end far
            // too loud (20% becomes roughly 58% on the sink scale).
            const auto pulseLevel = static_cast<pa_volume_t>(std::lround(std::clamp(level, 0.0, MAX_AMPLIFIED_LEVEL) * PA_VOLUME_NORM));
            pa_cvolume volume;
            pa_cvolume_set(&volume, sink.channels, pulseLevel);

            pa_threaded_mainloop_lock(m_mainloop);
            SSuccessQuery volumeQuery{.owner = this};
            auto*         volumeOperation = pa_context_set_sink_volume_by_name(m_context, sink.name.c_str(), &volume, &CImpl::onSuccess, &volumeQuery);
            const bool    volumeApplied   = waitForSuccess(volumeOperation, volumeQuery);
            pa_threaded_mainloop_unlock(m_mainloop);
            if (!volumeApplied)
                return false;

            if (unmute) {
                pa_threaded_mainloop_lock(m_mainloop);
                SSuccessQuery muteQuery{.owner = this};
                auto*         muteOperation = pa_context_set_sink_mute_by_name(m_context, sink.name.c_str(), 0, &CImpl::onSuccess, &muteQuery);
                const bool    unmuted       = waitForSuccess(muteOperation, muteQuery);
                pa_threaded_mainloop_unlock(m_mainloop);
                if (!unmuted)
                    return false;
            }

            return true;
        }

        bool applyLevel(double level) {
            SSinkState sink;
            if (!querySinkState(sink))
                return false;

            return applySinkLevel(sink, level, level > 0.0);
        }

        bool applyLevelAdjustment(double delta) {
            SSinkState sink;
            if (!querySinkState(sink))
                return false;

            const auto average = pa_cvolume_avg(&sink.volume);
            const auto level   = std::clamp(static_cast<double>(average) / PA_VOLUME_NORM + delta, 0.0, MAX_AMPLIFIED_LEVEL);
            return applySinkLevel(sink, level, true);
        }

        bool applyMuteToggle() {
            SSinkState sink;
            if (!querySinkState(sink))
                return false;

            pa_threaded_mainloop_lock(m_mainloop);
            SSuccessQuery muteQuery{.owner = this};
            auto*         muteOperation = pa_context_set_sink_mute_by_name(m_context, sink.name.c_str(), sink.muted ? 0 : 1, &CImpl::onSuccess, &muteQuery);
            const bool    muteApplied   = waitForSuccess(muteOperation, muteQuery);
            pa_threaded_mainloop_unlock(m_mainloop);
            return muteApplied;
        }

        bool querySinkInputState(uint32_t streamId, SSinkInputQuery& query) {
            query.owner = this;
            pa_threaded_mainloop_lock(m_mainloop);
            auto* operation = pa_context_get_sink_input_info(m_context, streamId, &CImpl::onSinkInputInfo, &query);
            if (!operation) {
                pa_threaded_mainloop_unlock(m_mainloop);
                return false;
            }
            while (!query.done && contextReadyLocked())
                pa_threaded_mainloop_wait(m_mainloop);
            pa_operation_unref(operation);
            pa_threaded_mainloop_unlock(m_mainloop);
            return query.success;
        }

        bool applyStreamLevel(uint32_t streamId, double level) {
            SSinkInputQuery stream;
            if (!querySinkInputState(streamId, stream))
                return false;

            const auto pulseLevel = static_cast<pa_volume_t>(std::lround(std::clamp(level, 0.0, 1.0) * PA_VOLUME_NORM));
            pa_cvolume volume;
            pa_cvolume_set(&volume, stream.channels, pulseLevel);

            pa_threaded_mainloop_lock(m_mainloop);
            SSuccessQuery volumeQuery{.owner = this};
            auto*         volumeOperation = pa_context_set_sink_input_volume(m_context, streamId, &volume, &CImpl::onSuccess, &volumeQuery);
            const bool    volumeApplied   = waitForSuccess(volumeOperation, volumeQuery);
            pa_threaded_mainloop_unlock(m_mainloop);
            if (!volumeApplied)
                return false;

            pa_threaded_mainloop_lock(m_mainloop);
            SSuccessQuery muteQuery{.owner = this};
            auto*         muteOperation = pa_context_set_sink_input_mute(m_context, streamId, 0, &CImpl::onSuccess, &muteQuery);
            const bool    unmuted       = waitForSuccess(muteOperation, muteQuery);
            pa_threaded_mainloop_unlock(m_mainloop);
            return unmuted;
        }

        std::optional<std::vector<SAudioStream>> readStreams() {
            SSinkInputListQuery query{.owner = this};
            pa_threaded_mainloop_lock(m_mainloop);
            auto* operation = pa_context_get_sink_input_info_list(m_context, &CImpl::onSinkInputList, &query);
            if (!operation) {
                pa_threaded_mainloop_unlock(m_mainloop);
                return {};
            }
            while (!query.done && contextReadyLocked())
                pa_threaded_mainloop_wait(m_mainloop);
            pa_operation_unref(operation);
            pa_threaded_mainloop_unlock(m_mainloop);
            if (!query.success)
                return {};

            std::ranges::sort(query.streams, {}, [](const SAudioStream& stream) { return stream.name; });
            return std::move(query.streams);
        }

        std::optional<double> readLevel() {
            SSinkState sink;
            if (!querySinkState(sink))
                return {};

            const auto average = pa_cvolume_avg(&sink.volume);
            return std::clamp(static_cast<double>(average) / PA_VOLUME_NORM, 0.0, 1.0);
        }
#endif

        void run() {
            while (true) {
                std::optional<double>                level;
                double                               adjustment       = 0.0;
                bool                                 toggleMute       = false;
                bool                                 stateRequested   = false;
                bool                                 streamsRequested = false;
                uint32_t                             requestSerial    = 0;
                std::unordered_map<uint32_t, double> streamLevels;
                {
                    std::unique_lock<std::mutex> lock(m_commandMutex);
                    m_commandCondition.wait(lock, [this] {
                        return m_stopping || m_pendingLevel.has_value() || m_pendingAdjustment != 0.0 || m_pendingMuteToggle || m_stateRequested || m_streamsRequested ||
                            !m_pendingStreamLevels.empty();
                    });
                    if (m_stopping)
                        break;

                    level = m_pendingLevel;
                    m_pendingLevel.reset();
                    adjustment          = m_pendingAdjustment;
                    m_pendingAdjustment = 0.0;
                    toggleMute          = m_pendingMuteToggle;
                    m_pendingMuteToggle = false;
                    stateRequested      = m_stateRequested;
                    m_stateRequested    = false;
                    streamsRequested    = m_streamsRequested;
                    m_streamsRequested  = false;
                    streamLevels.swap(m_pendingStreamLevels);
                    requestSerial          = m_pendingRequestSerial;
                    m_pendingRequestSerial = 0;
                }

#if defined(DENIAL_WITH_PULSE)
                if (!connectPulse())
                    continue;

                if (level && !applyLevel(*level)) {
                    Log::logger->log(Log::WARN, "Denial audio volume write failed: {}", pulseError());
                    disconnectPulse();
                    continue;
                }

                if (adjustment != 0.0 && !applyLevelAdjustment(adjustment)) {
                    Log::logger->log(Log::WARN, "Denial audio volume adjustment failed: {}", pulseError());
                    disconnectPulse();
                    continue;
                }

                if (toggleMute && !applyMuteToggle()) {
                    Log::logger->log(Log::WARN, "Denial audio mute toggle failed: {}", pulseError());
                    disconnectPulse();
                    continue;
                }

                if (stateRequested) {
                    const auto currentLevel = readLevel();
                    if (currentLevel && m_stateCallback)
                        m_stateCallback(*currentLevel, requestSerial);
                }

                for (const auto& [streamId, streamLevel] : streamLevels) {
                    if (!applyStreamLevel(streamId, streamLevel))
                        Log::logger->log(Log::DEBUG, "Denial audio stream disappeared before volume write id={}", streamId);
                }

                if (streamsRequested) {
                    const auto streams = readStreams();
                    if (streams && m_streamsCallback)
                        m_streamsCallback(*streams);
                }
#else
                (void)level;
                (void)adjustment;
                (void)toggleMute;
                (void)stateRequested;
                (void)requestSerial;
                (void)streamsRequested;
                (void)streamLevels;
#endif
            }

#if defined(DENIAL_WITH_PULSE)
            disconnectPulse();
#endif
        }

        TStateCallback                       m_stateCallback;
        TStreamsCallback                     m_streamsCallback;
        std::thread                          m_worker;
        std::mutex                           m_commandMutex;
        std::condition_variable              m_commandCondition;
        std::optional<double>                m_pendingLevel;
        double                               m_pendingAdjustment    = 0.0;
        bool                                 m_pendingMuteToggle    = false;
        uint32_t                             m_pendingRequestSerial = 0;
        bool                                 m_stateRequested       = false;
        bool                                 m_streamsRequested     = false;
        bool                                 m_stopping             = false;
        std::unordered_map<uint32_t, double> m_pendingStreamLevels;

#if defined(DENIAL_WITH_PULSE)
        pa_threaded_mainloop* m_mainloop        = nullptr;
        pa_context*           m_context         = nullptr;
        bool                  m_mainloopStarted = false;
#endif
    };

    CAudioController::CAudioController(TStateCallback stateCallback, TStreamsCallback streamsCallback) :
        m_impl(std::make_unique<CImpl>(std::move(stateCallback), std::move(streamsCallback))) {}

    CAudioController::~CAudioController() = default;

    void CAudioController::requestState() {
        m_impl->requestState();
    }

    void CAudioController::setLevel(double level, uint32_t requestSerial) {
        m_impl->setLevel(level, requestSerial);
    }

    void CAudioController::adjustLevel(double delta) {
        m_impl->adjustLevel(delta);
    }

    void CAudioController::toggleMute() {
        m_impl->toggleMute();
    }

    void CAudioController::requestStreams() {
        m_impl->requestStreams();
    }

    void CAudioController::setStreamLevel(uint32_t streamId, double level) {
        m_impl->setStreamLevel(streamId, level);
    }

}
