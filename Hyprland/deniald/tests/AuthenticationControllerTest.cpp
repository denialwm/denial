#include "../AuthenticationController.hpp"
#include "../AuthenticationProtocol.hpp"

#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {
    using namespace std::chrono_literals;

    class CEventCollector {
      public:
        void push(Denial::SAuthenticationEvent event) {
            {
                std::lock_guard lock(m_mutex);
                m_events.emplace_back(std::move(event));
            }
            m_condition.notify_all();
        }

        bool waitFor(const std::function<bool(const std::vector<Denial::SAuthenticationEvent>&)>& predicate) {
            std::unique_lock lock(m_mutex);
            return m_condition.wait_for(lock, 2s, [&] { return predicate(m_events); });
        }

        std::vector<Denial::SAuthenticationEvent> snapshot() const {
            std::lock_guard lock(m_mutex);
            return m_events;
        }

        void clear() {
            std::lock_guard lock(m_mutex);
            m_events.clear();
        }

      private:
        mutable std::mutex                        m_mutex;
        std::condition_variable                   m_condition;
        std::vector<Denial::SAuthenticationEvent> m_events;
    };

    class CFakeAuthenticationBackend final : public Denial::IAuthenticationBackend {
      public:
        explicit CFakeAuthenticationBackend(Denial::EAuthenticationBackendResult result) : m_result(result) {}

        bool available() const override {
            return m_available;
        }

        std::string unavailableReason() const override {
            return "Authentication test backend unavailable";
        }

        Denial::EAuthenticationBackendResult authenticate(std::string_view username, const TConversation& conversation, const TCancelled& cancelled) override {
            ++calls;
            observedUsername = username;
            auto response    = conversation(Denial::EAuthenticationPromptStyle::EchoOff, "Password:");
            if (response) {
                observedSecretMatched = response->view() == "correct horse";
                response->clear();
                responseCleared = response->empty();
            }
            observedCancellation = cancelled();
            return m_result;
        }

        bool                 m_available = true;
        std::atomic_uint32_t calls       = 0;
        std::string          observedUsername;
        std::atomic_bool     observedSecretMatched = false;
        std::atomic_bool     responseCleared       = false;
        std::atomic_bool     observedCancellation  = false;

      private:
        Denial::EAuthenticationBackendResult m_result;
    };

    const Denial::SAuthenticationEvent* lastEvent(const std::vector<Denial::SAuthenticationEvent>& events, Denial::SAuthenticationEvent::EKind kind) {
        for (auto iterator = events.rbegin(); iterator != events.rend(); ++iterator) {
            if (iterator->kind == kind)
                return &*iterator;
        }
        return nullptr;
    }
} // namespace

TEST(AuthenticationProtocol, RejectsMalformedOversizedAndTruncatedPackets) {
    using namespace Denial::AuthenticationProtocol;
    EXPECT_FALSE(decode(nullptr, 0));

    auto packet = encode(EKind::Respond, 0, 7, 3, "secret");
    ASSERT_EQ(packet.size(), HEADER_SIZE + 6);
    const auto decoded = decode(packet.data(), packet.size());
    ASSERT_TRUE(decoded);
    EXPECT_EQ(decoded->kind, EKind::Respond);
    EXPECT_EQ(decoded->attemptId, 7u);
    EXPECT_EQ(decoded->argument, 3u);
    EXPECT_EQ(decoded->payload, "secret");

    EXPECT_FALSE(decode(packet.data(), packet.size() - 1));
    packet[0] = 0;
    EXPECT_FALSE(decode(packet.data(), packet.size()));
    EXPECT_TRUE(encode(EKind::Respond, 0, 1, 1, std::string(MAX_PAYLOAD_BYTES + 1, 'x')).empty());
    EXPECT_TRUE(encode(EKind::Respond, 0, 1, 1, std::string_view{"a\0b", 3}).empty());
}

TEST(AuthenticationController, CorrectConversationUnlocksExactlyOnceAndClearsOwnedReply) {
    CEventCollector                   events;
    auto                              backend    = std::make_unique<CFakeAuthenticationBackend>(Denial::EAuthenticationBackendResult::Success);
    auto*                             backendPtr = backend.get();
    Denial::CAuthenticationController controller([&](auto event) { events.push(std::move(event)); }, std::move(backend));

    controller.lock();
    controller.begin();
    ASSERT_TRUE(events.waitFor([](const auto& captured) { return lastEvent(captured, Denial::SAuthenticationEvent::EKind::Prompt) != nullptr; }));
    const auto prompt = *lastEvent(events.snapshot(), Denial::SAuthenticationEvent::EKind::Prompt);
    EXPECT_TRUE(controller.respond(prompt.state.attemptId, prompt.promptSequence, Denial::CSecureString{"correct horse"}));

    ASSERT_TRUE(events.waitFor([](const auto& captured) {
        const auto* result = lastEvent(captured, Denial::SAuthenticationEvent::EKind::Result);
        return result && result->success;
    }));
    EXPECT_FALSE(controller.locked());
    EXPECT_EQ(backendPtr->calls.load(), 1u);
    EXPECT_TRUE(backendPtr->observedSecretMatched.load());
    EXPECT_TRUE(backendPtr->responseCleared.load());
    EXPECT_FALSE(controller.respond(prompt.state.attemptId, prompt.promptSequence, Denial::CSecureString{"duplicate"}));
}

TEST(AuthenticationController, FailureRemainsLockedAndRateLimitsImmediateRetry) {
    CEventCollector                   events;
    auto                              backend    = std::make_unique<CFakeAuthenticationBackend>(Denial::EAuthenticationBackendResult::Failure);
    auto*                             backendPtr = backend.get();
    Denial::CAuthenticationController controller([&](auto event) { events.push(std::move(event)); }, std::move(backend));

    controller.lock();
    controller.begin();
    ASSERT_TRUE(events.waitFor([](const auto& captured) { return lastEvent(captured, Denial::SAuthenticationEvent::EKind::Prompt) != nullptr; }));
    const auto prompt = *lastEvent(events.snapshot(), Denial::SAuthenticationEvent::EKind::Prompt);
    ASSERT_TRUE(controller.respond(prompt.state.attemptId, prompt.promptSequence, Denial::CSecureString{"wrong"}));
    ASSERT_TRUE(events.waitFor([](const auto& captured) {
        const auto* result = lastEvent(captured, Denial::SAuthenticationEvent::EKind::Result);
        return result && !result->success && !result->cancelled;
    }));

    EXPECT_TRUE(controller.locked());
    EXPECT_GT(controller.snapshot().cooldownMs, 0u);
    controller.begin();
    std::this_thread::sleep_for(30ms);
    EXPECT_EQ(backendPtr->calls.load(), 1u);
}

TEST(AuthenticationController, CancellationAndLateBackendSuccessCannotUnlock) {
    CEventCollector                   events;
    auto                              backend    = std::make_unique<CFakeAuthenticationBackend>(Denial::EAuthenticationBackendResult::Success);
    auto*                             backendPtr = backend.get();
    Denial::CAuthenticationController controller([&](auto event) { events.push(std::move(event)); }, std::move(backend));

    controller.lock();
    controller.begin();
    ASSERT_TRUE(events.waitFor([](const auto& captured) { return lastEvent(captured, Denial::SAuthenticationEvent::EKind::Prompt) != nullptr; }));
    const auto prompt = *lastEvent(events.snapshot(), Denial::SAuthenticationEvent::EKind::Prompt);
    controller.cancel(prompt.state.attemptId);

    ASSERT_TRUE(events.waitFor([](const auto& captured) {
        const auto* result = lastEvent(captured, Denial::SAuthenticationEvent::EKind::Result);
        return result && result->cancelled;
    }));
    EXPECT_TRUE(controller.locked());
    EXPECT_TRUE(backendPtr->observedCancellation.load());
}

TEST(AuthenticationController, SynchronizeReplaysAuthoritativeLockAndPendingPrompt) {
    CEventCollector                   events;
    auto                              backend = std::make_unique<CFakeAuthenticationBackend>(Denial::EAuthenticationBackendResult::Failure);
    Denial::CAuthenticationController controller([&](auto event) { events.push(std::move(event)); }, std::move(backend));

    controller.lock();
    controller.begin();
    ASSERT_TRUE(events.waitFor([](const auto& captured) { return lastEvent(captured, Denial::SAuthenticationEvent::EKind::Prompt) != nullptr; }));
    const auto original = *lastEvent(events.snapshot(), Denial::SAuthenticationEvent::EKind::Prompt);
    events.clear();
    controller.synchronize();

    const auto  replay = events.snapshot();
    const auto* state  = lastEvent(replay, Denial::SAuthenticationEvent::EKind::State);
    const auto* prompt = lastEvent(replay, Denial::SAuthenticationEvent::EKind::Prompt);
    ASSERT_NE(state, nullptr);
    ASSERT_NE(prompt, nullptr);
    EXPECT_TRUE(state->state.locked);
    EXPECT_TRUE(state->state.busy);
    EXPECT_EQ(prompt->state.attemptId, original.state.attemptId);
    EXPECT_EQ(prompt->promptSequence, original.promptSequence);
    controller.cancel(original.state.attemptId);
}
