#pragma once

#include "BridgeAPI.hpp"
#include "RuntimeOutputState.hpp"
#include "Wire.hpp"
#include "../src/defines.hpp"
#include "../src/denial/FrameSink.hpp"
#include "../src/denial/InputRouter.hpp"
#include "../src/denial/ScreenCopy.hpp"
#include "../src/denial/SurfaceRegistry.hpp"

#include "flutter/denial_c_api.h"

#include <array>
#include <atomic>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <queue>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

class IKeyboard;
struct SHyprCtlCommand;

class CEventLoopTimer;
class CEventLoopAsyncSignal;

namespace Aquamarine {
    class CSwapchain;
}

namespace Denial {

    class CAudioController;
    class CAuthenticationController;
    class CBrightnessController;
    class CNotificationServer;
    struct SAuthenticationEvent;
    struct SAudioStream;
    struct SNotificationEvent;

    struct SFlutterRenderTarget {
        MONITORID monitorId = -1;
        Vector2D  size;
        Vector2D  logicalSize;
        Vector2D  globalOrigin;
        double    scale       = 1.0;
        double    refreshRate = 60.0;
    };

    struct SRuntimeOptions {
        std::string dartBundlePath;
        std::string flutterMonitor;
        std::string systemBarMonitor;
        std::string systemBarSide          = "left";
        bool        directKmsRendering     = false;
        bool        disableDamageTracking  = false;
        bool        forceBlockingSceneCopy = false;
        uint16_t    flutterOutputTransform = 5;
    };

    class CRuntime : public IFrameSink, public ISurfaceFrameConsumer, public IBufferImportPolicy, public IInputRouter, public IScreenCopyFrameProvider {
      public:
        explicit CRuntime(SRuntimeOptions options = {});
        ~CRuntime();

        bool initializeBeforeHyprlandLoop();
        void shutdown();

        bool initialized() const;

        // IFrameSink
        bool claimsMonitor(PHLMONITOR monitor) override;
        void renderMonitor(PHLMONITOR monitor) override;

        // ISurfaceFrameConsumer
        void onSurfaceFrame(SSurfaceFrameRef frame) override;
        void onSurfaceFrameCallbackDemand() override;
        void onWindowMapped(TWindowId windowId) override;
        void onSurfaceTreeChanged(TWindowId windowId) override;
        void onWindowStateChanged(TWindowId windowId) override;
        void onWindowGeometryChanged(TWindowId windowId, const Vector2D& position, const Vector2D& size) override;
        void onSurfaceGone(TSurfaceId surfaceId, TWindowId windowId) override;
        void onWindowGone(TWindowId windowId, const std::vector<TSurfaceId>& surfaceIds) override;

        // IBufferImportPolicy
        bool canImportClientBuffer(const Aquamarine::SDMABUFAttrs& attrs) override;
        bool canSampleAsFlutterTexture(const Aquamarine::SDMABUFAttrs& attrs) override;

        // IInputRouter
        bool hitTest(MONITORID monitorId, const Vector2D& outputLogical, SInputHit& hit) override;
        bool sendFlutterTouchDown(uint32_t timeMs, int32_t touchId, MONITORID monitorId, const Vector2D& outputLogical) override;
        bool sendFlutterTouchMotion(uint32_t timeMs, int32_t touchId, MONITORID monitorId, const Vector2D& outputLogical) override;
        bool sendFlutterTouchUp(uint32_t timeMs, int32_t touchId) override;
        bool sendFlutterTouchCancel() override;
        bool sendFlutterPointerMove(MONITORID monitorId, const Vector2D& outputLogical) override;
        bool sendFlutterPointerDown(MONITORID monitorId, const Vector2D& outputLogical, EFlutterPointerButton button) override;
        bool sendFlutterPointerUp(MONITORID monitorId, const Vector2D& outputLogical, EFlutterPointerButton button) override;
        bool sendFlutterPointerLeave() override;
        bool sendFlutterPointerScroll(MONITORID monitorId, const Vector2D& outputLogical, const Vector2D& delta) override;
        bool flutterKeyboardCapture() const override;
        bool sendFlutterKeyboardKey(const SFlutterKeyboardEvent& event) override;
        bool sendFlutterKeyboardModifiers(const SFlutterKeyboardModifiers& modifiers) override;
        bool sendFlutterKeyboardKeymap(std::string_view keymap) override;
        void notifyClientWindowActivated(TWindowId windowId) override;
        void notifyClientWindowPlacement(PHLWINDOW window, EClientWindowPlacementPhase phase, EClientWindowPlacementChange change) override;
        void notifyCursorShape(const std::string& shape) override;
        void notifyCursorPosition(MONITORID monitorId, const Vector2D& outputLogical) override;
        void notifyDragIconSurface(SP<CWLSurfaceResource> surface) override;
        bool secureSessionLocked() const override;
        bool shellExclusiveMode() const override;
        bool windowGeometryLocked(TWindowId windowId) override;
        bool dispatchShortcutAction(const std::string& action, std::string& error) override;

        // IScreenCopyFrameProvider
        bool renderLatestOutputFrame(PHLMONITOR monitor, const CBox& captureBox, bool overlayCursor) override;

      private:
        struct SFlutterRuntime;
        using TImportedBufferId  = uint64_t;
        using eOutputBufferState = RuntimeOutputState::eBufferState;
        using eOutputBufferEvent = RuntimeOutputState::eBufferEvent;

        struct SExternalTextureCookie {
            CRuntime*  runtime   = nullptr;
            TSurfaceId surfaceId = 0;
        };

        struct SImportedBufferImage {
            TImportedBufferId     bufferId  = 0;
            const IHLBuffer*      sourceKey = nullptr;
            SP<IHLBuffer>         sourceBuffer;
            CHyprSignalListener   destroy;
            std::shared_ptr<void> eglImageLifetime;
            void*                 eglImage        = nullptr;
            uint32_t              width           = 0;
            uint32_t              height          = 0;
            bool                  sourceDestroyed = false;
        };

        // Hyprutils::Memory::CSharedPointer is deliberately single-threaded.
        // Keep the CHLBufferReference itself on the compositor thread and let
        // Flutter's raster thread copy only this std::shared_ptr control block.
        // Sample holds are always handed back to the compositor thread before
        // their final release, so the wrapped CHLBufferReference also dies
        // there and wl_buffer.release never escapes the Wayland thread.
        using TImportedBufferHold = std::shared_ptr<CHLBufferReference>;

        struct SImportedFrameHold {
            TImportedBufferHold   buffer;
            std::shared_ptr<void> eglImageLifetime;
        };

        enum class eExternalTextureKind : uint8_t {
            NONE,
            EGL_IMAGE,
            PIXEL_BUFFER,
        };

        enum class eFlutterProducerState : uint8_t {
            IDLE,
            REQUESTED,
            RASTERIZING,
            PREPARING,
        };

        struct SQueuedImportedFrame {
            TImportedBufferId   bufferId           = 0;
            uint64_t            generation         = 0;
            uint64_t            acceptedAtUs       = 0;
            TSurfaceId          parentSurfaceId    = 0;
            TSurfaceId          popupRootSurfaceId = 0;
            TImportedBufferHold buffer;
            uint32_t            width               = 0;
            uint32_t            height              = 0;
            uint32_t            transform           = 0;
            uint32_t            scale120            = 120;
            int32_t             stackingOrder       = 0;
            double              surfaceX            = 0.0;
            double              surfaceY            = 0.0;
            double              surfaceWidth        = 0.0;
            double              surfaceHeight       = 0.0;
            double              textureSourceX      = 0.0;
            double              textureSourceY      = 0.0;
            double              textureSourceWidth  = 0.0;
            double              textureSourceHeight = 0.0;
            ESurfaceLayerRole   surfaceRole         = ESurfaceLayerRole::Root;
        };

        struct SQueuedPixelFrame {
            uint64_t                                    generation         = 0;
            uint64_t                                    acceptedAtUs       = 0;
            TSurfaceId                                  parentSurfaceId    = 0;
            TSurfaceId                                  popupRootSurfaceId = 0;
            std::shared_ptr<const std::vector<uint8_t>> pixels;
            uint32_t                                    width               = 0;
            uint32_t                                    height              = 0;
            uint32_t                                    transform           = 0;
            uint32_t                                    scale120            = 120;
            int32_t                                     stackingOrder       = 0;
            double                                      surfaceX            = 0.0;
            double                                      surfaceY            = 0.0;
            double                                      surfaceWidth        = 0.0;
            double                                      surfaceHeight       = 0.0;
            double                                      textureSourceX      = 0.0;
            double                                      textureSourceY      = 0.0;
            double                                      textureSourceWidth  = 0.0;
            double                                      textureSourceHeight = 0.0;
            ESurfaceLayerRole                           surfaceRole         = ESurfaceLayerRole::Root;
        };

        struct SSurfaceTextureObject {
            TSurfaceId                                                  surfaceId              = 0;
            TSurfaceId                                                  parentSurfaceId        = 0;
            TSurfaceId                                                  popupRootSurfaceId     = 0;
            TWindowId                                                   windowId               = 0;
            int64_t                                                     textureId              = -1;
            eExternalTextureKind                                        textureKind            = eExternalTextureKind::NONE;
            TImportedBufferId                                           currentBufferId        = 0;
            TImportedBufferId                                           nextBufferId           = 1;
            uint64_t                                                    currentGeneration      = 0;
            uint64_t                                                    lastSampledGeneration  = 0;
            uint64_t                                                    lastAcceptedFrameUs    = 0;
            uint64_t                                                    lastAcceptedOutputTick = 0;
            std::unique_ptr<SExternalTextureCookie>                     cookie;
            std::unordered_map<const IHLBuffer*, TImportedBufferId>     bufferIdsBySource;
            std::unordered_map<TImportedBufferId, SImportedBufferImage> images;
            std::deque<SQueuedImportedFrame>                            pendingFrames;
            std::deque<SQueuedPixelFrame>                               pendingPixelFrames;
            TImportedBufferHold                                         currentBufferHold;
            std::shared_ptr<const std::vector<uint8_t>>                 currentPixelBuffer;
            uint32_t                                                    currentPixelWidth   = 0;
            uint32_t                                                    currentPixelHeight  = 0;
            uint32_t                                                    width               = 0;
            uint32_t                                                    height              = 0;
            uint32_t                                                    transform           = 0;
            uint32_t                                                    scale120            = 120;
            int32_t                                                     stackingOrder       = 0;
            double                                                      surfaceX            = 0.0;
            double                                                      surfaceY            = 0.0;
            double                                                      surfaceWidth        = 0.0;
            double                                                      surfaceHeight       = 0.0;
            double                                                      textureSourceX      = 0.0;
            double                                                      textureSourceY      = 0.0;
            double                                                      textureSourceWidth  = 0.0;
            double                                                      textureSourceHeight = 0.0;
            std::string                                                 title;
            std::string                                                 appId;
            PHLWINDOWREF                                                window;
            WP<CWLSurfaceResource>                                      surface;
            bool                                                        rootSurface               = false;
            bool                                                        dragIcon                  = false;
            ESurfaceLayerRole                                           surfaceRole               = ESurfaceLayerRole::Root;
            bool                                                        announcedToDart           = false;
            bool                                                        notificationArmed         = false;
            bool                                                        closing                   = false;
            bool                                                        resizeHandoffComplete     = false;
            double                                                      resizeTargetWidth         = 0.0;
            double                                                      resizeTargetHeight        = 0.0;
            double                                                      resizeSourceWidth         = 0.0;
            double                                                      resizeSourceHeight        = 0.0;
            uint64_t                                                    resizeHandoffDeadlineUs   = 0;
            uint64_t                                                    resizeCandidateSinceUs    = 0;
            uint64_t                                                    resizeCandidateGeneration = 0;
            uint64_t                                                    resizeHandoffWakeUs       = 0;
            bool                                                        hasStatusColor            = false;
            uint32_t                                                    statusColorArgb           = 0xff0f1115;
        };

        struct SClosingTextureLease {
            TWindowId               windowId = 0;
            std::vector<TSurfaceId> surfaceIds;
            size_t                  estimatedBytes = 0;
            uint64_t                deadlineUs     = 0;
        };

        struct SOutputBufferTarget {
            SP<Aquamarine::IBuffer>  buffer;
            Aquamarine::SDMABUFAttrs dmabuf;
            void*                    eglImage                 = nullptr;
            uint32_t                 presentationTexture      = 0;
            uint32_t                 presentationRenderbuffer = 0;
            uint32_t                 presentationFramebuffer  = 0;
            uint32_t                 directRenderTexture      = 0;
            uint32_t                 directRenderFramebuffer  = 0;
            Vector2D                 size;
            CBox                     scanoutSource;
            uint64_t                 sceneGeneration             = 0;
            eOutputBufferState       state                       = eOutputBufferState::FREE;
            bool                     sharedAtlasView             = false;
            bool                     presentationImportAttempted = false;
        };

        struct SSharedAtlasTarget {
            SOutputBufferTarget                                                 renderTarget;
            std::unordered_map<MONITORID, std::unique_ptr<SOutputBufferTarget>> outputTargets;
            uint64_t                                                            sceneGeneration = 0;
        };

        struct SOutputPulse {
            MONITORID monitorId         = -1;
            uint64_t  sequence          = 0;
            uint64_t  frameStartNanos   = 0;
            uint64_t  intervalNanos     = 0;
            uint32_t  presentationFlags = 0;
        };

        struct SDeferredDirectRenderResources {
            void*    eglImage    = nullptr;
            uint32_t texture     = 0;
            uint32_t framebuffer = 0;
        };

        struct SSceneFramebuffer {
            uint32_t framebuffer             = 0;
            uint32_t presentationFramebuffer = 0;
            uint32_t texture                 = 0;
            Vector2D size;
            bool     needsFullRepaint = true;
        };

        struct SOutputFrame {
            MONITORID                                       monitorId       = -1;
            SOutputBufferTarget*                            target          = nullptr;
            SSharedAtlasTarget*                             sharedAtlas     = nullptr;
            SSceneFramebuffer*                              scene           = nullptr;
            uint64_t                                        sequence        = 0;
            uint64_t                                        sceneGeneration = 0;
            CRegion                                         damage;
            std::shared_ptr<Hyprutils::OS::CFileDescriptor> renderCompletionFd;
            std::shared_ptr<Hyprutils::OS::CFileDescriptor> scanoutCompletionFd;
            std::unordered_map<TSurfaceId, uint64_t>        sampledGenerations;
            std::vector<SImportedFrameHold>                 sampledBufferHolds;
            bool                                            repeated = false;
            bool                                            black    = false;
        };

        struct SSceneDamageEntry {
            uint64_t generation = 0;
            CRegion  damage;
        };

        enum class eSceneSubmitState : uint8_t {
            FAILED,
            IN_FLIGHT,
            SUCCEEDED,
        };

        enum class eDirectTargetState : uint8_t {
            IDLE,
            ACQUIRING,
            READY,
            FAILED,
        };

        enum eMainLoopRequest : uint32_t {
            MAIN_LOOP_SUBMIT_SCENE          = 1U << 0,
            MAIN_LOOP_OUTPUT_FRAME          = 1U << 1,
            MAIN_LOOP_FLUTTER_TASK          = 1U << 2,
            MAIN_LOOP_PREPARE_DIRECT_TARGET = 1U << 3,
            MAIN_LOOP_CANCEL_DIRECT_TARGET  = 1U << 4,
            MAIN_LOOP_TEXTURE_MARK          = 1U << 5,
            MAIN_LOOP_PREPARE_ATLAS_TARGET  = 1U << 6,
            MAIN_LOOP_CANCEL_ATLAS_TARGET   = 1U << 7,
        };

        struct SFlutterTask {
            DenialTask task            = {};
            uint64_t   targetTimeNanos = 0;
            uint64_t   order           = 0;

            struct Compare {
                bool operator()(const SFlutterTask& lhs, const SFlutterTask& rhs) const {
                    if (lhs.targetTimeNanos == rhs.targetTimeNanos)
                        return lhs.order > rhs.order;
                    return lhs.targetTimeNanos > rhs.targetTimeNanos;
                }
            };
        };

#if defined(DENIAL_ENABLE_DIAGNOSTICS)
        struct SImportedFrameTimingAccumulator {
            uint64_t bucketStartUs  = 0;
            uint64_t totalRenderUs  = 0;
            uint64_t peakRenderUs   = 0;
            uint64_t lastGeneration = 0;
            uint64_t sampleCount    = 0;
            uint64_t overBudget     = 0;
        };
#endif

        struct SScreenCopyFrame {
            MONITORID monitorId = -1;
            uint32_t  texture   = 0;
            Vector2D  size;
            CBox      sourceRect;
            uint64_t  sequence = 0;
        };

        struct SOutputViewport {
            MONITORID   monitorId = -1;
            std::string name;
            CBox        logicalRect;
            CBox        sourceRect;
            Vector2D    pixelSize;
            double      scale       = 1.0;
            double      refreshRate = 60.0;
        };

        struct SDisplayLayout {
            Vector2D                     globalOrigin;
            Vector2D                     logicalSize;
            Vector2D                     pixelSize;
            double                       engineScale        = 1.0;
            double                       maxRefreshRate     = 60.0;
            MONITORID                    tickerMonitorId    = -1;
            MONITORID                    systemBarMonitorId = -1;
            uint64_t                     epoch              = 0;
            std::vector<SOutputViewport> outputs;
        };

        struct SOutputPipeline {
            PHLMONITORREF                                       monitor;
            CHyprSignalListener                                 presented;
            CHyprSignalListener                                 modeChanged;
            std::optional<SOutputPulse>                         physicalPulse;
            std::optional<SOutputFrame>                         readyScanoutFrame;
            std::optional<SOutputFrame>                         submittedOutputFrame;
            std::optional<SOutputFrame>                         scanningOutputFrame;
            std::array<std::unique_ptr<SOutputBufferTarget>, 3> targets;
            SScreenCopyFrame                                    latestScreenCopyFrame;
            uint64_t                                            intervalNanos = 0;
#if defined(DENIAL_ENABLE_DIAGNOSTICS)
            uint64_t lastPresentedSceneGeneration = 0;
#endif
        };

        // Core lifecycle and main-loop coordination.
        bool        requestMainLoop(uint32_t requests);
        void        processMainLoopRequests();
        static void onMainLoopSignal(void* userData);

        // Flutter engine ownership, task scheduling, and host callbacks.
        bool            startFlutterEngine();
        bool            restartFlutterEngine(PHLMONITOR monitor);
        bool            restartFlutterEngineIfReady(PHLMONITOR monitor);
        void            processFlutterTasks();
        bool            queueFlutterRasterSentinel();
        void            finishFlutterRasterFrame();

        static bool     onFlutterMakeCurrent(void* userData);
        static bool     onFlutterClearCurrent(void* userData);
        static void     onFlutterRasterIdle(void* userData);
        static bool     onFlutterResourceMakeCurrent(void* userData);
        static void*    onFlutterProcResolver(void* userData, const char* name);
        static bool     onFlutterResize(void* userData, size_t widthPx, size_t heightPx);
        static void     onFlutterBounds(void* userData, size_t* widthPx, size_t* heightPx);
        static double   onFlutterDpiScale(void* userData);
        static int32_t  onFlutterFrameRate(void* userData);
        static uint16_t onFlutterSurfaceTransform(void* userData);
        static bool     onFlutterRunsTaskOnCurrentThread(void* userData);
        static void     onFlutterPostTask(void* userData, DenialTask task, uint64_t targetTimeNanos);
        static void     onFlutterVsyncRequest(void* userData, intptr_t baton);

        // Display topology, output scheduling, rendering, and presentation.
        void                                requestOutputFrame();
        bool                                refreshDisplayLayout(bool initial = false);
        bool                                initializeSharedAtlasScanout();
        void                                syncOutputPipelines();
        void                                markDisplayLayoutDirty();
        SOutputPipeline*                    outputPipeline(MONITORID monitorId);
        const SOutputPipeline*              outputPipeline(MONITORID monitorId) const;
        const SOutputViewport*              outputViewport(MONITORID monitorId) const;
        void                                updateOutputRenderTarget();
        std::optional<SOutputPulse>         consumePhysicalOutputReady(SOutputPipeline& pipeline, PHLMONITOR monitor);
        bool                                prepareBlackOutputFrame(SOutputPipeline& pipeline, PHLMONITOR monitor);
        void                                completePresentedOutputFrame(SOutputPipeline& pipeline, PHLMONITOR monitor);
        bool                                submitNextOutputFrame(SOutputPipeline& pipeline, PHLMONITOR monitor, bool allowRepeat);
        bool                                startNextFlutterFrame(SOutputPipeline& pipeline, PHLMONITOR monitor, const std::optional<SOutputPulse>& pulse = std::nullopt);
        bool                                deliverFlutterVsync(PHLMONITOR monitor, const std::optional<SOutputPulse>& pulse = std::nullopt);
        bool                                hasPendingFlutterVsync() const;
        uint64_t                            importedFrameIntervalUs() const;
        SFlutterRenderTarget                renderTargetFromDisplayLayout() const;
        std::optional<SFlutterRenderTarget> currentRenderTargetSnapshotLocked() const;
        uint32_t                            sendVisibleClientFrameCallbacks(PHLMONITOR monitor);
        void                                sendSurfaceFeedbackForSampledSurfaces(const std::unordered_map<TSurfaceId, uint64_t>& sampledGenerations, PHLMONITOR monitor);
        SOutputBufferTarget*                acquireOutputTarget(SOutputPipeline& pipeline, PHLMONITOR monitor);
        SSharedAtlasTarget*                 acquireSharedAtlasTarget();
        static void                         reportInvalidOutputTargetTransition(eOutputBufferState actual, eOutputBufferEvent event, std::string_view operation);
        void                                transitionOutputTarget(SOutputBufferTarget& target, eOutputBufferEvent event, std::string_view operation) {
            const auto& rule     = RuntimeOutputState::transitionFor(event);
            const auto  previous = target.state;
            if (previous != rule.from) [[unlikely]]
                reportInvalidOutputTargetTransition(previous, event, operation);

            // Preserve the historical unconditional destination assignment:
            // diagnostics must never convert a bookkeeping bug into a stall.
            target.state = rule.to;
        }
        SOutputBufferTarget*           sharedAtlasOutputTarget(SSharedAtlasTarget& atlas, MONITORID monitorId);
        const SOutputBufferTarget*     sharedAtlasOutputTarget(const SSharedAtlasTarget& atlas, MONITORID monitorId) const;
        uint32_t                       ensureCurrentSceneFramebuffer();
        bool                           ensureSceneFramebuffer(SSceneFramebuffer& scene, const Vector2D& size);
        bool                           ensureOutputTargetPresentationFramebuffer(SOutputBufferTarget& target);
        bool                           ensureOutputTargetDirectFramebuffer(SOutputBufferTarget& target);
        void                           prepareDirectOutputTarget();
        void                           cancelDirectOutputTarget();
        void                           prepareSharedAtlasTarget();
        void                           cancelSharedAtlasTarget();
        void                           disableSharedAtlasScanout(std::string_view reason);
        bool                           presentCurrentOutputFrame(uint32_t fboId, const CRegion* frameDamage = nullptr);
        bool                           presentDirectOutputFrame(uint32_t fboId, const CRegion* frameDamage = nullptr);
        bool                           presentSharedAtlasFrame(uint32_t fboId, const CRegion* frameDamage = nullptr);
        bool                           publishRenderedFrame(SOutputFrame frame);
        void                           prepareRenderedFrame(SOutputFrame frame);
        void                           finishSceneSubmit(bool result);
        CRegion                        outputDamageForTarget(const SOutputBufferTarget& target, const SOutputViewport& viewport, uint64_t sceneGeneration) const;
        void                           pruneSceneDamageHistory();
        void                           destroyDeferredDirectRenderResources();
        void                           destroySharedAtlasTargets();
        void                           destroyOutputTargets();
        void                           destroyOutputTarget(SOutputBufferTarget& target);
        void                           destroySceneFramebuffers();
        void                           destroySceneFramebuffer(SSceneFramebuffer& scene);
        void                           resetOutputGraphicsForEngineRestart();
        bool                           waitForPendingSceneRender();
        bool                           waitForPendingSceneCopy();
        void                           finishPendingSceneRender();
        void                           finishPendingSceneCopy();
        void                           fenceOrFinishSceneRender(SOutputFrame& frame, bool retainEglFence = true);
        Hyprutils::OS::CFileDescriptor fenceOrFinishSceneCopy();
        void                           releaseSampledBuffersAfterRender(SOutputFrame& frame);
        void                           releaseSampleHoldsOnMainThread(std::vector<SImportedFrameHold> holds);

#if defined(DENIAL_ENABLE_DIAGNOSTICS)
        void recordSharedAtlasAvailability(bool acquired);
#endif

        static CRegion  damageFromFlutterDamage(const DenialDamage& damage);
        static bool     onFlutterPresentWithInfo(void* userData, const DenialPresentInfo* info);
        static size_t   onFlutterExistingDamage(void* userData, intptr_t fboId, DenialRect* rects, size_t maxRects);
        static bool     onFlutterDirectPresentWithInfo(void* userData, const DenialPresentInfo* info);
        static size_t   onFlutterDirectExistingDamage(void* userData, intptr_t fboId, DenialRect* rects, size_t maxRects);
        static bool     onFlutterSharedAtlasPresentWithInfo(void* userData, const DenialPresentInfo* info);
        static size_t   onFlutterSharedAtlasExistingDamage(void* userData, intptr_t fboId, DenialRect* rects, size_t maxRects);
        static uint32_t onFlutterFBO(void* userData);
        static uint32_t onFlutterDirectFBO(void* userData);
        static uint32_t onFlutterSharedAtlasFBO(void* userData);

        // Client buffers, external textures, and sampled-generation lifetime.
        bool                  importSurfaceFrame(SSurfaceFrameRef frame);
        bool                  importPixelSurfaceFrame(SSurfaceFrameRef frame);
        uint32_t              advanceQueuedImportedFrames();
        void                  processPendingTextureMarks();
        void                  queueTextureMarksForGenerations(const std::unordered_map<TSurfaceId, uint64_t>& sampledGenerations);
        bool                  markExternalTextureFrameAvailable(TSurfaceId surfaceId, int64_t textureId);
        void                  destroySurfaceTexture(TSurfaceId surfaceId);
        void                  leaseWindowTextures(TWindowId windowId, const std::vector<TSurfaceId>& surfaceIds);
        void                  releaseClosingTextureLease(TWindowId windowId);
        void                  releaseClosingTextureLeaseForSurface(TSurfaceId surfaceId);
        void                  expireClosingTextureLeases();
        void                  armClosingTextureLeaseTimer();
        void                  enforceClosingTextureLeaseLimits();
        void                  wakeResizeTextureHandoffs();
        void                  armResizeTextureHandoffTimer();
        void                  destroyImportedBufferImage(TSurfaceId surfaceId, TImportedBufferId bufferId);
        void                  destroyImportedTextures();
        std::shared_ptr<void> adoptEGLImage(void* image);
        void                  destroyEGLImage(void* image);
        bool                  fillExternalTextureDescriptor(TSurfaceId surfaceId, DenialEGLImageDescriptor& descriptor);
        bool                  fillExternalPixelBufferDescriptor(TSurfaceId surfaceId, DenialPixelBufferDescriptor& descriptor);

#if defined(DENIAL_ENABLE_DIAGNOSTICS)
        void        recordImportedFrameTiming(TSurfaceId surfaceId, uint64_t generation, uint64_t renderDurationUs, uint64_t timestampUs);
        static void onImportedFrameTimingControlMessage(const char* channel, const uint8_t* message, size_t messageSize, void* userData);
#endif

        static const DenialEGLImageDescriptor*    onExternalTextureFrame(size_t width, size_t height, void* eglDisplay, void* eglContext, void* userData);
        static const DenialPixelBufferDescriptor* onExternalPixelBufferFrame(size_t width, size_t height, void* userData);

        // Immutable input-layout installation and coordinate conversion.
        bool     installInputLayoutSnapshot(std::shared_ptr<const std::vector<uint8_t>> message);
        Vector2D mapOutputLogicalToSceneLogical(MONITORID monitorId, const Vector2D& outputLogical) const;
        Vector2D mapFlutterShellInputToEnginePixels(MONITORID monitorId, const Vector2D& outputLogical);

        // Ordered platform-wire ingress and request dispatch.
        uint64_t    nextWireSequence();
        bool        sendWirePayload(flatbuffers::FlatBufferBuilder& builder, Wire::Payload payloadType, flatbuffers::Offset<void> payload, uint64_t requestId = 0);
        void        handleWireMessage(std::shared_ptr<const std::vector<uint8_t>> message);
        void        handleWindowRequestMessage(const Wire::WindowRequest& request, uint64_t requestId);
        static void onWireMessage(const char* channel, const uint8_t* message, size_t messageSize, void* userData);

        // Immutable shell snapshot construction and publication.
        bool notifyWindowObjectsChanged();
        bool publishDragIconState();
        bool sendWindowListResponse(uint64_t requestId);
        bool sendDisplayLayoutResponse(uint64_t requestId);

        // Compositor window observation and command execution.
        void      sendClientWindowPlacement(PHLWINDOW window, const CBox& geometry, EClientWindowPlacementPhase phase, EClientWindowPlacementChange change);
        bool      sendWindowAction(TWindowId windowId, std::string_view action);
        bool      sendShellAction(std::string_view action, std::optional<MONITORID> monitorId = std::nullopt);
        PHLWINDOW windowById(TWindowId windowId) const;
        bool      closeWindowById(TWindowId windowId);
        bool      focusWindowById(TWindowId windowId);
        bool      configureWindowById(TWindowId windowId, const CBox& geometry);

        // Native controls, notification actions, and virtual keyboard input.
        void        handleNotificationCommandMessage(const Wire::DesktopNotificationCommand& command);
        void        handleKeyboardMessage(const Wire::KeyboardCommand& command);
        void        handleHapticsMessage(const uint8_t* message, size_t messageSize);
        void        handleAudioMessage(const uint8_t* message, size_t messageSize);
        void        handleBrightnessMessage(const uint8_t* message, size_t messageSize);
        void        handleSystemCommandMessage(std::shared_ptr<const std::vector<uint8_t>> message);
        void        handleAuthenticationMessage(const uint8_t* message, size_t messageSize);
        void        publishAuthenticationEvent(const SAuthenticationEvent& event);
        void        applyAuthenticationState(bool locked);
        std::string handleAuthenticationCommand(eHyprCtlOutputFormat format, std::string request);
        void        publishAudioLevel(double level, uint32_t requestSerial);
        void        publishAudioStreams(const std::vector<SAudioStream>& streams);
        void        publishBrightnessLevel(MONITORID monitorId, double level);
        void        publishNotificationEvent(const SNotificationEvent& event);
        bool        ensureHapticsSocket();
        void        closeHapticsSocket();
        bool        sendHapticTap();
        bool        ensureOskKeyboard();
        bool        sendOskText(const std::string& text);
        bool        sendOskNamedKey(const std::string& key, bool ctrl);
        bool        sendOskKeycode(uint32_t keycode, uint32_t mods);

        static void onHapticsMessage(const char* channel, const uint8_t* message, size_t messageSize, void* userData);
        static void onAudioMessage(const char* channel, const uint8_t* message, size_t messageSize, void* userData);
        static void onBrightnessMessage(const char* channel, const uint8_t* message, size_t messageSize, void* userData);
        static void onSystemCommandMessage(const char* channel, const uint8_t* message, size_t messageSize, void* userData);
        static void onAuthenticationMessage(const char* channel, const uint8_t* message, size_t messageSize, void* userData);
        static void onWindowCloseCompleteMessage(const char* channel, const uint8_t* message, size_t messageSize, void* userData);

        // Data-member order is part of teardown correctness. Keep ownership
        // labels here, but do not cosmetically regroup fields across them.

        // Root configuration, registry, Flutter host, and frame coordination.
        SRuntimeOptions                                                 m_options;
        CSurfaceRegistry                                                m_surfaceRegistry;
        std::unique_ptr<SFlutterRuntime>                                m_flutter;
        std::optional<SFlutterRenderTarget>                             m_lastOutputRenderTarget;
        MONITORID                                                       m_lastOutputMonitorId = -1;
        mutable std::mutex                                              m_renderTargetMutex;
        std::atomic<eSceneSubmitState>                                  m_sceneSubmitState = eSceneSubmitState::FAILED;
        SP<CEventLoopAsyncSignal>                                       m_mainLoopSignal;
        std::atomic_uint32_t                                            m_mainLoopRequests = 0;
        std::optional<SOutputFrame>                                     m_readyOutputFrame;
        std::atomic_bool                                                m_readyOutputFramePublished = false;
        mutable std::mutex                                              m_vsyncMutex;
        std::vector<intptr_t>                                           m_pendingVsyncBatons;
        uint64_t                                                        m_outputIntervalNanos           = 0;
        std::atomic_uint64_t                                            m_outputTickSerial              = 0;
        bool                                                            m_tickerPulseRequired           = false;
        std::atomic<eFlutterProducerState>                              m_flutterProducerState          = eFlutterProducerState::IDLE;
        std::atomic_bool                                                m_flutterRasterSentinelPending  = false;
        std::atomic_bool                                                m_flutterRestartRequested       = false;
        std::atomic_bool                                                m_flutterForcedRestartRequested = false;
        bool                                                            m_directKmsActive               = false;
        std::atomic_bool                                                m_sharedAtlasScanoutCapable     = false;
        std::atomic_bool                                                m_sharedAtlasScanoutActive      = false;
        std::atomic_bool                                                m_sharedAtlasScanoutSuppressed  = false;
        std::mutex                                                      m_externalTextureMutex;
        std::mutex                                                      m_inputRegionMutex;
        SDisplayLayout                                                  m_displayLayout;
        std::string                                                     m_displayLayoutSignature;
        std::unordered_map<MONITORID, std::unique_ptr<SOutputPipeline>> m_outputPipelines;
        SOutputBufferTarget*                                            m_directOutputTarget    = nullptr;
        MONITORID                                                       m_directOutputMonitorId = -1;
        std::atomic<eDirectTargetState>                                 m_directTargetState     = eDirectTargetState::IDLE;
        std::vector<SDeferredDirectRenderResources>                     m_deferredDirectRenderResources;
        SP<Aquamarine::CSwapchain>                                      m_sharedAtlasSwapchain;
        std::vector<std::unique_ptr<SSharedAtlasTarget>>                m_sharedAtlasTargets;
        SSharedAtlasTarget*                                             m_sharedAtlasRenderTarget = nullptr;
        std::atomic<eDirectTargetState>                                 m_sharedAtlasTargetState  = eDirectTargetState::IDLE;
#if defined(DENIAL_ENABLE_DIAGNOSTICS)
        uint64_t m_sharedAtlasStatsStartedUs    = 0;
        uint64_t m_sharedAtlasStatsAcquired     = 0;
        uint64_t m_sharedAtlasStatsDeferred     = 0;
        uint64_t m_sharedAtlasMailboxSupersedes = 0;
#endif
        SSceneFramebuffer               m_sceneFramebuffer;
        std::vector<SSceneDamageEntry>  m_sceneDamageHistory;
        uint64_t                        m_sceneGeneration = 0;
        std::vector<SImportedFrameHold> m_deferredSampledBufferHolds;

        // Native controls and their process-lifetime resources.
        SP<IKeyboard>                              m_oskKeyboard;
        std::unique_ptr<CAuthenticationController> m_authenticationController;
        std::unique_ptr<CAudioController>          m_audioController;
        std::unique_ptr<CBrightnessController>     m_brightnessController;
        std::unique_ptr<CNotificationServer>       m_notificationServer;
        int                                        m_hapticsSocketFd            = -1;
        uint64_t                                   m_lastHapticTapUs            = 0;
        bool                                       m_hapticsSocketWarningLogged = false;
        // Flutter platform-task scheduling.
        SP<CEventLoopTimer>                                                                 m_flutterTaskTimer;
        SP<SHyprCtlCommand>                                                                 m_flutterReloadCommand;
        SP<SHyprCtlCommand>                                                                 m_lockCommand;
        mutable std::mutex                                                                  m_flutterTaskMutex;
        std::priority_queue<SFlutterTask, std::vector<SFlutterTask>, SFlutterTask::Compare> m_flutterTasks;
        bool                                                                                m_flutterTaskDispatchPending = false;
#if defined(DENIAL_ENABLE_DIAGNOSTICS)
        std::unordered_map<TSurfaceId, SImportedFrameTimingAccumulator> m_importedFrameTimings;
        std::atomic_bool                                                m_importedFrameTimingEnabled        = false;
        std::atomic_bool                                                m_importedFrameTimingResetRequested = false;
        std::atomic_uint64_t                                            m_importedFrameTimingBudgetUs       = 16667;
#endif
        // Imported surfaces and raster/main-thread lifetime handoff.
        std::thread::id                                                        m_hyprThreadId;
        uint64_t                                                               m_nextFlutterTaskOrder = 0;
        SP<CEventLoopTimer>                                                    m_closingTextureLeaseTimer;
        SP<CEventLoopTimer>                                                    m_resizeTextureHandoffTimer;
        std::unordered_map<TSurfaceId, std::unique_ptr<SSurfaceTextureObject>> m_externalTextures;
        std::unordered_map<TWindowId, SClosingTextureLease>                    m_closingTextureLeases;
        size_t                                                                 m_closingTextureLeaseBytes = 0;
        std::unordered_map<TSurfaceId, uint64_t>                               m_rasterSampledGenerations;
        std::vector<SImportedFrameHold>                                        m_rasterSampledBufferHolds;
        std::vector<SImportedFrameHold>                                        m_pendingSampleReleases;
        std::vector<std::pair<TSurfaceId, int64_t>>                            m_pendingTextureMarks;
        std::vector<SImportedFrameHold>                                        m_sampleReleaseScratch;
        std::vector<std::pair<TSurfaceId, int64_t>>                            m_textureMarkScratch;
        // Immutable input snapshot, shell mode, and wire bookkeeping.
        std::shared_ptr<const std::vector<uint8_t>> m_inputLayoutBuffer;
        std::atomic_bool                            m_flutterKeyboardCapture = false;
        std::atomic_bool                            m_flutterShellExclusive  = false;
        bool                                        m_appliedSessionLocked   = false;
        std::atomic_bool                            m_acceptTextureMarks     = false;
        CHyprSignalListener                         m_decorationPolicyReload;
        bool                                        m_initialized          = false;
        uint64_t                                    m_sceneSequence        = 0;
        std::atomic_uint64_t                        m_nextWireSequence     = 1;
        std::atomic_uint64_t                        m_rejectedWireMessages = 0;
        std::string                                 m_lastCursorShape;
        TSurfaceId                                  m_dragIconSurfaceId = 0;
    };

} // namespace Denial
