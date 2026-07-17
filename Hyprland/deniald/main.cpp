#include "Runtime.hpp"

#include "../src/Compositor.hpp"
#include "../src/config/ConfigManager.hpp"
#include "../src/debug/HyprCtl.hpp"
#include "../src/debug/crash/SignalSafe.hpp"
#include "../src/debug/log/Logger.hpp"
#include "../src/helpers/env/Env.hpp"
#include "../src/init/initHelpers.hpp"

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fcntl.h>
#include <print>
#include <stdexcept>
#include <string>
#include <string_view>

namespace {

    struct SParsedArgs {
        std::string configPath;
        std::string socketName;
        std::string flutterBundlePath;
        std::string flutterMonitor;
        std::string systemBarMonitor;
        std::string systemBarSide;
        int         socketFd               = -1;
        int         watchdogFd             = -1;
        uint16_t    flutterOutputTransform = 5;
        bool        ignoreSudo             = false;
        bool        verifyConfig           = false;
        bool        safeMode               = false;
        bool        directKmsRendering     = false;
        bool        disableDamageTracking  = false;
        bool        forceBlockingSceneCopy = false;
    };

    void printHelp() {
        std::println("usage: deniald [arg [...]]\n");
        std::println(R"#(Arguments:
    --help              -h       - Show this message
    --config FILE       -c FILE  - Specify the Denial compositor config file
    --socket NAME                - Sets the Wayland socket name
    --wayland-fd FD              - Sets the Wayland socket fd
    --watchdog-fd FD             - Used by start-hyprland
    --safe-mode                  - Starts Denial in safe mode
    --verify-config              - Do not run Denial, only print config status
    --version           -v       - Print Denial version
    --version-json               - Print Denial version as JSON
    --systeminfo                 - Prints system info
    --i-am-really-stupid         - Omits root user privileges check
    --flutter-bundle PATH        - Dart/Flutter bundle path
    --flutter-monitor NAME       - Preferred physical-vsync ticker for the Flutter scene
    --system-bar-monitor NAME    - Monitor that owns the single Flutter system bar
    --system-bar-side SIDE       - System bar side [left|right|top|bottom|hidden], default left
    --flutter-output-transform X - Transform embedded Flutter output target
                                   [normal|rotate-90|rotate-180|rotate-270|flip-x|flip-y], default flip-y
    --denial-disable-damage
                               - Force full Flutter repaint and full scene/KMS blit damage
    --denial-force-blocking-scene-copy
                               - Finish the scene-to-scanout GL copy before KMS submission;
                                 required only by presentation backends without input fences
    --flutter-direct-kms        - Experimental: render Flutter directly into KMS swapchain buffers)#");
    }

    void reapZombieChildrenAutomatically() {
        struct sigaction act = {};
        act.sa_handler       = SIG_DFL;
        sigemptyset(&act.sa_mask);
        act.sa_flags = SA_NOCLDWAIT;
#ifdef SA_RESTORER
        act.sa_restorer = nullptr;
#endif
        sigaction(SIGCHLD, &act, nullptr);
    }

    bool parseIntArg(const char* raw, int* out, const char* name) {
        try {
            *out = std::stoi(raw);
            return true;
        } catch (const std::exception& e) {
            std::println(stderr, "[ ERROR ] Invalid {} '{}': {}", name, raw, e.what());
            return false;
        }
    }

    bool parseTransformArg(const char* raw, uint16_t* out, const char* name) {
        const std::string value = raw ? raw : "";
        if (value == "normal") {
            *out = 0;
            return true;
        }
        if (value == "rotate-90") {
            *out = 1;
            return true;
        }
        if (value == "rotate-180") {
            *out = 2;
            return true;
        }
        if (value == "rotate-270") {
            *out = 3;
            return true;
        }
        if (value == "flip-x") {
            *out = 4;
            return true;
        }
        if (value == "flip-y") {
            *out = 5;
            return true;
        }

        int numeric = 0;
        if (!parseIntArg(raw, &numeric, name))
            return false;

        if (numeric < 0 || numeric > 5) {
            std::println(stderr, "[ ERROR ] Invalid {} '{}': expected normal, rotate-90, rotate-180, rotate-270, flip-x or flip-y", name, raw);
            return false;
        }

        *out = static_cast<uint16_t>(numeric);
        return true;
    }

    bool parseSystemBarSide(const char* raw, std::string* out, const char* name) {
        const std::string value = raw ? raw : "";
        if (value == "left" || value == "right" || value == "top" || value == "bottom" || value == "hidden") {
            *out = value;
            return true;
        }

        std::println(stderr, "[ ERROR ] Invalid {} '{}': expected left, right, top, bottom or hidden", name, value);
        return false;
    }

    bool parseArgs(int argc, char** argv, SParsedArgs* parsed) {
        for (int i = 1; i < argc; ++i) {
            const std::string_view value = argv[i];

            auto                   requireValue = [&](const char* option) -> const char* {
                if (i + 1 >= argc) {
                    std::println(stderr, "[ ERROR ] Missing value for {}", option);
                    printHelp();
                    return nullptr;
                }
                return argv[++i];
            };

            if (value == "--i-am-really-stupid") {
                std::println("[ WARNING ] Running deniald with superuser privileges might damage your system");
                parsed->ignoreSudo = true;
            } else if (value == "--socket") {
                const char* raw = requireValue("--socket");
                if (!raw)
                    return false;
                parsed->socketName = raw;
            } else if (value == "--wayland-fd") {
                const char* raw = requireValue("--wayland-fd");
                if (!raw || !parseIntArg(raw, &parsed->socketFd, "--wayland-fd"))
                    return false;
                if (fcntl(parsed->socketFd, F_GETFD) == -1) {
                    std::println(stderr, "[ ERROR ] Invalid or closed Wayland fd '{}'", raw);
                    return false;
                }
            } else if (value == "-c" || value == "--config") {
                const char* raw = requireValue("--config");
                if (!raw)
                    return false;
                try {
                    const auto absPath = std::filesystem::canonical(raw);
                    if (!std::filesystem::is_regular_file(absPath))
                        throw std::runtime_error("not a regular file");
                    parsed->configPath = absPath;
                } catch (const std::exception& e) {
                    std::println(stderr, "[ ERROR ] Config file '{}' is invalid: {}", raw, e.what());
                    return false;
                }
            } else if (value == "--watchdog-fd") {
                const char* raw = requireValue("--watchdog-fd");
                if (!raw || !parseIntArg(raw, &parsed->watchdogFd, "--watchdog-fd"))
                    return false;
            } else if (value == "--flutter-bundle") {
                const char* raw = requireValue("--flutter-bundle");
                if (!raw)
                    return false;
                parsed->flutterBundlePath = raw;
            } else if (value == "--flutter-monitor") {
                const char* raw = requireValue("--flutter-monitor");
                if (!raw)
                    return false;
                parsed->flutterMonitor = raw;
            } else if (value == "--system-bar-monitor") {
                const char* raw = requireValue("--system-bar-monitor");
                if (!raw)
                    return false;
                parsed->systemBarMonitor = raw;
            } else if (value == "--system-bar-side") {
                const char* raw = requireValue("--system-bar-side");
                if (!raw || !parseSystemBarSide(raw, &parsed->systemBarSide, "--system-bar-side"))
                    return false;
            } else if (value == "--flutter-output-transform") {
                const char* raw = requireValue("--flutter-output-transform");
                if (!raw || !parseTransformArg(raw, &parsed->flutterOutputTransform, "--flutter-output-transform"))
                    return false;
            } else if (value == "--denial-disable-damage") {
                parsed->disableDamageTracking = true;
            } else if (value == "--denial-force-blocking-scene-copy") {
                parsed->forceBlockingSceneCopy = true;
            } else if (value == "--flutter-direct-kms") {
                parsed->directKmsRendering = true;
            } else if (value == "--safe-mode") {
                parsed->safeMode = true;
            } else if (value == "--verify-config") {
                parsed->verifyConfig = true;
            } else if (value == "-h" || value == "--help") {
                printHelp();
                std::exit(EXIT_SUCCESS);
            } else if (value == "-v" || value == "--version") {
                std::println("{}", versionRequest(eHyprCtlOutputFormat::FORMAT_NORMAL, ""));
                std::exit(EXIT_SUCCESS);
            } else if (value == "--version-json") {
                std::println("{}", versionRequest(eHyprCtlOutputFormat::FORMAT_JSON, ""));
                std::exit(EXIT_SUCCESS);
            } else if (value == "--systeminfo") {
                std::println("{}", systemInfoRequest(eHyprCtlOutputFormat::FORMAT_NORMAL, ""));
                std::exit(EXIT_SUCCESS);
            } else {
                std::println(stderr, "[ ERROR ] Unknown option '{}'", value);
                printHelp();
                return false;
            }
        }

        return true;
    }

    void exportRuntimeEnvironment(int argc, char** argv) {
        std::string cmd = argv[0];
        for (int i = 1; i < argc; ++i)
            cmd += std::string(" ") + argv[i];

        Env::set("HYPRLAND_CMD", cmd);
        Env::set("XDG_BACKEND", "wayland");
        Env::set("XDG_SESSION_TYPE", "wayland");
        Env::set("_JAVA_AWT_WM_NONREPARENTING", "1");
        Env::set("MOZ_ENABLE_WAYLAND", "1");
    }

} // namespace

int main(int argc, char** argv) {
    Env::capture();
    SignalSafe::captureEnvironment();

    if (!Env::get("XDG_RUNTIME_DIR")) {
        std::println(stderr, "[ ERROR ] XDG_RUNTIME_DIR is not set");
        return EXIT_FAILURE;
    }

    exportRuntimeEnvironment(argc, argv);
    SParsedArgs args;
    if (!parseArgs(argc, argv, &args))
        return EXIT_FAILURE;
    args.directKmsRendering     = args.directKmsRendering || Env::envEnabled("DENIAL_DIRECT_KMS");
    args.disableDamageTracking  = args.disableDamageTracking || Env::envEnabled("DENIAL_DISABLE_DAMAGE");
    args.forceBlockingSceneCopy = args.forceBlockingSceneCopy || Env::envEnabled("DENIAL_FORCE_BLOCKING_SCENE_COPY");

    if (!args.ignoreSudo && NInit::isSudo()) {
        std::println(stderr,
                     "[ ERROR ] deniald was launched with superuser privileges, but the privileges check is not omitted.\n"
                     "          Hint: Use the --i-am-really-stupid flag to omit that check.");
        return EXIT_FAILURE;
    }

    if (args.socketName.empty() ^ (args.socketFd == -1)) {
        std::println(stderr,
                     "[ ERROR ] deniald was launched with only one of --socket and --wayland-fd.\n"
                     "          Hint: Pass both --socket and --wayland-fd to perform Wayland socket handover.");
        return EXIT_FAILURE;
    }

    if (!args.verifyConfig && !Env::envEnabled("HYPRLAND_NO_RT"))
        NInit::gainRealTime();

    try {
        g_pCompositor                       = makeUnique<CCompositor>(args.verifyConfig);
        g_pCompositor->m_explicitConfigPath = args.configPath;
    } catch (const std::exception& e) {
        std::println(stderr, "deniald failed to create CCompositor: {}", e.what());
        return EXIT_FAILURE;
    }

    reapZombieChildrenAutomatically();

    if (args.watchdogFd > 0 && !g_pCompositor->setWatchdogFd(args.watchdogFd) && !args.verifyConfig)
        Log::logger->log(Log::WARN, "WARNING: deniald failed to set watchdog fd {}", args.watchdogFd);

    if (args.safeMode)
        g_pCompositor->m_safeMode = true;

    g_pCompositor->initServer(args.socketName, args.socketFd);

    if (args.verifyConfig)
        return !Config::mgr()->configVerifPassed();

    if (args.systemBarMonitor.empty()) {
        if (const auto configured = Env::get("DENIAL_SYSTEM_BAR_MONITOR"))
            args.systemBarMonitor = *configured;
    }
    if (args.systemBarSide.empty()) {
        const auto configured = Env::get("DENIAL_SYSTEM_BAR_SIDE");
        if (!parseSystemBarSide(configured ? configured->c_str() : "left", &args.systemBarSide, "DENIAL_SYSTEM_BAR_SIDE"))
            return EXIT_FAILURE;
    }

    Denial::CRuntime runtime({
        .dartBundlePath         = args.flutterBundlePath,
        .flutterMonitor         = args.flutterMonitor,
        .systemBarMonitor       = args.systemBarMonitor,
        .systemBarSide          = args.systemBarSide,
        .directKmsRendering     = args.directKmsRendering,
        .disableDamageTracking  = args.disableDamageTracking,
        .forceBlockingSceneCopy = args.forceBlockingSceneCopy,
        .flutterOutputTransform = args.flutterOutputTransform,
    });
    bool             runtimeOk = true;

    g_pCompositor->m_beforeEventLoopHook = [&runtime, &runtimeOk] {
        runtimeOk = runtime.initializeBeforeHyprlandLoop();

        // GPU selection is compositor bootstrap state. Do not leak it into
        // applications launched after the Wayland session becomes ready:
        // games may intentionally render on a different GPU.
        Env::unset("AQ_DRM_DEVICES");
        Env::unset("__EGL_VENDOR_LIBRARY_FILENAMES");

        if (!runtimeOk && g_pCompositor)
            g_pCompositor->stopCompositor();
    };

    Log::logger->log(Log::DEBUG, "deniald init finished");

    g_pCompositor->startCompositor();

    runtime.shutdown();
    g_pCompositor->cleanup();
    g_pCompositor.reset();

    Log::logger->log(Log::DEBUG, "deniald has reached the end");
    return runtimeOk ? EXIT_SUCCESS : EXIT_FAILURE;
}
