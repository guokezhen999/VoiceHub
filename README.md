下载 qwen3-0.6B gguf

mkdir -p model/llm/qwen3-0.6B/
cd model/llm/qwen3-0.6B/
curl -L -o qwen3-0.6b-instruct-q4_k_m.gguf "https://modelscope.cn/api/v1/models/unsloth/Qwen3-0.6B-GGUF/repo?Revision=master&FilePath=Qwen3-0.6B-Q4_K_M.gguf"

---

## C++ 动态库编译及拷贝指南 (C++ Dynamic Library Compilation & Copying Guide)

如果你修改了 `llama` 或 `opus_mt` 模块中的 C++ 源代码，需要重新编译生成动态库（`.dylib`）并拷贝到对应的 Flutter 插件目录中，以便 Flutter 应用程序能够加载更新后的逻辑。

### 1. 前置依赖 (Prerequisites)
请确保系统中已安装 CMake 和 `nlohmann-json`（以 macOS Homebrew 为例）：
```bash
brew install cmake nlohmann-json
```

---

### 2. 编译并打包 llama 模块 (llama.cpp)
`llama` 模块基于 `llama.cpp`，用于运行大语言模型翻译。

**编译步骤：**
1. 进入 `llama` 目录。
2. 运行 `build_macos.sh` 脚本进行编译。可通过传入 `release` 参数生成 Release 版本的动态库（推荐，性能更好）：
   ```bash
   cd llama
   # 编译 Debug 版本（默认）
   ./build_macos.sh
   # 或者编译 Release 版本（推荐）
   ./build_macos.sh release
   ```

**拷贝动态库到 Flutter 插件路径：**
* **自动拷贝**：`llama/build_macos.sh` 脚本编译成功后，会自动将生成的 `libllamacpp_nmt.dylib` (以及所需的 `libomp.dylib` 依赖) 拷贝到 Flutter 插件目录 `llama/flutter/llamacpp_macos/macos/` 中，无需手动操作。

---

### 3. 编译并打包 opus_mt 模块
`opus_mt` 模块用于机器翻译，依赖 ONNX Runtime 和 SentencePiece。

**编译步骤：**
1. **确保 ONNX Runtime 已就绪**：
   编译 `opus_mt` 之前，确保 `sherpa-onnx` 目录下的 ONNX Runtime 已编译或存在。如果尚未编译过 `sherpa-onnx`，可以先运行以下命令生成依赖：
   ```bash
   cd sherpa-onnx
   mkdir -p build && cd build
   cmake .. -DBUILD_SHARED_LIBS=ON
   cmake --build .
   cd ../..
   ```
2. 进入 `opus_mt` 目录，执行 `build_macos.sh` 编译：
   ```bash
   cd opus_mt
   # 编译 Debug 版本（默认）
   ./build_macos.sh
   # 或者编译 Release 版本（推荐）
   ./build_macos.sh release
   ```

**拷贝动态库到 Flutter 插件路径：**
* **手动拷贝**：`opus_mt` 的编译脚本不会自动拷贝动态库，你需要在 `opus_mt` 目录下手动将其拷贝到 `opus_mt_macos` 插件的 macos 目录下：
  ```bash
  # 在 opus_mt 目录下执行
  cp build/libopus_mt.dylib flutter/opus_mt_macos/macos/
  ```

---

### 4. 在 Flutter 项目中应用更改 (Apply Changes in Flutter)
编译并拷贝动态库后，建议在 `voice_app` 中执行清理和重新运行，以确保 Flutter 获取到最新的 `.dylib` 文件（避免 Xcode 缓存）：
```bash
cd voice_app
# 清理缓存
flutter clean
# 获取依赖
flutter pub get
# 运行应用
flutter run -d macos
```