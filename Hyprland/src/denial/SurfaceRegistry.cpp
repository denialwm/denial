#include "SurfaceRegistry.hpp"

#include "../Compositor.hpp"
#include "../debug/log/Logger.hpp"
#include "../desktop/view/Window.hpp"
#include "../desktop/view/WLSurface.hpp"
#include "../desktop/view/Popup.hpp"
#include "../event/EventBus.hpp"
#include "../helpers/time/Time.hpp"
#include "../protocols/XDGShell.hpp"
#include "../protocols/PresentationTime.hpp"
#include "../protocols/core/Compositor.hpp"
#include "../protocols/core/Subcompositor.hpp"
#include "../xwayland/XSurface.hpp"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <drm_fourcc.h>
#include <limits>
#include <utility>

namespace Denial {

    namespace {
        TSurfaceId globalSurfaceId(const SP<CWLSurfaceResource>& surface) {
            return sc<TSurfaceId>(rc<uintptr_t>(surface.get()));
        }

        uint64_t steadyUs(const Time::steady_tp& now) {
            return sc<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(now.time_since_epoch()).count());
        }

        uint8_t scale10To8(uint32_t value) {
            return sc<uint8_t>((value * 255U + 511U) / 1023U);
        }

        std::shared_ptr<const std::vector<uint8_t>> copyShmToRgba(const CHLBufferReference& buffer, uint32_t width, uint32_t height) {
            if (!buffer || width == 0 || height == 0)
                return {};

            const auto attrs = buffer->shm();
            const auto rowBytes = sc<size_t>(width) * 4U;
            if (!attrs.success || attrs.stride <= 0 || sc<size_t>(attrs.stride) < rowBytes ||
                height > std::numeric_limits<size_t>::max() / rowBytes)
                return {};

            switch (attrs.format) {
                case DRM_FORMAT_ARGB8888:
                case DRM_FORMAT_XRGB8888:
                case DRM_FORMAT_ABGR8888:
                case DRM_FORMAT_XBGR8888:
                case DRM_FORMAT_ARGB2101010:
                case DRM_FORMAT_XRGB2101010:
                case DRM_FORMAT_ABGR2101010:
                case DRM_FORMAT_XBGR2101010: break;
                default: return {};
            }

            auto [data, _, bytes] = buffer->beginDataPtr(0);
            if (!data || bytes < sc<size_t>(attrs.stride) * height) {
                buffer->endDataPtr();
                return {};
            }

            auto pixels = std::make_shared<std::vector<uint8_t>>(rowBytes * height);
            const auto convert8888 = [&](uint8_t redByte, uint8_t blueByte, bool copyAlpha) {
                for (uint32_t y = 0; y < height; ++y) {
                    const auto* source = data + sc<size_t>(y) * attrs.stride;
                    auto*       target = pixels->data() + sc<size_t>(y) * rowBytes;
                    for (uint32_t x = 0; x < width; ++x) {
                        const auto offset = sc<size_t>(x) * 4U;
                        target[offset + 0U] = source[offset + redByte];
                        target[offset + 1U] = source[offset + 1U];
                        target[offset + 2U] = source[offset + blueByte];
                        target[offset + 3U] = copyAlpha ? source[offset + 3U] : 255U;
                    }
                }
            };
            const auto convert2101010 = [&](bool redInLowBits, bool copyAlpha) {
                for (uint32_t y = 0; y < height; ++y) {
                    const auto* source = data + sc<size_t>(y) * attrs.stride;
                    auto*       target = pixels->data() + sc<size_t>(y) * rowBytes;
                    for (uint32_t x = 0; x < width; ++x) {
                        const auto offset = sc<size_t>(x) * 4U;
                        uint32_t   value  = 0;
                        std::memcpy(&value, source + offset, sizeof(value));

                        const auto low  = scale10To8(value & 0x3ffU);
                        const auto high = scale10To8((value >> 20U) & 0x3ffU);
                        target[offset + 0U] = redInLowBits ? low : high;
                        target[offset + 1U] = scale10To8((value >> 10U) & 0x3ffU);
                        target[offset + 2U] = redInLowBits ? high : low;
                        target[offset + 3U] = copyAlpha ? sc<uint8_t>((((value >> 30U) & 0x3U) * 255U + 1U) / 3U) : 255U;
                    }
                }
            };

            switch (attrs.format) {
                case DRM_FORMAT_ARGB8888: convert8888(2U, 0U, true); break;
                case DRM_FORMAT_XRGB8888: convert8888(2U, 0U, false); break;
                case DRM_FORMAT_ABGR8888: convert8888(0U, 2U, true); break;
                case DRM_FORMAT_XBGR8888: convert8888(0U, 2U, false); break;
                case DRM_FORMAT_ARGB2101010: convert2101010(false, true); break;
                case DRM_FORMAT_XRGB2101010: convert2101010(false, false); break;
                case DRM_FORMAT_ABGR2101010: convert2101010(true, true); break;
                case DRM_FORMAT_XBGR2101010: convert2101010(true, false); break;
                default: break;
            }

            buffer->endDataPtr();
            return pixels;
        }
    }

    CSurfaceRegistry::~CSurfaceRegistry() {
        stop();
    }

    void CSurfaceRegistry::start(ISurfaceFrameConsumer* consumer) {
        if (m_running)
            stop();

        m_consumer = consumer;
        m_running  = true;

        m_listeners.windowOpenEarly = Event::bus()->m_events.window.openEarly.listen([this](PHLWINDOW window) { trackWindow(window, "openEarly"); });
        m_listeners.windowOpen = Event::bus()->m_events.window.open.listen([this](PHLWINDOW window) {
            trackWindow(window, "open");
            if (m_consumer && window)
                m_consumer->onWindowMapped(window->m_stableID);
        });
        m_listeners.windowClose     = Event::bus()->m_events.window.close.listen([this](PHLWINDOW window) { removeWindow(window); });
        m_listeners.windowDestroy   = Event::bus()->m_events.window.destroy.listen([this](PHLWINDOW window) { removeWindow(window); });
        m_listeners.windowPin       = Event::bus()->m_events.window.pin.listen([this](PHLWINDOW window) {
            if (m_consumer && window)
                m_consumer->onWindowStateChanged(window->m_stableID);
        });

        trackExistingWindows();
        Log::logger->log(Log::INFO, "Denial surface registry started");
    }

    void CSurfaceRegistry::stop() {
        if (!m_running)
            return;

        if (m_consumer) {
            for (auto& [surfaceId, record] : m_surfaces) {
                if (record)
                    m_consumer->onSurfaceGone(surfaceId, record->windowId);
            }
        }

        m_listeners.windowOpenEarly.reset();
        m_listeners.windowOpen.reset();
        m_listeners.windowClose.reset();
        m_listeners.windowDestroy.reset();
        m_listeners.windowPin.reset();
        m_dragIconSurfaceId = 0;
        m_surfaces.clear();
        m_windows.clear();
        m_consumer = nullptr;
        m_running  = false;
        Log::logger->log(Log::INFO, "Denial surface registry stopped");
    }

    bool CSurfaceRegistry::running() const {
        return m_running;
    }

    void CSurfaceRegistry::trackDragIcon(SP<CWLSurfaceResource> surface) {
        if (!m_running || !surface)
            return;

        const auto SURFACE_ID = globalSurfaceId(surface);
        if (m_dragIconSurfaceId == SURFACE_ID && m_surfaces.contains(SURFACE_ID))
            return;

        clearDragIcon();

        auto record         = makeUnique<SSurfaceRecord>();
        record->surfaceId   = SURFACE_ID;
        record->surface     = surface;
        record->rootSurface = true;
        record->dragIcon    = true;
        record->surfaceRole = ESurfaceLayerRole::Root;
        record->commit      = surface->m_events.commit.listen([this, SURFACE_ID] { handleSurfaceCommit(SURFACE_ID); });
        record->destroy     = surface->m_events.destroy.listen([this, SURFACE_ID] { removeSurface(SURFACE_ID); });

        m_dragIconSurfaceId = SURFACE_ID;
        m_surfaces.emplace(SURFACE_ID, std::move(record));
        handleSurfaceCommit(SURFACE_ID);
    }

    void CSurfaceRegistry::clearDragIcon() {
        if (m_dragIconSurfaceId == 0)
            return;

        const auto SURFACE_ID = std::exchange(m_dragIconSurfaceId, 0);
        removeSurface(SURFACE_ID);
    }

    bool CSurfaceRegistry::resolveSurface(TSurfaceId surfaceId, PHLWINDOW& window, SP<CWLSurfaceResource>& surface, ESurfaceLayerRole& role,
                                          TSurfaceId& popupRootSurfaceId) const {
        const auto IT = m_surfaces.find(surfaceId);
        if (IT == m_surfaces.end() || !IT->second || !IT->second->mapped)
            return false;

        window             = IT->second->window.lock();
        surface            = IT->second->surface.lock();
        role               = IT->second->surfaceRole;
        popupRootSurfaceId = IT->second->popupRootSurfaceId;
        return window && surface;
    }

    bool CSurfaceRegistry::hasFrameCallbacks(PHLMONITOR monitor) const {
        if (!m_running || !monitor)
            return false;

        for (const auto& [_, record] : m_surfaces) {
            if (!record)
                continue;

            const auto SURFACE = record->surface.lock();
            const auto WINDOW  = record->window.lock();
            const bool VISIBLE = record->dragIcon ? g_pCompositor && g_pCompositor->getMonitorFromCursor() == monitor :
                                                    WINDOW && WINDOW->m_isMapped && WINDOW->m_monitor == monitor;
            if (record->mapped && VISIBLE && SURFACE && !SURFACE->m_current.callbacks.empty())
                return true;
        }

        return false;
    }

    uint32_t CSurfaceRegistry::sendFrameCallbacks(PHLMONITOR monitor) {
        if (!m_running || !monitor)
            return 0;

        const auto NOW  = Time::steadyNow();
        uint32_t   sent = 0;

        for (auto& [_, record] : m_surfaces) {
            if (!record)
                continue;

            const auto SURFACE = record->surface.lock();
            const auto WINDOW  = record->window.lock();
            const bool VISIBLE = record->dragIcon ? g_pCompositor && g_pCompositor->getMonitorFromCursor() == monitor :
                                                    WINDOW && WINDOW->m_isMapped && WINDOW->m_monitor == monitor;
            if (!record->mapped || !VISIBLE || !SURFACE)
                continue;

            const auto SURFACE_SENT = SURFACE->frame(NOW);
            sent += SURFACE_SENT;
            if (SURFACE_SENT > 0)
                record->frameCallbackUs = steadyUs(NOW);
        }

        return sent;
    }

    uint32_t CSurfaceRegistry::sendFrameCallbacksFor(const std::unordered_set<TSurfaceId>& surfaceIds, PHLMONITOR monitor,
                                                     std::unordered_set<TSurfaceId>* surfacesWithCallbacks) {
        if (!m_running || surfaceIds.empty() || !monitor)
            return 0;

        const auto NOW  = Time::steadyNow();
        uint32_t   sent = 0;

        for (const auto SURFACE_ID : surfaceIds) {
            const auto IT = m_surfaces.find(SURFACE_ID);
            if (IT == m_surfaces.end() || !IT->second)
                continue;

            const auto SURFACE = IT->second->surface.lock();
            const auto WINDOW  = IT->second->window.lock();
            const bool VISIBLE = IT->second->dragIcon ? g_pCompositor && g_pCompositor->getMonitorFromCursor() == monitor :
                                                        WINDOW && WINDOW->m_isMapped && WINDOW->m_monitor == monitor;
            if (!IT->second->mapped || !VISIBLE || !SURFACE)
                continue;

            const auto SURFACE_SENT = SURFACE->frame(NOW);
            sent += SURFACE_SENT;
            if (SURFACE_SENT > 0) {
                IT->second->frameCallbackUs = steadyUs(NOW);
                if (surfacesWithCallbacks)
                    surfacesWithCallbacks->insert(SURFACE_ID);
            }
        }

        return sent;
    }

    void CSurfaceRegistry::sendPresentFeedbackFor(const std::unordered_map<TSurfaceId, uint64_t>& surfaceGenerations, PHLMONITOR monitor) {
        if (!m_running || surfaceGenerations.empty() || !monitor)
            return;

        for (const auto& [SURFACE_ID, GENERATION] : surfaceGenerations) {
            const auto IT = m_surfaces.find(SURFACE_ID);
            // Presentation feedback is tagged with the imported generation at
            // commit time. A newer client commit may therefore coexist with
            // this older in-flight generation without stealing its feedback.
            if (IT == m_surfaces.end() || !IT->second)
                continue;

            const auto SURFACE = IT->second->surface.lock();
            const auto WINDOW  = IT->second->window.lock();
            const bool VISIBLE = IT->second->dragIcon ? g_pCompositor && g_pCompositor->getMonitorFromCursor() == monitor :
                                                        WINDOW && WINDOW->m_isMapped && WINDOW->m_monitor == monitor;
            if (!IT->second->mapped || !VISIBLE || !SURFACE)
                continue;

            // Flutter owns wl_surface.frame dispatch separately on the
            // surface's output. Queue only presentation feedback here so
            // independent output clocks cannot combine into a synthetic rate.
            SURFACE->queuePresentationFeedback(monitor, false, GENERATION);
        }
    }

    void CSurfaceRegistry::trackExistingWindows() {
        if (!g_pCompositor)
            return;

        for (const auto& window : g_pCompositor->m_windows) {
            if (window && window->m_isMapped)
                trackWindow(window, "existing");
        }
    }

    void CSurfaceRegistry::trackWindow(PHLWINDOW window, const char* reason) {
        if (!window)
            return;

        const bool TRACE_CLIENT = window->m_class != "denia-home" && window->m_title != "denia-home";
        const auto HLSURFACE    = window->wlSurface();
        const auto ROOT         = HLSURFACE ? HLSURFACE->resource() : nullptr;
        if (!HLSURFACE || !ROOT) {
            if (TRACE_CLIENT)
                Log::logger->log(Log::INFO, "Denial trackWindow skipped: reason={} window={} title='{}' class='{}' mapped={} has_hl_surface={} has_root={}", reason,
                                 window->m_stableID, window->m_title, window->m_class, window->m_isMapped, HLSURFACE != nullptr, ROOT != nullptr);
            return;
        }

        const auto WINDOW_ID = window->m_stableID;
        auto&      record    = m_windows[WINDOW_ID];
        const auto BEFORE    = record.surfaces.size();
        record.window        = window;

        // Override-redirect X11 windows (notifications, tooltips, menus) can
        // animate by changing only their X geometry. There may be no surface
        // commit to otherwise tell the embedded scene that the window moved.
        if (!record.x11GeometryChanged && window->m_isX11 && window->isX11OverrideRedirect() && window->m_xwaylandSurface) {
            record.x11GeometryChanged = window->m_xwaylandSurface->m_events.setGeometry.listen([this, WINDOW_ID] {
                if (!m_consumer)
                    return;

                const auto IT = m_windows.find(WINDOW_ID);
                if (IT == m_windows.end())
                    return;

                const auto WINDOW = IT->second.window.lock();
                if (!WINDOW || !WINDOW->m_isMapped)
                    return;

                m_consumer->onWindowGeometryChanged(WINDOW_ID, WINDOW->m_realPosition->goal(), WINDOW->m_realSize->goal());
            });
        }

        if (!record.newPopup && !window->m_isX11) {
            const auto XDG = window->m_xdgSurface.lock();
            if (XDG)
                record.newPopup = XDG->m_events.newPopup.listen([this, WINDOW = PHLWINDOWREF{window}](SP<CXDGPopupResource> popup) {
                    if (const auto LOCKED = WINDOW.lock())
                        trackPopup(LOCKED, popup);
                });
        }

        trackSurface(window, ROOT);

        ROOT->breadthfirst([this, window](SP<CWLSurfaceResource> surface, const Vector2D&, void*) { trackSurface(window, surface); }, nullptr);
        trackExistingPopups(window);

        if (TRACE_CLIENT)
            Log::logger->log(Log::INFO,
                             "Denial trackWindow: reason={} window={} title='{}' class='{}' mapped={} root={:x} surfaces_before={} surfaces_after={} root_buffer={} "
                             "root_texture={} root_size={} root_subsurfaces={}",
                             reason, WINDOW_ID, window->m_title, window->m_class, window->m_isMapped, rc<uintptr_t>(ROOT.get()), BEFORE, record.surfaces.size(),
                             ROOT->m_current.buffer ? 1 : 0, ROOT->m_current.texture ? 1 : 0, ROOT->m_current.bufferSize, ROOT->m_subsurfaces.size());
    }

    void CSurfaceRegistry::trackSurface(PHLWINDOW window, SP<CWLSurfaceResource> surface, TSurfaceId popupRootSurfaceId, bool mapped) {
        if (!window || !surface)
            return;

        const auto SURFACE_ID = globalSurfaceId(surface);
        if (m_surfaces.contains(SURFACE_ID))
            return;

        auto record         = makeUnique<SSurfaceRecord>();
        record->surfaceId   = SURFACE_ID;
        record->windowId    = window->m_stableID;
        record->window      = window;
        record->surface     = surface;
        record->rootSurface = surface == window->wlSurface()->resource();
        record->popupRootSurfaceId = popupRootSurfaceId;
        record->mapped             = mapped;
        record->surfaceRole        = record->rootSurface ? ESurfaceLayerRole::Root :
            popupRootSurfaceId == SURFACE_ID             ? ESurfaceLayerRole::Popup : ESurfaceLayerRole::Subsurface;

        if (surface->m_role && surface->m_role->role() == SURFACE_ROLE_SUBSURFACE) {
            const auto ROLE       = sc<CSubsurfaceRole*>(surface->m_role.get());
            const auto SUBSURFACE = ROLE->m_subsurface.lock();
            const auto PARENT     = SUBSURFACE ? SUBSURFACE->m_parent.lock() : nullptr;
            if (PARENT)
                record->parentSurfaceId = globalSurfaceId(PARENT);
        } else if (record->surfaceRole == ESurfaceLayerRole::Popup && surface->m_role && surface->m_role->role() == SURFACE_ROLE_XDG_SHELL) {
            const auto ROLE   = sc<CXDGSurfaceRole*>(surface->m_role.get());
            const auto XDG    = ROLE->m_xdgSurface.lock();
            const auto POPUP  = XDG ? XDG->m_popup.lock() : nullptr;
            const auto PARENT = POPUP ? POPUP->m_parent.lock() : nullptr;
            const auto PARENT_SURFACE = PARENT ? PARENT->m_surface.lock() : nullptr;
            if (PARENT_SURFACE)
                record->parentSurfaceId = globalSurfaceId(PARENT_SURFACE);
        }

        record->commit        = surface->m_events.commit.listen([this, SURFACE_ID] { handleSurfaceCommit(SURFACE_ID); });
        record->destroy       = surface->m_events.destroy.listen([this, SURFACE_ID] { removeSurface(SURFACE_ID); });
        if (const auto HLSURFACE = Desktop::View::CWLSurface::fromResource(surface)) {
            record->appearanceChanged = HLSURFACE->m_events.appearanceChanged.listen(
                [this, WINDOW_ID = record->windowId] { notifySurfaceTreeChanged(WINDOW_ID); });
        }
        record->newSubsurface = surface->m_events.newSubsurface.listen([this, SURFACE_ID](SP<CWLSubsurfaceResource> subsurface) { handleNewSubsurface(SURFACE_ID, subsurface); });

        m_windows[record->windowId].surfaces.emplace_back(SURFACE_ID);
        m_surfaces.emplace(SURFACE_ID, std::move(record));

        if (window->m_class != "denia-home" && window->m_title != "denia-home")
            Log::logger->log(Log::INFO, "Denial trackSurface: surface={} window={} title='{}' class='{}' root={} buffer={} texture={} size={} subsurfaces={}", SURFACE_ID,
                             window->m_stableID, window->m_title, window->m_class, surface == window->wlSurface()->resource(), surface->m_current.buffer ? 1 : 0,
                             surface->m_current.texture ? 1 : 0, surface->m_current.bufferSize, surface->m_subsurfaces.size());

        handleSurfaceCommit(SURFACE_ID);
    }

    void CSurfaceRegistry::trackPopup(PHLWINDOW window, SP<CXDGPopupResource> popup) {
        if (!window || !popup)
            return;

        const auto XDG     = popup->m_surface.lock();
        const auto SURFACE = XDG ? XDG->m_surface.lock() : nullptr;
        if (!XDG || !SURFACE)
            return;

        const auto POPUP_ROOT_ID = globalSurfaceId(SURFACE);
        const bool MAPPED        = XDG->m_mapped;
        trackSurface(window, SURFACE, POPUP_ROOT_ID, MAPPED);
        SURFACE->breadthfirst(
            [this, window, POPUP_ROOT_ID, MAPPED](SP<CWLSurfaceResource> child, const Vector2D&, void*) {
                trackSurface(window, child, POPUP_ROOT_ID, MAPPED);
            },
            nullptr);

        const auto IT = m_surfaces.find(POPUP_ROOT_ID);
        if (IT == m_surfaces.end() || !IT->second)
            return;

        auto& record = *IT->second;
        if (!record.popupMap)
            record.popupMap = XDG->m_events.map.listen([this, POPUP_ROOT_ID] { handlePopupMapped(POPUP_ROOT_ID, true); });
        if (!record.popupUnmap)
            record.popupUnmap = XDG->m_events.unmap.listen([this, POPUP_ROOT_ID] { handlePopupMapped(POPUP_ROOT_ID, false); });
        if (!record.popupNewPopup)
            record.popupNewPopup = XDG->m_events.newPopup.listen([this, WINDOW = PHLWINDOWREF{window}](SP<CXDGPopupResource> child) {
                if (const auto LOCKED = WINDOW.lock())
                    trackPopup(LOCKED, child);
            });
        if (!record.popupReposition)
            record.popupReposition = popup->m_events.reposition.listen([this, WINDOW_ID = window->m_stableID] { notifySurfaceTreeChanged(WINDOW_ID); });
        if (!record.popupDestroy)
            record.popupDestroy = popup->m_events.destroy.listen([this, POPUP_ROOT_ID] { removePopup(POPUP_ROOT_ID); });

        notifySurfaceTreeChanged(window->m_stableID);
    }

    void CSurfaceRegistry::trackExistingPopups(PHLWINDOW window) {
        if (!window || window->m_isX11 || !window->m_popupHead)
            return;

        window->m_popupHead->breadthfirst(
            [this, window](SP<Desktop::View::CPopup> popup, void*) {
                if (!popup || !popup->wlSurface())
                    return;
                const auto SURFACE = popup->wlSurface()->resource();
                if (!SURFACE || !SURFACE->m_role || SURFACE->m_role->role() != SURFACE_ROLE_XDG_SHELL)
                    return;
                const auto ROLE     = sc<CXDGSurfaceRole*>(SURFACE->m_role.get());
                const auto XDG      = ROLE->m_xdgSurface.lock();
                const auto RESOURCE = XDG ? XDG->m_popup.lock() : nullptr;
                if (RESOURCE)
                    trackPopup(window, RESOURCE);
            },
            nullptr);
    }

    void CSurfaceRegistry::removeWindow(PHLWINDOW window) {
        if (!window)
            return;

        const auto WINDOW_ID = window->m_stableID;
        const auto IT        = m_windows.find(WINDOW_ID);
        if (IT == m_windows.end())
            return;

        const auto SURFACES = IT->second.surfaces;
        if (m_consumer)
            m_consumer->onWindowGone(WINDOW_ID, SURFACES);

        for (const auto SURFACE_ID : SURFACES)
            m_surfaces.erase(SURFACE_ID);

        m_windows.erase(IT);
    }

    void CSurfaceRegistry::removeSurface(TSurfaceId surfaceId) {
        const auto IT = m_surfaces.find(surfaceId);
        if (IT == m_surfaces.end())
            return;

        const auto WINDOW_ID = IT->second->windowId;
        if (m_dragIconSurfaceId == surfaceId)
            m_dragIconSurfaceId = 0;
        if (m_consumer)
            m_consumer->onSurfaceGone(surfaceId, WINDOW_ID);

        if (auto windowIt = m_windows.find(WINDOW_ID); windowIt != m_windows.end())
            std::erase(windowIt->second.surfaces, surfaceId);

        m_surfaces.erase(IT);
        notifySurfaceTreeChanged(WINDOW_ID);
    }

    void CSurfaceRegistry::removePopup(TSurfaceId popupRootSurfaceId) {
        std::vector<TSurfaceId> surfaces;
        for (const auto& [SURFACE_ID, RECORD] : m_surfaces) {
            if (RECORD && RECORD->popupRootSurfaceId == popupRootSurfaceId)
                surfaces.emplace_back(SURFACE_ID);
        }
        for (const auto SURFACE_ID : surfaces)
            removeSurface(SURFACE_ID);
    }

    void CSurfaceRegistry::handlePopupMapped(TSurfaceId popupRootSurfaceId, bool mapped) {
        TWindowId              windowId = 0;
        std::vector<TSurfaceId> surfaces;
        for (auto& [SURFACE_ID, RECORD] : m_surfaces) {
            if (!RECORD || RECORD->popupRootSurfaceId != popupRootSurfaceId)
                continue;
            RECORD->mapped = mapped;
            windowId       = RECORD->windowId;
            surfaces.emplace_back(SURFACE_ID);
            if (!mapped) {
                RECORD->generation = 0;
                RECORD->frameCallbackUs = 0;
                if (m_consumer)
                    m_consumer->onSurfaceGone(SURFACE_ID, RECORD->windowId);
            }
        }

        if (mapped) {
            for (const auto SURFACE_ID : surfaces)
                handleSurfaceCommit(SURFACE_ID);
        }
        notifySurfaceTreeChanged(windowId);
    }

    void CSurfaceRegistry::notifySurfaceTreeChanged(TWindowId windowId) {
        if (m_consumer && windowId != 0)
            m_consumer->onSurfaceTreeChanged(windowId);
    }

    void CSurfaceRegistry::handleSurfaceCommit(TSurfaceId surfaceId) {
        if (!m_consumer)
            return;

        const auto IT = m_surfaces.find(surfaceId);
        if (IT == m_surfaces.end())
            return;

        const auto& RECORD = *IT->second;
        const auto WINDOW  = RECORD.window.lock();
        const auto SURFACE = IT->second->surface.lock();
        if ((!WINDOW && !RECORD.dragIcon) || !SURFACE || !RECORD.mapped)
            return;

        const auto& STATE = SURFACE->m_current;

        // A frame callback is a request to be notified about the next visual
        // transaction, not visual content by itself. In particular, Chromium
        // may commit only another callback (or rotate to an identically sized
        // buffer with empty damage) immediately after every callback it
        // receives. Treating that as a new external-texture generation closes
        // a self-sustaining max-refresh loop: callback -> no-op commit ->
        // Flutter frame -> KMS commit -> callback.
        //
        // Import the first buffer unconditionally so an already-mapped surface
        // can bootstrap. Afterwards Wayland damage is authoritative. Viewport
        // state is included because it changes how the existing pixels are
        // sampled even without changing the buffer contents. Buffer-size,
        // scale, and transform changes already acquire full damage in the
        // wl_surface state path.
        const bool HAS_DAMAGE = STATE.updated.bits.damage && (!STATE.damage.empty() || !STATE.bufferDamage.empty());
        const bool HAS_VISUAL_UPDATE = RECORD.generation == 0 || HAS_DAMAGE || STATE.updated.bits.viewport || (RECORD.dragIcon && STATE.updated.bits.offset);

        // Frame callbacks belong to individual wl_surfaces. Firefox, for
        // example, renders its browser contents into a full-window child
        // subsurface and waits for callbacks there rather than on the xdg
        // root. Any surface in the mapped window tree can therefore create
        // output demand.
        if (!STATE.callbacks.empty())
            m_consumer->onSurfaceFrameCallbackDemand();

        if (RECORD.dragIcon && !STATE.buffer) {
            if (RECORD.generation != 0) {
                IT->second->generation = 0;
                m_consumer->onSurfaceGone(surfaceId, 0);
            }
            return;
        }

        if (!HAS_VISUAL_UPDATE)
            return;

        if (!STATE.buffer)
            return;

        const auto       BUFFER = STATE.buffer;

        SSurfaceFrameRef frame;
        frame.surfaceId = surfaceId;
        frame.parentSurfaceId = IT->second->parentSurfaceId;
        frame.popupRootSurfaceId = IT->second->popupRootSurfaceId;
        frame.windowId  = IT->second->windowId;
        frame.dragIcon  = RECORD.dragIcon;
        frame.buffer    = BUFFER;

        if (BUFFER->type() == Aquamarine::BUFFER_TYPE_DMABUF) {
            const auto DMABUF = BUFFER->dmabuf();
            if (!DMABUF.success)
                return;
            frame.dmabuf = DMABUF;
            frame.width  = DMABUF.size.x > 0 ? sc<uint32_t>(DMABUF.size.x) : sc<uint32_t>(SURFACE->m_current.bufferSize.x);
            frame.height = DMABUF.size.y > 0 ? sc<uint32_t>(DMABUF.size.y) : sc<uint32_t>(SURFACE->m_current.bufferSize.y);
        } else if (BUFFER->type() == Aquamarine::BUFFER_TYPE_SHM) {
            frame.width      = sc<uint32_t>(SURFACE->m_current.bufferSize.x);
            frame.height     = sc<uint32_t>(SURFACE->m_current.bufferSize.y);
            frame.rgbaPixels = copyShmToRgba(BUFFER, frame.width, frame.height);
            if (!frame.rgbaPixels)
                return;
        } else {
            return;
        }

        frame.generation     = ++IT->second->generation;
        if (PROTO::presentation)
            PROTO::presentation->tagSurfaceFeedbacks(SURFACE, frame.generation);
        frame.transform      = sc<uint32_t>(SURFACE->m_current.transform);
        frame.scale120       = sc<uint32_t>(std::max(1, SURFACE->m_current.scale) * 120);
        frame.surfaceWidth   = SURFACE->m_current.size.x;
        frame.surfaceHeight  = SURFACE->m_current.size.y;
        if (RECORD.dragIcon) {
            frame.surfaceX = STATE.offset.x;
            frame.surfaceY = STATE.offset.y;
        } else if (!IT->second->rootSurface && SURFACE->m_role && SURFACE->m_role->role() == SURFACE_ROLE_SUBSURFACE) {
            const auto ROLE       = sc<CSubsurfaceRole*>(SURFACE->m_role.get());
            const auto SUBSURFACE = ROLE->m_subsurface.lock();
            if (SUBSURFACE) {
                const auto POSITION = SUBSURFACE->posRelativeToParent();
                frame.stackingOrder = SUBSURFACE->m_zIndex;
                frame.surfaceX      = POSITION.x;
                frame.surfaceY      = POSITION.y;
            }
        }
        if (SURFACE->m_current.viewport.hasSource) {
            const auto& SOURCE       = SURFACE->m_current.viewport.source;
            frame.textureSourceX     = SOURCE.x;
            frame.textureSourceY     = SOURCE.y;
            frame.textureSourceWidth = SOURCE.w;
            frame.textureSourceHeight = SOURCE.h;
        } else {
            frame.textureSourceWidth  = frame.width;
            frame.textureSourceHeight = frame.height;
        }

        if (IT->second->rootSurface && WINDOW) {
            const auto XDG = WINDOW->m_xdgSurface.lock();
            if (XDG) {
                const auto& GEOMETRY = XDG->m_current.geometry;
                const auto& SIZE     = SURFACE->m_current.size;
                if (GEOMETRY.w > 0.0 && GEOMETRY.h > 0.0 && SIZE.x > 0.0 && SIZE.y > 0.0) {
                    const double SOURCE_RIGHT  = frame.textureSourceX + frame.textureSourceWidth;
                    const double SOURCE_BOTTOM = frame.textureSourceY + frame.textureSourceHeight;
                    const double X1 = frame.textureSourceX + GEOMETRY.x * frame.textureSourceWidth / SIZE.x;
                    const double Y1 = frame.textureSourceY + GEOMETRY.y * frame.textureSourceHeight / SIZE.y;
                    const double X2 = frame.textureSourceX + (GEOMETRY.x + GEOMETRY.w) * frame.textureSourceWidth / SIZE.x;
                    const double Y2 = frame.textureSourceY + (GEOMETRY.y + GEOMETRY.h) * frame.textureSourceHeight / SIZE.y;
                    const double CLAMPED_X1 = std::clamp(X1, frame.textureSourceX, SOURCE_RIGHT);
                    const double CLAMPED_Y1 = std::clamp(Y1, frame.textureSourceY, SOURCE_BOTTOM);
                    const double CLAMPED_X2 = std::clamp(X2, CLAMPED_X1, SOURCE_RIGHT);
                    const double CLAMPED_Y2 = std::clamp(Y2, CLAMPED_Y1, SOURCE_BOTTOM);

                    if (CLAMPED_X2 > CLAMPED_X1 && CLAMPED_Y2 > CLAMPED_Y1) {
                        frame.surfaceX           = GEOMETRY.x;
                        frame.surfaceY           = GEOMETRY.y;
                        frame.surfaceWidth       = GEOMETRY.w;
                        frame.surfaceHeight      = GEOMETRY.h;
                        frame.textureSourceX     = CLAMPED_X1;
                        frame.textureSourceY     = CLAMPED_Y1;
                        frame.textureSourceWidth = CLAMPED_X2 - CLAMPED_X1;
                        frame.textureSourceHeight = CLAMPED_Y2 - CLAMPED_Y1;
                    }
                }
            }
        }
        const auto COMMIT_US = steadyUs(Time::steadyNow());
        if (IT->second->frameCallbackUs > 0 && COMMIT_US >= IT->second->frameCallbackUs)
            frame.renderDurationUs = COMMIT_US - IT->second->frameCallbackUs;
        IT->second->frameCallbackUs = 0;
        frame.rootSurface           = IT->second->rootSurface;
        frame.surfaceRole           = IT->second->surfaceRole;
        frame.window                = WINDOW;
        frame.surface               = SURFACE;

        m_consumer->onSurfaceFrame(std::move(frame));
    }

    void CSurfaceRegistry::handleNewSubsurface(TSurfaceId parentSurfaceId, SP<CWLSubsurfaceResource> subsurface) {
        if (!subsurface)
            return;

        const auto PARENT = m_surfaces.find(parentSurfaceId);
        if (PARENT == m_surfaces.end())
            return;

        const auto WINDOW  = PARENT->second->window.lock();
        const auto SURFACE = subsurface->m_surface.lock();
        if (!WINDOW || !SURFACE)
            return;

        const auto POPUP_ROOT_ID = PARENT->second->popupRootSurfaceId;
        const bool MAPPED        = PARENT->second->mapped;
        trackSurface(WINDOW, SURFACE, POPUP_ROOT_ID, MAPPED);
        SURFACE->breadthfirst(
            [this, WINDOW, POPUP_ROOT_ID, MAPPED](SP<CWLSurfaceResource> surface, const Vector2D&, void*) {
                trackSurface(WINDOW, surface, POPUP_ROOT_ID, MAPPED);
            },
            nullptr);
        notifySurfaceTreeChanged(WINDOW->m_stableID);
    }

} // namespace Denial
