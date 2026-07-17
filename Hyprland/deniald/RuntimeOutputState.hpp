#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

namespace Denial::RuntimeOutputState {

    enum class eBufferState : std::uint8_t {
        FREE,
        PREPARING,
        READY,
        SUBMITTED,
        SCANNING,
        COUNT,
    };

    enum class eBufferEvent : std::uint8_t {
        ACQUIRE_FOR_RENDER,
        CANCEL_PREPARATION,
        PUBLISH_PREPARED,
        PUBLISH_ATLAS_VIEW,
        DROP_READY,
        REJECT_READY,
        SUBMIT_READY,
        REJECT_REPEAT,
        SUBMIT_REPEAT,
        PRESENT,
        RETIRE,
        COUNT,
    };

    struct SBufferTransition {
        eBufferState from;
        eBufferState to;
    };

    inline constexpr std::size_t                                       BUFFER_STATE_COUNT = static_cast<std::size_t>(eBufferState::COUNT);
    inline constexpr std::size_t                                       BUFFER_EVENT_COUNT = static_cast<std::size_t>(eBufferEvent::COUNT);

    inline constexpr std::array<SBufferTransition, BUFFER_EVENT_COUNT> BUFFER_TRANSITIONS = {{
        {eBufferState::FREE, eBufferState::PREPARING},     // ACQUIRE_FOR_RENDER
        {eBufferState::PREPARING, eBufferState::FREE},     // CANCEL_PREPARATION
        {eBufferState::PREPARING, eBufferState::READY},    // PUBLISH_PREPARED
        {eBufferState::FREE, eBufferState::READY},         // PUBLISH_ATLAS_VIEW
        {eBufferState::READY, eBufferState::FREE},         // DROP_READY
        {eBufferState::READY, eBufferState::READY},        // REJECT_READY
        {eBufferState::READY, eBufferState::SUBMITTED},    // SUBMIT_READY
        {eBufferState::SCANNING, eBufferState::SCANNING},  // REJECT_REPEAT
        {eBufferState::SCANNING, eBufferState::SUBMITTED}, // SUBMIT_REPEAT
        {eBufferState::SUBMITTED, eBufferState::SCANNING}, // PRESENT
        {eBufferState::SCANNING, eBufferState::FREE},      // RETIRE
    }};

    inline constexpr std::array<std::string_view, BUFFER_STATE_COUNT>  BUFFER_STATE_NAMES = {
        "FREE", "PREPARING", "READY", "SUBMITTED", "SCANNING",
    };

    inline constexpr std::array<std::string_view, BUFFER_EVENT_COUNT> BUFFER_EVENT_NAMES = {
        "acquire-for-render",
        "cancel-preparation",
        "publish-prepared",
        "publish-atlas-view",
        "drop-ready",
        "reject-ready",
        "submit-ready",
        "reject-repeat",
        "submit-repeat",
        "present",
        "retire",
    };

    constexpr const SBufferTransition& transitionFor(eBufferEvent event) noexcept {
        return BUFFER_TRANSITIONS[static_cast<std::size_t>(event)];
    }

    constexpr std::optional<eBufferState> transition(eBufferState current, eBufferEvent event) noexcept {
        const auto& rule = transitionFor(event);
        if (current != rule.from)
            return std::nullopt;
        return rule.to;
    }

    constexpr std::string_view nameOf(eBufferState state) noexcept {
        const auto index = static_cast<std::size_t>(state);
        return index < BUFFER_STATE_NAMES.size() ? BUFFER_STATE_NAMES[index] : "INVALID";
    }

    constexpr std::string_view nameOf(eBufferEvent event) noexcept {
        const auto index = static_cast<std::size_t>(event);
        return index < BUFFER_EVENT_NAMES.size() ? BUFFER_EVENT_NAMES[index] : "invalid-event";
    }

} // namespace Denial::RuntimeOutputState
