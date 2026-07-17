#include "XDGDecoration.hpp"
#include "XDGShell.hpp"
#include "../desktop/view/WLSurface.hpp"
#include "core/Compositor.hpp"
#include <algorithm>

namespace {
    void applyDecorationMode(wl_resource* toplevelResource, zxdgToplevelDecorationV1Mode mode) {
        const auto TOPLEVEL = CXDGToplevelResource::fromResource(toplevelResource);
        const auto XDG      = TOPLEVEL ? TOPLEVEL->m_owner.lock() : nullptr;
        const auto RESOURCE = XDG ? XDG->m_surface.lock() : nullptr;
        if (!RESOURCE)
            return;

        const bool SERVER_SIDE = mode == ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE;
        RESOURCE->m_serverSideDecoration = SERVER_SIDE;

        const auto SURFACE  = Desktop::View::CWLSurface::fromResource(RESOURCE);
        if (!SURFACE)
            return;

        if (SURFACE->m_serverSideDecoration == SERVER_SIDE)
            return;

        SURFACE->m_serverSideDecoration = SERVER_SIDE;
        SURFACE->m_events.appearanceChanged.emit();
    }
}

CXDGDecoration::CXDGDecoration(SP<CZxdgToplevelDecorationV1> resource_, wl_resource* toplevel) : m_resource(resource_), m_toplevelResource(toplevel) {
    if UNLIKELY (!m_resource->resource())
        return;

    m_resource->setDestroy([this](CZxdgToplevelDecorationV1* pMgr) { PROTO::xdgDecoration->destroyDecoration(this); });
    m_resource->setOnDestroy([this](CZxdgToplevelDecorationV1* pMgr) { PROTO::xdgDecoration->destroyDecoration(this); });

    m_resource->setSetMode([this](CZxdgToplevelDecorationV1*, zxdgToplevelDecorationV1Mode mode) {
        std::string modeString;
        switch (mode) {
            case ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE: modeString = "MODE_CLIENT_SIDE"; break;
            case ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE: modeString = "MODE_SERVER_SIDE"; break;
            default: modeString = "INVALID"; break;
        }

        LOGM(Log::DEBUG, "setMode: {}. Honoring the requested decoration mode.", modeString);
        auto sendMode = xdgModeOnRequestCSD(mode);
        m_resource->sendConfigure(sendMode);
        mostRecentlySent      = sendMode;
        mostRecentlyRequested = mode;
        applyDecorationMode(m_toplevelResource, sendMode);
    });

    m_resource->setUnsetMode([this](CZxdgToplevelDecorationV1*) {
        LOGM(Log::DEBUG, "unsetMode. Sending MODE_SERVER_SIDE.");
        auto sendMode = xdgModeOnReleaseCSD();
        m_resource->sendConfigure(sendMode);
        mostRecentlySent      = sendMode;
        mostRecentlyRequested = 0;
        applyDecorationMode(m_toplevelResource, sendMode);
    });

    auto sendMode = xdgDefaultModeCSD();
    m_resource->sendConfigure(sendMode);
    mostRecentlySent = sendMode;
    applyDecorationMode(m_toplevelResource, sendMode);
}

zxdgToplevelDecorationV1Mode CXDGDecoration::xdgDefaultModeCSD() {
    return ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE;
}

zxdgToplevelDecorationV1Mode CXDGDecoration::xdgModeOnRequestCSD(uint32_t modeRequestedByClient) {
    return modeRequestedByClient == ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE ? ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE :
                                                                                   ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE;
}

zxdgToplevelDecorationV1Mode CXDGDecoration::xdgModeOnReleaseCSD() {
    return xdgDefaultModeCSD();
}

bool CXDGDecoration::good() {
    return m_resource->resource();
}

wl_resource* CXDGDecoration::toplevelResource() {
    return m_toplevelResource;
}

CXDGDecorationProtocol::CXDGDecorationProtocol(const wl_interface* iface, const int& ver, const std::string& name) : IWaylandProtocol(iface, ver, name) {
    ;
}

void CXDGDecorationProtocol::bindManager(wl_client* client, void* data, uint32_t ver, uint32_t id) {
    const auto RESOURCE = m_managers.emplace_back(makeUnique<CZxdgDecorationManagerV1>(client, ver, id)).get();
    RESOURCE->setOnDestroy([this](CZxdgDecorationManagerV1* p) { this->onManagerResourceDestroy(p->resource()); });

    RESOURCE->setDestroy([this](CZxdgDecorationManagerV1* pMgr) { this->onManagerResourceDestroy(pMgr->resource()); });
    RESOURCE->setGetToplevelDecoration([this](CZxdgDecorationManagerV1* pMgr, uint32_t id, wl_resource* xdgToplevel) { this->onGetDecoration(pMgr, id, xdgToplevel); });
}

void CXDGDecorationProtocol::onManagerResourceDestroy(wl_resource* res) {
    std::erase_if(m_managers, [&](const auto& other) { return other->resource() == res; });
}

void CXDGDecorationProtocol::destroyDecoration(CXDGDecoration* decoration) {
    applyDecorationMode(decoration->toplevelResource(), ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
    m_decorations.erase(decoration->toplevelResource());
}

void CXDGDecorationProtocol::onGetDecoration(CZxdgDecorationManagerV1* pMgr, uint32_t id, wl_resource* xdgToplevel) {
    if UNLIKELY (m_decorations.contains(xdgToplevel)) {
        pMgr->error(ZXDG_TOPLEVEL_DECORATION_V1_ERROR_ALREADY_CONSTRUCTED, "Decoration object already exists");
        return;
    }

    const auto CLIENT = pMgr->client();
    const auto RESOURCE =
        m_decorations.emplace(xdgToplevel, makeUnique<CXDGDecoration>(makeShared<CZxdgToplevelDecorationV1>(CLIENT, pMgr->version(), id), xdgToplevel)).first->second.get();

    if UNLIKELY (!RESOURCE->good()) {
        pMgr->noMemory();
        m_decorations.erase(xdgToplevel);
        return;
    }
}
