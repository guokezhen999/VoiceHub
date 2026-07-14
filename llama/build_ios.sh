#!/bin/bash
# Build libllamacpp_nmt.a for iOS (static library + xcframework).
#
# Prerequisites:
#   brew install cmake nlohmann-json
#   llama.cpp submodule must be initialized
#
# Key differences from macOS build:
#   - Static library (iOS doesn't support dylibs)
#   - OpenMP disabled (libomp not available on iOS; Accelerate used instead)
#   - Metal GPU enabled (iOS fully supports Metal)
#   - Metal shaders embedded in the binary (GGML_METAL_EMBED_LIBRARY=ON)
#
# Usage:
#   ./build_ios.sh
#
# Output:
#   llama/flutter/llamacpp_macos/ios/llamacpp_nmt.xcframework/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSRC_DIR="${SCRIPT_DIR}/csrc"
BUILD_DIR="${SCRIPT_DIR}/build-ios"
FLUTTER_IOS_DIR="${SCRIPT_DIR}/flutter/llamacpp_macos/ios"

SHERPA_ONNX_DIR="${SCRIPT_DIR}/../sherpa-onnx"
TOOLCHAIN_FILE="${SHERPA_ONNX_DIR}/toolchains/ios.toolchain.cmake"

if [ ! -f "${TOOLCHAIN_FILE}" ]; then
  echo "ERROR: iOS toolchain not found at ${TOOLCHAIN_FILE}"
  exit 1
fi

if [ ! -f "${SCRIPT_DIR}/llama.cpp/CMakeLists.txt" ]; then
  echo "ERROR: llama.cpp not found. Run: git submodule update --init"
  exit 1
fi

# ---- Build target ------------------------------------------------------------
build_target() {
  local platform="$1"      # SIMULATOR64, SIMULATORARM64, or OS64
  local build_subdir="$2"  # output subdirectory name

  echo ""
  echo "========================================"
  echo "Building for ${platform} (${build_subdir})"
  echo "========================================"

  cmake "${CSRC_DIR}" \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}" \
    -DPLATFORM="${platform}" \
    -DENABLE_BITCODE=0 \
    -DENABLE_ARC=1 \
    -DENABLE_VISIBILITY=1 \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMACPP_BUILD_SHARED=ON \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_OPENMP=OFF \
    -DDEPLOYMENT_TARGET=14.0 \
    -B "build-${build_subdir}"

  cmake --build "build-${build_subdir}" -j$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

  echo "Done: build-${build_subdir}/libllamacpp_nmt.dylib"
}

# ---- Main build --------------------------------------------------------------

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Build for simulator (x86_64)
if [ ! -f build-sim_x86_64/libllamacpp_nmt.dylib ]; then
  build_target "SIMULATOR64" "sim_x86_64"
else
  echo "Skip building for simulator (x86_64)"
fi

# Build for simulator (arm64)
if [ ! -f build-sim_arm64/libllamacpp_nmt.dylib ]; then
  build_target "SIMULATORARM64" "sim_arm64"
else
  echo "Skip building for simulator (arm64)"
fi

# Build for device (arm64)
if [ ! -f build-os64/libllamacpp_nmt.dylib ]; then
  build_target "OS64" "os64"
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
cp build-os64/libllamacpp_nmt.dylib ios-arm64/libllamacpp_nmt.dylib
cp build-sim_arm64/libllamacpp_nmt.dylib ios-arm64-simulator/libllamacpp_nmt.dylib
cp build-sim_x86_64/libllamacpp_nmt.dylib ios-x86_64-simulator/libllamacpp_nmt.dylib

# Combine simulator slices using lipo
echo "Creating universal binary for simulator..."
mkdir -p ios-arm64_x86_64-simulator
lipo -create \
  ios-arm64-simulator/libllamacpp_nmt.dylib \
  ios-x86_64-simulator/libllamacpp_nmt.dylib \
  -output ios-arm64_x86_64-simulator/libllamacpp_nmt.dylib

# Clean up temp simulator directories
rm -rf ios-arm64-simulator ios-x86_64-simulator

# Create framework bundles
create_framework() {
  local dir="$1"
  local name="$2"
  pushd "${dir}"
  rm -rf "${name}.framework"
  mkdir "${name}.framework"
  cp "libllamacpp_nmt.dylib" "${name}.framework/${name}"

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
  <string>com.voicehub.llamacpp-nmt</string>
  <key>CFBundleSignature</key>
  <string>????</string>
</dict>
</plist>
PLIST

  popd
}

create_framework "ios-arm64" "llamacpp_nmt"
create_framework "ios-arm64_x86_64-simulator" "llamacpp_nmt"

# Create xcframework
rm -rf llamacpp_nmt.xcframework
xcodebuild -create-xcframework \
  -framework ios-arm64/llamacpp_nmt.framework \
  -framework ios-arm64_x86_64-simulator/llamacpp_nmt.framework \
  -output llamacpp_nmt.xcframework

echo "xcframework created at: ${BUILD_DIR}/llamacpp_nmt.xcframework"

# ---- Copy to Flutter plugin --------------------------------------------------

mkdir -p "${FLUTTER_IOS_DIR}"
rm -rf "${FLUTTER_IOS_DIR}/llamacpp_nmt.xcframework"
cp -R llamacpp_nmt.xcframework "${FLUTTER_IOS_DIR}/"

echo ""
echo "========================================"
echo "Build succeeded!"
echo "xcframework: ${FLUTTER_IOS_DIR}/llamacpp_nmt.xcframework"
echo "========================================"
