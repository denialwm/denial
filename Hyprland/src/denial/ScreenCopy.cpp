#include "ScreenCopy.hpp"

namespace Denial {
    namespace {
        IScreenCopyFrameProvider* g_provider = nullptr;
    }

    void setScreenCopyFrameProvider(IScreenCopyFrameProvider* provider) {
        g_provider = provider;
    }

    bool renderLatestOutputFrame(PHLMONITOR monitor, const CBox& captureBox, bool overlayCursor) {
        return g_provider && g_provider->renderLatestOutputFrame(monitor, captureBox, overlayCursor);
    }

} // namespace Denial
