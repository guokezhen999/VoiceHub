#!/bin/bash
# Build libopus_mt.dylib for macOS.
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
#   build/libopus_mt.dylib

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSRC_DIR="${SCRIPT_DIR}/csrc"
BUILD_DIR="${SCRIPT_DIR}/build"

BUILD_TYPE="${1:-Debug}"

# ---- Locate ONNX Runtime ----------------------------------------------------
# The sherpa-onnx build already includes onnxruntime.
# Check common locations.
#
# IMPORTANT: Prefer sherpa-onnx's bundled ONNX Runtime over system installs
# to avoid loading two different ONNX Runtime versions into the same process.

ONNX_PATHS=(
  "${SCRIPT_DIR}/../sherpa-onnx/build/_deps/onnxruntime-src"
  "${SCRIPT_DIR}/../sherpa-onnx/build/_deps/onnxruntime-install"
  "${SCRIPT_DIR}/../sherpa-onnx/build-swift-macos/_deps/onnxruntime-install"
  "/opt/homebrew"
  "/usr/local"
)

if [ -z "${ONNXRUNTIME_DIR:-}" ]; then
  for path in "${ONNX_PATHS[@]}"; do
    if [ -f "${path}/include/onnxruntime_cxx_api.h" ] || \
       [ -f "${path}/include/onnxruntime/onnxruntime_cxx_api.h" ]; then
      ONNXRUNTIME_DIR="${path}"
      echo "Found ONNX Runtime at: ${ONNXRUNTIME_DIR}"
      break
    fi
  done
else
  echo "Using ONNXRUNTIME_DIR from environment: ${ONNXRUNTIME_DIR}"
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

# Find the dylib. Prefer libonnxruntime.dylib (has @rpath install name,
# compatible with Flutter app bundle) over versioned variants.
ORT_LIB=""
for candidate in \
  "${ONNXRUNTIME_DIR}/lib/libonnxruntime.dylib" \
  "${ONNXRUNTIME_DIR}/lib/libonnxruntime.1.27.0.dylib" \
  "${ONNXRUNTIME_DIR}/lib/libonnxruntime.1.22.0.dylib" \
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
  -DOPUS_MT_BUILD_SHARED=ON \
  -DOPUS_MT_USE_SENTENCEPIECE=ON \
  -DONNXRUNTIME_INCLUDE_DIR="${ORT_INCLUDE}" \
  -DONNXRUNTIME_LIB="${ORT_LIB}" \
  -DCMAKE_OSX_ARCHITECTURES="arm64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15

cmake --build . --config "${BUILD_TYPE}" -j$(sysctl -n hw.logicalcpu)

# ---- Show result ------------------------------------------------------------

if [ -f "${BUILD_DIR}/libopus_mt.dylib" ]; then
  echo ""
  echo "========================================"
  echo "Build succeeded!"
  echo "Library: ${BUILD_DIR}/libopus_mt.dylib"
  ls -lh "${BUILD_DIR}/libopus_mt.dylib"

  # Fix ONNX Runtime dependency to use @rpath if it was linked against
  # a Homebrew absolute path. This ensures the dylib finds the bundled
  # libonnxruntime.dylib at runtime instead of requiring a system install.
  ONNX_RUNTIME_LOAD=$(otool -L "${BUILD_DIR}/libopus_mt.dylib" | grep "libonnxruntime" | head -1 | sed 's/ (.*//' | xargs || true)
  if [[ "${ONNX_RUNTIME_LOAD}" == /opt/homebrew/* ]] || [[ "${ONNX_RUNTIME_LOAD}" == /usr/local/* ]]; then
    echo ""
    echo "Warning: ONNX Runtime linked via absolute path: ${ONNX_RUNTIME_LOAD}"
    echo "Fixing to @rpath/libonnxruntime.dylib ..."
    install_name_tool -change "${ONNX_RUNTIME_LOAD}" "@rpath/libonnxruntime.dylib" "${BUILD_DIR}/libopus_mt.dylib"
    echo "Fixed. New dependency:"
    otool -L "${BUILD_DIR}/libopus_mt.dylib" | grep "libonnxruntime" || true
  else
    echo "ONNX Runtime load path OK: ${ONNX_RUNTIME_LOAD}"
  fi

  # Fix SentencePiece dependency to use @rpath as well.
  # The Flutter app bundles libsentencepiece.dylib in its Frameworks directory.
  SPM_LOAD=$(otool -L "${BUILD_DIR}/libopus_mt.dylib" | grep "libsentencepiece" | head -1 | sed 's/ (.*//' | xargs || true)
  if [[ -n "${SPM_LOAD}" ]] && { [[ "${SPM_LOAD}" == /opt/homebrew/* ]] || [[ "${SPM_LOAD}" == /usr/local/* ]]; }; then
    echo ""
    echo "Warning: SentencePiece linked via absolute path: ${SPM_LOAD}"
    echo "Fixing to @rpath/libsentencepiece.0.dylib ..."
    install_name_tool -change "${SPM_LOAD}" "@rpath/libsentencepiece.0.dylib" "${BUILD_DIR}/libopus_mt.dylib"
    echo "Fixed. New dependency:"
    otool -L "${BUILD_DIR}/libopus_mt.dylib" | grep "libsentencepiece"
  else
    echo "SentencePiece load path OK: ${SPM_LOAD:-none}"
  fi

  echo ""
  echo "To bundle with the Flutter app, copy the dylib into:"
  echo "  opus_mt/flutter/opus_mt_macos/macos/libopus_mt.dylib"
  echo "========================================"
else
  echo "ERROR: Build did not produce libopus_mt.dylib"
  exit 1
fi
