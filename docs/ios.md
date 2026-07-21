<h2 id="english">🇬🇧 English</h2>

# iOS App Build and Packaging Guide

This document covers the complete iOS build, signing, packaging, and distribution workflow for the VoiceHub Flutter project.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Project Architecture Overview](#2-project-architecture-overview)
3. [Compiling C++ Native Libraries (xcframework)](#3-compiling-c-native-libraries-xcframework)
   - [3.1 Compiling llama.cpp](#31-compiling-llamacpp)
   - [3.2 Compiling opus_mt](#32-compiling-opus_mt)
   - [3.3 Compiling sherpa-onnx](#33-compiling-sherpa-onnx)
   - [3.4 Coexistence of Static and Dynamic Libraries](#34-coexistence-of-static-and-dynamic-libraries)
4. [Building the Flutter iOS App](#4-building-the-flutter-ios-app)
5. [Code Signing Configuration](#5-code-signing-configuration)
6. [Packaging IPA](#6-packaging-ipa)
7. [Deploying to Device](#7-deploying-to-device)
8. [Distributing to App Store](#8-distributing-to-app-store)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Prerequisites

Before starting, ensure that the following tools are installed on your macOS machine:

```bash
# Xcode (includes iOS SDK, Simulator, and Command Line Tools)
# Install from the App Store: https://apps.apple.com/app/xcode/id497799835

# Flutter SDK
# Installation guide: https://docs.flutter.dev/get-started/install/macos

# Homebrew (used to install build dependencies)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# CMake and nlohmann-json (required for compiling C++ libraries)
brew install cmake nlohmann-json

# CocoaPods (Flutter iOS dependency manager)
sudo gem install cocoapods

# Verify environment
flutter doctor
```

Make sure there are no errors in the iOS section of the `flutter doctor` output.

---

## 2. Project Architecture Overview

The VoiceHub iOS App is composed of the following components:

```text
VoiceHub/
├── voice_app/                          # Main Flutter project
│   ├── lib/                            # Dart source code
│   ├── ios/                            # iOS platform code
│   │   ├── Runner.xcworkspace          # Xcode workspace (entry point)
│   │   ├── Podfile                     # CocoaPods dependency configuration
│   │   └── Runner/                     # App entry point & resources
│   └── pubspec.yaml                    # Flutter dependencies declaration
├── llama/                              # llama.cpp LLM module
│   ├── csrc/                           # C++ source code (FFI interface)
│   ├── build_ios.sh                    # iOS xcframework build script
│   └── flutter/llamacpp_macos/
│       ├── ios/                        # iOS plugin (podspec + xcframework)
│       │   ├── llamacpp_macos.podspec
│       │   ├── Classes/                # Force-link registration
│       │   └── llamacpp_nmt.xcframework/
│       └── lib/                        # Dart FFI bindings
├── opus_mt/                            # opus-mt NMT module
│   ├── csrc/                           # C++ source code (FFI interface)
│   ├── build_ios.sh                    # iOS xcframework build script
│   └── flutter/opus_mt_macos/
│       ├── ios/                        # iOS plugin (podspec + xcframework)
│       │   ├── opus_mt_macos.podspec
│       │   ├── Classes/                # Force-link registration
│       │   └── opus_mt.xcframework/
│       └── lib/                        # Dart FFI bindings
└── sherpa-onnx/                        # sherpa-onnx (ASR/TTS, iOS toolchain)
    └── toolchains/
        └── ios.toolchain.cmake         # iOS cross-compilation toolchain
```

### Key Points

| Component | iOS Support Method | Library Type |
|------|-------------|--------|
| **sherpa-onnx** | Flutter Plugin (`sherpa_onnx_ios`) | xcframework |
| **llama.cpp** | FFI Plugin (`llamacpp_macos`) — The same plugin supports macOS/iOS | `llamacpp_nmt.xcframework` |
| **opus_mt** | FFI Plugin (`opus_mt_macos`) — The same plugin supports macOS/iOS | `opus_mt.xcframework` |

> **Note:** Although `llamacpp_macos` and `opus_mt_macos` have `_macos` in their names, they both declare `ios: ffiPlugin: true`, thus they are also used as iOS plugins. On iOS, they are loaded using `DynamicLibrary.open('FrameworkName.framework/FrameworkName')`, and on macOS, they are loaded using `DynamicLibrary.open('lib*.dylib')`.

---

## 3. Compiling C++ Native Libraries (xcframework)

If you modify the C++ code in `llama/csrc/`, `opus_mt/csrc/`, or `sherpa-onnx/sherpa-onnx/csrc/`, you need to recompile the iOS xcframework and copy it to the corresponding plugin directory.

> **Note:** If you haven't modified the C++ code, you can skip this chapter and use the existing xcframeworks in the repository.

### 3.1 Compiling llama.cpp

The `llama.cpp` module is used for LLM translation and smart chat, supporting Metal GPU acceleration.

```bash
cd llama

# Ensure the llama.cpp submodule is initialized
git submodule update --init

# Compile iOS xcframework (Device + Simulator)
./build_ios.sh
```

**Output:** `llama/flutter/llamacpp_macos/ios/llamacpp_nmt.xcframework/`

The script will automatically:
1. Compile for `SIMULATOR64` (x86_64 simulator)
2. Compile for `SIMULATORARM64` (Apple Silicon simulator)
3. Compile for `OS64` (arm64 real device)
4. Merge the simulator architectures into a universal binary using `lipo`
5. Create a framework bundle and package it as an xcframework
6. Automatically copy it to the Flutter plugin directory

**Build Parameters Description:**

| Parameter | Value | Description |
|------|---|------|
| `GGML_METAL` | `ON` | Enable Metal GPU acceleration |
| `GGML_METAL_EMBED_LIBRARY` | `ON` | Embed Metal shader into the binary |
| `GGML_OPENMP` | `OFF` | iOS does not support OpenMP, uses Accelerate instead |
| `DEPLOYMENT_TARGET` | `14.0` | Minimum iOS version |

### 3.2 Compiling opus_mt

The `opus_mt` module is used for traditional NMT machine translation and depends on ONNX Runtime.

```bash
cd opus_mt

# Compile iOS xcframework (Device + Simulator)
./build_ios.sh
```

**Output:** `opus_mt/flutter/opus_mt_macos/ios/opus_mt.xcframework/`

The script will automatically:
1. Download the ONNX Runtime iOS static xcframework (v1.27.0) (skipped if it already exists)
2. Compile for the three platforms
3. Merge and package into an xcframework
4. Automatically copy it to the Flutter plugin directory

**Build Parameters Description:**

| Parameter | Value | Description |
|------|---|------|
| `OPUS_MT_USE_SENTENCEPIECE` | `OFF` | iOS build does not depend on SentencePiece |
| Environment Variable `OPUS_MT_ONNXRUNTIME_VERSION` | `1.27.0` | Overrides the ONNX Runtime version |

### 3.3 Compiling sherpa-onnx

The `sherpa-onnx` module is used for ASR (Automatic Speech Recognition) and TTS (Text-to-Speech), depending on ONNX Runtime. On iOS, it uses a **dynamic framework** (shared libs), which is different from the `libsherpa-onnx-c-api.dylib` on macOS.

```bash
cd sherpa-onnx

# Compile iOS dynamic framework (Device + Simulator)
./build-ios-shared.sh
```

**Output:** `sherpa-onnx/build-ios-shared/sherpa_onnx.xcframework/`

The script will automatically:
1. Download the ONNX Runtime iOS static xcframework (v1.27.0) (skipped if it already exists)
2. Compile `libsherpa-onnx-c-api.dylib` for `SIMULATOR64`, `SIMULATORARM64`, and `OS64`
3. Merge simulator architectures into a universal binary using `lipo`
4. Create the `sherpa_onnx.framework` bundle (including `Info.plist`, signing, and install_name_tool fixes)
5. Package it as an xcframework

**Build Parameters Description:**

| Parameter | Value | Description |
|------|---|------|
| `BUILD_SHARED_LIBS` | `ON` | iOS Flutter plugins require dynamic libraries |
| `SHERPA_ONNX_ENABLE_TTS` | `ON` | Enable TTS support |
| `SHERPA_ONNX_ENABLE_C_API` | `ON` | Enable C API (required for FFI bindings) |
| `DEPLOYMENT_TARGET` | `13.0` | Minimum iOS version |

> ⚠️ **CRITICAL:** The sherpa-onnx iOS plugin (`sherpa_onnx_ios`) is published via pub.dev. Even if your `pubspec.yaml` uses a local path dependency for `sherpa_onnx`, the CocoaPods plugin on iOS still loads from the **pub cache** (path: `~/.pub-cache/hosted/pub.dev/sherpa_onnx_ios-{version}/`), not from the local project directory.

**After compiling, it must be manually copied to the pub cache:**

```bash
# Compile
cd sherpa-onnx && ./build-ios-shared.sh

# Copy to pub cache (replace version number accordingly)
PUB_CACHE_DIR="$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_ios-1.13.4"
rm -rf "$PUB_CACHE_DIR/ios/sherpa_onnx.xcframework"
cp -R build-ios-shared/sherpa_onnx.xcframework "$PUB_CACHE_DIR/ios/"

# Clean the Flutter build cache and recompile
cd ../voice_app
rm -rf build/ios/
flutter build ios --debug
```

> If you don't clean `build/ios/`, Xcode may use the cached `XCFrameworkIntermediates`, resulting in the old framework still being packaged into the app.

### 3.4 Coexistence of Static and Dynamic Libraries

The `sherpa-onnx` repository provides two iOS build scripts:

| Script | Artifact | Purpose |
|------|------|------|
| `build-ios.sh` | Static library `libsherpa-onnx.a` (xcframework) | Statically linked by the voice_engine module |
| `build-ios-shared.sh` | Dynamic framework `sherpa_onnx.framework` (xcframework) | Dynamically loaded via Flutter plugin FFI |

If you modified the C++ code, both scripts need to be run because the `voice_engine` module also depends on sherpa-onnx:

```bash
cd sherpa-onnx
./build-ios.sh          # Static library for voice_engine
./build-ios-shared.sh   # Dynamic framework for Flutter FFI plugin
cd ../voice_engine
./build_ios.sh          # voice_engine xcframework
```

---

## 4. Building the Flutter iOS App

### 4.1 Install Dependencies

```bash
cd voice_app

# Get Flutter dependencies
flutter pub get

# Install CocoaPods dependencies
cd ios
pod install
cd ..
```

### 4.2 Build Runner.app (Without Signing)

Verify whether the project can compile successfully (Apple Developer account is not required):

```bash
flutter build ios --no-codesign
```

Output on successful build: `build/ios/iphoneos/Runner.app`

### 4.3 Build Runner.app (Requires Signing)

```bash
flutter build ios
```

This command automatically handles code signing (requires configuration in Xcode first, see the next chapter).

---

## 5. Code Signing Configuration

### 5.1 Automatic Signing (Recommended)

```bash
# Open project in Xcode
cd voice_app
open ios/Runner.xcworkspace
```

In Xcode:
1. Select the **Runner** project in the left project navigator → **Runner** target
2. Select the **Signing & Capabilities** tab
3. Check **Automatically manage signing**
4. Choose your Apple Developer account from the **Team** dropdown menu
5. Ensure the **Bundle Identifier** is unique (e.g., `com.yourcompany.voiceApp`)

### 5.2 Manual Signing (CI/Teams)

If you need to manually configure the signing certificate and Provisioning Profile:

1. Create an App ID and Profile in the [Apple Developer Portal](https://developer.apple.com/account/)
2. Uncheck "Automatically manage signing" in the Xcode Signing & Capabilities tab
3. Manually select the corresponding Provisioning Profile

### 5.3 Configure Signing via Environment Variables (CI Friendly)

Create or edit `ExportOptions.plist` in the `ios/Flutter/` directory:

```bash
cat > ios/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF
```

---

## 6. Packaging IPA

### 6.1 IPA Export Methods

| Command | Purpose | Target Audience |
|------|------|---------|
| `flutter build ipa` | App Store Submission | All users (via App Store) |
| `flutter build ipa --export-method=ad-hoc` | Ad-Hoc Distribution | Registered devices (up to 100) |
| `flutter build ipa --export-method=development` | Development Distribution | Development team member devices |
| `flutter build ipa --export-method=enterprise` | Enterprise Internal Distribution | Internal company employees |

### 6.2 Build App Store IPA

```bash
cd voice_app

# Build IPA (default is --export-method=app-store)
flutter build ipa
```

Output on successful build:

```text
build/ios/ipa/
├── Runner.ipa              # IPA file
├── ExportOptions.plist     # Export configuration
└── ... (Symbol files, etc.)
```

### 6.3 Build Ad-Hoc IPA (For Testing Distribution)

```bash
cd voice_app
flutter build ipa --export-method=ad-hoc
```

Ad-Hoc IPAs can be distributed via the following methods:
- **Firebase App Distribution**
- **TestFlight** (Recommended to upload directly using the App Store method)
- **Pgyer / fir.im** (or other similar platforms)
- **Drag directly into Apple Configurator** to install on a device

### 6.4 View IPA Information

```bash
# Check IPA size
ls -lh build/ios/ipa/Runner.ipa

# Unzip to view contents (Optional)
unzip -l build/ios/ipa/Runner.ipa
```

### 6.5 Summary of Build Options

```bash
# Combined build options
flutter build ipa \
  --export-method=app-store \     # Export method
  --target=lib/main.dart \        # Entry file
  --flavor=prod \                 # Flavor (if configured)
  --dart-define=ENV=production \  # Compile-time environment variables
  --release                       # Release mode (default)
```

---

## 7. Deploying to Device

### 7.1 Deploy Directly via USB/WiFi

```bash
# List connected devices
flutter devices

# Deploy to specific iOS device (WiFi connection example)
flutter run -d 00008120-XXXX

# Deploy using Release mode
flutter run --release -d 00008120-XXXX
```

### 7.2 Deploy via Xcode

```bash
open ios/Runner.xcworkspace
```

In Xcode:
1. Select the target device (your iPhone) at the top
2. Press `Cmd+R` or click the ▶️ Run button

### 7.3 Install via IPA

**Method A — Using Apple Configurator:**
1. Install [Apple Configurator](https://apps.apple.com/app/apple-configurator/id1037126344) on your Mac
2. Connect your iPhone to the Mac
3. Drag the IPA file into the device interface of Apple Configurator

**Method B — Using `ideviceinstaller`:**
```bash
brew install ideviceinstaller
ideviceinstaller install build/ios/ipa/voice_app.ipa
```

---

## 8. Distributing to App Store

### 8.1 Preparation

1. **Apple Developer Program** membership ($99/year)
2. Create an App record in [App Store Connect](https://appstoreconnect.apple.com/)
3. Prepare the App icon, screenshots, description, and other metadata

### 8.2 Uploading the IPA

**Method A — Via Xcode:**

```bash
open ios/Runner.xcworkspace
```

Menu: **Product → Archive** → Select **Distribute App** in the pop-up Organizer window

**Method B — Via Command Line (fastlane):**

```bash
# Install fastlane
brew install fastlane

# Build and upload
flutter build ipa
xcrun altool --upload-app \
  --type ios \
  --file build/ios/ipa/Runner.ipa \
  --username "your@email.com" \
  --password "app-specific-password"
```

> **Tip:** An app-specific password needs to be generated at [appleid.apple.com](https://appleid.apple.com/).

**Method C — Via Transporter:**
1. Install [Transporter](https://apps.apple.com/app/transporter/id1450874784) from the Mac App Store
2. Drag `Runner.ipa` into Transporter
3. Click **Deliver**

### 8.3 Post-Upload

1. Complete the App information in App Store Connect
2. Submit for Review
3. Publish once approved

---

## 9. Troubleshooting

### 9.1 `pod install` Fails

```bash
# Clean CocoaPods cache and retry
cd voice_app/ios
rm -rf Pods Podfile.lock
pod cache clean --all
pod install
```

### 9.2 Signing Error: "Signing for Runner requires a development team"

Open `ios/Runner.xcworkspace` in Xcode, and select a Team for the Runner target.

### 9.3 Missing xcframework / Undefined Symbols

Ensure that `build_ios.sh` for the respective modules has been run:

```bash
cd llama && ./build_ios.sh
cd opus_mt && ./build_ios.sh
```

Then clear the Flutter cache and rebuild:

```bash
cd voice_app
flutter clean
flutter pub get
cd ios && pod install && cd ..
flutter build ios
```

### 9.4 sherpa-onnx C++ Modifications Not Taking Effect

If you modified the code in `sherpa-onnx/sherpa-onnx/csrc/` but the iOS device is still running the old logic, check:

1. **Ensure the correct build script was used:**
   ```bash
   cd sherpa-onnx && ./build-ios-shared.sh
   ```
   Dynamic frameworks require `build-ios-shared.sh`, not `build-ios.sh`.

2. **Ensure the framework has been copied to the pub cache:**
   ```bash
   # Check the source path in the pub cache
   strings ~/.pub-cache/hosted/pub.dev/sherpa_onnx_ios-1.13.4/ios/sherpa_onnx.xcframework/ios-arm64/sherpa_onnx.framework/sherpa_onnx \
     | grep "offline-tts-vits-model-config"
   ```
   - If it shows `/Users/runner/work/...` (CI path) → It means the old version from pub.dev is still being used, and needs to be re-copied.
   - If it shows a local path (e.g., `/VoiceHub/...`) → The locally compiled version is in use.

3. **Clean Xcode cache and rebuild:**
   ```bash
   cd voice_app
   rm -rf build/ios/
   flutter build ios --debug
   ```

4. **Full clean (Last resort):**
   ```bash
   cd voice_app
   flutter clean
   rm -rf ios/Pods ios/Podfile.lock
   flutter pub get
   cd ios && pod install && cd ..
   flutter build ios --debug
   ```

### 9.5 Swift Package Manager Warnings

```text
The following plugins do not support Swift Package Manager for ios:
  - audioplayers_darwin
  - llamacpp_macos
  - opus_mt_macos
  - sherpa_onnx_ios
```

This is a non-fatal warning; plugins still work perfectly via CocoaPods. Future Flutter versions may require plugins to migrate to SPM, but it does not affect the build right now.

### 9.6 Simulator vs Real Device Architecture Mismatch

The xcframework already includes both `ios-arm64` (real device) and `ios-arm64_x86_64-simulator` (simulator) architectures. If you encounter architecture errors, verify:

```bash
# Check the architecture info of the xcframework
xcodebuild -runFirstLaunch
xcrun vtool -show-build llama/flutter/llamacpp_macos/ios/llamacpp_nmt.xcframework/ios-arm64/llamacpp_nmt.framework/llamacpp_nmt
```

### 9.7 Minimum iOS Version

The project supports iOS 14.0 at minimum (defined in `ios/Podfile`). If you need to modify it:

```ruby
# ios/Podfile
platform :ios, '14.0'   # Modify this line
```

Also, ensure consistency in Xcode under Runner target → General → Minimum Deployments.

### 9.8 Build Fails with `Bitcode` Error

The xcframeworks are compiled using `ENABLE_BITCODE=0`. Xcode 14+ has deprecated Bitcode. If your project does not need Bitcode, ensure in Xcode:

- Runner target → Build Settings → **Enable Bitcode** = `NO`

### 9.9 First Build is Very Slow

The initial iOS build requires compiling the Flutter engine and all dependencies, which may take 5-15 minutes. Subsequent incremental builds will be much faster.

---

## Quick Reference

```bash
# ==== Complete Build Workflow ====

# 1. Compile C++ Native Libraries (only needed after modifying C++ code)
cd llama && ./build_ios.sh && cd ..
cd opus_mt && ./build_ios.sh && cd ..
cd sherpa-onnx && ./build-ios.sh && ./build-ios-shared.sh && cd ..

# 1b. Copy sherpa-onnx dynamic framework to pub cache
PUB_CACHE_DIR="$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_ios-1.13.4"
rm -rf "$PUB_CACHE_DIR/ios/sherpa_onnx.xcframework"
cp -R sherpa-onnx/build-ios-shared/sherpa_onnx.xcframework "$PUB_CACHE_DIR/ios/"

# 1c. If voice_engine or its dependent sherpa-onnx static library is modified
cd voice_engine && ./build_ios.sh && cd ..

# 2. Build the Flutter iOS App
cd voice_app
flutter clean
flutter pub get
cd ios && pod install && cd ..

# 3. Build and Package
flutter build ipa    # App Store
# flutter build ipa --export-method=ad-hoc  # Ad-Hoc testing

# 4. Output Location
open build/ios/ipa/
```

---

<h2 id="简体中文">🇨🇳 简体中文</h2>

# iOS App 构建与打包指南

本文档涵盖 VoiceHub Flutter 项目的完整 iOS 构建、签名、打包与分发流程。

---

## 目录

1. [前置依赖](#1-前置依赖)
2. [项目架构概览](#2-项目架构概览)
3. [编译 C++ 原生库 (xcframework)](#3-编译-c-原生库-xcframework)
   - [3.1 编译 llama.cpp](#31-编译-llamacpp)
   - [3.2 编译 opus_mt](#32-编译-opus_mt)
4. [构建 Flutter iOS App](#4-构建-flutter-ios-app)
5. [代码签名配置](#5-代码签名配置)
6. [打包 IPA](#6-打包-ipa)
7. [部署到设备](#7-部署到设备)
8. [分发到 App Store](#8-分发到-app-store)
9. [常见问题排查](#9-常见问题排查)

---

## 1. 前置依赖

在开始之前，确保你的 macOS 机器上已安装以下工具：

```bash
# Xcode (含 iOS SDK, 模拟器, 命令行工具)
# 从 App Store 安装: https://apps.apple.com/app/xcode/id497799835

# Flutter SDK
# 安装指南: https://docs.flutter.dev/get-started/install/macos

# Homebrew (用于安装编译依赖)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# CMake 和 nlohmann-json (编译 C++ 库所需)
brew install cmake nlohmann-json

# CocoaPods (Flutter iOS 依赖管理)
sudo gem install cocoapods

# 验证环境
flutter doctor
```

确保 `flutter doctor` 输出中 iOS 部分没有错误。

---

## 2. 项目架构概览

VoiceHub iOS App 由以下组件构成：

```
VoiceHub/
├── voice_app/                          # Flutter 主项目
│   ├── lib/                            # Dart 源码
│   ├── ios/                            # iOS 平台代码
│   │   ├── Runner.xcworkspace          # Xcode 工作空间 (入口)
│   │   ├── Podfile                     # CocoaPods 依赖配置
│   │   └── Runner/                     # App 入口 & 资源
│   └── pubspec.yaml                    # Flutter 依赖声明
├── llama/                              # llama.cpp LLM 模块
│   ├── csrc/                           # C++ 源码 (FFI 接口)
│   ├── build_ios.sh                    # iOS xcframework 编译脚本
│   └── flutter/llamacpp_macos/
│       ├── ios/                        # iOS 插件 (podspec + xcframework)
│       │   ├── llamacpp_macos.podspec
│       │   ├── Classes/                # Force-link 注册
│       │   └── llamacpp_nmt.xcframework/
│       └── lib/                        # Dart FFI 绑定
├── opus_mt/                            # opus-mt NMT 模块
│   ├── csrc/                           # C++ 源码 (FFI 接口)
│   ├── build_ios.sh                    # iOS xcframework 编译脚本
│   └── flutter/opus_mt_macos/
│       ├── ios/                        # iOS 插件 (podspec + xcframework)
│       │   ├── opus_mt_macos.podspec
│       │   ├── Classes/                # Force-link 注册
│       │   └── opus_mt.xcframework/
│       └── lib/                        # Dart FFI 绑定
└── sherpa-onnx/                        # sherpa-onnx (ASR/TTS, iOS toolchain)
    └── toolchains/
        └── ios.toolchain.cmake         # iOS 交叉编译工具链
```

### 关键点

| 组件 | iOS 支持方式 | 库类型 |
|------|-------------|--------|
| **sherpa-onnx** | Flutter 插件 (`sherpa_onnx_ios`) | xcframework |
| **llama.cpp** | FFI 插件 (`llamacpp_macos`) — 同名插件同时支持 macOS/iOS | `llamacpp_nmt.xcframework` |
| **opus_mt** | FFI 插件 (`opus_mt_macos`) — 同名插件同时支持 macOS/iOS | `opus_mt.xcframework` |

> **注意：** `llamacpp_macos` 和 `opus_mt_macos` 虽然名字带有 `_macos`，但它们同时声明了 `ios: ffiPlugin: true`，因此也作为 iOS 插件使用。iOS 上使用 `DynamicLibrary.open('FrameworkName.framework/FrameworkName')` 加载，macOS 上使用 `DynamicLibrary.open('lib*.dylib')` 加载。

---

## 3. 编译 C++ 原生库 (xcframework)

如果你修改了 `llama/csrc/`、`opus_mt/csrc/` 或 `sherpa-onnx/sherpa-onnx/csrc/` 中的 C++ 代码，需要重新编译 iOS xcframework 并拷贝到对应插件目录。

> **注意：** 如果你没有修改 C++ 代码，可以直接跳过本章，使用仓库中已有的 xcframework。

### 3.1 编译 llama.cpp

`llama.cpp` 模块用于 LLM 翻译和智能对话，支持 Metal GPU 加速。

```bash
cd llama

# 确保 llama.cpp 子模块已初始化
git submodule update --init

# 编译 iOS xcframework (设备 + 模拟器)
./build_ios.sh
```

**输出：** `llama/flutter/llamacpp_macos/ios/llamacpp_nmt.xcframework/`

脚本会自动：
1. 为 `SIMULATOR64` (x86_64 模拟器) 编译
2. 为 `SIMULATORARM64` (Apple Silicon 模拟器) 编译
3. 为 `OS64` (arm64 真机) 编译
4. 用 `lipo` 合并模拟器架构为通用二进制
5. 创建 framework bundle 并打包为 xcframework
6. 自动拷贝到 Flutter 插件目录

**编译参数说明：**

| 参数 | 值 | 说明 |
|------|---|------|
| `GGML_METAL` | `ON` | 启用 Metal GPU 加速 |
| `GGML_METAL_EMBED_LIBRARY` | `ON` | 将 Metal shader 嵌入二进制 |
| `GGML_OPENMP` | `OFF` | iOS 不支持 OpenMP，使用 Accelerate |
| `DEPLOYMENT_TARGET` | `14.0` | 最低 iOS 版本 |

### 3.2 编译 opus_mt

`opus_mt` 模块用于传统 NMT 机器翻译，依赖 ONNX Runtime。

```bash
cd opus_mt

# 编译 iOS xcframework (设备 + 模拟器)
./build_ios.sh
```

**输出：** `opus_mt/flutter/opus_mt_macos/ios/opus_mt.xcframework/`

脚本会自动：
1. 下载 ONNX Runtime iOS 静态 xcframework (v1.27.0)（如已存在则跳过）
2. 为三个平台编译
3. 合并、打包为 xcframework
4. 自动拷贝到 Flutter 插件目录

**编译参数说明：**

| 参数 | 值 | 说明 |
|------|---|------|
| `OPUS_MT_USE_SENTENCEPIECE` | `OFF` | iOS 编译不依赖 SentencePiece |
| 环境变量 `OPUS_MT_ONNXRUNTIME_VERSION` | `1.27.0` | 可覆盖 ONNX Runtime 版本 |

### 3.3 编译 sherpa-onnx

`sherpa-onnx` 模块用于 ASR（语音识别）和 TTS（文本转语音），依赖 ONNX Runtime。iOS 上使用**动态 framework**（shared libs），与 macOS 的 `libsherpa-onnx-c-api.dylib` 不同。

```bash
cd sherpa-onnx

# 编译 iOS 动态 framework (设备 + 模拟器)
./build-ios-shared.sh
```

**输出：** `sherpa-onnx/build-ios-shared/sherpa_onnx.xcframework/`

脚本会自动：
1. 下载 ONNX Runtime iOS 静态 xcframework (v1.27.0)（如已存在则跳过）
2. 为 `SIMULATOR64`、`SIMULATORARM64`、`OS64` 三个平台编译 `libsherpa-onnx-c-api.dylib`
3. 用 `lipo` 合并模拟器架构为通用二进制
4. 创建 `sherpa_onnx.framework` bundle（含 `Info.plist`、签名、install_name_tool 修正）
5. 打包为 xcframework

**编译参数说明：**

| 参数 | 值 | 说明 |
|------|---|------|
| `BUILD_SHARED_LIBS` | `ON` | iOS Flutter 插件需要动态库 |
| `SHERPA_ONNX_ENABLE_TTS` | `ON` | 启用 TTS 支持 |
| `SHERPA_ONNX_ENABLE_C_API` | `ON` | 启用 C API（FFI 绑定需要） |
| `DEPLOYMENT_TARGET` | `13.0` | 最低 iOS 版本 |

> ⚠️ **关键：** sherpa-onnx 的 iOS 插件 (`sherpa_onnx_ios`) 是通过 pub.dev 发布的。即使你的 `pubspec.yaml` 使用本地路径依赖 `sherpa_onnx`, iOS 的 CocoaPods 插件仍然从 **pub cache** 加载（路径：`~/.pub-cache/hosted/pub.dev/sherpa_onnx_ios-{version}/`），而非本地项目目录。

**编译后必须手动拷贝到 pub cache：**

```bash
# 编译
cd sherpa-onnx && ./build-ios-shared.sh

# 拷贝到 pub cache（替换版本号）
PUB_CACHE_DIR="$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_ios-1.13.4"
rm -rf "$PUB_CACHE_DIR/ios/sherpa_onnx.xcframework"
cp -R build-ios-shared/sherpa_onnx.xcframework "$PUB_CACHE_DIR/ios/"

# 清理 Flutter 构建缓存后重新编译
cd ../voice_app
rm -rf build/ios/
flutter build ios --debug
```

> 如果不清理 `build/ios/`，Xcode 可能使用缓存的 `XCFrameworkIntermediates`，导致旧 framework 仍然被打包进 app。

### 3.4 同时存在静态库和动态库

`sherpa-onnx` 仓库提供了两个 iOS 编译脚本：

| 脚本 | 产物 | 用途 |
|------|------|------|
| `build-ios.sh` | 静态库 `libsherpa-onnx.a` (xcframework) | voice_engine 模块静态链接 |
| `build-ios-shared.sh` | 动态 framework `sherpa_onnx.framework` (xcframework) | Flutter 插件 FFI 动态加载 |

如果你同时修改了 C++ 代码，两个脚本都需要运行，因为 `voice_engine` 模块也依赖 sherpa-onnx：

```bash
cd sherpa-onnx
./build-ios.sh          # voice_engine 用的静态库
./build-ios-shared.sh   # Flutter FFI 插件用的动态库
cd ../voice_engine
./build_ios.sh          # voice_engine xcframework
```

---

## 4. 构建 Flutter iOS App

### 4.1 安装依赖

```bash
cd voice_app

# 获取 Flutter 依赖
flutter pub get

# 安装 CocoaPods 依赖
cd ios
pod install
cd ..
```

### 4.2 构建 Runner.app (无需签名)

验证项目是否能编译通过（不需要 Apple Developer 账号）：

```bash
flutter build ios --no-codesign
```

构建成功后输出：`build/ios/iphoneos/Runner.app`

### 4.3 构建 Runner.app (需要签名)

```bash
flutter build ios
```

此命令会自动处理代码签名（需要先在 Xcode 中配置，见下一章）。

---

## 5. 代码签名配置

### 5.1 自动签名 (推荐)

```bash
# 在 Xcode 中打开项目
cd voice_app
open ios/Runner.xcworkspace
```

在 Xcode 中：
1. 左侧项目导航栏选择 **Runner** 项目 → **Runner** target
2. 选择 **Signing & Capabilities** 标签
3. 勾选 **Automatically manage signing**
4. 在 **Team** 下拉菜单中选择你的 Apple Developer 账号
5. 确保 **Bundle Identifier** 唯一（如 `com.yourcompany.voiceApp`）

### 5.2 手动签名 (CI/团队)

如果你需要手动配置签名证书和 Provisioning Profile：

1. 在 [Apple Developer Portal](https://developer.apple.com/account/) 创建 App ID 和 Profile
2. 在 Xcode 的 Signing & Capabilities 中取消勾选 "Automatically manage signing"
3. 手动选择对应的 Provisioning Profile

### 5.3 使用环境变量配置签名 (CI 友好)

在 `ios/Flutter/` 目录下创建或编辑 `ExportOptions.plist`：

```bash
cat > ios/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF
```

---

## 6. 打包 IPA

### 6.1 IPA 导出方式

| 命令 | 用途 | 目标用户 |
|------|------|---------|
| `flutter build ipa` | App Store 提交 | 所有用户 (通过 App Store) |
| `flutter build ipa --export-method=ad-hoc` | Ad-Hoc 分发 | 注册设备 (最多 100 台) |
| `flutter build ipa --export-method=development` | 开发版分发 | 开发团队成员设备 |
| `flutter build ipa --export-method=enterprise` | 企业内部分发 | 企业内部员工 |

### 6.2 构建 App Store IPA

```bash
cd voice_app

# 构建 IPA（默认 --export-method=app-store）
flutter build ipa
```

构建成功后输出：

```
build/ios/ipa/
├── Runner.ipa              # IPA 文件
├── ExportOptions.plist     # 导出配置
└── ... (符号文件等)
```

### 6.3 构建 Ad-Hoc IPA（用于测试分发）

```bash
cd voice_app
flutter build ipa --export-method=ad-hoc
```

Ad-Hoc IPA 可以通过以下方式分发：
- **Firebase App Distribution**
- **TestFlight** (推荐用 App Store 方式直接上传)
- **蒲公英 / fir.im** 等国内平台
- **直接拖入 Apple Configurator** 安装到设备

### 6.4 查看 IPA 信息

```bash
# 查看 IPA 大小
ls -lh build/ios/ipa/Runner.ipa

# 解压查看内容 (可选)
unzip -l build/ios/ipa/Runner.ipa
```

### 6.5 构建选项汇总

```bash
# 构建选项组合
flutter build ipa \
  --export-method=app-store \     # 导出方式
  --target=lib/main.dart \        # 入口文件
  --flavor=prod \                 # flavor (如有配置)
  --dart-define=ENV=production \  # 编译时环境变量
  --release                       # Release 模式 (默认)
```

---

## 7. 部署到设备

### 7.1 通过 USB/WiFi 直接部署

```bash
# 查看已连接设备
flutter devices

# 部署到指定 iOS 设备 (WiFi 连接示例)
flutter run -d 00008120-XXXX

# 使用 Release 模式部署
flutter run --release -d 00008120-XXXX
```

### 7.2 通过 Xcode 部署

```bash
open ios/Runner.xcworkspace
```

在 Xcode 中：
1. 顶部选择目标设备（你的 iPhone）
2. 按 `Cmd+R` 或点击 ▶️ 运行

### 7.3 通过 IPA 安装

**方式 A — 使用 Apple Configurator:**
1. 在 Mac 上安装 [Apple Configurator](https://apps.apple.com/app/apple-configurator/id1037126344)
2. 连接 iPhone 到 Mac
3. 将 IPA 文件拖入 Apple Configurator 的设备界面

**方式 B — 使用 `ideviceinstaller`:**
```bash
brew install ideviceinstaller
ideviceinstaller install build/ios/ipa/voice_app.ipa
```

---

## 8. 分发到 App Store

### 8.1 准备工作

1. **Apple Developer Program** 会员（$99/year）
2. 在 [App Store Connect](https://appstoreconnect.apple.com/) 创建 App 记录
3. 准备好 App 图标、截图、描述等元数据

### 8.2 上传 IPA

**方式 A — 通过 Xcode:**

```bash
open ios/Runner.xcworkspace
```

菜单: **Product → Archive** → 在弹出的 Organizer 窗口选择 **Distribute App**

**方式 B — 通过命令行 (fastlane):**

```bash
# 安装 fastlane
brew install fastlane

# 构建并上传
flutter build ipa
xcrun altool --upload-app \
  --type ios \
  --file build/ios/ipa/Runner.ipa \
  --username "your@email.com" \
  --password "app-specific-password"
```

> **提示：** App 专用密码需要在 [appleid.apple.com](https://appleid.apple.com/) 生成。

**方式 C — 通过 Transporter:**
1. 从 Mac App Store 安装 [Transporter](https://apps.apple.com/app/transporter/id1450874784)
2. 将 `Runner.ipa` 拖入 Transporter
3. 点击 **Deliver**

### 8.3 上传后

1. 在 App Store Connect 中完成 App 信息
2. 提交审核 (Submit for Review)
3. 审核通过后发布

---

## 9. 常见问题排查

### 9.1 `pod install` 失败

```bash
# 清除 CocoaPods 缓存后重试
cd voice_app/ios
rm -rf Pods Podfile.lock
pod cache clean --all
pod install
```

### 9.2 签名错误: "Signing for Runner requires a development team"

在 Xcode 中打开 `ios/Runner.xcworkspace`，为 Runner target 选择一个 Team。

### 9.3 找不到 xcframework / 符号未定义

确保已运行对应模块的 `build_ios.sh`：

```bash
cd llama && ./build_ios.sh
cd opus_mt && ./build_ios.sh
```

然后清理 Flutter 缓存重新构建：

```bash
cd voice_app
flutter clean
flutter pub get
cd ios && pod install && cd ..
flutter build ios
```

### 9.4 sherpa-onnx C++ 修改后未生效

如果你修改了 `sherpa-onnx/sherpa-onnx/csrc/` 中的代码但 iOS 设备上仍运行旧逻辑，检查：

1. **确认使用了正确的编译脚本：**
   ```bash
   cd sherpa-onnx && ./build-ios-shared.sh
   ```
   动态 framework 需要 `build-ios-shared.sh`，不是 `build-ios.sh`。

2. **确认 framework 已拷贝到 pub cache：**
   ```bash
   # 检查 pub cache 中的 source path
   strings ~/.pub-cache/hosted/pub.dev/sherpa_onnx_ios-1.13.4/ios/sherpa_onnx.xcframework/ios-arm64/sherpa_onnx.framework/sherpa_onnx \
     | grep "offline-tts-vits-model-config"
   ```
   - 如果是 `/Users/runner/work/...`（CI 路径）→ 说明还在用 pub.dev 上的旧版本，需要重新拷贝
   - 如果是本地路径（如 `/VoiceHub/...`）→ 已使用本地编译版本

3. **清理 Xcode 缓存后重建：**
   ```bash
   cd voice_app
   rm -rf build/ios/
   flutter build ios --debug
   ```

4. **完全清理（最后手段）：**
   ```bash
   cd voice_app
   flutter clean
   rm -rf ios/Pods ios/Podfile.lock
   flutter pub get
   cd ios && pod install && cd ..
   flutter build ios --debug
   ```

### 9.5 Swift Package Manager 警告

```
The following plugins do not support Swift Package Manager for ios:
  - audioplayers_darwin
  - llamacpp_macos
  - opus_mt_macos
  - sherpa_onnx_ios
```

这是非致命警告，插件仍通过 CocoaPods 正常工作。后续 Flutter 版本可能要求插件迁移到 SPM，但目前不影响构建。

### 9.6 模拟器 vs 真机架构不匹配

xcframework 已包含 `ios-arm64`（真机）和 `ios-arm64_x86_64-simulator`（模拟器）两种架构。如果遇到架构错误，确认：

```bash
# 检查 xcframework 的架构信息
xcodebuild -runFirstLaunch
xcrun vtool -show-build llama/flutter/llamacpp_macos/ios/llamacpp_nmt.xcframework/ios-arm64/llamacpp_nmt.framework/llamacpp_nmt
```

### 9.7 最低 iOS 版本

项目最低支持 iOS 14.0（在 `ios/Podfile` 中定义）。如果需要修改：

```ruby
# ios/Podfile
platform :ios, '14.0'   # 修改此行
```

同时在 Xcode 中 Runner target → General → Minimum Deployments 保持一致。

### 9.8 构建报 `Bitcode` 错误

xcframework 已使用 `ENABLE_BITCODE=0` 编译。Xcode 14+ 已弃用 Bitcode，如果你的项目不需要 Bitcode，在 Xcode 中确保：

- Runner target → Build Settings → **Enable Bitcode** = `NO`

### 9.9 首次构建很慢

iOS 首次构建需要编译 Flutter engine 和所有依赖，预计耗时 5-15 分钟。后续增量构建会快很多。

---

## 快速参考

```bash
# ==== 完整构建流程 ====

# 1. 编译 C++ 原生库 (仅在修改 C++ 代码后需要)
cd llama && ./build_ios.sh && cd ..
cd opus_mt && ./build_ios.sh && cd ..
cd sherpa-onnx && ./build-ios.sh && ./build-ios-shared.sh && cd ..

# 1b. 拷贝 sherpa-onnx 动态 framework 到 pub cache
PUB_CACHE_DIR="$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_ios-1.13.4"
rm -rf "$PUB_CACHE_DIR/ios/sherpa_onnx.xcframework"
cp -R sherpa-onnx/build-ios-shared/sherpa_onnx.xcframework "$PUB_CACHE_DIR/ios/"

# 1c. 如果修改了 voice_engine 或其依赖的 sherpa-onnx 静态库
cd voice_engine && ./build_ios.sh && cd ..

# 2. 构建 Flutter iOS App
cd voice_app
flutter clean
flutter pub get
cd ios && pod install && cd ..

# 3. 构建并打包
flutter build ipa    # App Store
# flutter build ipa --export-method=ad-hoc  # Ad-Hoc 测试

# 4. 输出位置
open build/ios/ipa/
```
