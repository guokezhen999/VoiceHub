#!/bin/bash
# Build libllamacpp_nmt.dylib for macOS with Metal GPU acceleration.
#
# Prerequisites:
#   brew install cmake nlohmann-json
#
# The llama.cpp repo must be at llama/llama.cpp/ (already cloned).
#
# Usage:
#   ./build_macos.sh          # Debug build
#   ./build_macos.sh release  # Release build
#
# Output:
#   build/libllamacpp_nmt.dylib

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSRC_DIR="${SCRIPT_DIR}/csrc"
BUILD_DIR="${SCRIPT_DIR}/build"

BUILD_TYPE="${1:-Debug}"

# ---- Verify llama.cpp exists ------------------------------------------------

if [ ! -f "${SCRIPT_DIR}/llama.cpp/CMakeLists.txt" ]; then
    echo "ERROR: llama.cpp not found at ${SCRIPT_DIR}/llama.cpp/"
    echo "Clone it: git clone https://github.com/ggerganov/llama.cpp ${SCRIPT_DIR}/llama.cpp"
    exit 1
fi

# ---- Build ------------------------------------------------------------------

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

cmake "${CSRC_DIR}" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DLLAMACPP_BUILD_SHARED=ON \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15

cmake --build . --config "${BUILD_TYPE}" -j$(sysctl -n hw.logicalcpu)

# ---- Show result ------------------------------------------------------------

DYLIB="${BUILD_DIR}/libllamacpp_nmt.dylib"

if [ -f "${DYLIB}" ]; then
    echo ""
    echo "========================================"
    echo "Build succeeded!"
    echo "Library: ${DYLIB}"
    ls -lh "${DYLIB}"

    # Check architecture.
    echo ""
    echo "Architecture:"
    lipo -info "${DYLIB}"

    # Check dependencies.
    echo ""
    echo "Dependencies:"
    otool -L "${DYLIB}"

    # Fix llama/ggml dependencies to use @rpath if they point to build dir.
    for lib in libllama libggml libggml-cpu libggml-base; do
        LOAD_PATH=$(otool -L "${DYLIB}" | grep "${lib}" | head -1 | sed 's/ (.*//' | xargs || true)
        if [ -n "${LOAD_PATH}" ] && [[ "${LOAD_PATH}" == "${BUILD_DIR}"* ]]; then
            echo ""
            echo "Fixing ${lib} from build dir to @rpath/${lib}.dylib ..."
            install_name_tool -change "${LOAD_PATH}" "@rpath/${lib}.dylib" "${DYLIB}"
        fi
    done

    # Fix libomp to use @rpath (always from Homebrew).
    OMP_LOAD=$(otool -L "${DYLIB}" | grep "libomp" | head -1 | sed 's/ (.*//' | xargs || true)
    if [ -n "${OMP_LOAD}" ] && [[ "${OMP_LOAD}" == /opt/homebrew/* ]]; then
        echo ""
        echo "Fixing libomp from ${OMP_LOAD} to @rpath/libomp.dylib ..."
        install_name_tool -change "${OMP_LOAD}" "@rpath/libomp.dylib" "${DYLIB}"
    fi

    echo ""
    echo "Final dependencies:"
    otool -L "${DYLIB}"

    # ---- Bundle with Flutter plugin -----------------------------------------
    PLUGIN_DIR="${SCRIPT_DIR}/flutter/llamacpp_macos/macos"
    mkdir -p "${PLUGIN_DIR}"

    cp "${DYLIB}" "${PLUGIN_DIR}/"

    # Copy libomp if needed.
    OMP_SRC="/opt/homebrew/opt/libomp/lib/libomp.dylib"
    if [ -f "${OMP_SRC}" ] && [ ! -f "${PLUGIN_DIR}/libomp.dylib" ]; then
        cp "${OMP_SRC}" "${PLUGIN_DIR}/"
        echo "Copied libomp.dylib to plugin"
    fi

    echo ""
    echo "Bundled into: ${PLUGIN_DIR}/"
    ls -lh "${PLUGIN_DIR}"/*.dylib
    echo "========================================"
else
    echo "ERROR: Build did not produce libllamacpp_nmt.dylib"
    exit 1
fi
