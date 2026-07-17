#include "Runtime.hpp"
#include "RuntimeEGL.hpp"
#include "RuntimeFlutterState.hpp"
#include "RuntimeInternal.hpp"

#include "AuthenticationController.hpp"
#include "AuthenticationProtocol.hpp"
#include "AudioController.hpp"
#include "BrightnessController.hpp"
#include "ClosingTextureLease.hpp"
#include "Wire.hpp"

#include "../src/Compositor.hpp"
#include "../src/debug/log/Logger.hpp"
#include "../src/devices/IKeyboard.hpp"
#include "../src/helpers/time/Time.hpp"
#include "../src/managers/SeatManager.hpp"
#include "../src/managers/eventLoop/EventLoopManager.hpp"
#include "../src/managers/eventLoop/EventLoopTimer.hpp"
#include "../src/render/OpenGL.hpp"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#include <dlfcn.h>

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <ranges>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace Denial {

    using RuntimeInternal::BRIGHTNESS_CHANNEL;
#if defined(DENIAL_ENABLE_DIAGNOSTICS)
    using RuntimeInternal::IMPORTED_FRAME_TIMING_CONTROL_CHANNEL;
#endif
    using RuntimeInternal::SYSTEM_COMMAND_CHANNEL;
    using RuntimeInternal::makeFlutterContextCurrent;

    namespace {
        std::optional<Time::steady_dur> flutterTaskDelay(uint64_t delayNanos) {
            constexpr uint64_t MIN_DELAY_NANOS = 100ULL * 1000ULL;
            constexpr uint64_t MAX_DELAY_NANOS = sc<uint64_t>(std::numeric_limits<int64_t>::max());
            return std::chrono::nanoseconds(sc<int64_t>(std::clamp(delayNanos, MIN_DELAY_NANOS, MAX_DELAY_NANOS)));
        }

        void* resolveGLProc(const char* name) {
            if (!name)
                return nullptr;

            if (auto* proc = rc<void*>(eglGetProcAddress(name)))
                return proc;

            static void* gles = []() -> void* {
                if (auto* handle = dlopen("libGLESv2.so.2", RTLD_LAZY | RTLD_LOCAL))
                    return handle;
                return dlopen("libGLESv2.so", RTLD_LAZY | RTLD_LOCAL);
            }();

            if (gles) {
                if (auto* proc = dlsym(gles, name))
                    return proc;
            }

            return dlsym(RTLD_DEFAULT, name);
        }

        EGLContext createSharedFlutterContext(EGLDisplay display, EGLContext shareContext) {
            if (display == EGL_NO_DISPLAY || shareContext == EGL_NO_CONTEXT)
                return EGL_NO_CONTEXT;

            eglBindAPI(EGL_OPENGL_ES_API);

            const auto*         EXTENSIONS_RAW = eglQueryString(display, EGL_EXTENSIONS);
            const std::string   EXTENSIONS     = EXTENSIONS_RAW ? EXTENSIONS_RAW : "";

            std::vector<EGLint> baseAttrs;
            if (EXTENSIONS.contains("EGL_IMG_context_priority")) {
                baseAttrs.push_back(EGL_CONTEXT_PRIORITY_LEVEL_IMG);
                baseAttrs.push_back(EGL_CONTEXT_PRIORITY_HIGH_IMG);
            }

            if (EXTENSIONS.contains("EGL_EXT_create_context_robustness")) {
                baseAttrs.push_back(EGL_CONTEXT_OPENGL_RESET_NOTIFICATION_STRATEGY_EXT);
                baseAttrs.push_back(EGL_LOSE_CONTEXT_ON_RESET_EXT);
            }

            if (EXTENSIONS.contains("EGL_KHR_context_flush_control")) {
                baseAttrs.push_back(EGL_CONTEXT_RELEASE_BEHAVIOR_KHR);
                baseAttrs.push_back(EGL_CONTEXT_RELEASE_BEHAVIOR_NONE_KHR);
            }

            auto attrsForVersion = [&baseAttrs](EGLint minor) {
                auto attrs = baseAttrs;
                attrs.push_back(EGL_CONTEXT_MAJOR_VERSION);
                attrs.push_back(3);
                attrs.push_back(EGL_CONTEXT_MINOR_VERSION);
                attrs.push_back(minor);
                attrs.push_back(EGL_NONE);
                return attrs;
            };

            const auto ATTRS_GLES32 = attrsForVersion(2);
            EGLContext context      = eglCreateContext(display, EGL_NO_CONFIG_KHR, shareContext, ATTRS_GLES32.data());
            if (context != EGL_NO_CONTEXT)
                return context;

            const auto ERR32 = eglGetError();
            Log::logger->log(Log::WARN, "Denial failed to create shared Flutter GLES 3.2 context: eglGetError={}", ERR32);

            const auto ATTRS_GLES30 = attrsForVersion(0);
            context                 = eglCreateContext(display, EGL_NO_CONFIG_KHR, shareContext, ATTRS_GLES30.data());
            if (context != EGL_NO_CONTEXT)
                return context;

            Log::logger->log(Log::ERR, "Denial failed to create shared Flutter GLES 3.0 context: eglGetError={}", eglGetError());
            return EGL_NO_CONTEXT;
        }
    } // namespace

    CRuntime::SFlutterRuntime::SFlutterRuntime() {
        host = denial_engine_host_create();

        if (Render::GL::g_pHyprOpenGL) {
            eglDisplay          = Render::GL::g_pHyprOpenGL->m_eglDisplay;
            renderContext       = createSharedFlutterContext(eglDisplay, Render::GL::g_pHyprOpenGL->m_eglContext);
            resourceContext     = createSharedFlutterContext(eglDisplay, Render::GL::g_pHyprOpenGL->m_eglContext);
            presentationContext = createSharedFlutterContext(eglDisplay, Render::GL::g_pHyprOpenGL->m_eglContext);
        }
    }

    CRuntime::SFlutterRuntime::~SFlutterRuntime() {
        denial_engine_host_destroy(host);
        if (sceneRenderFence != EGL_NO_SYNC_KHR && eglDisplay != EGL_NO_DISPLAY && renderContext != EGL_NO_CONTEXT && Render::GL::g_pHyprOpenGL &&
            Render::GL::g_pHyprOpenGL->m_proc.eglDestroySyncKHR) {
            eglMakeCurrent(eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, renderContext);
            glFinish();
            Render::GL::g_pHyprOpenGL->m_proc.eglDestroySyncKHR(eglDisplay, sceneRenderFence);
        }
        if (sceneCopyFence != EGL_NO_SYNC_KHR && eglDisplay != EGL_NO_DISPLAY && presentationContext != EGL_NO_CONTEXT && Render::GL::g_pHyprOpenGL &&
            Render::GL::g_pHyprOpenGL->m_proc.eglDestroySyncKHR) {
            eglMakeCurrent(eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, presentationContext);
            glFinish();
            Render::GL::g_pHyprOpenGL->m_proc.eglDestroySyncKHR(eglDisplay, sceneCopyFence);
        }
        if (eglDisplay != EGL_NO_DISPLAY && renderContext != EGL_NO_CONTEXT)
            eglDestroyContext(eglDisplay, renderContext);
        if (eglDisplay != EGL_NO_DISPLAY && resourceContext != EGL_NO_CONTEXT)
            eglDestroyContext(eglDisplay, resourceContext);
        if (eglDisplay != EGL_NO_DISPLAY && presentationContext != EGL_NO_CONTEXT)
            eglDestroyContext(eglDisplay, presentationContext);
    }

    bool CRuntime::queueFlutterRasterSentinel() {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return false;

        bool expected = false;
        if (!m_flutterRasterSentinelPending.compare_exchange_strong(expected, true, std::memory_order_acq_rel, std::memory_order_acquire))
            return true;

        if (denial_engine_host_post_raster_task(m_flutter->host, &CRuntime::onFlutterRasterIdle, this))
            return true;

        m_flutterRasterSentinelPending.store(false, std::memory_order_release);
        return false;
    }

    void CRuntime::finishFlutterRasterFrame() {
        const auto previous = m_flutterProducerState.exchange(eFlutterProducerState::IDLE, std::memory_order_acq_rel);
        if (previous == eFlutterProducerState::IDLE)
            return;

        // PREPARING means present() already sealed and transferred the sample
        // set. Any samples left by RASTERIZING belonged to a legal skipped
        // present and must be re-armed without creating another pacing path.
        if (previous == eFlutterProducerState::RASTERIZING || previous == eFlutterProducerState::REQUESTED) {
            std::unordered_map<TSurfaceId, uint64_t> abandonedSamples;
            std::vector<SImportedFrameHold>          abandonedBufferHolds;
            {
                std::lock_guard<std::mutex> lock(m_externalTextureMutex);
                abandonedSamples.swap(m_rasterSampledGenerations);
                abandonedBufferHolds.swap(m_rasterSampledBufferHolds);
            }
            if (!abandonedBufferHolds.empty())
                glFinish();
            queueTextureMarksForGenerations(abandonedSamples);
            releaseSampleHoldsOnMainThread(std::move(abandonedBufferHolds));
        }

        // AwaitVSync can be requested before the preceding raster sentinel
        // returns the producer to IDLE. Request one physical ticker pulse now
        // that the baton can actually be consumed.
        if (hasPendingFlutterVsync())
            requestMainLoop(MAIN_LOOP_OUTPUT_FRAME);
    }

    bool CRuntime::startFlutterEngine() {
        if (m_options.dartBundlePath.empty()) {
            Log::logger->log(Log::ERR, "Denial Flutter engine startup requested without --flutter-bundle");
            return false;
        }

        const std::filesystem::path BUNDLE = m_options.dartBundlePath;
        const auto                  ASSETS = BUNDLE / "data" / "flutter_assets";
        const auto                  ICU    = BUNDLE / "data" / "icudtl.dat";
        auto                        AOT    = BUNDLE / "lib" / "libapp.so";
        if (!std::filesystem::exists(AOT))
            AOT = BUNDLE / "libapp.so";

        if (!std::filesystem::exists(ASSETS) || !std::filesystem::exists(ICU) || !std::filesystem::exists(AOT)) {
            Log::logger->log(Log::ERR, "Denial invalid Flutter bundle '{}': expected data/flutter_assets, data/icudtl.dat and lib/libapp.so", BUNDLE.string());
            return false;
        }

        if (!refreshDisplayLayout(true)) {
            Log::logger->log(Log::ERR, "Denial cannot start Flutter without at least one enabled output");
            return false;
        }
        m_tickerPulseRequired = false;
#if defined(DENIAL_ENABLE_DIAGNOSTICS)
        m_sharedAtlasMailboxSupersedes = 0;
#endif
        m_sharedAtlasScanoutCapable = !m_sharedAtlasScanoutSuppressed.load(std::memory_order_acquire) && initializeSharedAtlasScanout();
        m_sharedAtlasScanoutActive.store(m_sharedAtlasScanoutCapable.load(std::memory_order_acquire), std::memory_order_release);
        m_sharedAtlasRenderTarget = nullptr;
        m_sharedAtlasTargetState.store(eDirectTargetState::IDLE, std::memory_order_release);
        m_sharedAtlasTargetState.notify_all();
        m_directKmsActive       = m_options.directKmsRendering && m_displayLayout.outputs.size() == 1;
        m_directOutputTarget    = nullptr;
        m_directOutputMonitorId = -1;
        m_directTargetState.store(eDirectTargetState::IDLE, std::memory_order_release);
        m_directTargetState.notify_all();
        if (m_options.directKmsRendering && !m_directKmsActive) {
            Log::logger->log(Log::INFO, "Denial direct KMS selected the shared scanout atlas for {} outputs", m_displayLayout.outputs.size());
        }

        m_flutter = std::make_unique<SFlutterRuntime>();
        if (m_flutter->renderContext == EGL_NO_CONTEXT || m_flutter->resourceContext == EGL_NO_CONTEXT || m_flutter->presentationContext == EGL_NO_CONTEXT) {
            Log::logger->log(Log::ERR, "Denial cannot start Flutter without shared EGL render/resource/presentation contexts");
            destroySharedAtlasTargets();
            m_flutter.reset();
            return false;
        }

        DenialRenderCallbacks callbacks = {
            .user_data                = this,
            .make_current             = &CRuntime::onFlutterMakeCurrent,
            .clear_current            = &CRuntime::onFlutterClearCurrent,
            .present_with_info        = &CRuntime::onFlutterPresentWithInfo,
            .populate_existing_damage = &CRuntime::onFlutterExistingDamage,
            .fbo                      = &CRuntime::onFlutterFBO,
            .resource_make_current    = &CRuntime::onFlutterResourceMakeCurrent,
            .gl_proc_resolver         = &CRuntime::onFlutterProcResolver,
            .resize                   = &CRuntime::onFlutterResize,
            .bounds                   = &CRuntime::onFlutterBounds,
            .dpi_scale                = &CRuntime::onFlutterDpiScale,
            .frame_rate               = &CRuntime::onFlutterFrameRate,
            .surface_transform        = &CRuntime::onFlutterSurfaceTransform,
        };
        if (m_directKmsActive) {
            callbacks.present_with_info        = &CRuntime::onFlutterDirectPresentWithInfo;
            callbacks.populate_existing_damage = &CRuntime::onFlutterDirectExistingDamage;
            callbacks.fbo                      = &CRuntime::onFlutterDirectFBO;
        } else if (m_sharedAtlasScanoutActive.load(std::memory_order_acquire)) {
            callbacks.present_with_info        = &CRuntime::onFlutterSharedAtlasPresentWithInfo;
            callbacks.populate_existing_damage = &CRuntime::onFlutterSharedAtlasExistingDamage;
            callbacks.fbo                      = &CRuntime::onFlutterSharedAtlasFBO;
        }

        DenialSchedulerCallbacks scheduler = {
            .user_data                   = this,
            .runs_task_on_current_thread = &CRuntime::onFlutterRunsTaskOnCurrentThread,
            .post_task                   = &CRuntime::onFlutterPostTask,
            .request_vsync               = &CRuntime::onFlutterVsyncRequest,
        };

        const bool STARTED = denial_engine_host_start(m_flutter->host, ASSETS.c_str(), ICU.c_str(), AOT.c_str(), &callbacks, &scheduler);
        if (!STARTED) {
            Log::logger->log(Log::ERR, "Denial failed to start the Flutter engine");
            m_flutter.reset();
            return false;
        }

        if (g_pSeatManager) {
            const auto keyboard = g_pSeatManager->m_keyboard.lock();
            if (keyboard && !keyboard->isVirtual() && !keyboard->m_xkbKeymapV1String.empty()) {
                sendFlutterKeyboardKeymap(keyboard->m_xkbKeymapV1String);
                sendFlutterKeyboardModifiers(SFlutterKeyboardModifiers{
                    .depressed = keyboard->m_modifiersState.depressed,
                    .latched   = keyboard->m_modifiersState.latched,
                    .locked    = keyboard->m_modifiersState.locked,
                    .group     = keyboard->m_modifiersState.group,
                });
            }
        }

        const char* DAMAGE_MODE = m_options.disableDamageTracking ? "full-runtime-disabled" : "dirty";

        if (g_pEventLoopManager) {
            m_flutterTaskTimer = makeShared<CEventLoopTimer>(std::nullopt, [this](SP<CEventLoopTimer>, void*) { processFlutterTasks(); }, nullptr);
            g_pEventLoopManager->addTimer(m_flutterTaskTimer);
        }

        denial_engine_host_set_platform_message_handler(m_flutter->host, BridgeWire::TO_NATIVE_CHANNEL, &CRuntime::onWireMessage, this);
        denial_engine_host_set_platform_message_handler(m_flutter->host, "denial/haptics", &CRuntime::onHapticsMessage, this);
        denial_engine_host_set_platform_message_handler(m_flutter->host, "denial/audio", &CRuntime::onAudioMessage, this);
        denial_engine_host_set_platform_message_handler(m_flutter->host, BRIGHTNESS_CHANNEL, &CRuntime::onBrightnessMessage, this);
        denial_engine_host_set_platform_message_handler(m_flutter->host, SYSTEM_COMMAND_CHANNEL, &CRuntime::onSystemCommandMessage, this);
        denial_engine_host_set_platform_message_handler(m_flutter->host, AuthenticationProtocol::TO_NATIVE_CHANNEL, &CRuntime::onAuthenticationMessage, this);
        denial_engine_host_set_platform_message_handler(m_flutter->host, ClosingTextureLease::COMPLETION_CHANNEL, &CRuntime::onWindowCloseCompleteMessage, this);
#if defined(DENIAL_ENABLE_DIAGNOSTICS)
        denial_engine_host_set_platform_message_handler(m_flutter->host, IMPORTED_FRAME_TIMING_CONTROL_CHANNEL, &CRuntime::onImportedFrameTimingControlMessage, this);
#endif
        if (m_authenticationController)
            m_authenticationController->synchronize();
        if (!m_audioController) {
            m_audioController = std::make_unique<CAudioController>(
                [this](double level, uint32_t requestSerial) {
                    const auto publish = [this, level, requestSerial] {
                        if (m_initialized)
                            publishAudioLevel(level, requestSerial);
                    };
                    if (g_pEventLoopManager)
                        g_pEventLoopManager->postToLoop(publish);
                    else
                        publish();
                },
                [this](const std::vector<SAudioStream>& streams) {
                    const auto publish = [this, streams] {
                        if (m_initialized)
                            publishAudioStreams(streams);
                    };
                    if (g_pEventLoopManager)
                        g_pEventLoopManager->postToLoop(publish);
                    else
                        publish();
                });
        }
#if defined(DENIAL_WITH_DDCUTIL)
        if (!m_brightnessController) {
            m_brightnessController = std::make_unique<CBrightnessController>([this](int64_t monitorId, double level) {
                const auto publish = [this, monitorId, level] {
                    if (m_initialized)
                        publishBrightnessLevel(monitorId, level);
                };
                if (g_pEventLoopManager)
                    g_pEventLoopManager->postToLoop(publish);
                else
                    publish();
            });
        }
#endif
        const char* renderPath = m_directKmsActive ? "direct-kms" : m_sharedAtlasScanoutActive.load(std::memory_order_acquire) ? "shared-atlas-scanout" : "scene-blit";
        Log::logger->log(Log::INFO, "Denial Flutter engine started from bundle '{}' output_transform={} render_path={} damage_mode={} scene_copy_sync={}", BUNDLE.string(),
                         m_options.flutterOutputTransform, renderPath, DAMAGE_MODE, m_options.forceBlockingSceneCopy ? "blocking" : "native-fence");
        return true;
    }

    bool CRuntime::restartFlutterEngineIfReady(PHLMONITOR monitor) {
        if (!m_flutterRestartRequested.load(std::memory_order_acquire) || !monitor)
            return false;

        const auto configuredTicker = g_pCompositor ? g_pCompositor->getMonitorFromID(m_displayLayout.tickerMonitorId) : nullptr;
        if (configuredTicker && configuredTicker->m_enabled && configuredTicker->m_output && monitor->m_id != m_displayLayout.tickerMonitorId)
            return false;

        const bool outputSubmitPending = std::ranges::any_of(m_outputPipelines, [](const auto& entry) { return entry.second && entry.second->submittedOutputFrame.has_value(); });
        if (outputSubmitPending || m_readyOutputFramePublished.load(std::memory_order_acquire) ||
            m_flutterProducerState.load(std::memory_order_acquire) != eFlutterProducerState::IDLE ||
            m_sceneSubmitState.load(std::memory_order_acquire) == eSceneSubmitState::IN_FLIGHT)
            return false;

        // modeChanged is also emitted while the backend finishes an initial
        // modeset.  In that case the effective atlas is often unchanged.  Do
        // not tear a live Dart isolate down for a notification alone: apart
        // from being expensive, collecting its AOT mapping can race Dart VM
        // worker tasks that are still draining after FlutterEngineShutdown.
        const bool forcedRestart = m_flutterForcedRestartRequested.load(std::memory_order_acquire);
        if (!forcedRestart && refreshDisplayLayout(false)) {
            m_flutterRestartRequested.store(false, std::memory_order_release);
            return false;
        }

        if (!m_flutterRestartRequested.exchange(false, std::memory_order_acq_rel))
            return false;

        m_flutterForcedRestartRequested.store(false, std::memory_order_release);
        restartFlutterEngine(monitor);
        return true;
    }

    bool CRuntime::restartFlutterEngine(PHLMONITOR monitor) {
        Log::logger->log(Log::INFO, "Denial Flutter engine in-process restart begin");
        m_acceptTextureMarks.store(false, std::memory_order_release);
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

        if (m_readyOutputFramePublished.exchange(false, std::memory_order_acq_rel) && m_readyOutputFrame)
            releaseSampledBuffersAfterRender(*m_readyOutputFrame);
        m_readyOutputFrame.reset();
        finishSceneSubmit(false);

        for (auto& [monitorId, pipeline] : m_outputPipelines) {
            if (!pipeline || !pipeline->readyScanoutFrame)
                continue;
            auto* target = pipeline->readyScanoutFrame->target;
            releaseSampledBuffersAfterRender(*pipeline->readyScanoutFrame);
            if (target && (!pipeline->scanningOutputFrame || target != pipeline->scanningOutputFrame->target)) {
                transitionOutputTarget(*target, eOutputBufferEvent::DROP_READY, "engine restart ready-frame discard");
                const auto output = pipeline->monitor.lock();
                if (!target->sharedAtlasView && output && output->m_output && output->m_output->swapchain)
                    output->m_output->swapchain->rollback();
            }
            pipeline->readyScanoutFrame.reset();
        }

        m_surfaceRegistry.stop();

        if (m_flutterTaskTimer && g_pEventLoopManager)
            g_pEventLoopManager->removeTimer(m_flutterTaskTimer);
        m_flutterTaskTimer.reset();

        if (m_flutter && denial_engine_host_running(m_flutter->host)) {
            std::vector<intptr_t> pendingBatons;
            {
                std::lock_guard<std::mutex> lock(m_vsyncMutex);
                pendingBatons.swap(m_pendingVsyncBatons);
            }
            const auto now      = denial_engine_host_current_time_nanos(m_flutter->host);
            const auto interval = m_outputIntervalNanos > 0 ? m_outputIntervalNanos : 16666666ULL;
            for (const auto baton : pendingBatons)
                denial_engine_host_on_vsync(m_flutter->host, baton, now, now + interval);
            denial_engine_host_stop(m_flutter->host);
        }

        // Flutter owns the render/resource contexts until Shutdown has joined
        // its worker threads. Releasing GL objects before that point races the
        // old raster thread and makes eglMakeCurrent fail with EGL_BAD_ACCESS.
        // Also discard any AwaitVSync request posted during shutdown so an old
        // engine baton can never be delivered to the replacement engine.
        {
            std::lock_guard<std::mutex> lock(m_vsyncMutex);
            m_pendingVsyncBatons.clear();
        }
        destroyImportedTextures();
        resetOutputGraphicsForEngineRestart();

        {
            std::lock_guard<std::mutex> lock(m_flutterTaskMutex);
            m_flutterTasks               = {};
            m_flutterTaskDispatchPending = false;
        }
        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            m_pendingTextureMarks.clear();
            m_pendingSampleReleases.clear();
        }
        {
            std::lock_guard<std::mutex> lock(m_inputRegionMutex);
            m_inputLayoutBuffer.reset();
        }
        m_flutterKeyboardCapture.store(false, std::memory_order_release);
        m_flutterShellExclusive.store(false, std::memory_order_release);

        m_flutterProducerState.store(eFlutterProducerState::IDLE, std::memory_order_release);
#if defined(DENIAL_ENABLE_DIAGNOSTICS)
        m_importedFrameTimings.clear();
#endif
        m_flutter.reset();

        m_displayLayoutSignature.clear();

        if (!startFlutterEngine()) {
            Log::logger->log(Log::ERR, "Denial Flutter engine in-process restart failed; compositor and clients remain alive");
            requestOutputFrame();
            return false;
        }

        m_acceptTextureMarks.store(true, std::memory_order_release);
        m_surfaceRegistry.start(this);
        requestOutputFrame();
        Log::logger->log(Log::INFO, "Denial Flutter engine in-process restart complete");
        return true;
    }

    void CRuntime::processFlutterTasks() {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return;

        {
            std::lock_guard<std::mutex> lock(m_flutterTaskMutex);
            m_flutterTaskDispatchPending = false;
        }

        while (true) {
            SFlutterTask task;
            {
                const auto                  nowNanos = denial_engine_host_current_time_nanos(m_flutter->host);
                std::lock_guard<std::mutex> lock(m_flutterTaskMutex);
                if (m_flutterTasks.empty() || m_flutterTasks.top().targetTimeNanos > nowNanos)
                    break;
                task = m_flutterTasks.top();
                m_flutterTasks.pop();
            }

            const bool ran = denial_engine_host_run_task(m_flutter->host, &task.task);
            if (!ran) {
                DENIAL_HOT_LOG(Log::ERR, "Denial failed to run Flutter platform task {}", task.task.task);
            }
        }

        std::optional<uint64_t> nextTargetNanos;
        {
            std::lock_guard<std::mutex> lock(m_flutterTaskMutex);
            if (!m_flutterTasks.empty())
                nextTargetNanos = m_flutterTasks.top().targetTimeNanos;
        }

        if (!m_flutterTaskTimer)
            return;
        if (!nextTargetNanos) {
            m_flutterTaskTimer->updateTimeout(std::nullopt);
            return;
        }

        const auto nowNanos   = denial_engine_host_current_time_nanos(m_flutter->host);
        const auto delayNanos = *nextTargetNanos > nowNanos ? *nextTargetNanos - nowNanos : 0;
        m_flutterTaskTimer->updateTimeout(flutterTaskDelay(delayNanos));
    }

    bool CRuntime::onFlutterMakeCurrent(void* userData) {
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime || !runtime->m_flutter)
            return false;

        const bool OK = makeFlutterContextCurrent(runtime->m_flutter->eglDisplay, runtime->m_flutter->renderContext, "Flutter render");
        if (OK) {
            auto expected = eFlutterProducerState::REQUESTED;
            if (runtime->m_flutterProducerState.compare_exchange_strong(expected, eFlutterProducerState::RASTERIZING, std::memory_order_acq_rel, std::memory_order_acquire) &&
                !runtime->queueFlutterRasterSentinel())
                runtime->finishFlutterRasterFrame();
        }
#if defined(DENIAL_ENABLE_DIAGNOSTICS)
        if (OK) {
            static bool loggedVersion = false;
            if (!loggedVersion) {
                const auto* version = rc<const char*>(glGetString(GL_VERSION));
                DENIAL_HOT_LOG(Log::INFO, "Denial Flutter GL context current: {}", version);
                loggedVersion = true;
            }
        }
#endif

        return OK;
    }

    bool CRuntime::onFlutterClearCurrent(void* userData) {
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime || !runtime->m_flutter || runtime->m_flutter->eglDisplay == EGL_NO_DISPLAY)
            return true;

        const auto CURRENT = eglGetCurrentContext();
        if (CURRENT != runtime->m_flutter->renderContext && CURRENT != runtime->m_flutter->resourceContext)
            return true;

        return eglMakeCurrent(runtime->m_flutter->eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT) == EGL_TRUE;
    }

    void CRuntime::onFlutterRasterIdle(void* userData) {
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime)
            return;

        runtime->m_flutterRasterSentinelPending.store(false, std::memory_order_release);
        runtime->finishFlutterRasterFrame();

        bool hasDeferredTextureWork = false;
        {
            std::lock_guard<std::mutex> lock(runtime->m_externalTextureMutex);
            hasDeferredTextureWork = !runtime->m_pendingTextureMarks.empty() || !runtime->m_pendingSampleReleases.empty();
        }
        if (hasDeferredTextureWork)
            runtime->requestMainLoop(MAIN_LOOP_TEXTURE_MARK);
    }

    bool CRuntime::onFlutterResourceMakeCurrent(void* userData) {
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime || !runtime->m_flutter)
            return false;

        return makeFlutterContextCurrent(runtime->m_flutter->eglDisplay, runtime->m_flutter->resourceContext, "Flutter resource");
    }

    void* CRuntime::onFlutterProcResolver(void* userData, const char* name) {
        (void)userData;
        return resolveGLProc(name);
    }

    bool CRuntime::onFlutterResize(void* userData, size_t widthPx, size_t heightPx) {
        (void)userData;
        (void)widthPx;
        (void)heightPx;
        return true;
    }

    void CRuntime::onFlutterBounds(void* userData, size_t* widthPx, size_t* heightPx) {
        auto*    runtime = sc<CRuntime*>(userData);
        Vector2D size{1, 1};
        if (runtime) {
            std::lock_guard<std::mutex> lock(runtime->m_renderTargetMutex);
            if (const auto target = runtime->currentRenderTargetSnapshotLocked())
                size = target->size;
        }

        if (widthPx)
            *widthPx = sc<size_t>(std::max(1.0, size.x));
        if (heightPx)
            *heightPx = sc<size_t>(std::max(1.0, size.y));
    }

    double CRuntime::onFlutterDpiScale(void* userData) {
        auto*  runtime = sc<CRuntime*>(userData);
        double scale   = 1.0;
        if (runtime) {
            std::lock_guard<std::mutex> lock(runtime->m_renderTargetMutex);
            if (const auto target = runtime->currentRenderTargetSnapshotLocked())
                scale = target->scale;
        }
        return scale > 0.0 ? scale : 1.0;
    }

    int32_t CRuntime::onFlutterFrameRate(void* userData) {
        auto*  runtime     = sc<CRuntime*>(userData);
        double refreshRate = 60.0;
        if (runtime) {
            std::lock_guard<std::mutex> lock(runtime->m_renderTargetMutex);
            if (const auto target = runtime->currentRenderTargetSnapshotLocked())
                refreshRate = target->refreshRate;
        }
        return sc<int32_t>(std::lround(std::max(1.0, refreshRate) * 1000.0));
    }

    uint16_t CRuntime::onFlutterSurfaceTransform(void* userData) {
        auto* runtime = sc<CRuntime*>(userData);
        return runtime ? runtime->m_options.flutterOutputTransform : 0;
    }

    bool CRuntime::onFlutterRunsTaskOnCurrentThread(void* userData) {
        auto* runtime = sc<CRuntime*>(userData);
        return runtime && std::this_thread::get_id() == runtime->m_hyprThreadId;
    }

    void CRuntime::onFlutterPostTask(void* userData, DenialTask task, uint64_t targetTimeNanos) {
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime)
            return;

        bool postDispatch = false;
        {
            std::lock_guard<std::mutex> lock(runtime->m_flutterTaskMutex);
            runtime->m_flutterTasks.push(SFlutterTask{
                .task            = task,
                .targetTimeNanos = targetTimeNanos,
                .order           = ++runtime->m_nextFlutterTaskOrder,
            });
            if (!runtime->m_flutterTaskDispatchPending && runtime->m_mainLoopSignal) {
                runtime->m_flutterTaskDispatchPending = true;
                postDispatch                          = true;
            }
        }
        if (postDispatch && !runtime->requestMainLoop(MAIN_LOOP_FLUTTER_TASK)) {
            std::lock_guard<std::mutex> lock(runtime->m_flutterTaskMutex);
            runtime->m_flutterTaskDispatchPending = false;
        }
    }

    void CRuntime::onFlutterVsyncRequest(void* userData, intptr_t baton) {
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime)
            return;

        {
            std::lock_guard<std::mutex> lock(runtime->m_vsyncMutex);
            runtime->m_pendingVsyncBatons.emplace_back(baton);
        }

        // A new AwaitVSync request is also Flutter's proof that the preceding
        // UI transaction has finished scheduling whatever raster work it will
        // have. Queue a sentinel behind that work. If the granted transaction
        // produced no raster task at all, the sentinel supplies the otherwise
        // missing REQUESTED -> IDLE transition; if raster work exists, it runs
        // after that work and the normal present path has already sealed it.
        if (runtime->m_flutterProducerState.load(std::memory_order_acquire) == eFlutterProducerState::REQUESTED)
            runtime->queueFlutterRasterSentinel();

        // AwaitVSync is producer demand. Wake the fixed-refresh ticker once;
        // its physical completion timestamps the baton. With no further
        // demand, the compositor remains idle.
        runtime->requestMainLoop(MAIN_LOOP_OUTPUT_FRAME);
    }

} // namespace Denial
