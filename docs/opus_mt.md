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
