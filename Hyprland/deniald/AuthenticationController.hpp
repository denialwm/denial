#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <thread>

namespace Denial {

    class CSecureString {
      public:
        CSecureString() = default;
        explicit CSecureString(std::string_view value);
        ~CSecureString();

        CSecureString(const CSecureString&)            = delete;
        CSecureString& operator=(const CSecureString&) = delete;
        CSecureString(CSecureString&& other) noexcept;
        CSecureString&   operator=(CSecureString&& other) noexcept;

        std::string_view view() const;
        bool             empty() const;
        void             clear();

      private:
        std::string m_value;
    };

    enum class EAuthenticationPromptStyle : uint8_t {
        EchoOff = 1,
        EchoOn  = 2,
        Info    = 3,
        Error   = 4,
    };

    enum class EAuthenticationBackendResult : uint8_t {
        Success,
        Failure,
        Cancelled,
        Error,
    };

    class IAuthenticationBackend {
      public:
        using TConversation = std::function<std::optional<CSecureString>(EAuthenticationPromptStyle, std::string_view)>;
        using TCancelled    = std::function<bool()>;

        virtual ~IAuthenticationBackend()                                                                                                            = default;
        virtual bool                         available() const                                                                                       = 0;
        virtual std::string                  unavailableReason() const                                                                               = 0;
        virtual EAuthenticationBackendResult authenticate(std::string_view username, const TConversation& conversation, const TCancelled& cancelled) = 0;
    };

    struct SAuthenticationSnapshot {
        bool        locked     = false;
        bool        available  = false;
        bool        busy       = false;
        uint64_t    attemptId  = 0;
        uint32_t    cooldownMs = 0;
        std::string statusMessage;
    };

    struct SAuthenticationEvent {
        enum class EKind : uint8_t {
            State,
            Prompt,
            Result,
        };

        EKind                      kind = EKind::State;
        SAuthenticationSnapshot    state;
        EAuthenticationPromptStyle promptStyle    = EAuthenticationPromptStyle::Info;
        uint32_t                   promptSequence = 0;
        std::string                message;
        bool                       success   = false;
        bool                       cancelled = false;
    };

    class CAuthenticationController {
      public:
        using TEventCallback = std::function<void(SAuthenticationEvent)>;

        explicit CAuthenticationController(TEventCallback callback, std::unique_ptr<IAuthenticationBackend> backend = {});
        ~CAuthenticationController();

        CAuthenticationController(const CAuthenticationController&)            = delete;
        CAuthenticationController& operator=(const CAuthenticationController&) = delete;

        bool                       locked() const;
        SAuthenticationSnapshot    snapshot() const;
        void                       synchronize();
        void                       lock();
        void                       begin();
        bool                       respond(uint64_t attemptId, uint32_t promptSequence, CSecureString response);
        void                       cancel(uint64_t attemptId = 0);

      private:
        struct SPromptState {
            EAuthenticationPromptStyle style    = EAuthenticationPromptStyle::Info;
            uint32_t                   sequence = 0;
            std::string                message;
            bool                       requiresResponse = false;
        };

        struct SWorkItem {
            uint64_t attemptId  = 0;
            uint64_t generation = 0;
        };

        static std::unique_ptr<IAuthenticationBackend> makeDefaultBackend();
        static std::string                             currentUsername();
        static std::string                             sanitizeMessage(std::string_view message);
        static std::chrono::milliseconds               cooldownForFailure(uint32_t failures);

        void                                           run();
        bool                                           cancelled(uint64_t generation) const;
        std::optional<CSecureString>                   converse(uint64_t attemptId, uint64_t generation, EAuthenticationPromptStyle style, std::string_view message);
        SAuthenticationSnapshot                        snapshotLocked(std::chrono::steady_clock::time_point now) const;
        std::optional<SAuthenticationEvent>            promptEventLocked() const;
        void                                           publish(SAuthenticationEvent event) const;
        void                                           publishState() const;

        TEventCallback                                 m_callback;
        std::unique_ptr<IAuthenticationBackend>        m_backend;
        std::string                                    m_username;
        std::thread                                    m_worker;
        mutable std::mutex                             m_mutex;
        std::condition_variable                        m_condition;
        std::atomic_bool                               m_locked             = false;
        bool                                           m_stopping           = false;
        bool                                           m_busy               = false;
        bool                                           m_cancelRequested    = false;
        uint64_t                                       m_generation         = 0;
        uint64_t                                       m_nextAttemptId      = 1;
        uint64_t                                       m_activeAttemptId    = 0;
        uint32_t                                       m_nextPromptSequence = 1;
        uint32_t                                       m_failureCount       = 0;
        std::chrono::steady_clock::time_point          m_cooldownUntil{};
        std::optional<SWorkItem>                       m_pendingWork;
        std::optional<SPromptState>                    m_prompt;
        std::optional<CSecureString>                   m_response;
    };

} // namespace Denial
