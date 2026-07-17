#include "InputRouter.hpp"

namespace Denial {

    namespace {
        IInputRouter* g_inputRouter = nullptr;
    }

    void setInputRouter(IInputRouter* router) {
        g_inputRouter = router;
    }

    IInputRouter* inputRouter() {
        return g_inputRouter;
    }

} // namespace Denial
