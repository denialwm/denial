cmake_minimum_required(VERSION 3.30)

# Get version
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" VER_RAW)
string(STRIP "${VER_RAW}" VER)

project(
  Denial
  DESCRIPTION "Flutter-native Wayland compositor"
  VERSION ${VER})

enable_testing()
option(DENIAL_BUILD_TESTS "Build Denial-owned native regression tests" OFF)

include(CheckIncludeFile)

set(HYPRLAND_VERSION ${VER})

set(CMAKE_MESSAGE_LOG_LEVEL "STATUS")

message(STATUS "Gathering git info")

# Make generated shader files includable without modifying the source tree.
set(DENIAL_SHADER_OUTPUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated/render/shaders")
execute_process(COMMAND ./scripts/generateShaderIncludes.sh ${DENIAL_SHADER_OUTPUT_DIR}
                WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
                RESULT_VARIABLE HYPR_SHADER_GEN_RESULT)
if(NOT HYPR_SHADER_GEN_RESULT EQUAL 0)
  message(
    FATAL_ERROR
      "Failed to generate shader includes (scripts/generateShaderIncludes.sh), exit code: ${HYPR_SHADER_GEN_RESULT}"
  )
endif()

find_package(PkgConfig REQUIRED)

set(DENIAL_UDIS86_SOURCE "" CACHE PATH "Path to the pinned udis86 checkout")
if(NOT EXISTS "${DENIAL_UDIS86_SOURCE}/CMakeLists.txt")
  message(FATAL_ERROR
    "Pinned udis86 source not found: ${DENIAL_UDIS86_SOURCE}; run tools/denial-pc bootstrap")
endif()
add_subdirectory("${DENIAL_UDIS86_SOURCE}"
                 "${CMAKE_CURRENT_BINARY_DIR}/third-party/udis86")
include_directories("${DENIAL_UDIS86_SOURCE}")

find_library(librt rt)
if("${librt}" MATCHES "librt-NOTFOUND")
  unset(LIBRT)
else()
  set(LIBRT rt)
endif()

pkg_get_variable(WAYLAND_PROTOCOLS_DIR wayland-protocols pkgdatadir)
message(STATUS "Found wayland-protocols at ${WAYLAND_PROTOCOLS_DIR}")
pkg_get_variable(WAYLAND_SCANNER_PKGDATA_DIR wayland-scanner pkgdatadir)
message(
  STATUS "Found wayland-scanner pkgdatadir at ${WAYLAND_SCANNER_PKGDATA_DIR}")

if(CMAKE_BUILD_TYPE MATCHES Debug OR CMAKE_BUILD_TYPE MATCHES DEBUG)
  message(STATUS "Configuring Denial in Debug with CMake")
  add_compile_definitions(HYPRLAND_DEBUG)
else()
  add_compile_options(-O3)
  message(STATUS "Configuring Denial in Release with CMake")
endif()

add_compile_definitions(HYPRLAND_VERSION="${HYPRLAND_VERSION}")

include_directories(
  "${CMAKE_CURRENT_BINARY_DIR}"
  "${CMAKE_CURRENT_BINARY_DIR}/generated"
  "${CMAKE_CURRENT_BINARY_DIR}/protocols"
  "${CMAKE_CURRENT_BINARY_DIR}/generated/render"
  .
  "src/"
  "protocols/")

set(CMAKE_CXX_STANDARD 26)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_compile_options(
  -Wall
  -Wextra
  -Wpedantic
  -Wno-keyword-macro
  -Wno-unused-result
  -Wno-unused-parameter
  -Wno-unused-value
  -Wno-missing-field-initializers
  -Wno-gnu-zero-variadic-macro-arguments
  -Wno-narrowing
  -Wno-pointer-arith
  -Wno-clobbered
  -frtti
  -fmacro-prefix-map=${CMAKE_CURRENT_SOURCE_DIR}/=)

# disable lto as it may break plugins
add_compile_options(-fno-lto)

set(CMAKE_EXECUTABLE_ENABLE_EXPORTS TRUE)
set(CMAKE_EXPORT_COMPILE_COMMANDS TRUE)

message(STATUS "Checking deps...")

find_package(Threads REQUIRED)

set(GLES_VERSION "GLES3")
find_package(OpenGL REQUIRED COMPONENTS ${GLES_VERSION})
find_package(glslang CONFIG REQUIRED)

set(AQUAMARINE_MINIMUM_VERSION 0.9.3)
set(HYPRLANG_MINIMUM_VERSION 0.6.7)
set(HYPRCURSOR_MINIMUM_VERSION 0.1.7)
set(HYPRUTILS_MINIMUM_VERSION 0.13.1)
set(HYPRGRAPHICS_MINIMUM_VERSION 0.5.1)

pkg_check_modules(aquamarine_dep REQUIRED IMPORTED_TARGET aquamarine>=${AQUAMARINE_MINIMUM_VERSION})
pkg_check_modules(hyprlang_dep REQUIRED IMPORTED_TARGET hyprlang>=${HYPRLANG_MINIMUM_VERSION})
pkg_check_modules(hyprcursor_dep REQUIRED IMPORTED_TARGET hyprcursor>=${HYPRCURSOR_MINIMUM_VERSION})
pkg_check_modules(hyprutils_dep REQUIRED IMPORTED_TARGET hyprutils>=${HYPRUTILS_MINIMUM_VERSION})
pkg_check_modules(hyprgraphics_dep REQUIRED IMPORTED_TARGET hyprgraphics>=${HYPRGRAPHICS_MINIMUM_VERSION})

string(REPLACE "." ";" AQ_VERSION_LIST ${aquamarine_dep_VERSION})
list(GET AQ_VERSION_LIST 0 AQ_VERSION_MAJOR)
list(GET AQ_VERSION_LIST 1 AQ_VERSION_MINOR)
list(GET AQ_VERSION_LIST 2 AQ_VERSION_PATCH)

set(AQUAMARINE_VERSION "${aquamarine_dep_VERSION}")
set(AQUAMARINE_VERSION_MAJOR "${AQ_VERSION_MAJOR}")
set(AQUAMARINE_VERSION_MINOR "${AQ_VERSION_MINOR}")
set(AQUAMARINE_VERSION_PATCH "${AQ_VERSION_PATCH}")
set(HYPRLANG_VERSION "${hyprlang_dep_VERSION}")
set(HYPRUTILS_VERSION "${hyprutils_dep_VERSION}")
set(HYPRCURSOR_VERSION "${hyprcursor_dep_VERSION}")
set(HYPRGRAPHICS_VERSION "${hyprgraphics_dep_VERSION}")


find_package(Git QUIET)

# Populate variables with env vars if present
set(GIT_COMMIT_HASH "$ENV{GIT_COMMIT_HASH}")
if(NOT GIT_COMMIT_HASH)
  set(GIT_COMMIT_HASH "unknown")
endif()

set(GIT_BRANCH "$ENV{GIT_BRANCH}")
if(NOT GIT_BRANCH)
  set(GIT_BRANCH "unknown")
endif()

set(GIT_COMMIT_MESSAGE "$ENV{GIT_COMMIT_MESSAGE}")
if(NOT GIT_COMMIT_MESSAGE)
  set(GIT_COMMIT_MESSAGE "unknown")
endif()

set(GIT_COMMIT_DATE "$ENV{GIT_COMMIT_DATE}")
if(NOT GIT_COMMIT_DATE)
  set(GIT_COMMIT_DATE "unknown")
endif()

set(GIT_DIRTY "$ENV{GIT_DIRTY}")
if(NOT GIT_DIRTY)
  set(GIT_DIRTY "unknown")
endif()

set(GIT_TAG "$ENV{GIT_TAG}")
if(NOT GIT_TAG)
  set(GIT_TAG "unknown")
endif()

set(GIT_COMMITS "$ENV{GIT_COMMITS}")
if(NOT GIT_COMMITS)
  set(GIT_COMMITS "0")
endif()

if(Git_FOUND)
  execute_process(
    COMMAND ${GIT_EXECUTABLE} rev-parse --show-toplevel
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    OUTPUT_VARIABLE GIT_TOPLEVEL
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
    RESULT_VARIABLE GIT_TOPLEVEL_RESULT
  )

  if(GIT_TOPLEVEL_RESULT EQUAL 0)
    message(STATUS "Detected git repository root: ${GIT_TOPLEVEL}")

    execute_process(COMMAND ${GIT_EXECUTABLE} rev-parse HEAD
      WORKING_DIRECTORY ${GIT_TOPLEVEL}
      OUTPUT_VARIABLE GIT_COMMIT_HASH OUTPUT_STRIP_TRAILING_WHITESPACE)
    execute_process(COMMAND ${GIT_EXECUTABLE} branch --show-current
      WORKING_DIRECTORY ${GIT_TOPLEVEL}
      OUTPUT_VARIABLE GIT_BRANCH OUTPUT_STRIP_TRAILING_WHITESPACE)
    execute_process(COMMAND ${GIT_EXECUTABLE} show -s --format=%s --no-show-signature
      WORKING_DIRECTORY ${GIT_TOPLEVEL}
      OUTPUT_VARIABLE GIT_COMMIT_MESSAGE OUTPUT_STRIP_TRAILING_WHITESPACE)
    string(REPLACE "\"" "'" GIT_COMMIT_MESSAGE "${GIT_COMMIT_MESSAGE}")
    execute_process(COMMAND ${GIT_EXECUTABLE} show -s --format=%cd --date=local --no-show-signature
      WORKING_DIRECTORY ${GIT_TOPLEVEL}
      OUTPUT_VARIABLE GIT_COMMIT_DATE OUTPUT_STRIP_TRAILING_WHITESPACE)
    execute_process(COMMAND ${GIT_EXECUTABLE} diff-index --quiet HEAD --
      WORKING_DIRECTORY ${GIT_TOPLEVEL}
      RESULT_VARIABLE GIT_DIRTY_RESULT)
    if(NOT GIT_DIRTY_RESULT EQUAL 0)
      set(GIT_DIRTY "dirty")
    else()
      set(GIT_DIRTY "clean")
    endif()
    execute_process(COMMAND ${GIT_EXECUTABLE} describe --tags
      WORKING_DIRECTORY ${GIT_TOPLEVEL}
      OUTPUT_VARIABLE GIT_TAG OUTPUT_STRIP_TRAILING_WHITESPACE)
    execute_process(COMMAND ${GIT_EXECUTABLE} rev-list --count HEAD
      WORKING_DIRECTORY ${GIT_TOPLEVEL}
      OUTPUT_VARIABLE GIT_COMMITS OUTPUT_STRIP_TRAILING_WHITESPACE)
  else()
    message(WARNING
      "No Git repository detected in ${CMAKE_CURRENT_SOURCE_DIR}")
  endif()
endif()

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated/denial")
configure_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/src/version.h.in"
  "${CMAKE_CURRENT_BINARY_DIR}/generated/denial/version.h"
  @ONLY)

set(XKBCOMMON_MINIMUM_VERSION 1.11.0)
set(WAYLAND_SERVER_MINIMUM_VERSION 1.22.91)
set(WAYLAND_SERVER_PROTOCOLS_MINIMUM_VERSION 1.47)
set(LIBINPUT_MINIMUM_VERSION 1.28)

pkg_check_modules(
  deps
  REQUIRED
  IMPORTED_TARGET GLOBAL
  xkbcommon>=${XKBCOMMON_MINIMUM_VERSION}
  uuid
  wayland-server>=${WAYLAND_SERVER_MINIMUM_VERSION}
  wayland-protocols>=${WAYLAND_SERVER_PROTOCOLS_MINIMUM_VERSION}
  cairo
  pango
  pangocairo
  pixman-1
  xcursor
  libdrm
  libinput>=${LIBINPUT_MINIMUM_VERSION}
  gbm
  gio-2.0
  re2
  muparser
  lcms2
)

pkg_search_module(LUA REQUIRED IMPORTED_TARGET GLOBAL lua55 lua5.5 lua-55 lua-5.5 lua>=5.5 lua<5.6)

find_package(hyprwayland-scanner 0.3.10 REQUIRED)

file(GLOB_RECURSE SRCFILES CONFIGURE_DEPENDS "src/*.cpp")

add_library(denial_compositor STATIC ${SRCFILES})

set(DENIAL_ENGINE_LIBRARY "" CACHE FILEPATH
    "Flutter engine library matching the Denial target architecture")
if(NOT EXISTS "${DENIAL_ENGINE_LIBRARY}")
  message(FATAL_ERROR
    "Denial Flutter engine not found: ${DENIAL_ENGINE_LIBRARY}; run tools/denial-pc bootstrap")
endif()

add_subdirectory(deniald/flutter denial-flutter)

add_executable(
  deniald
  deniald/AuthenticationController.cpp
  deniald/AuthenticationProtocol.cpp
  deniald/AudioController.cpp
  deniald/BrightnessController.cpp
  deniald/NotificationServer.cpp
  deniald/main.cpp
  deniald/Runtime.cpp
  deniald/RuntimeAuthentication.cpp
  deniald/RuntimeBridge.cpp
  deniald/RuntimeControls.cpp
  deniald/RuntimeFlutter.cpp
  deniald/RuntimeInput.cpp
  deniald/RuntimeOutput.cpp
  deniald/RuntimeShortcuts.cpp
  deniald/RuntimeSnapshots.cpp
  deniald/RuntimeSurfaces.cpp
  deniald/RuntimeWindows.cpp
  deniald/Wire.cpp)

find_path(denial_pam_INCLUDE_DIR security/pam_appl.h)
find_library(denial_pam_LIBRARY pam)
if(denial_pam_INCLUDE_DIR AND denial_pam_LIBRARY)
  target_compile_definitions(deniald PRIVATE DENIAL_WITH_PAM=1)
  target_include_directories(deniald PRIVATE ${denial_pam_INCLUDE_DIR})
  target_link_libraries(deniald ${denial_pam_LIBRARY})
else()
  message(WARNING "Denial native authentication disabled: PAM development files not found")
endif()

pkg_check_modules(denial_pulse IMPORTED_TARGET libpulse)
if(denial_pulse_FOUND)
  target_compile_definitions(deniald PRIVATE DENIAL_WITH_PULSE=1)
  target_link_libraries(deniald PkgConfig::denial_pulse)
else()
  message(WARNING "Denial native audio disabled: libpulse development files not found")
endif()

find_path(denial_ddcutil_INCLUDE_DIR ddcutil_c_api.h)
find_library(denial_ddcutil_LIBRARY ddcutil)
if(denial_ddcutil_INCLUDE_DIR AND denial_ddcutil_LIBRARY)
  target_compile_definitions(deniald PRIVATE DENIAL_WITH_DDCUTIL=1)
  target_include_directories(deniald PRIVATE ${denial_ddcutil_INCLUDE_DIR})
  target_link_libraries(deniald ${denial_ddcutil_LIBRARY})
else()
  message(WARNING "Denial native monitor brightness disabled: libddcutil development files not found")
endif()

target_include_directories(denial_compositor PUBLIC ${deps_INCLUDE_DIRS} ${LUA_INCLUDE_DIRS})
target_include_directories(
  deniald
  PUBLIC ${deps_INCLUDE_DIRS} ${LUA_INCLUDE_DIRS}
  PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/flatbuffers/include")

if(DENIAL_BUILD_TESTS)
  add_executable(
    denial_wire_protocol_test
    "${CMAKE_CURRENT_SOURCE_DIR}/../protocol/tests/wire_cpp_test.cpp"
    deniald/Wire.cpp)
  target_include_directories(
    denial_wire_protocol_test
    PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/flatbuffers/include")
  add_test(NAME denial_wire_protocol_test COMMAND denial_wire_protocol_test)
  set_tests_properties(
    denial_wire_protocol_test
    PROPERTIES WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/..")

  add_executable(
    denial_runtime_output_state_test
    deniald/tests/RuntimeOutputStateTest.cpp)
  add_test(
    NAME denial_runtime_output_state_test
    COMMAND denial_runtime_output_state_test)

  add_executable(
    denial_closing_texture_lease_test
    deniald/tests/ClosingTextureLeaseTest.cpp)
  add_test(
    NAME denial_closing_texture_lease_test
    COMMAND denial_closing_texture_lease_test)

  add_executable(
    denial_resize_texture_handoff_test
    deniald/tests/ResizeTextureHandoffTest.cpp)
  add_test(
    NAME denial_resize_texture_handoff_test
    COMMAND denial_resize_texture_handoff_test)

  add_executable(
    denial_window_decoration_policy_test
    deniald/tests/WindowDecorationPolicyTest.cpp)
  add_test(
    NAME denial_window_decoration_policy_test
    COMMAND denial_window_decoration_policy_test)
endif()

option(DENIAL_ENABLE_DIAGNOSTICS "Compile Denial render-path diagnostics" OFF)
if(DENIAL_ENABLE_DIAGNOSTICS)
  target_compile_definitions(deniald PRIVATE DENIAL_ENABLE_DIAGNOSTICS=1)
endif()

get_filename_component(DENIAL_ENGINE_LIBRARY_DIR "${DENIAL_ENGINE_LIBRARY}" DIRECTORY)
target_link_libraries(
  deniald
  denial_flutter_embedder
  "${DENIAL_ENGINE_LIBRARY}")
target_link_options(deniald PRIVATE "-Wl,-rpath-link,${DENIAL_ENGINE_LIBRARY_DIR}")

option(DENIAL_ENABLE_ASAN "Build the compositor core with AddressSanitizer" OFF)
if(CMAKE_BUILD_TYPE MATCHES Debug OR CMAKE_BUILD_TYPE MATCHES DEBUG)
  message(STATUS "Setting debug flags")

  if(DENIAL_ENABLE_ASAN)
    message(STATUS "Enabling ASan")

    target_link_libraries(denial_compositor PUBLIC asan)
    target_compile_options(denial_compositor PUBLIC -fsanitize=address)
  endif()

  add_compile_options(-fno-pie -fno-builtin -fno-omit-frame-pointer)
  add_link_options(-no-pie -fno-builtin)
endif()

check_include_file("execinfo.h" EXECINFOH)
if(EXECINFOH)
  message(STATUS "Configuration supports execinfo")
  add_compile_definitions(HAS_EXECINFO)
endif()

include(CheckLibraryExists)
check_library_exists(execinfo backtrace "" HAVE_LIBEXECINFO)
if(HAVE_LIBEXECINFO)
  target_link_libraries(denial_compositor PUBLIC execinfo)
endif()

check_include_file("sys/timerfd.h" HAS_TIMERFD)
pkg_check_modules(epoll IMPORTED_TARGET epoll-shim)
if(NOT HAS_TIMERFD AND epoll_FOUND)
  target_link_libraries(denial_compositor PUBLIC PkgConfig::epoll)
endif()

check_include_file("sys/inotify.h" HAS_INOTIFY)
pkg_check_modules(inotify IMPORTED_TARGET libinotify)
if(NOT HAS_INOTIFY AND inotify_FOUND)
  target_link_libraries(denial_compositor PUBLIC PkgConfig::inotify)
endif()

if(NO_XWAYLAND)
  message(STATUS "Using the NO_XWAYLAND flag, disabling XWayland!")
  add_compile_definitions(NO_XWAYLAND)
else()
  message(STATUS "XWAYLAND Enabled (NO_XWAYLAND not defined) checking deps...")
  set(XWAYLAND_DEPENDENCIES
    xcb
    xcb-render
    xcb-xfixes
    xcb-icccm
    xcb-composite
    xcb-res
    xcb-errors)

  pkg_check_modules(
    xdeps
    REQUIRED
    IMPORTED_TARGET
    ${XWAYLAND_DEPENDENCIES})

  target_link_libraries(denial_compositor PUBLIC PkgConfig::xdeps)
endif()

if(NO_SYSTEMD)
  message(STATUS "SYSTEMD support is disabled...")
else()
  message(STATUS "SYSTEMD support is requested (NO_SYSTEMD not defined)...")
  add_compile_definitions(USES_SYSTEMD)
endif()

if(CMAKE_DISABLE_PRECOMPILE_HEADERS)
  message(STATUS "Not using precompiled headers")
else()
  message(STATUS "Setting precompiled headers")
  target_precompile_headers(denial_compositor PRIVATE
                            $<$<COMPILE_LANGUAGE:CXX>:src/pch/pch.hpp>)
endif()

message(STATUS "Setting link libraries")

target_link_libraries(
  denial_compositor
  PUBLIC
  PkgConfig::aquamarine_dep
  PkgConfig::hyprlang_dep
  PkgConfig::hyprutils_dep
  PkgConfig::hyprcursor_dep
  PkgConfig::hyprgraphics_dep
  PkgConfig::deps
  PkgConfig::LUA
)

target_link_libraries(
  deniald
  ${LIBRT}
  denial_compositor)
target_link_libraries(denial_compositor PUBLIC libudis86)

set(DENIAL_PROTOCOL_OUTPUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/protocols")
file(MAKE_DIRECTORY "${DENIAL_PROTOCOL_OUTPUT_DIR}")

function(protocolnew protoPath protoName external)
  if(external)
    set(path ${protoPath})
  else()
    set(path ${WAYLAND_PROTOCOLS_DIR}/${protoPath})
  endif()
  add_custom_command(
    OUTPUT ${DENIAL_PROTOCOL_OUTPUT_DIR}/${protoName}.cpp
           ${DENIAL_PROTOCOL_OUTPUT_DIR}/${protoName}.hpp
    COMMAND hyprwayland-scanner ${path}/${protoName}.xml
            ${DENIAL_PROTOCOL_OUTPUT_DIR}/
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
  target_sources(denial_compositor PRIVATE
                 ${DENIAL_PROTOCOL_OUTPUT_DIR}/${protoName}.cpp
                 ${DENIAL_PROTOCOL_OUTPUT_DIR}/${protoName}.hpp)
endfunction()
function(protocolWayland)
  add_custom_command(
    OUTPUT ${DENIAL_PROTOCOL_OUTPUT_DIR}/wayland.cpp
           ${DENIAL_PROTOCOL_OUTPUT_DIR}/wayland.hpp
    COMMAND
      hyprwayland-scanner --wayland-enums
      ${WAYLAND_SCANNER_PKGDATA_DIR}/wayland.xml ${DENIAL_PROTOCOL_OUTPUT_DIR}/
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
  target_sources(denial_compositor PRIVATE
                 ${DENIAL_PROTOCOL_OUTPUT_DIR}/wayland.cpp
                 ${DENIAL_PROTOCOL_OUTPUT_DIR}/wayland.hpp)
endfunction()

if(TARGET OpenGL::GL)
  target_link_libraries(denial_compositor PUBLIC OpenGL::EGL OpenGL::GL glslang::glslang glslang-default-resource-limits glslang::SPIRV Threads::Threads)
else()
  target_link_libraries(denial_compositor PUBLIC OpenGL::EGL OpenGL::GLES3 glslang::glslang glslang-default-resource-limits glslang::SPIRV Threads::Threads)
endif()

set(DENIAL_HYPRLAND_PROTOCOLS_SOURCE "" CACHE PATH
    "Path to the pinned hyprland-protocols checkout")
if(NOT EXISTS "${DENIAL_HYPRLAND_PROTOCOLS_SOURCE}/protocols/hyprland-global-shortcuts-v1.xml")
  message(FATAL_ERROR
    "Pinned hyprland-protocols source not found: ${DENIAL_HYPRLAND_PROTOCOLS_SOURCE}; run tools/denial-pc bootstrap")
endif()
set(HYPRLAND_PROTOCOLS "${DENIAL_HYPRLAND_PROTOCOLS_SOURCE}")

protocolnew("${HYPRLAND_PROTOCOLS}/protocols" "hyprland-global-shortcuts-v1"
            true)
protocolnew("unstable/text-input" "text-input-unstable-v1" false)
protocolnew("${HYPRLAND_PROTOCOLS}/protocols" "hyprland-toplevel-export-v1"
            true)
protocolnew("protocols" "wlr-screencopy-unstable-v1" true)
protocolnew("protocols" "wlr-gamma-control-unstable-v1" true)
protocolnew("protocols" "wlr-foreign-toplevel-management-unstable-v1" true)
protocolnew("protocols" "wlr-output-power-management-unstable-v1" true)
protocolnew("protocols" "virtual-keyboard-unstable-v1" true)
protocolnew("protocols" "wlr-virtual-pointer-unstable-v1" true)
protocolnew("protocols" "input-method-unstable-v2" true)
protocolnew("protocols" "wlr-output-management-unstable-v1" true)
protocolnew("protocols" "kde-server-decoration" true)
protocolnew("protocols" "wlr-data-control-unstable-v1" true)
protocolnew("${HYPRLAND_PROTOCOLS}/protocols" "hyprland-focus-grab-v1" true)
protocolnew("protocols" "wlr-layer-shell-unstable-v1" true)
protocolnew("protocols" "wayland-drm" true)
protocolnew("${HYPRLAND_PROTOCOLS}/protocols" "hyprland-ctm-control-v1" true)
protocolnew("${HYPRLAND_PROTOCOLS}/protocols" "hyprland-surface-v1" true)
protocolnew("${HYPRLAND_PROTOCOLS}/protocols" "hyprland-lock-notify-v1" true)
protocolnew("${HYPRLAND_PROTOCOLS}/protocols" "hyprland-toplevel-mapping-v1"
            true)

protocolnew("staging/tearing-control" "tearing-control-v1" false)
protocolnew("staging/fractional-scale" "fractional-scale-v1" false)
protocolnew("unstable/xdg-output" "xdg-output-unstable-v1" false)
protocolnew("staging/cursor-shape" "cursor-shape-v1" false)
protocolnew("unstable/idle-inhibit" "idle-inhibit-unstable-v1" false)
protocolnew("unstable/relative-pointer" "relative-pointer-unstable-v1" false)
protocolnew("unstable/xdg-decoration" "xdg-decoration-unstable-v1" false)
protocolnew("staging/alpha-modifier" "alpha-modifier-v1" false)
protocolnew("staging/ext-foreign-toplevel-list" "ext-foreign-toplevel-list-v1"
            false)
protocolnew("unstable/pointer-gestures" "pointer-gestures-unstable-v1" false)
protocolnew("unstable/keyboard-shortcuts-inhibit"
            "keyboard-shortcuts-inhibit-unstable-v1" false)
protocolnew("unstable/text-input" "text-input-unstable-v3" false)
protocolnew("unstable/pointer-constraints" "pointer-constraints-unstable-v1"
            false)
protocolnew("unstable/xdg-foreign" "xdg-foreign-unstable-v2" false)
protocolnew("staging/xdg-activation" "xdg-activation-v1" false)
protocolnew("staging/ext-idle-notify" "ext-idle-notify-v1" false)
protocolnew("staging/ext-session-lock" "ext-session-lock-v1" false)
protocolnew("stable/tablet" "tablet-v2" false)
protocolnew("stable/presentation-time" "presentation-time" false)
protocolnew("stable/xdg-shell" "xdg-shell" false)
protocolnew("unstable/primary-selection" "primary-selection-unstable-v1" false)
protocolnew("staging/xwayland-shell" "xwayland-shell-v1" false)
protocolnew("stable/viewporter" "viewporter" false)
protocolnew("stable/linux-dmabuf" "linux-dmabuf-v1" false)
protocolnew("staging/drm-lease" "drm-lease-v1" false)
protocolnew("staging/linux-drm-syncobj" "linux-drm-syncobj-v1" false)
protocolnew("staging/xdg-dialog" "xdg-dialog-v1" false)
protocolnew("staging/single-pixel-buffer" "single-pixel-buffer-v1" false)
protocolnew("staging/security-context" "security-context-v1" false)
protocolnew("staging/content-type" "content-type-v1" false)
protocolnew("staging/color-management" "color-management-v1" false)
protocolnew("staging/xdg-toplevel-tag" "xdg-toplevel-tag-v1" false)
protocolnew("staging/xdg-system-bell" "xdg-system-bell-v1" false)
protocolnew("staging/ext-workspace" "ext-workspace-v1" false)
protocolnew("staging/ext-data-control" "ext-data-control-v1" false)
protocolnew("staging/pointer-warp" "pointer-warp-v1" false)
protocolnew("staging/fifo" "fifo-v1" false)
protocolnew("staging/commit-timing" "commit-timing-v1" false)
protocolnew("staging/ext-image-capture-source" "ext-image-capture-source-v1" false)
protocolnew("staging/ext-image-copy-capture" "ext-image-copy-capture-v1" false)

protocolwayland()

set(DENIAL_DATAROOT "${CMAKE_CURRENT_BINARY_DIR}/share")
file(MAKE_DIRECTORY "${DENIAL_DATAROOT}/hypr")
foreach(asset lockdead.png lockdead2.png)
  configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/assets/${asset}"
    "${DENIAL_DATAROOT}/hypr/${asset}"
    COPYONLY)
endforeach()
add_compile_definitions(DATAROOTDIR="${DENIAL_DATAROOT}")

if(DENIAL_BUILD_TESTS)
  message(STATUS "Building Denial core tests")
  find_package(GTest CONFIG REQUIRED)
  include(GoogleTest)
  file(GLOB_RECURSE TESTFILES "tests/*.cpp")
  add_executable(denial_core_tests ${TESTFILES})
  target_include_directories(
    denial_core_tests
    PRIVATE "./src" "./src/include" "./protocols"
            "${CMAKE_CURRENT_BINARY_DIR}")

  target_link_libraries(denial_core_tests denial_compositor GTest::gtest_main)

  add_executable(
    denial_notification_server_test
    deniald/tests/NotificationServerTest.cpp
    deniald/NotificationServer.cpp)
  target_include_directories(
    denial_notification_server_test
    PRIVATE "./src" "./src/include" "./protocols"
            "${CMAKE_CURRENT_BINARY_DIR}")
  target_link_libraries(
    denial_notification_server_test
    denial_compositor
    GTest::gtest_main)

  add_executable(
    denial_authentication_test
    deniald/tests/AuthenticationControllerTest.cpp
    deniald/AuthenticationController.cpp
    deniald/AuthenticationProtocol.cpp)
  target_link_libraries(denial_authentication_test GTest::gtest_main)

  gtest_discover_tests(denial_core_tests)
  gtest_discover_tests(denial_notification_server_test)
  gtest_discover_tests(denial_authentication_test)
  add_custom_target(
    check
    COMMAND ${CMAKE_CTEST_COMMAND} --output-on-failure
    DEPENDS denial_core_tests denial_notification_server_test
            denial_authentication_test
            denial_wire_protocol_test
            denial_closing_texture_lease_test
            denial_resize_texture_handoff_test
            denial_runtime_output_state_test
            denial_window_decoration_policy_test
            denial_text_input_model_test denial_json_channel_test
            denial_native_message_handler_test)
endif()
