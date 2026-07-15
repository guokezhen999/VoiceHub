#!/bin/bash
# Build libvoice_engine for iOS (dynamic library + xcframework).
#
# Prerequisites:
#   - sherpa-onnx iOS must be prebuilt (run ../sherpa-onnx/build-ios.sh):
#       ../sherpa-onnx/build-ios/sherpa-onnx.xcframework
#       ../sherpa-onnx/build-ios/ios-onnxruntime/onnxruntime.xcframework
#   - brew install cmake nlohmann-json
#
# Usage:
#   ./build_ios.sh
#
# Output:
#   voice_engine/flutter/voice_engine_macos/ios/voice_engine.xcframework/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSRC_DIR="${SCRIPT_DIR}/csrc"
BUILD_DIR="${SCRIPT_DIR}/build-ios"
FLUTTER_IOS_DIR="${SCRIPT_DIR}/flutter/voice_engine_macos/ios"

SHERPA_ONNX_DIR="${SCRIPT_DIR}/../sherpa-onnx"
TOOLCHAIN_FILE="${SHERPA_ONNX_DIR}/toolchains/ios.toolchain.cmake"
SHERPA_XCFW="${SHERPA_ONNX_DIR}/build-ios/sherpa-onnx.xcframework"
ORT_XCFW="${SHERPA_ONNX_DIR}/build-ios/ios-onnxruntime/onnxruntime.xcframework"

if [ ! -f "${TOOLCHAIN_FILE}" ]; then
  echo "ERROR: iOS toolchain not found at ${TOOLCHAIN_FILE}"
  exit 1
fi
if [ ! -d "${SHERPA_XCFW}" ]; then
  echo "ERROR: sherpa-onnx iOS xcframework not found at ${SHERPA_XCFW}"
  echo "Build sherpa-onnx for iOS first: cd ../sherpa-onnx && ./build-ios.sh"
  exit 1
fi
if [ ! -d "${ORT_XCFW}" ]; then
  echo "ERROR: onnxruntime iOS xcframework not found at ${ORT_XCFW}"
  echo "Build sherpa-onnx for iOS first (it downloads onnxruntime): cd ../sherpa-onnx && ./build-ios.sh"
  exit 1
fi

# ---- Build target ------------------------------------------------------------
# Args: <toolchain PLATFORM> <build subdir> <xcframework slice>
build_target() {
  local platform="$1"      # SIMULATOR64, SIMULATORARM64, or OS64
  local build_subdir="$2"  # output subdirectory name
  local xcfw_platform="$3" # ios-arm64 or ios-arm64_x86_64-simulator

  local sherpa_lib="${SHERPA_XCFW}/${xcfw_platform}/libsherpa-onnx.a"
  local sherpa_inc="${SHERPA_XCFW}/${xcfw_platform}/Headers/sherpa-onnx/c-api"
  local ort_fw="${ORT_XCFW}/${xcfw_platform}/onnxruntime.framework"
  local ort_inc="${ort_fw}/Headers"
  local ort_lib="${ort_fw}/onnxruntime"

  echo ""
  echo "========================================"
  echo "Building for ${platform} (${build_subdir})"
  echo "========================================"
  echo "sherpa-onnx lib:     ${sherpa_lib}"
  echo "sherpa-onnx include: ${sherpa_inc}"
  echo "onnxruntime lib:     ${ort_lib}"

  cmake "${CSRC_DIR}" \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}" \
    -DPLATFORM="${platform}" \
    -DENABLE_BITCODE=0 \
    -DENABLE_ARC=1 \
    -DENABLE_VISIBILITY=1 \
    -DCMAKE_BUILD_TYPE=Release \
    -DVOICE_ENGINE_BUILD_SHARED=ON \
    -DSHERPA_ONNX_LIB="${sherpa_lib}" \
    -DSHERPA_ONNX_INCLUDE_DIR="${sherpa_inc}" \
    -DONNXRUNTIME_LIB="${ort_lib}" \
    -DONNXRUNTIME_INCLUDE_DIR="${ort_inc}" \
    -DDEPLOYMENT_TARGET=14.0 \
    -B "build-${build_subdir}"

  cmake --build "build-${build_subdir}" -j$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

  echo "Done: build-${build_subdir}/libvoice_engine.dylib"
}

# ---- Main build --------------------------------------------------------------

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Build for simulator (x86_64)
if [ ! -f build-sim_x86_64/libvoice_engine.dylib ]; then
  build_target "SIMULATOR64" "sim_x86_64" "ios-arm64_x86_64-simulator"
else
  echo "Skip building for simulator (x86_64)"
fi

# Build for simulator (arm64)
if [ ! -f build-sim_arm64/libvoice_engine.dylib ]; then
  build_target "SIMULATORARM64" "sim_arm64" "ios-arm64_x86_64-simulator"
else
  echo "Skip building for simulator (arm64)"
fi

# Build for device (arm64)
if [ ! -f build-os64/libvoice_engine.dylib ]; then
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
cp build-os64/libvoice_engine.dylib ios-arm64/libvoice_engine.dylib
cp build-sim_arm64/libvoice_engine.dylib ios-arm64-simulator/libvoice_engine.dylib
cp build-sim_x86_64/libvoice_engine.dylib ios-x86_64-simulator/libvoice_engine.dylib

# Combine simulator slices using lipo
echo "Creating universal binary for simulator..."
mkdir -p ios-arm64_x86_64-simulator
lipo -create \
  ios-arm64-simulator/libvoice_engine.dylib \
  ios-x86_64-simulator/libvoice_engine.dylib \
  -output ios-arm64_x86_64-simulator/libvoice_engine.dylib

# Clean up temp simulator directories
rm -rf ios-arm64-simulator ios-x86_64-simulator

# Create framework bundles
create_framework() {
  local dir="$1"
  local name="$2"
  pushd "${dir}"
  rm -rf "${name}.framework"
  mkdir "${name}.framework"
  cp "libvoice_engine.dylib" "${name}.framework/${name}"

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
  <string>com.voicehub.voice-engine</string>
  <key>CFBundleSignature</key>
  <string>????</string>
</dict>
</plist>
PLIST

  popd
}

create_framework "ios-arm64" "voice_engine"
create_framework "ios-arm64_x86_64-simulator" "voice_engine"

# Create xcframework
rm -rf voice_engine.xcframework
xcodebuild -create-xcframework \
  -framework ios-arm64/voice_engine.framework \
  -framework ios-arm64_x86_64-simulator/voice_engine.framework \
  -output voice_engine.xcframework

echo "xcframework created at: ${BUILD_DIR}/voice_engine.xcframework"

# ---- Copy to Flutter plugin --------------------------------------------------

mkdir -p "${FLUTTER_IOS_DIR}"
rm -rf "${FLUTTER_IOS_DIR}/voice_engine.xcframework"
cp -R voice_engine.xcframework "${FLUTTER_IOS_DIR}/"

echo ""
echo "========================================"
echo "Build succeeded!"
echo "xcframework: ${FLUTTER_IOS_DIR}/voice_engine.xcframework"
echo "========================================"
