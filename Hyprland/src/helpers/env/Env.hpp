#pragma once

#include <optional>
#include <string>
#include <string_view>

namespace Env {
    // Capture the process environment once, before compositor initialization.
    // Runtime code reads this owned cache instead of calling getenv lazily.
    void                       capture();
    std::optional<std::string> get(std::string_view name);
    bool                       envEnabled(std::string_view name);

    // Keep deliberate runtime exports visible both to future child processes
    // and to cached reads without rescanning the process environment.
    bool set(std::string_view name, std::string_view value, bool overwrite = true);
    bool unset(std::string_view name);

    bool isTrace();
}
