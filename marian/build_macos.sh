#!/bin/bash
# Build libmarian_nmt.dylib for macOS.
#
# Prerequisites:
#   brew install cmake nlohmann-json
#
# ONNX Runtime is expected to be found in the sherpa-onnx build directory,
# or you can set ONNXRUNTIME_DIR to point to your onnxruntime installation.
#
# Usage:
#   ./build_macos.sh          # Debug build
#   ./build_macos.sh release  # Release build
#
# Output:
#   build/libmarian_nmt.dylib

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSRC_DIR="${SCRIPT_DIR}/csrc"
BUILD_DIR="${SCRIPT_DIR}/build"

BUILD_TYPE="${1:-Debug}"

# ---- Locate ONNX Runtime ----------------------------------------------------
# The sherpa-onnx build already includes onnxruntime.
# Check common locations.

ONNX_PATHS=(
  "${SCRIPT_DIR}/../sherpa-onnx/build/_deps/onnxruntime-install"
  "${SCRIPT_DIR}/../sherpa-onnx/build-swift-macos/_deps/onnxruntime-install"
  "${SCRIPT_DIR}/../sherpa-onnx/build/_deps/onnxruntime-src"
  "/usr/local"
  "/opt/homebrew"
)

ONNXRUNTIME_DIR=""
if [ -n "${ONNXRUNTIME_DIR:-}" ]; then
  echo "Using ONNXRUNTIME_DIR from environment: ${ONNXRUNTIME_DIR}"
else
  for path in "${ONNX_PATHS[@]}"; do
    if [ -f "${path}/include/onnxruntime_cxx_api.h" ] || \
       [ -f "${path}/include/onnxruntime/onnxruntime_cxx_api.h" ]; then
      ONNXRUNTIME_DIR="${path}"
      echo "Found ONNX Runtime at: ${ONNXRUNTIME_DIR}"
      break
    fi
  done
fi

if [ -z "${ONNXRUNTIME_DIR}" ]; then
  echo "ERROR: ONNX Runtime not found."
  echo "Set ONNXRUNTIME_DIR to your onnxruntime installation, or build sherpa-onnx first:"
  echo "  cd ../sherpa-onnx && mkdir -p build && cd build"
  echo "  cmake .. -DBUILD_SHARED_LIBS=ON"
  echo "  cmake --build ."
  exit 1
fi

# ---- Find the actual include path and library --------------------------------

# Some installations place headers in include/onnxruntime/.
if [ -f "${ONNXRUNTIME_DIR}/include/onnxruntime/onnxruntime_cxx_api.h" ]; then
  ORT_INCLUDE="${ONNXRUNTIME_DIR}/include/onnxruntime"
elif [ -f "${ONNXRUNTIME_DIR}/include/onnxruntime_cxx_api.h" ]; then
  ORT_INCLUDE="${ONNXRUNTIME_DIR}/include"
else
  echo "ERROR: Could not find onnxruntime_cxx_api.h"
  exit 1
fi

# Find the dylib.
ORT_LIB=""
for candidate in \
  "${ONNXRUNTIME_DIR}/lib/libonnxruntime.dylib" \
  "${ONNXRUNTIME_DIR}/lib/libonnxruntime.1.27.0.dylib" \
  "${ONNXRUNTIME_DIR}/lib/libonnxruntime.so"; do
  if [ -f "${candidate}" ]; then
    ORT_LIB="${candidate}"
    break
  fi
done

if [ -z "${ORT_LIB}" ]; then
  echo "ERROR: Could not find libonnxruntime.dylib or .so"
  echo "Looked in: ${ONNXRUNTIME_DIR}/lib/"
  exit 1
fi

echo "ORT include: ${ORT_INCLUDE}"
echo "ORT lib:     ${ORT_LIB}"

# ---- Build -------------------------------------------------------------------

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

cmake "${CSRC_DIR}" \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DMARIAN_BUILD_SHARED=ON \
  -DONNXRUNTIME_INCLUDE_DIR="${ORT_INCLUDE}" \
  -DONNXRUNTIME_LIB="${ORT_LIB}" \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15

cmake --build . --config "${BUILD_TYPE}" -j$(sysctl -n hw.logicalcpu)

# ---- Show result ------------------------------------------------------------

if [ -f "${BUILD_DIR}/libmarian_nmt.dylib" ]; then
  echo ""
  echo "========================================"
  echo "Build succeeded!"
  echo "Library: ${BUILD_DIR}/libmarian_nmt.dylib"
  ls -lh "${BUILD_DIR}/libmarian_nmt.dylib"
  echo ""
  echo "To bundle with the Flutter app, copy the dylib into:"
  echo "  voice_app/macos/Runner/"
  echo "and add it to the Xcode project under"
  echo "  Runner > General > Frameworks, Libraries, and Embedded Content."
  echo "========================================"
else
  echo "ERROR: Build did not produce libmarian_nmt.dylib"
  exit 1
fi
