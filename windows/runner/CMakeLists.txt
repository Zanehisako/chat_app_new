cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "windows_push_channel.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

option(CHAT_APP_ENABLE_WNS "Enable Windows App SDK WNS registration" OFF)
if(DEFINED ENV{CHAT_APP_ENABLE_WNS} AND "$ENV{CHAT_APP_ENABLE_WNS}" STREQUAL "ON")
  set(CHAT_APP_ENABLE_WNS ON CACHE BOOL "Enable Windows App SDK WNS registration" FORCE)
endif()
set(CHAT_APP_WINDOWS_APP_SDK_ROOT "$ENV{CHAT_APP_WINDOWS_APP_SDK_ROOT}" CACHE PATH
  "Root of the Microsoft.WindowsAppSDK NuGet package")

if(CHAT_APP_ENABLE_WNS)
  find_path(CHAT_APP_WINDOWS_APP_SDK_INCLUDE_DIR
    NAMES winrt/Microsoft.Windows.PushNotifications.h
    PATHS
      "${CHAT_APP_WINDOWS_APP_SDK_ROOT}/include"
      "${CHAT_APP_WINDOWS_APP_SDK_ROOT}/build/native/include")
  if(NOT CHAT_APP_WINDOWS_APP_SDK_INCLUDE_DIR)
    message(FATAL_ERROR
      "CHAT_APP_ENABLE_WNS requires CHAT_APP_WINDOWS_APP_SDK_ROOT with WinAppSDK headers")
  endif()
  if(NOT EXISTS "${CHAT_APP_WINDOWS_APP_SDK_INCLUDE_DIR}/winrt/Microsoft.Windows.AppNotifications.h")
    message(FATAL_ERROR
      "CHAT_APP_ENABLE_WNS requires Microsoft.Windows.AppNotifications headers")
  endif()
  find_library(CHAT_APP_WINDOWS_APP_SDK_BOOTSTRAP_LIB
    NAMES Microsoft.WindowsAppRuntime.Bootstrap
    PATHS
      "${CHAT_APP_WINDOWS_APP_SDK_ROOT}/lib/native/x64"
      "${CHAT_APP_WINDOWS_APP_SDK_ROOT}/runtimes/win-x64/native"
      "${CHAT_APP_WINDOWS_APP_SDK_ROOT}/build/native/x64")
  if(NOT CHAT_APP_WINDOWS_APP_SDK_BOOTSTRAP_LIB)
    message(FATAL_ERROR
      "CHAT_APP_ENABLE_WNS requires Microsoft.WindowsAppRuntime.Bootstrap.lib")
  endif()
  target_include_directories(${BINARY_NAME} PRIVATE
    "${CHAT_APP_WINDOWS_APP_SDK_INCLUDE_DIR}")
  target_link_libraries(${BINARY_NAME} PRIVATE
    "${CHAT_APP_WINDOWS_APP_SDK_BOOTSTRAP_LIB}")
  target_compile_definitions(${BINARY_NAME} PRIVATE CHAT_APP_ENABLE_WNS)
endif()

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
