#include "../WindowDecorationPolicy.hpp"

namespace {

    using Denial::WindowDecorationPolicy::SRequest;
    using Denial::WindowDecorationPolicy::drawsServerFrame;

    static_assert(drawsServerFrame(SRequest{}));
    static_assert(drawsServerFrame(SRequest{.clientPrefersServerFrame = false}));
    static_assert(!drawsServerFrame(SRequest{.popupLike = true}));
    static_assert(!drawsServerFrame(SRequest{.popupLike = true, .respectClientPreference = true}));
    static_assert(drawsServerFrame(SRequest{.respectClientPreference = true}));
    static_assert(!drawsServerFrame(SRequest{.respectClientPreference = true, .clientPrefersServerFrame = false}));

} // namespace

int main() {
    return 0;
}
