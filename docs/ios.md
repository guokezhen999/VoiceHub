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

如果你修改了 `llama/csrc/` 或 `opus_mt/csrc/` 中的 C++ 代码，需要重新编译 iOS xcframework 并拷贝到对应插件目录。

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
ideviceinstaller -i build/ios/ipa/Runner.ipa
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

### 9.4 Swift Package Manager 警告

```
The following plugins do not support Swift Package Manager for ios:
  - audioplayers_darwin
  - llamacpp_macos
  - opus_mt_macos
  - sherpa_onnx_ios
```

这是非致命警告，插件仍通过 CocoaPods 正常工作。后续 Flutter 版本可能要求插件迁移到 SPM，但目前不影响构建。

### 9.5 模拟器 vs 真机架构不匹配

xcframework 已包含 `ios-arm64`（真机）和 `ios-arm64_x86_64-simulator`（模拟器）两种架构。如果遇到架构错误，确认：

```bash
# 检查 xcframework 的架构信息
xcodebuild -runFirstLaunch
xcrun vtool -show-build llama/flutter/llamacpp_macos/ios/llamacpp_nmt.xcframework/ios-arm64/llamacpp_nmt.framework/llamacpp_nmt
```

### 9.6 最低 iOS 版本

项目最低支持 iOS 14.0（在 `ios/Podfile` 中定义）。如果需要修改：

```ruby
# ios/Podfile
platform :ios, '14.0'   # 修改此行
```

同时在 Xcode 中 Runner target → General → Minimum Deployments 保持一致。

### 9.7 构建报 `Bitcode` 错误

xcframework 已使用 `ENABLE_BITCODE=0` 编译。Xcode 14+ 已弃用 Bitcode，如果你的项目不需要 Bitcode，在 Xcode 中确保：

- Runner target → Build Settings → **Enable Bitcode** = `NO`

### 9.8 首次构建很慢

iOS 首次构建需要编译 Flutter engine 和所有依赖，预计耗时 5-15 分钟。后续增量构建会快很多。

---

## 快速参考

```bash
# ==== 完整构建流程 ====

# 1. 编译 C++ 原生库 (仅在修改 C++ 代码后需要)
cd llama && ./build_ios.sh && cd ..
cd opus_mt && ./build_ios.sh && cd ..

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
