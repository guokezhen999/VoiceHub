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
          /opt/homebrew/include
          ${CMAKE_CURRENT_SOURCE_DIR}/../../sherpa-onnx/build-android-arm64-v8a/_deps/json-src/include
    NO_CMAKE_FIND_ROOT_PATH)
if(NLOHMANN_JSON_INCLUDE_DIR)
    message(STATUS "Found nlohmann/json at ${NLOHMANN_JSON_INCLUDE_DIR}")
else()
    message(FATAL_ERROR
        "nlohmann/json.hpp not found. Install it: brew install nlohmann-json")
endif()

# ---- sherpa-onnx ------------------------------------------------------------
# macOS: link the prebuilt libsherpa-onnx-c-api.dylib bundled by the
#        sherpa_onnx Flutter plugin.
# iOS:   statically link libsherpa-onnx.a + onnxruntime (both prebuilt by
#        sherpa-onnx/build-ios.sh) into the voice_engine dylib so the
#        resulting framework is self-contained.
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    # Paths are supplied by build_ios.sh.
    if(NOT SHERPA_ONNX_LIB OR NOT SHERPA_ONNX_INCLUDE_DIR)
        message(FATAL_ERROR
            "iOS build requires -DSHERPA_ONNX_LIB=<libsherpa-onnx.a> and "
            "-DSHERPA_ONNX_INCLUDE_DIR=<.../c-api headers>")
    endif()
    if(NOT ONNXRUNTIME_LIB OR NOT ONNXRUNTIME_INCLUDE_DIR)
        message(FATAL_ERROR
            "iOS build requires -DONNXRUNTIME_LIB=<onnxruntime> and "
            "-DONNXRUNTIME_INCLUDE_DIR=<onnxruntime Headers>")
    endif()

    message(STATUS "iOS sherpa-onnx lib:      ${SHERPA_ONNX_LIB}")
    message(STATUS "iOS sherpa-onnx include:  ${SHERPA_ONNX_INCLUDE_DIR}")
    message(STATUS "iOS onnxruntime lib:      ${ONNXRUNTIME_LIB}")
    message(STATUS "iOS onnxruntime include:  ${ONNXRUNTIME_INCLUDE_DIR}")

    # sherpa-onnx static archive references vDSP/BLAS (Accelerate),
    # CoreFoundation, and CoreML. Resolve them via find_library so they link by full path
    # (avoids the `-framework X` token-splitting gotcha in target_link_options).
    find_library(ACCELERATE_FRAMEWORK Accelerate REQUIRED)
    find_library(COREFOUNDATION_FRAMEWORK CoreFoundation REQUIRED)
    find_library(COREML_FRAMEWORK CoreML REQUIRED)

    set(SHERPA_LINK_LIBS
        ${SHERPA_ONNX_LIB}
        ${ONNXRUNTIME_LIB}
        ${ACCELERATE_FRAMEWORK}
        ${COREFOUNDATION_FRAMEWORK}
        ${COREML_FRAMEWORK})
    set(SHERPA_INCLUDE_DIRS ${SHERPA_ONNX_INCLUDE_DIR} ${ONNXRUNTIME_INCLUDE_DIR})
    set(SHERPA_LINK_OPTIONS "")
else()
    # ---- macOS: prebuilt dynamic library -----------------------------------
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
        set(SHERPA_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../sherpa-onnx")
    endif()

    find_library(SHERPA_ONNX_C_API_LIB
        NAMES sherpa-onnx-c-api
        HINTS ${SHERPA_ROOT}/build/install/lib
              ${SHERPA_ROOT}/build/lib
              ${SHERPA_ROOT}/build-android-arm64-v8a/install/lib
              ${SHERPA_ROOT}/build-android-arm64-v8a/lib
              ${SHERPA_ROOT}/build-swift-macos/install/lib
        PATH_SUFFIXES lib
        NO_CMAKE_FIND_ROOT_PATH)
    if(NOT SHERPA_ONNX_C_API_LIB)
        message(FATAL_ERROR
            "libsherpa-onnx-c-api not found. Build sherpa-onnx first.")
    endif()

    # Resolve the include directory for c-api.h.
    find_path(SHERPA_ONNX_INCLUDE_DIR
        NAMES c-api.h
        HINTS ${SHERPA_ROOT}/sherpa-onnx/c-api
              ${SHERPA_ROOT}/build/install/include/sherpa-onnx/c-api
              ${SHERPA_ROOT}/build-android-arm64-v8a/install/include/sherpa-onnx/c-api
        PATH_SUFFIXES sherpa-onnx/c-api
        NO_CMAKE_FIND_ROOT_PATH)
    if(NOT SHERPA_ONNX_INCLUDE_DIR)
        message(FATAL_ERROR "sherpa-onnx c-api.h not found under ${SHERPA_ROOT}")
    endif()

    message(STATUS "sherpa-onnx c-api lib:    ${SHERPA_ONNX_C_API_LIB}")
    message(STATUS "sherpa-onnx c-api include: ${SHERPA_ONNX_INCLUDE_DIR}")

    add_library(sherpa_onnx_c_api SHARED IMPORTED)
    set_target_properties(sherpa_onnx_c_api PROPERTIES
        IMPORTED_LOCATION "${SHERPA_ONNX_C_API_LIB}"
        INTERFACE_INCLUDE_DIRECTORIES "${SHERPA_ONNX_INCLUDE_DIR}")

    set(SHERPA_LINK_LIBS sherpa_onnx_c_api)
    set(SHERPA_INCLUDE_DIRS "")
    set(SHERPA_LINK_OPTIONS "")
endif()

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
    PRIVATE ${NLOHMANN_JSON_INCLUDE_DIR} ${SHERPA_INCLUDE_DIRS})

target_link_libraries(voice_engine PRIVATE ${SHERPA_LINK_LIBS})
if(APPLE)
    find_library(COREFOUNDATION_FRAMEWORK CoreFoundation REQUIRED)
    find_library(AUDIOTOOLBOX_FRAMEWORK AudioToolbox REQUIRED)
    target_link_libraries(voice_engine PRIVATE ${COREFOUNDATION_FRAMEWORK} ${AUDIOTOOLBOX_FRAMEWORK})
endif()
if(SHERPA_LINK_OPTIONS)
    target_link_options(voice_engine PRIVATE ${SHERPA_LINK_OPTIONS})
endif()

# Apple: bundle-friendly install name.
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
