#!/bin/bash

# 获取脚本所在的目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 定义路径
BIN="$APP_DIR/bin/zipformer/sherpa-onnx"
MODEL_DIR="$APP_DIR/model/zipformer/vi_base_v1.0.0.3"
WAV_FILE="$APP_DIR/wav/asr/vi/vi_boy_3000_1.wav"

# 检查可执行二进制文件是否存在
if [ ! -f "$BIN" ]; then
    echo "Error: 可执行文件未找到: $BIN"
fi

# 检查模型文件是否存在
for file in "tokens.txt" "encoder.onnx" "decoder.onnx" "joiner.onnx"; do
    if [ ! -f "$MODEL_DIR/$file" ]; then
        echo "Error: 模型文件缺失: $MODEL_DIR/$file"
    fi
done

# 检查测试音频是否存在
if [ ! -f "$WAV_FILE" ]; then
    echo "Error: 测试音频文件未找到: $WAV_FILE"
fi

echo "=================================================="
echo "正在使用 Zipformer 流式模型运行语音识别测试..."
echo "二进制路径: $BIN"
echo "模型目录:   $MODEL_DIR"
echo "音频文件:   $WAV_FILE"
echo "=================================================="
echo ""

# 执行语音识别
"$BIN" \
  --tokens="$MODEL_DIR/tokens.txt" \
  --encoder="$MODEL_DIR/encoder.onnx" \
  --decoder="$MODEL_DIR/decoder.onnx" \
  --joiner="$MODEL_DIR/joiner.onnx" \
  --num-threads=4 \
  --enable-endpoint=false \
  "$WAV_FILE"

echo ""
echo "=================================================="
echo "测试执行完成。"
echo "=================================================="
