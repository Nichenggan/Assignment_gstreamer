cmake_minimum_required(VERSION 3.16)
project(monitor_sender C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GST REQUIRED IMPORTED_TARGET gstreamer-1.0 glib-2.0)

add_executable(monitor_sender src/monitor_sender.c)
target_link_libraries(monitor_sender PRIVATE PkgConfig::GST)

if(MSVC)
    target_compile_options(monitor_sender PRIVATE /W3)
    target_compile_definitions(monitor_sender PRIVATE _CRT_SECURE_NO_WARNINGS)
else()
    target_compile_options(monitor_sender PRIVATE -Wall -Wextra)
endif()

# put the executable directly in build/ (also with multi-config generators
# like Visual Studio), so it is always ./build/monitor_sender
set_target_properties(monitor_sender PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    RUNTIME_OUTPUT_DIRECTORY_DEBUG ${CMAKE_BINARY_DIR}
    RUNTIME_OUTPUT_DIRECTORY_RELEASE ${CMAKE_BINARY_DIR})
