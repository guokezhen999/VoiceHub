#!/usr/bin/env python3
"""
Static INT8 quantization for ONNX encoder models.

Per-channel symmetric INT8 weight quantization + static activation calibration.

Usage:
    python quantize_encoder.py \\
        --input encoder.onnx --output encoder_int8.onnx \\
        --hf-dir hf/ --calibration-data calib.txt
"""

import argparse
import shutil
import sys
from pathlib import Path

import numpy as np
import onnx
from onnxruntime.quantization import CalibrationDataReader
from transformers import AutoTokenizer

from _common import quantize_model, load_calibration_texts, apply_static_activations


# ===========================================================================
# Calibration reader
# ===========================================================================

class EncoderCalibrationReader(CalibrationDataReader):
    def __init__(self, tokenizer, texts, max_len=128):
        self.data = []
        for text in texts:
            enc = tokenizer(text, return_tensors="np", max_length=max_len,
                            truncation=True, padding="max_length")
            self.data.append({
                "input_ids": enc["input_ids"].astype(np.int64),
                "attention_mask": enc["attention_mask"].astype(np.int64),
            })
        self.pos = 0

    def get_next(self):
        if self.pos >= len(self.data):
            return None
        item = self.data[self.pos]
        self.pos += 1
        return item

    def rewind(self):
        self.pos = 0


# ===========================================================================
# Main
# ===========================================================================

def main():
    parser = argparse.ArgumentParser(description="Static INT8 quantization for ONNX encoder")
    parser.add_argument("--input", required=True, help="Path to encoder.onnx")
    parser.add_argument("--output", required=True, help="Output directory")
    parser.add_argument("--hf-dir", required=True, help="HF model dir (for tokenizer)")
    parser.add_argument("--calibration-data", required=True, help="Text file, one sentence per line")
    args = parser.parse_args()

    input_path = Path(args.input)
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    if not input_path.exists():
        print(f"ERROR: encoder model not found: {input_path}", file=sys.stderr)
        sys.exit(1)

    print("=" * 60)
    print("Encoder INT8 Quantization [static]")
    print(f"  Input:  {input_path}")
    print(f"  Output: {output_dir}")
    print("=" * 60)

    # ---- Load ----
    tokenizer = AutoTokenizer.from_pretrained(args.hf_dir)
    texts = load_calibration_texts(args.calibration_data)

    print("\n[1/2] Weight-quantizing encoder ...")
    enc_model = onnx.load(str(input_path))
    orig_size = input_path.stat().st_size / 1e6
    print(f"      {orig_size:.1f} MB, {len(enc_model.graph.initializer)} init, {len(enc_model.graph.node)} nodes")
    quant_info = quantize_model(enc_model)
    print(f"      {len(quant_info)} weights quantized")

    # ---- Static calibration ----
    print("\n[2/2] Static activation calibration ...")
    tmp_wq = output_dir / "_enc_wq.onnx"
    onnx.save(enc_model, str(tmp_wq))
    enc_reader = EncoderCalibrationReader(tokenizer, texts)
    tmp_static = output_dir / "_enc_static.onnx"
    apply_static_activations(tmp_wq, tmp_static, enc_reader)
    shutil.move(str(tmp_static), str(output_dir / "encoder.onnx"))
    tmp_wq.unlink()
    print("      OK")

    # ---- Verify ----
    onnx.checker.check_model(str(output_dir / "encoder.onnx"))
    print("      ONNX check passed")

    # ---- Summary ----
    out_path = output_dir / "encoder.onnx"
    new_size = out_path.stat().st_size / 1e6
    print(f"\n  {orig_size:.1f} MB -> {new_size:.1f} MB  (-{(1 - new_size / orig_size) * 100:.0f}%)")
    print("=" * 60)


if __name__ == "__main__":
    main()
