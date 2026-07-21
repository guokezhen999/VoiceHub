<h2 id="english">🇬🇧 English</h2>

# opus-mt ONNX Model Export

Exporting the Helsinki-NLP/opus-mt series translation models to ONNX format, supporting two precisions: FP32 and INT8 (encoder).

## Environment Preparation

### Conda Environment

```bash
conda create -n opus-onnx python=3.10 -y
conda activate opus-onnx

# CPU Version (No GPU required for model export/quantization)
pip install torch "transformers==4.44.2" sentencepiece huggingface_hub onnx onnxruntime

# If CUDA acceleration is needed (optional)
# pip install torch --index-url https://download.pytorch.org/whl/cu118
```

Dependency Description:

| Package | Purpose |
|---|---|
| `pytorch` | Model loading & ONNX export |
| `transformers` (< 4.36) | HuggingFace MarianMT model loading (DynamicCache in ≥ 4.36 is incompatible with the old KV Cache access method) |
| `sentencepiece` | Tokenizer (opus-mt uses SentencePiece) |
| `huggingface_hub` | Downloading models from HuggingFace |
| `onnx` | ONNX model read/write |
| `onnxruntime` | INT8 static quantization |
| `numpy` | Numerical computation (automatically installed with the above packages) |


## Export Process

### One-Click Export (Recommended)

```bash
# Run from the VoiceHub project root directory
./opus_mt/export/prepare_mt_zh_en.sh
```

This script will automatically execute all 3 stages.

### Multi-Stage Export

```bash
# Usage
./opus_mt/export/export_opus_mt.sh <hf_repo> <output_dir> [start_stage] [end_stage] [--calib-data FILE]

# Example: Full process
./opus_mt/export/export_opus_mt.sh Helsinki-NLP/opus-mt-zh-en opus_mt/model/zh-en

# Execute stages 2 and 3 only (skip downloading)
./opus_mt/export/export_opus_mt.sh Helsinki-NLP/opus-mt-zh-en opus_mt/model/zh-en 2 3

# Execute stage 3 only (INT8 quantization), specify calibration data
./opus_mt/export/export_opus_mt.sh Helsinki-NLP/opus-mt-zh-en opus_mt/model/zh-en 3 --calib-data calib_zh.txt
```

### Export Stages

| Stage | Script | Description |
|---|---|---|
| 1. Download | `hf/download.py` | Download model from HuggingFace → `<output>/hf/` |
| 2. FP32 Export | `hf/convert_to_onnx.py` + `hf/share_weights.py` | Export ONNX + share weights → `<output>/onnx_fp32/` |
| 3. INT8 Quantization | `hf/quantize_encoder.py` | Encoder INT8 quantization + FP32 decoder → `<output>/onnx_int8/` |

### Export Artifacts

```
onnx_fp32/
├── encoder.onnx          # FP32 Encoder
├── decoder.onnx           # Incremental Decoder (index file, referencing decoder.onnx.data)
├── decoder_init.onnx      # First-Step Decoder (index file, referencing decoder.onnx.data)
├── decoder.onnx.data      # Shared weight data (~500 MB)
├── source.spm             # Source language SentencePiece model
├── target.spm             # Target language SentencePiece model
├── vocab.json             # Vocabulary
└── config.json            # Model configuration

onnx_int8/
├── encoder.onnx          # INT8 Encoder (static quantization)
├── decoder.onnx           # FP32 Incremental Decoder (same as above)
├── decoder_init.onnx      # FP32 First-Step Decoder (same as above)
├── decoder.onnx.data      # Shared weight data
├── source.spm / target.spm / vocab.json / config.json
```

## Model Architecture

Based on MarianMT (opus-mt) Encoder-Decoder Transformer, split into 3 ONNX sub-models:

| Sub-model | Purpose |
|---|---|
| `encoder` | Encodes source language input → `last_hidden_state` |
| `decoder_init` | First-step decoding: generates the first token + all KV Cache (self-attention + cross-attention) |
| `decoder` | Incremental decoding: inputs previous step KV Cache, generates the next token + updates self-attention KV Cache |

The two decoders share the weight file (`decoder.onnx.data`) via ONNX external data, avoiding duplicate storage of ~500 MB of copied weights.

---
<h2 id="简体中文">🇨🇳 简体中文</h2>

# opus-mt ONNX 模型导出

基于 Helsinki-NLP/opus-mt 系列翻译模型，导出为 ONNX 格式，支持 FP32 和 INT8（编码器）两种精度。

## 环境准备

### Conda 环境

```bash
conda create -n opus-onnx python=3.10 -y
conda activate opus-onnx

# CPU 版（模型导出/量化无需 GPU）
pip install torch "transformers==4.44.2" sentencepiece huggingface_hub onnx onnxruntime

# 如果需要 CUDA 加速（可选）
# pip install torch --index-url https://download.pytorch.org/whl/cu118
```

依赖说明：

| 包 | 用途 |
|---|---|
| `pytorch` | 模型加载 & ONNX 导出 |
| `transformers` (< 4.36) | HuggingFace MarianMT 模型加载（≥ 4.36 的 DynamicCache 不兼容旧版 KV Cache 访问方式） |
| `sentencepiece` | 分词器（opus-mt 使用 SentencePiece） |
| `huggingface_hub` | 从 HuggingFace 下载模型 |
| `onnx` | ONNX 模型读写 |
| `onnxruntime` | INT8 静态量化 |
| `numpy` | 数值计算（随上述包自动安装） |


## 导出流程

### 一键导出（推荐）

```bash
# 从 VoiceHub 项目根目录运行
./opus_mt/export/prepare_mt_zh_en.sh
```

该脚本会自动执行全部 3 个阶段。

### 分阶段导出

```bash
# 用法
./opus_mt/export/export_opus_mt.sh <hf_repo> <output_dir> [start_stage] [end_stage] [--calib-data FILE]

# 示例：全流程
./opus_mt/export/export_opus_mt.sh Helsinki-NLP/opus-mt-zh-en opus_mt/model/zh-en

# 只执行阶段 2 和 3（跳过下载）
./opus_mt/export/export_opus_mt.sh Helsinki-NLP/opus-mt-zh-en opus_mt/model/zh-en 2 3

# 只执行阶段 3（INT8 量化），指定校准数据
./opus_mt/export/export_opus_mt.sh Helsinki-NLP/opus-mt-zh-en opus_mt/model/zh-en 3 --calib-data calib_zh.txt
```

### 导出阶段

| 阶段 | 脚本 | 说明 |
|---|---|---|
| 1. 下载 | `hf/download.py` | 从 HuggingFace 下载模型 → `<output>/hf/` |
| 2. FP32 导出 | `hf/convert_to_onnx.py` + `hf/share_weights.py` | 导出 ONNX + 共享权重 → `<output>/onnx_fp32/` |
| 3. INT8 量化 | `hf/quantize_encoder.py` | 编码器 INT8 量化 + FP32 解码器 → `<output>/onnx_int8/` |

### 导出产物

```
onnx_fp32/
├── encoder.onnx          # FP32 编码器
├── decoder.onnx           # 增量解码器（索引文件，引用 decoder.onnx.data）
├── decoder_init.onnx      # 首步解码器（索引文件，引用 decoder.onnx.data）
├── decoder.onnx.data      # 共享权重数据（~500 MB）
├── source.spm             # 源语言 SentencePiece 模型
├── target.spm             # 目标语言 SentencePiece 模型
├── vocab.json             # 词表
└── config.json            # 模型配置

onnx_int8/
├── encoder.onnx          # INT8 编码器（静态量化）
├── decoder.onnx           # FP32 增量解码器（同上）
├── decoder_init.onnx      # FP32 首步解码器（同上）
├── decoder.onnx.data      # 共享权重数据
├── source.spm / target.spm / vocab.json / config.json
```

## 模型架构

基于 MarianMT（opus-mt）的 Encoder-Decoder Transformer，拆分为 3 个 ONNX 子模型：

| 子模型 | 作用 |
|---|---|
| `encoder` | 编码源语言输入 → `last_hidden_state` |
| `decoder_init` | 首步解码：生成第一个 token + 全部 KV Cache（自注意 + 交叉注意） |
| `decoder` | 增量解码：输入上一步 KV Cache，生成下一 token + 更新自注意 KV Cache |

两个解码器通过 ONNX external data 共享权重文件 (`decoder.onnx.data`)，避免重复存储 ~500 MB 的权重复制。
