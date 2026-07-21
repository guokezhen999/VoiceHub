<h2 id="english">🇬🇧 English</h2>

# macOS App Build and Packaging Guide

This document covers the complete macOS compilation, native dynamic library (`.dylib`) building, Flutter app packaging, and artifact distribution process for the VoiceHub Flutter project.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Project Architecture Overview](#2-project-architecture-overview)
3. [Compile macOS C++ Native Dynamic Libraries (.dylib)](#3-compile-macos-c-native-dynamic-libraries-dylib)
   - [3.1 One-Click Build for All Native Libraries](#31-one-click-build-for-all-native-libraries)
   - [3.2 Module-Specific Compilation Guide](#32-module-specific-compilation-guide)
   - [3.3 Dynamic Library Copying and @rpath Loading Path Processing](#33-dynamic-library-copying-and-rpath-loading-path-processing)
4. [Build and Run Flutter macOS App](#4-build-and-run-flutter-macos-app)
   - [4.1 Run in Development Environment](#41-run-in-development-environment)
   - [4.2 Cache Clearing and Dependency Updates](#42-cache-clearing-and-dependency-updates)
5. [Package Release App and Distribution Bundles](#5-package-release-app-and-distribution-bundles)
   - [5.1 Build macOS .app Bundle](#51-build-macos-app-bundle)
   - [5.2 Verify App Structure and Dynamic Library Packaging](#52-verify-app-structure-and-dynamic-library-packaging)
   - [5.3 Compression and Archiving (ZIP / DMG)](#53-compression-and-archiving-zip--dmg)
6. [Troubleshooting](#6-troubleshooting)

---

## 1. Prerequisites

Before starting, please ensure your macOS system has correctly installed and configured the following basic development tools:

```bash
# 1. Install Xcode Command Line Tools
xcode-select --install

# 2. Install Homebrew package manager (if not installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 3. Install CMake and nlohmann-json via Homebrew (C++ native module dependencies)
brew install cmake nlohmann-json libomp

# 4. Install/Check Flutter SDK (Flutter >= 3.10.0 recommended)
flutter doctor
```

Ensure both **macOS toolchain** and **Xcode** are normally prompted as enabled in `flutter doctor`.

---

## 2. Project Architecture Overview

The VoiceHub macOS application consists of a Flutter frontend app and 5 core C++ native inference engine/algorithm modules:

```
VoiceHub/
├── scripts/
│   └── build_macos_all.sh             # One-click build & package script for macOS native libraries
├── voice_app/                         # Main Flutter project
│   ├── lib/                           # Dart UI and logic code
│   ├── macos/                         # macOS native App configuration (Xcode project)
│   └── build/macos/Build/Products/    # Final packaging output path
├── sherpa-onnx/                       # ASR / TTS offline speech recognition and synthesis engine
│   └── flutter/sherpa_onnx_macos/
├── llama/                             # LLM machine translation module (based on llama.cpp)
│   └── flutter/llamacpp_macos/
├── opus_mt/                           # Opus-MT neural machine translation module
│   └── flutter/opus_mt_macos/
├── voice_engine/                      # Core voice processing pipeline engine
│   └── flutter/voice_engine_macos/
└── simulst/                           # Simultaneous Translation module
    └── flutter/simulst_macos/
```

### Core Native Libraries and Flutter Plugins Mapping Table

| Module Name | Generated Dynamic Library (`.dylib`) | Flutter Plugin Name | Corresponding Plugin Directory |
|---|---|---|---|
| **sherpa-onnx** | `libsherpa-onnx-c-api.dylib`, `libonnxruntime.dylib` | `sherpa_onnx` (`sherpa_onnx_macos`) | `sherpa-onnx/flutter/sherpa_onnx_macos` |
| **llama** | `libllamacpp_nmt.dylib`, `libomp.dylib` | `llamacpp_macos` | `llama/flutter/llamacpp_macos` |
| **opus_mt** | `libopus_mt.dylib` | `opus_mt_macos` | `opus_mt/flutter/opus_mt_macos` |
| **voice_engine** | `libvoice_engine.dylib` | `voice_engine_macos` | `voice_engine/flutter/voice_engine_macos` |
| **simulst** | `libsimulst.dylib`, `libkaldi-native-fbank-core.dylib` | `simulst_macos` | `simulst/flutter/simulst_macos` |

---

## 3. Compile macOS C++ Native Dynamic Libraries (.dylib)

Before packaging or running the Flutter macOS application, you must compile the C++ native source code into `.dylib` dynamic libraries usable on the macOS platform, and embed them into the `macos/` directory of each Flutter plugin.

### 3.1 One-Click Build for All Native Libraries

VoiceHub provides a root directory script to automatically complete the compilation and copying of the 5 modules with one click:

```bash
# Grant execution permissions
chmod +x scripts/build_macos_all.sh

# Compile Release version (Recommended, better inference performance)
./scripts/build_macos_all.sh release

# Or compile Debug version
./scripts/build_macos_all.sh debug
```

### 3.2 Module-Specific Compilation Guide

If you need to modify the code of a single module and compile it separately, you can do so by following the commands below.

> [!NOTE]
> Inter-module dependency tip: `voice_engine` and `simulst` depend on the C-API header files and dynamic libraries exported by `sherpa-onnx` and `llama`. If you want to compile `voice_engine` or `simulst` separately, please make sure `sherpa-onnx` and `llama` have been compiled first.

#### (1) Compile sherpa-onnx
```bash
cd sherpa-onnx
mkdir -p build && cd build
cmake .. -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=release
cmake --build . --config release -j$(sysctl -n hw.logicalcpu)
cmake --install . --config release

# Copy the generated dynamic libraries to the macOS Flutter plugin path
mkdir -p ../flutter/sherpa_onnx_macos/macos/
cp lib/libsherpa-onnx-c-api.dylib ../flutter/sherpa_onnx_macos/macos/
cp _deps/onnxruntime-build/lib/libonnxruntime.dylib ../flutter/sherpa_onnx_macos/macos/
```

#### (2) Compile llama.cpp
```bash
cd llama
# Ensure the llama.cpp submodule has been cloned correctly (to llama/llama.cpp)
./build_macos.sh release
# The build artifacts libllamacpp_nmt.dylib and libomp.dylib will automatically fix @rpath and be copied to:
# flutter/llamacpp_macos/macos/
```

#### (3) Compile opus_mt
```bash
cd opus_mt
./build_macos.sh release
# Automatically/manually copy artifacts to plugin path:
mkdir -p flutter/opus_mt_macos/macos/
cp build/libopus_mt.dylib flutter/opus_mt_macos/macos/
```

#### (4) Compile voice_engine
```bash
cd voice_engine
./build_macos.sh release
# Automatically links sherpa-onnx and copies to:
# flutter/voice_engine_macos/macos/libvoice_engine.dylib
```

#### (5) Compile simulst
```bash
cd simulst
./build_macos.sh release
# Automatically compiles and copies to:
# flutter/simulst_macos/macos/libsimulst.dylib
```

### 3.3 Dynamic Library Copying and @rpath Loading Path Processing

To ensure the packaged App can correctly find and load dependencies (e.g., `libomp.dylib` or `libsherpa-onnx-c-api.dylib`) when running on any macOS device, the build script uses the `install_name_tool` utility to change absolute paths to `@rpath` relative loading paths. For example:

```bash
# Example: Change the dependency path of libvoice_engine.dylib on sherpa-onnx
install_name_tool -change "/absolute/path/libsherpa-onnx-c-api.dylib" \
                        "@rpath/libsherpa-onnx-c-api.dylib" \
                        "libvoice_engine.dylib"
```

---

## 4. Build and Run Flutter macOS App

Once the native dynamic libraries are ready, you can debug and run the Flutter application under the `voice_app` directory.

### 4.1 Run in Development Environment

```bash
cd voice_app

# Start the macOS native app for testing
flutter run -d macos
```

### 4.2 Cache Clearing and Dependency Updates

If Xcode still loads older versions of libraries after recompiling the `.dylib`s, you can perform a Flutter and Xcode cache cleanup:

```bash
cd voice_app

# Clear Flutter build cache
flutter clean

# Fetch dependencies again
flutter pub get

# Run again
flutter run -d macos
```

---

## 5. Package Release App and Distribution Bundles

### 5.1 Build macOS .app Bundle

Use the following command to build the Release version:

```bash
cd voice_app
flutter build macos --release
```

After building, the compilation artifacts are stored in:
`voice_app/build/macos/Build/Products/Release/Voice Hub.app`

### 5.2 Verify App Structure and Dynamic Library Packaging

Upon successful build, you can check the `Contents/Frameworks` directory inside the `.app` bundle to confirm all native dynamic libraries have been successfully packaged into the App:

```bash
ls -la "voice_app/build/macos/Build/Products/Release/Voice Hub.app/Contents/Frameworks"
```

The complete list of dynamic libraries included in the package should look like this:
- `App.framework`
- `FlutterMacOS.framework`
- `libcargs.dylib`
- `libkaldi-native-fbank-core.dylib`
- `libllamacpp_nmt.dylib`
- `libomp.dylib`
- `libonnxruntime.dylib`
- `libopus_mt.dylib`
- `libsherpa-onnx-c-api.dylib`
- `libsherpa-onnx-cxx-api.dylib`
- `libsimulst.dylib`
- `libvoice_engine.dylib`

### 5.3 Compression and Archiving (ZIP / DMG)

For distribution and publishing, you can use ZIP archives or standard macOS DMG disk images:

#### (1) Package ZIP Archive (Fast, Cross-platform extraction)
Use macOS's `ditto` tool for compression (preserves macOS resource metadata):

```bash
cd voice_app/build/macos/Build/Products/Release

# Package ZIP
ditto -c -k --sequesterRsrc "Voice Hub.app" "VoiceHub-macOS.zip"
```

#### (2) Package DMG Disk Image (Standard macOS installation experience)

##### Option A: Using macOS built-in command `hdiutil` (Zero dependencies, ready to use)
Includes a `/Applications` symlink for convenient drag-and-drop installation:

```bash
cd voice_app/build/macos/Build/Products/Release

# Create a temporary directory structure and package DMG
mkdir -p DMG_Folder
cp -R "Voice Hub.app" DMG_Folder/
ln -s /Applications DMG_Folder/Applications
hdiutil create -volname "VoiceHub" -srcfolder DMG_Folder -ov -format UDZO "VoiceHub-macOS.dmg"
rm -rf DMG_Folder
```

##### Option B: Using `create-dmg` (Recommended, supports icons and visual drag-and-drop layout)
Generates a polished DMG with background layout, custom icons, and application drag-and-drop indicators:

```bash
# 1. Install create-dmg
brew install create-dmg

# 2. Generate customized beautiful DMG
create-dmg \
  --volname "VoiceHub" \
  --volicon "Voice Hub.app/Contents/Resources/AppIcon.icns" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "Voice Hub.app" 175 190 \
  --hide-extension "Voice Hub.app" \
  --app-drop-link 425 190 \
  "VoiceHub-macOS.dmg" \
  "Voice Hub.app"
```

---

## 6. Troubleshooting

### Q1: Xcode compilation prompts `library not found` or loads old `.dylib`
* **Reason**: Xcode DerivedData cache is causing the latest dynamic library files not to be loaded.
* **Solution**:
  ```bash
  cd voice_app
  flutter clean
  rm -rf macos/Pods/
  flutter pub get
  ```

### Q2: Running or starting prompts `dyld: Library not loaded: @rpath/...`
* **Reason**: The dynamic library's install_name is not set to `@rpath`, or the plugin's Frameworks copying phase did not include the `.dylib`.
* **Solution**:
  Ensure you compile using `./scripts/build_macos_all.sh release`; the script automatically uses `install_name_tool` to fix the `@rpath` path.

### Q3: Prompt `Swift Package Manager` does not support certain plugins warning
* **Symptom**: Flutter build output displays `The following plugins do not support Swift Package Manager for macos...`
* **Explanation**: This is a warning prompt as Flutter progressively deprecates CocoaPods in favor of SPM. It currently does not affect CocoaPods build packaging and can be safely ignored.

### Q4: Prompt `ld: warning: ignoring file ... found architecture 'arm64', required architecture 'x86_64'`
* **Reason**: The `.dylib` compiled on Apple Silicon (M-series chips) is the `arm64` architecture, while Xcode tries to build universal binaries (Universal / x86_64).
* **Explanation**: Apple Silicon Macs can natively run `arm64` architecture `.app`s. If you need to distribute Intel (x86_64) applications, you need to use `x86_64` or Universal binary (`lipo`) cross-compilation toolchains when compiling the underlying `.dylib`s.

---

<h2 id="简体中文">🇨🇳 简体中文</h2>

# macOS App 构建与打包指南

本文档涵盖 VoiceHub Flutter 项目的完整 macOS 编译、原生动态库（`.dylib`）构建、Flutter 应用打包与产物分发流程。

---

## 目录

1. [前置依赖](#1-前置依赖)
2. [项目架构概览](#2-项目架构概览)
3. [编译 macOS C++ 原生动态库 (.dylib)](#3-编译-macos-c-原生动态库-dylib)
   - [3.1 一键构建全部原生库](#31-一键构建全部原生库)
   - [3.2 分模块编译说明](#32-分模块编译说明)
   - [3.3 动态库拷贝与 @rpath 加载路径处理](#33-动态库拷贝与-rpath-加载路径处理)
4. [构建与运行 Flutter macOS App](#4-构建与运行-flutter-macos-app)
   - [4.1 开发环境运行](#41-开发环境运行)
   - [4.2 缓存清理与依赖更新](#42-缓存清理与依赖更新)
5. [打包 Release 应用与分发包](#5-打包-release-应用与分发包)
   - [5.1 构建 macOS .app Bundle](#51-构建-macos-app-bundle)
   - [5.2 验证应用结构与动态库打包](#52-验证应用结构与动态库打包)
   - [5.3 压缩与归档 (ZIP / DMG)](#53-压缩与归档-zip--dmg)
6. [常见问题排查 (Troubleshooting)](#6-常见问题排查-troubleshooting)

---

## 1. 前置依赖

在开始之前，请确保你的 macOS 系统上已正确安装并配置以下基础开发工具：

```bash
# 1. 安装 Xcode 命令行工具 (Command Line Tools)
xcode-select --install

# 2. 安装 Homebrew 包管理器 (如未安装)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 3. 通过 Homebrew 安装 CMake 和 nlohmann-json (C++ 原生模块依赖)
brew install cmake nlohmann-json libomp

# 4. 安装/检查 Flutter SDK (建议 Flutter >= 3.10.0)
flutter doctor
```

确保 `flutter doctor` 中 **macOS toolchain** 和 **Xcode** 均正常提示启用。

---

## 2. 项目架构概览

VoiceHub macOS 应用程序由 Flutter 前端应用与 5 个核心 C++ 原生推理引擎/算法模块组成：

```
VoiceHub/
├── scripts/
│   └── build_macos_all.sh             # macOS 原生库一键编译打包脚本
├── voice_app/                         # Flutter 主工程
│   ├── lib/                           # Dart 界面与逻辑代码
│   ├── macos/                         # macOS 原生 App 配置 (Xcode 工程)
│   └── build/macos/Build/Products/    # 最终打包输出路径
├── sherpa-onnx/                       # ASR / TTS 离线语音识别与合成引擎
│   └── flutter/sherpa_onnx_macos/
├── llama/                             # LLM 机器翻译模块 (基于 llama.cpp)
│   └── flutter/llamacpp_macos/
├── opus_mt/                           # Opus-MT 神经机器翻译模块
│   └── flutter/opus_mt_macos/
├── voice_engine/                      # 核心语音处理管道引擎
│   └── flutter/voice_engine_macos/
└── simulst/                           # 同声传译 (Simultaneous Translation) 模块
    └── flutter/simulst_macos/
```

### 核心原生库与 Flutter 插件映射表

| 模块名称 | 生成动态库 (`.dylib`) | Flutter 插件名称 | 对应插件目录 |
|---|---|---|---|
| **sherpa-onnx** | `libsherpa-onnx-c-api.dylib`, `libonnxruntime.dylib` | `sherpa_onnx` (`sherpa_onnx_macos`) | `sherpa-onnx/flutter/sherpa_onnx_macos` |
| **llama** | `libllamacpp_nmt.dylib`, `libomp.dylib` | `llamacpp_macos` | `llama/flutter/llamacpp_macos` |
| **opus_mt** | `libopus_mt.dylib` | `opus_mt_macos` | `opus_mt/flutter/opus_mt_macos` |
| **voice_engine** | `libvoice_engine.dylib` | `voice_engine_macos` | `voice_engine/flutter/voice_engine_macos` |
| **simulst** | `libsimulst.dylib`, `libkaldi-native-fbank-core.dylib` | `simulst_macos` | `simulst/flutter/simulst_macos` |

---

## 3. 编译 macOS C++ 原生动态库 (.dylib)

在打包或运行 Flutter macOS 应用之前，必须先将 C++ 原生源码编译为 macOS 平台可用的 `.dylib` 动态库，并嵌入到各 Flutter 插件的 `macos/` 目录中。

### 3.1 一键构建全部原生库

VoiceHub 提供了根目录脚本用于一键自动完成 5 个模块的编译与拷贝：

```bash
# 赋予执行权限
chmod +x scripts/build_macos_all.sh

# 编译 Release 版本（推荐，推理性能更佳）
./scripts/build_macos_all.sh release

# 或编译 Debug 版本
./scripts/build_macos_all.sh debug
```

### 3.2 分模块编译说明

如需对单个模块进行代码修改与单独编译，可按照以下命令分别进行。

> [!NOTE]
> 模块间依赖提示：`voice_engine` 与 `simulst` 依赖 `sherpa-onnx` 及 `llama` 导出的 C-API 头文件与动态库。若要单独编译 `voice_engine` 或 `simulst`，请确保已先行编译 `sherpa-onnx` 与 `llama`。

#### (1) 编译 sherpa-onnx
```bash
cd sherpa-onnx
mkdir -p build && cd build
cmake .. -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=release
cmake --build . --config release -j$(sysctl -n hw.logicalcpu)
cmake --install . --config release

# 将编译生成的动态库拷贝至 macOS Flutter 插件路径
mkdir -p ../flutter/sherpa_onnx_macos/macos/
cp lib/libsherpa-onnx-c-api.dylib ../flutter/sherpa_onnx_macos/macos/
cp _deps/onnxruntime-build/lib/libonnxruntime.dylib ../flutter/sherpa_onnx_macos/macos/
```

#### (2) 编译 llama.cpp
```bash
cd llama
# 确保 llama.cpp 子模块已被正确 clone (至 llama/llama.cpp)
./build_macos.sh release
# 编译产物 libllamacpp_nmt.dylib 和 libomp.dylib 会自动修复 @rpath 并拷贝至:
# flutter/llamacpp_macos/macos/
```

#### (3) 编译 opus_mt
```bash
cd opus_mt
./build_macos.sh release
# 自动/手动拷贝产物到插件路径:
mkdir -p flutter/opus_mt_macos/macos/
cp build/libopus_mt.dylib flutter/opus_mt_macos/macos/
```

#### (4) 编译 voice_engine
```bash
cd voice_engine
./build_macos.sh release
# 自动链接 sherpa-onnx 并拷贝至:
# flutter/voice_engine_macos/macos/libvoice_engine.dylib
```

#### (5) 编译 simulst
```bash
cd simulst
./build_macos.sh release
# 自动编译并拷贝至:
# flutter/simulst_macos/macos/libsimulst.dylib
```

### 3.3 动态库拷贝与 @rpath 加载路径处理

为了确保打包后的 App 在任何 macOS 设备上运行时都能正确找到并加载依赖项（例如 `libomp.dylib` 或 `libsherpa-onnx-c-api.dylib`），构建脚本中使用了 `install_name_tool` 工具将绝对路径修改为 `@rpath` 相对加载路径。例如：

```bash
# 示例：修改 libvoice_engine.dylib 对 sherpa-onnx 的依赖路径
install_name_tool -change "/absolute/path/libsherpa-onnx-c-api.dylib" \
                        "@rpath/libsherpa-onnx-c-api.dylib" \
                        "libvoice_engine.dylib"
```

---

## 4. 构建与运行 Flutter macOS App

原生动态库准备完毕后，即可在 `voice_app` 目录下进行 Flutter 应用的调试与运行。

### 4.1 开发环境运行

```bash
cd voice_app

# 启动 macOS 本地应用进行测试
flutter run -d macos
```

### 4.2 缓存清理与依赖更新

如果在重新编译 `.dylib` 后 Xcode 依然加载旧版本的库，可进行 Flutter 与 Xcode 缓存清理：

```bash
cd voice_app

# 清理 Flutter 编译缓存
flutter clean

# 重新拉取依赖
flutter pub get

# 再次运行
flutter run -d macos
```

---

## 5. 打包 Release 应用与分发包

### 5.1 构建 macOS .app Bundle

使用以下命令进行 Release 版本构建：

```bash
cd voice_app
flutter build macos --release
```

构建完成后，编译产物存放在：
`voice_app/build/macos/Build/Products/Release/Voice Hub.app`

### 5.2 验证应用结构与动态库打包

构建成功后，可检查 `.app` 包内的 `Contents/Frameworks` 目录，确认所有原生 dynamic libraries 已成功打包进 App 中：

```bash
ls -la "voice_app/build/macos/Build/Products/Release/Voice Hub.app/Contents/Frameworks"
```

完整打包包含的动态库清单应如下所示：
- `App.framework`
- `FlutterMacOS.framework`
- `libcargs.dylib`
- `libkaldi-native-fbank-core.dylib`
- `libllamacpp_nmt.dylib`
- `libomp.dylib`
- `libonnxruntime.dylib`
- `libopus_mt.dylib`
- `libsherpa-onnx-c-api.dylib`
- `libsherpa-onnx-cxx-api.dylib`
- `libsimulst.dylib`
- `libvoice_engine.dylib`

### 5.3 压缩与归档 (ZIP / DMG)

用于分发和发布时，可以使用 ZIP 包或 macOS 标准的 DMG 磁盘镜像：

#### (1) 打包 ZIP 压缩包 (快捷、跨平台解压)
使用 macOS 的 `ditto` 工具压缩（保留 macOS 资源元数据）：

```bash
cd voice_app/build/macos/Build/Products/Release

# 打包 ZIP
ditto -c -k --sequesterRsrc "Voice Hub.app" "VoiceHub-macOS.zip"
```

#### (2) 打包 DMG 磁盘镜像包 (macOS 标准安装体验)

##### 方案 A：使用 macOS 内置命令 `hdiutil`（零依赖，即装即用）
包含 `/Applications` 软链接，方便用户拖拽安装：

```bash
cd voice_app/build/macos/Build/Products/Release

# 创建临时目录结构并打包 DMG
mkdir -p DMG_Folder
cp -R "Voice Hub.app" DMG_Folder/
ln -s /Applications DMG_Folder/Applications
hdiutil create -volname "VoiceHub" -srcfolder DMG_Folder -ov -format UDZO "VoiceHub-macOS.dmg"
rm -rf DMG_Folder
```

##### 方案 B：使用 `create-dmg`（推荐，支持图标与可视化拖拽布局）
生成带有背景布局、自定义图标与应用拖拽指示的精美 DMG 包：

```bash
# 1. 安装 create-dmg
brew install create-dmg

# 2. 生成自定义美化 DMG
create-dmg \
  --volname "VoiceHub" \
  --volicon "Voice Hub.app/Contents/Resources/AppIcon.icns" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "Voice Hub.app" 175 190 \
  --hide-extension "Voice Hub.app" \
  --app-drop-link 425 190 \
  "VoiceHub-macOS.dmg" \
  "Voice Hub.app"
```

---

## 6. 常见问题排查 (Troubleshooting)

### Q1: Xcode 编译提示 `library not found` 或加载旧版 `.dylib`
* **原因**：Xcode DerivedData 缓存导致未加载最新的动态库文件。
* **解决办法**：
  ```bash
  cd voice_app
  flutter clean
  rm -rf macos/Pods/
  flutter pub get
  ```

### Q2: 运行或启动时提示 `dyld: Library not loaded: @rpath/...`
* **原因**：动态库的 install_name 没有设置为 `@rpath`，或者插件的 Frameworks 复制阶段未包含该 `.dylib`。
* **解决办法**：
  确保通过 `./scripts/build_macos_all.sh release` 编译，脚本会自动使用 `install_name_tool` 修复 `@rpath` 路径。

### Q3: 提示 `Swift Package Manager` 不支持某些插件警告
* **现象**：Flutter 编译输出中显示 `The following plugins do not support Swift Package Manager for macos...`
* **说明**：此为 Flutter 渐进式废弃 CocoaPods 转向 SPM 时的提示警告，目前不影响 CocoaPods 的构建打包，可正常忽略。

### Q4: 提示 `ld: warning: ignoring file ... found architecture 'arm64', required architecture 'x86_64'`
* **原因**：Apple Silicon (M系列芯片) 上编译生成的 `.dylib` 为 `arm64` 架构，而 Xcode 尝试构建通用二进制 (Universal / x86_64)。
* **说明**：Apple Silicon Mac 上可原生运行 `arm64` 架构的 `.app`。如需分发 Intel (x86_64) 应用，需要在编译底层 `.dylib` 时使用 `x86_64` 或 Universal binary (`lipo`) 交叉编译工具链。
