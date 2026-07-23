cmake_minimum_required(VERSION 3.16)
project(second_display_harmony LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(second_display_protocol STATIC
    protocol/Json.cpp
    protocol/ControlMessage.cpp
    protocol/VideoFrame.cpp
    transport/FrameParser.cpp
    decoder/DecoderFrameQueue.cpp
)
target_include_directories(second_display_protocol PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_options(second_display_protocol PRIVATE -Wall -Wextra -Wpedantic)
if(NOT CMAKE_SYSTEM_NAME STREQUAL "OHOS")
    target_compile_options(second_display_protocol PRIVATE -Werror)
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "OHOS")
    add_library(entry SHARED
        napi_init.cpp
        decoder/H264SurfaceDecoder.cpp
    )
    if(CMAKE_BUILD_TYPE STREQUAL "Debug")
        file(READ
            "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../shared/test-vectors/media/h264_1920x1200_60.h264"
            H264_TEST_VECTOR_HEX HEX)
        string(REGEX REPLACE "([0-9a-fA-F][0-9a-fA-F])" "0x\\1," H264_TEST_VECTOR_BYTES
            "${H264_TEST_VECTOR_HEX}")
        file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated")
        configure_file(
            decoder/TestVectorData.hpp.in
            "${CMAKE_CURRENT_BINARY_DIR}/generated/TestVectorData.hpp"
            @ONLY)
        target_compile_definitions(entry PRIVATE SECOND_DISPLAY_ENABLE_DIAGNOSTICS=1)
    endif()
    target_include_directories(entry PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/generated")
    target_link_libraries(entry PRIVATE
        second_display_protocol
        libace_napi.z.so
        libace_ndk.z.so
        libnative_media_codecbase.so
        libnative_media_core.so
        libnative_media_vdec.so
        libnative_window.so
    )
endif()

option(BUILD_PROTOCOL_TESTS "Build host protocol tests" OFF)
if(BUILD_PROTOCOL_TESTS)
    enable_testing()
    add_executable(protocol_tests tests/ProtocolTests.cpp)
    target_link_libraries(protocol_tests PRIVATE second_display_protocol)
    target_compile_options(protocol_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
    add_test(NAME protocol_tests COMMAND protocol_tests ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../shared/test-vectors)
endif()
