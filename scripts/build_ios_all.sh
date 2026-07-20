#!/bin/bash
# ==============================================================================
# VoiceHub iOS Static & Framework (.xcframework) One-Click Build Script
# Compiles all C++ modules (sherpa-onnx, llama, opus_mt, voice_engine) for iOS
# and bundles xcframeworks into their respective Flutter iOS plugin directories.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=================================================="
echo "Building all VoiceHub iOS Native Frameworks"
echo "=================================================="

# 1. Build sherpa-onnx for iOS
echo ""
echo "---> [1/4] Building sherpa-onnx for iOS..."
cd "${ROOT_DIR}/sherpa-onnx"
./build-ios.sh

# 2. Build llama for iOS
echo ""
echo "---> [2/4] Building llama.cpp for iOS..."
cd "${ROOT_DIR}/llama"
./build_ios.sh

# 3. Build opus_mt for iOS
echo ""
echo "---> [3/4] Building opus_mt for iOS..."
cd "${ROOT_DIR}/opus_mt"
./build_ios.sh

# 4. Build voice_engine for iOS
echo ""
echo "---> [4/4] Building voice_engine for iOS..."
cd "${ROOT_DIR}/voice_engine"
./build_ios.sh

echo ""
echo "=================================================="
echo "All iOS Native Frameworks built & bundled successfully!"
echo "=================================================="
