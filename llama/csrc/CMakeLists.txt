cmake_minimum_required(VERSION 3.14)
project(llamacpp_nmt VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ---- Build options ----------------------------------------------------------

option(LLAMACPP_BUILD_SHARED "Build shared library" ON)

# ---- llama.cpp --------------------------------------------------------------
# The original llama.cpp repo is at ../llama.cpp.
# We add it as a subdirectory and link against the static "llama" target.

set(LLAMA_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../llama.cpp")

if(NOT EXISTS "${LLAMA_CPP_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "llama.cpp not found at ${LLAMA_CPP_DIR}")
endif()

if(APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "Android")
    set(GGML_METAL ON CACHE BOOL "Enable Metal backend" FORCE)
    set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "Embed Metal library" FORCE)
else()
    set(GGML_METAL OFF CACHE BOOL "Disable Metal backend" FORCE)
    set(GGML_METAL_EMBED_LIBRARY OFF CACHE BOOL "Embed Metal library" FORCE)
endif()
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build static llama" FORCE)

add_subdirectory("${LLAMA_CPP_DIR}" _llama_build)

# iOS: Disable ARC for llama.cpp Metal Objective-C files.
# llama.cpp's Metal backend uses manual reference counting (release/retain),
# but the iOS toolchain enables ARC globally. This causes compilation errors
# like "'release' is unavailable" and missing bridged casts.
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  if(TARGET ggml-metal)
    target_compile_options(ggml-metal PRIVATE "-fno-objc-arc")
    message(STATUS "Disabled ARC for ggml-metal target (iOS)")
  endif()
endif()

# ---- nlohmann/json ----------------------------------------------------------

find_path(NLOHMANN_JSON_INCLUDE_DIR
    NAMES nlohmann/json.hpp
    HINTS /opt/homebrew/include /usr/local/include
          ${CMAKE_CURRENT_SOURCE_DIR}/../../sherpa-onnx/build-android-arm64-v8a/_deps/json-src/include
    NO_CMAKE_FIND_ROOT_PATH)

if(NLOHMANN_JSON_INCLUDE_DIR)
    message(STATUS "Found nlohmann/json at ${NLOHMANN_JSON_INCLUDE_DIR}")
else()
    message(FATAL_ERROR "nlohmann/json.hpp not found. Install: brew install nlohmann-json")
endif()

# ---- Library sources --------------------------------------------------------

set(LLAMACPP_SOURCES
    llamacpp_translator.cpp
    llamacpp_tokenizer.cpp
    llamacpp_ffi.cpp)

set(LLAMACPP_HEADERS
    llamacpp_config.h
    llamacpp_translator.h
    llamacpp_tokenizer.h
    llamacpp_ffi.h
    llamacpp_bridge.h)

# ---- Build targets ----------------------------------------------------------

if(LLAMACPP_BUILD_SHARED)
    add_library(llamacpp_nmt SHARED ${LLAMACPP_SOURCES} ${LLAMACPP_HEADERS})
else()
    add_library(llamacpp_nmt STATIC ${LLAMACPP_SOURCES} ${LLAMACPP_HEADERS})
endif()

target_include_directories(llamacpp_nmt
    PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}
    PRIVATE ${NLOHMANN_JSON_INCLUDE_DIR}
    PRIVATE "${LLAMA_CPP_DIR}/include"
    PRIVATE "${LLAMA_CPP_DIR}/src")

target_link_libraries(llamacpp_nmt PRIVATE llama)

# macOS: set install name so the dylib can be bundled with an app.
if(APPLE AND LLAMACPP_BUILD_SHARED)
    set_target_properties(llamacpp_nmt PROPERTIES
        INSTALL_RPATH "@executable_path/../Frameworks"
        BUILD_WITH_INSTALL_RPATH ON
        MACOSX_RPATH ON)
endif()

# ---- Test executable ---------------------------------------------------------
option(LLAMACPP_BUILD_TEST "Build inference test executable" ON)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(LLAMACPP_BUILD_TEST OFF)
endif()

if(LLAMACPP_BUILD_TEST)
    add_executable(test_llamacpp_inference test_llamacpp_inference.cpp)
    target_include_directories(test_llamacpp_inference
        PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}
        PRIVATE ${NLOHMANN_JSON_INCLUDE_DIR}
        PRIVATE "${LLAMA_CPP_DIR}/include"
        PRIVATE "${LLAMA_CPP_DIR}/src")
    target_link_libraries(test_llamacpp_inference PRIVATE llamacpp_nmt)
endif()

# ---- Installation -----------------------------------------------------------

install(TARGETS llamacpp_nmt
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib)
install(FILES ${LLAMACPP_HEADERS} DESTINATION include/llamacpp)

# ---- Platform-specific notes ------------------------------------------------
# To build for macOS:
#   cmake -B build -DLLAMACPP_BUILD_SHARED=ON
#   cmake --build build
#
# To build for iOS:
#   cmake -B build-ios \
#       -DCMAKE_SYSTEM_NAME=iOS \
#       -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
#       -DCMAKE_OSX_ARCHITECTURES=arm64 \
#       -DLLAMACPP_BUILD_SHARED=OFF \
#       -DGGML_OPENMP=OFF \
#       -DGGML_METAL=ON \
#       -DGGML_METAL_EMBED_LIBRARY=ON
#   cmake --build build-ios
