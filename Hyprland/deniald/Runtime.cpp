#include "Runtime.hpp"
#include "RuntimeFlutterState.hpp"

#include "AuthenticationController.hpp"
#include "AudioController.hpp"
#include "BrightnessController.hpp"
#include "NotificationServer.hpp"

#include "../src/debug/HyprCtl.hpp"
#include "../src/debug/log/Logger.hpp"
#include "../src/event/EventBus.hpp"
#include "../src/managers/eventLoop/EventLoopManager.hpp"
#include "../src/managers/eventLoop/EventLoopTimer.hpp"

#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace Denial {

    CRuntime::CRuntime(SRuntimeOptions options) : m_options(std::move(options)) {}

    CRuntime::~CRuntime() {
        shutdown();
        closeHapticsSocket();
    }

    bool CRuntime::initializeBeforeHyprlandLoop() {
        if (m_initialized)
            return true;

        m_hyprThreadId = std::this_thread::get_id();
        Log::logger->log(Log::INFO, "Denial runtime hook reached before Hyprland event loop");

        if (!g_pEventLoopManager || !(m_mainLoopSignal = g_pEventLoopManager->createAsyncSignal(&CRuntime::onMainLoopSignal, this))) {
            Log::logger->log(Log::ERR, "Denial could not create its persistent event-loop signal");
            return false;
        }

        m_authenticationController = std::make_unique<CAuthenticationController>([this](SAuthenticationEvent event) {
            auto deliver = [this, event = std::move(event)] {
                if (!m_authenticationController)
                    return;
                applyAuthenticationState(event.state.locked);
                publishAuthenticationEvent(event);
            };
            if (g_pEventLoopManager)
                g_pEventLoopManager->postToLoop(std::move(deliver));
            else
                deliver();
        });

        if (!startFlutterEngine()) {
            m_authenticationController.reset();
            m_mainLoopSignal.reset();
            return false;
        }

        m_closingTextureLeaseTimer = makeShared<CEventLoopTimer>(std::nullopt, [this](SP<CEventLoopTimer>, void*) { expireClosingTextureLeases(); }, nullptr);
        g_pEventLoopManager->addTimer(m_closingTextureLeaseTimer);
        m_resizeTextureHandoffTimer = makeShared<CEventLoopTimer>(std::nullopt, [this](SP<CEventLoopTimer>, void*) { wakeResizeTextureHandoffs(); }, nullptr);
        g_pEventLoopManager->addTimer(m_resizeTextureHandoffTimer);

        m_notificationServer = std::make_unique<CNotificationServer>([this](SNotificationEvent event) {
            auto publish = [this, event = std::move(event)] { publishNotificationEvent(event); };
            if (g_pEventLoopManager)
                g_pEventLoopManager->postToLoop(std::move(publish));
            else
                publish();
        });
        if (!m_notificationServer->start()) {
            Log::logger->log(Log::ERR, "Denial could not start its notification service thread");
            m_notificationServer.reset();
        }

        m_acceptTextureMarks.store(true, std::memory_order_release);
        m_decorationPolicyReload = Event::bus()->m_events.config.reloaded.listen([this] {
            if (m_initialized)
                notifyWindowObjectsChanged();
        });
        m_surfaceRegistry.start(this);
        setFrameSink(this);
        setInputRouter(this);
        setScreenCopyFrameProvider(this);
        if (g_pHyprCtl) {
            m_flutterReloadCommand = g_pHyprCtl->registerCommand(SHyprCtlCommand{
                .name  = "denial-reload",
                .exact = true,
                .fn =
                    [this](eHyprCtlOutputFormat format, std::string) {
                        m_flutterForcedRestartRequested.store(true, std::memory_order_release);
                        m_flutterRestartRequested.store(true, std::memory_order_release);
                        requestOutputFrame();
                        Log::logger->log(Log::INFO, "Denial Flutter engine reload scheduled");
                        return format == FORMAT_JSON ? R"({"ok":true,"status":"scheduled"})" : "ok";
                    },
            });
            m_lockCommand          = g_pHyprCtl->registerCommand(SHyprCtlCommand{
                .name  = "denial-lock",
                .exact = false,
                .fn    = [this](eHyprCtlOutputFormat format, std::string request) { return handleAuthenticationCommand(format, std::move(request)); },
            });
        }
        Log::logger->log(Log::INFO, "Denial runtime installed as Hyprland frame sink");
        m_initialized = true;
        return true;
    }

    void CRuntime::shutdown() {
        if (!m_initialized)
            return;

        m_initialized = false;
        m_decorationPolicyReload.reset();
        m_notificationServer.reset();
        m_audioController.reset();
        m_brightnessController.reset();
        m_flutterRestartRequested.store(false, std::memory_order_release);
        m_flutterForcedRestartRequested.store(false, std::memory_order_release);
        if (g_pHyprCtl && m_flutterReloadCommand)
            g_pHyprCtl->unregisterCommand(m_flutterReloadCommand);
        m_flutterReloadCommand.reset();
        if (g_pHyprCtl && m_lockCommand)
            g_pHyprCtl->unregisterCommand(m_lockCommand);
        m_lockCommand.reset();
        m_acceptTextureMarks.store(false, std::memory_order_release);
        m_tickerPulseRequired = false;
        m_flutterProducerState.store(eFlutterProducerState::IDLE, std::memory_order_release);
        m_flutterRasterSentinelPending.store(false, std::memory_order_release);
#if defined(DENIAL_ENABLE_DIAGNOSTICS)
        m_importedFrameTimingEnabled.store(false, std::memory_order_release);
#endif
        cancelDirectOutputTarget();
        m_directTargetState.store(eDirectTargetState::FAILED, std::memory_order_release);
        m_directTargetState.notify_all();
        cancelSharedAtlasTarget();
        m_sharedAtlasTargetState.store(eDirectTargetState::FAILED, std::memory_order_release);
        m_sharedAtlasTargetState.notify_all();
        // Release a raster callback that may be waiting for the main-thread
        // submit while the compositor is shutting down.
        if (m_readyOutputFramePublished.exchange(false, std::memory_order_acq_rel) && m_readyOutputFrame)
            releaseSampledBuffersAfterRender(*m_readyOutputFrame);
        for (auto& [monitorId, pipeline] : m_outputPipelines) {
            if (!pipeline)
                continue;
            if (pipeline->readyScanoutFrame)
                releaseSampledBuffersAfterRender(*pipeline->readyScanoutFrame);
            if (pipeline->submittedOutputFrame)
                releaseSampledBuffersAfterRender(*pipeline->submittedOutputFrame);
            if (pipeline->scanningOutputFrame)
                releaseSampledBuffersAfterRender(*pipeline->scanningOutputFrame);
        }
        m_readyOutputFrame.reset();
        for (auto& [monitorId, pipeline] : m_outputPipelines) {
            if (!pipeline)
                continue;
            pipeline->readyScanoutFrame.reset();
            pipeline->submittedOutputFrame.reset();
            pipeline->scanningOutputFrame.reset();
            pipeline->physicalPulse.reset();
            pipeline->presented.reset();
            pipeline->modeChanged.reset();
        }
        m_mainLoopRequests.store(0, std::memory_order_release);
        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            m_pendingTextureMarks.clear();
            m_pendingSampleReleases.clear();
        }
        finishSceneSubmit(false);
        setFrameSink(nullptr);
        setInputRouter(nullptr);
        setScreenCopyFrameProvider(nullptr);
        m_authenticationController.reset();
        closeHapticsSocket();
        if (m_closingTextureLeaseTimer && g_pEventLoopManager)
            g_pEventLoopManager->removeTimer(m_closingTextureLeaseTimer);
        m_closingTextureLeaseTimer.reset();
        if (m_resizeTextureHandoffTimer && g_pEventLoopManager)
            g_pEventLoopManager->removeTimer(m_resizeTextureHandoffTimer);
        m_resizeTextureHandoffTimer.reset();
        m_surfaceRegistry.stop();
        if (m_flutter && denial_engine_host_running(m_flutter->host)) {
            std::vector<intptr_t> shutdownBatons;
            {
                std::lock_guard<std::mutex> lock(m_vsyncMutex);
                shutdownBatons.swap(m_pendingVsyncBatons);
            }
            if (!shutdownBatons.empty()) {
                uint64_t intervalNanos = 16666666;
                {
                    std::lock_guard<std::mutex> lock(m_renderTargetMutex);
                    if (m_lastOutputRenderTarget && m_lastOutputRenderTarget->refreshRate > 0)
                        intervalNanos = sc<uint64_t>(1000000000.0 / m_lastOutputRenderTarget->refreshRate);
                }
                const auto now = denial_engine_host_current_time_nanos(m_flutter->host);
                for (const auto baton : shutdownBatons)
                    denial_engine_host_on_vsync(m_flutter->host, baton, now, now + intervalNanos);
            }
            denial_engine_host_stop(m_flutter->host);
        }
#if defined(DENIAL_ENABLE_DIAGNOSTICS)
        m_importedFrameTimings.clear();
#endif
        if (m_flutterTaskTimer && g_pEventLoopManager)
            g_pEventLoopManager->removeTimer(m_flutterTaskTimer);
        m_flutterTaskTimer.reset();
        destroyOutputTargets();
        m_deferredSampledBufferHolds.clear();
        destroyImportedTextures();
        m_lastOutputMonitorId = -1;
        {
            std::lock_guard<std::mutex> lock(m_flutterTaskMutex);
            m_flutterTasks               = {};
            m_flutterTaskDispatchPending = false;
        }
        m_flutter.reset();
        m_mainLoopSignal.reset();

        Log::logger->log(Log::INFO, "Denial runtime shutdown");
    }

    bool CRuntime::initialized() const {
        return m_initialized;
    }

    bool CRuntime::requestMainLoop(uint32_t requests) {
        const auto previous = m_mainLoopRequests.fetch_or(requests, std::memory_order_acq_rel);
        if (previous != 0)
            return true;

        if (m_mainLoopSignal && m_mainLoopSignal->signal())
            return true;

        m_mainLoopRequests.fetch_and(~requests, std::memory_order_release);
        return false;
    }

    void CRuntime::processMainLoopRequests() {
        const auto requests = m_mainLoopRequests.exchange(0, std::memory_order_acquire);

        if (requests & MAIN_LOOP_CANCEL_ATLAS_TARGET)
            cancelSharedAtlasTarget();
        if (requests & MAIN_LOOP_CANCEL_DIRECT_TARGET)
            cancelDirectOutputTarget();
        if (requests & MAIN_LOOP_PREPARE_ATLAS_TARGET)
            prepareSharedAtlasTarget();
        if (requests & MAIN_LOOP_PREPARE_DIRECT_TARGET)
            prepareDirectOutputTarget();
        if (requests & MAIN_LOOP_TEXTURE_MARK)
            processPendingTextureMarks();
        if ((requests & MAIN_LOOP_SUBMIT_SCENE) && m_readyOutputFramePublished.exchange(false, std::memory_order_acq_rel)) {
            auto frame = std::move(*m_readyOutputFrame);
            m_readyOutputFrame.reset();
            prepareRenderedFrame(std::move(frame));
        }
        if (requests & MAIN_LOOP_OUTPUT_FRAME)
            requestOutputFrame();
        if (requests & MAIN_LOOP_FLUTTER_TASK)
            processFlutterTasks();
    }

    void CRuntime::onMainLoopSignal(void* userData) {
        sc<CRuntime*>(userData)->processMainLoopRequests();
    }

} // namespace Denial
