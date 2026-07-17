#include "Env.hpp"

#include <cstdlib>
#include <mutex>
#include <shared_mutex>
#include <unordered_map>
#include <string_view>

extern "C" char** environ;

namespace {
    std::unordered_map<std::string, std::string> environment;
    std::shared_mutex                            environmentMutex;
    bool                                         captured = false;
    bool                                         trace    = false;
}

void Env::capture() {
    std::unique_lock lock(environmentMutex);
    if (captured)
        return;

    for (char** entry = environ; entry && *entry; ++entry) {
        const std::string_view raw       = *entry;
        const auto             separator = raw.find('=');
        if (separator == std::string_view::npos || separator == 0)
            continue;

        environment.insert_or_assign(std::string{raw.substr(0, separator)}, std::string{raw.substr(separator + 1)});
    }

    if (const auto it = environment.find("HYPRLAND_TRACE"); it != environment.end())
        trace = !it->second.empty() && it->second != "0";

    captured = true;
}

std::optional<std::string> Env::get(std::string_view name) {
    std::shared_lock lock(environmentMutex);
    if (!captured)
        return std::nullopt;

    const auto it = environment.find(std::string{name});
    if (it == environment.end())
        return std::nullopt;

    return it->second;
}

bool Env::envEnabled(std::string_view name) {
    const auto value = get(name);
    if (!value)
        return false;

    return !value->empty() && *value != "0";
}

bool Env::set(std::string_view name, std::string_view value, bool overwrite) {
    const std::string ownedName{name};
    const std::string ownedValue{value};

    {
        std::shared_lock lock(environmentMutex);
        if (!captured)
            return false;
        if (!overwrite && environment.contains(ownedName))
            return true;
    }

    if (::setenv(ownedName.c_str(), ownedValue.c_str(), 1) != 0)
        return false;

    std::unique_lock lock(environmentMutex);
    environment.insert_or_assign(ownedName, ownedValue);
    return true;
}

bool Env::unset(std::string_view name) {
    const std::string ownedName{name};
    if (::unsetenv(ownedName.c_str()) != 0)
        return false;

    std::unique_lock lock(environmentMutex);
    if (!captured)
        return false;
    environment.erase(ownedName);
    return true;
}

bool Env::isTrace() {
    return trace;
}
