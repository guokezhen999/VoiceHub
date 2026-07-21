# 语音与翻译模型准备指南 (Model Setup Guide)

本文档提供 VoiceHub 所需开源 AI 模型的下载、配置与放置指南。工程中模型托管与推理主要基于 **sherpa-onnx**（语音识别 ASR 与语音合成 TTS）、**opus_mt**（神经机器翻译 MT）以及 **llama.cpp**（大语言模型 LLM）。

> 🔗 **sherpa-onnx 官方预训练模型索引**：[sherpa-onnx Pre-trained Models](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/index.html)

---

## 1. 目录规范与概览

```text
VoiceHub/
└── models/
    ├── asr/     # 语音识别模型 (sherpa-onnx 驱动)
    ├── tts/     # 语音合成模型 (sherpa-onnx 驱动)
    ├── mt/      # 机器翻译模型 (opus-mt ONNX 格式，须见 docs/opus_mt.md)
    └── llm/     # 大语言模型 (llama.cpp GGUF 格式)
```

> [!IMPORTANT]
> - **文件忽略提醒**：模型权重文件通常较大，已在项目 `.gitignore` 中配置忽略，请勿将本地模型提交到 Git 仓库。
> - **iOS 上传与压缩包保留**：App 内部集成了压缩包自动解压与导入功能。在 **iOS 设备**上，受系统限制无法直接向 App 模型仓库上传文件夹目录，**仅支持上传模型压缩文件（如 `.tar.bz2` 或 `.zip`）**。因此下载模型时请保留原始压缩包以便在 App 内上传导入。

---

## 2. ASR (语音识别) 模型配置

ASR 模块由 **sherpa-onnx** 驱动。VoiceHub 目前**仅适配 Transducer 架构模型**（即由 `encoder.onnx`, `decoder.onnx`, `joiner.onnx` 组成的模型），按使用场景分为**流式 Transducer（Online Transducer）**与**非流式 Transducer（Offline Transducer）**两种类型。

官方 Transducer 模型库：
- 🔗 **Online Transducer (流式)**：[sherpa-onnx Online Transducer Models Index](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/index.html)
- 🔗 **Offline Transducer (非流式)**：[sherpa-onnx Offline Transducer Models Index](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-transducer/index.html)

---

### 2.1 Transducer 模型选型

| 模型架构类型 | 识别模式 | 典型代表模型 | 适配说明与适用场景 |
|---|---|---|---|
| **Online Transducer** | 流式 (Online) | Zipformer Streaming | 边录音边实时输出结果，低延迟，适配同声传译与流式语音输入 |
| **Offline Transducer** | 非流式 (Offline) | Zipformer Non-streaming | 一次性解码完整音频，准确度高、上下文完整，适配整句/段落识别 |

---

### 2.2 下载与配置示例

#### 示例 1: 中文/多语种流式 Transducer 模型 (`sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12`)
```bash
mkdir -p models/asr
cd models/asr

wget https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12.tar.bz2
tar xvf sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12.tar.bz2
```

流式 Transducer 模型解压后的标准目录结构（包含 `encoder`, `decoder`, `joiner` 与 `tokens.txt`）：
```text
models/asr/sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12/
├── encoder-epoch-20-avg-1.onnx   # Encoder ONNX 模型
├── decoder-epoch-20-avg-1.onnx   # Decoder ONNX 模型
├── joiner-epoch-20-avg-1.onnx    # Joiner ONNX 模型
└── tokens.txt                    # Token 词表
```

#### 示例 2: 英文流式 Transducer 模型 (`sherpa-onnx-streaming-zipformer-en-2023-06-26`)
```bash
cd models/asr

wget https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2
tar xvf sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2
```

#### 示例 3: 中英双语非流式 Transducer 模型 (`sherpa-onnx-zipformer-zh-en-2023-11-22`)
```bash
cd models/asr

wget https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-zipformer-zh-en-2023-11-22.tar.bz2
tar xvf sherpa-onnx-zipformer-zh-en-2023-11-22.tar.bz2
```

---

## 3. TTS (语音合成) 模型配置

TTS 模块由 **sherpa-onnx** 驱动，专门采用 **VITS** 架构语音合成模型。

官方 VITS 模型汇总页面：[sherpa-onnx VITS Models Index](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/vits.html)

---

### 3.1 VITS 模型选型

| 模型标识 | 语言支持 | 发音人数 | 适用场景 |
|---|---|---|---|
| **vits-melo-tts-zh_en** | 中文 + 英文 (Chinese + English) | 1 Speaker | 中英双语混合朗读 |
| **vits-piper-en_US-glados** | 英文 (English) | 1 Speaker | 轻量、高质量标准英文朗读 |
| **csukuangfj/sherpa-onnx-vits-zh-ll** | 中文 (Chinese) | 5 Speakers | 支持 5 种不同中文音色/发音人切换 |

---

### 3.2 下载与配置示例

#### 示例 1: 中英双语单发音人模型 (`vits-melo-tts-zh_en`)
```bash
mkdir -p models/tts
cd models/tts

wget https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-melo-tts-zh_en.tar.bz2
tar xvf vits-melo-tts-zh_en.tar.bz2
```

解压后的完整结构说明：
```text
models/tts/vits-melo-tts-zh_en/
├── model.onnx          # TTS 合成 ONNX 模型
├── lexicon.txt         # 发音词典 (Phoneme Map)
├── tokens.txt          # Token 表
├── date.fst            # 数字/日期转换规整模型 (可选)
├── number.fst          # 数字规整模型 (可选)
└── phone.fst           # 音素处理模型 (可选)
```

#### 示例 2: 英文单发音人模型 (`vits-piper-en_US-glados`)
```bash
cd models/tts

wget https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-glados.tar.bz2
tar xvf vits-piper-en_US-glados.tar.bz2
```

*注意：Piper 模型解压后常包含 `espeak-ng-data/` 依赖文件夹，运行时请确保该文件夹与 `model.onnx` 保持在同一相对路径下。*

#### 示例 3: 中文多发音人模型 (`csukuangfj/sherpa-onnx-vits-zh-ll`)
```bash
cd models/tts

wget https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/sherpa-onnx-vits-zh-ll.tar.bz2
tar xvf sherpa-onnx-vits-zh-ll.tar.bz2
```

---

## 4. MT (神经机器翻译) 模型配置

VoiceHub 传统 NMT 机器翻译模块基于 `opus_mt`。该模型**不能直接使用官方原始 HuggingFace 权重**，必须转换为 ONNX 并经过 INT8 量化后放入 `models/mt/` 目录下。

具体转换与部署流程请参见专项指南：[opus_mt.md](opus_mt.md)

---

## 5. LLM (大语言模型) 配置

VoiceHub 使用 **llama.cpp** 作为大语言模型推理引擎，模型格式统一要求为 **GGUF**。支持 Qwen3 系列以及腾讯混元 Hy-MT2 翻译大模型，包含 `Q4_K_M`（4-bit 中度量化，均衡速度与占用）与 `Q8_0`（8-bit 高精度量化）两种量化版本。

模型统一存放至 `models/llm/` 对应的子目录中。

---

### 5.1 Qwen3-0.6B 模型

#### Q4_K_M 量化版本
```bash
mkdir -p models/llm/qwen3-0.6B
cd models/llm/qwen3-0.6B

curl -L -o qwen3-0.6b-instruct-q4_k_m.gguf \
  "https://modelscope.cn/api/v1/models/unsloth/Qwen3-0.6B-GGUF/repo?Revision=master&FilePath=Qwen3-0.6B-Q4_K_M.gguf"
```

#### Q8_0 量化版本
```bash
cd models/llm/qwen3-0.6B

curl -L -o qwen3-0.6b-instruct-q8_0.gguf \
  "https://modelscope.cn/api/v1/models/unsloth/Qwen3-0.6B-GGUF/repo?Revision=master&FilePath=Qwen3-0.6B-Q8_0.gguf"
```

---

### 5.2 Qwen3-1.7B 模型

#### Q4_K_M 量化版本
```bash
mkdir -p models/llm/qwen3-1.7B
cd models/llm/qwen3-1.7B

curl -L -o qwen3-1.7b-instruct-q4_k_m.gguf \
  "https://modelscope.cn/api/v1/models/unsloth/Qwen3-1.7B-GGUF/repo?Revision=master&FilePath=Qwen3-1.7B-Q4_K_M.gguf"
```

#### Q8_0 量化版本
```bash
cd models/llm/qwen3-1.7B

curl -L -o qwen3-1.7b-instruct-q8_0.gguf \
  "https://modelscope.cn/api/v1/models/unsloth/Qwen3-1.7B-GGUF/repo?Revision=master&FilePath=Qwen3-1.7B-Q8_0.gguf"
```

---

### 5.3 Qwen3-4B 模型

#### Q4_K_M 量化版本
```bash
mkdir -p models/llm/qwen3-4B
cd models/llm/qwen3-4B

curl -L -o qwen3-4b-instruct-q4_k_m.gguf \
  "https://modelscope.cn/api/v1/models/unsloth/Qwen3-4B-GGUF/repo?Revision=master&FilePath=Qwen3-4B-Q4_K_M.gguf"
```

#### Q8_0 量化版本
```bash
cd models/llm/qwen3-4B

curl -L -o qwen3-4b-instruct-q8_0.gguf \
  "https://modelscope.cn/api/v1/models/unsloth/Qwen3-4B-GGUF/repo?Revision=master&FilePath=Qwen3-4B-Q8_0.gguf"
```

---

### 5.4 腾讯混元 Hy-MT2-1.8B 翻译大模型

#### Q4_K_M 量化版本
```bash
mkdir -p models/llm/hy-mt2-1.8B
cd models/llm/hy-mt2-1.8B

curl -L -o hy-mt2-1.8b-q4_k_m.gguf \
  "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/main/Hy-MT2-1.8B-Q4_K_M.gguf"
```
