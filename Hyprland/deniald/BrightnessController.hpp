#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace Denial {

    class CBrightnessController {
      public:
        using TStateCallback = std::function<void(int64_t, double)>;

        explicit CBrightnessController(TStateCallback stateCallback);
        ~CBrightnessController();

        CBrightnessController(const CBrightnessController&)            = delete;
        CBrightnessController& operator=(const CBrightnessController&) = delete;

        // Queues a relative change for a DRM connector. Calls are cheap and
        // never perform DDC traffic on the compositor/input thread.
        void adjustLevel(const std::string& connector, int64_t monitorId, double delta);
        void setLevel(const std::string& connector, int64_t monitorId, double level);

      private:
        class CImpl;
        std::unique_ptr<CImpl> m_impl;
    };

}
