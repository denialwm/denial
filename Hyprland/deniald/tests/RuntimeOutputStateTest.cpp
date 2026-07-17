#include "../RuntimeOutputState.hpp"

#include <array>
#include <optional>

namespace {

    using Denial::RuntimeOutputState::eBufferEvent;
    using Denial::RuntimeOutputState::eBufferState;
    using Denial::RuntimeOutputState::transition;

    template <std::size_t N>
    constexpr std::optional<eBufferState> runSequence(eBufferState initial, const std::array<eBufferEvent, N>& events) {
        auto state = initial;
        for (const auto event : events) {
            const auto next = transition(state, event);
            if (!next)
                return std::nullopt;
            state = *next;
        }
        return state;
    }

    constexpr auto PREPARED_FRAME_LIFETIME = std::to_array({
        eBufferEvent::ACQUIRE_FOR_RENDER,
        eBufferEvent::PUBLISH_PREPARED,
        eBufferEvent::SUBMIT_READY,
        eBufferEvent::PRESENT,
        eBufferEvent::RETIRE,
    });

    constexpr auto CANCELLED_PREPARATION = std::to_array({
        eBufferEvent::ACQUIRE_FOR_RENDER,
        eBufferEvent::CANCEL_PREPARATION,
    });

    constexpr auto ATLAS_REPEAT_LIFETIME = std::to_array({
        eBufferEvent::PUBLISH_ATLAS_VIEW,
        eBufferEvent::SUBMIT_READY,
        eBufferEvent::PRESENT,
        eBufferEvent::REJECT_REPEAT,
        eBufferEvent::SUBMIT_REPEAT,
        eBufferEvent::PRESENT,
        eBufferEvent::RETIRE,
    });

    constexpr auto REJECTED_READY_FRAME = std::to_array({
        eBufferEvent::ACQUIRE_FOR_RENDER,
        eBufferEvent::PUBLISH_PREPARED,
        eBufferEvent::REJECT_READY,
        eBufferEvent::SUBMIT_READY,
        eBufferEvent::PRESENT,
        eBufferEvent::RETIRE,
    });

    constexpr auto DROPPED_ATLAS_VIEW = std::to_array({
        eBufferEvent::PUBLISH_ATLAS_VIEW,
        eBufferEvent::DROP_READY,
    });

    static_assert(runSequence(eBufferState::FREE, PREPARED_FRAME_LIFETIME) == eBufferState::FREE);
    static_assert(runSequence(eBufferState::FREE, CANCELLED_PREPARATION) == eBufferState::FREE);
    static_assert(runSequence(eBufferState::FREE, ATLAS_REPEAT_LIFETIME) == eBufferState::FREE);
    static_assert(runSequence(eBufferState::FREE, REJECTED_READY_FRAME) == eBufferState::FREE);
    static_assert(runSequence(eBufferState::FREE, DROPPED_ATLAS_VIEW) == eBufferState::FREE);

    static_assert(!transition(eBufferState::FREE, eBufferEvent::SUBMIT_READY));
    static_assert(!transition(eBufferState::PREPARING, eBufferEvent::PUBLISH_ATLAS_VIEW));
    static_assert(!transition(eBufferState::SUBMITTED, eBufferEvent::RETIRE));

} // namespace

int main() {
    return 0;
}
