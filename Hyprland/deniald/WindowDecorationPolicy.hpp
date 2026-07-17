#pragma once

namespace Denial::WindowDecorationPolicy {

    struct SRequest {
        bool popupLike                = false;
        bool respectClientPreference  = false;
        bool clientPrefersServerFrame = true;
    };

    // Denial owns the desktop frame policy: popup-like surfaces are always
    // frameless, while every normal window is framed by default. Protocol and
    // X11 decoration preferences remain available as an explicit user opt-in.
    constexpr bool drawsServerFrame(const SRequest& request) {
        return !request.popupLike && (!request.respectClientPreference || request.clientPrefersServerFrame);
    }

} // namespace Denial::WindowDecorationPolicy
