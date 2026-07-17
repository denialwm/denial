#include "../NotificationServer.hpp"

#include <gio/gio.h>
#include <gtest/gtest.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

    using namespace std::chrono_literals;

    constexpr const char* SERVICE_NAME = "org.freedesktop.Notifications";
    constexpr const char* OBJECT_PATH  = "/org/freedesktop/Notifications";
    constexpr const char* INTERFACE    = "org.freedesktop.Notifications";

    struct SObservedSignal {
        std::string name;
        uint32_t    id     = 0;
        uint32_t    reason = 0;
        std::string action;
    };

    class CNotificationServerTest : public ::testing::Test {
      protected:
        static void SetUpTestSuite() {
            s_testBus = g_test_dbus_new(G_TEST_DBUS_NONE);
            ASSERT_NE(s_testBus, nullptr);
            g_test_dbus_up(s_testBus);
        }

        static void TearDownTestSuite() {
            g_test_dbus_down(s_testBus);
            g_object_unref(s_testBus);
            s_testBus = nullptr;
        }

        void SetUp() override {
            m_server = std::make_unique<Denial::CNotificationServer>([this](Denial::SNotificationEvent event) {
                std::lock_guard lock(m_mutex);
                m_events.emplace_back(std::move(event));
            });
            ASSERT_TRUE(m_server->start());

            GError*    error   = nullptr;
            const auto address = g_test_dbus_get_bus_address(s_testBus);
            ASSERT_NE(address, nullptr);
            m_client = g_dbus_connection_new_for_address_sync(
                address, static_cast<GDBusConnectionFlags>(G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION), nullptr, nullptr,
                &error);
            ASSERT_NE(m_client, nullptr) << (error ? error->message : "session bus unavailable");
            g_clear_error(&error);

            m_closedSubscription = g_dbus_connection_signal_subscribe(m_client, nullptr, INTERFACE, "NotificationClosed", OBJECT_PATH, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
                                                                      &CNotificationServerTest::handleSignal, this, nullptr);
            m_actionSubscription = g_dbus_connection_signal_subscribe(m_client, nullptr, INTERFACE, "ActionInvoked", OBJECT_PATH, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
                                                                      &CNotificationServerTest::handleSignal, this, nullptr);
            ASSERT_TRUE(waitUntil([this] { return nameHasOwner(); }, 2s));
        }

        void TearDown() override {
            m_server.reset();
            if (m_client && m_closedSubscription != 0)
                g_dbus_connection_signal_unsubscribe(m_client, m_closedSubscription);
            if (m_client && m_actionSubscription != 0)
                g_dbus_connection_signal_unsubscribe(m_client, m_actionSubscription);
            g_clear_object(&m_client);
        }

        static void handleSignal(GDBusConnection*, const char*, const char*, const char*, const char* signalName, GVariant* parameters, gpointer userData) {
            auto*           self = static_cast<CNotificationServerTest*>(userData);
            SObservedSignal signal{.name = signalName};
            if (signal.name == "NotificationClosed") {
                guint32 id     = 0;
                guint32 reason = 0;
                g_variant_get(parameters, "(uu)", &id, &reason);
                signal.id     = id;
                signal.reason = reason;
            } else {
                guint32     id     = 0;
                const char* action = nullptr;
                g_variant_get(parameters, "(u&s)", &id, &action);
                signal.id     = id;
                signal.action = action ? action : "";
            }

            std::lock_guard lock(self->m_mutex);
            self->m_signals.emplace_back(std::move(signal));
        }

        bool waitUntil(const std::function<bool()>& predicate, std::chrono::milliseconds timeout = 1s) {
            const auto deadline = std::chrono::steady_clock::now() + timeout;
            while (std::chrono::steady_clock::now() < deadline) {
                while (g_main_context_iteration(nullptr, false)) {}
                if (predicate())
                    return true;
                std::this_thread::sleep_for(1ms);
            }
            while (g_main_context_iteration(nullptr, false)) {}
            return predicate();
        }

        bool nameHasOwner() {
            GError* error = nullptr;
            auto*   reply = g_dbus_connection_call_sync(m_client, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                                                        g_variant_new("(s)", SERVICE_NAME), G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NONE, 250, nullptr, &error);
            if (!reply) {
                g_clear_error(&error);
                return false;
            }
            gboolean owned = false;
            g_variant_get(reply, "(b)", &owned);
            g_variant_unref(reply);
            return owned;
        }

        GVariant* call(const char* method, GVariant* parameters, const GVariantType* replyType) {
            GError* error = nullptr;
            auto* reply = g_dbus_connection_call_sync(m_client, SERVICE_NAME, OBJECT_PATH, INTERFACE, method, parameters, replyType, G_DBUS_CALL_FLAGS_NONE, 2000, nullptr, &error);
            if (!reply) {
                ADD_FAILURE() << method << " failed: " << (error ? error->message : "unknown D-Bus error");
                g_clear_error(&error);
            }
            return reply;
        }

        uint32_t notify(std::string summary, uint32_t replacesId = 0, int32_t timeoutMs = 0, const std::vector<std::pair<std::string, std::string>>& actions = {},
                        const std::function<void(GVariantBuilder&)>& addHints = {}) {
            GVariantBuilder actionBuilder;
            g_variant_builder_init(&actionBuilder, G_VARIANT_TYPE("as"));
            for (const auto& [key, label] : actions) {
                g_variant_builder_add(&actionBuilder, "s", key.c_str());
                g_variant_builder_add(&actionBuilder, "s", label.c_str());
            }

            GVariantBuilder hintBuilder;
            g_variant_builder_init(&hintBuilder, G_VARIANT_TYPE("a{sv}"));
            if (addHints)
                addHints(hintBuilder);

            auto* reply = call("Notify",
                               g_variant_new("(susss@as@a{sv}i)", "Denial test", replacesId, "dialog-information", summary.c_str(), "Notification body",
                                             g_variant_builder_end(&actionBuilder), g_variant_builder_end(&hintBuilder), timeoutMs),
                               G_VARIANT_TYPE("(u)"));
            if (!reply)
                return 0;
            guint32 id = 0;
            g_variant_get(reply, "(u)", &id);
            g_variant_unref(reply);
            return id;
        }

        std::vector<Denial::SNotificationEvent> events() {
            std::lock_guard lock(m_mutex);
            return m_events;
        }

        std::vector<SObservedSignal> signals() {
            std::lock_guard lock(m_mutex);
            return m_signals;
        }

        size_t signalCount(const std::string& name) {
            std::lock_guard lock(m_mutex);
            return std::ranges::count_if(m_signals, [&name](const auto& signal) { return signal.name == name; });
        }

        inline static GTestDBus*                     s_testBus = nullptr;

        std::unique_ptr<Denial::CNotificationServer> m_server;
        GDBusConnection*                             m_client             = nullptr;
        guint                                        m_closedSubscription = 0;
        guint                                        m_actionSubscription = 0;
        std::mutex                                   m_mutex;
        std::vector<Denial::SNotificationEvent>      m_events;
        std::vector<SObservedSignal>                 m_signals;
    };

    TEST_F(CNotificationServerTest, RegistersHonestCapabilitiesAndReplacesInPlace) {
        auto* capabilityReply = call("GetCapabilities", nullptr, G_VARIANT_TYPE("(as)"));
        ASSERT_NE(capabilityReply, nullptr);
        gchar** capabilities = nullptr;
        g_variant_get(capabilityReply, "(^as)", &capabilities);
        const std::vector<std::string> capabilityList(capabilities, capabilities + g_strv_length(capabilities));
        g_strfreev(capabilities);
        g_variant_unref(capabilityReply);

        EXPECT_NE(std::ranges::find(capabilityList, std::string{"actions"}), capabilityList.end());
        EXPECT_NE(std::ranges::find(capabilityList, std::string{"body"}), capabilityList.end());
        EXPECT_NE(std::ranges::find(capabilityList, std::string{"icon-static"}), capabilityList.end());
        EXPECT_EQ(std::ranges::find(capabilityList, std::string{"body-markup"}), capabilityList.end());
        EXPECT_EQ(std::ranges::find(capabilityList, std::string{"sound"}), capabilityList.end());
        EXPECT_EQ(std::ranges::find(capabilityList, std::string{"persistence"}), capabilityList.end());

        const auto id = notify("Original", 0, 0, {{"default", "Open"}, {"accept", "Accept"}});
        ASSERT_NE(id, 0u);
        const auto replacedId = notify("Updated", id, 0, {{"default", "Open"}});
        EXPECT_EQ(replacedId, id);
        ASSERT_TRUE(waitUntil([this] { return events().size() >= 2; }));

        const auto observed = events();
        ASSERT_EQ(observed.size(), 2u);
        EXPECT_EQ(observed[0].kind, Denial::ENotificationEventKind::Added);
        EXPECT_EQ(observed[1].kind, Denial::ENotificationEventKind::Replaced);
        EXPECT_EQ(observed[1].notification.summary, "Updated");

        auto* closeReply = call("CloseNotification", g_variant_new("(u)", id), G_VARIANT_TYPE("()"));
        ASSERT_NE(closeReply, nullptr);
        g_variant_unref(closeReply);
        ASSERT_TRUE(waitUntil([this] { return events().size() >= 3 && signalCount("NotificationClosed") >= 1; }));
        const auto closedEvents = events();
        EXPECT_EQ(closedEvents.back().closeReason, 3u);
        const auto closedSignals = signals();
        EXPECT_TRUE(std::ranges::any_of(closedSignals, [id](const auto& signal) { return signal.name == "NotificationClosed" && signal.id == id && signal.reason == 3; }));
    }

    TEST_F(CNotificationServerTest, EmitsCorrectExpiryAndDismissReasons) {
        const auto expiringId = notify("Expires", 0, 25);
        ASSERT_NE(expiringId, 0u);
        ASSERT_TRUE(waitUntil([this] { return events().size() >= 2 && signalCount("NotificationClosed") >= 1; }, 2s));
        auto observed = events();
        ASSERT_EQ(observed.back().notificationId, expiringId);
        EXPECT_EQ(observed.back().closeReason, 1u);

        const auto dismissedId = notify("Dismissed");
        ASSERT_NE(dismissedId, 0u);
        ASSERT_TRUE(m_server->dismiss(dismissedId));
        ASSERT_TRUE(waitUntil([this] { return events().size() >= 4 && signalCount("NotificationClosed") >= 2; }));
        observed = events();
        EXPECT_EQ(observed.back().notificationId, dismissedId);
        EXPECT_EQ(observed.back().closeReason, 2u);
    }

    TEST_F(CNotificationServerTest, EvictsTheOldestNotificationAtTheNativeBound) {
        const auto oldestId = notify("Oldest");
        ASSERT_NE(oldestId, 0u);
        for (uint32_t index = 1; index <= 256; ++index)
            ASSERT_NE(notify("Bounded " + std::to_string(index)), 0u);

        ASSERT_TRUE(waitUntil([this] { return signalCount("NotificationClosed") >= 1; }, 2s));
        const auto observedSignals = signals();
        EXPECT_EQ(
            std::ranges::count_if(observedSignals, [oldestId](const auto& signal) { return signal.name == "NotificationClosed" && signal.id == oldestId && signal.reason == 4; }),
            1);
        const auto observedEvents = events();
        EXPECT_TRUE(std::ranges::any_of(observedEvents, [oldestId](const auto& event) {
            return event.kind == Denial::ENotificationEventKind::Closed && event.notificationId == oldestId && event.closeReason == 4;
        }));
    }

    TEST_F(CNotificationServerTest, BoundsActionsStringsAndImageHints) {
        std::vector<std::pair<std::string, std::string>> actions;
        for (int index = 0; index < 24; ++index)
            actions.emplace_back("action-" + std::to_string(index), "Action " + std::to_string(index));
        actions.emplace_back("action-0", "Duplicate");
        actions.emplace_back("", "Empty key");

        std::vector<uint8_t> oversizedImage(528384, 0x7f);
        const auto           invalidImageId = notify(std::string(5000, 'x'), 0, 0, actions, [&oversizedImage](GVariantBuilder& hints) {
            auto* bytes = g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, oversizedImage.data(), oversizedImage.size(), sizeof(uint8_t));
            g_variant_builder_add(&hints, "{sv}", "image-data", g_variant_new("(iiibii@ay)", 1024, 129, 4096, true, 8, 4, bytes));
            g_variant_builder_add(&hints, "{sv}", "urgency", g_variant_new_string("not-a-byte"));
            g_variant_builder_add(&hints, "{sv}", "x", g_variant_new_int32(12));
        });
        ASSERT_NE(invalidImageId, 0u);
        ASSERT_TRUE(waitUntil([this] { return !events().empty(); }));
        auto observed = events();
        ASSERT_EQ(observed.front().notification.actions.size(), 16u);
        EXPECT_EQ(observed.front().notification.summary.size(), 4096u);
        EXPECT_FALSE(observed.front().notification.imageData.has_value());
        EXPECT_EQ(observed.front().notification.urgency, Denial::ENotificationUrgency::Normal);
        EXPECT_FALSE(observed.front().notification.hasPosition);

        const std::vector<uint8_t> validImage = {
            0xff, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff,
        };
        const auto validImageId = notify("Valid image", 0, 0, {}, [&validImage](GVariantBuilder& hints) {
            auto* bytes = g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, validImage.data(), validImage.size(), sizeof(uint8_t));
            g_variant_builder_add(&hints, "{sv}", "image_data", g_variant_new("(iiibii@ay)", 2, 2, 6, false, 8, 3, bytes));
        });
        ASSERT_NE(validImageId, 0u);
        ASSERT_TRUE(waitUntil([this] { return events().size() >= 2; }));
        observed = events();
        ASSERT_TRUE(observed.back().notification.imageData.has_value());
        EXPECT_EQ(observed.back().notification.imageData->data, validImage);
    }

    TEST_F(CNotificationServerTest, InvokesEachActionExactlyOncePerRevision) {
        const auto residentId = notify("Resident", 0, 0, {{"default", "Open"}, {"accept", "Accept"}},
                                       [](GVariantBuilder& hints) { g_variant_builder_add(&hints, "{sv}", "resident", g_variant_new_boolean(true)); });
        ASSERT_NE(residentId, 0u);

        ASSERT_TRUE(m_server->invokeAction(residentId, "default"));
        ASSERT_TRUE(m_server->invokeAction(residentId, "default"));
        ASSERT_TRUE(waitUntil([this] { return signalCount("ActionInvoked") >= 1; }));
        EXPECT_FALSE(waitUntil([this] { return signalCount("ActionInvoked") > 1; }, 50ms));

        ASSERT_TRUE(m_server->invokeAction(residentId, "accept"));
        ASSERT_TRUE(waitUntil([this] { return signalCount("ActionInvoked") >= 2; }));
        const auto actionSignals = signals();
        EXPECT_EQ(std::ranges::count_if(actionSignals,
                                        [residentId](const auto& signal) { return signal.name == "ActionInvoked" && signal.id == residentId && signal.action == "default"; }),
                  1);
        EXPECT_EQ(std::ranges::count_if(actionSignals,
                                        [residentId](const auto& signal) { return signal.name == "ActionInvoked" && signal.id == residentId && signal.action == "accept"; }),
                  1);

        ASSERT_TRUE(m_server->dismiss(residentId));
        ASSERT_TRUE(waitUntil([this] { return signalCount("NotificationClosed") >= 1; }));

        const auto transientId = notify("One shot", 0, 0, {{"default", "Open"}});
        ASSERT_NE(transientId, 0u);
        ASSERT_TRUE(m_server->invokeAction(transientId, "default"));
        ASSERT_TRUE(waitUntil([this] { return signalCount("ActionInvoked") >= 3 && signalCount("NotificationClosed") >= 2; }));
        const auto finalSignals = signals();
        EXPECT_TRUE(
            std::ranges::any_of(finalSignals, [transientId](const auto& signal) { return signal.name == "NotificationClosed" && signal.id == transientId && signal.reason == 2; }));
    }

} // namespace
