#pragma once

#include "../desktop/DesktopTypes.hpp"
#include "../helpers/math/Math.hpp"
#include "../helpers/memory/Memory.hpp"

namespace Denial {

    class IScreenCopyFrameProvider {
      public:
        virtual ~IScreenCopyFrameProvider() = default;

        virtual bool renderLatestOutputFrame(PHLMONITOR monitor, const CBox& captureBox, bool overlayCursor) = 0;
    };

    void setScreenCopyFrameProvider(IScreenCopyFrameProvider* provider);
    bool renderLatestOutputFrame(PHLMONITOR monitor, const CBox& captureBox, bool overlayCursor);

} // namespace Denial
