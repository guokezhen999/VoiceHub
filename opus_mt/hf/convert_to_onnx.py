#!/usr/bin/env python3
"""
Convert a downloaded opus-mt (MarianMT) model to ONNX format.

Exports:
  - encoder.onnx               : standalone encoder
  - decoder_model_init.onnx    : first-step decoder (no past KV, computes cross-attention)
  - decoder_model.onnx         : incremental decoder (with past KV, reuses cross-attention)

Usage:
    python convert_to_onnx.py --input ./model_cache/ --output ./onnx_models/
"""

import argparse
import json
import shutil
import sys
from pathlib import Path

import onnx
import torch
import torch.nn as nn
from transformers import AutoModelForSeq2SeqLM

_ft = torch.float32


# ---------------------------------------------------------------------------
# Wrapper classes
# ---------------------------------------------------------------------------

class EncoderOnnx(nn.Module):
    """Wraps Marian encoder so it accepts int64 input_ids directly."""

    def __init__(self, full_model):
        super().__init__()
        self.shared = full_model.model.shared
        self.encoder = full_model.model.encoder
        cfg = full_model.config
        self.embed_scale = float(cfg.d_model) ** 0.5 if cfg.scale_embedding else 1.0

    def forward(
        self,
        input_ids: torch.Tensor,
        attention_mask: torch.Tensor,
    ) -> torch.Tensor:
        inputs_embeds = self.shared(input_ids.to(torch.int64)) * self.embed_scale
        out = self.encoder(
            inputs_embeds=inputs_embeds,
            attention_mask=attention_mask,
            return_dict=True,
        )
        return out.last_hidden_state


class DecoderFullOnnx(nn.Module):
    """Full decoder WITHOUT KV cache — used for quantization calibration only.
    All layers run in a single consistent pass, producing correct activation
    ranges for static quantization.  The quantized weights and activation
    scales are then injected into decoder_init and decoder_step."""

    def __init__(self, full_model: nn.Module):
        super().__init__()
        self.decoder = full_model.model.decoder
        self.lm_head = full_model.lm_head
        self.final_logits_bias = full_model.final_logits_bias

    def forward(
        self,
        input_ids: torch.Tensor,              # [batch, dec_seq]
        encoder_hidden_states: torch.Tensor,  # [batch, enc_seq, d_model]
        encoder_attention_mask: torch.Tensor, # [batch, enc_seq]
    ) -> torch.Tensor:
        out = self.decoder(
            input_ids=input_ids,
            encoder_hidden_states=encoder_hidden_states,
            encoder_attention_mask=encoder_attention_mask,
            past_key_values=None,
            use_cache=False,
            return_dict=True,
        )
        hidden = out.last_hidden_state
        logits = self.lm_head(hidden) + self.final_logits_bias
        return logits


class DecoderInitOnnx(nn.Module):
    """First-step decoder: takes encoder_hidden_states, NO past KV.
    Outputs logits + ALL past KVs (self-attn + cross-attn, 4 per layer)."""

    def __init__(self, full_model: nn.Module, num_layers: int):
        super().__init__()
        self.decoder = full_model.model.decoder
        self.lm_head = full_model.lm_head
        self.final_logits_bias = full_model.final_logits_bias
        self.num_layers = num_layers

    def forward(
        self,
        input_ids: torch.Tensor,                  # [batch, 1]
        encoder_hidden_states: torch.Tensor,      # [batch, enc_seq, d_model]
        encoder_attention_mask: torch.Tensor,     # [batch, enc_seq]
    ):
        out = self.decoder(
            input_ids=input_ids,
            encoder_hidden_states=encoder_hidden_states,
            encoder_attention_mask=encoder_attention_mask,
            past_key_values=None,
            use_cache=True,
            return_dict=True,
        )
        hidden = out.last_hidden_state
        logits = self.lm_head(hidden) + self.final_logits_bias

        cache = out.past_key_values
        results = [logits]
        for i in range(self.num_layers):
            results.append(cache.self_attention_cache[i][0])   # decoder key   (sk)
            results.append(cache.self_attention_cache[i][1])   # decoder value (sv)
            results.append(cache.cross_attention_cache[i][0])  # encoder key   (ek)
            results.append(cache.cross_attention_cache[i][1])  # encoder value (ev)
        return tuple(results)


class DecoderStepOnnx(nn.Module):
    """Incremental-step decoder: caches all KVs (4 per layer).
    Self-attention KVs are updated; cross-attention KVs are passed through
    unchanged.  Outputs 4 KVs per layer (same as init decoder).

    NOTE: encoder_hidden_states must still be passed so the decoder's
    cross-attention layer runs (it uses cached K/V internally), otherwise
    cross-attention is skipped entirely, producing garbage output."""

    def __init__(self, full_model: nn.Module, num_layers: int):
        super().__init__()
        self.decoder = full_model.model.decoder
        self.lm_head = full_model.lm_head
        self.final_logits_bias = full_model.final_logits_bias
        self.num_layers = num_layers

    def forward(
        self,
        input_ids: torch.Tensor,                  # [batch, 1]
        encoder_hidden_states: torch.Tensor,      # [batch, enc_seq, d_model]
        encoder_attention_mask: torch.Tensor,     # [batch, enc_seq]
        *past_kvs: torch.Tensor,                  # 4 * num_layers: sk, sv, ek, ev
    ):
        pkv_flat = list(past_kvs)
        pkv = tuple(
            (pkv_flat[4 * i], pkv_flat[4 * i + 1],
             pkv_flat[4 * i + 2], pkv_flat[4 * i + 3])
            for i in range(self.num_layers)
        )

        out = self.decoder(
            input_ids=input_ids,
            encoder_hidden_states=encoder_hidden_states,
            encoder_attention_mask=encoder_attention_mask,
            past_key_values=pkv,
            use_cache=True,
            return_dict=True,
        )

        hidden = out.last_hidden_state
        logits = self.lm_head(hidden) + self.final_logits_bias

        cache = out.past_key_values
        results = [logits]
        for i in range(self.num_layers):
            results.append(cache.self_attention_cache[i][0])   # dk (updated)
            results.append(cache.self_attention_cache[i][1])   # dv (updated)
            results.append(cache.cross_attention_cache[i][0])  # ek (unchanged)
            results.append(cache.cross_attention_cache[i][1])  # ev (unchanged)
        return tuple(results)


# ---------------------------------------------------------------------------
# ONNX export helpers
# ---------------------------------------------------------------------------

def _consolidate_onnx(path: Path):
    data_file = Path(str(path) + ".data")
    if not data_file.exists():
        return
    m = onnx.load(str(path))
    onnx.save(m, str(path))
    data_file.unlink()
    print(f"      Consolidated external data into {path.name}")


def _build_kv_names(prefix: str, num_layers: int):
    """4 KVs per layer: decoder.key, decoder.value, encoder.key, encoder.value."""
    names = []
    for i in range(num_layers):
        for ktype in ("decoder.key", "decoder.value",
                       "encoder.key", "encoder.value"):
            names.append(f"{prefix}.{i}.{ktype}")
    return names


def _build_self_kv_names(prefix: str, num_layers: int):
    """2 KVs per layer: decoder.key, decoder.value (self-attention only)."""
    names = []
    for i in range(num_layers):
        for ktype in ("decoder.key", "decoder.value"):
            names.append(f"{prefix}.{i}.{ktype}")
    return names


def _kv_names_list(num_layers: int):
    """Return 4*layers individual parameter name strings."""
    names = []
    for i in range(num_layers):
        for kt in ("dk", "dv", "ek", "ev"):
            names.append(f"pkv_{i}_{kt}")
    return names


def export_encoder(model, output_path: Path, enc_seq_len: int = 16):
    wrapper = EncoderOnnx(model)
    wrapper.eval()

    dummy_ids = torch.zeros(1, enc_seq_len, dtype=torch.int64)
    dummy_mask = torch.ones(1, enc_seq_len, dtype=torch.int64)

    print(f"      Tracing encoder with input shape [1, {enc_seq_len}] ...")
    torch.onnx.export(
        wrapper,
        (dummy_ids, dummy_mask),
        str(output_path),
        input_names=["input_ids", "attention_mask"],
        output_names=["last_hidden_state"],
        dynamic_axes={
            "input_ids": {0: "batch_size", 1: "sequence_length"},
            "attention_mask": {0: "batch_size", 1: "sequence_length"},
            "last_hidden_state": {0: "batch_size", 1: "sequence_length"},
        },
        opset_version=18,
        do_constant_folding=False,
        dynamo=False,
    )
    _consolidate_onnx(output_path)
    size_mb = output_path.stat().st_size / 1_000_000
    print(f"      Exported: {output_path.name}  ({size_mb:.1f} MB)")


def export_decoder_full(model, output_path: Path, enc_seq_len: int = 16):
    """Export full decoder WITHOUT KV cache — for quantization calibration only.

    This model has ALL weights and consistent activation distributions across
    all layers, making it the ideal target for static quantization.  The
    resulting quantization parameters are then injected into the split
    decoder_init + decoder_step models that are actually used at runtime."""
    d_model = model.config.d_model
    dec_seq_len = 4  # must be > 1 to trace the multi-token attention path

    wrapper = DecoderFullOnnx(model)
    wrapper.eval()

    dummy_ids = torch.zeros(1, dec_seq_len, dtype=torch.int64)
    dummy_enc = torch.randn(1, enc_seq_len, d_model, dtype=_ft)
    dummy_mask = torch.ones(1, enc_seq_len, dtype=torch.int64)

    input_names = ["input_ids", "encoder_hidden_states", "encoder_attention_mask"]
    output_names = ["logits"]

    print(f"      Tracing decoder_full (no KV cache, enc_seq={enc_seq_len}, dec_seq={dec_seq_len}) ...")
    torch.onnx.export(
        wrapper,
        (dummy_ids, dummy_enc, dummy_mask),
        str(output_path),
        input_names=input_names,
        output_names=output_names,
        dynamic_axes={
            "input_ids": {0: "batch_size", 1: "decoder_sequence_length"},
            "encoder_hidden_states": {0: "batch_size", 1: "encoder_sequence_length"},
            "encoder_attention_mask": {0: "batch_size", 1: "encoder_sequence_length"},
            "logits": {0: "batch_size", 1: "decoder_sequence_length"},
        },
        opset_version=18,
        do_constant_folding=False,
        dynamo=False,
    )
    _consolidate_onnx(output_path)
    print(f"      Exported: {output_path.name}  ({output_path.stat().st_size / 1_000_000:.1f} MB)")


def export_decoder_init(model, output_path: Path, enc_seq_len: int = 16):
    """Export first-step decoder (no past KV, computes cross-attention KVs)."""
    num_layers = model.config.decoder_layers
    d_model = model.config.d_model

    wrapper = DecoderInitOnnx(model, num_layers)
    wrapper.eval()

    dummy_ids = torch.zeros(1, 1, dtype=torch.int64)
    dummy_enc = torch.randn(1, enc_seq_len, d_model)
    dummy_mask = torch.ones(1, enc_seq_len, dtype=torch.int64)

    input_names = ["input_ids", "encoder_hidden_states", "encoder_attention_mask"]
    output_names = ["logits"] + _build_kv_names("present", num_layers)

    dynamic_axes = {
        "input_ids": {0: "batch_size"},
        "encoder_hidden_states": {0: "batch_size", 1: "encoder_sequence_length"},
        "encoder_attention_mask": {0: "batch_size", 1: "encoder_sequence_length"},
        "logits": {0: "batch_size"},
    }
    for i in range(num_layers):
        for kt in ("decoder.key", "decoder.value"):
            dynamic_axes[f"present.{i}.{kt}"] = {
                0: "batch_size", 2: f"past_len_{i}"
            }
        for kt in ("encoder.key", "encoder.value"):
            dynamic_axes[f"present.{i}.{kt}"] = {
                0: "batch_size", 2: "encoder_sequence_length"
            }

    print(f"      Tracing decoder_init (enc_seq={enc_seq_len}) ...")
    torch.onnx.export(
        wrapper,
        (dummy_ids, dummy_enc, dummy_mask),
        str(output_path),
        input_names=input_names,
        output_names=output_names,
        dynamic_axes=dynamic_axes,
        opset_version=18,
        do_constant_folding=False,
        dynamo=False,
    )
    _consolidate_onnx(output_path)
    print(f"      Exported: {output_path.name}  ({output_path.stat().st_size / 1_000_000:.1f} MB)")


def export_decoder_step(model, output_path: Path, enc_seq_len: int = 16):
    """Export incremental-step decoder.

    Input:  encoder_hidden_states + 4 KVs per layer (sk, sv, ek, ev).
    Cross-attn KVs from step 1 are reused.
    Output: 4 KVs per layer (sk, sv updated; ek, ev pass-through)."""
    num_layers = model.config.decoder_layers
    num_heads = model.config.decoder_attention_heads
    d_model = model.config.d_model
    head_dim = d_model // num_heads

    wrapper = DecoderStepOnnx(model, num_layers)
    wrapper.eval()

    dummy_ids = torch.zeros(1, 1, dtype=torch.int64)
    dummy_enc = torch.randn(1, enc_seq_len, d_model)
    dummy_mask = torch.ones(1, enc_seq_len, dtype=torch.int64)

    dummy_past_len = 2
    dummy_kv_list = []
    for i in range(num_layers):
        dummy_kv_list.append(torch.randn(1, num_heads, dummy_past_len, head_dim, dtype=_ft))   # sk
        dummy_kv_list.append(torch.randn(1, num_heads, dummy_past_len, head_dim, dtype=_ft))   # sv
        dummy_kv_list.append(torch.randn(1, num_heads, enc_seq_len, head_dim, dtype=_ft))      # ek
        dummy_kv_list.append(torch.randn(1, num_heads, enc_seq_len, head_dim, dtype=_ft))      # ev

    input_names = ["input_ids", "encoder_hidden_states", "encoder_attention_mask"]
    input_names += _build_kv_names("past_key_values", num_layers)
    output_names = ["logits"] + _build_kv_names("present", num_layers)

    dynamic_axes = {
        "input_ids": {0: "batch_size"},
        "encoder_hidden_states": {0: "batch_size", 1: "encoder_sequence_length"},
        "encoder_attention_mask": {0: "batch_size", 1: "encoder_sequence_length"},
        "logits": {0: "batch_size"},
    }
    for i in range(num_layers):
        for kt in ("decoder.key", "decoder.value"):
            dynamic_axes[f"past_key_values.{i}.{kt}"] = {0: "batch_size", 2: f"past_len_{i}"}
            dynamic_axes[f"present.{i}.{kt}"] = {0: "batch_size", 2: f"past_len_{i}"}
        for kt in ("encoder.key", "encoder.value"):
            dynamic_axes[f"past_key_values.{i}.{kt}"] = {0: "batch_size", 2: "encoder_sequence_length"}

    print(f"      Tracing decoder_step (enc_seq={enc_seq_len}, past_len={dummy_past_len}) ...")
    torch.onnx.export(
        wrapper,
        (dummy_ids, dummy_enc, dummy_mask, *dummy_kv_list),
        str(output_path),
        input_names=input_names,
        output_names=output_names,
        dynamic_axes=dynamic_axes,
        opset_version=18,
        do_constant_folding=False,
        dynamo=False,
    )
    _consolidate_onnx(output_path)
    print(f"      Exported: {output_path.name}  ({output_path.stat().st_size / 1_000_000:.1f} MB)")


# ---------------------------------------------------------------------------
# Config & vocab helpers
# ---------------------------------------------------------------------------

def _or_default(value, default):
    """Return value if not None, otherwise default.  Prevents null in config.json."""
    return value if value is not None else default


def extract_config_json(model, output_dir: Path):
    c = model.config
    cfg = {
        "model_type": c.model_type,
        "architectures": list(c.architectures),
        "vocab_size": _or_default(c.vocab_size, 0),
        "d_model": _or_default(c.d_model, 0),
        "encoder_layers": _or_default(c.encoder_layers, 0),
        "decoder_layers": _or_default(c.decoder_layers, 0),
        "encoder_attention_heads": _or_default(c.encoder_attention_heads, 0),
        "decoder_attention_heads": _or_default(c.decoder_attention_heads, 0),
        "decoder_ffn_dim": _or_default(c.decoder_ffn_dim, 0),
        "max_position_embeddings": _or_default(c.max_position_embeddings, 0),
        "max_length": _or_default(getattr(c, "max_length", None), 512),
        "pad_token_id": _or_default(c.pad_token_id, 0),
        "eos_token_id": _or_default(c.eos_token_id, 0),
        "bos_token_id": _or_default(c.bos_token_id, 0),
        "unk_token_id": _or_default(getattr(c, "unk_token_id", None), 1),
        "decoder_start_token_id": _or_default(c.decoder_start_token_id, 0),
        "use_cache": True,
        "activation_function": c.activation_function,
    }
    path = output_dir / "config.json"
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print(f"      Saved: {path.name}")


def copy_vocab_and_spm(input_dir: Path, output_dir: Path):
    for name in ["vocab.json", "source.spm", "target.spm", "tokenizer.json"]:
        src = input_dir / name
        if src.exists():
            dst = output_dir / name
            shutil.copy2(src, dst)
            print(f"      Copied: {name}  ({dst.stat().st_size:,} B)")
        else:
            print(f"      Skipped (not found): {name}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Convert a MarianMT model (opus-mt) to ONNX format"
    )
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--enc-seq-len", type=int, default=16)
    parser.add_argument("--fp16", action="store_true", help="Export in FP16 precision")
    args = parser.parse_args()

    input_dir = Path(args.input)
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    if not (input_dir / "config.json").exists():
        print(f"ERROR: {input_dir}/config.json not found.", file=sys.stderr)
        sys.exit(1)

    print(f"[1/7] Loading model from {input_dir} ...")
    model = AutoModelForSeq2SeqLM.from_pretrained(
        str(input_dir), attn_implementation="eager")
    global _ft
    if args.fp16:
        model = model.half()
        _ft = torch.float16
        torch.set_default_dtype(torch.float16)
        print("      Converted to FP16")
    model.eval()
    config = model.config
    print(f"      Architecture:  {config.architectures[0]}")
    print(f"      d_model:       {config.d_model}")
    print(f"      Enc layers:    {config.encoder_layers}")
    print(f"      Dec layers:    {config.decoder_layers}")
    print(f"      Heads:         {config.decoder_attention_heads}")
    print(f"      Vocab size:    {config.vocab_size}")

    print("[2/7] Exporting encoder ...")
    export_encoder(model, output_dir / "encoder.onnx", args.enc_seq_len)

    print("[3/7] Exporting decoder_full (no KV cache, for quantization calibration) ...")
    export_decoder_full(model, output_dir / "decoder_model_full.onnx", args.enc_seq_len)

    print("[4/7] Exporting decoder_init (first step, computes cross-attn KVs) ...")
    export_decoder_init(model, output_dir / "decoder_model_init.onnx", args.enc_seq_len)

    print("[5/7] Exporting decoder_step (incremental, reuses cross-attn KVs) ...")
    export_decoder_step(model, output_dir / "decoder_model.onnx", args.enc_seq_len)

    print("[6/7] Copying vocab and SentencePiece files ...")
    copy_vocab_and_spm(input_dir, output_dir)

    print("[7/7] Writing config.json ...")
    extract_config_json(model, output_dir)

    print("")
    print("=" * 60)
    print("ONNX conversion complete!")
    print(f"Output: {output_dir}")
    for f in sorted(output_dir.iterdir()):
        size = f.stat().st_size
        if size > 1_000_000:
            print(f"  {f.name}  ({size / 1_000_000:.1f} MB)")
        else:
            print(f"  {f.name}  ({size:,} B)")
    print("=" * 60)


if __name__ == "__main__":
    main()
