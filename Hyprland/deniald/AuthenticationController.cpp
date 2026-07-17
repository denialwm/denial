#include "AuthenticationController.hpp"

#include <algorithm>
#include <atomic>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <pwd.h>
#include <ranges>
#include <utility>
#include <vector>

#include <unistd.h>

#if defined(DENIAL_WITH_PAM)
#include <security/pam_appl.h>
#endif

namespace Denial {

    namespace {
        void eraseBytes(char* bytes, size_t size) {
            if (!bytes || size == 0)
                return;
            volatile char* cursor = bytes;
            while (size-- > 0)
                *cursor++ = 0;
            std::atomic_signal_fence(std::memory_order_seq_cst);
        }

        class CUnavailableAuthenticationBackend final : public IAuthenticationBackend {
          public:
            bool available() const override {
                return false;
            }

            std::string unavailableReason() const override {
                return "System authentication is unavailable on this build.";
            }

            EAuthenticationBackendResult authenticate(std::string_view, const TConversation&, const TCancelled&) override {
                return EAuthenticationBackendResult::Error;
            }
        };

#if defined(DENIAL_WITH_PAM)
        class CPamAuthenticationBackend final : public IAuthenticationBackend {
          public:
            CPamAuthenticationBackend() {
                const char* configured = std::getenv("DENIAL_PAM_SERVICE");
                if (configured && *configured) {
                    const std::string_view candidate{configured};
                    const bool             valid = candidate.size() <= 64 && std::ranges::all_of(candidate, [](unsigned char character) {
                                           return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9') ||
                                               character == '-' || character == '_';
                                                   });
                    if (valid)
                        m_service = candidate;
                }
            }

            bool available() const override {
                return true;
            }

            std::string unavailableReason() const override {
                return {};
            }

            EAuthenticationBackendResult authenticate(std::string_view username, const TConversation& conversation, const TCancelled& cancelled) override {
                SConversationContext context{
                    .conversation = &conversation,
                    .cancelled    = &cancelled,
                };
                pam_conv conversationAdapter{
                    .conv        = &CPamAuthenticationBackend::onConversation,
                    .appdata_ptr = &context,
                };
                pam_handle_t*     handle = nullptr;
                const std::string ownedUsername{username};
                int               result = pam_start(m_service.c_str(), ownedUsername.c_str(), &conversationAdapter, &handle);
                if (result != PAM_SUCCESS || !handle)
                    return cancelled() ? EAuthenticationBackendResult::Cancelled : EAuthenticationBackendResult::Error;

                // Denial applies its own bounded retry policy and never blocks
                // the compositor thread. Disable PAM's optional artificial
                // delay so teardown is not held by two independent timers.
                pam_fail_delay(handle, 0);
                pam_set_item(handle, PAM_TTY, "denial");

                result = pam_authenticate(handle, PAM_DISALLOW_NULL_AUTHTOK);
                if (result == PAM_SUCCESS)
                    result = pam_acct_mgmt(handle, PAM_SILENT);
                const bool wasCancelled = cancelled();
                pam_end(handle, result);

                if (wasCancelled)
                    return EAuthenticationBackendResult::Cancelled;
                if (result == PAM_SUCCESS)
                    return EAuthenticationBackendResult::Success;
                if (result == PAM_AUTH_ERR || result == PAM_USER_UNKNOWN || result == PAM_MAXTRIES || result == PAM_CRED_INSUFFICIENT || result == PAM_AUTHINFO_UNAVAIL)
                    return EAuthenticationBackendResult::Failure;
                return EAuthenticationBackendResult::Error;
            }

          private:
            struct SConversationContext {
                const TConversation* conversation = nullptr;
                const TCancelled*    cancelled    = nullptr;
            };

            static void clearResponses(pam_response* responses, int count) {
                if (!responses)
                    return;
                for (int index = 0; index < count; ++index) {
                    if (!responses[index].resp)
                        continue;
                    eraseBytes(responses[index].resp, std::strlen(responses[index].resp));
                    std::free(responses[index].resp);
                    responses[index].resp = nullptr;
                }
                eraseBytes(reinterpret_cast<char*>(responses), sizeof(pam_response) * static_cast<size_t>(std::max(0, count)));
                std::free(responses);
            }

            static int onConversation(int count, const pam_message** messages, pam_response** output, void* userData) {
                auto* context = static_cast<SConversationContext*>(userData);
                if (!context || !context->conversation || !context->cancelled || !output || count <= 0 || count > PAM_MAX_NUM_MSG || !messages || (*context->cancelled)())
                    return PAM_CONV_ERR;

                auto* responses = static_cast<pam_response*>(std::calloc(static_cast<size_t>(count), sizeof(pam_response)));
                if (!responses)
                    return PAM_BUF_ERR;

                for (int index = 0; index < count; ++index) {
                    if (!messages[index] || (*context->cancelled)()) {
                        clearResponses(responses, count);
                        return PAM_CONV_ERR;
                    }

                    EAuthenticationPromptStyle style;
                    switch (messages[index]->msg_style) {
                        case PAM_PROMPT_ECHO_OFF: style = EAuthenticationPromptStyle::EchoOff; break;
                        case PAM_PROMPT_ECHO_ON: style = EAuthenticationPromptStyle::EchoOn; break;
                        case PAM_TEXT_INFO: style = EAuthenticationPromptStyle::Info; break;
                        case PAM_ERROR_MSG: style = EAuthenticationPromptStyle::Error; break;
                        default: clearResponses(responses, count); return PAM_CONV_ERR;
                    }

                    auto response = (*context->conversation)(style, messages[index]->msg ? messages[index]->msg : "");
                    if (!response) {
                        clearResponses(responses, count);
                        return PAM_CONV_ERR;
                    }

                    if (style == EAuthenticationPromptStyle::Info || style == EAuthenticationPromptStyle::Error)
                        continue;

                    const auto value = response->view();
                    if (value.size() > static_cast<size_t>(INT_MAX)) {
                        clearResponses(responses, count);
                        return PAM_CONV_ERR;
                    }
                    responses[index].resp = static_cast<char*>(std::calloc(value.size() + 1, 1));
                    if (!responses[index].resp) {
                        clearResponses(responses, count);
                        return PAM_BUF_ERR;
                    }
                    std::memcpy(responses[index].resp, value.data(), value.size());
                    response->clear();
                }

                *output = responses;
                return PAM_SUCCESS;
            }

            std::string m_service = "login";
        };
#endif
    } // namespace

    CSecureString::CSecureString(std::string_view value) : m_value(value) {}

    CSecureString::~CSecureString() {
        clear();
    }

    CSecureString::CSecureString(CSecureString&& other) noexcept {
        m_value.swap(other.m_value);
    }

    CSecureString& CSecureString::operator=(CSecureString&& other) noexcept {
        if (this == &other)
            return *this;
        clear();
        m_value.swap(other.m_value);
        return *this;
    }

    std::string_view CSecureString::view() const {
        return m_value;
    }

    bool CSecureString::empty() const {
        return m_value.empty();
    }

    void CSecureString::clear() {
        if (!m_value.empty())
            eraseBytes(m_value.data(), m_value.size());
        m_value.clear();
    }

    CAuthenticationController::CAuthenticationController(TEventCallback callback, std::unique_ptr<IAuthenticationBackend> backend) :
        m_callback(std::move(callback)), m_backend(backend ? std::move(backend) : makeDefaultBackend()), m_username(currentUsername()), m_worker([this] { run(); }) {}

    CAuthenticationController::~CAuthenticationController() {
        {
            std::lock_guard lock(m_mutex);
            m_stopping = true;
            ++m_generation;
            m_cancelRequested = true;
            m_response.reset();
        }
        m_condition.notify_all();
        if (m_worker.joinable())
            m_worker.join();
    }

    std::unique_ptr<IAuthenticationBackend> CAuthenticationController::makeDefaultBackend() {
#if defined(DENIAL_WITH_PAM)
        return std::make_unique<CPamAuthenticationBackend>();
#else
        return std::make_unique<CUnavailableAuthenticationBackend>();
#endif
    }

    std::string CAuthenticationController::currentUsername() {
        const auto userId = getuid();
        long       size   = sysconf(_SC_GETPW_R_SIZE_MAX);
        size              = std::clamp<long>(size > 0 ? size : 4096, 1024, 64 * 1024);
        std::vector<char> buffer(static_cast<size_t>(size));
        passwd            record{};
        passwd*           result = nullptr;
        if (getpwuid_r(userId, &record, buffer.data(), buffer.size(), &result) == 0 && result && result->pw_name && *result->pw_name)
            return std::string(result->pw_name).substr(0, 256);
        return std::to_string(userId);
    }

    std::string CAuthenticationController::sanitizeMessage(std::string_view message) {
        constexpr size_t MAX_MESSAGE_BYTES = 1024;
        std::string      sanitized;
        sanitized.reserve(std::min(message.size(), MAX_MESSAGE_BYTES));
        for (const unsigned char character : message) {
            if (sanitized.size() >= MAX_MESSAGE_BYTES)
                break;
            if (character == '\n' || character == '\t' || character >= 0x20)
                sanitized.push_back(static_cast<char>(character));
        }
        while (!sanitized.empty() && (sanitized.back() == '\n' || sanitized.back() == '\r' || sanitized.back() == ' '))
            sanitized.pop_back();
        return sanitized.empty() ? "Authenticate to unlock" : sanitized;
    }

    std::chrono::milliseconds CAuthenticationController::cooldownForFailure(uint32_t failures) {
        constexpr uint32_t BASE_MS  = 750;
        constexpr uint32_t MAX_MS   = 30000;
        const auto         exponent = std::min<uint32_t>(failures > 0 ? failures - 1 : 0, 6);
        return std::chrono::milliseconds{std::min<uint32_t>(MAX_MS, BASE_MS << exponent)};
    }

    bool CAuthenticationController::locked() const {
        return m_locked.load(std::memory_order_acquire);
    }

    SAuthenticationSnapshot CAuthenticationController::snapshot() const {
        std::lock_guard lock(m_mutex);
        return snapshotLocked(std::chrono::steady_clock::now());
    }

    SAuthenticationSnapshot CAuthenticationController::snapshotLocked(std::chrono::steady_clock::time_point now) const {
        uint32_t cooldownMs = 0;
        if (m_cooldownUntil > now) {
            const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(m_cooldownUntil - now).count();
            cooldownMs           = static_cast<uint32_t>(std::clamp<int64_t>(remaining, 1, std::numeric_limits<uint32_t>::max()));
        }

        std::string status;
        if (!m_backend->available())
            status = m_backend->unavailableReason();
        else if (m_cancelRequested && m_busy)
            status = "Cancelling authentication…";

        return SAuthenticationSnapshot{
            .locked        = m_locked.load(std::memory_order_acquire),
            .available     = m_backend->available(),
            .busy          = m_busy,
            .attemptId     = m_activeAttemptId,
            .cooldownMs    = cooldownMs,
            .statusMessage = std::move(status),
        };
    }

    std::optional<SAuthenticationEvent> CAuthenticationController::promptEventLocked() const {
        if (!m_prompt)
            return {};
        return SAuthenticationEvent{
            .kind           = SAuthenticationEvent::EKind::Prompt,
            .state          = snapshotLocked(std::chrono::steady_clock::now()),
            .promptStyle    = m_prompt->style,
            .promptSequence = m_prompt->sequence,
            .message        = m_prompt->message,
        };
    }

    void CAuthenticationController::publish(SAuthenticationEvent event) const {
        if (m_callback)
            m_callback(std::move(event));
    }

    void CAuthenticationController::publishState() const {
        publish(SAuthenticationEvent{
            .kind  = SAuthenticationEvent::EKind::State,
            .state = snapshot(),
        });
    }

    void CAuthenticationController::synchronize() {
        SAuthenticationEvent                stateEvent;
        std::optional<SAuthenticationEvent> promptEvent;
        {
            std::lock_guard lock(m_mutex);
            stateEvent = SAuthenticationEvent{
                .kind  = SAuthenticationEvent::EKind::State,
                .state = snapshotLocked(std::chrono::steady_clock::now()),
            };
            promptEvent = promptEventLocked();
        }
        publish(std::move(stateEvent));
        if (promptEvent)
            publish(std::move(*promptEvent));
    }

    void CAuthenticationController::lock() {
        {
            std::lock_guard lock(m_mutex);
            m_locked.store(true, std::memory_order_release);
            if (m_busy) {
                ++m_generation;
                m_cancelRequested = true;
                m_response.reset();
                m_prompt.reset();
            }
        }
        m_condition.notify_all();
        publishState();
    }

    void CAuthenticationController::begin() {
        std::optional<SAuthenticationEvent> immediateResult;
        {
            std::lock_guard lock(m_mutex);
            const auto      now = std::chrono::steady_clock::now();
            if (!m_locked.load(std::memory_order_acquire) || m_busy)
                return;

            if (!m_backend->available()) {
                immediateResult = SAuthenticationEvent{
                    .kind    = SAuthenticationEvent::EKind::Result,
                    .state   = snapshotLocked(now),
                    .message = m_backend->unavailableReason(),
                };
            } else if (m_cooldownUntil > now) {
                immediateResult = SAuthenticationEvent{
                    .kind    = SAuthenticationEvent::EKind::Result,
                    .state   = snapshotLocked(now),
                    .message = "Please wait before trying again.",
                };
            } else {
                ++m_generation;
                m_activeAttemptId = m_nextAttemptId++;
                if (m_nextAttemptId == 0)
                    m_nextAttemptId = 1;
                m_busy            = true;
                m_cancelRequested = false;
                m_prompt.reset();
                m_response.reset();
                m_pendingWork = SWorkItem{
                    .attemptId  = m_activeAttemptId,
                    .generation = m_generation,
                };
            }
        }

        if (immediateResult) {
            publish(std::move(*immediateResult));
            publishState();
            return;
        }
        m_condition.notify_all();
        publishState();
    }

    bool CAuthenticationController::respond(uint64_t attemptId, uint32_t promptSequence, CSecureString response) {
        {
            std::lock_guard lock(m_mutex);
            if (!m_busy || m_cancelRequested || attemptId == 0 || attemptId != m_activeAttemptId || !m_prompt || !m_prompt->requiresResponse || promptSequence == 0 ||
                promptSequence != m_prompt->sequence || m_response)
                return false;
            m_response.emplace(std::move(response));
        }
        m_condition.notify_all();
        return true;
    }

    void CAuthenticationController::cancel(uint64_t attemptId) {
        {
            std::lock_guard lock(m_mutex);
            if (!m_busy || (attemptId != 0 && attemptId != m_activeAttemptId))
                return;
            ++m_generation;
            m_cancelRequested = true;
            m_response.reset();
            m_prompt.reset();
        }
        m_condition.notify_all();
        publishState();
    }

    bool CAuthenticationController::cancelled(uint64_t generation) const {
        std::lock_guard lock(m_mutex);
        return m_stopping || generation != m_generation || m_cancelRequested;
    }

    std::optional<CSecureString> CAuthenticationController::converse(uint64_t attemptId, uint64_t generation, EAuthenticationPromptStyle style, std::string_view message) {
        SAuthenticationEvent event;
        const bool           requiresResponse = style == EAuthenticationPromptStyle::EchoOff || style == EAuthenticationPromptStyle::EchoOn;
        uint32_t             sequence         = 0;
        {
            std::lock_guard lock(m_mutex);
            if (m_stopping || generation != m_generation || m_cancelRequested || attemptId != m_activeAttemptId)
                return {};

            sequence = m_nextPromptSequence++;
            if (m_nextPromptSequence == 0)
                m_nextPromptSequence = 1;
            m_prompt = SPromptState{
                .style            = style,
                .sequence         = sequence,
                .message          = sanitizeMessage(message),
                .requiresResponse = requiresResponse,
            };
            m_response.reset();
            event = SAuthenticationEvent{
                .kind           = SAuthenticationEvent::EKind::Prompt,
                .state          = snapshotLocked(std::chrono::steady_clock::now()),
                .promptStyle    = style,
                .promptSequence = sequence,
                .message        = m_prompt->message,
            };
        }
        publish(std::move(event));

        if (!requiresResponse)
            return CSecureString{};

        std::unique_lock lock(m_mutex);
        const bool       ready =
            m_condition.wait_for(lock, std::chrono::seconds(120), [&] { return m_stopping || generation != m_generation || m_cancelRequested || m_response.has_value(); });
        if (!ready) {
            ++m_generation;
            m_cancelRequested = true;
            m_prompt.reset();
            return {};
        }
        if (m_stopping || generation != m_generation || m_cancelRequested || !m_response)
            return {};

        auto response = std::move(*m_response);
        m_response.reset();
        if (m_prompt && m_prompt->sequence == sequence)
            m_prompt.reset();
        return response;
    }

    void CAuthenticationController::run() {
        while (true) {
            SWorkItem work;
            {
                std::unique_lock lock(m_mutex);
                m_condition.wait(lock, [&] { return m_stopping || m_pendingWork.has_value(); });
                if (m_stopping)
                    return;
                work = *m_pendingWork;
                m_pendingWork.reset();
            }

            const auto result = m_backend->authenticate(
                m_username, [this, work](EAuthenticationPromptStyle style, std::string_view message) { return converse(work.attemptId, work.generation, style, message); },
                [this, work] { return cancelled(work.generation); });

            SAuthenticationEvent resultEvent;
            {
                std::lock_guard lock(m_mutex);
                const bool      current      = !m_stopping && work.attemptId == m_activeAttemptId && work.generation == m_generation && !m_cancelRequested;
                const bool      success      = current && result == EAuthenticationBackendResult::Success;
                const bool      wasCancelled = !current || result == EAuthenticationBackendResult::Cancelled;

                m_busy            = false;
                m_cancelRequested = false;
                m_prompt.reset();
                m_response.reset();

                std::string message;
                if (success) {
                    m_locked.store(false, std::memory_order_release);
                    m_failureCount  = 0;
                    m_cooldownUntil = {};
                    message         = "Authentication successful";
                } else if (wasCancelled) {
                    message = "Authentication cancelled";
                } else {
                    ++m_failureCount;
                    m_cooldownUntil = std::chrono::steady_clock::now() + cooldownForFailure(m_failureCount);
                    message         = result == EAuthenticationBackendResult::Failure ? "Authentication failed. Try again." : "System authentication could not complete.";
                }

                resultEvent = SAuthenticationEvent{
                    .kind      = SAuthenticationEvent::EKind::Result,
                    .state     = snapshotLocked(std::chrono::steady_clock::now()),
                    .message   = std::move(message),
                    .success   = success,
                    .cancelled = wasCancelled,
                };
            }
            publish(std::move(resultEvent));
            publishState();
        }
    }

} // namespace Denial
