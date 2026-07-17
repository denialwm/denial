#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace Denial {

    enum class ENotificationEventKind : uint8_t {
        Added,
        Replaced,
        Closed,
    };

    enum class ENotificationUrgency : uint8_t {
        Low,
        Normal,
        Critical,
    };

    struct SNotificationAction {
        std::string key;
        std::string label;
    };

    struct SNotificationImageData {
        uint32_t             width         = 0;
        uint32_t             height        = 0;
        uint32_t             rowStride     = 0;
        bool                 hasAlpha      = false;
        uint8_t              bitsPerSample = 8;
        uint8_t              channels      = 0;
        std::vector<uint8_t> data;
    };

    struct SNotification {
        uint32_t                              id = 0;
        std::string                           sender;
        std::string                           appName;
        std::string                           appIcon;
        std::string                           summary;
        std::string                           body;
        std::vector<SNotificationAction>      actions;
        ENotificationUrgency                  urgency = ENotificationUrgency::Normal;
        std::string                           category;
        std::string                           desktopEntry;
        std::string                           imagePath;
        std::optional<SNotificationImageData> imageData;
        bool                                  resident      = false;
        bool                                  transient     = false;
        bool                                  suppressSound = false;
        bool                                  actionIcons   = false;
        std::string                           soundName;
        std::string                           soundFile;
        int32_t                               x               = 0;
        int32_t                               y               = 0;
        bool                                  hasPosition     = false;
        int32_t                               progress        = 0;
        bool                                  hasProgress     = false;
        int32_t                               expireTimeoutMs = -1;
    };

    struct SNotificationEvent {
        ENotificationEventKind kind = ENotificationEventKind::Added;
        SNotification          notification;
        uint32_t               notificationId = 0;
        uint32_t               closeReason    = 0;
    };

    class CNotificationServer {
      public:
        using TEventCallback = std::function<void(SNotificationEvent)>;

        explicit CNotificationServer(TEventCallback eventCallback);
        ~CNotificationServer();

        CNotificationServer(const CNotificationServer&)            = delete;
        CNotificationServer& operator=(const CNotificationServer&) = delete;

        bool                 start();
        void                 stop();
        bool                 dismiss(uint32_t notificationId);
        bool                 invokeAction(uint32_t notificationId, std::string actionKey);

      private:
        class CImpl;
        std::unique_ptr<CImpl> m_impl;
    };

} // namespace Denial
