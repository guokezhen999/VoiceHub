#!/usr/bin/env python3
"""
INT8 quantization for ONNX encoder/decoder models.

Two methods:
  dynamic   Quantize only weights (MatMul → INT8). No calibration needed. Fast.
  static    Quantize weights + activations. Needs calibration data. Better perf.

Usage:
    # Dynamic (default)
    python quantize.py --input ./onnx/ --output ./onnx_int8/

    # Static with calibration data
    python quantize.py --input ./onnx/ --output ./onnx_int8/ --method static \\
        --hf-dir ./hf/ --calibration-data ./calib.txt
"""

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
from onnxruntime.quantization import QuantType, CalibrationDataReader
from onnxruntime.quantization import quantize_dynamic, quantize_static
from transformers import AutoTokenizer


# ---------------------------------------------------------------------------
# Calibration data readers (for static quantization)
# ---------------------------------------------------------------------------

class EncoderCalibrationReader(CalibrationDataReader):
    """Feeds (input_ids, attention_mask) from tokenized calibration texts."""

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


class DecoderCalibrationReader(CalibrationDataReader):
    """Feeds (input_ids, encoder_hidden_states, encoder_attention_mask).

    Runs the FP32 encoder first to collect encoder_hidden_states for each
    calibration text, then pairs them with decoder_start_token as input.

    Used for the OLD ONNX format where decoder_model.onnx takes
    encoder_hidden_states directly (no KV cache).
    """

    def __init__(self, encoder_session, tokenizer, texts, max_len=128,
                 decoder_start_token_id=0):
        self.data = []
        for text in texts:
            enc = tokenizer(text, return_tensors="np", max_length=max_len,
                            truncation=True, padding="max_length")
            input_ids = enc["input_ids"].astype(np.int64)
            attention_mask = enc["attention_mask"].astype(np.int64)

            # Run encoder to get hidden states.
            enc_out = encoder_session.run(
                ["last_hidden_state"],
                {"input_ids": input_ids, "attention_mask": attention_mask},
            )[0]

            self.data.append({
                "input_ids": np.array([[decoder_start_token_id]], dtype=np.int64),
                "encoder_hidden_states": enc_out.astype(np.float32),
                "encoder_attention_mask": attention_mask.astype(np.int64),
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


class DecoderStepCalibrationReader(CalibrationDataReader):
    """Feeds (input_ids, past_key_values.*) for the KV-cache step decoder.

    Runs the FP32 encoder + decoder_model_init.onnx first to collect initial
    past KV tensors for each calibration text, then maps them to the step
    decoder's input names.

    Used for the NEW ONNX format where decoder_model.onnx caches cross-attention
    KVs and does NOT take encoder_hidden_states.
    """

    def __init__(self, encoder_session, init_decoder_session, tokenizer, texts,
                 max_len=128, decoder_start_token_id=0):
        # Discover KV output→input name mapping from init → step decoder.
        # init decoder outputs: present.{i}.{decoder,encoder}.{key,value}
        # step decoder inputs:  past_key_values.{i}.{decoder,encoder}.{key,value}
        init_output_names = [o.name for o in init_decoder_session.get_outputs()]
        self._kv_output_names = [n for n in init_output_names if n != "logits"]

        self.data = []
        for text in texts:
            enc = tokenizer(text, return_tensors="np", max_length=max_len,
                            truncation=True, padding="max_length")
            input_ids_enc = enc["input_ids"].astype(np.int64)
            attention_mask = enc["attention_mask"].astype(np.int64)

            # Step 1: run encoder.
            enc_out = encoder_session.run(
                ["last_hidden_state"],
                {"input_ids": input_ids_enc, "attention_mask": attention_mask},
            )[0]

            # Step 2: run init decoder to get initial past KVs.
            init_inputs = {
                "input_ids": np.array([[decoder_start_token_id]], dtype=np.int64),
                "encoder_hidden_states": enc_out.astype(np.float32),
                "encoder_attention_mask": attention_mask.astype(np.int64),
            }
            init_outputs = init_decoder_session.run(None, init_inputs)
            kv_dict = dict(zip(init_output_names, init_outputs))

            # Step 3: build calibration dict for step decoder.
            # Map present.{i}.* → past_key_values.{i}.*
            sample = {
                "input_ids": np.array([[decoder_start_token_id]], dtype=np.int64),
            }
            for out_name in self._kv_output_names:
                in_name = out_name.replace("present", "past_key_values")
                sample[in_name] = kv_dict[out_name].astype(np.float32)
            self.data.append(sample)

        self.pos = 0

    def get_next(self):
        if self.pos >= len(self.data):
            return None
        item = self.data[self.pos]
        self.pos += 1
        return item

    def rewind(self):
        self.pos = 0


# ---------------------------------------------------------------------------
# Decoder format detection
# ---------------------------------------------------------------------------

def _decoder_input_names(decoder_onnx_path: Path):
    """Return the set of input names for a decoder ONNX model."""
    m = onnx.load(str(decoder_onnx_path))
    return {i.name for i in m.graph.input}


def _uses_kv_cache(decoder_onnx_path: Path) -> bool:
    """Return True if the decoder uses past_key_values (new KV-cache format)."""
    names = _decoder_input_names(decoder_onnx_path)
    return any(n.startswith("past_key_values") for n in names)


# ---------------------------------------------------------------------------
# Quantization
# ---------------------------------------------------------------------------

def quantize_onnx_model(input_path, output_path, weight_type=QuantType.QInt8):
    """Dynamic quantization — weights only, no calibration needed.

    Only quantizes MatMul weights.  Do NOT use EnableSubgraph — it causes
    the quantizer to aggressively quantize intermediate activations
    (Softmax, LayerNorm, Sigmoid, attention Mul ops), which destroys
    precision in the decoder's cross-attention and produces garbage output.
    """
    print(f"      [dynamic] {input_path.name} ...")
    t0 = time.monotonic()
    quantize_dynamic(
        model_input=str(input_path),
        model_output=str(output_path),
        weight_type=weight_type,
        op_types_to_quantize=["MatMul", "Gather"],
    )
    onnx.checker.check_model(str(output_path))
    _report(input_path, output_path, time.monotonic() - t0)


def quantize_onnx_model_static(input_path, output_path, reader,
                               weight_type=QuantType.QInt8):
    """Static quantization — weights + activations, uses calibration data.

    Same note as dynamic: do NOT use EnableSubgraph as it destroys
    decoder precision."""
    print(f"      [static]  {input_path.name} ...")
    t0 = time.monotonic()
    quantize_static(
        model_input=str(input_path),
        model_output=str(output_path),
        calibration_data_reader=reader,
        weight_type=weight_type,
        op_types_to_quantize=["MatMul", "Gather"],
    )
    onnx.checker.check_model(str(output_path))
    reader.rewind()
    _report(input_path, output_path, time.monotonic() - t0)


def _report(input_path, output_path, elapsed):
    in_size = input_path.stat().st_size / 1_000_000
    out_size = output_path.stat().st_size / 1_000_000
    reduction = (1.0 - out_size / in_size) * 100 if in_size > 0 else 0.0
    print(f"        {in_size:.1f} MB → {out_size:.1f} MB  "
          f"(-{reduction:.0f}%)  [{elapsed:.1f}s]")


def load_calibration_texts(path, max_lines=500):
    """Read calibration texts from a file, one sentence per line."""
    texts = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                texts.append(line)
                if len(texts) >= max_lines:
                    break
    if not texts:
        print("ERROR: calibration data file is empty.", file=sys.stderr)
        sys.exit(1)
    print(f"      Loaded {len(texts)} calibration lines from {path}")
    return texts


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="INT8 quantization for ONNX encoder/decoder models"
    )
    parser.add_argument("--input", required=True,
                        help="Directory containing encoder_model.onnx and decoder_model.onnx")
    parser.add_argument("--output", required=True,
                        help="Output directory for quantized ONNX models")
    parser.add_argument("--method", default="dynamic", choices=["dynamic", "static"],
                        help="dynamic = weights only  |  static = weights + activations")
    parser.add_argument("--hf-dir",
                        help="[static] HF model dir (for tokenizer)")
    parser.add_argument("--calibration-data",
                        help="[static] Text file, one sentence per line")
    parser.add_argument("--max-calib-lines", type=int, default=500,
                        help="[static] Max calibration lines to use (default: 500)")
    parser.add_argument("--max-seq-len", type=int, default=128,
                        help="[static] Max tokenized sequence length (default: 128)")
    args = parser.parse_args()

    if args.method == "static":
        if not args.hf_dir or not args.calibration_data:
            print("ERROR: --method static requires --hf-dir and --calibration-data.", file=sys.stderr)
            sys.exit(1)

    input_dir = Path(args.input)
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    encoder_in = input_dir / "encoder_model.onnx"
    decoder_in = input_dir / "decoder_model.onnx"
    encoder_out = output_dir / "encoder_model.onnx"
    decoder_out = output_dir / "decoder_model.onnx"

    if not encoder_in.exists() or not decoder_in.exists():
        print(f"ERROR: {encoder_in} or {decoder_in} not found.", file=sys.stderr)
        sys.exit(1)

    print("=" * 60)
    print(f"INT8 Quantization  [{args.method}]")
    print(f"  Input:  {input_dir}")
    print(f"  Output: {output_dir}")
    print("=" * 60)
    print("")

    if args.method == "dynamic":
        # ---- dynamic ----------------------------------------------------------
        print("[1/2] Encoder")
        quantize_onnx_model(encoder_in, encoder_out)
        print("[2/2] Decoder")
        quantize_onnx_model(decoder_in, decoder_out)

    else:
        # ---- static -----------------------------------------------------------
        texts = load_calibration_texts(args.calibration_data, args.max_calib_lines)

        print("[0/3] Loading tokenizer ...")
        tokenizer = AutoTokenizer.from_pretrained(args.hf_dir)
        decoder_start = getattr(tokenizer, "decoder_start_token_id", 0) or 0

        # Check decoder format: old (encoder_hidden_states) vs new (KV cache).
        is_kv = _uses_kv_cache(decoder_in)
        print(f"      Decoder format: {'KV-cache (new)' if is_kv else 'encoder_hidden_states (old)'}")

        # Encoder.
        print("[1/3] Encoder (static)")
        enc_reader = EncoderCalibrationReader(tokenizer, texts, args.max_seq_len)
        quantize_onnx_model_static(encoder_in, encoder_out, enc_reader)

        # Decoder.
        print("[2/3] Decoder (static) ...")
        enc_sess = ort.InferenceSession(str(encoder_in))

        if is_kv:
            # New KV-cache format: need decoder_model_init.onnx to generate
            # past KVs for calibration. Fall back to dynamic if unavailable.
            init_path = input_dir / "decoder_model_init.onnx"
            if not init_path.exists():
                print(f"      WARNING: {init_path.name} not found, "
                      f"falling back to dynamic quantization for decoder.")
                quantize_onnx_model(decoder_in, decoder_out)
            else:
                init_sess = ort.InferenceSession(str(init_path))
                dec_reader = DecoderStepCalibrationReader(
                    enc_sess, init_sess, tokenizer, texts,
                    args.max_seq_len, decoder_start,
                )
                quantize_onnx_model_static(decoder_in, decoder_out, dec_reader)
        else:
            # Old format: decoder takes encoder_hidden_states directly.
            dec_reader = DecoderCalibrationReader(
                enc_sess, tokenizer, texts, args.max_seq_len, decoder_start,
            )
            quantize_onnx_model_static(decoder_in, decoder_out, dec_reader)

    # ---- summary ------------------------------------------------------------
    print("")
    print("=" * 60)
    print("Quantization complete!")
    print(f"Output: {output_dir}")
    for f in sorted(output_dir.iterdir()):
        print(f"  {f.name}  ({f.stat().st_size / 1_000_000:.1f} MB)")
    print("=" * 60)


if __name__ == "__main__":
    main()
