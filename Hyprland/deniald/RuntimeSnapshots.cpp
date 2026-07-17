#include "Runtime.hpp"
#include "RuntimeFlutterState.hpp"
#include "RuntimeInternal.hpp"
#include "Wire.hpp"
#include "WindowDecorationPolicy.hpp"

#include "../src/config/ConfigValue.hpp"
#include "../src/debug/log/Logger.hpp"
#include "../src/desktop/view/Popup.hpp"
#include "../src/desktop/view/WLSurface.hpp"
#include "../src/desktop/view/Window.hpp"
#include "../src/helpers/Monitor.hpp"
#include "../src/layout/target/Target.hpp"
#include "../src/protocols/XDGShell.hpp"
#include "../src/protocols/core/Compositor.hpp"
#include "../src/protocols/core/Subcompositor.hpp"
#include "../src/xwayland/XWayland.hpp"

#include <algorithm>
#include <array>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace Denial {

    using RuntimeInternal::STATUS_COLOR_FALLBACK_ARGB;

    namespace {
        bool isPopupLikeWindow(const PHLWINDOW& window) {
            if (!window || !window->m_isX11)
                return false;

            const auto surface = window->m_xwaylandSurface.lock();
            if (!surface)
                return false;

            // Native xdg_popup surfaces already remain layers of their owner.
            // XWayland exposes equivalent transient UI as independent windows,
            // so carry that semantic distinction across the Denial bridge.
            if (surface->m_overrideRedirect || surface->m_role.contains("pop-up"))
                return true;

            constexpr std::array POPUP_TYPES{
                "_NET_WM_WINDOW_TYPE_COMBO",        "_NET_WM_WINDOW_TYPE_DND",        "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU", "_NET_WM_WINDOW_TYPE_MENU",
                "_NET_WM_WINDOW_TYPE_NOTIFICATION", "_NET_WM_WINDOW_TYPE_POPUP_MENU", "_NET_WM_WINDOW_TYPE_TOOLTIP",
            };
            return std::ranges::any_of(POPUP_TYPES, [&](const char* name) {
                const auto atom = HYPRATOMS.find(name);
                return atom != HYPRATOMS.end() && std::ranges::contains(surface->m_atoms, atom->second);
            });
        }

        float surfaceOpacity(const SP<CWLSurfaceResource>& resource) {
            const auto surface = Desktop::View::CWLSurface::fromResource(resource);
            return surface ? std::clamp(surface->effectiveOpacity(), 0.F, 1.F) : 1.F;
        }
    } // namespace

    bool CRuntime::notifyWindowObjectsChanged() {
        // Image identity, dimensions and source crop are one surface
        // transaction. Sending only an invalidation makes Dart request the
        // matching metadata asynchronously, while MarkExternalTextureFrameAvailable
        // can already schedule a texture-only frame with the new EGLImage.
        // Chromium exposes that gap whenever it replaces its oversized resize
        // buffers with exact-size buffers: one frame samples the new image with
        // the preceding crop. Publish the complete snapshot first so the
        // platform-message ordering makes the layer metadata visible before
        // the following texture mark.
        return sendWindowListResponse(0);
    }

    bool CRuntime::sendWindowListResponse(uint64_t requestId) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host))
            return false;

        struct SSurfaceLayerSnapshot {
            TSurfaceId        surfaceId           = 0;
            TSurfaceId        parentSurfaceId     = 0;
            TSurfaceId        popupRootSurfaceId  = 0;
            ESurfaceLayerRole role                = ESurfaceLayerRole::Root;
            int64_t           textureId           = -1;
            uint32_t          width               = 0;
            uint32_t          height              = 0;
            double            surfaceX            = 0.0;
            double            surfaceY            = 0.0;
            double            surfaceWidth        = 0.0;
            double            surfaceHeight       = 0.0;
            double            textureSourceX      = 0.0;
            double            textureSourceY      = 0.0;
            double            textureSourceWidth  = 0.0;
            double            textureSourceHeight = 0.0;
            uint32_t          transform           = 0;
            uint32_t          scale120            = 120;
            uint32_t          compositionOrder    = 0;
            float             opacity             = 1.F;
        };

        struct SWindowSnapshot {
            TSurfaceId                         objectId            = 0;
            TSurfaceId                         surfaceId           = 0;
            TWindowId                          windowId            = 0;
            int64_t                            textureId           = -1;
            uint32_t                           width               = 0;
            uint32_t                           height              = 0;
            double                             surfaceX            = 0.0;
            double                             surfaceY            = 0.0;
            double                             surfaceWidth        = 0.0;
            double                             surfaceHeight       = 0.0;
            double                             textureSourceX      = 0.0;
            double                             textureSourceY      = 0.0;
            double                             textureSourceWidth  = 0.0;
            double                             textureSourceHeight = 0.0;
            double                             geometryX           = 0.0;
            double                             geometryY           = 0.0;
            double                             geometryWidth       = 0.0;
            double                             geometryHeight      = 0.0;
            MONITORID                          monitorId           = -1;
            uint32_t                           transform           = 0;
            uint32_t                           scale120            = 120;
            int32_t                            stackingOrder       = 0;
            std::string                        title;
            std::string                        appId;
            bool                               rootSurface         = false;
            bool                               pinned              = false;
            bool                               suppressAnimations  = false;
            bool                               serverSideDecorated = true;
            float                              opacity             = 1.F;
            bool                               hasStatusColor      = false;
            uint32_t                           statusColorArgb     = STATUS_COLOR_FALLBACK_ARGB;
            double                             contentX            = 0.0;
            double                             contentY            = 0.0;
            double                             contentWidth        = 0.0;
            double                             contentHeight       = 0.0;
            PHLWINDOWREF                       nativeWindow;
            std::vector<SSurfaceLayerSnapshot> surfaces;
        };

        std::vector<SWindowSnapshot> windows;
        {
            std::lock_guard<std::mutex> lock(m_externalTextureMutex);
            windows.reserve(m_externalTextures.size());
            std::unordered_map<TWindowId, size_t>     bestByWindow;
            std::unordered_map<TWindowId, TSurfaceId> rootObjectByWindow;
            std::unordered_map<TWindowId, CBox>       presentedContentByWindow;
            bestByWindow.reserve(m_externalTextures.size());
            rootObjectByWindow.reserve(m_externalTextures.size());
            presentedContentByWindow.reserve(m_externalTextures.size());

            for (const auto& [surfaceId, record] : m_externalTextures) {
                if (record && !record->closing && !record->dragIcon && record->rootSurface) {
                    rootObjectByWindow[record->windowId] = surfaceId;
                    if (record->currentGeneration != 0 && record->surfaceWidth > 0.0 && record->surfaceHeight > 0.0) {
                        presentedContentByWindow[record->windowId] = CBox{
                            record->surfaceX,
                            record->surfaceY,
                            record->surfaceWidth,
                            record->surfaceHeight,
                        };
                    }
                }
            }

            const auto visibleWidth = [](const SWindowSnapshot& surface) {
                if (surface.surfaceWidth > 0.0)
                    return surface.surfaceWidth;
                if (surface.textureSourceWidth > 0.0)
                    return surface.textureSourceWidth;
                return sc<double>(surface.width);
            };
            const auto visibleHeight = [](const SWindowSnapshot& surface) {
                if (surface.surfaceHeight > 0.0)
                    return surface.surfaceHeight;
                if (surface.textureSourceHeight > 0.0)
                    return surface.textureSourceHeight;
                return sc<double>(surface.height);
            };
            const auto coversRootContent = [&](const SWindowSnapshot& child, const SWindowSnapshot& root) {
                if (child.rootSurface || !root.rootSurface || child.stackingOrder < 0)
                    return false;

                const auto rootWidth   = visibleWidth(root);
                const auto rootHeight  = visibleHeight(root);
                const auto childWidth  = visibleWidth(child);
                const auto childHeight = visibleHeight(child);
                if (rootWidth <= 0.0 || rootHeight <= 0.0 || childWidth <= 0.0 || childHeight <= 0.0)
                    return false;

                const auto overlapWidth  = std::max(0.0, std::min(child.surfaceX + childWidth, root.surfaceX + rootWidth) - std::max(child.surfaceX, root.surfaceX));
                const auto overlapHeight = std::max(0.0, std::min(child.surfaceY + childHeight, root.surfaceY + rootHeight) - std::max(child.surfaceY, root.surfaceY));
                return overlapWidth * overlapHeight >= rootWidth * rootHeight * 0.95;
            };
            const auto betterWindowSurface = [&](const SWindowSnapshot& candidate, const SWindowSnapshot& current) {
                if (candidate.rootSurface != current.rootSurface) {
                    const auto& child           = candidate.rootSurface ? current : candidate;
                    const auto& root            = candidate.rootSurface ? candidate : current;
                    const bool  childCoversRoot = coversRootContent(child, root);
                    if (childCoversRoot)
                        return !candidate.rootSurface;
                    return candidate.rootSurface;
                }

                if (!candidate.rootSurface && candidate.stackingOrder != current.stackingOrder)
                    return candidate.stackingOrder > current.stackingOrder;

                const auto candidateArea = visibleWidth(candidate) * visibleHeight(candidate);
                const auto currentArea   = visibleWidth(current) * visibleHeight(current);
                if (candidateArea != currentArea)
                    return candidateArea > currentArea;

                return candidate.surfaceId < current.surfaceId;
            };

            for (const auto& [surfaceId, record] : m_externalTextures) {
                // Popup surfaces are layers of their owner. They must never
                // replace the owner's primary texture or create another
                // logical window in the shell.
                if (!record || record->closing || record->dragIcon || record->textureId < 0 || record->popupRootSurfaceId != 0)
                    continue;

                const auto      rootObject = rootObjectByWindow.find(record->windowId);
                SWindowSnapshot snapshot{
                    // Surface selection may change while a client builds its
                    // initial tree. Keep the shell object's identity tied to
                    // the xdg root so placement, focus and overview state do
                    // not reset when a full-window child becomes preferable.
                    .objectId            = rootObject != rootObjectByWindow.end() ? rootObject->second : surfaceId,
                    .surfaceId           = surfaceId,
                    .windowId            = record->windowId,
                    .textureId           = record->textureId,
                    .width               = record->width,
                    .height              = record->height,
                    .surfaceX            = record->surfaceX,
                    .surfaceY            = record->surfaceY,
                    .surfaceWidth        = record->surfaceWidth,
                    .surfaceHeight       = record->surfaceHeight,
                    .textureSourceX      = record->textureSourceX,
                    .textureSourceY      = record->textureSourceY,
                    .textureSourceWidth  = record->textureSourceWidth,
                    .textureSourceHeight = record->textureSourceHeight,
                    .transform           = record->transform,
                    .scale120            = record->scale120,
                    .stackingOrder       = record->stackingOrder,
                    .title               = record->title,
                    .appId               = record->appId,
                    .rootSurface         = record->rootSurface,
                    .opacity             = surfaceOpacity(record->surface.lock()),
                    .hasStatusColor      = record->hasStatusColor,
                    .statusColorArgb     = record->statusColorArgb,
                    .nativeWindow        = record->window,
                };
                if (const auto nativeWindow = record->window.lock()) {
                    // openEarly can import a client's first buffer before its
                    // layout target has received final floating geometry. Do
                    // not expose that transient 0,0 box. SurfaceRegistry sends
                    // another snapshot from the final window.open boundary.
                    if (const auto target = nativeWindow->layoutTarget(); nativeWindow->m_isMapped && !nativeWindow->m_firstMap && target) {
                        const auto geometry     = target->position();
                        snapshot.geometryX      = geometry.x - m_displayLayout.globalOrigin.x;
                        snapshot.geometryY      = geometry.y - m_displayLayout.globalOrigin.y;
                        snapshot.geometryWidth  = geometry.w;
                        snapshot.geometryHeight = geometry.h;
                    }
                    if (const auto monitor = nativeWindow->m_monitor.lock())
                        snapshot.monitorId = monitor->m_id;
                    static auto PRESPECTCLIENTDECORATIONREQUESTS = CConfigValue<Config::INTEGER>("denial:respect_client_decoration_requests");

                    const bool  popupLike        = isPopupLikeWindow(nativeWindow);
                    const auto  rootSurface      = nativeWindow->wlSurface();
                    const bool  clientWantsFrame = !nativeWindow->m_X11DoesntWantBorders && (!rootSurface || rootSurface->m_serverSideDecoration);
                    snapshot.pinned              = nativeWindow->m_pinned;
                    snapshot.suppressAnimations  = popupLike;
                    snapshot.serverSideDecorated = WindowDecorationPolicy::drawsServerFrame({
                        .popupLike                = popupLike,
                        .respectClientPreference  = *PRESPECTCLIENTDECORATIONREQUESTS != 0,
                        .clientPrefersServerFrame = clientWantsFrame,
                    });
                }

                const auto [best, inserted] = bestByWindow.emplace(snapshot.windowId, windows.size());
                if (inserted) {
                    windows.push_back(std::move(snapshot));
                } else if (betterWindowSurface(snapshot, windows[best->second])) {
                    windows[best->second] = std::move(snapshot);
                }
            }

            for (auto& window : windows) {
                const auto NATIVE = window.nativeWindow.lock();
                const auto ROOT   = NATIVE && NATIVE->wlSurface() ? NATIVE->wlSurface()->resource() : nullptr;
                if (!NATIVE || !ROOT)
                    continue;

                // Keep coordinate metadata on the same presented generation
                // as the external texture. During a resize, wl_surface current
                // state can already describe a future Chromium buffer while
                // Flutter is deliberately stretching the preceding frame.
                // Publishing that future geometry would defeat the handoff.
                CBox contentRect;
                if (const auto presented = presentedContentByWindow.find(window.windowId); presented != presentedContentByWindow.end()) {
                    contentRect = presented->second;
                } else if (window.surfaceWidth > 0.0 && window.surfaceHeight > 0.0) {
                    // Some clients put the complete window in a child
                    // subsurface and never attach a root buffer. The selected
                    // presented layer is still a better resize source than a
                    // newer, not-yet-exposed root surface state.
                    contentRect = CBox{window.surfaceX, window.surfaceY, window.surfaceWidth, window.surfaceHeight};
                } else {
                    contentRect = CBox{0.0, 0.0, ROOT->m_current.size.x, ROOT->m_current.size.y};
                    if (!NATIVE->m_isX11) {
                        const auto XDG = NATIVE->m_xdgSurface.lock();
                        if (XDG && XDG->m_current.geometry.w > 0.0 && XDG->m_current.geometry.h > 0.0)
                            contentRect = XDG->m_current.geometry;
                    }
                }
                if (contentRect.w <= 0.0 || contentRect.h <= 0.0)
                    contentRect = CBox{0.0, 0.0, window.surfaceWidth, window.surfaceHeight};
                window.contentX      = contentRect.x;
                window.contentY      = contentRect.y;
                window.contentWidth  = contentRect.w;
                window.contentHeight = contentRect.h;

                uint32_t   compositionOrder = 0;
                const auto parentSurfaceId  = [](const SP<CWLSurfaceResource>& surface, ESurfaceLayerRole role) -> TSurfaceId {
                    if (!surface || !surface->m_role)
                        return 0;
                    if (surface->m_role->role() == SURFACE_ROLE_SUBSURFACE) {
                        const auto SUBSURFACE = sc<CSubsurfaceRole*>(surface->m_role.get())->m_subsurface.lock();
                        const auto PARENT     = SUBSURFACE ? SUBSURFACE->m_parent.lock() : nullptr;
                        return PARENT ? sc<TSurfaceId>(rc<uintptr_t>(PARENT.get())) : 0;
                    }
                    if (role == ESurfaceLayerRole::Popup && surface->m_role->role() == SURFACE_ROLE_XDG_SHELL) {
                        const auto XDG            = sc<CXDGSurfaceRole*>(surface->m_role.get())->m_xdgSurface.lock();
                        const auto POPUP          = XDG ? XDG->m_popup.lock() : nullptr;
                        const auto PARENT_XDG     = POPUP ? POPUP->m_parent.lock() : nullptr;
                        const auto PARENT_SURFACE = PARENT_XDG ? PARENT_XDG->m_surface.lock() : nullptr;
                        return PARENT_SURFACE ? sc<TSurfaceId>(rc<uintptr_t>(PARENT_SURFACE.get())) : 0;
                    }
                    return 0;
                };
                const auto addSurfaceLayer = [&](const SP<CWLSurfaceResource>& surface, const Vector2D& position, TSurfaceId popupRootSurfaceId, ESurfaceLayerRole role) {
                    if (!surface)
                        return;

                    SSurfaceLayerSnapshot layer;
                    layer.surfaceId           = sc<TSurfaceId>(rc<uintptr_t>(surface.get()));
                    layer.parentSurfaceId     = parentSurfaceId(surface, role);
                    layer.popupRootSurfaceId  = popupRootSurfaceId;
                    layer.role                = role;
                    layer.surfaceX            = position.x;
                    layer.surfaceY            = position.y;
                    layer.surfaceWidth        = surface->m_current.size.x;
                    layer.surfaceHeight       = surface->m_current.size.y;
                    layer.width               = surface->m_current.bufferSize.x > 0 ? sc<uint32_t>(surface->m_current.bufferSize.x) : 0;
                    layer.height              = surface->m_current.bufferSize.y > 0 ? sc<uint32_t>(surface->m_current.bufferSize.y) : 0;
                    layer.textureSourceWidth  = layer.width;
                    layer.textureSourceHeight = layer.height;
                    layer.transform           = sc<uint32_t>(surface->m_current.transform);
                    layer.scale120            = sc<uint32_t>(std::max(1, surface->m_current.scale) * 120);
                    layer.compositionOrder    = compositionOrder++;
                    layer.opacity             = surfaceOpacity(surface);

                    if (const auto TEXTURE = m_externalTextures.find(layer.surfaceId);
                        TEXTURE != m_externalTextures.end() && TEXTURE->second && !TEXTURE->second->closing && TEXTURE->second->textureId >= 0) {
                        const auto& RECORD        = *TEXTURE->second;
                        layer.textureId           = RECORD.textureId;
                        layer.width               = RECORD.width;
                        layer.height              = RECORD.height;
                        layer.textureSourceX      = RECORD.textureSourceX;
                        layer.textureSourceY      = RECORD.textureSourceY;
                        layer.textureSourceWidth  = RECORD.textureSourceWidth;
                        layer.textureSourceHeight = RECORD.textureSourceHeight;
                        layer.transform           = RECORD.transform;
                        layer.scale120            = RECORD.scale120;
                    }

                    if (role == ESurfaceLayerRole::Root && contentRect.w > 0.0 && contentRect.h > 0.0) {
                        layer.surfaceX      = contentRect.x;
                        layer.surfaceY      = contentRect.y;
                        layer.surfaceWidth  = contentRect.w;
                        layer.surfaceHeight = contentRect.h;
                    }

                    if (layer.surfaceWidth > 0.0 && layer.surfaceHeight > 0.0)
                        window.surfaces.emplace_back(std::move(layer));
                };

                ROOT->breadthfirst([&](SP<CWLSurfaceResource> surface, const Vector2D& offset,
                                       void*) { addSurfaceLayer(surface, offset, 0, surface == ROOT ? ESurfaceLayerRole::Root : ESurfaceLayerRole::Subsurface); },
                                   nullptr);

                if (!NATIVE->m_isX11 && NATIVE->m_popupHead) {
                    NATIVE->m_popupHead->breadthfirst(
                        [&](SP<Desktop::View::CPopup> popup, void*) {
                            if (!popup || !popup->wlSurface())
                                return;
                            const auto POPUP_ROOT = popup->wlSurface()->resource();
                            if (!POPUP_ROOT || !POPUP_ROOT->m_role || POPUP_ROOT->m_role->role() != SURFACE_ROLE_XDG_SHELL)
                                return;
                            const auto XDG = sc<CXDGSurfaceRole*>(POPUP_ROOT->m_role.get())->m_xdgSurface.lock();
                            if (!XDG || !XDG->m_mapped)
                                return;
                            const auto POPUP_ROOT_ID  = sc<TSurfaceId>(rc<uintptr_t>(POPUP_ROOT.get()));
                            const auto POPUP_POSITION = popup->coordsRelativeToParent();
                            POPUP_ROOT->breadthfirst(
                                [&](SP<CWLSurfaceResource> surface, const Vector2D& offset, void*) {
                                    addSurfaceLayer(surface, POPUP_POSITION + offset, POPUP_ROOT_ID,
                                                    surface == POPUP_ROOT ? ESurfaceLayerRole::Popup : ESurfaceLayerRole::Subsurface);
                                },
                                nullptr);
                        },
                        nullptr);
                }
            }
        }

        std::sort(windows.begin(), windows.end(), [](const SWindowSnapshot& lhs, const SWindowSnapshot& rhs) {
            const auto lhsHome = lhs.appId == "denia-home" || lhs.title == "denia-home";
            const auto rhsHome = rhs.appId == "denia-home" || rhs.title == "denia-home";
            if (lhsHome != rhsHome)
                return lhsHome;
            if (lhs.windowId != rhs.windowId)
                return lhs.windowId < rhs.windowId;
            return lhs.surfaceId < rhs.surfaceId;
        });

        size_t surfaceCount = 0;
        for (const auto& window : windows)
            surfaceCount += window.surfaces.size();
        flatbuffers::FlatBufferBuilder                 builder(1024 + windows.size() * 256 + surfaceCount * 192);
        std::vector<flatbuffers::Offset<Wire::Window>> wireWindows;
        wireWindows.reserve(windows.size());
        for (const auto& window : windows) {
            const auto title = window.title.size() <= BridgeWire::MAX_STRING_BYTES ? builder.CreateString(window.title) : builder.CreateString("");
            const auto appId = window.appId.size() <= BridgeWire::MAX_STRING_BYTES ? builder.CreateString(window.appId) : builder.CreateString("");
            std::vector<flatbuffers::Offset<Wire::SurfaceLayer>> wireSurfaces;
            wireSurfaces.reserve(window.surfaces.size());
            for (const auto& surface : window.surfaces) {
                const auto role = surface.role == ESurfaceLayerRole::Popup ? Wire::SurfaceRole_Popup :
                    surface.role == ESurfaceLayerRole::Subsurface          ? Wire::SurfaceRole_Subsurface :
                                                                             Wire::SurfaceRole_Root;
                wireSurfaces.emplace_back(Wire::CreateSurfaceLayer(
                    builder, surface.surfaceId, surface.parentSurfaceId, surface.popupRootSurfaceId, role, surface.textureId >= 0 ? sc<uint64_t>(surface.textureId) : 0,
                    surface.width, surface.height, surface.surfaceX, surface.surfaceY, surface.surfaceWidth, surface.surfaceHeight, surface.textureSourceX, surface.textureSourceY,
                    surface.textureSourceWidth, surface.textureSourceHeight, surface.transform, surface.scale120, surface.compositionOrder, surface.opacity));
            }
            wireWindows.emplace_back(Wire::CreateWindow(builder, window.objectId, Wire::ObjectKind_RootSurface, window.surfaceId, window.windowId, sc<uint64_t>(window.textureId),
                                                        title, appId, window.width, window.height, window.surfaceX, window.surfaceY, window.surfaceWidth, window.surfaceHeight,
                                                        window.textureSourceX, window.textureSourceY, window.textureSourceWidth, window.textureSourceHeight, window.geometryX,
                                                        window.geometryY, window.geometryWidth, window.geometryHeight, window.monitorId, window.transform, window.scale120,
                                                        window.statusColorArgb, window.hasStatusColor, window.contentX, window.contentY, window.contentWidth, window.contentHeight,
                                                        builder.CreateVector(wireSurfaces), window.pinned, window.suppressAnimations, window.serverSideDecorated, window.opacity));
        }

        const auto snapshot = Wire::CreateWindowSnapshot(builder, builder.CreateVector(wireWindows));
        const bool sent     = requestId == 0 ? sendWirePayload(builder, Wire::Payload_WindowSnapshot, snapshot.Union()) : [&] {
            const auto response = Wire::CreateWindowResponse(builder, Wire::WindowResponseKind_Windows, true, snapshot);
            return sendWirePayload(builder, Wire::Payload_WindowResponse, response.Union(), requestId);
        }();
        if (!sent && requestId == 0)
            Log::logger->log(Log::WARN, "Denial failed to publish window snapshot");
        else if (!sent)
            Log::logger->log(Log::WARN, "Denial failed to answer listWindows request={}", requestId);
        return sent;
    }

    bool CRuntime::sendDisplayLayoutResponse(uint64_t requestId) {
        if (!m_flutter || !denial_engine_host_running(m_flutter->host) || m_displayLayout.outputs.empty())
            return false;

        flatbuffers::FlatBufferBuilder                        builder(1024 + m_displayLayout.outputs.size() * 160);
        std::vector<flatbuffers::Offset<Wire::DisplayOutput>> outputs;
        outputs.reserve(m_displayLayout.outputs.size());
        for (const auto& output : m_displayLayout.outputs) {
            const auto           name = output.name.size() <= BridgeWire::MAX_STRING_BYTES ? builder.CreateString(output.name) : builder.CreateString("");
            const Wire::WireRect logicalRect{output.logicalRect.x, output.logicalRect.y, output.logicalRect.w, output.logicalRect.h};
            const Wire::WireSize pixelSize{output.pixelSize.x, output.pixelSize.y};
            const Wire::WireRect sourceRect{output.sourceRect.x, output.sourceRect.y, output.sourceRect.w, output.sourceRect.h};
            outputs.emplace_back(Wire::CreateDisplayOutput(builder, output.monitorId, name, &logicalRect, &pixelSize, &sourceRect, output.scale, output.refreshRate));
        }

        Wire::SystemBarSide side = Wire::SystemBarSide_Left;
        if (m_options.systemBarSide == "right")
            side = Wire::SystemBarSide_Right;
        else if (m_options.systemBarSide == "top")
            side = Wire::SystemBarSide_Top;
        else if (m_options.systemBarSide == "bottom")
            side = Wire::SystemBarSide_Bottom;
        else if (m_options.systemBarSide == "hidden")
            side = Wire::SystemBarSide_Hidden;

        const Wire::WirePoint globalOrigin{m_displayLayout.globalOrigin.x, m_displayLayout.globalOrigin.y};
        const Wire::WireSize  logicalSize{m_displayLayout.logicalSize.x, m_displayLayout.logicalSize.y};
        const Wire::WireSize  pixelSize{m_displayLayout.pixelSize.x, m_displayLayout.pixelSize.y};
        const auto            layout   = Wire::CreateDisplayLayout(builder, m_displayLayout.epoch, &globalOrigin, &logicalSize, &pixelSize, m_displayLayout.engineScale,
                                                                   m_displayLayout.tickerMonitorId, m_displayLayout.systemBarMonitorId, side, builder.CreateVector(outputs));
        const auto            response = Wire::CreateWindowResponse(builder, Wire::WindowResponseKind_DisplayLayout, true, 0, layout);
        return sendWirePayload(builder, Wire::Payload_WindowResponse, response.Union(), requestId);
    }

} // namespace Denial
