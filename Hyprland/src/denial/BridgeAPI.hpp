#pragma once

#include "../desktop/DesktopTypes.hpp"
#include "../protocols/types/Buffer.hpp"

#include <aquamarine/buffer/Buffer.hpp>

#include <cstdint>
#include <memory>
#include <vector>

class CWLSurfaceResource;

namespace Denial {

    using TSurfaceId = uint64_t;
    using TWindowId  = uint64_t;

    enum class ESurfaceLayerRole : uint8_t {
        Root,
        Subsurface,
        Popup,
    };

    struct SSurfaceFrameRef {
        TSurfaceId                                  surfaceId  = 0;
        TSurfaceId                                  parentSurfaceId = 0;
        TSurfaceId                                  popupRootSurfaceId = 0;
        TWindowId                                   windowId   = 0;
        uint64_t                                    generation = 0;
        CHLBufferReference                          buffer;
        Aquamarine::SDMABUFAttrs                    dmabuf;
        std::shared_ptr<const std::vector<uint8_t>> rgbaPixels;
        uint32_t                                    width     = 0;
        uint32_t                                    height    = 0;
        uint32_t                                    transform = 0;
        uint32_t                                    scale120  = 120;
        int32_t                                     stackingOrder       = 0;
        double                                      surfaceX           = 0.0;
        double                                      surfaceY           = 0.0;
        double                                      surfaceWidth       = 0.0;
        double                                      surfaceHeight      = 0.0;
        double                                      textureSourceX     = 0.0;
        double                                      textureSourceY     = 0.0;
        double                                      textureSourceWidth = 0.0;
        double                                      textureSourceHeight = 0.0;
        // Time from the compositor sending this surface's frame callback to
        // receiving the corresponding buffer commit. This is the only generic
        // app-render latency available without modifying the Wayland client.
        uint64_t               renderDurationUs = 0;
        int                    acquireFence     = -1;
        bool                   rootSurface      = false;
        bool                   dragIcon         = false;
        ESurfaceLayerRole      surfaceRole      = ESurfaceLayerRole::Root;
        PHLWINDOW              window;
        WP<CWLSurfaceResource> surface;
    };

    class ISurfaceFrameConsumer {
      public:
        virtual ~ISurfaceFrameConsumer() = default;

        virtual void onSurfaceFrame(SSurfaceFrameRef frame) = 0;
        virtual void onSurfaceFrameCallbackDemand() {}
        virtual void onWindowMapped(TWindowId windowId) {
            (void)windowId;
        }
        virtual void onSurfaceTreeChanged(TWindowId windowId) {
            (void)windowId;
        }
        virtual void onWindowStateChanged(TWindowId windowId) {
            (void)windowId;
        }
        virtual void onWindowGeometryChanged(TWindowId windowId, const Vector2D& position, const Vector2D& size) {
            (void)windowId;
            (void)position;
            (void)size;
        }
        virtual void onSurfaceGone(TSurfaceId surfaceId, TWindowId windowId) {
            (void)surfaceId;
            (void)windowId;
        }
        virtual void onWindowGone(TWindowId windowId, const std::vector<TSurfaceId>& surfaceIds) {
            for (const auto surfaceId : surfaceIds)
                onSurfaceGone(surfaceId, windowId);
        }
    };

    class IBufferImportPolicy {
      public:
        virtual ~IBufferImportPolicy() = default;

        virtual bool canImportClientBuffer(const Aquamarine::SDMABUFAttrs& attrs)     = 0;
        virtual bool canSampleAsFlutterTexture(const Aquamarine::SDMABUFAttrs& attrs) = 0;
    };

} // namespace Denial
