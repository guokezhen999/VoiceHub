cmake_minimum_required(VERSION 3.14)
project(opus_mt VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ---- Build options ----------------------------------------------------------

# Build as shared library by default (needed for FFI).
option(OPUS_MT_BUILD_SHARED "Build shared library" ON)
option(OPUS_MT_USE_SENTENCEPIECE "Use SentencePiece library" OFF)
option(OPUS_MT_USE_SYSTEM_ONNXRUNTIME "Use system-installed onnxruntime" OFF)

# ---- Dependencies -----------------------------------------------------------

# nlohmann/json (header-only JSON parser).
# Automatically fetched or expected at a known location.
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
        "nlohmann/json.hpp not found. "
        "Install it: brew install nlohmann-json (macOS) "
        "or place it in opus_mt/third_party/nlohmann/")
endif()

# ---- ONNX Runtime -----------------------------------------------------------
# ONNX Runtime is required. The library can be found:
#   - Prebuilt in sherpa-onnx build directory
#   - System-installed (brew install onnxruntime)
#   - Via onnxruntime_DIR or ONNXRUNTIME_ROOT

if(OPUS_MT_USE_SYSTEM_ONNXRUNTIME)
    find_package(onnxruntime REQUIRED)
    set(ONNXRUNTIME_TARGET onnxruntime::onnxruntime)
else()
    # Search in common locations.
    # Prefer sherpa-onnx build directories to avoid version conflicts.
    set(ONNX_PATHS
        ${CMAKE_CURRENT_SOURCE_DIR}/../sherpa-onnx/build/_deps/onnxruntime-src
        ${CMAKE_CURRENT_SOURCE_DIR}/../sherpa-onnx/build/_deps/onnxruntime-install
        ${CMAKE_CURRENT_SOURCE_DIR}/../sherpa-onnx/build-swift-macos/_deps/onnxruntime-install
        ${CMAKE_CURRENT_SOURCE_DIR}/../sherpa-onnx/build-ios/ios-onnxruntime
        /opt/homebrew
        /usr/local)

    find_path(ONNXRUNTIME_INCLUDE_DIR
        NAMES onnxruntime_cxx_api.h
        HINTS ${ONNX_PATHS}
        PATH_SUFFIXES include include/onnxruntime)

    find_library(ONNXRUNTIME_LIB
        NAMES onnxruntime libonnxruntime
        HINTS ${ONNX_PATHS}
        PATH_SUFFIXES lib)

    if(NOT ONNXRUNTIME_INCLUDE_DIR OR NOT ONNXRUNTIME_LIB)
        message(FATAL_ERROR
            "ONNX Runtime not found. Set -DONNXRUNTIME_INCLUDE_DIR=... "
            "and -DONNXRUNTIME_LIB=..., or enable -DOPUS_MT_USE_SYSTEM_ONNXRUNTIME=ON")
    endif()

    message(STATUS "ONNX Runtime include: ${ONNXRUNTIME_INCLUDE_DIR}")
    message(STATUS "ONNX Runtime lib: ${ONNXRUNTIME_LIB}")

    add_library(onnxruntime SHARED IMPORTED)
    set_target_properties(onnxruntime PROPERTIES
        IMPORTED_LOCATION "${ONNXRUNTIME_LIB}"
        INTERFACE_INCLUDE_DIRECTORIES "${ONNXRUNTIME_INCLUDE_DIR}")
    set(ONNXRUNTIME_TARGET onnxruntime)
endif()

# ---- SentencePiece (optional) -----------------------------------------------

if(OPUS_MT_USE_SENTENCEPIECE)
    find_package(sentencepiece QUIET)
    if(NOT sentencepiece_FOUND)
        find_path(SENTENCEPIECE_INCLUDE_DIR
            NAMES sentencepiece_processor.h
            HINTS /usr/local/include /opt/homebrew/include)
        find_library(SENTENCEPIECE_LIB
            NAMES sentencepiece
            HINTS /usr/local/lib /opt/homebrew/lib)

        if(SENTENCEPIECE_INCLUDE_DIR AND SENTENCEPIECE_LIB)
            add_library(sentencepiece SHARED IMPORTED)
            set_target_properties(sentencepiece PROPERTIES
                IMPORTED_LOCATION "${SENTENCEPIECE_LIB}"
                INTERFACE_INCLUDE_DIRECTORIES "${SENTENCEPIECE_INCLUDE_DIR}")
        else()
            message(WARNING "SentencePiece not found. Building without it. "
                            "Falling back to vocab-based tokenization.")
            set(OPUS_MT_USE_SENTENCEPIECE OFF)
        endif()
    endif()
endif()

# ---- Library sources --------------------------------------------------------

set(OPUS_MT_SOURCES
    opus_mt_tokenizer.cpp
    opus_mt_translator.cpp
    opus_mt_ffi.cpp)

set(OPUS_MT_HEADERS
    opus_mt_config.h
    opus_mt_tokenizer.h
    opus_mt_translator.h
    opus_mt_ffi.h
    opus_mt_bridge.h)

# ---- Build targets ----------------------------------------------------------

if(OPUS_MT_BUILD_SHARED)
    add_library(opus_mt SHARED ${OPUS_MT_SOURCES} ${OPUS_MT_HEADERS})
else()
    add_library(opus_mt STATIC ${OPUS_MT_SOURCES} ${OPUS_MT_HEADERS})
endif()

target_include_directories(opus_mt
    PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}
    PRIVATE ${NLOHMANN_JSON_INCLUDE_DIR})

target_link_libraries(opus_mt PRIVATE ${ONNXRUNTIME_TARGET})

if(OPUS_MT_USE_SENTENCEPIECE)
    target_compile_definitions(opus_mt PRIVATE OPUS_MT_USE_SENTENCEPIECE)
    target_link_libraries(opus_mt PRIVATE sentencepiece)
endif()

# macOS: set install name so the dylib can be bundled with an app.
if(APPLE AND OPUS_MT_BUILD_SHARED)
    set_target_properties(opus_mt PROPERTIES
        INSTALL_RPATH "@executable_path/../Frameworks"
        BUILD_WITH_INSTALL_RPATH ON
        MACOSX_RPATH ON)
endif()

# ---- Installation -----------------------------------------------------------

# ---- Test executable (optional) ----------------------------------------------
option(OPUS_MT_BUILD_TEST "Build inference test executable" OFF)

if(OPUS_MT_BUILD_TEST)
    add_executable(test_opus_mt_inference test_opus_mt_inference.cpp)
    target_include_directories(test_opus_mt_inference
        PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}
        PRIVATE ${NLOHMANN_JSON_INCLUDE_DIR})
    target_link_libraries(test_opus_mt_inference PRIVATE opus_mt)
endif()

install(TARGETS opus_mt
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib)
install(FILES ${OPUS_MT_HEADERS} DESTINATION include/opus_mt)

# ---- Platform-specific notes ------------------------------------------------
# To build for macOS:
#   cmake -B build -DOPUS_MT_BUILD_SHARED=ON
#   cmake --build build
#
# To build for iOS:
#   cmake -B build-ios \
#       -DCMAKE_SYSTEM_NAME=iOS \
#       -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
#       -DCMAKE_OSX_ARCHITECTURES=arm64 \
#       -DOPUS_MT_BUILD_SHARED=OFF \
#       -DONNXRUNTIME_INCLUDE_DIR=... \
#       -DONNXRUNTIME_LIB=...
#
# To build for Android (cross-compile):
#   Use Android NDK toolchain file with cmake.
