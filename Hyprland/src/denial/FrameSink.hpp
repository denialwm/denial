#pragma once

#include "../desktop/DesktopTypes.hpp"

namespace Denial {

    class IFrameSink {
      public:
        virtual ~IFrameSink() = default;

        virtual bool claimsMonitor(PHLMONITOR monitor) = 0;
        virtual void renderMonitor(PHLMONITOR monitor) = 0;
    };

    void        setFrameSink(IFrameSink* sink);
    IFrameSink* frameSink();

} // namespace Denial
