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
mkdir -p build-android-arm64 && cd build-android-arm64
cmake .. \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-24 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DSHERPA_ONNX_ENABLE_C_API=ON \
    -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
    -DSHERPA_ONNX_ENABLE_JNI=OFF

cmake --build . --config Release -j$(sysctl -n hw.logicalcpu || echo 4)

# Copy sherpa-onnx and onnxruntime libs
find . -name "libsherpa-onnx-c-api.so" -exec cp {} "${JNILIBS_DIR}/" \; 2>/dev/null || true
find . -name "libonnxruntime.so" -exec cp {} "${JNILIBS_DIR}/" \; 2>/dev/null || true

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
    -DOPUS_MT_BUILD_TEST=OFF

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
    -DVOICE_ENGINE_BUILD_SHARED=ON

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
    -DSIMULST_BUILD_SHARED=ON

cmake --build . --config Release -j$(sysctl -n hw.logicalcpu || echo 4)

find . -name "libsimulst.so" -exec cp {} "${JNILIBS_DIR}/" \; 2>/dev/null || true

echo ""
echo "=================================================="
echo "Android Native compilation finished!"
echo "Check compiled .so files in: ${JNILIBS_DIR}"
ls -lh "${JNILIBS_DIR}"
echo "=================================================="
