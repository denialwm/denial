#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace Denial {

    struct SAudioStream {
        uint32_t    id = 0;
        std::string name;
        double      level = 0.0;
        bool        muted = false;
    };

    class CAudioController {
      public:
        using TStateCallback   = std::function<void(double, uint32_t)>;
        using TStreamsCallback = std::function<void(const std::vector<SAudioStream>&)>;

        explicit CAudioController(TStateCallback stateCallback, TStreamsCallback streamsCallback);
        ~CAudioController();

        CAudioController(const CAudioController&)            = delete;
        CAudioController& operator=(const CAudioController&) = delete;

        void              requestState();
        void              setLevel(double level, uint32_t requestSerial = 0);
        void              adjustLevel(double delta);
        void              toggleMute();
        void              requestStreams();
        void              setStreamLevel(uint32_t streamId, double level);

      private:
        class CImpl;
        std::unique_ptr<CImpl> m_impl;
    };

}
