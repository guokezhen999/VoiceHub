#!/bin/bash
# ==============================================================================
# VoiceHub macOS Native Dynamic Libraries (.dylib) One-Click Build Script
# Compiles all C++ modules (sherpa-onnx, llama, opus_mt, voice_engine, simulst) for macOS
# and copies generated dylibs into their respective Flutter plugin directories.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_TYPE="${1:-release}"

echo "=================================================="
echo "Building all VoiceHub macOS Native Libraries"
echo "Build Type: ${BUILD_TYPE}"
echo "=================================================="

# 1. Build sherpa-onnx
echo ""
echo "---> [1/5] Building sherpa-onnx for macOS..."
cd "${ROOT_DIR}/sherpa-onnx"
mkdir -p build && cd build
cmake .. -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE="${BUILD_TYPE}"
cmake --build . --config "${BUILD_TYPE}" -j$(sysctl -n hw.logicalcpu || echo 4)

# 2. Build llama
echo ""
echo "---> [2/5] Building llama.cpp for macOS..."
cd "${ROOT_DIR}/llama"
./build_macos.sh "${BUILD_TYPE}"

# 3. Build opus_mt
echo ""
echo "---> [3/5] Building opus_mt for macOS..."
cd "${ROOT_DIR}/opus_mt"
./build_macos.sh "${BUILD_TYPE}"
mkdir -p flutter/opus_mt_macos/macos/
cp build/libopus_mt.dylib flutter/opus_mt_macos/macos/

# 4. Build voice_engine
echo ""
echo "---> [4/5] Building voice_engine for macOS..."
cd "${ROOT_DIR}/voice_engine"
./build_macos.sh "${BUILD_TYPE}"

# 5. Build simulst
echo ""
echo "---> [5/5] Building simulst for macOS..."
cd "${ROOT_DIR}/simulst"
./build_macos.sh "${BUILD_TYPE}"

echo ""
echo "=================================================="
echo "All macOS Native Libraries built & bundled successfully!"
echo "=================================================="
