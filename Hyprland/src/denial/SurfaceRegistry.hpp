#pragma once

#include "BridgeAPI.hpp"

#include "../helpers/signal/Signal.hpp"

#include <unordered_map>
#include <unordered_set>
#include <vector>

class CWLSurfaceResource;
class CWLSubsurfaceResource;
class CXDGPopupResource;

namespace Denial {

    class CSurfaceRegistry {
      public:
        CSurfaceRegistry() = default;
        ~CSurfaceRegistry();

        void     start(ISurfaceFrameConsumer* consumer);
        void     stop();

        bool     running() const;
        void     trackDragIcon(SP<CWLSurfaceResource> surface);
        void     clearDragIcon();
        bool     hasFrameCallbacks(PHLMONITOR monitor) const;
        uint32_t sendFrameCallbacks(PHLMONITOR monitor);
        uint32_t sendFrameCallbacksFor(const std::unordered_set<TSurfaceId>& surfaceIds, PHLMONITOR monitor,
                                       std::unordered_set<TSurfaceId>* surfacesWithCallbacks = nullptr);
        void     sendPresentFeedbackFor(const std::unordered_map<TSurfaceId, uint64_t>& surfaceGenerations, PHLMONITOR monitor);
        bool     resolveSurface(TSurfaceId surfaceId, PHLWINDOW& window, SP<CWLSurfaceResource>& surface, ESurfaceLayerRole& role,
                                TSurfaceId& popupRootSurfaceId) const;

      private:
        struct SWindowRecord {
            PHLWINDOWREF            window;
            std::vector<TSurfaceId> surfaces;
            CHyprSignalListener     x11GeometryChanged;
            CHyprSignalListener     newPopup;
        };

        struct SSurfaceRecord {
            TSurfaceId             surfaceId  = 0;
            TSurfaceId             parentSurfaceId = 0;
            TSurfaceId             popupRootSurfaceId = 0;
            TWindowId              windowId   = 0;
            uint64_t               generation = 0;
            uint64_t               frameCallbackUs = 0;
            PHLWINDOWREF           window;
            WP<CWLSurfaceResource> surface;
            bool                   rootSurface = false;
            bool                   dragIcon    = false;
            bool                   mapped      = true;
            ESurfaceLayerRole      surfaceRole = ESurfaceLayerRole::Root;

            CHyprSignalListener    commit;
            CHyprSignalListener    destroy;
            CHyprSignalListener    appearanceChanged;
            CHyprSignalListener    newSubsurface;
            CHyprSignalListener    popupMap;
            CHyprSignalListener    popupUnmap;
            CHyprSignalListener    popupNewPopup;
            CHyprSignalListener    popupReposition;
            CHyprSignalListener    popupDestroy;
        };

        void                                               trackExistingWindows();
        void                                               trackWindow(PHLWINDOW window, const char* reason = "scan");
        void                                               trackSurface(PHLWINDOW window, SP<CWLSurfaceResource> surface, TSurfaceId popupRootSurfaceId = 0,
                                                                        bool mapped = true);
        void                                               trackPopup(PHLWINDOW window, SP<CXDGPopupResource> popup);
        void                                               trackExistingPopups(PHLWINDOW window);
        void                                               removeWindow(PHLWINDOW window);
        void                                               removeSurface(TSurfaceId surfaceId);
        void                                               removePopup(TSurfaceId popupRootSurfaceId);
        void                                               handleSurfaceCommit(TSurfaceId surfaceId);
        void                                               handleNewSubsurface(TSurfaceId parentSurfaceId, SP<CWLSubsurfaceResource> subsurface);
        void                                               handlePopupMapped(TSurfaceId popupRootSurfaceId, bool mapped);
        void                                               notifySurfaceTreeChanged(TWindowId windowId);

        ISurfaceFrameConsumer*                             m_consumer = nullptr;
        bool                                               m_running  = false;

        std::unordered_map<TWindowId, SWindowRecord>       m_windows;
        std::unordered_map<TSurfaceId, UP<SSurfaceRecord>> m_surfaces;
        TSurfaceId                                         m_dragIconSurfaceId = 0;

        struct {
            CHyprSignalListener windowOpenEarly;
            CHyprSignalListener windowOpen;
            CHyprSignalListener windowClose;
            CHyprSignalListener windowDestroy;
            CHyprSignalListener windowPin;
        } m_listeners;
    };

} // namespace Denial
