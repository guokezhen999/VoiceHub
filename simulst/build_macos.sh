#!/bin/bash
# Build libsimulst.dylib for macOS.
#
# Prerequisites:
#   brew install cmake nlohmann-json
#   sherpa-onnx built (libsherpa-onnx-c-api.dylib + onnxruntime)
#   llama.cpp at llama/llama.cpp
#
# Usage:
#   ./build_macos.sh
#   ./build_macos.sh release

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSRC_DIR="${SCRIPT_DIR}/csrc"
BUILD_DIR="${SCRIPT_DIR}/build"
BUILD_TYPE="${1:-Debug}"

SHERPA_DIR="${SCRIPT_DIR}/../sherpa-onnx"

SHERPA_C_API_LIB=""
for candidate in \
  "${SHERPA_DIR}/flutter/sherpa_onnx_macos/macos/libsherpa-onnx-c-api.dylib" \
  "${SHERPA_DIR}/build/install/lib/libsherpa-onnx-c-api.dylib" \
  "${SHERPA_DIR}/build/lib/libsherpa-onnx-c-api.dylib"; do
  if [ -f "${candidate}" ]; then
    SHERPA_C_API_LIB="${candidate}"
    break
  fi
done
if [ -z "${SHERPA_C_API_LIB}" ]; then
  echo "ERROR: libsherpa-onnx-c-api.dylib not found"
  exit 1
fi

ONNXRUNTIME_LIB=""
for candidate in \
  "${SHERPA_DIR}/flutter/sherpa_onnx_macos/macos/libonnxruntime.dylib" \
  "${SHERPA_DIR}/build/install/lib/libonnxruntime.dylib" \
  "${SHERPA_DIR}/build/lib/libonnxruntime.dylib"; do
  if [ -f "${candidate}" ]; then
    ONNXRUNTIME_LIB="${candidate}"
    break
  fi
done
if [ -z "${ONNXRUNTIME_LIB}" ]; then
  echo "ERROR: libonnxruntime.dylib not found"
  exit 1
fi

ONNXRUNTIME_INCLUDE_DIR="${SHERPA_DIR}/build/_deps/onnxruntime-src/include"
if [ ! -f "${ONNXRUNTIME_INCLUDE_DIR}/onnxruntime_cxx_api.h" ]; then
  ONNXRUNTIME_INCLUDE_DIR="${SHERPA_DIR}/build/install/include"
fi

SHERPA_INCLUDE_DIR="${SHERPA_DIR}/sherpa-onnx/c-api"

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

cmake "${CSRC_DIR}" \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DSIMULST_BUILD_SHARED=ON \
  -DSIMULST_BUILD_TEST=ON \
  -DSHERPA_ONNX_C_API_LIB="${SHERPA_C_API_LIB}" \
  -DSHERPA_ONNX_INCLUDE_DIR="${SHERPA_INCLUDE_DIR}" \
  -DONNXRUNTIME_LIB="${ONNXRUNTIME_LIB}" \
  -DONNXRUNTIME_INCLUDE_DIR="${ONNXRUNTIME_INCLUDE_DIR}" \
  -DCMAKE_OSX_ARCHITECTURES="arm64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15

cmake --build . --config "${BUILD_TYPE}" -j"$(sysctl -n hw.logicalcpu)"

DYLIB="${BUILD_DIR}/libsimulst.dylib"
if [ ! -f "${DYLIB}" ]; then
  echo "ERROR: build did not produce libsimulst.dylib"
  exit 1
fi

echo "Build succeeded: ${DYLIB}"
ls -lh "${DYLIB}"
otool -L "${DYLIB}"

TEST_BIN="${BUILD_DIR}/test_simulst_inference"
if [ -f "${TEST_BIN}" ]; then
  echo "Test binary: ${TEST_BIN}"
  ls -lh "${TEST_BIN}"
fi

PLUGIN_DIR="${SCRIPT_DIR}/flutter/simulst_macos/macos"
mkdir -p "${PLUGIN_DIR}"
cp "${DYLIB}" "${PLUGIN_DIR}/"
echo "Copied to ${PLUGIN_DIR}/libsimulst.dylib"
