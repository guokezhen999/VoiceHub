#!/bin/bash
# Build libvoice_engine.dylib for macOS.
#
# Prerequisites:
#   brew install cmake nlohmann-json
#   sherpa-onnx must be built first (produces libsherpa-onnx-c-api.dylib):
#     cd ../sherpa-onnx && mkdir -p build && cd build
#     cmake .. -DBUILD_SHARED_LIBS=ON && cmake --build .
#     cmake --install . --config Release
#
# Usage:
#   ./build_macos.sh          # Debug build
#   ./build_macos.sh release  # Release build
#
# Output:
#   build/libvoice_engine.dylib  (copied into the Flutter plugin macos/ dir)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSRC_DIR="${SCRIPT_DIR}/csrc"
BUILD_DIR="${SCRIPT_DIR}/build"
BUILD_TYPE="${1:-Debug}"

SHERPA_DIR="${SCRIPT_DIR}/../sherpa-onnx"

# ---- Locate sherpa-onnx c-api dylib + include ------------------------------
SHERPA_C_API_LIB=""
for candidate in \
  "${SHERPA_DIR}/build/install/lib/libsherpa-onnx-c-api.dylib" \
  "${SHERPA_DIR}/build/lib/libsherpa-onnx-c-api.dylib" \
  "${SHERPA_DIR}/build-swift-macos/install/lib/libsherpa-onnx-c-api.dylib"; do
  if [ -f "${candidate}" ]; then
    SHERPA_C_API_LIB="${candidate}"
    break
  fi
done

if [ -z "${SHERPA_C_API_LIB}" ]; then
  echo "ERROR: libsherpa-onnx-c-api.dylib not found."
  echo "Build sherpa-onnx first:"
  echo "  cd ../sherpa-onnx && mkdir -p build && cd build"
  echo "  cmake .. -DBUILD_SHARED_LIBS=ON && cmake --build ."
  echo "  cmake --install . --config Release"
  exit 1
fi

SHERPA_INCLUDE_DIR="${SHERPA_DIR}/sherpa-onnx/c-api"
if [ ! -f "${SHERPA_INCLUDE_DIR}/c-api.h" ]; then
  SHERPA_INCLUDE_DIR="${SHERPA_DIR}/build/install/include/sherpa-onnx/c-api"
fi
if [ ! -f "${SHERPA_INCLUDE_DIR}/c-api.h" ]; then
  echo "ERROR: sherpa-onnx c-api.h not found."
  exit 1
fi

echo "sherpa-onnx c-api lib:    ${SHERPA_C_API_LIB}"
echo "sherpa-onnx c-api include: ${SHERPA_INCLUDE_DIR}"

# ---- Build -----------------------------------------------------------------
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

cmake "${CSRC_DIR}" \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DVOICE_ENGINE_BUILD_SHARED=ON \
  -DSHERPA_ONNX_C_API_LIB="${SHERPA_C_API_LIB}" \
  -DSHERPA_ONNX_INCLUDE_DIR="${SHERPA_INCLUDE_DIR}" \
  -DCMAKE_OSX_ARCHITECTURES="arm64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15

cmake --build . --config "${BUILD_TYPE}" -j$(sysctl -n hw.logicalcpu)

# ---- Show result + fix load paths ------------------------------------------
DYLIB="${BUILD_DIR}/libvoice_engine.dylib"
if [ ! -f "${DYLIB}" ]; then
  echo "ERROR: Build did not produce libvoice_engine.dylib"
  exit 1
fi

echo ""
echo "========================================"
echo "Build succeeded!"
ls -lh "${DYLIB}"

# Rewrite the sherpa-onnx-c-api dependency to @rpath so it resolves to the
# same dylib the sherpa_onnx Flutter plugin bundles into the app Frameworks.
SHERPA_LOAD=$(otool -L "${DYLIB}" | grep "libsherpa-onnx-c-api" | head -1 | sed 's/ (.*//' | xargs || true)
if [[ -n "${SHERPA_LOAD}" ]] && [[ "${SHERPA_LOAD}" != @rpath/* ]] && [[ "${SHERPA_LOAD}" != @loader_path/* ]]; then
  echo "Rewriting sherpa-onnx-c-api load path -> @rpath/libsherpa-onnx-c-api.dylib"
  install_name_tool -change "${SHERPA_LOAD}" "@rpath/libsherpa-onnx-c-api.dylib" "${DYLIB}"
fi
otool -L "${DYLIB}" | grep "libsherpa-onnx-c-api" || true

# ---- Copy into the Flutter plugin macos/ dir -------------------------------
PLUGIN_DIR="${SCRIPT_DIR}/flutter/voice_engine_macos/macos"
mkdir -p "${PLUGIN_DIR}"
cp "${DYLIB}" "${PLUGIN_DIR}/"
echo "Copied to ${PLUGIN_DIR}/libvoice_engine.dylib"
echo "========================================"
