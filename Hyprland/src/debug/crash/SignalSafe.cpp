#include "SignalSafe.hpp"
#include "../../helpers/env/Env.hpp"

#ifndef __GLIBC__
#include <signal.h>
#endif
#include <fcntl.h>
#include <unistd.h>
#include <array>
#include <cstring>

using namespace SignalSafe;

namespace {
    constexpr size_t               MAX_ENV_PATH = 4096;
    std::array<char, MAX_ENV_PATH> home{};
    std::array<char, MAX_ENV_PATH> cacheHome{};
    bool                           hasHome      = false;
    bool                           hasCacheHome = false;

    bool                           copyEnvironmentPath(std::array<char, MAX_ENV_PATH>& destination, const std::optional<std::string>& source) {
        if (!source || source->size() >= destination.size())
            return false;

        std::memcpy(destination.data(), source->data(), source->size());
        destination[source->size()] = '\0';
        return true;
    }
}

void SignalSafe::captureEnvironment() {
    hasHome      = copyEnvironmentPath(home, Env::get("HOME"));
    hasCacheHome = copyEnvironmentPath(cacheHome, Env::get("XDG_CACHE_HOME"));
}

char const* SignalSafe::environmentValue(char const* name) {
    if (hasHome && std::strcmp(name, "HOME") == 0)
        return home.data();
    if (hasCacheHome && std::strcmp(name, "XDG_CACHE_HOME") == 0)
        return cacheHome.data();
    return nullptr;
}

char const* SignalSafe::strsignal(int sig) {
#ifdef __GLIBC__
    return sigabbrev_np(sig);
#elif defined(__DragonFly__) || defined(__FreeBSD__)
    return sys_signame[sig];
#else
    return "unknown";
#endif
}
