#include "SdDaemon.hpp"
#include "env/Env.hpp"
#include "memory/Memory.hpp"

#include <memory>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <sys/socket.h>
#include <sys/un.h>
#include <cstdlib>
#include <cstring>

int NSystemd::sdBooted() {
    if (!faccessat(AT_FDCWD, "/run/systemd/system/", F_OK, AT_SYMLINK_NOFOLLOW))
        return true;

    if (errno == ENOENT)
        return false;

    return -errno;
}

int NSystemd::sdNotify(int unsetEnvironment, const char* state) {
    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return -errno;

    constexpr char envVar[] = "NOTIFY_SOCKET";

    auto           cleanup = [unsetEnvironment, envVar](const int* fd) {
        if (unsetEnvironment)
            Env::unset(envVar);
        close(*fd);
    };
    std::unique_ptr<int, decltype(cleanup)> fdCleaup(&fd, cleanup);

    const auto                              address = Env::get(envVar);
    if (!address)
        return 0;
    const char*        addr = address->c_str();

    struct sockaddr_un unixAddr = {0};

    size_t             addrLen = strnlen(addr, sizeof(unixAddr.sun_path) - 1);

    unixAddr.sun_family = AF_UNIX;
    strncpy(unixAddr.sun_path, addr, addrLen);
    if (unixAddr.sun_path[0] == '@')
        unixAddr.sun_path[0] = '\0';

    if (connect(fd, rc<const sockaddr*>(&unixAddr), sizeof(struct sockaddr_un)) < 0)
        return -errno;

    // arbitrary value which seems to be enough for s-d messages
    ssize_t stateLen = strnlen(state, 128);
    if (write(fd, state, stateLen) == stateLen)
        return 1;

    return -errno;
}
