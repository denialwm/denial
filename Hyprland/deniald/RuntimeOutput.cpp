#include "Runtime.hpp"
#include "RuntimeEGL.hpp"
#include "RuntimeFlutterState.hpp"
#include "RuntimeInternal.hpp"

#include "../src/Compositor.hpp"
#include "../src/debug/log/Logger.hpp"
#include "../src/desktop/view/Window.hpp"
#include "../src/helpers/time/Time.hpp"
#include "../src/managers/eventLoop/EventLoopManager.hpp"
#include "../src/managers/input/InputManager.hpp"
#include "../src/managers/PointerManager.hpp"
#include "../src/render/OpenGL.hpp"
#include "../src/render/Renderer.hpp"

#include <aquamarine/allocator/Swapchain.hpp>
#include <aquamarine/backend/DRM.hpp>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#include <drm_fourcc.h>
#include <dlfcn.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <ranges>
#include <sstream>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

namespace Denial {

    using RuntimeInternal::makeFlutterContextCurrent;
    using RuntimeInternal::steadyUs;

    namespace {
        class CBorrowedScreenCopyTexture final : public Render::ITexture {
          public:
            CBorrowedScreenCopyTexture(uint32_t textureId, const Vector2D& size) {
                m_texID            = textureId;
                m_size             = size;
                m_type             = Render::TEXTURE_RGBA;
                m_opaque           = true;
                m_imageDescription = NColorManagement::DEFAULT_SRGB_IMAGE_DESCRIPTION;
            }

            void allocate(const Vector2D& size, uint32_t drmFormat = 0) override {
                (void)size;
                (void)drmFormat;
            }

            void update(uint32_t drmFormat, uint8_t* pixels, uint32_t stride, const CRegion& damage) override {
                (void)drmFormat;
                (void)pixels;
                (void)stride;
                (void)damage;
            }

            void bind() override {
                glBindTexture(GL_TEXTURE_2D, m_texID);
            }

            void unbind() override {
                glBindTexture(GL_TEXTURE_2D, 0);
            }

            void setTexParameter(GLenum pname, GLint param) override {
                glTexParameteri(GL_TEXTURE_2D, pname, param);
            }

            bool ok() override {
                return m_texID != 0;
            }

            bool isDMA() override {
                return false;
            }
        };

        // Keep one full desktop allocation for Flutter, then expose one
        // output-sized scanout view per monitor. dmabuf() deliberately returns
        // the complete atlas so KMS imports a normal full framebuffer; the
        // Aquamarine attachment selects this output's source origin.
        class CSharedAtlasBufferView final : public Aquamarine::IBuffer {
          public:
            CSharedAtlasBufferView(SP<Aquamarine::IBuffer> backing, Aquamarine::SDMABUFAttrs attrs, const Vector2D& outputSize, uint32_t sourceX, uint32_t sourceY) :
                m_backing(std::move(backing)), m_attrs(std::move(attrs)) {
                size   = outputSize;
                opaque = true;
                attachments.add(makeShared<Aquamarine::CDRMBufferScanoutSource>(sourceX, sourceY));
            }

            Aquamarine::eBufferCapability caps() override {
                return Aquamarine::BUFFER_CAPABILITY_NONE;
            }

            Aquamarine::eBufferType type() override {
                return Aquamarine::BUFFER_TYPE_DMABUF;
            }

            void update(const CRegion& damage) override {
                (void)damage;
            }

            bool isSynchronous() override {
                return false;
            }

            bool good() override {
                return m_backing && m_backing->good() && m_attrs.success;
            }

            Aquamarine::SDMABUFAttrs dmabuf() override {
                return m_attrs;
            }

          private:
            SP<Aquamarine::IBuffer>  m_backing;
            Aquamarine::SDMABUFAttrs m_attrs;
        };
    } // namespace

    void CRuntime::reportInvalidOutputTargetTransition(eOutputBufferState actual, eOutputBufferEvent event, std::string_view operation) {
        const auto& rule = RuntimeOutputState::transitionFor(event);
        Log::logger->log(Log::ERR, "Denial invalid output target transition during {}: event={} expected={} actual={} next={}", operation, RuntimeOutputState::nameOf(event),
                         RuntimeOutputState::nameOf(rule.from), RuntimeOutputState::nameOf(actual), RuntimeOutputState::nameOf(rule.to));
    }

    SFlutterRenderTarget CRuntime::renderTargetFromDisplayLayout() const {
        return SFlutterRenderTarget{
            .monitorId    = m_displayLayout.tickerMonitorId,
            .size         = m_displayLayout.pixelSize,
            .logicalSize  = m_displayLayout.logicalSize,
            .globalOrigin = m_displayLayout.globalOrigin,
            .scale        = m_displayLayout.engineScale,
            .refreshRate  = m_displayLayout.maxRefreshRate,
        };
    }

    bool CRuntime::claimsMonitor(PHLMONITOR monitor) {
        if (!monitor || !monitor->m_output || !monitor->m_enabled || monitor->m_isUnsafeFallback)
            return false;

        const auto* viewport = outputViewport(monitor->m_id);
        if (!viewport) {
            if (m_initialized)
                markDisplayLayoutDirty();
            return false;
        }

        const auto expectedPosition = m_displayLayout.globalOrigin + viewport->logicalRect.pos();
        if (expectedPosition != monitor->m_position || viewport->logicalRect.size() != monitor->m_size || viewport->pixelSize != monitor->m_pixelSize ||
            std::abs(viewport->scale - monitor->m_scale) > 0.0001) {
            markDisplayLayoutDirty();
        }
        return true;
    }

    void CRuntime::renderMonitor(PHLMONITOR monitor) {
        if (!monitor || !monitor->m_output)
            return;

        auto* pipeline = outputPipeline(monitor->m_id);
        if (!pipeline)
            return;

        monitor->m_forceFullFrames = 0;
        monitor->m_pendingFrame    = false;

        const bool ticker = monitor->m_id == m_displayLayout.tickerMonitorId;
        if (!monitor->m_output->pendingPageFlip() && restartFlutterEngineIfReady(monitor))
            return;

        if (const auto pulse = consumePhysicalOutputReady(*pipeline, monitor)) {
            if (ticker && pulse->intervalNanos > 0)
                m_outputIntervalNanos = pulse->intervalNanos;

            completePresentedOutputFrame(*pipeline, monitor);
            if (restartFlutterEngineIfReady(monitor))
                return;
            if (!pipeline->readyScanoutFrame && !pipeline->scanningOutputFrame && !prepareBlackOutputFrame(*pipeline, monitor)) {
                requestOutputFrame();
                return;
            }

            // A delivered client frame callback means the client is about to
            // produce the next transaction. Keep exactly one physical edge
            // queued so that work has a full refresh interval instead of
            // racing the KMS deadline before it can re-arm the output. If the
            // client does not request another callback, the lookahead pulse
            // completes without queuing a successor and the output idles.
            const auto clientCallbacks = sendVisibleClientFrameCallbacks(monitor);

            const bool tickerLookahead = ticker && m_tickerPulseRequired;
            if (submitNextOutputFrame(*pipeline, monitor, clientCallbacks > 0 || tickerLookahead) && tickerLookahead)
                m_tickerPulseRequired = false;

            if (ticker)
                startNextFlutterFrame(*pipeline, monitor, pulse);
            return;
        }

        if (monitor->m_output->pendingPageFlip())
            return;

        // Bootstrap and commit-failure recovery use the same transition as a
        // physical completion: prepare black if no owned scanout exists,
        // then submit it as an actual new buffer.
        if (!pipeline->readyScanoutFrame && !pipeline->scanningOutputFrame && !prepareBlackOutputFrame(*pipeline, monitor))
            return;

        // With a fixed-refresh output, an idle scanout has no presentation
        // event to timestamp a newly requested producer frame. In that one
        // case submit the current ticker buffer once. Its completion supplies
        // the real physical edge; it never self-repeats.
        const bool flutterReadyForEdge = ticker && hasPendingFlutterVsync() && m_flutterProducerState.load(std::memory_order_acquire) == eFlutterProducerState::IDLE;
        const bool tickerLookahead     = ticker && m_tickerPulseRequired;
        const bool edgeDemand          = flutterReadyForEdge || tickerLookahead || m_surfaceRegistry.hasFrameCallbacks(monitor);
        if (submitNextOutputFrame(*pipeline, monitor, edgeDemand) && tickerLookahead)
            m_tickerPulseRequired = false;
    }

    std::optional<SFlutterRenderTarget> CRuntime::currentRenderTargetSnapshotLocked() const {
        if (m_lastOutputRenderTarget)
            return m_lastOutputRenderTarget;

        return std::nullopt;
    }

    uint64_t CRuntime::importedFrameIntervalUs() const {
        if (m_outputIntervalNanos > 0)
            return std::max<uint64_t>(1, m_outputIntervalNanos / 1000);

        double refreshRate = 60.0;
        {
            std::lock_guard<std::mutex> lock(m_renderTargetMutex);
            if (m_lastOutputRenderTarget && m_lastOutputRenderTarget->refreshRate > 0)
                refreshRate = m_lastOutputRenderTarget->refreshRate;
        }

        return std::max<uint64_t>(1, sc<uint64_t>(std::llround(1000000.0 / refreshRate)));
    }

    uint32_t CRuntime::sendVisibleClientFrameCallbacks(PHLMONITOR monitor) {
        if (!monitor)
            return 0;

        // A frame callback paces the client; it is not an input or visibility
        // grant. Minimized/off-scene clients stay alive so video, audio and
        // live overview textures continue without entering an unpaced commit
        // loop while their Flutter placement is absent.
        return m_surfaceRegistry.sendFrameCallbacks(monitor);
    }

    bool CRuntime::hasPendingFlutterVsync() const {
        std::lock_guard<std::mutex> lock(m_vsyncMutex);
        return !m_pendingVsyncBatons.empty();
    }

    void CRuntime::requestOutputFrame() {
        if (!g_pCompositor)
            return;

        for (const auto& [monitorId, pipeline] : m_outputPipelines) {
            const auto monitor = pipeline ? pipeline->monitor.lock() : nullptr;
            if (monitor && monitor->m_enabled && monitor->m_output)
                g_pCompositor->scheduleFrameForMonitor(monitor, Aquamarine::IOutput::AQ_SCHEDULE_NEEDS_FRAME);
        }
    }

    CRuntime::SOutputPipeline* CRuntime::outputPipeline(MONITORID monitorId) {
        const auto it = m_outputPipelines.find(monitorId);
        return it == m_outputPipelines.end() ? nullptr : it->second.get();
    }

    const CRuntime::SOutputPipeline* CRuntime::outputPipeline(MONITORID monitorId) const {
        const auto it = m_outputPipelines.find(monitorId);
        return it == m_outputPipelines.end() ? nullptr : it->second.get();
    }

    const CRuntime::SOutputViewport* CRuntime::outputViewport(MONITORID monitorId) const {
        const auto it = std::ranges::find_if(m_displayLayout.outputs, [monitorId](const auto& output) { return output.monitorId == monitorId; });
        return it == m_displayLayout.outputs.end() ? nullptr : &*it;
    }

    CRuntime::SOutputBufferTarget* CRuntime::sharedAtlasOutputTarget(SSharedAtlasTarget& atlas, MONITORID monitorId) {
        const auto it = atlas.outputTargets.find(monitorId);
        return it == atlas.outputTargets.end() ? nullptr : it->second.get();
    }

    const CRuntime::SOutputBufferTarget* CRuntime::sharedAtlasOutputTarget(const SSharedAtlasTarget& atlas, MONITORID monitorId) const {
        const auto it = atlas.outputTargets.find(monitorId);
        return it == atlas.outputTargets.end() ? nullptr : it->second.get();
    }

    CRuntime::SSharedAtlasTarget* CRuntime::acquireSharedAtlasTarget() {
        for (const auto& atlas : m_sharedAtlasTargets) {
            if (!atlas || atlas->renderTarget.state != eOutputBufferState::FREE)
                continue;
            const bool outputInUse = std::ranges::any_of(atlas->outputTargets, [](const auto& entry) { return entry.second && entry.second->state != eOutputBufferState::FREE; });
            if (outputInUse)
                continue;

            transitionOutputTarget(atlas->renderTarget, eOutputBufferEvent::ACQUIRE_FOR_RENDER, "shared atlas acquisition");
            return atlas.get();
        }
        return nullptr;
    }

#if defined(DENIAL_ENABLE_DIAGNOSTICS)
    void CRuntime::recordSharedAtlasAvailability(bool acquired) {
        const auto now = steadyUs();
        if (m_sharedAtlasStatsStartedUs == 0)
            m_sharedAtlasStatsStartedUs = now;

        if (acquired)
            ++m_sharedAtlasStatsAcquired;
        else
            ++m_sharedAtlasStatsDeferred;

        constexpr uint64_t REPORT_INTERVAL_US = 1000000;
        const auto         elapsedUs          = now - m_sharedAtlasStatsStartedUs;
        if (elapsedUs < REPORT_INTERVAL_US)
            return;

        // Stay silent in the healthy steady state. A report only when the
        // producer was actually throttled gives us enough evidence to size
        // the pool without turning the frame loop into a logging benchmark.
        if (m_sharedAtlasStatsDeferred > 0) {
            Log::logger->log(Log::WARN, "Denial shared atlas back-pressure over {}us: acquired={} deferred={} pool={}", elapsedUs, m_sharedAtlasStatsAcquired,
                             m_sharedAtlasStatsDeferred, m_sharedAtlasTargets.size());
        }
        m_sharedAtlasStatsStartedUs = now;
        m_sharedAtlasStatsAcquired  = 0;
        m_sharedAtlasStatsDeferred  = 0;
    }
#endif

    bool CRuntime::initializeSharedAtlasScanout() {
        if (!g_pCompositor || m_displayLayout.outputs.size() < 2 || m_displayLayout.pixelSize.x < 1 || m_displayLayout.pixelSize.y < 1)
            return false;
        using AquamarineScanoutSourceProbe = bool (*)();
        const auto scanoutSourceProbe      = rc<AquamarineScanoutSourceProbe>(dlsym(RTLD_DEFAULT, "aquamarine_drm_buffer_scanout_source_v1"));
        if (!scanoutSourceProbe || !scanoutSourceProbe()) {
            Log::logger->log(Log::WARN, "Denial shared atlas scanout requires Aquamarine source-crop support; retaining scene-blit fallback");
            return false;
        }
        if (m_options.flutterOutputTransform != 5) {
            Log::logger->log(
                Log::WARN,
                "Denial shared atlas scanout requires the flip-y Flutter surface transform so atlas coordinates match KMS scanout memory; retaining scene-blit fallback");
            return false;
        }

        if (!m_sharedAtlasTargets.empty()) {
            if (!m_sharedAtlasScanoutCapable.load(std::memory_order_acquire))
                return false;
            const bool compatible = std::ranges::all_of(m_sharedAtlasTargets, [this](const auto& atlas) {
                if (!atlas || atlas->renderTarget.size != m_displayLayout.pixelSize || atlas->outputTargets.size() != m_displayLayout.outputs.size())
                    return false;

                const auto& atlasDmabuf = atlas->renderTarget.dmabuf;
                return atlasDmabuf.success && atlasDmabuf.planes == 1 && atlasDmabuf.strides[0] != 0 &&
                    std::ranges::all_of(m_displayLayout.outputs, [&atlas, &atlasDmabuf](const auto& viewport) {
                           const auto it = atlas->outputTargets.find(viewport.monitorId);
                           if (it == atlas->outputTargets.end() || !it->second || it->second->size != viewport.pixelSize)
                               return false;

                           const auto& rect     = viewport.sourceRect;
                           const bool  integral = std::abs(rect.x - std::round(rect.x)) < 0.001 && std::abs(rect.y - std::round(rect.y)) < 0.001 &&
                               std::abs(rect.w - std::round(rect.w)) < 0.001 && std::abs(rect.h - std::round(rect.h)) < 0.001;
                           const bool oneToOne = std::abs(rect.w - viewport.pixelSize.x) < 0.001 && std::abs(rect.h - viewport.pixelSize.y) < 0.001;
                           if (!integral || !oneToOne || rect.x < 0 || rect.y < 0 || rect.x + rect.w > atlasDmabuf.size.x || rect.y + rect.h > atlasDmabuf.size.y)
                               return false;

                           const auto& viewDmabuf = it->second->dmabuf;
                           const auto& source     = it->second->scanoutSource;
                           return viewDmabuf.success && viewDmabuf.size == atlasDmabuf.size && viewDmabuf.format == atlasDmabuf.format &&
                               viewDmabuf.modifier == atlasDmabuf.modifier && viewDmabuf.planes == atlasDmabuf.planes && viewDmabuf.offsets == atlasDmabuf.offsets &&
                               viewDmabuf.strides == atlasDmabuf.strides && std::abs(source.x - rect.x) < 0.001 && std::abs(source.y - rect.y) < 0.001 &&
                               std::abs(source.w - rect.w) < 0.001 && std::abs(source.h - rect.h) < 0.001;
                       });
            });
            if (compatible) {
                Log::logger->log(Log::INFO, "Denial reusing the validated shared atlas scanout pool across Flutter restart");
                return true;
            }

            Log::logger->log(Log::WARN, "Denial existing shared atlas pool does not match the new layout; retaining scene-blit fallback until old scanout buffers retire");
            return false;
        }

        struct SProbeOutput {
            const SOutputViewport*     viewport = nullptr;
            SP<Aquamarine::CDRMOutput> drmOutput;
        };

        std::vector<SProbeOutput>   outputs;
        SP<Aquamarine::CDRMBackend> drmBackend;
        outputs.reserve(m_displayLayout.outputs.size());

        for (const auto& viewport : m_displayLayout.outputs) {
            const auto monitor = g_pCompositor->getMonitorFromID(viewport.monitorId);
            if (!monitor || !monitor->m_output) {
                Log::logger->log(Log::WARN, "Denial shared atlas scanout probe unavailable: output {} disappeared; retaining scene-blit fallback", viewport.name);
                return false;
            }
            if (monitor->m_transform != WL_OUTPUT_TRANSFORM_NORMAL || monitor->m_enabled10bit) {
                Log::logger->log(
                    Log::WARN,
                    "Denial shared atlas scanout does not alter per-output transform or 10-bit scanout state (output={} transform={} 10bit={}); retaining scene-blit fallback",
                    viewport.name, sc<int>(monitor->m_transform), monitor->m_enabled10bit);
                return false;
            }

            const auto output  = dynamicPointerCast<Aquamarine::CDRMOutput>(monitor->m_output);
            const auto backend = output ? dynamicPointerCast<Aquamarine::CDRMBackend>(output->getBackend()) : nullptr;
            if (!output || !backend || backend->drmFD() < 0) {
                Log::logger->log(Log::WARN, "Denial shared atlas scanout probe unavailable: output {} is not on an atomic DRM backend; retaining scene-blit fallback",
                                 viewport.name);
                return false;
            }
            if (backend->getPrimary()) {
                Log::logger->log(Log::WARN, "Denial shared atlas scanout cannot preserve source crops through Aquamarine's multi-GPU blit for {}; retaining scene-blit fallback",
                                 viewport.name);
                return false;
            }

            if (drmBackend && drmBackend.get() != backend.get()) {
                Log::logger->log(Log::WARN, "Denial shared atlas scanout probe unavailable: outputs span DRM devices; retaining scene-blit fallback");
                return false;
            }

            drmBackend = backend;
            outputs.push_back(SProbeOutput{.viewport = &viewport, .drmOutput = output});
        }

        struct SDrmProperty {
            uint32_t id    = 0;
            uint64_t value = 0;
        };

        const auto objectProperty = [](int fd, uint32_t object, uint32_t objectType, std::string_view name) -> std::optional<SDrmProperty> {
            auto* properties = drmModeObjectGetProperties(fd, object, objectType);
            if (!properties)
                return std::nullopt;

            std::optional<SDrmProperty> result;
            for (uint32_t i = 0; i < properties->count_props; ++i) {
                auto* property = drmModeGetProperty(fd, properties->props[i]);
                if (!property)
                    continue;
                if (name == property->name)
                    result = SDrmProperty{.id = property->prop_id, .value = properties->prop_values[i]};
                drmModeFreeProperty(property);
                if (result)
                    break;
            }

            drmModeFreeObjectProperties(properties);
            return result;
        };

        struct SPrimaryPlane {
            uint32_t     id = 0;
            SDrmProperty fbId;
            SDrmProperty crtcId;
            SDrmProperty srcX;
            SDrmProperty srcY;
            SDrmProperty srcW;
            SDrmProperty srcH;
            SDrmProperty crtcX;
            SDrmProperty crtcY;
            SDrmProperty crtcW;
            SDrmProperty crtcH;
        };

        const auto activePrimaryPlane = [&objectProperty](int fd, uint32_t crtcId, uint32_t crtcIndex) -> std::optional<SPrimaryPlane> {
            if (crtcIndex >= 32)
                return std::nullopt;

            auto* planeResources = drmModeGetPlaneResources(fd);
            if (!planeResources)
                return std::nullopt;

            std::optional<SPrimaryPlane> result;
            for (uint32_t i = 0; i < planeResources->count_planes && !result; ++i) {
                auto* plane = drmModeGetPlane(fd, planeResources->planes[i]);
                if (!plane)
                    continue;

                const bool canDriveCrtc = (plane->possible_crtcs & (1U << crtcIndex)) != 0;
                if (!canDriveCrtc) {
                    drmModeFreePlane(plane);
                    continue;
                }

                const auto type        = objectProperty(fd, plane->plane_id, DRM_MODE_OBJECT_PLANE, "type");
                const auto planeCrtcId = objectProperty(fd, plane->plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_ID");
                if (!type || type->value != DRM_PLANE_TYPE_PRIMARY || !planeCrtcId || planeCrtcId->value != crtcId) {
                    drmModeFreePlane(plane);
                    continue;
                }

                const auto fbId      = objectProperty(fd, plane->plane_id, DRM_MODE_OBJECT_PLANE, "FB_ID");
                const auto srcX      = objectProperty(fd, plane->plane_id, DRM_MODE_OBJECT_PLANE, "SRC_X");
                const auto srcY      = objectProperty(fd, plane->plane_id, DRM_MODE_OBJECT_PLANE, "SRC_Y");
                const auto srcW      = objectProperty(fd, plane->plane_id, DRM_MODE_OBJECT_PLANE, "SRC_W");
                const auto srcH      = objectProperty(fd, plane->plane_id, DRM_MODE_OBJECT_PLANE, "SRC_H");
                const auto crtcX     = objectProperty(fd, plane->plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_X");
                const auto crtcY     = objectProperty(fd, plane->plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_Y");
                const auto crtcW     = objectProperty(fd, plane->plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_W");
                const auto crtcH     = objectProperty(fd, plane->plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_H");
                const auto inFenceFd = objectProperty(fd, plane->plane_id, DRM_MODE_OBJECT_PLANE, "IN_FENCE_FD");
                if (fbId && srcX && srcY && srcW && srcH && crtcX && crtcY && crtcW && crtcH && inFenceFd) {
                    result = SPrimaryPlane{
                        .id     = plane->plane_id,
                        .fbId   = *fbId,
                        .crtcId = *planeCrtcId,
                        .srcX   = *srcX,
                        .srcY   = *srcY,
                        .srcW   = *srcW,
                        .srcH   = *srcH,
                        .crtcX  = *crtcX,
                        .crtcY  = *crtcY,
                        .crtcW  = *crtcW,
                        .crtcH  = *crtcH,
                    };
                }

                drmModeFreePlane(plane);
            }

            drmModeFreePlaneResources(planeResources);
            return result;
        };

        struct SAtomicOutput {
            const SOutputViewport* viewport = nullptr;
            uint32_t               crtcId   = 0;
            SPrimaryPlane          plane;
        };

        const int                                                    fd = drmBackend->drmFD();
        std::unique_ptr<drmModeRes, decltype(&drmModeFreeResources)> resources(drmModeGetResources(fd), &drmModeFreeResources);
        if (!resources) {
            Log::logger->log(Log::WARN, "Denial shared atlas scanout probe could not read DRM resources: {}; retaining scene-blit fallback", std::strerror(errno));
            return false;
        }

        std::vector<SAtomicOutput>   atomicOutputs;
        std::unordered_set<uint32_t> usedPlanes;
        atomicOutputs.reserve(outputs.size());
        for (const auto& output : outputs) {
            const auto connectorId = output.drmOutput->getConnectorID();
            const auto crtc        = connectorId > 0 ? objectProperty(fd, sc<uint32_t>(connectorId), DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID") : std::nullopt;
            if (!crtc || crtc->value == 0 || crtc->value > std::numeric_limits<uint32_t>::max()) {
                Log::logger->log(Log::WARN, "Denial shared atlas scanout probe found no active CRTC for {}; retaining scene-blit fallback", output.viewport->name);
                return false;
            }

            uint32_t crtcIndex = resources->count_crtcs;
            for (int i = 0; i < resources->count_crtcs; ++i) {
                if (resources->crtcs[i] == crtc->value) {
                    crtcIndex = sc<uint32_t>(i);
                    break;
                }
            }
            if (crtcIndex == sc<uint32_t>(resources->count_crtcs)) {
                Log::logger->log(Log::WARN, "Denial shared atlas scanout probe could not map the CRTC for {}; retaining scene-blit fallback", output.viewport->name);
                return false;
            }

            auto primary = activePrimaryPlane(fd, sc<uint32_t>(crtc->value), crtcIndex);
            if (!primary || !usedPlanes.emplace(primary->id).second) {
                Log::logger->log(Log::WARN, "Denial shared atlas scanout probe found no unique explicit-sync primary plane for {}; retaining scene-blit fallback",
                                 output.viewport->name);
                return false;
            }

            atomicOutputs.push_back(SAtomicOutput{.viewport = output.viewport, .crtcId = sc<uint32_t>(crtc->value), .plane = *primary});
        }

        const auto allocator = drmBackend->preferredAllocator();
        const auto swapchain = allocator ? Aquamarine::CSwapchain::create(allocator, drmBackend) : nullptr;
        // Each independently clocked output can retain a scanning and a
        // pending atlas generation while Flutter needs one unowned target for
        // the next raster. A three-buffer desktop-wide pool is therefore not
        // equivalent to the usual per-output triple buffering: with 200 Hz +
        // 180 Hz it periodically couples the fast output to the slow one.
        const size_t poolLength = outputs.size() * 2 + 1;
        if (!swapchain ||
            !swapchain->reconfigure(Aquamarine::SSwapchainOptions{
                .length  = poolLength,
                .size    = m_displayLayout.pixelSize,
                .format  = DRM_FORMAT_XRGB8888,
                .scanout = true,
                .cursor  = false,
                // Keep the allocator's preferred scanout modifier (including
                // DCC/tiled layouts). Every output imports this complete BO
                // and selects its own source rectangle on the primary plane.
                .multigpu      = false,
                .scanoutOutput = outputs.front().drmOutput,
            })) {
            Log::logger->log(Log::WARN, "Denial shared atlas scanout could not allocate a {}-buffer scanout pool of size {}; retaining scene-blit fallback", poolLength,
                             m_displayLayout.pixelSize);
            return false;
        }

        std::vector<std::unique_ptr<SSharedAtlasTarget>> atlasTargets;
        std::unordered_set<const Aquamarine::IBuffer*>   uniqueBuffers;
        atlasTargets.reserve(poolLength);
        for (size_t i = 0; i < poolLength; ++i) {
            int        age    = 0;
            const auto buffer = swapchain->next(&age);
            const auto dmabuf = buffer ? buffer->dmabuf() : Aquamarine::SDMABUFAttrs{};
            if (!buffer || !buffer->good() || !dmabuf.success || dmabuf.planes != 1 || dmabuf.format != DRM_FORMAT_XRGB8888 || dmabuf.strides[0] == 0 ||
                !uniqueBuffers.emplace(buffer.get()).second) {
                Log::logger->log(Log::WARN, "Denial shared atlas scanout pool did not provide unique single-plane XR24 dma-bufs; retaining scene-blit fallback");
                return false;
            }

            auto atlas                 = std::make_unique<SSharedAtlasTarget>();
            atlas->renderTarget.buffer = buffer;
            atlas->renderTarget.dmabuf = dmabuf;
            atlas->renderTarget.size   = dmabuf.size;

            for (const auto& output : outputs) {
                const auto& rect      = output.viewport->sourceRect;
                const auto& pixelSize = output.viewport->pixelSize;
                const bool  integral  = std::abs(rect.x - std::round(rect.x)) < 0.001 && std::abs(rect.y - std::round(rect.y)) < 0.001 &&
                    std::abs(rect.w - std::round(rect.w)) < 0.001 && std::abs(rect.h - std::round(rect.h)) < 0.001;
                const bool oneToOne = std::abs(rect.w - pixelSize.x) < 0.001 && std::abs(rect.h - pixelSize.y) < 0.001;
                if (!integral || !oneToOne || rect.x < 0 || rect.y < 0 || rect.w < 1 || rect.h < 1 || rect.x + rect.w > dmabuf.size.x || rect.y + rect.h > dmabuf.size.y) {
                    Log::logger->log(Log::WARN,
                                     "Denial shared atlas scanout needs integral one-to-one output crops; {} has source=({}, {}, {}, {}) pixels={}; retaining scene-blit fallback",
                                     output.viewport->name, rect.x, rect.y, rect.w, rect.h, pixelSize);
                    return false;
                }

                const auto sourceX = sc<uint64_t>(std::llround(rect.x));
                const auto sourceY = sc<uint64_t>(std::llround(rect.y));
                if (sourceX > std::numeric_limits<uint32_t>::max() || sourceY > std::numeric_limits<uint32_t>::max()) {
                    Log::logger->log(Log::WARN, "Denial shared atlas scanout source overflow for {}; retaining scene-blit fallback", output.viewport->name);
                    return false;
                }

                auto viewBuffer             = makeShared<CSharedAtlasBufferView>(buffer, dmabuf, pixelSize, sc<uint32_t>(sourceX), sc<uint32_t>(sourceY));
                auto viewTarget             = std::make_unique<SOutputBufferTarget>();
                viewTarget->buffer          = viewBuffer;
                viewTarget->dmabuf          = dmabuf;
                viewTarget->size            = pixelSize;
                viewTarget->scanoutSource   = CBox{rect.x, rect.y, rect.w, rect.h};
                viewTarget->sharedAtlasView = true;
                atlas->outputTargets.emplace(output.viewport->monitorId, std::move(viewTarget));
            }

            atlasTargets.emplace_back(std::move(atlas));
        }

        const auto&                                           probeDmabuf = atlasTargets.front()->renderTarget.dmabuf;
        std::unordered_map<MONITORID, SP<Aquamarine::CDRMFB>> probeFramebuffers;
        for (size_t atlasIndex = 0; atlasIndex < atlasTargets.size(); ++atlasIndex) {
            for (const auto& output : atomicOutputs) {
                auto* target      = sharedAtlasOutputTarget(*atlasTargets[atlasIndex], output.viewport->monitorId);
                errno             = 0;
                auto      fb      = target && target->buffer ? Aquamarine::CDRMFB::create(target->buffer, drmBackend) : nullptr;
                const int fbError = errno;
                if (!fb || fb->id == 0) {
                    Log::logger->log(Log::WARN,
                                     "Denial shared atlas scanout could not import pool buffer {} as a full atlas framebuffer for {}: {} ({}) size={} stride={} "
                                     "modifier=0x{:x}; retaining scene-blit fallback",
                                     atlasIndex, output.viewport->name, std::strerror(fbError), fbError, target ? target->dmabuf.size : Vector2D{},
                                     target ? target->dmabuf.strides[0] : 0, target ? target->dmabuf.modifier : DRM_FORMAT_MOD_INVALID);
                    return false;
                }
                if (atlasIndex == 0)
                    probeFramebuffers.emplace(output.viewport->monitorId, std::move(fb));
            }
        }

        const auto fixed1616 = [](double value) -> std::optional<uint64_t> {
            constexpr double SCALE = 65536.0;
            if (!std::isfinite(value) || value < 0.0 || value * SCALE > std::numeric_limits<uint32_t>::max())
                return std::nullopt;
            return sc<uint64_t>(std::llround(value * SCALE));
        };

        std::unique_ptr<drmModeAtomicReq, decltype(&drmModeAtomicFree)> request(drmModeAtomicAlloc(), &drmModeAtomicFree);
        if (!request) {
            Log::logger->log(Log::WARN, "Denial shared atlas scanout probe could not allocate an atomic request; retaining scene-blit fallback");
            return false;
        }

        const auto addProperty = [&request](uint32_t object, const SDrmProperty& property, uint64_t value) {
            return property.id != 0 && drmModeAtomicAddProperty(request.get(), object, property.id, value) >= 0;
        };

        for (const auto& output : atomicOutputs) {
            const auto& rect = output.viewport->sourceRect;
            if (!std::isfinite(rect.x) || !std::isfinite(rect.y) || !std::isfinite(rect.w) || !std::isfinite(rect.h) || rect.x < 0 || rect.y < 0 || rect.w <= 0 || rect.h <= 0 ||
                rect.x + rect.w > m_displayLayout.pixelSize.x || rect.y + rect.h > m_displayLayout.pixelSize.y) {
                Log::logger->log(Log::WARN, "Denial shared atlas scanout probe rejected invalid source rect ({}, {}, {}, {}) for {}; retaining scene-blit fallback", rect.x, rect.y,
                                 rect.w, rect.h, output.viewport->name);
                return false;
            }

            const auto srcX  = fixed1616(rect.x);
            const auto srcY  = fixed1616(rect.y);
            const auto srcW  = fixed1616(output.viewport->pixelSize.x);
            const auto srcH  = fixed1616(output.viewport->pixelSize.y);
            const auto fb    = probeFramebuffers.at(output.viewport->monitorId);
            const auto crtcW = sc<uint64_t>(std::llround(output.viewport->pixelSize.x));
            const auto crtcH = sc<uint64_t>(std::llround(output.viewport->pixelSize.y));
            if (!srcX || !srcY || !srcW || !srcH || !fb || !addProperty(output.plane.id, output.plane.fbId, fb->id) ||
                !addProperty(output.plane.id, output.plane.crtcId, output.crtcId) || !addProperty(output.plane.id, output.plane.srcX, *srcX) ||
                !addProperty(output.plane.id, output.plane.srcY, *srcY) || !addProperty(output.plane.id, output.plane.srcW, *srcW) ||
                !addProperty(output.plane.id, output.plane.srcH, *srcH) || !addProperty(output.plane.id, output.plane.crtcX, 0) ||
                !addProperty(output.plane.id, output.plane.crtcY, 0) || !addProperty(output.plane.id, output.plane.crtcW, crtcW) ||
                !addProperty(output.plane.id, output.plane.crtcH, crtcH)) {
                Log::logger->log(Log::WARN, "Denial shared atlas scanout probe could not populate the atomic plane state for {}; retaining scene-blit fallback",
                                 output.viewport->name);
                return false;
            }

            Log::logger->log(Log::INFO, "Denial shared atlas scanout candidate output={} plane={} source=({}, {}, {}, {}) fb={} framebuffer={} destination=({}, {}, {}, {})",
                             output.viewport->name, output.plane.id, rect.x, rect.y, rect.w, rect.h, fb->id, probeDmabuf.size, 0, 0, crtcW, crtcH);
        }

        errno            = 0;
        const int result = drmModeAtomicCommit(fd, request.get(), DRM_MODE_ATOMIC_TEST_ONLY, nullptr);
        const int error  = errno;
        if (result != 0) {
            Log::logger->log(Log::WARN, "Denial shared atlas scanout TEST_ONLY rejected atlas={} format=0x{:08x} modifier=0x{:x}: {} ({}); retaining scene-blit fallback",
                             m_displayLayout.pixelSize, probeDmabuf.format, probeDmabuf.modifier, std::strerror(error), error);
            return false;
        }

        m_sharedAtlasSwapchain = swapchain;
        m_sharedAtlasTargets   = std::move(atlasTargets);
        Log::logger->log(Log::INFO, "Denial shared atlas scanout TEST_ONLY passed: pool={} atlas={} format=0x{:08x} modifier=0x{:x} feeds {} source-cropped primary planes",
                         m_sharedAtlasTargets.size(), m_displayLayout.pixelSize, probeDmabuf.format, probeDmabuf.modifier, atomicOutputs.size());
        return true;
    }

    bool CRuntime::refreshDisplayLayout(bool initial) {
        if (!g_pCompositor)
            return false;

        std::vector<PHLMONITOR> monitors;
        monitors.reserve(g_pCompositor->m_monitors.size());
        for (const auto& monitor : g_pCompositor->m_monitors) {
            if (monitor && monitor->m_output && monitor->m_enabled && !monitor->m_isUnsafeFallback && monitor->m_size.x > 0 && monitor->m_size.y > 0 &&
                monitor->m_pixelSize.x > 0 && monitor->m_pixelSize.y > 0)
                monitors.push_back(monitor);
        }
        if (monitors.empty())
            return false;

        std::ranges::sort(monitors, [](const auto& lhs, const auto& rhs) {
            if (lhs->m_position.x != rhs->m_position.x)
                return lhs->m_position.x < rhs->m_position.x;
            if (lhs->m_position.y != rhs->m_position.y)
                return lhs->m_position.y < rhs->m_position.y;
            return lhs->m_name < rhs->m_name;
        });

        PHLMONITOR ticker;
        if (!m_options.flutterMonitor.empty()) {
            const auto it = std::ranges::find_if(monitors, [this](const auto& monitor) { return monitor->m_name == m_options.flutterMonitor; });
            if (it != monitors.end())
                ticker = *it;
        }
        if (!ticker) {
            ticker = *std::ranges::max_element(monitors, [](const auto& lhs, const auto& rhs) { return lhs->m_refreshRate < rhs->m_refreshRate; });
        }

        Vector2D minimum{std::numeric_limits<double>::max(), std::numeric_limits<double>::max()};
        Vector2D maximum{std::numeric_limits<double>::lowest(), std::numeric_limits<double>::lowest()};
        for (const auto& monitor : monitors) {
            minimum.x = std::min(minimum.x, monitor->m_position.x);
            minimum.y = std::min(minimum.y, monitor->m_position.y);
            maximum.x = std::max(maximum.x, monitor->m_position.x + monitor->m_size.x);
            maximum.y = std::max(maximum.y, monitor->m_position.y + monitor->m_size.y);
        }

        const auto     engineScale = ticker->m_scale > 0.0 ? ticker->m_scale : 1.0;
        SDisplayLayout next{
            .globalOrigin       = minimum,
            .logicalSize        = maximum - minimum,
            .pixelSize          = (maximum - minimum) * engineScale,
            .engineScale        = engineScale,
            .maxRefreshRate     = std::max(1.F, ticker->m_refreshRate),
            .tickerMonitorId    = ticker->m_id,
            .systemBarMonitorId = ticker->m_id,
            .epoch              = m_displayLayout.epoch + 1,
        };
        next.pixelSize = {std::ceil(next.pixelSize.x), std::ceil(next.pixelSize.y)};
        next.outputs.reserve(monitors.size());

        const auto requestedBarMonitor = m_options.systemBarMonitor.empty() ? ticker->m_name : m_options.systemBarMonitor;
        for (const auto& monitor : monitors) {
            const auto logicalPosition = monitor->m_position - minimum;
            const CBox logicalRect{logicalPosition, monitor->m_size};
            const CBox sourceRect{
                (logicalPosition * engineScale).round(),
                (monitor->m_size * engineScale).round(),
            };
            next.outputs.push_back(SOutputViewport{
                .monitorId   = monitor->m_id,
                .name        = monitor->m_name,
                .logicalRect = logicalRect,
                .sourceRect  = sourceRect,
                .pixelSize   = monitor->m_pixelSize,
                .scale       = monitor->m_scale > 0.0 ? monitor->m_scale : 1.0,
                .refreshRate = monitor->m_refreshRate > 0.0 ? monitor->m_refreshRate : 60.0,
            });
            if (monitor->m_name == requestedBarMonitor)
                next.systemBarMonitorId = monitor->m_id;
        }

        std::ostringstream signature;
        signature << next.globalOrigin.x << ':' << next.globalOrigin.y << ':' << next.logicalSize.x << ':' << next.logicalSize.y << ':' << next.engineScale << ':'
                  << next.tickerMonitorId << ':' << next.systemBarMonitorId;
        for (const auto& output : next.outputs) {
            signature << '|' << output.monitorId << ':' << output.name << ':' << output.logicalRect.x << ':' << output.logicalRect.y << ':' << output.logicalRect.w << ':'
                      << output.logicalRect.h << ':' << output.pixelSize.x << ':' << output.pixelSize.y << ':' << output.scale << ':' << output.refreshRate;
        }
        auto signatureValue = std::move(signature).str();

        if (!initial && !m_displayLayoutSignature.empty() && signatureValue != m_displayLayoutSignature) {
            markDisplayLayoutDirty();
            return false;
        }
        if (signatureValue == m_displayLayoutSignature)
            return true;

        m_displayLayout          = std::move(next);
        m_displayLayoutSignature = std::move(signatureValue);
        m_outputIntervalNanos    = 0;
        m_outputTickSerial.fetch_add(1, std::memory_order_release);
        syncOutputPipelines();
        updateOutputRenderTarget();
        Log::logger->log(Log::INFO, "Denial display atlas outputs={} logical={} pixels={} origin={} scale={} ticker={} system_bar={} side={}", m_displayLayout.outputs.size(),
                         m_displayLayout.logicalSize, m_displayLayout.pixelSize, m_displayLayout.globalOrigin, m_displayLayout.engineScale, m_displayLayout.tickerMonitorId,
                         m_displayLayout.systemBarMonitorId, m_options.systemBarSide);
        return true;
    }

    void CRuntime::syncOutputPipelines() {
        std::unordered_set<MONITORID> active;
        active.reserve(m_displayLayout.outputs.size());
        for (const auto& output : m_displayLayout.outputs)
            active.emplace(output.monitorId);

        for (auto it = m_outputPipelines.begin(); it != m_outputPipelines.end();) {
            if (active.contains(it->first)) {
                ++it;
                continue;
            }
            it->second->presented.reset();
            it->second->modeChanged.reset();
            for (auto& target : it->second->targets) {
                if (target)
                    destroyOutputTarget(*target);
            }
            it = m_outputPipelines.erase(it);
        }

        for (const auto& output : m_displayLayout.outputs) {
            const auto monitor = g_pCompositor ? g_pCompositor->getMonitorFromID(output.monitorId) : nullptr;
            if (!monitor || !monitor->m_output)
                continue;

            auto& pipeline = m_outputPipelines[output.monitorId];
            if (!pipeline)
                pipeline = std::make_unique<SOutputPipeline>();
            pipeline->monitor = monitor;
            pipeline->presented.reset();
            pipeline->presented = monitor->m_events.presented.listen([this, monitorId = output.monitorId](const SMonitorPresentationEvent& event) {
                if (!event.presented)
                    return;
                auto* current = outputPipeline(monitorId);
                if (!current)
                    return;
                const auto monitor = current->monitor.lock();
                if (monitor && current->submittedOutputFrame && !current->submittedOutputFrame->repeated && !current->submittedOutputFrame->sampledGenerations.empty()) {
                    sendSurfaceFeedbackForSampledSurfaces(current->submittedOutputFrame->sampledGenerations, monitor);
                    // Feedback is now queued for the KMS event currently
                    // being dispatched. Completion must not queue it a
                    // second time after the protocol flush.
                    current->submittedOutputFrame->sampledGenerations.clear();
                }
                if (monitorId == m_displayLayout.tickerMonitorId)
                    m_outputTickSerial.fetch_add(1, std::memory_order_release);
                const auto seconds     = event.when.tv_sec > 0 ? sc<uint64_t>(event.when.tv_sec) : 0;
                const auto nanos       = event.when.tv_nsec > 0 ? sc<uint64_t>(event.when.tv_nsec) : 0;
                current->physicalPulse = SOutputPulse{
                    .monitorId         = monitorId,
                    .sequence          = event.sequence,
                    .frameStartNanos   = seconds * 1000000000ULL + nanos,
                    .intervalNanos     = event.refreshNs > 0 ? sc<uint64_t>(event.refreshNs) : 0,
                    .presentationFlags = event.flags,
                };
                // A physical completion advances only this output. Waking
                // every pipeline here cross-couples independent refresh
                // clocks and can grant the Flutter ticker extra cycles at
                // the sum of all monitor refresh rates. Scene publication
                // still calls requestOutputFrame() to fan a new Flutter
                // frame out to every output.
                if (g_pCompositor && monitor && monitor->m_enabled && monitor->m_output)
                    g_pCompositor->scheduleFrameForMonitor(monitor, Aquamarine::IOutput::AQ_SCHEDULE_NEEDS_FRAME);
            });
            pipeline->modeChanged.reset();
            pipeline->modeChanged = monitor->m_events.modeChanged.listen([this] { markDisplayLayoutDirty(); });
        }
    }

    void CRuntime::markDisplayLayoutDirty() {
        m_flutterRestartRequested.store(true, std::memory_order_release);
        requestOutputFrame();
    }

    void CRuntime::updateOutputRenderTarget() {
        const auto                  target = renderTargetFromDisplayLayout();
        std::lock_guard<std::mutex> lock(m_renderTargetMutex);
        m_lastOutputRenderTarget = target;
        m_lastOutputMonitorId    = target.monitorId;
    }

    void CRuntime::prepareDirectOutputTarget() {
        if (m_directTargetState.load(std::memory_order_acquire) != eDirectTargetState::ACQUIRING)
            return;

        MONITORID monitorId = -1;
        {
            std::lock_guard<std::mutex> lock(m_renderTargetMutex);
            monitorId = m_lastOutputMonitorId;
        }

        const auto monitor  = g_pCompositor && monitorId >= 0 ? g_pCompositor->getMonitorFromID(monitorId) : nullptr;
        auto*      pipeline = outputPipeline(monitorId);
        auto*      target   = monitor && monitor->m_output && pipeline ? acquireOutputTarget(*pipeline, monitor) : nullptr;
        if (!target) {
            m_directTargetState.store(eDirectTargetState::FAILED, std::memory_order_release);
            m_directTargetState.notify_one();
            return;
        }

        transitionOutputTarget(*target, eOutputBufferEvent::ACQUIRE_FOR_RENDER, "direct target acquisition");
        m_directOutputTarget    = target;
        m_directOutputMonitorId = monitorId;
        m_directTargetState.store(eDirectTargetState::READY, std::memory_order_release);
        m_directTargetState.notify_one();
    }

    void CRuntime::cancelDirectOutputTarget() {
        if (m_directOutputTarget) {
            transitionOutputTarget(*m_directOutputTarget, eOutputBufferEvent::CANCEL_PREPARATION, "direct target cancellation");
            if (g_pCompositor && m_directOutputMonitorId >= 0) {
                const auto monitor = g_pCompositor->getMonitorFromID(m_directOutputMonitorId);
                if (monitor && monitor->m_output && monitor->m_output->swapchain)
                    monitor->m_output->swapchain->rollback();
            }
        }

        m_directOutputTarget    = nullptr;
        m_directOutputMonitorId = -1;
        m_directTargetState.store(eDirectTargetState::IDLE, std::memory_order_release);
        m_directTargetState.notify_all();
    }

    void CRuntime::prepareSharedAtlasTarget() {
        if (m_sharedAtlasTargetState.load(std::memory_order_acquire) != eDirectTargetState::ACQUIRING)
            return;

        auto* target = acquireSharedAtlasTarget();
#if defined(DENIAL_ENABLE_DIAGNOSTICS)
        recordSharedAtlasAvailability(target != nullptr);
#endif
        if (!target) {
            // Every atlas may briefly be owned by KMS when the outputs have
            // different refresh clocks. This is ordinary producer
            // back-pressure, not evidence that source-cropped scanout is
            // unsupported. Leave the Flutter baton pending and retry after a
            // later physical output edge retires one of the buffers.
            DENIAL_HOT_LOG(Log::TRACE, "Denial shared atlas pool is saturated; deferring the next Flutter frame");
            m_sharedAtlasRenderTarget = nullptr;
            m_sharedAtlasTargetState.store(eDirectTargetState::IDLE, std::memory_order_release);
            m_sharedAtlasTargetState.notify_all();
            return;
        }

        m_sharedAtlasRenderTarget = target;
        m_sharedAtlasTargetState.store(eDirectTargetState::READY, std::memory_order_release);
        m_sharedAtlasTargetState.notify_one();
    }

    void CRuntime::cancelSharedAtlasTarget() {
        if (m_sharedAtlasRenderTarget)
            transitionOutputTarget(m_sharedAtlasRenderTarget->renderTarget, eOutputBufferEvent::CANCEL_PREPARATION, "shared atlas cancellation");
        m_sharedAtlasRenderTarget = nullptr;
        m_sharedAtlasTargetState.store(eDirectTargetState::IDLE, std::memory_order_release);
        m_sharedAtlasTargetState.notify_all();
    }

    void CRuntime::disableSharedAtlasScanout(std::string_view reason) {
        if (!m_sharedAtlasScanoutActive.exchange(false, std::memory_order_acq_rel))
            return;

        m_sharedAtlasScanoutCapable = false;
        m_sharedAtlasScanoutSuppressed.store(true, std::memory_order_release);
        Log::logger->log(Log::WARN, "Denial disabling shared atlas scanout after {}; restarting with scene-blit fallback", reason);
        m_flutterForcedRestartRequested.store(true, std::memory_order_release);
        m_flutterRestartRequested.store(true, std::memory_order_release);
        requestMainLoop(MAIN_LOOP_CANCEL_ATLAS_TARGET | MAIN_LOOP_OUTPUT_FRAME);
    }

    std::optional<CRuntime::SOutputPulse> CRuntime::consumePhysicalOutputReady(SOutputPipeline& pipeline, PHLMONITOR monitor) {
        if (!pipeline.physicalPulse || pipeline.physicalPulse->monitorId != monitor->m_id)
            return std::nullopt;

        return std::exchange(pipeline.physicalPulse, std::nullopt);
    }

    bool CRuntime::prepareBlackOutputFrame(SOutputPipeline& pipeline, PHLMONITOR monitor) {
        if (!monitor || !monitor->m_output || !m_flutter || pipeline.readyScanoutFrame)
            return false;

        auto* target = acquireOutputTarget(pipeline, monitor);
        if (!target)
            return false;
        if (target->state != eOutputBufferState::FREE) {
            DENIAL_HOT_LOG(Log::ERR, "Denial bootstrap acquired non-free output target state={}", sc<int>(target->state));
            monitor->m_output->swapchain->rollback();
            return false;
        }

        transitionOutputTarget(*target, eOutputBufferEvent::ACQUIRE_FOR_RENDER, "black frame acquisition");
        if (!makeFlutterContextCurrent(m_flutter->eglDisplay, m_flutter->presentationContext, "black output prepare") || !ensureOutputTargetPresentationFramebuffer(*target)) {
            transitionOutputTarget(*target, eOutputBufferEvent::CANCEL_PREPARATION, "black frame preparation failure");
            monitor->m_output->swapchain->rollback();
            return false;
        }

        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, target->presentationFramebuffer);
        glViewport(0, 0, sc<GLsizei>(target->size.x), sc<GLsizei>(target->size.y));
        glDisable(GL_SCISSOR_TEST);
        glClearColor(0.F, 0.F, 0.F, 1.F);
        glClear(GL_COLOR_BUFFER_BIT);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);

        auto         copyCompletionFd = fenceOrFinishSceneCopy();
        SOutputFrame frame{
            .monitorId = monitor->m_id,
            .target    = target,
            .sequence  = ++m_sceneSequence,
            .damage    = CRegion{0, 0, target->size.x, target->size.y},
            .black     = true,
        };
        if (copyCompletionFd.isValid())
            frame.scanoutCompletionFd = std::make_shared<Hyprutils::OS::CFileDescriptor>(std::move(copyCompletionFd));

        transitionOutputTarget(*target, eOutputBufferEvent::PUBLISH_PREPARED, "black frame publication");
        pipeline.readyScanoutFrame = std::move(frame);
        return true;
    }

    void CRuntime::completePresentedOutputFrame(SOutputPipeline& pipeline, PHLMONITOR monitor) {
        if (!monitor || !pipeline.submittedOutputFrame)
            return;

        auto presented = std::move(*pipeline.submittedOutputFrame);
        pipeline.submittedOutputFrame.reset();
        if (!presented.target)
            return;

        if (presented.repeated) {
            transitionOutputTarget(*presented.target, eOutputBufferEvent::PRESENT, "repeated frame presentation");
            return;
        }

#if defined(DENIAL_ENABLE_DIAGNOSTICS)
        if (presented.sceneGeneration != 0 && pipeline.lastPresentedSceneGeneration != 0 && presented.sceneGeneration <= pipeline.lastPresentedSceneGeneration) {
            Log::logger->log(Log::ERR, "Denial non-monotonic output generation on {}: previous={} presented={}", monitor->m_name, pipeline.lastPresentedSceneGeneration,
                             presented.sceneGeneration);
        }
        pipeline.lastPresentedSceneGeneration = std::max(pipeline.lastPresentedSceneGeneration, presented.sceneGeneration);
#endif

        if (pipeline.scanningOutputFrame && pipeline.scanningOutputFrame->target && pipeline.scanningOutputFrame->target != presented.target)
            transitionOutputTarget(*pipeline.scanningOutputFrame->target, eOutputBufferEvent::RETIRE, "scanout replacement");

        transitionOutputTarget(*presented.target, eOutputBufferEvent::PRESENT, "frame presentation");
        if (presented.target->presentationTexture != 0) {
            const auto sourceRect          = presented.target->sharedAtlasView ? presented.target->scanoutSource : CBox{{}, presented.target->size};
            pipeline.latestScreenCopyFrame = SScreenCopyFrame{
                .monitorId  = monitor->m_id,
                .texture    = presented.target->presentationTexture,
                .size       = presented.target->sharedAtlasView ? presented.target->dmabuf.size : presented.target->size,
                .sourceRect = sourceRect,
                .sequence   = presented.sequence,
            };
        } else
            pipeline.latestScreenCopyFrame = {};

        pipeline.scanningOutputFrame = std::move(presented);
    }

    bool CRuntime::submitNextOutputFrame(SOutputPipeline& pipeline, PHLMONITOR monitor, bool allowRepeat) {
        if (!monitor || !monitor->m_output || monitor->m_output->pendingPageFlip() || pipeline.submittedOutputFrame)
            return false;

        SOutputFrame frame;
        const bool   hasReady = pipeline.readyScanoutFrame.has_value();
        if (hasReady) {
            frame = std::move(*pipeline.readyScanoutFrame);
            pipeline.readyScanoutFrame.reset();
        } else if (allowRepeat && pipeline.scanningOutputFrame && pipeline.scanningOutputFrame->target) {
            frame = SOutputFrame{
                .monitorId       = monitor->m_id,
                .target          = pipeline.scanningOutputFrame->target,
                .sequence        = pipeline.scanningOutputFrame->sequence,
                .sceneGeneration = pipeline.scanningOutputFrame->sceneGeneration,
                .repeated        = true,
                .black           = pipeline.scanningOutputFrame->black,
            };
        } else
            return false;

        if (!frame.target || !frame.target->buffer)
            return false;

        if (frame.scanoutCompletionFd && frame.scanoutCompletionFd->isValid()) {
            monitor->m_inFence = frame.scanoutCompletionFd->duplicate();
            monitor->m_output->state->setExplicitInFence(monitor->m_inFence.get());
        } else {
            monitor->m_inFence.reset();
            monitor->m_output->state->resetExplicitFences();
        }

        monitor->m_output->state->setBuffer(frame.target->buffer);
        monitor->m_output->state->setPresentationMode(Aquamarine::eOutputPresentationMode::AQ_OUTPUT_PRESENTATION_VSYNC);
        if (!frame.repeated && !frame.damage.empty())
            monitor->m_output->state->addDamage(frame.damage);

        if (!monitor->m_state.commit()) {
            DENIAL_HOT_LOG(Log::ERR, "Denial failed to submit {} output frame for {}", frame.repeated ? "repeated" : "ready", monitor->m_name);
            if (frame.target->sharedAtlasView) {
                if (frame.repeated)
                    transitionOutputTarget(*frame.target, eOutputBufferEvent::REJECT_REPEAT, "shared atlas repeat rejection");
                else
                    transitionOutputTarget(*frame.target, eOutputBufferEvent::DROP_READY, "shared atlas frame rejection");
                disableSharedAtlasScanout(std::string{"KMS commit rejection on "} + monitor->m_name);
                return false;
            }
            if (frame.repeated)
                transitionOutputTarget(*frame.target, eOutputBufferEvent::REJECT_REPEAT, "repeated frame rejection");
            else {
                transitionOutputTarget(*frame.target, eOutputBufferEvent::REJECT_READY, "ready frame rejection");
                pipeline.readyScanoutFrame = std::move(frame);
            }
            return false;
        }

        transitionOutputTarget(*frame.target, frame.repeated ? eOutputBufferEvent::SUBMIT_REPEAT : eOutputBufferEvent::SUBMIT_READY, "KMS submission");
        pipeline.submittedOutputFrame = std::move(frame);
        return true;
    }

    bool CRuntime::startNextFlutterFrame(SOutputPipeline& pipeline, PHLMONITOR monitor, const std::optional<SOutputPulse>& pulse) {
        if (!monitor || pipeline.readyScanoutFrame || m_flutterProducerState.load(std::memory_order_acquire) != eFlutterProducerState::IDLE)
            return false;

        return deliverFlutterVsync(monitor, pulse);
    }

    bool CRuntime::deliverFlutterVsync(PHLMONITOR monitor, const std::optional<SOutputPulse>& pulse) {
        if (!monitor || !monitor->m_output || !m_flutter || !denial_engine_host_running(m_flutter->host))
            return false;

        if (monitor->m_pixelSize.x < 1 || monitor->m_pixelSize.y < 1)
            return false;

        const auto* tickerPipeline = outputPipeline(m_displayLayout.tickerMonitorId);
        if (m_flutterProducerState.load(std::memory_order_acquire) != eFlutterProducerState::IDLE || (tickerPipeline && tickerPipeline->readyScanoutFrame))
            return false;

        // Do not consume Flutter's one-shot baton until the frame has a
        // concrete render target. With mismatched output refresh rates all
        // atlas buffers can legitimately remain pinned by KMS for a short
        // interval; consuming the baton first would force Flutter to raster
        // into an unavailable target.
        {
            std::lock_guard<std::mutex> lock(m_vsyncMutex);
            if (m_pendingVsyncBatons.empty())
                return false;
        }

        // The physical ticker edge already runs on the compositor thread.
        // Reserve the atlas here so Flutter's later raster-thread FBO callback
        // normally becomes a lock-free READY load instead of an eventfd
        // round-trip back to this same thread on every rendered frame.
        bool preacquiredSharedAtlas = false;
        if (m_sharedAtlasScanoutActive.load(std::memory_order_acquire)) {
            auto targetState = m_sharedAtlasTargetState.load(std::memory_order_acquire);
            if (targetState == eDirectTargetState::IDLE) {
                auto expected = eDirectTargetState::IDLE;
                if (m_sharedAtlasTargetState.compare_exchange_strong(expected, eDirectTargetState::ACQUIRING, std::memory_order_acq_rel, std::memory_order_acquire))
                    prepareSharedAtlasTarget();
                targetState = m_sharedAtlasTargetState.load(std::memory_order_acquire);
            }

            preacquiredSharedAtlas = targetState == eDirectTargetState::READY && m_sharedAtlasRenderTarget;
            if (!preacquiredSharedAtlas) {
                if (targetState == eDirectTargetState::FAILED)
                    requestMainLoop(MAIN_LOOP_CANCEL_ATLAS_TARGET | MAIN_LOOP_OUTPUT_FRAME);
                else
                    requestOutputFrame();
                return false;
            }
        }

        intptr_t baton = 0;
        {
            std::lock_guard<std::mutex> lock(m_vsyncMutex);
            if (m_pendingVsyncBatons.empty()) {
                if (preacquiredSharedAtlas)
                    cancelSharedAtlasTarget();
                return false;
            }

            baton = m_pendingVsyncBatons.front();
            m_pendingVsyncBatons.erase(m_pendingVsyncBatons.begin());
        }

        // The single-shot ticker commit has completed before this function is
        // called. Latch the producer queues for the following output buffer.
        advanceQueuedImportedFrames();

        const auto fallbackInterval = monitor->m_refreshRate > 0 ? sc<uint64_t>(1000000000.0 / monitor->m_refreshRate) : 16666666;
        const auto intervalNanos    = pulse && pulse->intervalNanos > 0 ? pulse->intervalNanos : fallbackInterval;
        const auto frameStartNanos  = pulse && pulse->frameStartNanos > 0 ? pulse->frameStartNanos : denial_engine_host_current_time_nanos(m_flutter->host);

        m_flutterProducerState.store(eFlutterProducerState::REQUESTED, std::memory_order_release);
        if (denial_engine_host_on_vsync(m_flutter->host, baton, frameStartNanos, frameStartNanos + intervalNanos))
            return true;

        m_flutterProducerState.store(eFlutterProducerState::IDLE, std::memory_order_release);
        if (preacquiredSharedAtlas)
            cancelSharedAtlasTarget();

        DENIAL_HOT_LOG(Log::ERR, "Denial failed to return Flutter vsync baton {}", baton);

        // A failed embedder call did not consume the baton. Preserve it ahead
        // of any requests that arrived while this edge was being delivered,
        // then request one more physical ticker pulse.
        {
            std::lock_guard<std::mutex> lock(m_vsyncMutex);
            m_pendingVsyncBatons.insert(m_pendingVsyncBatons.begin(), baton);
        }
        requestMainLoop(MAIN_LOOP_OUTPUT_FRAME);
        return false;

        (void)monitor;
        (void)pulse;
        return false;
    }

    CRuntime::SOutputBufferTarget* CRuntime::acquireOutputTarget(SOutputPipeline& pipeline, PHLMONITOR monitor) {
        if (!monitor || !monitor->m_output || !monitor->m_output->swapchain)
            return nullptr;

        if (!monitor->m_state.updateSwapchain()) {
            DENIAL_HOT_LOG(Log::ERR, "Denial failed to update output swapchain for {}", monitor->m_name);
            return nullptr;
        }

        int        age    = 0;
        const auto BUFFER = monitor->m_output->swapchain->next(&age);
        if (!BUFFER || !BUFFER->good()) {
            DENIAL_HOT_LOG(Log::ERR, "Denial failed to acquire output buffer for {}", monitor->m_name);
            return nullptr;
        }

        const auto DMABUF = BUFFER->dmabuf();
        if (!canImportClientBuffer(DMABUF)) {
            DENIAL_HOT_LOG(Log::ERR, "Denial output buffer for {} is not an importable dmabuf", monitor->m_name);
            monitor->m_output->swapchain->rollback();
            return nullptr;
        }

        for (const auto& target : pipeline.targets) {
            if (target && target->buffer.get() == BUFFER.get()) {
                if (target->state != eOutputBufferState::FREE) {
                    DENIAL_HOT_LOG(Log::ERR, "Denial swapchain rotated to non-free output target state={}", sc<int>(target->state));
                    monitor->m_output->swapchain->rollback();
                    return nullptr;
                }
                return target.get();
            }
        }

        auto slot = std::ranges::find_if(pipeline.targets, [](const auto& target) { return !target; });
        if (slot == pipeline.targets.end()) {
            slot = std::ranges::find_if(pipeline.targets, [](const auto& target) { return target && target->state == eOutputBufferState::FREE; });
            if (slot == pipeline.targets.end()) {
                DENIAL_HOT_LOG(Log::ERR, "Denial output swapchain has no FREE target");
                monitor->m_output->swapchain->rollback();
                return nullptr;
            }
            destroyOutputTarget(**slot);
        }

        *slot           = std::make_unique<SOutputBufferTarget>();
        (*slot)->buffer = BUFFER;
        (*slot)->dmabuf = DMABUF;
        (*slot)->size   = DMABUF.size;
        return slot->get();
    }

    uint32_t CRuntime::ensureCurrentSceneFramebuffer() {
        const auto failFrame = [] { return 0U; };

        if (!m_flutter || !Render::GL::g_pHyprOpenGL)
            return failFrame();

        // Flutter may request the next FBO immediately after present(), before
        // the next output frame has been prepared. The scene target therefore
        // belongs to the engine lifetime, not to one output-frame record.
        Vector2D size;
        {
            std::lock_guard<std::mutex> lock(m_renderTargetMutex);
            if (!m_lastOutputRenderTarget)
                return failFrame();
            size = m_lastOutputRenderTarget->size;
        }

        if (!makeFlutterContextCurrent(m_flutter->eglDisplay, m_flutter->renderContext, "Flutter scene target"))
            return failFrame();
        if (!waitForPendingSceneCopy())
            return failFrame();

        // This callback is Flutter's actual raster-frame boundary. A vsync is
        // only a time signal and may arrive while the prior raster frame is
        // still being built, so clearing samples there can detach an imported
        // generation from the scene that really contains it. Samples left here
        // came from a raster frame that never presented. Finish that abnormal
        // command stream before releasing its wl_buffer references, then rearm
        // only generations that are still the latest surface mailbox value.
        std::unordered_map<TSurfaceId, uint64_t> abandonedSamples;
        std::vector<SImportedFrameHold>          abandonedBufferHolds;
        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            abandonedSamples.swap(m_rasterSampledGenerations);
            abandonedBufferHolds.swap(m_rasterSampledBufferHolds);
        }
        if (!abandonedBufferHolds.empty()) {
            glFinish();
            releaseSampleHoldsOnMainThread(std::move(abandonedBufferHolds));
        }
        if (!abandonedSamples.empty())
            queueTextureMarksForGenerations(abandonedSamples);

        auto& scene = m_sceneFramebuffer;
        if (!ensureSceneFramebuffer(scene, size))
            return failFrame();

        // The texture is detached by present() before ownership crosses to the
        // presentation context. Reattach it only when Flutter asks to render.
        glBindFramebuffer(GL_FRAMEBUFFER, scene.framebuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, scene.texture, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            DENIAL_HOT_LOG(Log::ERR, "Denial scene framebuffer became incomplete while acquiring it");
            glBindFramebuffer(GL_FRAMEBUFFER, 0);
            return failFrame();
        }
        glViewport(0, 0, sc<GLsizei>(scene.size.x), sc<GLsizei>(scene.size.y));

        return scene.framebuffer;
    }

    bool CRuntime::ensureSceneFramebuffer(SSceneFramebuffer& scene, const Vector2D& size) {
        if (!m_flutter || size.x < 1 || size.y < 1)
            return false;

        if (scene.framebuffer != 0 && scene.texture != 0 && scene.size.x == size.x && scene.size.y == size.y)
            return true;

        destroySceneFramebuffer(scene);

        if (!makeFlutterContextCurrent(m_flutter->eglDisplay, m_flutter->renderContext, "Flutter scene framebuffer create"))
            return false;

        GLuint texture     = 0;
        GLuint framebuffer = 0;

        glGenTextures(1, &texture);
        glBindTexture(GL_TEXTURE_2D, texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, sc<GLsizei>(size.x), sc<GLsizei>(size.y), 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glBindTexture(GL_TEXTURE_2D, 0);

        const auto TEXTURE_ERROR = glGetError();
        if (TEXTURE_ERROR != GL_NO_ERROR) {
            DENIAL_HOT_LOG(Log::ERR, "Denial scene texture allocation failed: glError=0x{:x} size={}", sc<int>(TEXTURE_ERROR), size);
            if (texture != 0)
                glDeleteTextures(1, &texture);
            return false;
        }

        glGenFramebuffers(1, &framebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);

        const auto STATUS = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (STATUS != GL_FRAMEBUFFER_COMPLETE) {
            DENIAL_HOT_LOG(Log::ERR, "Denial scene framebuffer incomplete: status=0x{:x}", sc<int>(STATUS));
            glBindFramebuffer(GL_FRAMEBUFFER, 0);
            glDeleteFramebuffers(1, &framebuffer);
            glDeleteTextures(1, &texture);
            return false;
        }

        scene = SSceneFramebuffer{
            .framebuffer             = framebuffer,
            .presentationFramebuffer = 0,
            .texture                 = texture,
            .size                    = size,
        };

        DENIAL_HOT_LOG(Log::INFO, "Denial created scene framebuffer fbo={} texture={} size={}", framebuffer, texture, size);
        return true;
    }

    bool CRuntime::ensureOutputTargetPresentationFramebuffer(SOutputBufferTarget& target) {
        // Must be called on the Hypr main thread with presentationContext current.
        if (!m_flutter || !Render::GL::g_pHyprOpenGL)
            return false;

        if (target.presentationFramebuffer != 0)
            return true;

        target.presentationImportAttempted = true;

        // The EGLImage is shared across contexts; reuse it if the renderContext
        // path already imported this buffer, otherwise import it here.
        if (!target.eglImage) {
            const auto IMAGE = Render::GL::g_pHyprOpenGL->createEGLImage(target.dmabuf);
            if (IMAGE == EGL_NO_IMAGE_KHR) {
                DENIAL_HOT_LOG(Log::ERR, "Denial failed to import output dmabuf as presentation EGLImage");
                return false;
            }
            target.eglImage = rc<void*>(IMAGE);
        }

        GLuint texture      = 0;
        GLuint renderbuffer = 0;
        GLuint framebuffer  = 0;

        if (Render::GL::g_pHyprOpenGL->m_proc.glEGLImageTargetTexture2DOES) {
            glGenTextures(1, &texture);
            glBindTexture(GL_TEXTURE_2D, texture);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            Render::GL::g_pHyprOpenGL->m_proc.glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, rc<EGLImageKHR>(target.eglImage));
            glBindTexture(GL_TEXTURE_2D, 0);
            if (const auto error = glGetError(); error != GL_NO_ERROR) {
                DENIAL_HOT_LOG(Log::WARN, "Denial could not expose committed output buffer for screen copy: glError=0x{:x}", sc<int>(error));
                glDeleteTextures(1, &texture);
                texture = 0;
            }
        }

        glGenRenderbuffers(1, &renderbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
        Render::GL::g_pHyprOpenGL->m_proc.glEGLImageTargetRenderbufferStorageOES(GL_RENDERBUFFER, rc<EGLImageKHR>(target.eglImage));
        glBindRenderbuffer(GL_RENDERBUFFER, 0);

        glGenFramebuffers(1, &framebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, renderbuffer);

        const auto STATUS = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (STATUS != GL_FRAMEBUFFER_COMPLETE) {
            DENIAL_HOT_LOG(Log::ERR, "Denial output presentation framebuffer incomplete: status=0x{:x}", sc<int>(STATUS));
            glBindFramebuffer(GL_FRAMEBUFFER, 0);
            glDeleteFramebuffers(1, &framebuffer);
            glDeleteRenderbuffers(1, &renderbuffer);
            glDeleteTextures(1, &texture);
            return false;
        }

        target.presentationTexture      = texture;
        target.presentationRenderbuffer = renderbuffer;
        target.presentationFramebuffer  = framebuffer;

        DENIAL_HOT_LOG(Log::INFO, "Denial imported output presentation target buffer={} fbo={} rbo={} texture={} size={}", rc<uintptr_t>(target.buffer.get()),
                       target.presentationFramebuffer, target.presentationRenderbuffer, target.presentationTexture, target.size);
        return true;
    }

    bool CRuntime::ensureOutputTargetDirectFramebuffer(SOutputBufferTarget& target) {
        if (!m_flutter || !Render::GL::g_pHyprOpenGL)
            return false;

        // Flutter invokes this callback with its raster context current.
        destroyDeferredDirectRenderResources();

        if (target.directRenderFramebuffer != 0) {
            glBindFramebuffer(GL_FRAMEBUFFER, target.directRenderFramebuffer);
            glViewport(0, 0, sc<GLsizei>(target.size.x), sc<GLsizei>(target.size.y));
            return true;
        }

        if (!target.eglImage) {
            const auto image = Render::GL::g_pHyprOpenGL->createEGLImage(target.dmabuf);
            if (image == EGL_NO_IMAGE_KHR)
                return false;
            target.eglImage = rc<void*>(image);
        }

        GLuint texture     = 0;
        GLuint framebuffer = 0;
        glGenTextures(1, &texture);
        glBindTexture(GL_TEXTURE_2D, texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        Render::GL::g_pHyprOpenGL->m_proc.glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, rc<EGLImageKHR>(target.eglImage));

        glGenFramebuffers(1, &framebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            glBindFramebuffer(GL_FRAMEBUFFER, 0);
            glDeleteFramebuffers(1, &framebuffer);
            glDeleteTextures(1, &texture);
            return false;
        }

        target.directRenderTexture     = texture;
        target.directRenderFramebuffer = framebuffer;
        glViewport(0, 0, sc<GLsizei>(target.size.x), sc<GLsizei>(target.size.y));
        DENIAL_HOT_LOG(Log::INFO, "Denial direct KMS target buffer={} fbo={} texture={} size={}", rc<uintptr_t>(target.buffer.get()), framebuffer, texture, target.size);
        return true;
    }

    void CRuntime::destroyDeferredDirectRenderResources() {
        for (const auto& resources : m_deferredDirectRenderResources) {
            if (resources.framebuffer != 0) {
                const GLuint framebuffer = resources.framebuffer;
                glDeleteFramebuffers(1, &framebuffer);
            }
            if (resources.texture != 0) {
                const GLuint texture = resources.texture;
                glDeleteTextures(1, &texture);
            }
            destroyEGLImage(resources.eglImage);
        }
        m_deferredDirectRenderResources.clear();
    }

    void CRuntime::destroySharedAtlasTargets() {
        m_sharedAtlasRenderTarget = nullptr;
        m_sharedAtlasTargetState.store(eDirectTargetState::FAILED, std::memory_order_release);
        m_sharedAtlasTargetState.notify_all();

        for (auto& atlas : m_sharedAtlasTargets) {
            if (!atlas)
                continue;
            for (auto& [monitorId, target] : atlas->outputTargets) {
                if (target)
                    destroyOutputTarget(*target);
            }
            atlas->outputTargets.clear();
            destroyOutputTarget(atlas->renderTarget);
        }
        m_sharedAtlasTargets.clear();
        m_sharedAtlasSwapchain.reset();
        m_sharedAtlasScanoutActive.store(false, std::memory_order_release);
        m_sharedAtlasScanoutCapable = false;

        if (m_flutter && !m_deferredDirectRenderResources.empty() && makeFlutterContextCurrent(m_flutter->eglDisplay, m_flutter->renderContext, "shared atlas resources destroy"))
            destroyDeferredDirectRenderResources();
    }

    CRegion CRuntime::outputDamageForTarget(const SOutputBufferTarget& target, const SOutputViewport& viewport, uint64_t sceneGeneration) const {
        const CRegion full{0, 0, target.size.x, target.size.y};
        if (target.sceneGeneration == 0 || target.sceneGeneration >= sceneGeneration)
            return target.sceneGeneration == 0 ? full : CRegion{};

        if (m_sceneDamageHistory.empty() || target.sceneGeneration + 1 < m_sceneDamageHistory.front().generation)
            return full;

        CRegion sceneDamage;
        for (const auto& entry : m_sceneDamageHistory) {
            if (entry.generation > target.sceneGeneration && entry.generation <= sceneGeneration)
                sceneDamage.add(entry.damage);
        }
        sceneDamage.intersect(viewport.sourceRect);

        CRegion    damage;
        const auto sourceWidth  = viewport.sourceRect.w;
        const auto sourceHeight = viewport.sourceRect.h;
        if (sourceWidth <= 0.0 || sourceHeight <= 0.0)
            return full;

        const auto scaleX = target.size.x / sourceWidth;
        const auto scaleY = target.size.y / sourceHeight;
        for (const auto& rect : sceneDamage.getRects()) {
            const auto left   = std::floor((rect.x1 - viewport.sourceRect.x) * scaleX);
            const auto top    = std::floor((rect.y1 - viewport.sourceRect.y) * scaleY);
            const auto right  = std::ceil((rect.x2 - viewport.sourceRect.x) * scaleX);
            const auto bottom = std::ceil((rect.y2 - viewport.sourceRect.y) * scaleY);
            if (right > left && bottom > top)
                damage.add(CBox{left, top, right - left, bottom - top});
        }
        damage.intersect(0, 0, target.size.x, target.size.y);

        const auto extents   = damage.getExtents();
        const auto fullArea  = target.size.x * target.size.y;
        const auto area      = extents.width * extents.height;
        int        rectCount = 0;
        pixman_region32_rectangles(damage.pixman(), &rectCount);
        if (rectCount > 32 || (fullArea > 0 && area >= fullArea * 0.8))
            return full;

        return damage;
    }

    void CRuntime::pruneSceneDamageHistory() {
        uint64_t   minGeneration  = m_sceneGeneration;
        bool       haveUsedTarget = false;

        const auto includeGeneration = [&minGeneration, &haveUsedTarget](uint64_t generation) {
            if (generation == 0)
                return;
            haveUsedTarget = true;
            minGeneration  = std::min(minGeneration, generation);
        };

        for (const auto& [monitorId, pipeline] : m_outputPipelines) {
            if (!pipeline)
                continue;
            for (const auto& target : pipeline->targets) {
                if (target)
                    includeGeneration(target->sceneGeneration);
            }
        }

        // An atlas buffer may be reused long after a different atlas buffer
        // was last scanned out. Keep enough history for Flutter to reconstruct
        // that buffer and for every output view to calculate its own damage.
        for (const auto& atlas : m_sharedAtlasTargets) {
            if (!atlas)
                continue;
            includeGeneration(atlas->sceneGeneration);
            for (const auto& [monitorId, target] : atlas->outputTargets) {
                if (target)
                    includeGeneration(target->sceneGeneration);
            }
        }

        if (haveUsedTarget) {
            std::erase_if(m_sceneDamageHistory, [minGeneration](const auto& entry) { return entry.generation <= minGeneration; });
        }

        constexpr size_t MAX_DAMAGE_HISTORY = 256;
        if (m_sceneDamageHistory.size() > MAX_DAMAGE_HISTORY)
            m_sceneDamageHistory.erase(m_sceneDamageHistory.begin(), m_sceneDamageHistory.end() - MAX_DAMAGE_HISTORY);
    }

    bool CRuntime::presentCurrentOutputFrame(uint32_t fboId, const CRegion* frameDamage) {
        SOutputFrame frame;
        {
            std::lock_guard<std::mutex> lock(m_renderTargetMutex);
            if (!m_lastOutputRenderTarget || m_lastOutputMonitorId < 0 || m_lastOutputRenderTarget->monitorId < 0 || m_lastOutputRenderTarget->size.x < 1 ||
                m_lastOutputRenderTarget->size.y < 1) {
                DENIAL_HOT_LOG(Log::ERR, "Denial present has no valid simple frame for fbo={}", fboId);
                return false;
            }

            frame = SOutputFrame{
                .monitorId = m_lastOutputMonitorId,
                .scene     = &m_sceneFramebuffer,
            };
        }

        if (!m_sceneFramebuffer.framebuffer || !m_sceneFramebuffer.texture || (fboId != 0 && m_sceneFramebuffer.framebuffer != fboId)) {
            DENIAL_HOT_LOG(Log::ERR, "Denial present has no valid simple frame for fbo={}", fboId);
            return false;
        }

        if (!frameDamage || m_sceneFramebuffer.needsFullRepaint)
            frame.damage = CRegion{0, 0, m_sceneFramebuffer.size.x, m_sceneFramebuffer.size.y};
        else {
            frame.damage = *frameDamage;
            frame.damage.intersect(0, 0, m_sceneFramebuffer.size.x, m_sceneFramebuffer.size.y);
        }

        m_sceneFramebuffer.needsFullRepaint = false;

        if (!frame.damage.empty()) {
            {
                std::lock_guard<std::mutex> lock(m_renderTargetMutex);
                frame.sequence        = ++m_sceneSequence;
                frame.sceneGeneration = ++m_sceneGeneration;
            }
            m_sceneDamageHistory.push_back(SSceneDamageEntry{
                .generation = frame.sceneGeneration,
                .damage     = frame.damage,
            });

            if (m_sceneSubmitState.exchange(eSceneSubmitState::IN_FLIGHT, std::memory_order_acq_rel) == eSceneSubmitState::IN_FLIGHT) {
                DENIAL_HOT_LOG(Log::ERR, "Denial received overlapping scene submit {}", frame.sequence);
                return false;
            }
        }

        // A shared texture must never remain attached in both EGL contexts.
        // Detach it from Flutter, then put an EGL fence after the complete
        // raster command stream. The presentation context waits on that fence
        // on the GPU before copying, without stalling either CPU thread.
        glBindFramebuffer(GL_FRAMEBUFFER, frame.scene->framebuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        fenceOrFinishSceneRender(frame);

        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            frame.sampledGenerations.swap(m_rasterSampledGenerations);
            frame.sampledBufferHolds.swap(m_rasterSampledBufferHolds);
        }

        // Flutter may legally close a scheduled transaction with no dirty
        // region. It still needs its GL work fenced and sampled client buffers
        // released, but it is not a scene generation and must not copy into
        // per-output scanout buffers or schedule KMS commits.
        if (frame.damage.empty()) {
            releaseSampledBuffersAfterRender(frame);
            return true;
        }

        return publishRenderedFrame(std::move(frame));
    }

    bool CRuntime::presentDirectOutputFrame(uint32_t fboId, const CRegion* frameDamage) {
        auto* target = m_directTargetState.load(std::memory_order_acquire) == eDirectTargetState::READY ? m_directOutputTarget : nullptr;
        // The embedder may close a second pass after the real direct buffer was
        // already presented. There is deliberately no destination/composition
        // pass in this experiment, so acknowledge that empty close as a no-op.
        if (!target && fboId == 0 && m_directTargetState.load(std::memory_order_acquire) == eDirectTargetState::IDLE)
            return true;
        if (!target || target->directRenderFramebuffer == 0 || (fboId != 0 && target->directRenderFramebuffer != fboId)) {
            DENIAL_HOT_LOG(Log::ERR, "Denial direct KMS present has no acquired target for fbo={}", fboId);
            m_directTargetState.store(eDirectTargetState::FAILED, std::memory_order_release);
            requestMainLoop(MAIN_LOOP_CANCEL_DIRECT_TARGET);
            return false;
        }

        SOutputFrame frame{
            .monitorId       = m_directOutputMonitorId,
            .target          = target,
            .sequence        = ++m_sceneSequence,
            .sceneGeneration = ++m_sceneGeneration,
        };

        if (!frameDamage)
            frame.damage = CRegion{0, 0, target->size.x, target->size.y};
        else {
            frame.damage = *frameDamage;
            frame.damage.intersect(0, 0, target->size.x, target->size.y);
        }

        m_sceneDamageHistory.push_back(SSceneDamageEntry{
            .generation = frame.sceneGeneration,
            .damage     = frame.damage,
        });

        if (m_sceneSubmitState.exchange(eSceneSubmitState::IN_FLIGHT, std::memory_order_acq_rel) == eSceneSubmitState::IN_FLIGHT) {
            DENIAL_HOT_LOG(Log::ERR, "Denial received overlapping direct KMS submit {}", frame.sequence);
            return false;
        }

        fenceOrFinishSceneRender(frame, false);
        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            frame.sampledGenerations.swap(m_rasterSampledGenerations);
            frame.sampledBufferHolds.swap(m_rasterSampledBufferHolds);
        }

        const bool submitted = publishRenderedFrame(std::move(frame));
        if (!submitted && m_directTargetState.load(std::memory_order_acquire) != eDirectTargetState::IDLE) {
            m_directTargetState.store(eDirectTargetState::FAILED, std::memory_order_release);
            requestMainLoop(MAIN_LOOP_CANCEL_DIRECT_TARGET);
        }
        return submitted;
    }

    bool CRuntime::presentSharedAtlasFrame(uint32_t fboId, const CRegion* frameDamage) {
        auto* atlas = m_sharedAtlasTargetState.load(std::memory_order_acquire) == eDirectTargetState::READY ? m_sharedAtlasRenderTarget : nullptr;
        if (!atlas && fboId == 0 && m_sharedAtlasTargetState.load(std::memory_order_acquire) == eDirectTargetState::IDLE)
            return true;
        if (!atlas || atlas->renderTarget.directRenderFramebuffer == 0 || (fboId != 0 && atlas->renderTarget.directRenderFramebuffer != fboId)) {
            DENIAL_HOT_LOG(Log::ERR, "Denial shared atlas present has no acquired target for fbo={}", fboId);
            m_sharedAtlasTargetState.store(eDirectTargetState::FAILED, std::memory_order_release);
            requestMainLoop(MAIN_LOOP_CANCEL_ATLAS_TARGET);
            return false;
        }

        SOutputFrame frame{
            .monitorId       = m_displayLayout.tickerMonitorId,
            .sharedAtlas     = atlas,
            .sequence        = ++m_sceneSequence,
            .sceneGeneration = ++m_sceneGeneration,
        };
        if (!frameDamage)
            frame.damage = CRegion{0, 0, atlas->renderTarget.size.x, atlas->renderTarget.size.y};
        else {
            frame.damage = *frameDamage;
            frame.damage.intersect(0, 0, atlas->renderTarget.size.x, atlas->renderTarget.size.y);
        }

        m_sceneDamageHistory.push_back(SSceneDamageEntry{
            .generation = frame.sceneGeneration,
            .damage     = frame.damage,
        });
        if (m_sceneSubmitState.exchange(eSceneSubmitState::IN_FLIGHT, std::memory_order_acq_rel) == eSceneSubmitState::IN_FLIGHT) {
            DENIAL_HOT_LOG(Log::ERR, "Denial received overlapping shared atlas submit {}", frame.sequence);
            requestMainLoop(MAIN_LOOP_CANCEL_ATLAS_TARGET);
            return false;
        }

        // KMS consumes the exported native fence directly. The EGL fence is
        // not retained because there is no intermediate presentation-context
        // copy to order.
        fenceOrFinishSceneRender(frame, false);
        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            frame.sampledGenerations.swap(m_rasterSampledGenerations);
            frame.sampledBufferHolds.swap(m_rasterSampledBufferHolds);
        }

        const bool submitted = publishRenderedFrame(std::move(frame));
        if (!submitted && m_sharedAtlasTargetState.load(std::memory_order_acquire) != eDirectTargetState::IDLE) {
            m_sharedAtlasTargetState.store(eDirectTargetState::FAILED, std::memory_order_release);
            requestMainLoop(MAIN_LOOP_CANCEL_ATLAS_TARGET);
        }
        return submitted;
    }

    bool CRuntime::publishRenderedFrame(SOutputFrame frame) {
        m_readyOutputFrame.emplace(std::move(frame));
        m_readyOutputFramePublished.store(true, std::memory_order_release);
        if (!requestMainLoop(MAIN_LOOP_SUBMIT_SCENE)) {
            m_readyOutputFramePublished.store(false, std::memory_order_release);
            frame = std::move(*m_readyOutputFrame);
            m_readyOutputFrame.reset();
            queueTextureMarksForGenerations(frame.sampledGenerations);
            releaseSampledBuffersAfterRender(frame);
            finishSceneSubmit(false);
            return false;
        }

        m_sceneSubmitState.wait(eSceneSubmitState::IN_FLIGHT, std::memory_order_acquire);
        return m_sceneSubmitState.load(std::memory_order_acquire) == eSceneSubmitState::SUCCEEDED;
    }

    void CRuntime::finishSceneSubmit(bool result) {
        m_sceneSubmitState.store(result ? eSceneSubmitState::SUCCEEDED : eSceneSubmitState::FAILED, std::memory_order_release);
        m_sceneSubmitState.notify_one();
    }

    void CRuntime::prepareRenderedFrame(SOutputFrame frame) {
        if (!m_flutter) {
            queueTextureMarksForGenerations(frame.sampledGenerations);
            releaseSampledBuffersAfterRender(frame);
            finishSceneSubmit(false);
            return;
        }

        if (frame.sharedAtlas) {
            auto* atlas = frame.sharedAtlas;
            bool  valid = m_sharedAtlasScanoutActive.load(std::memory_order_acquire) && atlas == m_sharedAtlasRenderTarget &&
                m_sharedAtlasTargetState.load(std::memory_order_acquire) == eDirectTargetState::READY && atlas->renderTarget.state == eOutputBufferState::PREPARING;

            bool                                            fenceDuplicationFailed = false;
            std::shared_ptr<Hyprutils::OS::CFileDescriptor> scanoutCompletionFd;
            if (valid && frame.renderCompletionFd && frame.renderCompletionFd->isValid()) {
                auto scanoutFence = frame.renderCompletionFd->duplicate();
                if (scanoutFence.isValid())
                    scanoutCompletionFd = std::make_shared<Hyprutils::OS::CFileDescriptor>(std::move(scanoutFence));
                else {
                    Log::logger->log(Log::ERR, "Denial could not duplicate the shared atlas render fence for KMS");
                    fenceDuplicationFailed = true;
                    valid                  = false;
                }
            }

            size_t preparedOutputs              = 0;
            bool   tickerPrepared               = false;
            bool   visibleDamage                = false;
            bool   presentationContextAttempted = false;
            bool   presentationContextReady     = false;
            if (valid) {
                for (const auto& viewport : m_displayLayout.outputs) {
                    auto frameOutputDamage = frame.damage;
                    frameOutputDamage.intersect(viewport.sourceRect);
                    visibleDamage |= !frameOutputDamage.empty();

                    auto*      pipeline = outputPipeline(viewport.monitorId);
                    const auto monitor  = g_pCompositor ? g_pCompositor->getMonitorFromID(viewport.monitorId) : nullptr;
                    auto*      target   = sharedAtlasOutputTarget(*atlas, viewport.monitorId);
                    if (!pipeline || !monitor || !monitor->m_output || !monitor->m_enabled || !target || target->state != eOutputBufferState::FREE)
                        continue;

                    auto outputDamage = outputDamageForTarget(*target, viewport, frame.sceneGeneration);
                    if (outputDamage.empty())
                        continue;

                    // The ticker can outrun another output (200 Hz versus
                    // 180 Hz on the development setup). A newer atlas frame
                    // must replace an older frame that is merely READY; it
                    // must never replace SUBMITTED or SCANNING storage. Without
                    // this mailbox step, a frame damaging only the slower
                    // output prepares zero views and false-fails Flutter's
                    // present callback.
                    auto outputSampledGenerations = frame.sampledGenerations;
                    if (pipeline->readyScanoutFrame) {
                        auto& superseded = *pipeline->readyScanoutFrame;
                        if (!superseded.target || superseded.target->state != eOutputBufferState::READY) {
                            Log::logger->log(Log::ERR, "Denial cannot supersede inconsistent READY atlas frame for {}", viewport.name);
                            continue;
                        }

                        for (const auto& [surfaceId, generation] : superseded.sampledGenerations) {
                            auto& retainedGeneration = outputSampledGenerations[surfaceId];
                            retainedGeneration       = std::max(retainedGeneration, generation);
                        }
                        const bool supersededSharedAtlas = superseded.target->sharedAtlasView;
                        transitionOutputTarget(*superseded.target, eOutputBufferEvent::DROP_READY, "atlas mailbox supersede");
                        pipeline->readyScanoutFrame.reset();
                        if (!supersededSharedAtlas && monitor->m_output->swapchain)
                            monitor->m_output->swapchain->rollback();
#if defined(DENIAL_ENABLE_DIAGNOSTICS)
                        if (++m_sharedAtlasMailboxSupersedes == 1) {
                            Log::logger->log(Log::INFO, "Denial shared atlas mailbox superseded its first unsubmitted frame on {}; independently clocked outputs remain live",
                                             viewport.name);
                        }
#endif
                    }

                    // Import the full atlas once for screen-copy consumers;
                    // latestScreenCopyFrame applies this output's source crop.
                    // This creates no copy and stays outside the hot path.
                    if (target->presentationFramebuffer == 0 && !target->presentationImportAttempted) {
                        if (!presentationContextAttempted) {
                            presentationContextReady     = makeFlutterContextCurrent(m_flutter->eglDisplay, m_flutter->presentationContext, "shared atlas output views");
                            presentationContextAttempted = true;
                        }
                        if (presentationContextReady)
                            ensureOutputTargetPresentationFramebuffer(*target);
                    }

                    target->sceneGeneration = frame.sceneGeneration;
                    transitionOutputTarget(*target, eOutputBufferEvent::PUBLISH_ATLAS_VIEW, "atlas view publication");
                    pipeline->readyScanoutFrame = SOutputFrame{
                        .monitorId           = viewport.monitorId,
                        .target              = target,
                        .sequence            = frame.sequence,
                        .sceneGeneration     = frame.sceneGeneration,
                        .damage              = std::move(outputDamage),
                        .scanoutCompletionFd = scanoutCompletionFd,
                        .sampledGenerations  = std::move(outputSampledGenerations),
                    };
                    g_pCompositor->scheduleFrameForMonitor(monitor, Aquamarine::IOutput::AQ_SCHEDULE_NEEDS_FRAME);
                    preparedOutputs += 1;
                    tickerPrepared = tickerPrepared || viewport.monitorId == m_displayLayout.tickerMonitorId;
                }

                atlas->sceneGeneration              = frame.sceneGeneration;
                atlas->renderTarget.sceneGeneration = frame.sceneGeneration;
            }

            transitionOutputTarget(atlas->renderTarget, eOutputBufferEvent::CANCEL_PREPARATION, "shared atlas render completion");
            m_sharedAtlasRenderTarget = nullptr;
            m_sharedAtlasTargetState.store(eDirectTargetState::IDLE, std::memory_order_release);
            m_sharedAtlasTargetState.notify_all();
            if (fenceDuplicationFailed)
                disableSharedAtlasScanout("the render fence could not be duplicated for KMS");

            // Flutter may close a legal no-op frame, and future layouts may
            // contain atlas gaps. Neither case is a presentation failure just
            // because no physical output intersects the damage.
            const bool prepared = valid && (preparedOutputs > 0 || !visibleDamage);
            if (preparedOutputs > 0 && !tickerPrepared) {
                // A frame that updates only a non-ticker output still needs one
                // lookahead commit on the ticker. That future physical edge is
                // what paces Flutter after the ticker crop itself goes idle.
                m_tickerPulseRequired    = true;
                const auto tickerMonitor = g_pCompositor ? g_pCompositor->getMonitorFromID(m_displayLayout.tickerMonitorId) : nullptr;
                if (tickerMonitor && tickerMonitor->m_enabled && tickerMonitor->m_output)
                    g_pCompositor->scheduleFrameForMonitor(tickerMonitor, Aquamarine::IOutput::AQ_SCHEDULE_NEEDS_FRAME);
            }
            if (!prepared) {
                queueTextureMarksForGenerations(frame.sampledGenerations);
                disableSharedAtlasScanout("a visible Flutter frame could not enter any output mailbox");
            }
            releaseSampledBuffersAfterRender(frame);
            pruneSceneDamageHistory();
            finishSceneSubmit(prepared);
            return;
        }

        const bool directFrame = frame.target && !frame.scene;
        if (directFrame) {
            const auto monitor  = g_pCompositor ? g_pCompositor->getMonitorFromID(frame.monitorId) : nullptr;
            auto*      pipeline = outputPipeline(frame.monitorId);
            const bool prepared = monitor && monitor->m_output && pipeline && !pipeline->readyScanoutFrame && frame.target->state == eOutputBufferState::PREPARING;
            if (prepared) {
                if (frame.renderCompletionFd && frame.renderCompletionFd->isValid())
                    frame.scanoutCompletionFd = std::make_shared<Hyprutils::OS::CFileDescriptor>(frame.renderCompletionFd->duplicate());
                frame.target->sceneGeneration = frame.sceneGeneration;
                releaseSampledBuffersAfterRender(frame);
                transitionOutputTarget(*frame.target, eOutputBufferEvent::PUBLISH_PREPARED, "direct frame publication");
                pipeline->readyScanoutFrame = std::move(frame);
                pruneSceneDamageHistory();
            } else {
                if (frame.target) {
                    transitionOutputTarget(*frame.target, eOutputBufferEvent::CANCEL_PREPARATION, "direct frame preparation failure");
                    if (monitor && monitor->m_output && monitor->m_output->swapchain)
                        monitor->m_output->swapchain->rollback();
                }
                queueTextureMarksForGenerations(frame.sampledGenerations);
                releaseSampledBuffersAfterRender(frame);
            }
            m_directOutputTarget    = nullptr;
            m_directOutputMonitorId = -1;
            m_directTargetState.store(eDirectTargetState::IDLE, std::memory_order_release);
            m_directTargetState.notify_all();
            finishSceneSubmit(prepared);
            if (prepared)
                requestOutputFrame();
            return;
        }

        if (!frame.scene || !makeFlutterContextCurrent(m_flutter->eglDisplay, m_flutter->presentationContext, "multi-output scene blit") || !waitForPendingSceneRender()) {
            queueTextureMarksForGenerations(frame.sampledGenerations);
            releaseSampledBuffersAfterRender(frame);
            finishSceneSubmit(false);
            return;
        }

        const bool newPresentationFramebuffer = frame.scene->presentationFramebuffer == 0;
        if (newPresentationFramebuffer)
            glGenFramebuffers(1, &frame.scene->presentationFramebuffer);
        if (frame.scene->presentationFramebuffer == 0) {
            queueTextureMarksForGenerations(frame.sampledGenerations);
            releaseSampledBuffersAfterRender(frame);
            finishSceneSubmit(false);
            return;
        }

        glBindFramebuffer(GL_FRAMEBUFFER, frame.scene->presentationFramebuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, frame.scene->texture, 0);
        if (newPresentationFramebuffer && glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
            glDeleteFramebuffers(1, &frame.scene->presentationFramebuffer);
            frame.scene->presentationFramebuffer = 0;
            glBindFramebuffer(GL_FRAMEBUFFER, 0);
            queueTextureMarksForGenerations(frame.sampledGenerations);
            releaseSampledBuffersAfterRender(frame);
            finishSceneSubmit(false);
            return;
        }
        glReadBuffer(GL_COLOR_ATTACHMENT0);
        glDisable(GL_SCISSOR_TEST);

        size_t     preparedOutputs = 0;
        const auto sceneHeight     = sc<GLint>(frame.scene->size.y);
        for (const auto& viewport : m_displayLayout.outputs) {
            auto*      pipeline = outputPipeline(viewport.monitorId);
            const auto monitor  = g_pCompositor ? g_pCompositor->getMonitorFromID(viewport.monitorId) : nullptr;
            if (!pipeline || !monitor || !monitor->m_output || !monitor->m_enabled || pipeline->readyScanoutFrame)
                continue;

            auto* target = acquireOutputTarget(*pipeline, monitor);
            if (!target || target->state != eOutputBufferState::FREE)
                continue;
            transitionOutputTarget(*target, eOutputBufferEvent::ACQUIRE_FOR_RENDER, "scene-copy target acquisition");

            auto outputDamage = outputDamageForTarget(*target, viewport, frame.sceneGeneration);
            // A scene transaction may affect only one monitor in the atlas.
            // Keep every unaffected output scanning its current buffer instead
            // of copying into and rotating a swapchain that has no new pixels.
            if (outputDamage.empty()) {
                transitionOutputTarget(*target, eOutputBufferEvent::CANCEL_PREPARATION, "empty output damage");
                if (monitor->m_output->swapchain)
                    monitor->m_output->swapchain->rollback();
                continue;
            }

            bool copied = ensureOutputTargetPresentationFramebuffer(*target);
            if (copied) {
                glBindFramebuffer(GL_READ_FRAMEBUFFER, frame.scene->presentationFramebuffer);
                glReadBuffer(GL_COLOR_ATTACHMENT0);
                glBindFramebuffer(GL_DRAW_FRAMEBUFFER, target->presentationFramebuffer);
                const bool oneToOne = viewport.sourceRect.w == target->size.x && viewport.sourceRect.h == target->size.y;
                if (oneToOne) {
                    for (const auto& rect : outputDamage.getRects()) {
                        const auto sourceLeft   = sc<GLint>(viewport.sourceRect.x) + rect.x1;
                        const auto sourceTop    = sc<GLint>(viewport.sourceRect.y) + rect.y1;
                        const auto sourceRight  = sc<GLint>(viewport.sourceRect.x) + rect.x2;
                        const auto sourceBottom = sc<GLint>(viewport.sourceRect.y) + rect.y2;
                        glBlitFramebuffer(sourceLeft, sceneHeight - sourceBottom, sourceRight, sceneHeight - sourceTop, rect.x1, sc<GLint>(target->size.y) - rect.y2, rect.x2,
                                          sc<GLint>(target->size.y) - rect.y1, GL_COLOR_BUFFER_BIT, GL_NEAREST);
                    }
                } else {
                    const auto sourceLeft   = sc<GLint>(viewport.sourceRect.x);
                    const auto sourceTop    = sc<GLint>(viewport.sourceRect.y);
                    const auto sourceRight  = sc<GLint>(viewport.sourceRect.x + viewport.sourceRect.w);
                    const auto sourceBottom = sc<GLint>(viewport.sourceRect.y + viewport.sourceRect.h);
                    glBlitFramebuffer(sourceLeft, sceneHeight - sourceBottom, sourceRight, sceneHeight - sourceTop, 0, 0, sc<GLint>(target->size.x), sc<GLint>(target->size.y),
                                      GL_COLOR_BUFFER_BIT, GL_NEAREST);
                    outputDamage = CRegion{0, 0, target->size.x, target->size.y};
                }
                glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
#if defined(DENIAL_ENABLE_DIAGNOSTICS)
                if (const auto error = glGetError(); error != GL_NO_ERROR) {
                    DENIAL_HOT_LOG(Log::ERR, "Denial atlas blit failed monitor={} glError=0x{:x}", viewport.name, sc<int>(error));
                    copied = false;
                }
#endif
            }
            if (!copied) {
                transitionOutputTarget(*target, eOutputBufferEvent::CANCEL_PREPARATION, "scene copy failure");
                if (monitor->m_output->swapchain)
                    monitor->m_output->swapchain->rollback();
                continue;
            }

            target->sceneGeneration = frame.sceneGeneration;
            transitionOutputTarget(*target, eOutputBufferEvent::PUBLISH_PREPARED, "scene-copy frame publication");
            pipeline->readyScanoutFrame = SOutputFrame{
                .monitorId          = viewport.monitorId,
                .target             = target,
                .sequence           = frame.sequence,
                .sceneGeneration    = frame.sceneGeneration,
                .damage             = std::move(outputDamage),
                .sampledGenerations = frame.sampledGenerations,
            };
            preparedOutputs += 1;
        }

        glBindFramebuffer(GL_FRAMEBUFFER, frame.scene->presentationFramebuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        // One fence after the detach orders every output blit as well as the
        // atlas ownership handoff. Share its exported fd with all KMS commits;
        // the EGL fence itself remains available to waitForPendingSceneCopy().
        // This avoids creating and exporting one intermediate fence per output.
        auto copyCompletionFd = fenceOrFinishSceneCopy();
        if (copyCompletionFd.isValid()) {
            auto completion = std::make_shared<Hyprutils::OS::CFileDescriptor>(std::move(copyCompletionFd));
            for (const auto& viewport : m_displayLayout.outputs) {
                auto* pipeline = outputPipeline(viewport.monitorId);
                if (pipeline && pipeline->readyScanoutFrame && pipeline->readyScanoutFrame->sequence == frame.sequence)
                    pipeline->readyScanoutFrame->scanoutCompletionFd = completion;
            }
        }

        const bool prepared = preparedOutputs > 0;
        if (!prepared)
            queueTextureMarksForGenerations(frame.sampledGenerations);
        releaseSampledBuffersAfterRender(frame);
        pruneSceneDamageHistory();
        finishSceneSubmit(prepared);
        if (prepared)
            requestOutputFrame();
    }

    void CRuntime::sendSurfaceFeedbackForSampledSurfaces(const std::unordered_map<TSurfaceId, uint64_t>& sampledGenerations, PHLMONITOR monitor) {
        m_surfaceRegistry.sendPresentFeedbackFor(sampledGenerations, monitor);
    }

    void CRuntime::destroyOutputTargets() {
        m_tickerPulseRequired = false;
        m_flutterProducerState.store(eFlutterProducerState::IDLE, std::memory_order_release);
        m_flutterRasterSentinelPending.store(false, std::memory_order_release);

        std::vector<std::unique_ptr<SOutputBufferTarget>> targets;
        for (auto& [monitorId, pipeline] : m_outputPipelines) {
            if (!pipeline)
                continue;
            pipeline->readyScanoutFrame.reset();
            pipeline->submittedOutputFrame.reset();
            pipeline->scanningOutputFrame.reset();
            pipeline->latestScreenCopyFrame = {};
            pipeline->presented.reset();
            pipeline->modeChanged.reset();
            for (auto& target : pipeline->targets) {
                if (target)
                    targets.emplace_back(std::move(target));
            }
        }
        destroySceneFramebuffers();
        {
            std::lock_guard<std::mutex> lock(m_renderTargetMutex);
            m_lastOutputRenderTarget.reset();
            m_lastOutputMonitorId = -1;
        }

        for (auto& target : targets) {
            if (target)
                destroyOutputTarget(*target);
        }
        destroySharedAtlasTargets();
        m_outputPipelines.clear();

        if (m_flutter && !m_deferredDirectRenderResources.empty() && makeFlutterContextCurrent(m_flutter->eglDisplay, m_flutter->renderContext, "direct KMS resources destroy"))
            destroyDeferredDirectRenderResources();
    }

    void CRuntime::destroyOutputTarget(SOutputBufferTarget& target) {
        if (target.directRenderFramebuffer != 0 || target.directRenderTexture != 0) {
            for (auto& [monitorId, pipeline] : m_outputPipelines) {
                if (pipeline && pipeline->latestScreenCopyFrame.texture == target.directRenderTexture)
                    pipeline->latestScreenCopyFrame = {};
            }
            m_deferredDirectRenderResources.emplace_back(SDeferredDirectRenderResources{
                .eglImage    = target.eglImage,
                .texture     = target.directRenderTexture,
                .framebuffer = target.directRenderFramebuffer,
            });
            target.eglImage                = nullptr;
            target.directRenderTexture     = 0;
            target.directRenderFramebuffer = 0;
        }

        if (m_flutter && (target.presentationFramebuffer != 0 || target.presentationRenderbuffer != 0 || target.presentationTexture != 0)) {
            makeFlutterContextCurrent(m_flutter->eglDisplay, m_flutter->presentationContext, "Flutter output presentation destroy");
            if (target.presentationFramebuffer != 0) {
                const GLuint framebuffer = target.presentationFramebuffer;
                glDeleteFramebuffers(1, &framebuffer);
                target.presentationFramebuffer = 0;
            }
            if (target.presentationRenderbuffer != 0) {
                const GLuint renderbuffer = target.presentationRenderbuffer;
                glDeleteRenderbuffers(1, &renderbuffer);
                target.presentationRenderbuffer = 0;
            }
            if (target.presentationTexture != 0) {
                for (auto& [monitorId, pipeline] : m_outputPipelines) {
                    if (pipeline && pipeline->latestScreenCopyFrame.texture == target.presentationTexture)
                        pipeline->latestScreenCopyFrame = {};
                }
                const GLuint texture = target.presentationTexture;
                glDeleteTextures(1, &texture);
                target.presentationTexture = 0;
            }
        }

        destroyEGLImage(target.eglImage);
        target.eglImage = nullptr;
        target.buffer.reset();
        // Destruction is an ownership reset, not a live pipeline transition.
        // Frames and callbacks holding this target have already been cleared.
        target.state                       = eOutputBufferState::FREE;
        target.presentationImportAttempted = false;
    }

    void CRuntime::destroySceneFramebuffers() {
        if (m_flutter)
            makeFlutterContextCurrent(m_flutter->eglDisplay, m_flutter->renderContext, "Flutter scene framebuffers destroy");

        destroySceneFramebuffer(m_sceneFramebuffer);
    }

    void CRuntime::destroySceneFramebuffer(SSceneFramebuffer& scene) {
        if (m_flutter) {
            finishPendingSceneRender();
            finishPendingSceneCopy();
            if (scene.presentationFramebuffer != 0 &&
                makeFlutterContextCurrent(m_flutter->eglDisplay, m_flutter->presentationContext, "Flutter scene presentation framebuffer destroy")) {
                const GLuint framebuffer = scene.presentationFramebuffer;
                glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
                glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
                glBindFramebuffer(GL_FRAMEBUFFER, 0);
                glDeleteFramebuffers(1, &framebuffer);
            }
            makeFlutterContextCurrent(m_flutter->eglDisplay, m_flutter->renderContext, "Flutter scene framebuffer destroy");
        }

        if (scene.framebuffer != 0) {
            const GLuint framebuffer = scene.framebuffer;
            glDeleteFramebuffers(1, &framebuffer);
        }

        if (scene.texture != 0) {
            const GLuint texture = scene.texture;
            glDeleteTextures(1, &texture);
        }
        scene = SSceneFramebuffer{};
    }

    bool CRuntime::waitForPendingSceneRender() {
        if (!m_flutter || m_flutter->sceneRenderFence == EGL_NO_SYNC_KHR)
            return true;

        const auto* GL    = Render::GL::g_pHyprOpenGL.get();
        const auto  fence = std::exchange(m_flutter->sceneRenderFence, EGL_NO_SYNC_KHR);
        if (GL && GL->m_proc.eglWaitSyncKHR && GL->m_proc.eglDestroySyncKHR && GL->m_proc.eglWaitSyncKHR(m_flutter->eglDisplay, fence, 0) == EGL_TRUE) {
            GL->m_proc.eglDestroySyncKHR(m_flutter->eglDisplay, fence);
            return true;
        }

        DENIAL_HOT_LOG(Log::ERR, "Denial could not queue the Flutter-render EGL wait");
        if (GL && GL->m_proc.eglDestroySyncKHR)
            GL->m_proc.eglDestroySyncKHR(m_flutter->eglDisplay, fence);
        return false;
    }

    bool CRuntime::waitForPendingSceneCopy() {
        if (!m_flutter || m_flutter->sceneCopyFence == EGL_NO_SYNC_KHR)
            return true;

        const auto* GL    = Render::GL::g_pHyprOpenGL.get();
        const auto  fence = std::exchange(m_flutter->sceneCopyFence, EGL_NO_SYNC_KHR);
        if (GL && GL->m_proc.eglWaitSyncKHR && GL->m_proc.eglDestroySyncKHR && GL->m_proc.eglWaitSyncKHR(m_flutter->eglDisplay, fence, 0) == EGL_TRUE) {
            GL->m_proc.eglDestroySyncKHR(m_flutter->eglDisplay, fence);
            return true;
        }

        DENIAL_HOT_LOG(Log::WARN, "Denial could not queue the scene-copy EGL wait; falling back to a blocking finish");
        if (!makeFlutterContextCurrent(m_flutter->eglDisplay, m_flutter->presentationContext, "scene copy wait fallback")) {
            m_flutter->sceneCopyFence = fence;
            return false;
        }
        glFinish();
        if (GL && GL->m_proc.eglDestroySyncKHR)
            GL->m_proc.eglDestroySyncKHR(m_flutter->eglDisplay, fence);
        return makeFlutterContextCurrent(m_flutter->eglDisplay, m_flutter->renderContext, "scene copy wait fallback restore");
    }

    void CRuntime::finishPendingSceneRender() {
        if (!m_flutter || m_flutter->sceneRenderFence == EGL_NO_SYNC_KHR)
            return;

        const auto fence = std::exchange(m_flutter->sceneRenderFence, EGL_NO_SYNC_KHR);
        if (makeFlutterContextCurrent(m_flutter->eglDisplay, m_flutter->renderContext, "scene render teardown"))
            glFinish();
        if (Render::GL::g_pHyprOpenGL && Render::GL::g_pHyprOpenGL->m_proc.eglDestroySyncKHR)
            Render::GL::g_pHyprOpenGL->m_proc.eglDestroySyncKHR(m_flutter->eglDisplay, fence);
    }

    void CRuntime::finishPendingSceneCopy() {
        if (!m_flutter || m_flutter->sceneCopyFence == EGL_NO_SYNC_KHR)
            return;

        const auto fence = std::exchange(m_flutter->sceneCopyFence, EGL_NO_SYNC_KHR);
        if (makeFlutterContextCurrent(m_flutter->eglDisplay, m_flutter->presentationContext, "scene copy teardown"))
            glFinish();
        if (Render::GL::g_pHyprOpenGL && Render::GL::g_pHyprOpenGL->m_proc.eglDestroySyncKHR)
            Render::GL::g_pHyprOpenGL->m_proc.eglDestroySyncKHR(m_flutter->eglDisplay, fence);
    }

    void CRuntime::fenceOrFinishSceneRender(SOutputFrame& frame, bool retainEglFence) {
        if (!m_flutter)
            return;

        const auto* GL = Render::GL::g_pHyprOpenGL.get();
        if (m_flutter->sceneRenderFence != EGL_NO_SYNC_KHR) {
            DENIAL_HOT_LOG(Log::WARN, "Denial render fence was not consumed before the next present; finishing conservatively");
            glFinish();
            if (GL && GL->m_proc.eglDestroySyncKHR)
                GL->m_proc.eglDestroySyncKHR(m_flutter->eglDisplay, m_flutter->sceneRenderFence);
            m_flutter->sceneRenderFence = EGL_NO_SYNC_KHR;
            return;
        }

        if (GL && GL->m_proc.eglCreateSyncKHR && GL->m_proc.eglDupNativeFenceFDANDROID && GL->m_proc.eglDestroySyncKHR) {
            const auto fence = GL->m_proc.eglCreateSyncKHR(m_flutter->eglDisplay, EGL_SYNC_NATIVE_FENCE_ANDROID, nullptr);
            if (fence != EGL_NO_SYNC_KHR) {
                glFlush();
                const int fd = GL->m_proc.eglDupNativeFenceFDANDROID(m_flutter->eglDisplay, fence);
                if (fd != EGL_NO_NATIVE_FENCE_FD_ANDROID) {
                    frame.renderCompletionFd = std::make_shared<Hyprutils::OS::CFileDescriptor>(fd);
                    if (retainEglFence)
                        m_flutter->sceneRenderFence = fence;
                    else
                        GL->m_proc.eglDestroySyncKHR(m_flutter->eglDisplay, fence);
                    return;
                }
                GL->m_proc.eglDestroySyncKHR(m_flutter->eglDisplay, fence);
            }
        }

        DENIAL_HOT_LOG(Log::WARN, "Denial could not create a Flutter-render EGL fence; falling back to glFinish");
        glFinish();
    }

    Hyprutils::OS::CFileDescriptor CRuntime::fenceOrFinishSceneCopy() {
        if (!m_flutter)
            return {};

        // Some legacy KMS backends cannot attach the native fence returned by
        // this function to their page-flip request. Those backends must opt in
        // explicitly so the canonical runtime remains asynchronous everywhere
        // that KMS input fences are available.
        if (m_options.forceBlockingSceneCopy) {
            glFinish();
            if (m_flutter->sceneCopyFence != EGL_NO_SYNC_KHR && Render::GL::g_pHyprOpenGL && Render::GL::g_pHyprOpenGL->m_proc.eglDestroySyncKHR)
                Render::GL::g_pHyprOpenGL->m_proc.eglDestroySyncKHR(m_flutter->eglDisplay, m_flutter->sceneCopyFence);
            m_flutter->sceneCopyFence = EGL_NO_SYNC_KHR;
            return {};
        }

        const auto* GL = Render::GL::g_pHyprOpenGL.get();
        if (m_flutter->sceneCopyFence != EGL_NO_SYNC_KHR) {
            // All output blits use this one presentation context. A new fence
            // therefore orders every earlier copy as well; the exported native
            // fd keeps the previous fence alive for the corresponding KMS
            // commit after the EGL handle is discarded here.
            if (GL && GL->m_proc.eglDestroySyncKHR)
                GL->m_proc.eglDestroySyncKHR(m_flutter->eglDisplay, m_flutter->sceneCopyFence);
            m_flutter->sceneCopyFence = EGL_NO_SYNC_KHR;
        }

        if (GL && GL->m_proc.eglCreateSyncKHR && GL->m_proc.eglDupNativeFenceFDANDROID && GL->m_proc.eglDestroySyncKHR) {
            const auto fence = GL->m_proc.eglCreateSyncKHR(m_flutter->eglDisplay, EGL_SYNC_NATIVE_FENCE_ANDROID, nullptr);
            if (fence != EGL_NO_SYNC_KHR) {
                glFlush();
                const int fd = GL->m_proc.eglDupNativeFenceFDANDROID(m_flutter->eglDisplay, fence);
                if (fd != EGL_NO_NATIVE_FENCE_FD_ANDROID) {
                    m_flutter->sceneCopyFence = fence;
                    return Hyprutils::OS::CFileDescriptor{fd};
                }
                GL->m_proc.eglDestroySyncKHR(m_flutter->eglDisplay, fence);
            }
        }

        DENIAL_HOT_LOG(Log::WARN, "Denial could not export a scene-copy native fence; falling back to glFinish");
        glFinish();
        return {};
    }

    void CRuntime::releaseSampledBuffersAfterRender(SOutputFrame& frame) {
        if (frame.renderCompletionFd && frame.renderCompletionFd->isValid() && g_pEventLoopManager) {
            if (m_flutter && m_flutter->sceneRenderFence != EGL_NO_SYNC_KHR) {
                if (Render::GL::g_pHyprOpenGL && Render::GL::g_pHyprOpenGL->m_proc.eglDestroySyncKHR)
                    Render::GL::g_pHyprOpenGL->m_proc.eglDestroySyncKHR(m_flutter->eglDisplay, m_flutter->sceneRenderFence);
                m_flutter->sceneRenderFence = EGL_NO_SYNC_KHR;
            }

            if (!frame.sampledBufferHolds.empty())
                g_pEventLoopManager->doOnReadable(std::move(*frame.renderCompletionFd), [holds = std::move(frame.sampledBufferHolds)]() mutable { holds.clear(); });
            return;
        }

        if (frame.renderCompletionFd && frame.renderCompletionFd->isValid()) {
            if (!frame.sampledBufferHolds.empty()) {
                std::lock_guard<std::mutex> lock(m_externalTextureMutex);
                m_deferredSampledBufferHolds.insert(m_deferredSampledBufferHolds.end(), std::make_move_iterator(frame.sampledBufferHolds.begin()),
                                                    std::make_move_iterator(frame.sampledBufferHolds.end()));
            }
            frame.sampledBufferHolds.clear();
            return;
        }

        releaseSampleHoldsOnMainThread(std::move(frame.sampledBufferHolds));
        frame.sampledBufferHolds.clear();
    }

    void CRuntime::releaseSampleHoldsOnMainThread(std::vector<SImportedFrameHold> holds) {
        if (holds.empty() || std::this_thread::get_id() == m_hyprThreadId)
            return;

        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            m_pendingSampleReleases.insert(m_pendingSampleReleases.end(), std::make_move_iterator(holds.begin()), std::make_move_iterator(holds.end()));
        }
        requestMainLoop(MAIN_LOOP_TEXTURE_MARK);
    }

    bool CRuntime::renderLatestOutputFrame(PHLMONITOR monitor, const CBox& captureBox, bool overlayCursor) {
        if (secureSessionLocked())
            return false;

        SScreenCopyFrame screenCopyFrame;
        {
            const auto* pipeline = monitor ? outputPipeline(monitor->m_id) : nullptr;
            if (!monitor || !pipeline || !g_pHyprRenderer || pipeline->latestScreenCopyFrame.texture == 0 || pipeline->latestScreenCopyFrame.monitorId != monitor->m_id ||
                pipeline->latestScreenCopyFrame.size.x < 1 || pipeline->latestScreenCopyFrame.size.y < 1 || pipeline->latestScreenCopyFrame.sourceRect.w < 1 ||
                pipeline->latestScreenCopyFrame.sourceRect.h < 1)
                return false;

            screenCopyFrame = pipeline->latestScreenCopyFrame;
        }

        const auto texture = makeShared<CBorrowedScreenCopyTexture>(screenCopyFrame.texture, screenCopyFrame.size);
        if (!texture || !texture->ok())
            return false;

        CBox       sourceBox = CBox{{}, screenCopyFrame.size}
                                   .transform(Math::wlTransformToHyprutils(Math::invertTransform(monitor->m_transform)), monitor->m_pixelSize.x, monitor->m_pixelSize.y)
                                   .translate(-screenCopyFrame.sourceRect.pos())
                                   .translate(-captureBox.pos());

        const auto OLD_RENDER_MODIF                       = g_pHyprRenderer->m_renderData.renderModif.enabled;
        g_pHyprRenderer->m_renderData.renderModif.enabled = false;
        g_pHyprRenderer->startRenderPass();
        g_pHyprRenderer->draw(
            CTexPassElement::SRenderData{
                .tex          = texture,
                .box          = sourceBox,
                .flipEndFrame = true,
                .cmBackToSRGB = true,
            },
            {0, 0, monitor->m_pixelSize.x, monitor->m_pixelSize.y});
        g_pHyprRenderer->m_renderData.renderModif.enabled = OLD_RENDER_MODIF;

        if (overlayCursor && g_pPointerManager && g_pInputManager) {
            CRegion  fakeDamage = {0, 0, INT16_MAX, INT16_MAX};
            Vector2D cursorPos  = g_pInputManager->getMouseCoordsInternal() - monitor->m_position - captureBox.pos() / monitor->m_scale;
            g_pPointerManager->renderSoftwareCursorsFor(monitor, Time::steadyNow(), fakeDamage, cursorPos, true);
        }

        // Complete the main-thread read before the next Flutter render can
        // reuse the single scene texture.
        glFinish();

        return true;
    }

    void CRuntime::resetOutputGraphicsForEngineRestart() {
        if (!m_flutter)
            return;

        destroySceneFramebuffers();

        for (auto& [monitorId, pipeline] : m_outputPipelines) {
            if (pipeline)
                pipeline->latestScreenCopyFrame = {};
        }

        if (makeFlutterContextCurrent(m_flutter->eglDisplay, m_flutter->presentationContext, "Flutter output presentation restart cleanup")) {
            const auto destroyPresentationResources = [](SOutputBufferTarget& target) {
                if (target.presentationFramebuffer != 0) {
                    const GLuint framebuffer = target.presentationFramebuffer;
                    glDeleteFramebuffers(1, &framebuffer);
                }
                if (target.presentationRenderbuffer != 0) {
                    const GLuint renderbuffer = target.presentationRenderbuffer;
                    glDeleteRenderbuffers(1, &renderbuffer);
                }
                if (target.presentationTexture != 0) {
                    const GLuint texture = target.presentationTexture;
                    glDeleteTextures(1, &texture);
                }
                target.presentationFramebuffer  = 0;
                target.presentationRenderbuffer = 0;
                target.presentationTexture      = 0;
            };

            for (auto& [monitorId, pipeline] : m_outputPipelines) {
                if (!pipeline)
                    continue;
                for (auto& target : pipeline->targets) {
                    if (target)
                        destroyPresentationResources(*target);
                }
            }
            for (auto& atlas : m_sharedAtlasTargets) {
                if (!atlas)
                    continue;
                destroyPresentationResources(atlas->renderTarget);
                for (auto& [monitorId, target] : atlas->outputTargets) {
                    if (target)
                        destroyPresentationResources(*target);
                }
            }
        }

        if (makeFlutterContextCurrent(m_flutter->eglDisplay, m_flutter->renderContext, "Flutter direct output restart cleanup")) {
            const auto destroyDirectResources = [](SOutputBufferTarget& target) {
                if (target.directRenderFramebuffer != 0) {
                    const GLuint framebuffer = target.directRenderFramebuffer;
                    glDeleteFramebuffers(1, &framebuffer);
                }
                if (target.directRenderTexture != 0) {
                    const GLuint texture = target.directRenderTexture;
                    glDeleteTextures(1, &texture);
                }
                target.directRenderFramebuffer = 0;
                target.directRenderTexture     = 0;
            };

            for (auto& [monitorId, pipeline] : m_outputPipelines) {
                if (!pipeline)
                    continue;
                for (auto& target : pipeline->targets) {
                    if (target)
                        destroyDirectResources(*target);
                }
            }
            for (auto& atlas : m_sharedAtlasTargets) {
                if (!atlas)
                    continue;
                destroyDirectResources(atlas->renderTarget);
                for (auto& [monitorId, target] : atlas->outputTargets) {
                    if (target)
                        destroyDirectResources(*target);
                }
            }
            destroyDeferredDirectRenderResources();
        }

        for (auto& [monitorId, pipeline] : m_outputPipelines) {
            if (!pipeline)
                continue;
            for (auto& target : pipeline->targets) {
                if (!target)
                    continue;
                destroyEGLImage(target->eglImage);
                target->eglImage                    = nullptr;
                target->presentationImportAttempted = false;
            }
        }
        for (auto& atlas : m_sharedAtlasTargets) {
            if (!atlas)
                continue;
            destroyEGLImage(atlas->renderTarget.eglImage);
            atlas->renderTarget.eglImage                    = nullptr;
            atlas->renderTarget.sceneGeneration             = 0;
            atlas->renderTarget.presentationImportAttempted = false;
            atlas->sceneGeneration                          = 0;
            for (auto& [monitorId, target] : atlas->outputTargets) {
                if (!target)
                    continue;
                destroyEGLImage(target->eglImage);
                target->eglImage                    = nullptr;
                target->sceneGeneration             = 0;
                target->presentationImportAttempted = false;
            }
        }

        // Do not leave a soon-to-be-destroyed Flutter context current on the
        // compositor thread. EGL otherwise defers its destruction until some
        // unrelated later context switch and can retain the atlas imports.
        if (eglMakeCurrent(m_flutter->eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT) != EGL_TRUE)
            Log::logger->log(Log::WARN, "Denial could not clear the Flutter EGL context after restart cleanup");
    }

    CRegion CRuntime::damageFromFlutterDamage(const DenialDamage& damage) {
        CRegion region;
        if (!damage.rects)
            return region;

        for (size_t i = 0; i < damage.num_rects; ++i) {
            const auto& rect = damage.rects[i];
            if (!std::isfinite(rect.left) || !std::isfinite(rect.top) || !std::isfinite(rect.right) || !std::isfinite(rect.bottom) || rect.right <= rect.left ||
                rect.bottom <= rect.top)
                continue;
            region.add(std::floor(rect.left), std::floor(rect.top), std::ceil(rect.right) - std::floor(rect.left), std::ceil(rect.bottom) - std::floor(rect.top));
        }
        return region;
    }

    bool CRuntime::onFlutterPresentWithInfo(void* userData, const DenialPresentInfo* info) {
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime)
            return false;
        if (!info) {
            runtime->finishFlutterRasterFrame();
            return false;
        }

        runtime->m_flutterProducerState.store(eFlutterProducerState::PREPARING, std::memory_order_release);
        bool presented = false;
        if (runtime->m_options.disableDamageTracking)
            presented = runtime->presentCurrentOutputFrame(info->fbo_id);
        else {
            auto damage = damageFromFlutterDamage(info->frame_damage);
            if (damage.empty() && info->buffer_damage.num_rects > 0)
                damage = damageFromFlutterDamage(info->buffer_damage);
            presented = runtime->presentCurrentOutputFrame(info->fbo_id, &damage);
        }

        runtime->finishFlutterRasterFrame();
        return presented;
    }

    size_t CRuntime::onFlutterExistingDamage(void* userData, intptr_t fboId, DenialRect* rects, size_t maxRects) {
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime)
            return 0;

        const auto& scene = runtime->m_sceneFramebuffer;
        if ((!runtime->m_options.disableDamageTracking && !scene.needsFullRepaint) || scene.framebuffer == 0 || scene.texture == 0 || scene.size.x < 1 || scene.size.y < 1 ||
            (fboId != 0 && sc<uint32_t>(fboId) != scene.framebuffer))
            return 0;

        if (rects && maxRects > 0) {
            rects[0] = DenialRect{
                .left   = 0,
                .top    = 0,
                .right  = scene.size.x,
                .bottom = scene.size.y,
            };
        }
        return 1;
    }

    bool CRuntime::onFlutterDirectPresentWithInfo(void* userData, const DenialPresentInfo* info) {
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime)
            return false;
        if (!info) {
            runtime->finishFlutterRasterFrame();
            return false;
        }

        runtime->m_flutterProducerState.store(eFlutterProducerState::PREPARING, std::memory_order_release);
        bool presented = false;
        if (runtime->m_options.disableDamageTracking)
            presented = runtime->presentDirectOutputFrame(info->fbo_id);
        else {
            auto damage = damageFromFlutterDamage(info->frame_damage);
            if (damage.empty() && info->buffer_damage.num_rects > 0)
                damage = damageFromFlutterDamage(info->buffer_damage);
            presented = runtime->presentDirectOutputFrame(info->fbo_id, &damage);
        }

        runtime->finishFlutterRasterFrame();
        return presented;
    }

    size_t CRuntime::onFlutterDirectExistingDamage(void* userData, intptr_t fboId, DenialRect* rects, size_t maxRects) {
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime || runtime->m_directTargetState.load(std::memory_order_acquire) != eDirectTargetState::READY || !runtime->m_directOutputTarget)
            return 0;

        const auto* target = runtime->m_directOutputTarget;
        if (target->directRenderFramebuffer == 0 || (fboId != 0 && sc<uint32_t>(fboId) != target->directRenderFramebuffer))
            return 0;

        if (runtime->m_options.disableDamageTracking) {
            if (rects && maxRects > 0) {
                rects[0] = DenialRect{
                    .left   = 0,
                    .top    = 0,
                    .right  = target->size.x,
                    .bottom = target->size.y,
                };
            }
            return 1;
        }

        const auto* viewport = runtime->outputViewport(runtime->m_directOutputMonitorId);
        if (!viewport)
            return 0;
        auto       damage          = runtime->outputDamageForTarget(*target, *viewport, runtime->m_sceneGeneration + 1);
        int        damageRectCount = 0;
        const auto damageRects     = pixman_region32_rectangles(damage.pixman(), &damageRectCount);
        if (rects) {
            const auto count = std::min(maxRects, sc<size_t>(damageRectCount));
            for (size_t i = 0; i < count; ++i) {
                rects[i] = DenialRect{
                    .left   = sc<double>(damageRects[i].x1),
                    .top    = sc<double>(damageRects[i].y1),
                    .right  = sc<double>(damageRects[i].x2),
                    .bottom = sc<double>(damageRects[i].y2),
                };
            }
        }
        return sc<size_t>(damageRectCount);
    }

    bool CRuntime::onFlutterSharedAtlasPresentWithInfo(void* userData, const DenialPresentInfo* info) {
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime)
            return false;
        if (!info) {
            runtime->finishFlutterRasterFrame();
            return false;
        }

        runtime->m_flutterProducerState.store(eFlutterProducerState::PREPARING, std::memory_order_release);
        bool presented = false;
        if (runtime->m_options.disableDamageTracking)
            presented = runtime->presentSharedAtlasFrame(info->fbo_id);
        else {
            auto damage = damageFromFlutterDamage(info->frame_damage);
            if (damage.empty() && info->buffer_damage.num_rects > 0)
                damage = damageFromFlutterDamage(info->buffer_damage);
            presented = runtime->presentSharedAtlasFrame(info->fbo_id, &damage);
        }

        runtime->finishFlutterRasterFrame();
        return presented;
    }

    size_t CRuntime::onFlutterSharedAtlasExistingDamage(void* userData, intptr_t fboId, DenialRect* rects, size_t maxRects) {
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime || runtime->m_sharedAtlasTargetState.load(std::memory_order_acquire) != eDirectTargetState::READY || !runtime->m_sharedAtlasRenderTarget)
            return 0;

        const auto& atlas  = *runtime->m_sharedAtlasRenderTarget;
        const auto& target = atlas.renderTarget;
        if (target.directRenderFramebuffer == 0 || (fboId != 0 && sc<uint32_t>(fboId) != target.directRenderFramebuffer))
            return 0;

        CRegion       damage;
        const CRegion full{0, 0, target.size.x, target.size.y};
        if (runtime->m_options.disableDamageTracking || atlas.sceneGeneration == 0 || runtime->m_sceneDamageHistory.empty() ||
            atlas.sceneGeneration + 1 < runtime->m_sceneDamageHistory.front().generation) {
            damage = full;
        } else {
            for (const auto& entry : runtime->m_sceneDamageHistory) {
                if (entry.generation > atlas.sceneGeneration && entry.generation <= runtime->m_sceneGeneration)
                    damage.add(entry.damage);
            }
            damage.intersect(0, 0, target.size.x, target.size.y);
        }

        int        damageRectCount = 0;
        const auto damageRects     = pixman_region32_rectangles(damage.pixman(), &damageRectCount);
        if (rects) {
            const auto count = std::min(maxRects, sc<size_t>(damageRectCount));
            for (size_t i = 0; i < count; ++i) {
                rects[i] = DenialRect{
                    .left   = sc<double>(damageRects[i].x1),
                    .top    = sc<double>(damageRects[i].y1),
                    .right  = sc<double>(damageRects[i].x2),
                    .bottom = sc<double>(damageRects[i].y2),
                };
            }
        }
        return sc<size_t>(damageRectCount);
    }

    uint32_t CRuntime::onFlutterFBO(void* userData) {
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime)
            return 0;

        return runtime->ensureCurrentSceneFramebuffer();
    }

    uint32_t CRuntime::onFlutterDirectFBO(void* userData) {
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime)
            return 0;

        auto state = runtime->m_directTargetState.load(std::memory_order_acquire);
        if (state == eDirectTargetState::IDLE) {
            auto expected = eDirectTargetState::IDLE;
            if (runtime->m_directTargetState.compare_exchange_strong(expected, eDirectTargetState::ACQUIRING, std::memory_order_acq_rel, std::memory_order_acquire)) {
                if (!runtime->requestMainLoop(MAIN_LOOP_PREPARE_DIRECT_TARGET)) {
                    runtime->m_directTargetState.store(eDirectTargetState::FAILED, std::memory_order_release);
                    runtime->m_directTargetState.notify_one();
                }
            }
        }

        runtime->m_directTargetState.wait(eDirectTargetState::ACQUIRING, std::memory_order_acquire);
        state = runtime->m_directTargetState.load(std::memory_order_acquire);
        if (state != eDirectTargetState::READY || !runtime->m_directOutputTarget) {
            auto failed = eDirectTargetState::FAILED;
            runtime->m_directTargetState.compare_exchange_strong(failed, eDirectTargetState::IDLE, std::memory_order_release, std::memory_order_relaxed);
            return 0;
        }

        if (!runtime->ensureOutputTargetDirectFramebuffer(*runtime->m_directOutputTarget)) {
            runtime->m_directTargetState.store(eDirectTargetState::FAILED, std::memory_order_release);
            runtime->requestMainLoop(MAIN_LOOP_CANCEL_DIRECT_TARGET);
            return 0;
        }
        return runtime->m_directOutputTarget->directRenderFramebuffer;
    }

    uint32_t CRuntime::onFlutterSharedAtlasFBO(void* userData) {
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime || !runtime->m_sharedAtlasScanoutActive.load(std::memory_order_acquire))
            return 0;

        auto state = runtime->m_sharedAtlasTargetState.load(std::memory_order_acquire);
        if (state == eDirectTargetState::IDLE) {
            auto expected = eDirectTargetState::IDLE;
            if (runtime->m_sharedAtlasTargetState.compare_exchange_strong(expected, eDirectTargetState::ACQUIRING, std::memory_order_acq_rel, std::memory_order_acquire)) {
                if (!runtime->requestMainLoop(MAIN_LOOP_PREPARE_ATLAS_TARGET)) {
                    runtime->m_sharedAtlasTargetState.store(eDirectTargetState::FAILED, std::memory_order_release);
                    runtime->m_sharedAtlasTargetState.notify_one();
                }
            }
        }

        runtime->m_sharedAtlasTargetState.wait(eDirectTargetState::ACQUIRING, std::memory_order_acquire);
        state = runtime->m_sharedAtlasTargetState.load(std::memory_order_acquire);
        if (state != eDirectTargetState::READY || !runtime->m_sharedAtlasRenderTarget) {
            auto failed = eDirectTargetState::FAILED;
            runtime->m_sharedAtlasTargetState.compare_exchange_strong(failed, eDirectTargetState::IDLE, std::memory_order_release, std::memory_order_relaxed);
            return 0;
        }

        auto& target = runtime->m_sharedAtlasRenderTarget->renderTarget;
        if (!runtime->ensureOutputTargetDirectFramebuffer(target)) {
            runtime->disableSharedAtlasScanout("Flutter could not import the scanout atlas as a render target");
            return 0;
        }
        return target.directRenderFramebuffer;
    }

} // namespace Denial
