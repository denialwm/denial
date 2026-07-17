set(DENIAL_FLUTTER_SOURCES
  denial_flutter_engine.cc
  denial_flutter_view.cc
  denial_json_channel.cc
  denial_native_message_handler.cc
  external_texture_pixelbuffer.cc
  external_texture_egl_image.cc
  denial_flutter_texture_registrar.cc
  keyboard_glfw_util.cc
  key_event_plugin.cc
  platform_plugin.cc
  text_input_plugin.cc
  denial_c_api.cc
  text_input_model.cc)

# The embedder is an internal object target: its objects are linked directly
# into deniald and no intermediate project-owned library is produced or loaded.
add_library(denial_flutter_embedder OBJECT ${DENIAL_FLUTTER_SOURCES})
set_target_properties(
  denial_flutter_embedder
  PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    CXX_EXTENSIONS ON)
target_compile_options(
  denial_flutter_embedder
  PRIVATE -Wno-c++20-extensions)

target_compile_definitions(
  denial_flutter_embedder
  PRIVATE
    EGL_NO_X11
    FLUTTER_RELEASE
    RAPIDJSON_HAS_CXX11_NOEXCEPT
    RAPIDJSON_HAS_CXX11_RANGE_FOR
    RAPIDJSON_HAS_CXX11_RVALUE_REFS
    RAPIDJSON_HAS_CXX11_TYPETRAITS
    RAPIDJSON_HAS_STDSTRING)

target_include_directories(
  denial_flutter_embedder
  PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/.."
    "${PROJECT_SOURCE_DIR}/../third_party/rapidjson/include")

target_link_libraries(
  denial_flutter_embedder
  PUBLIC
    OpenGL::EGL
    OpenGL::GLES3
    PkgConfig::deps)

if(DENIAL_BUILD_TESTS)
  add_executable(
    denial_text_input_model_test
    tests/text_input_model_test.cc
    text_input_model.cc)
  set_target_properties(
    denial_text_input_model_test
    PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS ON)
  target_include_directories(
    denial_text_input_model_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/..")
  add_test(NAME denial_text_input_model_test COMMAND denial_text_input_model_test)

  add_executable(
    denial_json_channel_test
    tests/json_channel_test.cc
    denial_json_channel.cc)
  set_target_properties(
    denial_json_channel_test
    PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS ON)
  target_include_directories(
    denial_json_channel_test
    PRIVATE
      "${CMAKE_CURRENT_SOURCE_DIR}/.."
      "${PROJECT_SOURCE_DIR}/../third_party/rapidjson/include")
  target_compile_definitions(
    denial_json_channel_test PRIVATE RAPIDJSON_HAS_STDSTRING)
  add_test(NAME denial_json_channel_test COMMAND denial_json_channel_test)

  add_executable(
    denial_native_message_handler_test
    tests/native_message_handler_test.cc
    denial_native_message_handler.cc)
  set_target_properties(
    denial_native_message_handler_test
    PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS ON)
  target_include_directories(
    denial_native_message_handler_test
    PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/..")
  add_test(
    NAME denial_native_message_handler_test
    COMMAND denial_native_message_handler_test)
endif()
