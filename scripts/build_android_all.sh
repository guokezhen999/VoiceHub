#!/bin/bash
# ==============================================================================
# VoiceHub Android Native (.so) Cross-Compilation Script
# Automatically compiles C++ modules (sherpa-onnx, llama, opus_mt, voice_engine, simulst)
# for Android arm64-v8a and copies .so files into voice_app/android/app/src/main/jniLibs/arm64-v8a/
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
JNILIBS_DIR="${ROOT_DIR}/voice_app/android/app/src/main/jniLibs/arm64-v8a"

# 1. Locate Android NDK
if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "${ANDROID_NDK_HOME}" ]; then
    NDK="${ANDROID_NDK_HOME}"
elif [ -n "${NDK_HOME:-}" ] && [ -d "${NDK_HOME}" ]; then
    NDK="${NDK_HOME}"
else
    # Try default macOS Android SDK NDK location
    LATEST_NDK=$(ls -d ~/Library/Android/sdk/ndk/* 2>/dev/null | tail -n 1 || true)
    if [ -n "${LATEST_NDK}" ] && [ -d "${LATEST_NDK}" ]; then
        NDK="${LATEST_NDK}"
    else
        echo "ERROR: Android NDK not found!"
        echo "Please install NDK via Android Studio (Tools -> SDK Manager -> SDK Tools -> NDK) "
        echo "or export ANDROID_NDK_HOME=/path/to/ndk"
        exit 1
    fi
fi

echo "=================================================="
echo "Using Android NDK: ${NDK}"
echo "Target ABI: arm64-v8a"
echo "Output Directory: ${JNILIBS_DIR}"
echo "=================================================="

TOOLCHAIN="${NDK}/build/cmake/android.toolchain.cmake"
mkdir -p "${JNILIBS_DIR}"

# 2. Build sherpa-onnx
echo ""
echo "---> Building sherpa-onnx for Android..."
cd "${ROOT_DIR}/sherpa-onnx"
ANDROID_NDK="${NDK}" SHERPA_ONNX_ENABLE_C_API=ON ./build-android-arm64-v8a.sh

# Copy sherpa-onnx and onnxruntime libs
find build-android-arm64-v8a -name "libsherpa-onnx*.so" -exec cp {} "${JNILIBS_DIR}/" \; 2>/dev/null || true
find build-android-arm64-v8a -name "libonnxruntime.so" -exec cp {} "${JNILIBS_DIR}/" \; 2>/dev/null || true

# 3. Build llama
echo ""
echo "---> Building llama.cpp for Android..."
cd "${ROOT_DIR}/llama"
mkdir -p build-android-arm64 && cd build-android-arm64
cmake ../csrc \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-24 \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMACPP_BUILD_SHARED=ON \
    -DLLAMACPP_BUILD_TEST=OFF

cmake --build . --config Release -j$(sysctl -n hw.logicalcpu || echo 4)

find . -name "libllamacpp_nmt.so" -exec cp {} "${JNILIBS_DIR}/" \; 2>/dev/null || true

SHERPA_BUILD_DIR="${ROOT_DIR}/sherpa-onnx/build-android-arm64-v8a"
ONNX_LIB="${SHERPA_BUILD_DIR}/install/lib/libonnxruntime.so"
ONNX_INC="${SHERPA_BUILD_DIR}/1.27.0/headers"
SHERPA_C_API_LIB="${SHERPA_BUILD_DIR}/install/lib/libsherpa-onnx-c-api.so"
SHERPA_C_API_INC="${ROOT_DIR}/sherpa-onnx/sherpa-onnx/c-api"

# 4. Build opus_mt
echo ""
echo "---> Building opus_mt for Android..."
cd "${ROOT_DIR}/opus_mt"
mkdir -p build-android-arm64 && cd build-android-arm64
cmake ../csrc \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-24 \
    -DCMAKE_BUILD_TYPE=Release \
    -DOPUS_MT_BUILD_SHARED=ON \
    -DOPUS_MT_BUILD_TEST=OFF \
    -DONNXRUNTIME_LIB="${ONNX_LIB}" \
    -DONNXRUNTIME_INCLUDE_DIR="${ONNX_INC}"

cmake --build . --config Release -j$(sysctl -n hw.logicalcpu || echo 4)

find . -name "libopus_mt.so" -exec cp {} "${JNILIBS_DIR}/" \; 2>/dev/null || true

# 5. Build voice_engine
echo ""
echo "---> Building voice_engine for Android..."
cd "${ROOT_DIR}/voice_engine"
mkdir -p build-android-arm64 && cd build-android-arm64
cmake ../csrc \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-24 \
    -DCMAKE_BUILD_TYPE=Release \
    -DVOICE_ENGINE_BUILD_SHARED=ON \
    -DSHERPA_ONNX_C_API_LIB="${SHERPA_C_API_LIB}" \
    -DSHERPA_ONNX_INCLUDE_DIR="${SHERPA_C_API_INC}"

cmake --build . --config Release -j$(sysctl -n hw.logicalcpu || echo 4)

find . -name "libvoice_engine.so" -exec cp {} "${JNILIBS_DIR}/" \; 2>/dev/null || true

# 6. Build simulst
echo ""
echo "---> Building simulst for Android..."
cd "${ROOT_DIR}/simulst"
mkdir -p build-android-arm64 && cd build-android-arm64
cmake ../csrc \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-24 \
    -DCMAKE_BUILD_TYPE=Release \
    -DSIMULST_BUILD_SHARED=ON \
    -DSIMULST_BUILD_TEST=OFF \
    -DONNXRUNTIME_LIB="${ONNX_LIB}" \
    -DONNXRUNTIME_INCLUDE_DIR="${ONNX_INC}" \
    -DSHERPA_ONNX_C_API_LIB="${SHERPA_C_API_LIB}" \
    -DSHERPA_ONNX_INCLUDE_DIR="${SHERPA_C_API_INC}"

cmake --build . --config Release -j$(sysctl -n hw.logicalcpu || echo 4)

find . -name "libsimulst.so" -exec cp {} "${JNILIBS_DIR}/" \; 2>/dev/null || true

echo ""
echo "=================================================="
echo "Android Native compilation finished!"
echo "Check compiled .so files in: ${JNILIBS_DIR}"
ls -lh "${JNILIBS_DIR}"
echo "=================================================="
