#include "FrameSink.hpp"

namespace Denial {

    namespace {
        IFrameSink* g_frameSink = nullptr;
    }

    void setFrameSink(IFrameSink* sink) {
        g_frameSink = sink;
    }

    IFrameSink* frameSink() {
        return g_frameSink;
    }

} // namespace Denial
