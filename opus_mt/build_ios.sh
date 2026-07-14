#!/bin/bash
# Build libopus_mt.a for iOS (static library + xcframework).
#
# Prerequisites:
#   brew install cmake nlohmann-json
#
# ONNX Runtime for iOS will be auto-downloaded if not found.
#
# Usage:
#   ./build_ios.sh
#
# Output:
#   opus_mt/flutter/opus_mt_macos/ios/opus_mt.xcframework/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSRC_DIR="${SCRIPT_DIR}/csrc"
BUILD_DIR="${SCRIPT_DIR}/build-ios"
FLUTTER_IOS_DIR="${SCRIPT_DIR}/flutter/opus_mt_macos/ios"

ONNXRUNTIME_VERSION="${OPUS_MT_ONNXRUNTIME_VERSION:-1.27.0}"
SHERPA_ONNX_DIR="${SCRIPT_DIR}/../sherpa-onnx"
TOOLCHAIN_FILE="${SHERPA_ONNX_DIR}/toolchains/ios.toolchain.cmake"

if [ ! -f "${TOOLCHAIN_FILE}" ]; then
  echo "ERROR: iOS toolchain not found at ${TOOLCHAIN_FILE}"
  exit 1
fi

# ---- Download ONNX Runtime for iOS if needed ---------------------------------
ORT_DIR="${SHERPA_ONNX_DIR}/build-ios/ios-onnxruntime"
ORT_XCFRAMEWORK="${ORT_DIR}/onnxruntime.xcframework"

if [ ! -d "${ORT_XCFRAMEWORK}" ]; then
  echo "Downloading ONNX Runtime v${ONNXRUNTIME_VERSION} for iOS..."
  mkdir -p "${ORT_DIR}"
  pushd "${ORT_DIR}"
  ORT_ZIP="onnxruntime-ios-static-xcframework-${ONNXRUNTIME_VERSION}.zip"
  wget -c "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v${ONNXRUNTIME_VERSION}/${ORT_ZIP}"
  unzip -o "${ORT_ZIP}"
  rm "${ORT_ZIP}"
  mv onnxruntime-ios-static-xcframework-${ONNXRUNTIME_VERSION}/onnxruntime.xcframework .
  rmdir onnxruntime-ios-static-xcframework-${ONNXRUNTIME_VERSION}
  popd
  echo "ONNX Runtime xcframework ready at ${ORT_XCFRAMEWORK}"
fi

# ---- Helper: get ONNX Runtime paths for a given platform ---------------------
get_ort_paths() {
  local platform="$1"  # ios-arm64 or ios-arm64_x86_64-simulator
  local framework="${ORT_XCFRAMEWORK}/${platform}/onnxruntime.framework"
  echo "${framework}/Headers ${framework}/onnxruntime"
}

# ---- Build target ------------------------------------------------------------
build_target() {
  local platform="$1"      # SIMULATOR64, SIMULATORARM64, or OS64
  local build_subdir="$2"  # output subdirectory name
  local ort_platform="$3"  # ios-arm64_x86_64-simulator or ios-arm64

  echo ""
  echo "========================================"
  echo "Building for ${platform} (${build_subdir})"
  echo "========================================"

  # Get ONNX Runtime paths for this platform.
  if [ "${platform}" = "OS64" ]; then
    local ort_fw="${ORT_XCFRAMEWORK}/ios-arm64/onnxruntime.framework"
  else
    local ort_fw="${ORT_XCFRAMEWORK}/ios-arm64_x86_64-simulator/onnxruntime.framework"
  fi

  local ort_include="${ort_fw}/Headers"
  local ort_lib="${ort_fw}/onnxruntime"

  echo "ONNX Runtime include: ${ort_include}"
  echo "ONNX Runtime lib:     ${ort_lib}"

  cmake "${CSRC_DIR}" \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}" \
    -DPLATFORM="${platform}" \
    -DENABLE_BITCODE=0 \
    -DENABLE_ARC=1 \
    -DENABLE_VISIBILITY=1 \
    -DCMAKE_BUILD_TYPE=Release \
    -DOPUS_MT_BUILD_SHARED=ON \
    -DOPUS_MT_USE_SENTENCEPIECE=OFF \
    -DONNXRUNTIME_INCLUDE_DIR="${ort_include}" \
    -DONNXRUNTIME_LIB="${ort_lib}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -B "build-${build_subdir}"

  cmake --build "build-${build_subdir}" -j$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

  echo "Done: build-${build_subdir}/libopus_mt.dylib"
}

# ---- Main build --------------------------------------------------------------

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Build for simulator (x86_64) — only if not already built
if [ ! -f build-sim_x86_64/libopus_mt.dylib ]; then
  build_target "SIMULATOR64" "sim_x86_64" "ios-arm64_x86_64-simulator"
else
  echo "Skip building for simulator (x86_64)"
fi

# Build for simulator (arm64)
if [ ! -f build-sim_arm64/libopus_mt.dylib ]; then
  build_target "SIMULATORARM64" "sim_arm64" "ios-arm64_x86_64-simulator"
else
  echo "Skip building for simulator (arm64)"
fi

# Build for device (arm64)
if [ ! -f build-os64/libopus_mt.dylib ]; then
  build_target "OS64" "os64" "ios-arm64"
else
  echo "Skip building for arm64 device"
fi

# ---- Bundle into xcframework ------------------------------------------------

echo ""
echo "========================================"
echo "Creating xcframework"
echo "========================================"

# Prepare staging directories
rm -rf ios-arm64 ios-arm64_x86_64-simulator ios-arm64-simulator ios-x86_64-simulator
mkdir -p ios-arm64 ios-arm64-simulator ios-x86_64-simulator

# Copy the dynamic libraries
cp build-os64/libopus_mt.dylib ios-arm64/libopus_mt.dylib
cp build-sim_arm64/libopus_mt.dylib ios-arm64-simulator/libopus_mt.dylib
cp build-sim_x86_64/libopus_mt.dylib ios-x86_64-simulator/libopus_mt.dylib

# Combine simulator slices using lipo
echo "Creating universal binary for simulator..."
mkdir -p ios-arm64_x86_64-simulator
lipo -create \
  ios-arm64-simulator/libopus_mt.dylib \
  ios-x86_64-simulator/libopus_mt.dylib \
  -output ios-arm64_x86_64-simulator/libopus_mt.dylib

# Clean up temp simulator directories
rm -rf ios-arm64-simulator ios-x86_64-simulator

# Create framework bundles
create_framework() {
  local dir="$1"
  local name="$2"
  pushd "${dir}"
  rm -rf "${name}.framework"
  mkdir "${name}.framework"
  cp "libopus_mt.dylib" "${name}.framework/${name}"

  # Fix the dynamic library identity
  install_name_tool -id "@rpath/${name}.framework/${name}" "${name}.framework/${name}"

  # Under iOS, dynamic libraries inside a framework must be executable
  chmod +x "${name}.framework/${name}"

  cat > "${name}.framework/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${name}</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleSupportedPlatforms</key>
  <array><string>iPhoneOS</string></array>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleExecutable</key>
  <string>${name}</string>
  <key>MinimumOSVersion</key>
  <string>14.0</string>
  <key>CFBundleIdentifier</key>
  <string>com.voicehub.opus-mt</string>
  <key>CFBundleSignature</key>
  <string>????</string>
</dict>
</plist>
PLIST

  popd
}

create_framework "ios-arm64" "opus_mt"
create_framework "ios-arm64_x86_64-simulator" "opus_mt"

# Create xcframework
rm -rf opus_mt.xcframework
xcodebuild -create-xcframework \
  -framework ios-arm64/opus_mt.framework \
  -framework ios-arm64_x86_64-simulator/opus_mt.framework \
  -output opus_mt.xcframework

echo "xcframework created at: ${BUILD_DIR}/opus_mt.xcframework"

# ---- Copy to Flutter plugin --------------------------------------------------

mkdir -p "${FLUTTER_IOS_DIR}"
rm -rf "${FLUTTER_IOS_DIR}/opus_mt.xcframework"
cp -R opus_mt.xcframework "${FLUTTER_IOS_DIR}/"

echo ""
echo "========================================"
echo "Build succeeded!"
echo "xcframework: ${FLUTTER_IOS_DIR}/opus_mt.xcframework"
echo "========================================"
