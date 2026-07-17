cmake_minimum_required(VERSION 3.14)
project(simulst VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(SIMULST_BUILD_SHARED "Build shared library" ON)
option(SIMULST_BUILD_TEST "Build test executable" ON)

# ---- nlohmann/json ----------------------------------------------------------
find_path(NLOHMANN_JSON_INCLUDE_DIR
    NAMES nlohmann/json.hpp
    HINTS /opt/homebrew/include /usr/local/include)
if(NOT NLOHMANN_JSON_INCLUDE_DIR)
    message(FATAL_ERROR "nlohmann/json.hpp not found. Install: brew install nlohmann-json")
endif()

# ---- kaldi-native-fbank -----------------------------------------------------
include(FetchContent)
FetchContent_Declare(kaldi_native_fbank
    GIT_REPOSITORY https://github.com/csukuangfj/kaldi-native-fbank.git
    GIT_TAG v1.22.3)
set(KALDI_NATIVE_FBANK_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(KALDI_NATIVE_FBANK_BUILD_PYTHON OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(kaldi_native_fbank)

# ---- llama.cpp --------------------------------------------------------------
set(LLAMA_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../llama/llama.cpp")
if(NOT EXISTS "${LLAMA_CPP_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "llama.cpp not found at ${LLAMA_CPP_DIR}")
endif()
set(GGML_METAL ON CACHE BOOL "" FORCE)
set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
add_subdirectory("${LLAMA_CPP_DIR}" _llama_build)

# ---- onnxruntime ------------------------------------------------------------
set(SHERPA_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../sherpa-onnx")
if(NOT ONNXRUNTIME_LIB OR NOT ONNXRUNTIME_INCLUDE_DIR)
    find_library(ONNXRUNTIME_LIB
        NAMES onnxruntime
        HINTS ${SHERPA_ROOT}/build/install/lib
              ${SHERPA_ROOT}/build/lib
              ${SHERPA_ROOT}/flutter/sherpa_onnx_macos/macos)
    find_path(ONNXRUNTIME_INCLUDE_DIR
        NAMES onnxruntime_cxx_api.h
        HINTS ${SHERPA_ROOT}/build/_deps/onnxruntime-src/include
              ${SHERPA_ROOT}/build/install/include
              /opt/homebrew/include)
endif()
if(NOT ONNXRUNTIME_LIB OR NOT ONNXRUNTIME_INCLUDE_DIR)
    message(FATAL_ERROR "onnxruntime not found. Build sherpa-onnx first or pass -DONNXRUNTIME_LIB=...")
endif()

# ---- sherpa-onnx c-api (VAD) ------------------------------------------------
if(NOT SHERPA_ONNX_C_API_LIB OR NOT SHERPA_ONNX_INCLUDE_DIR)
    find_library(SHERPA_ONNX_C_API_LIB
        NAMES sherpa-onnx-c-api
        HINTS ${SHERPA_ROOT}/build/install/lib
              ${SHERPA_ROOT}/build/lib
              ${SHERPA_ROOT}/flutter/sherpa_onnx_macos/macos)
    find_path(SHERPA_ONNX_INCLUDE_DIR
        NAMES c-api.h
        HINTS ${SHERPA_ROOT}/sherpa-onnx/c-api)
endif()
if(NOT SHERPA_ONNX_C_API_LIB OR NOT SHERPA_ONNX_INCLUDE_DIR)
    message(FATAL_ERROR "sherpa-onnx c-api not found")
endif()

add_library(sherpa_onnx_c_api SHARED IMPORTED)
set_target_properties(sherpa_onnx_c_api PROPERTIES
    IMPORTED_LOCATION "${SHERPA_ONNX_C_API_LIB}"
    INTERFACE_INCLUDE_DIRECTORIES "${SHERPA_ONNX_INCLUDE_DIR}")

# ---- simulst library --------------------------------------------------------
set(SIMULST_SOURCES
    npz_loader.cpp
    fbank_extractor.cpp
    onnx_streaming_encoder.cpp
    llama_gguf_decoder.cpp
    streaming_ast_pipeline.cpp
    simulst_ffi.cpp)

if(SIMULST_BUILD_SHARED)
    add_library(simulst SHARED ${SIMULST_SOURCES})
else()
    add_library(simulst STATIC ${SIMULST_SOURCES})
endif()

target_include_directories(simulst
    PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}
    PRIVATE ${NLOHMANN_JSON_INCLUDE_DIR}
    PRIVATE ${ONNXRUNTIME_INCLUDE_DIR}
    PRIVATE ${SHERPA_ONNX_INCLUDE_DIR}
    PRIVATE "${LLAMA_CPP_DIR}/include"
    PRIVATE "${kaldi_native_fbank_SOURCE_DIR}")

target_link_libraries(simulst
    PRIVATE llama
    PRIVATE kaldi-native-fbank-core
    PRIVATE sherpa_onnx_c_api
    PRIVATE ${ONNXRUNTIME_LIB}
    PRIVATE z)

if(APPLE)
    find_library(COREFOUNDATION_FRAMEWORK CoreFoundation REQUIRED)
    target_link_libraries(simulst PRIVATE ${COREFOUNDATION_FRAMEWORK})
    if(SIMULST_BUILD_SHARED)
        set_target_properties(simulst PROPERTIES
            INSTALL_RPATH "@executable_path/../Frameworks"
            BUILD_WITH_INSTALL_RPATH ON
            MACOSX_RPATH ON)
    endif()
endif()

if(SIMULST_BUILD_TEST)
    add_executable(test_simulst_inference test_simulst_inference.cpp)
    target_include_directories(test_simulst_inference
        PRIVATE ${CMAKE_CURRENT_SOURCE_DIR} ${NLOHMANN_JSON_INCLUDE_DIR})
    target_link_libraries(test_simulst_inference PRIVATE simulst)

    add_executable(test_simulst_gpu test_simulst_gpu.cpp)
    target_include_directories(test_simulst_gpu
        PRIVATE ${CMAKE_CURRENT_SOURCE_DIR} ${NLOHMANN_JSON_INCLUDE_DIR})
    target_link_libraries(test_simulst_gpu PRIVATE simulst)

    foreach(_simulst_test_target test_simulst_inference test_simulst_gpu)
    if(APPLE)
        set(_simulst_test_rpath
            "${CMAKE_BINARY_DIR}"
            "${CMAKE_BINARY_DIR}/lib")
        list(APPEND _simulst_test_rpath
            "${SHERPA_ROOT}/flutter/sherpa_onnx_macos/macos")
        set_target_properties(${_simulst_test_target} PROPERTIES
            BUILD_RPATH "${_simulst_test_rpath}"
            INSTALL_RPATH "${_simulst_test_rpath}")
    endif()
    endforeach()
endif()
