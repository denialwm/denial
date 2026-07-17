#include "NotificationServer.hpp"

#include "../src/debug/log/Logger.hpp"

#include <gio/gio.h>

#include <algorithm>
#include <condition_variable>
#include <deque>
#include <limits>
#include <mutex>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <utility>

namespace Denial {

    namespace {
        constexpr const char* SERVICE_NAME = "org.freedesktop.Notifications";
        constexpr const char* OBJECT_PATH  = "/org/freedesktop/Notifications";
        constexpr const char* INTERFACE    = "org.freedesktop.Notifications";

        constexpr size_t      MAX_STRING_BYTES     = 4096;
        constexpr size_t      MAX_ACTIONS          = 16;
        constexpr size_t      MAX_IMAGE_DATA_BYTES = 512 * 1024;
        constexpr size_t      MAX_NOTIFICATIONS    = 256;

        constexpr const char* INTROSPECTION_XML = R"XML(
<node>
  <interface name="org.freedesktop.Notifications">
    <method name="GetCapabilities">
      <arg name="capabilities" type="as" direction="out"/>
    </method>
    <method name="Notify">
      <arg name="app_name" type="s" direction="in"/>
      <arg name="replaces_id" type="u" direction="in"/>
      <arg name="app_icon" type="s" direction="in"/>
      <arg name="summary" type="s" direction="in"/>
      <arg name="body" type="s" direction="in"/>
      <arg name="actions" type="as" direction="in"/>
      <arg name="hints" type="a{sv}" direction="in"/>
      <arg name="expire_timeout" type="i" direction="in"/>
      <arg name="id" type="u" direction="out"/>
    </method>
    <method name="CloseNotification">
      <arg name="id" type="u" direction="in"/>
    </method>
    <method name="GetServerInformation">
      <arg name="name" type="s" direction="out"/>
      <arg name="vendor" type="s" direction="out"/>
      <arg name="version" type="s" direction="out"/>
      <arg name="spec_version" type="s" direction="out"/>
    </method>
    <signal name="NotificationClosed">
      <arg name="id" type="u"/>
      <arg name="reason" type="u"/>
    </signal>
    <signal name="ActionInvoked">
      <arg name="id" type="u"/>
      <arg name="action_key" type="s"/>
    </signal>
  </interface>
</node>
)XML";

        std::string           boundedString(const char* value) {
            if (!value)
                return {};

            const auto length = std::char_traits<char>::length(value);
            if (length <= MAX_STRING_BYTES)
                return {value, length};

            const char* validEnd = nullptr;
            g_utf8_validate(value, MAX_STRING_BYTES, &validEnd);
            return {value, static_cast<size_t>(validEnd - value)};
        }

        bool lookupBoolean(GVariant* hints, const char* key) {
            gboolean value = false;
            return hints && g_variant_lookup(hints, key, "b", &value) && value;
        }

        std::string lookupString(GVariant* hints, const char* key) {
            const char* value = nullptr;
            return hints && g_variant_lookup(hints, key, "&s", &value) ? boundedString(value) : std::string{};
        }
    } // namespace

    class CNotificationServer::CImpl {
      public:
        explicit CImpl(TEventCallback eventCallback) : m_eventCallback(std::move(eventCallback)) {}

        ~CImpl() {
            stop();
        }

        bool start() {
            std::unique_lock lock(m_threadMutex);
            if (m_thread.joinable())
                return m_started;

            m_threadReady = false;
            m_started     = false;
            m_thread      = std::thread([this] { run(); });
            m_threadCondition.wait(lock, [this] { return m_threadReady; });
            return m_started;
        }

        void stop() {
            GMainContext* context = nullptr;
            GMainLoop*    loop    = nullptr;
            {
                std::lock_guard lock(m_threadMutex);
                if (!m_thread.joinable())
                    return;
                if (m_context)
                    context = g_main_context_ref(m_context);
                if (m_loop)
                    loop = g_main_loop_ref(m_loop);
            }

            if (context && loop) {
                g_main_context_invoke_full(
                    context, G_PRIORITY_HIGH,
                    [](gpointer data) -> gboolean {
                        g_main_loop_quit(static_cast<GMainLoop*>(data));
                        return G_SOURCE_REMOVE;
                    },
                    loop, [](gpointer data) { g_main_loop_unref(static_cast<GMainLoop*>(data)); });
            } else if (loop) {
                g_main_loop_unref(loop);
            }
            if (context)
                g_main_context_unref(context);

            m_thread.join();
        }

        bool dismiss(uint32_t id) {
            return postCommand(SCommandData{.server = this, .kind = ECommandKind::Dismiss, .id = id});
        }

        bool invokeAction(uint32_t id, std::string actionKey) {
            return postCommand(SCommandData{.server = this, .kind = ECommandKind::InvokeAction, .id = id, .actionKey = std::move(actionKey)});
        }

      private:
        struct SStoredNotification {
            SNotification                   notification;
            GSource*                        expirySource = nullptr;
            std::unordered_set<std::string> invokedActions;
        };

        struct SExpiryData {
            CImpl*   server = nullptr;
            uint32_t id     = 0;
        };

        enum class ECommandKind : uint8_t {
            Dismiss,
            InvokeAction,
        };

        struct SCommandData {
            CImpl*       server = nullptr;
            ECommandKind kind   = ECommandKind::Dismiss;
            uint32_t     id     = 0;
            std::string  actionKey;
        };

        bool postCommand(SCommandData command) {
            GMainContext* context = nullptr;
            {
                std::lock_guard lock(m_threadMutex);
                if (!m_thread.joinable() || !m_context)
                    return false;
                context = g_main_context_ref(m_context);
            }

            g_main_context_invoke_full(
                context, G_PRIORITY_DEFAULT,
                [](gpointer data) -> gboolean {
                    auto* command = static_cast<SCommandData*>(data);
                    if (command->kind == ECommandKind::Dismiss)
                        command->server->handleDismiss(command->id);
                    else
                        command->server->handleInvokeAction(command->id, command->actionKey);
                    return G_SOURCE_REMOVE;
                },
                new SCommandData(std::move(command)), [](gpointer data) { delete static_cast<SCommandData*>(data); });
            g_main_context_unref(context);
            return true;
        }

        void run() {
            auto* context = g_main_context_new();
            auto* loop    = g_main_loop_new(context, false);
            g_main_context_push_thread_default(context);

            GError* error       = nullptr;
            m_introspectionData = g_dbus_node_info_new_for_xml(INTROSPECTION_XML, &error);
            if (!m_introspectionData) {
                Log::logger->log(Log::ERR, "Denial notifications could not parse D-Bus introspection: {}", error ? error->message : "unknown error");
                g_clear_error(&error);
            }

            const bool started = m_introspectionData && connectAndExport();

            {
                std::lock_guard lock(m_threadMutex);
                m_context     = context;
                m_loop        = loop;
                m_started     = started;
                m_threadReady = true;
            }
            m_threadCondition.notify_all();

            if (started)
                g_main_loop_run(loop);

            clearStoredNotifications();
            if (m_ownerId != 0) {
                g_bus_unown_name(m_ownerId);
                m_ownerId = 0;
            }
            clearConnection();
            if (m_introspectionData) {
                g_dbus_node_info_unref(m_introspectionData);
                m_introspectionData = nullptr;
            }

            g_main_context_pop_thread_default(context);
            {
                std::lock_guard lock(m_threadMutex);
                m_context = nullptr;
                m_loop    = nullptr;
                m_started = false;
            }
            g_main_loop_unref(loop);
            g_main_context_unref(context);
        }

        bool connectAndExport() {
            GError* error   = nullptr;
            auto*   address = g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, nullptr, &error);
            if (!address) {
                Log::logger->log(Log::ERR, "Denial notifications could not resolve the session D-Bus: {}", error ? error->message : "unknown error");
                g_clear_error(&error);
                return false;
            }

            m_connection = g_dbus_connection_new_for_address_sync(
                address, static_cast<GDBusConnectionFlags>(G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION), nullptr, nullptr,
                &error);
            g_free(address);
            if (!m_connection) {
                Log::logger->log(Log::ERR, "Denial notifications could not connect to the session D-Bus: {}", error ? error->message : "unknown error");
                g_clear_error(&error);
                return false;
            }

            static const GDBusInterfaceVTable VTABLE = {
                .method_call  = &CImpl::onMethodCall,
                .get_property = nullptr,
                .set_property = nullptr,
            };

            m_registrationId = g_dbus_connection_register_object(m_connection, OBJECT_PATH, m_introspectionData->interfaces[0], &VTABLE, this, nullptr, &error);
            if (m_registrationId == 0) {
                Log::logger->log(Log::ERR, "Denial notifications could not export D-Bus object: {}", error ? error->message : "unknown error");
                g_clear_error(&error);
                clearConnection();
                return false;
            }

            m_ownerId = g_bus_own_name_on_connection(m_connection, SERVICE_NAME, G_BUS_NAME_OWNER_FLAGS_NONE, &CImpl::onNameAcquired, &CImpl::onNameLost, this, nullptr);
            if (m_ownerId == 0) {
                Log::logger->log(Log::ERR, "Denial notifications could not request org.freedesktop.Notifications");
                clearConnection();
                return false;
            }
            return true;
        }

        static void onNameAcquired(GDBusConnection*, const char*, gpointer) {
            Log::logger->log(Log::INFO, "Denial notification service acquired org.freedesktop.Notifications");
        }

        static void onNameLost(GDBusConnection* connection, const char*, gpointer userData) {
            if (connection && !g_dbus_connection_is_closed(connection))
                Log::logger->log(Log::WARN, "Denial notification service name is already owned by another daemon");
            else
                Log::logger->log(Log::WARN, "Denial notification service could not connect to the session D-Bus");
        }

        static void onMethodCall(GDBusConnection*, const char* sender, const char*, const char*, const char* method, GVariant* parameters, GDBusMethodInvocation* invocation,
                                 gpointer userData) {
            auto* self = static_cast<CImpl*>(userData);
            if (std::string_view{method} == "GetCapabilities") {
                // Keep this list deliberately conservative. Denial sanitizes
                // markup into plain text and does not currently play sounds or
                // persist notifications across sessions.
                const char* capabilities[] = {"actions", "body", "icon-static", nullptr};
                g_dbus_method_invocation_return_value(invocation, g_variant_new("(^as)", capabilities));
                return;
            }
            if (std::string_view{method} == "GetServerInformation") {
                g_dbus_method_invocation_return_value(invocation, g_variant_new("(ssss)", "Denial", "Denial", "0.1.0", "1.3"));
                return;
            }
            if (std::string_view{method} == "Notify") {
                self->handleNotify(sender, parameters, invocation);
                return;
            }
            if (std::string_view{method} == "CloseNotification") {
                guint32 id = 0;
                g_variant_get(parameters, "(u)", &id);
                if (!self->closeNotification(id, 3)) {
                    g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.Notifications.Error.UnknownNotification", "Unknown notification ID");
                    return;
                }
                g_dbus_method_invocation_return_value(invocation, nullptr);
                return;
            }
            g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown notification method");
        }

        void handleNotify(const char* sender, GVariant* parameters, GDBusMethodInvocation* invocation) {
            const char* appName       = nullptr;
            const char* appIcon       = nullptr;
            const char* summary       = nullptr;
            const char* body          = nullptr;
            guint32     replacesId    = 0;
            gint32      expireTimeout = -1;
            GVariant*   actions       = nullptr;
            GVariant*   hints         = nullptr;
            g_variant_get(parameters, "(&su&s&s&s@as@a{sv}i)", &appName, &replacesId, &appIcon, &summary, &body, &actions, &hints, &expireTimeout);

            const bool replacing = replacesId != 0 && m_notifications.contains(replacesId);
            if (!replacing && m_notifications.size() >= MAX_NOTIFICATIONS && !m_notificationOrder.empty())
                closeNotification(m_notificationOrder.front(), 4);

            const auto id           = replacing ? replacesId : nextNotificationId();
            auto       notification = parseNotification(sender, id, appName, appIcon, summary, body, actions, hints, expireTimeout);
            g_variant_unref(actions);
            g_variant_unref(hints);

            if (replacing)
                cancelExpiry(m_notifications.at(id));

            auto& stored          = m_notifications[id];
            stored.notification   = notification;
            stored.invokedActions = {};
            if (!replacing)
                m_notificationOrder.push_back(id);
            armExpiry(stored);

            g_dbus_method_invocation_return_value(invocation, g_variant_new("(u)", id));
            publish(SNotificationEvent{
                .kind           = replacing ? ENotificationEventKind::Replaced : ENotificationEventKind::Added,
                .notification   = std::move(notification),
                .notificationId = id,
            });
        }

        SNotification parseNotification(const char* sender, uint32_t id, const char* appName, const char* appIcon, const char* summary, const char* body, GVariant* actions,
                                        GVariant* hints, int32_t expireTimeout) const {
            SNotification notification{
                .id              = id,
                .sender          = boundedString(sender),
                .appName         = boundedString(appName),
                .appIcon         = boundedString(appIcon),
                .summary         = boundedString(summary),
                .body            = boundedString(body),
                .expireTimeoutMs = expireTimeout,
            };

            const auto actionPairCount = g_variant_n_children(actions) / 2;
            notification.actions.reserve(std::min<gsize>(actionPairCount, MAX_ACTIONS));
            std::unordered_set<std::string> actionKeys;
            for (gsize index = 0; index < actionPairCount && notification.actions.size() < MAX_ACTIONS; ++index) {
                const char* key   = nullptr;
                const char* label = nullptr;
                g_variant_get_child(actions, index * 2, "&s", &key);
                g_variant_get_child(actions, index * 2 + 1, "&s", &label);
                auto boundedKey = boundedString(key);
                if (boundedKey.empty() || !actionKeys.emplace(boundedKey).second)
                    continue;
                notification.actions.emplace_back(SNotificationAction{.key = std::move(boundedKey), .label = boundedString(label)});
            }

            guchar urgency = 1;
            if (g_variant_lookup(hints, "urgency", "y", &urgency))
                urgency = std::min<guchar>(urgency, 2);
            notification.urgency      = static_cast<ENotificationUrgency>(urgency);
            notification.category     = lookupString(hints, "category");
            notification.desktopEntry = lookupString(hints, "desktop-entry");
            notification.imagePath    = lookupString(hints, "image-path");
            if (notification.imagePath.empty())
                notification.imagePath = lookupString(hints, "image_path");
            notification.resident      = lookupBoolean(hints, "resident");
            notification.transient     = lookupBoolean(hints, "transient");
            notification.suppressSound = lookupBoolean(hints, "suppress-sound");
            notification.actionIcons   = lookupBoolean(hints, "action-icons");
            notification.soundName     = lookupString(hints, "sound-name");
            notification.soundFile     = lookupString(hints, "sound-file");

            gint32 x = 0;
            gint32 y = 0;
            if (g_variant_lookup(hints, "x", "i", &x) && g_variant_lookup(hints, "y", "i", &y)) {
                notification.x           = x;
                notification.y           = y;
                notification.hasPosition = true;
            }

            gint32 progress = 0;
            if (g_variant_lookup(hints, "value", "i", &progress)) {
                notification.progress    = std::clamp(progress, 0, 100);
                notification.hasProgress = true;
            }

            notification.imageData = parseImageData(hints);
            return notification;
        }

        std::optional<SNotificationImageData> parseImageData(GVariant* hints) const {
            GVariant* image = g_variant_lookup_value(hints, "image-data", G_VARIANT_TYPE("(iiibiiay)"));
            if (!image)
                image = g_variant_lookup_value(hints, "image_data", G_VARIANT_TYPE("(iiibiiay)"));
            if (!image)
                image = g_variant_lookup_value(hints, "icon_data", G_VARIANT_TYPE("(iiibiiay)"));
            if (!image)
                return std::nullopt;

            gint32    width         = 0;
            gint32    height        = 0;
            gint32    rowStride     = 0;
            gboolean  hasAlpha      = false;
            gint32    bitsPerSample = 0;
            gint32    channels      = 0;
            GVariant* bytes         = nullptr;
            g_variant_get(image, "(iiibii@ay)", &width, &height, &rowStride, &hasAlpha, &bitsPerSample, &channels, &bytes);

            gsize       byteCount        = 0;
            const auto* data             = static_cast<const uint8_t*>(g_variant_get_fixed_array(bytes, &byteCount, sizeof(uint8_t)));
            const auto  expectedChannels = hasAlpha ? 4 : 3;
            const bool  validDimensions =
                width > 0 && height > 0 && width <= 4096 && height <= 4096 && channels == expectedChannels && bitsPerSample == 8 && rowStride >= width * channels;
            const uint64_t                        requiredBytes = validDimensions ? static_cast<uint64_t>(rowStride) * static_cast<uint64_t>(height) : 0;
            const bool                            valid         = validDimensions && requiredBytes <= MAX_IMAGE_DATA_BYTES && requiredBytes <= byteCount && data;

            std::optional<SNotificationImageData> result;
            if (valid) {
                result = SNotificationImageData{
                    .width         = static_cast<uint32_t>(width),
                    .height        = static_cast<uint32_t>(height),
                    .rowStride     = static_cast<uint32_t>(rowStride),
                    .hasAlpha      = static_cast<bool>(hasAlpha),
                    .bitsPerSample = static_cast<uint8_t>(bitsPerSample),
                    .channels      = static_cast<uint8_t>(channels),
                    .data          = std::vector<uint8_t>(data, data + requiredBytes),
                };
            }
            g_variant_unref(bytes);
            g_variant_unref(image);
            return result;
        }

        uint32_t nextNotificationId() {
            while (m_nextId == 0 || m_notifications.contains(m_nextId)) {
                ++m_nextId;
                if (m_nextId == 0)
                    m_nextId = 1;
            }
            const auto id = m_nextId++;
            if (m_nextId == 0)
                m_nextId = 1;
            return id;
        }

        int32_t effectiveTimeout(const SNotification& notification) const {
            if (notification.urgency == ENotificationUrgency::Critical || notification.expireTimeoutMs == 0)
                return 0;
            if (notification.expireTimeoutMs > 0)
                return notification.expireTimeoutMs;
            return notification.urgency == ENotificationUrgency::Low ? 4000 : 7000;
        }

        void armExpiry(SStoredNotification& stored) {
            const auto timeout = effectiveTimeout(stored.notification);
            if (timeout <= 0 || !m_context)
                return;

            auto* source = g_timeout_source_new(static_cast<guint>(timeout));
            g_source_set_callback(
                source,
                [](gpointer data) -> gboolean {
                    auto*      expiry = static_cast<SExpiryData*>(data);
                    auto*      self   = expiry->server;
                    const auto id     = expiry->id;
                    const auto it     = self->m_notifications.find(id);
                    if (it == self->m_notifications.end())
                        return G_SOURCE_REMOVE;

                    auto* ownedSource       = it->second.expirySource;
                    it->second.expirySource = nullptr;
                    self->m_notifications.erase(it);
                    std::erase(self->m_notificationOrder, id);
                    if (ownedSource)
                        g_source_unref(ownedSource);
                    self->emitClosed(id, 1);
                    return G_SOURCE_REMOVE;
                },
                new SExpiryData{.server = this, .id = stored.notification.id}, [](gpointer data) { delete static_cast<SExpiryData*>(data); });
            if (g_source_attach(source, m_context) == 0) {
                g_source_unref(source);
                return;
            }
            stored.expirySource = source;
        }

        void cancelExpiry(SStoredNotification& stored) {
            if (!stored.expirySource)
                return;
            g_source_destroy(stored.expirySource);
            g_source_unref(stored.expirySource);
            stored.expirySource = nullptr;
        }

        bool closeNotification(uint32_t id, uint32_t reason) {
            const auto it = m_notifications.find(id);
            if (it == m_notifications.end())
                return false;
            cancelExpiry(it->second);
            m_notifications.erase(it);
            std::erase(m_notificationOrder, id);
            emitClosed(id, reason);
            return true;
        }

        void handleDismiss(uint32_t id) {
            if (!closeNotification(id, 2))
                Log::logger->log(Log::WARN, "Denial notification dismiss ignored for unknown id={}", id);
        }

        void handleInvokeAction(uint32_t id, const std::string& actionKey) {
            const auto notification = m_notifications.find(id);
            if (notification == m_notifications.end()) {
                Log::logger->log(Log::WARN, "Denial notification action ignored for unknown id={}", id);
                return;
            }
            const auto action = std::find_if(notification->second.notification.actions.begin(), notification->second.notification.actions.end(),
                                             [&actionKey](const SNotificationAction& candidate) { return candidate.key == actionKey; });
            if (action == notification->second.notification.actions.end()) {
                Log::logger->log(Log::WARN, "Denial notification action ignored for unknown action id={}", id);
                return;
            }
            if (notification->second.invokedActions.contains(actionKey))
                return;

            GError* error = nullptr;
            if (!m_connection ||
                !g_dbus_connection_emit_signal(m_connection, nullptr, OBJECT_PATH, INTERFACE, "ActionInvoked", g_variant_new("(us)", id, actionKey.c_str()), &error)) {
                Log::logger->log(Log::WARN, "Denial notifications failed to emit action signal id={}: {}", id, error ? error->message : "no D-Bus connection");
                g_clear_error(&error);
                return;
            }
            notification->second.invokedActions.emplace(actionKey);

            if (!notification->second.notification.resident)
                closeNotification(id, 2);
        }

        void emitClosed(uint32_t id, uint32_t reason) {
            publish(SNotificationEvent{
                .kind           = ENotificationEventKind::Closed,
                .notificationId = id,
                .closeReason    = reason,
            });

            if (!m_connection)
                return;
            GError* error = nullptr;
            if (!g_dbus_connection_emit_signal(m_connection, nullptr, OBJECT_PATH, INTERFACE, "NotificationClosed", g_variant_new("(uu)", id, reason), &error)) {
                Log::logger->log(Log::WARN, "Denial notifications failed to emit close signal: {}", error ? error->message : "unknown error");
                g_clear_error(&error);
            }
        }

        void publish(SNotificationEvent event) {
            if (m_eventCallback)
                m_eventCallback(std::move(event));
        }

        void clearStoredNotifications() {
            for (auto& [_, stored] : m_notifications)
                cancelExpiry(stored);
            m_notifications.clear();
            m_notificationOrder.clear();
        }

        void clearConnection() {
            if (m_connection && m_registrationId != 0)
                g_dbus_connection_unregister_object(m_connection, m_registrationId);
            m_registrationId = 0;
            if (m_connection && !g_dbus_connection_is_closed(m_connection)) {
                GError* error = nullptr;
                if (!g_dbus_connection_close_sync(m_connection, nullptr, &error)) {
                    Log::logger->log(Log::WARN, "Denial notifications could not close its D-Bus connection cleanly: {}", error ? error->message : "unknown error");
                    g_clear_error(&error);
                }
            }
            g_clear_object(&m_connection);
        }

        TEventCallback                                    m_eventCallback;
        std::thread                                       m_thread;
        std::mutex                                        m_threadMutex;
        std::condition_variable                           m_threadCondition;
        bool                                              m_threadReady       = false;
        bool                                              m_started           = false;
        GMainContext*                                     m_context           = nullptr;
        GMainLoop*                                        m_loop              = nullptr;
        GDBusNodeInfo*                                    m_introspectionData = nullptr;
        GDBusConnection*                                  m_connection        = nullptr;
        guint                                             m_ownerId           = 0;
        guint                                             m_registrationId    = 0;
        uint32_t                                          m_nextId            = 1;
        std::unordered_map<uint32_t, SStoredNotification> m_notifications;
        std::deque<uint32_t>                              m_notificationOrder;
    };

    CNotificationServer::CNotificationServer(TEventCallback eventCallback) : m_impl(std::make_unique<CImpl>(std::move(eventCallback))) {}

    CNotificationServer::~CNotificationServer() = default;

    bool CNotificationServer::start() {
        return m_impl->start();
    }

    void CNotificationServer::stop() {
        m_impl->stop();
    }

    bool CNotificationServer::dismiss(uint32_t notificationId) {
        return notificationId != 0 && m_impl->dismiss(notificationId);
    }

    bool CNotificationServer::invokeAction(uint32_t notificationId, std::string actionKey) {
        return notificationId != 0 && !actionKey.empty() && m_impl->invokeAction(notificationId, std::move(actionKey));
    }

} // namespace Denial
