#pragma once

#include <ctime>
#include <vector>
#include <cstdint>
#include "WaylandProtocol.hpp"
#include "presentation-time.hpp"
#include "../helpers/time/Time.hpp"

class CMonitor;
class CWLSurfaceResource;

class CQueuedPresentationData {
  public:
    CQueuedPresentationData(SP<CWLSurfaceResource> surf);

    void setPresentationType(bool zeroCopy);
    void attachMonitor(PHLMONITOR pMonitor);
    void setCommitSequence(uint64_t sequence);

    void presented();
    void discarded();

    bool m_done = false;

  private:
    bool                   m_wasPresented = false;
    bool                   m_zeroCopy     = false;
    uint64_t               m_commitSequence = 0;
    PHLMONITORREF          m_monitor;
    WP<CWLSurfaceResource> m_surface;

    friend class CPresentationFeedback;
    friend class CPresentationProtocol;
};

class CPresentationFeedback {
  public:
    CPresentationFeedback(UP<CWpPresentationFeedback>&& resource_, SP<CWLSurfaceResource> surf);

    bool good();

    void sendQueued(WP<CQueuedPresentationData> data, const timespec& when, uint32_t untilRefreshNs, uint64_t seq, uint32_t reportedFlags);

  private:
    UP<CWpPresentationFeedback> m_resource;
    WP<CWLSurfaceResource>      m_surface;
    bool                        m_done = false;
    uint64_t                    m_commitSequence = 0;

    friend class CPresentationProtocol;
};

class CPresentationProtocol : public IWaylandProtocol {
  public:
    CPresentationProtocol(const wl_interface* iface, const int& ver, const std::string& name);

    virtual void bindManager(wl_client* client, void* data, uint32_t ver, uint32_t id);

    void         onPresented(PHLMONITOR pMonitor, const timespec& when, uint32_t untilRefreshNs, uint64_t seq, uint32_t reportedFlags);
    void         queueData(UP<CQueuedPresentationData>&& data);
    void         tagSurfaceFeedbacks(const SP<CWLSurfaceResource>& surface, uint64_t commitSequence);
    bool         hasPendingFeedbacks() const;
    bool         hasPendingFeedbackFor(const SP<CWLSurfaceResource>& surface) const;

  private:
    void onManagerResourceDestroy(wl_resource* res);
    void destroyResource(CPresentationFeedback* feedback);
    void onGetFeedback(CWpPresentation* pMgr, wl_resource* surf, uint32_t id);

    //
    std::vector<UP<CWpPresentation>>         m_managers;
    std::vector<UP<CPresentationFeedback>>   m_feedbacks;
    std::vector<UP<CQueuedPresentationData>> m_queue;

    friend class CPresentationFeedback;
};

namespace PROTO {
    inline UP<CPresentationProtocol> presentation;
};
