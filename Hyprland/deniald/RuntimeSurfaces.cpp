#include "Runtime.hpp"
#include "ClosingTextureLease.hpp"
#include "ResizeTextureHandoff.hpp"
#include "RuntimeEGL.hpp"
#include "RuntimeFlutterState.hpp"
#include "RuntimeInternal.hpp"

#include "Wire.hpp"

#include "../src/debug/log/Logger.hpp"
#include "../src/desktop/view/Window.hpp"
#include "../src/managers/eventLoop/EventLoopManager.hpp"
#include "../src/managers/eventLoop/EventLoopTimer.hpp"
#include "../src/render/OpenGL.hpp"

#include <aquamarine/backend/DRM.hpp>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#include <drm_fourcc.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <optional>
#include <ranges>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace Denial {

#if defined(DENIAL_ENABLE_DIAGNOSTICS)
    using RuntimeInternal::IMPORTED_FRAME_TIMING_BUCKET_US;
    using RuntimeInternal::IMPORTED_FRAME_TIMING_CHANNEL;
    using RuntimeInternal::IMPORTED_FRAME_TIMING_IDLE_FRAMES;
    using RuntimeInternal::IMPORTED_FRAME_TIMING_MESSAGE_SIZE;
#endif
    using RuntimeInternal::IMPORTED_FRAME_QUEUE_DEPTH;
    using RuntimeInternal::inputLayoutFromBuffer;
    using RuntimeInternal::makeFlutterContextCurrent;
    using RuntimeInternal::readUint64LE;
    using RuntimeInternal::steadyUs;
    using RuntimeInternal::writeUint64LE;

    namespace {
        struct SWindowResizeTarget {
            ResizeTextureHandoff::SSize target;
            ResizeTextureHandoff::SSize source;
        };

        void clearResizeTextureHandoff(auto& record) {
            record.resizeHandoffComplete     = false;
            record.resizeTargetWidth         = 0.0;
            record.resizeTargetHeight        = 0.0;
            record.resizeSourceWidth         = 0.0;
            record.resizeSourceHeight        = 0.0;
            record.resizeHandoffDeadlineUs   = 0;
            record.resizeCandidateSinceUs    = 0;
            record.resizeCandidateGeneration = 0;
            record.resizeHandoffWakeUs       = 0;
        }

        bool resizeTextureHandoffDeferred(const auto& record, uint64_t nowUs) {
            return !record.resizeHandoffComplete && record.resizeHandoffWakeUs > nowUs;
        }
    } // namespace

    void CRuntime::onSurfaceFrame(SSurfaceFrameRef frame) {
#if defined(DENIAL_ENABLE_DIAGNOSTICS)
        if (m_importedFrameTimingEnabled.load(std::memory_order_acquire) && frame.renderDurationUs > 0)
            recordImportedFrameTiming(frame.surfaceId, frame.generation, frame.renderDurationUs, steadyUs());
#endif
        importSurfaceFrame(std::move(frame));
    }

    void CRuntime::onSurfaceFrameCallbackDemand() {
        requestMainLoop(MAIN_LOOP_OUTPUT_FRAME);
    }

    void CRuntime::onSurfaceGone(TSurfaceId surfaceId, TWindowId windowId) {
        (void)windowId;
        destroySurfaceTexture(surfaceId);
    }

    void CRuntime::onWindowGone(TWindowId windowId, const std::vector<TSurfaceId>& surfaceIds) {
        leaseWindowTextures(windowId, surfaceIds);
    }

    bool CRuntime::canImportClientBuffer(const Aquamarine::SDMABUFAttrs& attrs) {
        if (!attrs.success || attrs.size.x < 1 || attrs.size.y < 1 || attrs.planes < 1 || attrs.planes > 4)
            return false;

        for (int i = 0; i < attrs.planes; ++i) {
            if (attrs.fds[i] < 0 || attrs.strides[i] == 0)
                return false;
        }

        return true;
    }

    bool CRuntime::canSampleAsFlutterTexture(const Aquamarine::SDMABUFAttrs& attrs) {
        return canImportClientBuffer(attrs);
    }

#if defined(DENIAL_ENABLE_DIAGNOSTICS)
    void CRuntime::recordImportedFrameTiming(TSurfaceId surfaceId, uint64_t generation, uint64_t renderDurationUs, uint64_t timestampUs) {
        if (!m_importedFrameTimingEnabled.load(std::memory_order_acquire) || renderDurationUs == 0)
            return;

        if (m_importedFrameTimingResetRequested.exchange(false, std::memory_order_acq_rel))
            m_importedFrameTimings.clear();

        auto& timing = m_importedFrameTimings[surfaceId];
        if (generation <= timing.lastGeneration)
            return;

        if (timing.bucketStartUs == 0)
            timing.bucketStartUs = timestampUs;
        timing.lastGeneration = generation;

        const auto budgetUs = std::max<uint64_t>(1000, m_importedFrameTimingBudgetUs.load(std::memory_order_relaxed));

        const auto flushBucket = [&]() {
            if (timing.sampleCount == 0)
                return;

            const auto                                              averageRenderUs = timing.totalRenderUs / timing.sampleCount;
            std::array<uint8_t, IMPORTED_FRAME_TIMING_MESSAGE_SIZE> payload         = {};
            writeUint64LE(payload.data() + sizeof(uint64_t) * 0, surfaceId);
            writeUint64LE(payload.data() + sizeof(uint64_t) * 1, generation);
            writeUint64LE(payload.data() + sizeof(uint64_t) * 2, timestampUs);
            writeUint64LE(payload.data() + sizeof(uint64_t) * 3, averageRenderUs);
            writeUint64LE(payload.data() + sizeof(uint64_t) * 4, timing.peakRenderUs);
            writeUint64LE(payload.data() + sizeof(uint64_t) * 5, timing.sampleCount);
            writeUint64LE(payload.data() + sizeof(uint64_t) * 6, timing.overBudget);

            if (m_importedFrameTimingEnabled.load(std::memory_order_relaxed) && m_flutter && denial_engine_host_running(m_flutter->host))
                denial_engine_host_send_platform_message(m_flutter->host, IMPORTED_FRAME_TIMING_CHANNEL, payload.data(), payload.size());

            timing.bucketStartUs = timestampUs;
            timing.totalRenderUs = 0;
            timing.peakRenderUs  = 0;
            timing.sampleCount   = 0;
            timing.overBudget    = 0;
        };

        // Generic Wayland clients may keep a frame callback outstanding while
        // otherwise idle. That callback-to-commit gap is sleep time, not render
        // work, so exclude it while preserving any active partial bucket.
        if (renderDurationUs > budgetUs * IMPORTED_FRAME_TIMING_IDLE_FRAMES) {
            flushBucket();
            timing.bucketStartUs = timestampUs;
            return;
        }

        timing.totalRenderUs += renderDurationUs;
        timing.peakRenderUs = std::max(timing.peakRenderUs, renderDurationUs);
        timing.sampleCount++;
        if (renderDurationUs > budgetUs)
            timing.overBudget++;

        if (timestampUs - timing.bucketStartUs < IMPORTED_FRAME_TIMING_BUCKET_US)
            return;

        flushBucket();
    }
#endif

    uint32_t CRuntime::advanceQueuedImportedFrames() {
        struct SRetiredImage {
            int64_t               textureId = -1;
            TImportedBufferId     bufferId  = 0;
            SP<IHLBuffer>         sourceBuffer;
            std::shared_ptr<void> imageLifetime;
        };

        std::shared_ptr<const std::vector<uint8_t>> layoutBuffer;
        {
            std::lock_guard<std::mutex> lock(m_inputRegionMutex);
            layoutBuffer = m_inputLayoutBuffer;
        }
        const auto*                                        layout = inputLayoutFromBuffer(layoutBuffer);

        const bool                                         allSurfacesExpected = !layout || (layout->flags() & BridgeWire::INPUT_LAYOUT_EXCLUSIVE_SHELL) != 0;
        std::unordered_set<TSurfaceId>                     visibleSurfaces;
        std::unordered_map<TWindowId, SWindowResizeTarget> resizeTargets;
        if (layout && layout->windows()) {
            resizeTargets.reserve(layout->windows()->size());
            for (const auto* window : *layout->windows()) {
                if (!window || window->window_id() == 0 || window->surface_id() == 0 || window->surface_id() != window->object_id())
                    continue;

                const SWindowResizeTarget target{
                    .target = {.width = window->rect().width(), .height = window->rect().height()},
                    .source = {.width = window->source_rect().width(), .height = window->source_rect().height()},
                };
                if (ResizeTextureHandoff::valid(target.target) && ResizeTextureHandoff::valid(target.source))
                    resizeTargets[window->window_id()] = target;
            }
        }
        if (!allSurfacesExpected) {
            if (const auto* visibleSurfaceIds = layout->visible_surface_ids(); visibleSurfaceIds && !visibleSurfaceIds->empty()) {
                visibleSurfaces.reserve(visibleSurfaceIds->size());
                for (const auto surfaceId : *visibleSurfaceIds) {
                    if (surfaceId != 0)
                        visibleSurfaces.emplace(surfaceId);
                }
            } else if (layout->windows()) {
                visibleSurfaces.reserve(layout->windows()->size());
                for (const auto* window : *layout->windows()) {
                    if (window && (window->flags() & BridgeWire::INPUT_WINDOW_VISIBLE) != 0 && window->surface_id() != 0)
                        visibleSurfaces.emplace(window->surface_id());
                }
            }
        }

        std::vector<std::pair<TSurfaceId, int64_t>>              marks;
        std::vector<SRetiredImage>                               retiredImages;
        std::vector<TImportedBufferHold>                         discardedQueuedBuffers;
        std::vector<std::shared_ptr<const std::vector<uint8_t>>> discardedPixelBuffers;
        uint32_t                                                 advanced              = 0;
        bool                                                     windowMetadataChanged = false;
        bool                                                     dragIconMetadataChanged = false;
        const auto                                               nowUs                 = steadyUs();
        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            marks.reserve(m_externalTextures.size());

            const auto retireImageIfUnused = [&](auto& record, TImportedBufferId bufferId) {
                if (bufferId == 0 || bufferId == record.currentBufferId)
                    return;

                const bool stillQueued = std::ranges::any_of(record.pendingFrames, [bufferId](const auto& pending) { return pending.bufferId == bufferId; });
                const auto image       = record.images.find(bufferId);
                if (stillQueued || image == record.images.end() || !image->second.sourceDestroyed)
                    return;

                retiredImages.emplace_back(SRetiredImage{
                    .textureId     = record.textureId,
                    .bufferId      = bufferId,
                    .sourceBuffer  = std::move(image->second.sourceBuffer),
                    .imageLifetime = std::move(image->second.eglImageLifetime),
                });
                record.images.erase(image);
            };

            const auto discardOldEglFrames = [&](auto& record) {
                while (record.pendingFrames.size() > 1) {
                    auto dropped = std::move(record.pendingFrames.front());
                    record.pendingFrames.pop_front();
                    if (dropped.buffer)
                        discardedQueuedBuffers.emplace_back(std::move(dropped.buffer));
                    retireImageIfUnused(record, dropped.bufferId);
                }
            };

            const auto discardOldPixelFrames = [&](auto& record) {
                while (record.pendingPixelFrames.size() > 1) {
                    auto dropped = std::move(record.pendingPixelFrames.front());
                    record.pendingPixelFrames.pop_front();
                    if (dropped.pixels)
                        discardedPixelBuffers.emplace_back(std::move(dropped.pixels));
                }
            };

            for (auto& [surfaceId, recordPtr] : m_externalTextures) {
                if (!recordPtr || recordPtr->closing)
                    continue;

                auto& record = *recordPtr;
                if (record.textureId < 0)
                    continue;

                // Never replace a generation that a previously granted
                // Flutter frame has not sampled yet. Off-scene textures are
                // mailboxed instead: Flutter has no pending sample to protect,
                // and advancing them is what releases buffers back to a live
                // minimized client. Opening overview makes the whole scene
                // sampleable again and immediately receives the latest generation.
                const bool expectsFlutterSample = record.dragIcon || allSurfacesExpected || visibleSurfaces.contains(surfaceId);
                bool       resizeHandoffActive  = false;
                if (expectsFlutterSample && record.currentGeneration != 0 && record.popupRootSurfaceId == 0) {
                    const auto resizeTarget = resizeTargets.find(record.windowId);
                    if (resizeTarget != resizeTargets.end() && ResizeTextureHandoff::resizeActive(resizeTarget->second.target, resizeTarget->second.source)) {
                        const ResizeTextureHandoff::SSize previousTarget{.width = record.resizeTargetWidth, .height = record.resizeTargetHeight};
                        const ResizeTextureHandoff::SSize previousSource{.width = record.resizeSourceWidth, .height = record.resizeSourceHeight};
                        const bool                        changed = !ResizeTextureHandoff::approximatelyEqual(previousTarget, resizeTarget->second.target) ||
                            !ResizeTextureHandoff::approximatelyEqual(previousSource, resizeTarget->second.source);
                        if (changed) {
                            record.resizeTargetWidth         = resizeTarget->second.target.width;
                            record.resizeTargetHeight        = resizeTarget->second.target.height;
                            record.resizeSourceWidth         = resizeTarget->second.source.width;
                            record.resizeSourceHeight        = resizeTarget->second.source.height;
                            record.resizeHandoffDeadlineUs   = nowUs + ResizeTextureHandoff::MAX_WAIT_US;
                            record.resizeCandidateSinceUs    = 0;
                            record.resizeCandidateGeneration = 0;
                            record.resizeHandoffComplete     = false;
                        }
                        record.resizeHandoffWakeUs = 0;
                        resizeHandoffActive        = !record.resizeHandoffComplete;
                    } else {
                        clearResizeTextureHandoff(record);
                    }
                } else {
                    clearResizeTextureHandoff(record);
                }

                if (expectsFlutterSample && record.currentGeneration != 0 && record.lastSampledGeneration < record.currentGeneration)
                    continue;

                if (record.textureKind == eExternalTextureKind::PIXEL_BUFFER) {
                    if (record.pendingPixelFrames.empty())
                        continue;

                    if (resizeHandoffActive) {
                        const auto& newest  = record.pendingPixelFrames.back();
                        const bool  matches = ResizeTextureHandoff::surfaceMatchesTarget(
                            {.width = record.surfaceWidth, .height = record.surfaceHeight}, {.width = newest.surfaceWidth, .height = newest.surfaceHeight},
                            {.width = record.resizeTargetWidth, .height = record.resizeTargetHeight}, {.width = record.resizeSourceWidth, .height = record.resizeSourceHeight});
                        if (matches) {
                            if (record.resizeCandidateSinceUs == 0) {
                                const auto handoffStartedUs   = record.resizeHandoffDeadlineUs - ResizeTextureHandoff::MAX_WAIT_US;
                                record.resizeCandidateSinceUs = std::max(handoffStartedUs, newest.acceptedAtUs);
                            }
                            record.resizeCandidateGeneration = newest.generation;
                        } else {
                            record.resizeCandidateSinceUs    = 0;
                            record.resizeCandidateGeneration = 0;
                        }

                        if (!ResizeTextureHandoff::candidateReady(record.resizeCandidateSinceUs, record.resizeHandoffDeadlineUs, nowUs)) {
                            record.resizeHandoffWakeUs = ResizeTextureHandoff::nextWakeUs(record.resizeCandidateSinceUs, record.resizeHandoffDeadlineUs);
                            continue;
                        }

                        record.resizeHandoffComplete = true;
                        record.resizeHandoffWakeUs   = 0;
                        discardOldPixelFrames(record);
                    }

                    auto queued = std::move(record.pendingPixelFrames.front());
                    record.pendingPixelFrames.pop_front();
                    if (queued.generation <= record.currentGeneration || !queued.pixels)
                        continue;

                    const bool metadataChanged = record.width != queued.width || record.height != queued.height || record.transform != queued.transform ||
                        record.scale120 != queued.scale120 || record.stackingOrder != queued.stackingOrder || record.surfaceX != queued.surfaceX ||
                        record.surfaceY != queued.surfaceY || record.surfaceWidth != queued.surfaceWidth || record.surfaceHeight != queued.surfaceHeight ||
                        record.textureSourceX != queued.textureSourceX || record.textureSourceY != queued.textureSourceY ||
                        record.textureSourceWidth != queued.textureSourceWidth || record.textureSourceHeight != queued.textureSourceHeight ||
                        record.parentSurfaceId != queued.parentSurfaceId || record.popupRootSurfaceId != queued.popupRootSurfaceId || record.surfaceRole != queued.surfaceRole;
                    record.currentPixelBuffer  = std::move(queued.pixels);
                    record.currentPixelWidth   = queued.width;
                    record.currentPixelHeight  = queued.height;
                    record.currentGeneration   = queued.generation;
                    record.width               = queued.width;
                    record.height              = queued.height;
                    record.transform           = queued.transform;
                    record.scale120            = queued.scale120;
                    record.stackingOrder       = queued.stackingOrder;
                    record.surfaceX            = queued.surfaceX;
                    record.surfaceY            = queued.surfaceY;
                    record.surfaceWidth        = queued.surfaceWidth;
                    record.surfaceHeight       = queued.surfaceHeight;
                    record.textureSourceX      = queued.textureSourceX;
                    record.textureSourceY      = queued.textureSourceY;
                    record.textureSourceWidth  = queued.textureSourceWidth;
                    record.textureSourceHeight = queued.textureSourceHeight;
                    record.parentSurfaceId     = queued.parentSurfaceId;
                    record.popupRootSurfaceId  = queued.popupRootSurfaceId;
                    record.surfaceRole         = queued.surfaceRole;
                    if (metadataChanged) {
                        if (record.dragIcon)
                            dragIconMetadataChanged = true;
                        else
                            windowMetadataChanged = true;
                    }
                    if (!record.notificationArmed) {
                        record.notificationArmed = true;
                        marks.emplace_back(surfaceId, record.textureId);
                    }
                    advanced++;
                    continue;
                }

                if (record.pendingFrames.empty())
                    continue;

                if (resizeHandoffActive) {
                    const auto& newest  = record.pendingFrames.back();
                    const bool  matches = ResizeTextureHandoff::surfaceMatchesTarget(
                        {.width = record.surfaceWidth, .height = record.surfaceHeight}, {.width = newest.surfaceWidth, .height = newest.surfaceHeight},
                        {.width = record.resizeTargetWidth, .height = record.resizeTargetHeight}, {.width = record.resizeSourceWidth, .height = record.resizeSourceHeight});
                    if (matches) {
                        if (record.resizeCandidateSinceUs == 0) {
                            const auto handoffStartedUs   = record.resizeHandoffDeadlineUs - ResizeTextureHandoff::MAX_WAIT_US;
                            record.resizeCandidateSinceUs = std::max(handoffStartedUs, newest.acceptedAtUs);
                        }
                        record.resizeCandidateGeneration = newest.generation;
                    } else {
                        record.resizeCandidateSinceUs    = 0;
                        record.resizeCandidateGeneration = 0;
                    }

                    if (!ResizeTextureHandoff::candidateReady(record.resizeCandidateSinceUs, record.resizeHandoffDeadlineUs, nowUs)) {
                        record.resizeHandoffWakeUs = ResizeTextureHandoff::nextWakeUs(record.resizeCandidateSinceUs, record.resizeHandoffDeadlineUs);
                        continue;
                    }

                    record.resizeHandoffComplete = true;
                    record.resizeHandoffWakeUs   = 0;
                    discardOldEglFrames(record);
                }

                auto queued = std::move(record.pendingFrames.front());
                record.pendingFrames.pop_front();

                // Queue order is monotonic. Never let a delayed or duplicate
                // record move a texture backwards.
                if (queued.generation <= record.currentGeneration)
                    continue;

                if (!record.images.contains(queued.bufferId))
                    continue;

                const bool metadataChanged = record.width != queued.width || record.height != queued.height || record.transform != queued.transform ||
                    record.scale120 != queued.scale120 || record.stackingOrder != queued.stackingOrder || record.surfaceX != queued.surfaceX ||
                    record.surfaceY != queued.surfaceY || record.surfaceWidth != queued.surfaceWidth || record.surfaceHeight != queued.surfaceHeight ||
                    record.textureSourceX != queued.textureSourceX || record.textureSourceY != queued.textureSourceY || record.textureSourceWidth != queued.textureSourceWidth ||
                    record.textureSourceHeight != queued.textureSourceHeight || record.parentSurfaceId != queued.parentSurfaceId ||
                    record.popupRootSurfaceId != queued.popupRootSurfaceId || record.surfaceRole != queued.surfaceRole;
                const auto previousBufferId = record.currentBufferId;
                record.currentBufferId      = queued.bufferId;
                record.currentGeneration    = queued.generation;
                record.currentBufferHold    = std::move(queued.buffer);
                record.width                = queued.width;
                record.height               = queued.height;
                record.transform            = queued.transform;
                record.scale120             = queued.scale120;
                record.stackingOrder        = queued.stackingOrder;
                record.surfaceX             = queued.surfaceX;
                record.surfaceY             = queued.surfaceY;
                record.surfaceWidth         = queued.surfaceWidth;
                record.surfaceHeight        = queued.surfaceHeight;
                record.textureSourceX       = queued.textureSourceX;
                record.textureSourceY       = queued.textureSourceY;
                record.textureSourceWidth   = queued.textureSourceWidth;
                record.textureSourceHeight  = queued.textureSourceHeight;
                record.parentSurfaceId      = queued.parentSurfaceId;
                record.popupRootSurfaceId   = queued.popupRootSurfaceId;
                record.surfaceRole          = queued.surfaceRole;
                if (metadataChanged) {
                    if (record.dragIcon)
                        dragIconMetadataChanged = true;
                    else
                        windowMetadataChanged = true;
                }
                if (!record.notificationArmed) {
                    // Admission normally primes this request before the KMS
                    // edge. This fallback only recovers a failed notification;
                    // a shell baton has already been reserved for this tick.
                    record.notificationArmed = true;
                    marks.emplace_back(surfaceId, record.textureId);
                }
                advanced++;

                if (previousBufferId == 0 || previousBufferId == record.currentBufferId)
                    continue;

                retireImageIfUnused(record, previousBufferId);
            }
        }

        // CHLBufferReference destruction may emit wl_buffer.release. Keep it
        // on the compositor thread, but never run it while holding the texture
        // map lock. Pixel storage can likewise be large enough to avoid freeing
        // it in that critical section.
        discardedQueuedBuffers.clear();
        discardedPixelBuffers.clear();

        for (auto& retired : retiredImages) {
            if (m_flutter && retired.textureId >= 0)
                denial_engine_host_retire_external_texture_image(m_flutter->host, retired.textureId, retired.bufferId);
            retired.imageLifetime.reset();
            retired.sourceBuffer.reset();
        }

        if (windowMetadataChanged)
            notifyWindowObjectsChanged();
        if (dragIconMetadataChanged)
            publishDragIconState();

        bool retry = false;
        for (const auto& [surfaceId, textureId] : marks)
            retry = !markExternalTextureFrameAvailable(surfaceId, textureId) || retry;

        if (retry)
            requestMainLoop(MAIN_LOOP_OUTPUT_FRAME);

        armResizeTextureHandoffTimer();

        return advanced;
    }

    bool CRuntime::importSurfaceFrame(SSurfaceFrameRef frame) {
        if (frame.rgbaPixels)
            return importPixelSurfaceFrame(std::move(frame));

        if (!m_acceptTextureMarks.load(std::memory_order_acquire) || !m_flutter || !denial_engine_host_running(m_flutter->host) || (!frame.window && !frame.dragIcon) || !frame.buffer ||
            !frame.buffer.m_buffer)
            return false;

        if (!canImportClientBuffer(frame.dmabuf) || !canSampleAsFlutterTexture(frame.dmabuf))
            return false;

        if (!Render::GL::g_pHyprOpenGL)
            return false;

        // A wl_surface address can eventually be reused. Never let a new
        // client inherit the external-texture cookie retained by an old close
        // animation; the bounded old lease is the graceful fallback victim.
        releaseClosingTextureLeaseForSurface(frame.surfaceId);

        // Construct the sole Hyprland buffer reference for this queued frame
        // on the Wayland thread. The raster thread may retain the surrounding
        // std::shared_ptr, but must never copy CHLBufferReference itself: its
        // underlying Hyprutils shared pointer has a non-atomic control block.
        auto                    queuedBufferHold = std::make_shared<CHLBufferReference>(frame.buffer);
        const auto              BUFFER_KEY       = frame.buffer.m_buffer.get();
        const auto              acceptedAtUs     = steadyUs();
        const auto              outputTick       = m_outputTickSerial.load(std::memory_order_acquire);
        const auto              intervalUs       = outputTick == 0 ? importedFrameIntervalUs() : 0;

        bool                    needsImage          = false;
        bool                    shouldNotify        = false;
        bool                    shouldPrime         = false;
        bool                    replacePendingFrame = false;
        SExternalTextureCookie* cookie              = nullptr;
        int64_t                 textureId           = -1;
        TImportedBufferId       bufferId            = 0;
        TImportedBufferId       retiredBufferId     = 0;
        SP<IHLBuffer>           retiredSourceBuffer;
        std::shared_ptr<void>   retiredImageLifetime;

        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            auto&                       record = m_externalTextures[frame.surfaceId];
            if (!record) {
                record                    = std::make_unique<SSurfaceTextureObject>();
                record->surfaceId         = frame.surfaceId;
                record->cookie            = std::make_unique<SExternalTextureCookie>();
                record->cookie->runtime   = this;
                record->cookie->surfaceId = frame.surfaceId;
            }
            if (record->textureKind == eExternalTextureKind::PIXEL_BUFFER)
                return false;
            record->textureKind = eExternalTextureKind::EGL_IMAGE;
            record->dragIcon    = frame.dragIcon;

            // Admission is phase-locked to the arbiter. Multiple commits in
            // one output tick form a mailbox: keep the newest queued commit
            // instead of rejecting it. Rejecting the newest commit can retain
            // every image of a two-buffer client (one in currentBufferHold and
            // one in the Wayland surface), permanently blocking its release
            // timeline before the following output tick can advance it.
            const bool sameOutputTick = outputTick != 0 && record->lastAcceptedOutputTick == outputTick;
            const bool bootstrapBurst =
                outputTick == 0 && record->lastAcceptedFrameUs != 0 && (acceptedAtUs <= record->lastAcceptedFrameUs || acceptedAtUs - record->lastAcceptedFrameUs < intervalUs);
            replacePendingFrame = (sameOutputTick || bootstrapBurst) && !record->pendingFrames.empty();

            record->lastAcceptedFrameUs    = acceptedAtUs;
            record->lastAcceptedOutputTick = outputTick;

            if (auto existing = record->bufferIdsBySource.find(BUFFER_KEY); existing != record->bufferIdsBySource.end())
                bufferId = existing->second;
            else
                needsImage = true;

            cookie    = record->cookie.get();
            textureId = record->textureId;
        }

        void* eglImage = nullptr;
        if (needsImage) {
            const auto IMAGE = Render::GL::g_pHyprOpenGL->createEGLImage(frame.dmabuf);
            if (IMAGE == EGL_NO_IMAGE_KHR) {
                DENIAL_HOT_LOG(Log::ERR, "Denial failed to import dmabuf as EGLImage for surface {}", frame.surfaceId);
                return false;
            }
            eglImage = rc<void*>(IMAGE);
        }

        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            const auto                  recordIt = m_externalTextures.find(frame.surfaceId);
            if (recordIt == m_externalTextures.end() || !recordIt->second) {
                destroyEGLImage(eglImage);
                return false;
            }
            auto&      record = recordIt->second;

            const auto existingBuffer = record->bufferIdsBySource.find(BUFFER_KEY);
            if (eglImage && existingBuffer == record->bufferIdsBySource.end()) {
                bufferId = record->nextBufferId++;

                SImportedBufferImage imported;
                imported.bufferId         = bufferId;
                imported.sourceKey        = BUFFER_KEY;
                imported.sourceBuffer     = frame.buffer.m_buffer;
                imported.eglImageLifetime = adoptEGLImage(eglImage);
                if (!imported.eglImageLifetime) {
                    destroyEGLImage(eglImage);
                    return false;
                }
                imported.eglImage = eglImage;
                imported.width    = frame.width;
                imported.height   = frame.height;
                imported.destroy  = frame.buffer->events.destroy.listen([this, surfaceId = frame.surfaceId, bufferId] { destroyImportedBufferImage(surfaceId, bufferId); });

                record->bufferIdsBySource.emplace(BUFFER_KEY, bufferId);
                record->images.emplace(bufferId, std::move(imported));
                eglImage = nullptr;
            } else if (existingBuffer != record->bufferIdsBySource.end()) {
                bufferId = existingBuffer->second;
            }

            if (bufferId == 0) {
                destroyEGLImage(eglImage);
                return false;
            }

            if (replacePendingFrame && !record->pendingFrames.empty()) {
                const auto supersededBufferId = record->pendingFrames.back().bufferId;
                record->pendingFrames.pop_back();

                const bool bufferStillQueued =
                    std::ranges::any_of(record->pendingFrames, [supersededBufferId](const auto& queued) { return queued.bufferId == supersededBufferId; });
                const auto supersededImage = record->images.find(supersededBufferId);
                if (supersededBufferId != record->currentBufferId && !bufferStillQueued && supersededImage != record->images.end() && supersededImage->second.sourceDestroyed) {
                    retiredBufferId      = supersededBufferId;
                    retiredSourceBuffer  = std::move(supersededImage->second.sourceBuffer);
                    retiredImageLifetime = std::move(supersededImage->second.eglImageLifetime);
                    record->images.erase(supersededImage);
                }
            }

            const bool bootstrapMetadata = record->currentGeneration == 0 && record->pendingFrames.empty();
            if (bootstrapMetadata) {
                record->width               = frame.width;
                record->height              = frame.height;
                record->transform           = frame.transform;
                record->scale120            = frame.scale120;
                record->stackingOrder       = frame.stackingOrder;
                record->surfaceX            = frame.surfaceX;
                record->surfaceY            = frame.surfaceY;
                record->surfaceWidth        = frame.surfaceWidth;
                record->surfaceHeight       = frame.surfaceHeight;
                record->textureSourceX      = frame.textureSourceX;
                record->textureSourceY      = frame.textureSourceY;
                record->textureSourceWidth  = frame.textureSourceWidth;
                record->textureSourceHeight = frame.textureSourceHeight;
                record->parentSurfaceId     = frame.parentSurfaceId;
                record->popupRootSurfaceId  = frame.popupRootSurfaceId;
                record->surfaceRole         = frame.surfaceRole;
            }

            record->pendingFrames.emplace_back(SQueuedImportedFrame{
                .bufferId            = bufferId,
                .generation          = frame.generation,
                .acceptedAtUs        = acceptedAtUs,
                .parentSurfaceId     = frame.parentSurfaceId,
                .popupRootSurfaceId  = frame.popupRootSurfaceId,
                .buffer              = std::move(queuedBufferHold),
                .width               = frame.width,
                .height              = frame.height,
                .transform           = frame.transform,
                .scale120            = frame.scale120,
                .stackingOrder       = frame.stackingOrder,
                .surfaceX            = frame.surfaceX,
                .surfaceY            = frame.surfaceY,
                .surfaceWidth        = frame.surfaceWidth,
                .surfaceHeight       = frame.surfaceHeight,
                .textureSourceX      = frame.textureSourceX,
                .textureSourceY      = frame.textureSourceY,
                .textureSourceWidth  = frame.textureSourceWidth,
                .textureSourceHeight = frame.textureSourceHeight,
                .surfaceRole         = frame.surfaceRole,
            });

            if (record->pendingFrames.size() > IMPORTED_FRAME_QUEUE_DEPTH) {
                const auto droppedBufferId = record->pendingFrames.front().bufferId;
                record->pendingFrames.pop_front();

                const bool bufferStillQueued = std::ranges::any_of(record->pendingFrames, [droppedBufferId](const auto& queued) { return queued.bufferId == droppedBufferId; });
                const auto droppedImage      = record->images.find(droppedBufferId);
                if (droppedBufferId != record->currentBufferId && !bufferStillQueued && droppedImage != record->images.end() && droppedImage->second.sourceDestroyed) {
                    retiredBufferId      = droppedBufferId;
                    retiredSourceBuffer  = std::move(droppedImage->second.sourceBuffer);
                    retiredImageLifetime = std::move(droppedImage->second.eglImageLifetime);
                    record->images.erase(droppedImage);
                }
            }

            textureId = record->textureId;
            cookie    = record->cookie.get();
        }

        destroyEGLImage(eglImage);

        if (retiredBufferId != 0 && textureId >= 0)
            denial_engine_host_retire_external_texture_image(m_flutter->host, textureId, retiredBufferId);
        retiredImageLifetime.reset();
        retiredSourceBuffer.reset();

        if (textureId < 0) {
            textureId = denial_engine_host_register_egl_image_texture(m_flutter->host, &CRuntime::onExternalTextureFrame, cookie);
            if (textureId < 0) {
                DENIAL_HOT_LOG(Log::ERR, "Denial failed to register Flutter external texture for surface {}", frame.surfaceId);
                return false;
            }

            bool installed = false;
            {
                std::lock_guard<std::mutex> lock(m_externalTextureMutex);
                if (auto it = m_externalTextures.find(frame.surfaceId); it != m_externalTextures.end() && it->second) {
                    it->second->textureId = textureId;
                    shouldNotify          = true;
                    installed             = true;
                }
            }
            if (!installed) {
                denial_engine_host_unregister_external_texture(m_flutter->host, textureId);
                return false;
            }
        }

        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            if (auto it = m_externalTextures.find(frame.surfaceId); it != m_externalTextures.end() && it->second) {
                auto&      record       = *it->second;
                const bool titleChanged = frame.window && record.title != frame.window->m_title;
                const bool appIdChanged = frame.window && record.appId != frame.window->m_class;
                if (!record.announcedToDart || record.windowId != frame.windowId || record.textureId != textureId || titleChanged || appIdChanged ||
                    record.stackingOrder != frame.stackingOrder || record.rootSurface != frame.rootSurface || record.parentSurfaceId != frame.parentSurfaceId ||
                    record.popupRootSurfaceId != frame.popupRootSurfaceId || record.surfaceRole != frame.surfaceRole || record.dragIcon != frame.dragIcon) {
                    shouldNotify = true;
                }

                record.windowId = frame.windowId;
                if (titleChanged && frame.window)
                    record.title = frame.window->m_title;
                if (appIdChanged && frame.window)
                    record.appId = frame.window->m_class;
                record.window             = frame.window;
                record.surface            = frame.surface;
                record.stackingOrder      = frame.stackingOrder;
                record.rootSurface        = frame.rootSurface;
                record.dragIcon           = frame.dragIcon;
                record.parentSurfaceId    = frame.parentSurfaceId;
                record.popupRootSurfaceId = frame.popupRootSurfaceId;
                record.surfaceRole        = frame.surfaceRole;
                record.announcedToDart    = true;

                if (!record.notificationArmed && !record.pendingFrames.empty() && record.textureId >= 0) {
                    // Marking only stores Flutter demand. It cannot render or
                    // commit; the output state machine consumes it after the
                    // current KMS submission.
                    record.notificationArmed = true;
                    textureId                = record.textureId;
                    shouldPrime              = true;
                }
            }
        }

        if (shouldNotify) {
            if (frame.dragIcon)
                publishDragIconState();
            else
                notifyWindowObjectsChanged();
        }
        if (shouldPrime)
            markExternalTextureFrameAvailable(frame.surfaceId, textureId);
        return true;
    }

    bool CRuntime::importPixelSurfaceFrame(SSurfaceFrameRef frame) {
        if (!m_acceptTextureMarks.load(std::memory_order_acquire) || !m_flutter || !denial_engine_host_running(m_flutter->host) || (!frame.window && !frame.dragIcon) || !frame.rgbaPixels ||
            frame.rgbaPixels->empty() || frame.width == 0 || frame.height == 0)
            return false;

        releaseClosingTextureLeaseForSurface(frame.surfaceId);

        const auto              acceptedAtUs = steadyUs();
        const auto              outputTick   = m_outputTickSerial.load(std::memory_order_acquire);
        const auto              intervalUs   = outputTick == 0 ? importedFrameIntervalUs() : 0;

        bool                    shouldNotify = false;
        bool                    shouldPrime  = false;
        SExternalTextureCookie* cookie       = nullptr;
        int64_t                 textureId    = -1;

        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            auto&                       record = m_externalTextures[frame.surfaceId];
            if (!record) {
                record                    = std::make_unique<SSurfaceTextureObject>();
                record->surfaceId         = frame.surfaceId;
                record->cookie            = std::make_unique<SExternalTextureCookie>();
                record->cookie->runtime   = this;
                record->cookie->surfaceId = frame.surfaceId;
            }
            if (record->textureKind == eExternalTextureKind::EGL_IMAGE)
                return false;
            record->textureKind = eExternalTextureKind::PIXEL_BUFFER;
            record->dragIcon    = frame.dragIcon;

            const bool sameOutputTick = outputTick != 0 && record->lastAcceptedOutputTick == outputTick;
            const bool bootstrapBurst =
                outputTick == 0 && record->lastAcceptedFrameUs != 0 && (acceptedAtUs <= record->lastAcceptedFrameUs || acceptedAtUs - record->lastAcceptedFrameUs < intervalUs);
            if ((sameOutputTick || bootstrapBurst) && !record->pendingPixelFrames.empty())
                record->pendingPixelFrames.pop_back();

            record->lastAcceptedFrameUs    = acceptedAtUs;
            record->lastAcceptedOutputTick = outputTick;

            const bool bootstrapMetadata = record->currentGeneration == 0 && record->pendingPixelFrames.empty();
            if (bootstrapMetadata) {
                record->width               = frame.width;
                record->height              = frame.height;
                record->transform           = frame.transform;
                record->scale120            = frame.scale120;
                record->stackingOrder       = frame.stackingOrder;
                record->surfaceX            = frame.surfaceX;
                record->surfaceY            = frame.surfaceY;
                record->surfaceWidth        = frame.surfaceWidth;
                record->surfaceHeight       = frame.surfaceHeight;
                record->textureSourceX      = frame.textureSourceX;
                record->textureSourceY      = frame.textureSourceY;
                record->textureSourceWidth  = frame.textureSourceWidth;
                record->textureSourceHeight = frame.textureSourceHeight;
                record->parentSurfaceId     = frame.parentSurfaceId;
                record->popupRootSurfaceId  = frame.popupRootSurfaceId;
                record->surfaceRole         = frame.surfaceRole;
            }

            record->pendingPixelFrames.emplace_back(SQueuedPixelFrame{
                .generation          = frame.generation,
                .acceptedAtUs        = acceptedAtUs,
                .parentSurfaceId     = frame.parentSurfaceId,
                .popupRootSurfaceId  = frame.popupRootSurfaceId,
                .pixels              = frame.rgbaPixels,
                .width               = frame.width,
                .height              = frame.height,
                .transform           = frame.transform,
                .scale120            = frame.scale120,
                .stackingOrder       = frame.stackingOrder,
                .surfaceX            = frame.surfaceX,
                .surfaceY            = frame.surfaceY,
                .surfaceWidth        = frame.surfaceWidth,
                .surfaceHeight       = frame.surfaceHeight,
                .textureSourceX      = frame.textureSourceX,
                .textureSourceY      = frame.textureSourceY,
                .textureSourceWidth  = frame.textureSourceWidth,
                .textureSourceHeight = frame.textureSourceHeight,
                .surfaceRole         = frame.surfaceRole,
            });
            while (record->pendingPixelFrames.size() > IMPORTED_FRAME_QUEUE_DEPTH)
                record->pendingPixelFrames.pop_front();

            cookie    = record->cookie.get();
            textureId = record->textureId;
        }

        if (textureId < 0) {
            textureId = denial_engine_host_register_pixel_buffer_texture(m_flutter->host, &CRuntime::onExternalPixelBufferFrame, cookie);
            if (textureId < 0) {
                Log::logger->log(Log::ERR, "Denial failed to register Flutter pixel-buffer texture for SHM surface {}", frame.surfaceId);
                return false;
            }

            bool installed = false;
            {
                std::lock_guard<std::mutex> lock(m_externalTextureMutex);
                if (auto it = m_externalTextures.find(frame.surfaceId); it != m_externalTextures.end() && it->second && it->second->textureId < 0) {
                    it->second->textureId = textureId;
                    shouldNotify          = true;
                    installed             = true;
                }
            }
            if (!installed) {
                denial_engine_host_unregister_external_texture(m_flutter->host, textureId);
                return false;
            }
        }

        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            if (auto it = m_externalTextures.find(frame.surfaceId); it != m_externalTextures.end() && it->second) {
                auto&      record       = *it->second;
                const bool titleChanged = frame.window && record.title != frame.window->m_title;
                const bool appIdChanged = frame.window && record.appId != frame.window->m_class;
                if (!record.announcedToDart || record.windowId != frame.windowId || record.textureId != textureId || titleChanged || appIdChanged ||
                    record.rootSurface != frame.rootSurface || record.dragIcon != frame.dragIcon) {
                    shouldNotify = true;
                }

                record.windowId = frame.windowId;
                if (titleChanged && frame.window)
                    record.title = frame.window->m_title;
                if (appIdChanged && frame.window)
                    record.appId = frame.window->m_class;
                record.window          = frame.window;
                record.surface         = frame.surface;
                record.rootSurface     = frame.rootSurface;
                record.dragIcon        = frame.dragIcon;
                record.announcedToDart = true;

                if (!record.notificationArmed && !record.pendingPixelFrames.empty() && record.textureId >= 0) {
                    record.notificationArmed = true;
                    textureId                = record.textureId;
                    shouldPrime              = true;
                }
            }
        }

        if (shouldNotify) {
            if (frame.dragIcon)
                publishDragIconState();
            else
                notifyWindowObjectsChanged();
        }
        if (shouldPrime)
            markExternalTextureFrameAvailable(frame.surfaceId, textureId);
        return true;
    }

    bool CRuntime::markExternalTextureFrameAvailable(TSurfaceId surfaceId, int64_t textureId) {
        if (textureId < 0)
            return false;

        if (!m_acceptTextureMarks.load(std::memory_order_acquire) || !m_flutter || !denial_engine_host_running(m_flutter->host)) {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            const auto                  record = m_externalTextures.find(surfaceId);
            if (record != m_externalTextures.end() && record->second && record->second->textureId == textureId)
                record->second->notificationArmed = false;
            return false;
        }

        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            const auto                  record = m_externalTextures.find(surfaceId);
            if (record == m_externalTextures.end() || !record->second || record->second->closing || record->second->textureId != textureId || !record->second->notificationArmed)
                return false;
        }

        if (denial_engine_host_mark_external_texture_frame_available(m_flutter->host, textureId))
            return true;

        std::lock_guard<std::mutex> lock(m_externalTextureMutex);
        const auto                  record = m_externalTextures.find(surfaceId);
        if (record != m_externalTextures.end() && record->second && record->second->textureId == textureId)
            record->second->notificationArmed = false;
        return false;
    }

    void CRuntime::queueTextureMarksForGenerations(const std::unordered_map<TSurfaceId, uint64_t>& sampledGenerations) {
        if (sampledGenerations.empty() || !m_acceptTextureMarks.load(std::memory_order_acquire))
            return;

        bool       queued = false;
        const auto nowUs  = steadyUs();
        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            for (const auto& [surfaceId, sampledGeneration] : sampledGenerations) {
                const auto record = m_externalTextures.find(surfaceId);
                if (record == m_externalTextures.end() || !record->second || record->second->textureId < 0 || record->second->currentGeneration < sampledGeneration ||
                    record->second->notificationArmed || record->second->closing || resizeTextureHandoffDeferred(*record->second, nowUs))
                    continue;

                record->second->notificationArmed = true;
                m_pendingTextureMarks.emplace_back(surfaceId, record->second->textureId);
                queued = true;
            }
        }

        if (queued)
            requestMainLoop(MAIN_LOOP_TEXTURE_MARK);
    }

    void CRuntime::processPendingTextureMarks() {
        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            m_textureMarkScratch.swap(m_pendingTextureMarks);
            m_sampleReleaseScratch.swap(m_pendingSampleReleases);
        }

        // Destruction on the Hypr thread is intentional: CHLBufferReference
        // may emit wl_buffer.release when the final sampled hold is dropped.
        m_sampleReleaseScratch.clear();

        for (const auto& [surfaceId, textureId] : m_textureMarkScratch)
            markExternalTextureFrameAvailable(surfaceId, textureId);
        // Keep both capacities. The next swap gives producers a reusable
        // buffer instead of allocating fresh vectors on every frame drain.
        m_textureMarkScratch.clear();
    }

    void CRuntime::destroySurfaceTexture(TSurfaceId surfaceId) {
        std::unique_ptr<SSurfaceTextureObject> record;
        TWindowId                              closingWindowId = 0;

        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            auto                        it = m_externalTextures.find(surfaceId);
            if (it == m_externalTextures.end())
                return;

            if (it->second && it->second->closing) {
                closingWindowId = it->second->windowId;
            } else {
                record = std::move(it->second);
                m_externalTextures.erase(it);
                m_rasterSampledGenerations.erase(surfaceId);
                std::erase_if(m_pendingTextureMarks, [surfaceId](const auto& mark) { return mark.first == surfaceId; });
#if defined(DENIAL_ENABLE_DIAGNOSTICS)
                m_importedFrameTimings.erase(surfaceId);
#endif
            }
        }

        if (closingWindowId != 0) {
            releaseClosingTextureLease(closingWindowId);
            return;
        }

        if (!record)
            return;

        if (record->dragIcon)
            publishDragIconState();
        else
            notifyWindowObjectsChanged();

        if (m_flutter && record->textureId >= 0)
            denial_engine_host_unregister_external_texture(m_flutter->host, record->textureId);
    }

    void CRuntime::leaseWindowTextures(TWindowId windowId, const std::vector<TSurfaceId>& surfaceIds) {
        if (windowId == 0)
            return;

        // A duplicate close boundary should replace, never extend, an old
        // lease. Stable window IDs make this defensive rather than routine.
        releaseClosingTextureLease(windowId);

        struct SRetiredImage {
            int64_t               textureId = -1;
            TImportedBufferId     bufferId  = 0;
            SP<IHLBuffer>         sourceBuffer;
            std::shared_ptr<void> imageLifetime;
        };

        std::vector<SRetiredImage>       retiredImages;
        std::vector<TImportedBufferHold> discardedQueuedBuffers;
        std::vector<TSurfaceId>          leasedSurfaceIds;
        size_t                           estimatedBytes   = 0;
        constexpr size_t                 ESTIMATE_CEILING = ClosingTextureLease::MAX_ESTIMATED_BUFFER_BYTES + 1U;
        const auto                       addEstimate      = [&](size_t bytes) {
            estimatedBytes = bytes >= ESTIMATE_CEILING || estimatedBytes >= ESTIMATE_CEILING - bytes ? ESTIMATE_CEILING : estimatedBytes + bytes;
        };

        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            leasedSurfaceIds.reserve(surfaceIds.size());

            for (const auto surfaceId : surfaceIds) {
                const auto found = m_externalTextures.find(surfaceId);
                if (found == m_externalTextures.end() || !found->second || found->second->windowId != windowId || found->second->closing)
                    continue;

                auto& record             = *found->second;
                record.closing           = true;
                record.notificationArmed = false;
                clearResizeTextureHandoff(record);
                leasedSurfaceIds.emplace_back(surfaceId);

                for (auto& queued : record.pendingFrames) {
                    if (queued.buffer)
                        discardedQueuedBuffers.emplace_back(std::move(queued.buffer));
                }
                record.pendingFrames.clear();
                record.pendingPixelFrames.clear();
                std::erase_if(m_pendingTextureMarks, [surfaceId](const auto& mark) { return mark.first == surfaceId; });

                for (auto image = record.images.begin(); image != record.images.end();) {
                    if (image->first == record.currentBufferId) {
                        ++image;
                        continue;
                    }

                    record.bufferIdsBySource.erase(image->second.sourceKey);
                    retiredImages.emplace_back(SRetiredImage{
                        .textureId     = record.textureId,
                        .bufferId      = image->first,
                        .sourceBuffer  = std::move(image->second.sourceBuffer),
                        .imageLifetime = std::move(image->second.eglImageLifetime),
                    });
                    image = record.images.erase(image);
                }

                if (record.textureKind == eExternalTextureKind::PIXEL_BUFFER && record.currentPixelBuffer)
                    addEstimate(record.currentPixelBuffer->size());
                else if (const auto current = record.images.find(record.currentBufferId); current != record.images.end())
                    addEstimate(ClosingTextureLease::estimateBufferBytes(current->second.width, current->second.height));
                else
                    addEstimate(ClosingTextureLease::estimateBufferBytes(record.width, record.height));

#if defined(DENIAL_ENABLE_DIAGNOSTICS)
                m_importedFrameTimings.erase(surfaceId);
#endif
            }

            if (!leasedSurfaceIds.empty()) {
                m_closingTextureLeases.emplace(windowId,
                                               SClosingTextureLease{
                                                   .windowId       = windowId,
                                                   .surfaceIds     = leasedSurfaceIds,
                                                   .estimatedBytes = estimatedBytes,
                                                   .deadlineUs     = steadyUs() + ClosingTextureLease::WATCHDOG_TIMEOUT_US,
                                               });
                m_closingTextureLeaseBytes = std::min(ESTIMATE_CEILING, m_closingTextureLeaseBytes + estimatedBytes);
            }
        }

        // Queued client holds and obsolete EGLImages can emit release work;
        // drop them on the compositor thread, but never while the texture map
        // mutex is held. Only the last displayed frame remains leased.
        discardedQueuedBuffers.clear();
        for (auto& retired : retiredImages) {
            if (m_flutter && retired.textureId >= 0)
                denial_engine_host_retire_external_texture_image(m_flutter->host, retired.textureId, retired.bufferId);
            retired.imageLifetime.reset();
            retired.sourceBuffer.reset();
        }

        // This is the single live-state transition. Leased records remain
        // addressable only by Flutter's already-issued texture IDs.
        notifyWindowObjectsChanged();

        if (leasedSurfaceIds.empty())
            return;

        armClosingTextureLeaseTimer();
        enforceClosingTextureLeaseLimits();
    }

    void CRuntime::releaseClosingTextureLease(TWindowId windowId) {
        if (windowId == 0)
            return;

        std::vector<std::unique_ptr<SSurfaceTextureObject>> records;
        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            const auto                  lease = m_closingTextureLeases.find(windowId);
            if (lease == m_closingTextureLeases.end())
                return;

            records.reserve(lease->second.surfaceIds.size());
            for (const auto surfaceId : lease->second.surfaceIds) {
                const auto record = m_externalTextures.find(surfaceId);
                if (record == m_externalTextures.end() || !record->second || !record->second->closing || record->second->windowId != windowId)
                    continue;

                records.emplace_back(std::move(record->second));
                m_externalTextures.erase(record);
                m_rasterSampledGenerations.erase(surfaceId);
                std::erase_if(m_pendingTextureMarks, [surfaceId](const auto& mark) { return mark.first == surfaceId; });
            }

            m_closingTextureLeases.erase(lease);
            m_closingTextureLeaseBytes        = 0;
            constexpr size_t ESTIMATE_CEILING = ClosingTextureLease::MAX_ESTIMATED_BUFFER_BYTES + 1U;
            for (const auto& [_, remaining] : m_closingTextureLeases)
                m_closingTextureLeaseBytes = remaining.estimatedBytes >= ESTIMATE_CEILING || m_closingTextureLeaseBytes >= ESTIMATE_CEILING - remaining.estimatedBytes ?
                    ESTIMATE_CEILING :
                    m_closingTextureLeaseBytes + remaining.estimatedBytes;
        }

        for (auto& record : records) {
            if (record && m_flutter && record->textureId >= 0)
                denial_engine_host_unregister_external_texture(m_flutter->host, record->textureId);
        }

        armClosingTextureLeaseTimer();
    }

    void CRuntime::releaseClosingTextureLeaseForSurface(TSurfaceId surfaceId) {
        TWindowId windowId = 0;
        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            const auto                  record = m_externalTextures.find(surfaceId);
            if (record != m_externalTextures.end() && record->second && record->second->closing)
                windowId = record->second->windowId;
        }

        if (windowId != 0)
            releaseClosingTextureLease(windowId);
    }

    void CRuntime::expireClosingTextureLeases() {
        const auto             nowUs = steadyUs();
        std::vector<TWindowId> expired;
        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            expired.reserve(m_closingTextureLeases.size());
            for (const auto& [windowId, lease] : m_closingTextureLeases) {
                if (lease.deadlineUs <= nowUs)
                    expired.emplace_back(windowId);
            }
        }

        for (const auto windowId : expired) {
            Log::logger->log(Log::WARN, "Denial close texture lease watchdog expired for window {}", windowId);
            releaseClosingTextureLease(windowId);
        }
        armClosingTextureLeaseTimer();
    }

    void CRuntime::armClosingTextureLeaseTimer() {
        if (!m_closingTextureLeaseTimer)
            return;

        uint64_t earliestDeadlineUs = 0;
        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            for (const auto& [_, lease] : m_closingTextureLeases) {
                if (earliestDeadlineUs == 0 || lease.deadlineUs < earliestDeadlineUs)
                    earliestDeadlineUs = lease.deadlineUs;
            }
        }

        if (earliestDeadlineUs == 0) {
            m_closingTextureLeaseTimer->updateTimeout(std::nullopt);
            return;
        }

        const auto nowUs   = steadyUs();
        const auto delayUs = earliestDeadlineUs > nowUs ? earliestDeadlineUs - nowUs : 1U;
        m_closingTextureLeaseTimer->updateTimeout(std::chrono::microseconds(delayUs));
    }

    void CRuntime::wakeResizeTextureHandoffs() {
        const auto                                  nowUs = steadyUs();
        std::vector<std::pair<TSurfaceId, int64_t>> marks;
        bool                                        requestFrame = false;
        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            marks.reserve(m_externalTextures.size());
            for (auto& [surfaceId, record] : m_externalTextures) {
                if (!record || record->closing || record->resizeHandoffWakeUs == 0 || record->resizeHandoffWakeUs > nowUs)
                    continue;

                // Disarm this edge before requesting a frame. The next output
                // either completes the handoff or computes a later one-shot
                // deadline; it must not spin this timer in the meantime.
                record->resizeHandoffWakeUs = 0;
                const bool hasPending       = record->textureKind == eExternalTextureKind::PIXEL_BUFFER ? !record->pendingPixelFrames.empty() : !record->pendingFrames.empty();
                if (!hasPending || record->textureId < 0)
                    continue;

                if (!record->notificationArmed) {
                    record->notificationArmed = true;
                    marks.emplace_back(surfaceId, record->textureId);
                } else {
                    requestFrame = true;
                }
            }
        }

        for (const auto& [surfaceId, textureId] : marks)
            requestFrame = !markExternalTextureFrameAvailable(surfaceId, textureId) || requestFrame;

        // A mark asks Flutter for a frame; the explicit output request also
        // covers an already-armed mark whose AwaitVSync baton arrived before
        // this timer edge.
        if (requestFrame || !marks.empty())
            requestMainLoop(MAIN_LOOP_OUTPUT_FRAME);
        armResizeTextureHandoffTimer();
    }

    void CRuntime::armResizeTextureHandoffTimer() {
        if (!m_resizeTextureHandoffTimer)
            return;

        uint64_t earliestWakeUs = 0;
        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            for (const auto& [_, record] : m_externalTextures) {
                if (!record || record->closing || record->resizeHandoffWakeUs == 0)
                    continue;
                if (earliestWakeUs == 0 || record->resizeHandoffWakeUs < earliestWakeUs)
                    earliestWakeUs = record->resizeHandoffWakeUs;
            }
        }

        if (earliestWakeUs == 0) {
            m_resizeTextureHandoffTimer->updateTimeout(std::nullopt);
            return;
        }

        const auto nowUs   = steadyUs();
        const auto delayUs = earliestWakeUs > nowUs ? earliestWakeUs - nowUs : 1U;
        m_resizeTextureHandoffTimer->updateTimeout(std::chrono::microseconds(delayUs));
    }

    void CRuntime::enforceClosingTextureLeaseLimits() {
        while (true) {
            TWindowId victim = 0;
            {
                std::lock_guard<std::mutex> lock(m_externalTextureMutex);
                if (m_closingTextureLeases.size() <= ClosingTextureLease::MAX_ACTIVE_LEASES && m_closingTextureLeaseBytes <= ClosingTextureLease::MAX_ESTIMATED_BUFFER_BYTES)
                    return;

                uint64_t earliestDeadlineUs = 0;
                for (const auto& [windowId, lease] : m_closingTextureLeases) {
                    if (victim == 0 || lease.deadlineUs < earliestDeadlineUs) {
                        victim             = windowId;
                        earliestDeadlineUs = lease.deadlineUs;
                    }
                }
            }

            if (victim == 0)
                return;

            Log::logger->log(Log::WARN, "Denial evicting close texture lease for window {} to preserve the bounded texture budget", victim);
            releaseClosingTextureLease(victim);
        }
    }

    void CRuntime::onWindowCloseCompleteMessage(const char* channel, const uint8_t* message, size_t messageSize, void* userData) {
        (void)channel;
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime)
            return;

        const auto windowId = ClosingTextureLease::decodeCompletion(message, messageSize);
        if (!windowId)
            return;

        const auto complete = [runtime, windowId = *windowId] {
            if (runtime->m_initialized)
                runtime->releaseClosingTextureLease(windowId);
        };
        if (g_pEventLoopManager)
            g_pEventLoopManager->postToLoop(complete);
        else
            complete();
    }

    void CRuntime::destroyImportedBufferImage(TSurfaceId surfaceId, TImportedBufferId bufferId) {
        SP<IHLBuffer>         retiredSourceBuffer;
        std::shared_ptr<void> retiredImageLifetime;
        int64_t               textureId = -1;

        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            auto                        recordIt = m_externalTextures.find(surfaceId);
            if (recordIt == m_externalTextures.end() || !recordIt->second)
                return;

            auto& record  = *recordIt->second;
            auto  imageIt = record.images.find(bufferId);
            if (imageIt == record.images.end())
                return;

            record.bufferIdsBySource.erase(imageIt->second.sourceKey);
            imageIt->second.sourceDestroyed = true;

            // Destroying the wl_buffer object does not detach its committed or
            // queued contents. Keep the image sampleable until both the
            // current slot and the bounded playout queue have released it.
            const bool bufferQueued = std::ranges::any_of(record.pendingFrames, [bufferId](const auto& queued) { return queued.bufferId == bufferId; });
            if (record.currentBufferId == bufferId || bufferQueued)
                return;

            retiredSourceBuffer  = std::move(imageIt->second.sourceBuffer);
            retiredImageLifetime = std::move(imageIt->second.eglImageLifetime);
            textureId            = record.textureId;
            record.images.erase(imageIt);
        }

        if (m_flutter && textureId >= 0)
            denial_engine_host_retire_external_texture_image(m_flutter->host, textureId, bufferId);
        retiredImageLifetime.reset();
        retiredSourceBuffer.reset();
    }

    void CRuntime::destroyImportedTextures() {
        std::vector<std::unique_ptr<SSurfaceTextureObject>> records;

        bool                                                hasUnsealedSamples = false;
        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            hasUnsealedSamples = !m_rasterSampledBufferHolds.empty();
        }
        if (hasUnsealedSamples && m_flutter && makeFlutterContextCurrent(m_flutter->eglDisplay, m_flutter->renderContext, "imported texture shutdown"))
            glFinish();

        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            records.reserve(m_externalTextures.size());
            for (auto& [_, record] : m_externalTextures)
                records.emplace_back(std::move(record));
            m_externalTextures.clear();
            m_closingTextureLeases.clear();
            m_closingTextureLeaseBytes = 0;
            m_rasterSampledGenerations.clear();
            m_rasterSampledBufferHolds.clear();
            m_pendingSampleReleases.clear();
            m_pendingTextureMarks.clear();
#if defined(DENIAL_ENABLE_DIAGNOSTICS)
            m_importedFrameTimings.clear();
#endif
        }

        for (auto& record : records) {
            if (!record)
                continue;

            if (m_flutter && record->textureId >= 0)
                denial_engine_host_unregister_external_texture(m_flutter->host, record->textureId);
        }

        if (m_closingTextureLeaseTimer)
            m_closingTextureLeaseTimer->updateTimeout(std::nullopt);
        if (m_resizeTextureHandoffTimer)
            m_resizeTextureHandoffTimer->updateTimeout(std::nullopt);
    }

    std::shared_ptr<void> CRuntime::adoptEGLImage(void* image) {
        const auto* GL = Render::GL::g_pHyprOpenGL.get();
        if (!image || image == EGL_NO_IMAGE_KHR || !GL || !GL->m_proc.eglDestroyImageKHR)
            return {};

        const auto display      = GL->m_eglDisplay;
        const auto destroyImage = GL->m_proc.eglDestroyImageKHR;
        return std::shared_ptr<void>{image, [display, destroyImage](void* ownedImage) {
                                         if (ownedImage && ownedImage != EGL_NO_IMAGE_KHR)
                                             destroyImage(display, rc<EGLImageKHR>(ownedImage));
                                     }};
    }

    void CRuntime::destroyEGLImage(void* image) {
        if (image && image != EGL_NO_IMAGE_KHR && Render::GL::g_pHyprOpenGL && Render::GL::g_pHyprOpenGL->m_proc.eglDestroyImageKHR)
            Render::GL::g_pHyprOpenGL->m_proc.eglDestroyImageKHR(Render::GL::g_pHyprOpenGL->m_eglDisplay, rc<EGLImageKHR>(image));
    }

    bool CRuntime::fillExternalTextureDescriptor(TSurfaceId surfaceId, DenialEGLImageDescriptor& descriptor) {
        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);

            const auto                  RECORD = m_externalTextures.find(surfaceId);
            if (RECORD == m_externalTextures.end() || !RECORD->second || RECORD->second->currentBufferId == 0 || RECORD->second->currentGeneration == 0)
                return false;

            const auto IMAGE = RECORD->second->images.find(RECORD->second->currentBufferId);
            if (IMAGE == RECORD->second->images.end() || !IMAGE->second.eglImage)
                return false;

            descriptor.egl_image        = IMAGE->second.eglImage;
            descriptor.stable_id        = IMAGE->second.bufferId;
            descriptor.width            = IMAGE->second.width;
            descriptor.height           = IMAGE->second.height;
            descriptor.release_callback = nullptr;
            descriptor.release_context  = nullptr;
            const auto previousSample   = m_rasterSampledGenerations.find(surfaceId);
            if (previousSample == m_rasterSampledGenerations.end() || previousSample->second != RECORD->second->currentGeneration) {
                if (RECORD->second->currentBufferHold)
                    m_rasterSampledBufferHolds.emplace_back(SImportedFrameHold{
                        .buffer           = RECORD->second->currentBufferHold,
                        .eglImageLifetime = IMAGE->second.eglImageLifetime,
                    });
                m_rasterSampledGenerations[surfaceId] = RECORD->second->currentGeneration;
            }
            RECORD->second->lastSampledGeneration = RECORD->second->currentGeneration;
            RECORD->second->notificationArmed     = false;

            if (!RECORD->second->pendingFrames.empty() && RECORD->second->textureId >= 0 && !resizeTextureHandoffDeferred(*RECORD->second, steadyUs())) {
                // Never notify Flutter while it is resolving this texture for
                // the current raster frame. The engine can coalesce that mark
                // into the frame already in progress and never issue another
                // AwaitVSync baton. Store the demand now; the raster-runner
                // sentinel dispatches it on the main thread after this raster
                // task has completely returned.
                RECORD->second->notificationArmed = true;
                m_pendingTextureMarks.emplace_back(surfaceId, RECORD->second->textureId);
            }
        }
        return true;
    }

    bool CRuntime::fillExternalPixelBufferDescriptor(TSurfaceId surfaceId, DenialPixelBufferDescriptor& descriptor) {
        std::lock_guard<std::mutex> lock(m_externalTextureMutex);

        const auto                  RECORD = m_externalTextures.find(surfaceId);
        if (RECORD == m_externalTextures.end() || !RECORD->second || RECORD->second->textureKind != eExternalTextureKind::PIXEL_BUFFER || !RECORD->second->currentPixelBuffer ||
            RECORD->second->currentGeneration == 0 || RECORD->second->currentPixelWidth == 0 || RECORD->second->currentPixelHeight == 0 ||
            RECORD->second->currentPixelBuffer->size() < sc<size_t>(RECORD->second->currentPixelWidth) * RECORD->second->currentPixelHeight * 4U)
            return false;

        using TPixelHold            = std::shared_ptr<const std::vector<uint8_t>>;
        auto* hold                  = new TPixelHold(RECORD->second->currentPixelBuffer);
        descriptor.buffer           = (*hold)->data();
        descriptor.width            = RECORD->second->currentPixelWidth;
        descriptor.height           = RECORD->second->currentPixelHeight;
        descriptor.release_context  = hold;
        descriptor.release_callback = [](void* context) { delete sc<TPixelHold*>(context); };

        m_rasterSampledGenerations[surfaceId] = RECORD->second->currentGeneration;
        RECORD->second->lastSampledGeneration = RECORD->second->currentGeneration;
        RECORD->second->notificationArmed     = false;

        if (!RECORD->second->pendingPixelFrames.empty() && RECORD->second->textureId >= 0 && !resizeTextureHandoffDeferred(*RECORD->second, steadyUs())) {
            RECORD->second->notificationArmed = true;
            m_pendingTextureMarks.emplace_back(surfaceId, RECORD->second->textureId);
        }

        return true;
    }

    const DenialEGLImageDescriptor* CRuntime::onExternalTextureFrame(size_t width, size_t height, void* eglDisplay, void* eglContext, void* userData) {
        (void)width;
        (void)height;
        (void)eglDisplay;
        (void)eglContext;

        auto* cookie = sc<SExternalTextureCookie*>(userData);
        if (!cookie || !cookie->runtime)
            return nullptr;

        thread_local DenialEGLImageDescriptor descriptor = {};
        return cookie->runtime->fillExternalTextureDescriptor(cookie->surfaceId, descriptor) ? &descriptor : nullptr;
    }

    const DenialPixelBufferDescriptor* CRuntime::onExternalPixelBufferFrame(size_t width, size_t height, void* userData) {
        (void)width;
        (void)height;

        auto* cookie = sc<SExternalTextureCookie*>(userData);
        if (!cookie || !cookie->runtime)
            return nullptr;

        thread_local DenialPixelBufferDescriptor descriptor = {};
        return cookie->runtime->fillExternalPixelBufferDescriptor(cookie->surfaceId, descriptor) ? &descriptor : nullptr;
    }

#if defined(DENIAL_ENABLE_DIAGNOSTICS)
    void CRuntime::onImportedFrameTimingControlMessage(const char* channel, const uint8_t* message, size_t messageSize, void* userData) {
        (void)channel;
        auto* runtime = sc<CRuntime*>(userData);
        if (!runtime)
            return;

        const bool enabled = message && messageSize > 0 && message[0] != 0;
        if (enabled && messageSize >= 1 + sizeof(uint64_t)) {
            const auto budgetUs = readUint64LE(message + 1);
            if (budgetUs >= 1000 && budgetUs <= 100000)
                runtime->m_importedFrameTimingBudgetUs.store(budgetUs, std::memory_order_relaxed);
        }

        // The producer remains completely dormant unless the Dart overlay is
        // mounted. Reset on each enable so an idle gap from an earlier session
        // can never contaminate the first visible bucket.
        runtime->m_importedFrameTimingResetRequested.store(true, std::memory_order_release);
        runtime->m_importedFrameTimingEnabled.store(enabled, std::memory_order_release);
    }
#endif

} // namespace Denial
