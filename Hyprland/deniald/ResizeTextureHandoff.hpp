#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>

namespace Denial::ResizeTextureHandoff {

    // A target-sized commit can still contain an older Chromium viewport.
    // Keep the previous frame stretched for roughly two 60 Hz frames so a
    // newer commit can replace that transitional image. The hard deadline
    // guarantees that unusual clients can never leave a texture frozen.
    inline constexpr uint64_t CONTENT_SETTLE_US = 32'000;
    inline constexpr uint64_t MAX_WAIT_US       = 120'000;

    struct SSize {
        double width  = 0.0;
        double height = 0.0;
    };

    inline bool valid(const SSize& size) {
        return std::isfinite(size.width) && std::isfinite(size.height) && size.width > 0.0 && size.height > 0.0;
    }

    inline double tolerance(double value) {
        return std::max(1.0, std::abs(value) * 0.001);
    }

    inline bool approximatelyEqual(double left, double right) {
        return std::isfinite(left) && std::isfinite(right) && std::abs(left - right) <= std::max(tolerance(left), tolerance(right));
    }

    inline bool approximatelyEqual(const SSize& left, const SSize& right) {
        return valid(left) && valid(right) && approximatelyEqual(left.width, right.width) && approximatelyEqual(left.height, right.height);
    }

    inline bool resizeActive(const SSize& targetWindow, const SSize& sourceWindow) {
        return valid(targetWindow) && valid(sourceWindow) && !approximatelyEqual(targetWindow, sourceWindow);
    }

    inline std::optional<SSize> expectedSurfaceSize(const SSize& currentSurface, const SSize& targetWindow, const SSize& sourceWindow) {
        if (!valid(currentSurface) || !valid(targetWindow) || !valid(sourceWindow))
            return std::nullopt;

        const SSize expected{
            .width  = currentSurface.width * targetWindow.width / sourceWindow.width,
            .height = currentSurface.height * targetWindow.height / sourceWindow.height,
        };
        return valid(expected) ? std::optional<SSize>{expected} : std::nullopt;
    }

    inline bool surfaceMatchesTarget(const SSize& currentSurface, const SSize& queuedSurface, const SSize& targetWindow, const SSize& sourceWindow) {
        const auto expected = expectedSurfaceSize(currentSurface, targetWindow, sourceWindow);
        return expected && approximatelyEqual(queuedSurface, *expected);
    }

    inline bool candidateReady(uint64_t candidateSinceUs, uint64_t deadlineUs, uint64_t nowUs) {
        if (deadlineUs != 0 && nowUs >= deadlineUs)
            return true;
        return candidateSinceUs != 0 && nowUs >= candidateSinceUs && nowUs - candidateSinceUs >= CONTENT_SETTLE_US;
    }

    inline uint64_t nextWakeUs(uint64_t candidateSinceUs, uint64_t deadlineUs) {
        if (candidateSinceUs == 0)
            return deadlineUs;
        if (deadlineUs == 0)
            return candidateSinceUs + CONTENT_SETTLE_US;
        return std::min(deadlineUs, candidateSinceUs + CONTENT_SETTLE_US);
    }

} // namespace Denial::ResizeTextureHandoff
