cmake_minimum_required(VERSION 3.14)
project(voice_engine VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ---- Build options ----------------------------------------------------------
option(VOICE_ENGINE_BUILD_SHARED "Build shared library" ON)
option(VOICE_ENGINE_BUILD_TEST "Build test executable" OFF)

# ---- nlohmann/json (header-only) -------------------------------------------
find_path(NLOHMANN_JSON_INCLUDE_DIR
    NAMES nlohmann/json.hpp
    HINTS ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/nlohmann
          ${CMAKE_SOURCE_DIR}/../third_party/nlohmann
          /usr/local/include
          /opt/homebrew/include)
if(NLOHMANN_JSON_INCLUDE_DIR)
    message(STATUS "Found nlohmann/json at ${NLOHMANN_JSON_INCLUDE_DIR}")
else()
    message(FATAL_ERROR
        "nlohmann/json.hpp not found. Install it: brew install nlohmann-json")
endif()

# ---- sherpa-onnx C API (prebuilt dynamic library) --------------------------
# voice_engine links the same libsherpa-onnx-c-api.dylib that the sherpa_onnx
# Flutter plugin bundles into the app. We do NOT rebuild sherpa-onnx here.
set(SHERPA_SEARCH_PATHS
    ${CMAKE_CURRENT_SOURCE_DIR}/../sherpa-onnx
    ${CMAKE_CURRENT_SOURCE_DIR}/../../sherpa-onnx)

# Resolve the sherpa-onnx root (the submodule checkout that contains
# sherpa-onnx/c-api/c-api.h and build/install/lib).
set(SHERPA_ROOT "")
foreach(_candidate ${SHERPA_SEARCH_PATHS})
    if(EXISTS "${_candidate}/sherpa-onnx/c-api/c-api.h")
        set(SHERPA_ROOT "${_candidate}")
        break()
    endif()
endforeach()
if(NOT SHERPA_ROOT)
    # Fall back to a sibling directory resolved from the cmake source dir.
    set(SHERPA_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../sherpa-onnx")
endif()

# Locate the prebuilt dylib (prefer the install tree, then the build tree).
find_library(SHERPA_ONNX_C_API_LIB
    NAMES sherpa-onnx-c-api
    HINTS ${SHERPA_ROOT}/build/install/lib
          ${SHERPA_ROOT}/build/lib
          ${SHERPA_ROOT}/build-swift-macos/install/lib
    PATH_SUFFIXES lib)
if(NOT SHERPA_ONNX_C_API_LIB)
    message(FATAL_ERROR
        "libsherpa-onnx-c-api.dylib not found. Build sherpa-onnx first:\n"
        "  cd sherpa-onnx && mkdir -p build && cd build\n"
        "  cmake .. -DBUILD_SHARED_LIBS=ON && cmake --build .\n"
        "  cmake --install . --config Release")
endif()

# Resolve the include directory for c-api.h.
find_path(SHERPA_ONNX_INCLUDE_DIR
    NAMES c-api.h
    HINTS ${SHERPA_ROOT}/sherpa-onnx/c-api
          ${SHERPA_ROOT}/build/install/include/sherpa-onnx/c-api
    PATH_SUFFIXES sherpa-onnx/c-api)
if(NOT SHERPA_ONNX_INCLUDE_DIR)
    message(FATAL_ERROR "sherpa-onnx c-api.h not found under ${SHERPA_ROOT}")
endif()

message(STATUS "sherpa-onnx c-api lib:    ${SHERPA_ONNX_C_API_LIB}")
message(STATUS "sherpa-onnx c-api include: ${SHERPA_ONNX_INCLUDE_DIR}")

add_library(sherpa_onnx_c_api SHARED IMPORTED)
set_target_properties(sherpa_onnx_c_api PROPERTIES
    IMPORTED_LOCATION "${SHERPA_ONNX_C_API_LIB}"
    INTERFACE_INCLUDE_DIRECTORIES "${SHERPA_ONNX_INCLUDE_DIR}")

# ---- Library sources --------------------------------------------------------
set(VOICE_ENGINE_SOURCES
    streaming_asr_pipeline.cpp
    voice_engine_ffi.cpp)

set(VOICE_ENGINE_HEADERS
    voice_engine_config.h
    streaming_asr_pipeline.h
    voice_engine_ffi.h)

# ---- Build targets ----------------------------------------------------------
if(VOICE_ENGINE_BUILD_SHARED)
    add_library(voice_engine SHARED ${VOICE_ENGINE_SOURCES} ${VOICE_ENGINE_HEADERS})
else()
    add_library(voice_engine STATIC ${VOICE_ENGINE_SOURCES} ${VOICE_ENGINE_HEADERS})
endif()

target_include_directories(voice_engine
    PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}
    PRIVATE ${NLOHMANN_JSON_INCLUDE_DIR})

target_link_libraries(voice_engine PRIVATE sherpa_onnx_c_api)

# macOS: bundle-friendly install name.
if(APPLE AND VOICE_ENGINE_BUILD_SHARED)
    set_target_properties(voice_engine PROPERTIES
        INSTALL_RPATH "@executable_path/../Frameworks"
        BUILD_WITH_INSTALL_RPATH ON
        MACOSX_RPATH ON)
endif()

# ---- Test executable (optional) --------------------------------------------
if(VOICE_ENGINE_BUILD_TEST)
    add_executable(test_voice_engine test_voice_engine.cpp)
    target_include_directories(test_voice_engine
        PRIVATE ${CMAKE_CURRENT_SOURCE_DIR} ${NLOHMANN_JSON_INCLUDE_DIR})
    target_link_libraries(test_voice_engine PRIVATE voice_engine)
endif()
