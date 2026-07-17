cmake_minimum_required(VERSION 3.15)
project(denial_flutter_bundle LANGUAGES NONE)

# The Sony tooling produces these pinned Flutter artifacts before invoking
# CMake. Denial embeds Flutter itself, so this platform project packages only
# the engine, ICU data, and Dart AOT library consumed by deniald.
set(EPHEMERAL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral")
include("${EPHEMERAL_DIR}/generated_config.cmake")

set(FLUTTER_ENGINE "${EPHEMERAL_DIR}/libflutter_engine.so")
set(FLUTTER_ICU_DATA "${EPHEMERAL_DIR}/icudtl.dat")
set(FLUTTER_AOT_LIBRARY "${EPHEMERAL_DIR}/libapp.so")

add_custom_target(
  denial_flutter_bundle ALL
  DEPENDS "${FLUTTER_ENGINE}" "${FLUTTER_ICU_DATA}"
          "${FLUTTER_AOT_LIBRARY}")

set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "" FORCE)
endif()

install(CODE "file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}\")")
install(FILES "${FLUTTER_ICU_DATA}" DESTINATION data)
install(FILES "${FLUTTER_ENGINE}" "${FLUTTER_AOT_LIBRARY}" DESTINATION lib)
