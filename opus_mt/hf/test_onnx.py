#!/usr/bin/env python3
"""
End-to-end test for ONNX opus-mt-zh-en models with KV cache.

Tests the exported ONNX models (encoder, decoder_init, decoder_step) by:
  1. Running auto-regressive translation with KV cache using ONNX Runtime.
  2. Comparing token-by-token logits against the original HuggingFace model.
  3. Checking that the ONNX-generated translation matches the HF model's output.

Usage:
    python opus_mt/hf/test_onnx.py

Requires:
    conda activate opus-onnx
"""

import argparse
import json
import time
from pathlib import Path

import numpy as np
import onnxruntime as ort
import torch
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

MODEL_DIR = Path(__file__).resolve().parent.parent / "model" / "opus-mt-zh-en"
HF_DIR = MODEL_DIR / "hf"
ONNX_DIR = MODEL_DIR / "onnx"

# ---------------------------------------------------------------------------
# Test sentences (Chinese → English)
# ---------------------------------------------------------------------------

TEST_TEXTS = [
    "你好，今天天气怎么样？",
    "谢谢你帮助我。",
    "对不起，我没听懂你刚才说的话，能重复一遍吗？",
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _map_init_output_to_step_input(init_outputs: dict, step_input_names: list,
                                   num_layers: int) -> dict:
    """Map decoder_init outputs (present.{i}.*) → decoder_step inputs (past_key_values.{i}.*)."""
    mapped = {}
    for i in range(num_layers):
        for kt in ("decoder.key", "decoder.value", "encoder.key", "encoder.value"):
            src_name = f"present.{i}.{kt}"
            dst_name = f"past_key_values.{i}.{kt}"
            if dst_name in step_input_names and src_name in init_outputs:
                mapped[dst_name] = init_outputs[src_name]
    return mapped


def _map_step_output_to_step_input(step_outputs: dict, step_input_names: list,
                                   num_layers: int) -> dict:
    """Map decoder_step outputs (present.{i}.*) → next step inputs (past_key_values.{i}.*)."""
    mapped = {}
    for i in range(num_layers):
        for kt in ("decoder.key", "decoder.value", "encoder.key", "encoder.value"):
            src_name = f"present.{i}.{kt}"
            dst_name = f"past_key_values.{i}.{kt}"
            if dst_name in step_input_names and src_name in step_outputs:
                mapped[dst_name] = step_outputs[src_name]
    return mapped


# ---------------------------------------------------------------------------
# ONNX translation with KV cache
# ---------------------------------------------------------------------------

def translate_onnx(
    enc_sess: ort.InferenceSession,
    init_sess: ort.InferenceSession,
    step_sess: ort.InferenceSession,
    input_ids: np.ndarray,
    attention_mask: np.ndarray,
    decoder_start_token_id: int,
    eos_token_id: int,
    max_length: int = 128,
) -> list[int]:
    """Auto-regressive translation using ONNX models with KV cache."""

    step_input_names = {i.name for i in step_sess.get_inputs()}
    num_layers = 6  # opus-mt-zh-en has 6 decoder layers
    generated_ids = []

    # --- Step 1: Encoder ---
    enc_inputs = {
        "input_ids": input_ids,
        "attention_mask": attention_mask,
    }
    enc_out = enc_sess.run(["last_hidden_state"], enc_inputs)
    encoder_hidden_states = enc_out[0]  # [batch, enc_seq, d_model]

    # Auto-cast encoder output to match decoder input type (needed for mixed precision)
    init_enc_type = _get_input_type(init_sess, "encoder_hidden_states")
    if init_enc_type is not None and encoder_hidden_states.dtype != init_enc_type:
        encoder_hidden_states = encoder_hidden_states.astype(init_enc_type)

    # --- Step 2: Decoder init (first token) ---
    decoder_input = np.array([[decoder_start_token_id]], dtype=np.int64)
    init_inputs = {
        "input_ids": decoder_input,
        "encoder_hidden_states": encoder_hidden_states,
        "encoder_attention_mask": attention_mask,
    }
    init_outputs = init_sess.run(None, init_inputs)
    init_output_dict = dict(zip(
        [o.name for o in init_sess.get_outputs()], init_outputs
    ))

    logits = init_output_dict["logits"]  # [batch, 1, vocab_size]
    next_token_id = int(np.argmax(logits[0, -1, :]))
    generated_ids.append(next_token_id)

    # KV cache from init
    past_kv_dict = _map_init_output_to_step_input(
        init_output_dict, step_input_names, num_layers
    )

    # Auto-cast KVs to match step input type (needed for mixed precision)
    _cast_kv_types(past_kv_dict, init_sess, step_sess)

    # --- Step 3: Auto-regressive loop ---
    for _ in range(max_length - 1):
        if next_token_id == eos_token_id:
            break

        decoder_input = np.array([[next_token_id]], dtype=np.int64)
        step_inputs = {
            "input_ids": decoder_input,
            "encoder_attention_mask": attention_mask,
            **past_kv_dict,
        }
        step_outputs = step_sess.run(None, step_inputs)
        step_output_dict = dict(zip(
            [o.name for o in step_sess.get_outputs()], step_outputs
        ))

        logits = step_output_dict["logits"]  # [batch, 1, vocab_size]
        next_token_id = int(np.argmax(logits[0, -1, :]))
        generated_ids.append(next_token_id)

        # Update KV cache for next iteration
        past_kv_dict = _map_step_output_to_step_input(
            step_output_dict, step_input_names, num_layers
        )

    return generated_ids


def _get_input_type(sess, name):
    """Return numpy dtype for a named input, or None if not found."""
    for inp in sess.get_inputs():
        if inp.name == name:
            t = inp.type
            if t == "tensor(float16)":
                return np.float16
            elif t == "tensor(float)":
                return np.float32
            elif t == "tensor(int64)":
                return np.int64
    return None


def _cast_kv_types(kv_dict, init_sess, step_sess):
    """Cast KV tensors from init output type to step input type if needed."""
    init_out_type = None
    for out in init_sess.get_outputs():
        if "present" in out.name:
            t = out.type
            if t == "tensor(float16)":
                init_out_type = np.float16
            elif t == "tensor(float)":
                init_out_type = np.float32
            break
    step_in_type = None
    for inp in step_sess.get_inputs():
        if "past_key_values" in inp.name:
            t = inp.type
            if t == "tensor(float16)":
                step_in_type = np.float16
            elif t == "tensor(float)":
                step_in_type = np.float32
            break
    if init_out_type is not None and step_in_type is not None and init_out_type != step_in_type:
        for k in kv_dict:
            kv_dict[k] = kv_dict[k].astype(step_in_type)


# ---------------------------------------------------------------------------
# HF model reference
# ---------------------------------------------------------------------------

def translate_hf(
    model,
    input_ids: torch.Tensor,
    attention_mask: torch.Tensor,
    decoder_start_token_id: int,
    eos_token_id: int,
    max_length: int = 128,
) -> list[int]:
    """Auto-regressive translation using the original HF model (eager / no cache)."""
    model.eval()
    with torch.no_grad():
        generated = model.generate(
            input_ids=input_ids,
            attention_mask=attention_mask,
            decoder_start_token_id=decoder_start_token_id,
            max_length=max_length,
            eos_token_id=eos_token_id,
            use_cache=True,
            do_sample=False,
            num_beams=1,
        )
    return generated[0].tolist()


def get_hf_logits_per_step(
    model,
    input_ids: torch.Tensor,
    attention_mask: torch.Tensor,
    max_length: int = 128,
) -> list[np.ndarray]:
    """Run HF model step by step with KV cache, collecting logits at each step.
    Returns list of logits arrays [step_0, step_1, ...] each [1, vocab_size]."""
    model.eval()
    decoder_start_token_id = model.config.decoder_start_token_id
    eos_token_id = model.config.eos_token_id

    with torch.no_grad():
        # Encoder
        encoder_outputs = model.model.encoder(
            input_ids=input_ids,
            attention_mask=attention_mask,
            return_dict=True,
        )
        encoder_hidden_states = encoder_outputs.last_hidden_state

        # Decoder step 0
        decoder_input = torch.tensor([[decoder_start_token_id]])
        decoder_outputs = model.model.decoder(
            input_ids=decoder_input,
            encoder_hidden_states=encoder_hidden_states,
            encoder_attention_mask=attention_mask,
            past_key_values=None,
            use_cache=True,
            return_dict=True,
        )
        hidden = decoder_outputs.last_hidden_state
        logits_0 = (model.lm_head(hidden) + model.final_logits_bias).squeeze(0).squeeze(0)
        logits_list = [logits_0.cpu().numpy()]

        past_kv = decoder_outputs.past_key_values
        next_token_id = torch.argmax(logits_0[-1]).item()

        for _ in range(max_length - 1):
            if next_token_id == eos_token_id:
                break

            decoder_input = torch.tensor([[next_token_id]])
            decoder_outputs = model.model.decoder(
                input_ids=decoder_input,
                encoder_hidden_states=None,
                encoder_attention_mask=attention_mask,
                past_key_values=past_kv,
                use_cache=True,
                return_dict=True,
            )

            hidden = decoder_outputs.last_hidden_state
            logits_step = (model.lm_head(hidden) + model.final_logits_bias).squeeze(0).squeeze(0)
            logits_list.append(logits_step.cpu().numpy())

            past_kv = decoder_outputs.past_key_values
            next_token_id = torch.argmax(logits_step[-1]).item()

    return logits_list


# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Test ONNX opus-mt-zh-en models")
    parser.add_argument("--onnx-dir", type=str, default=None,
                        help="Custom ONNX model directory")
    args = parser.parse_args()

    if args.onnx_dir:
        onnx_dir = Path(args.onnx_dir)
    else:
        onnx_dir = ONNX_DIR

    print("=" * 70)
    print(f"ONNX opus-mt-zh-en KV-cache E2E Test")
    print(f"Model dir: {onnx_dir}")
    print("=" * 70)

    # -- load tokenizer & HF model --
    print("\n[1/5] Loading tokenizer ...")
    tokenizer = AutoTokenizer.from_pretrained(str(HF_DIR))
    print(f"      vocab_size = {tokenizer.vocab_size}")

    print("[2/5] Loading HF model ...")
    hf_model = AutoModelForSeq2SeqLM.from_pretrained(str(HF_DIR), attn_implementation="eager")
    hf_model.eval()
    cfg = hf_model.config
    print(f"      decoder_start_token_id = {cfg.decoder_start_token_id}")
    print(f"      eos_token_id           = {cfg.eos_token_id}")
    print(f"      pad_token_id           = {cfg.pad_token_id}")

    decoder_start_token_id = cfg.decoder_start_token_id
    eos_token_id = cfg.eos_token_id

    # -- load ONNX models --
    print(f"[3/5] Loading ONNX models from {onnx_dir} ...")
    sess_opts = ort.SessionOptions()
    sess_opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL

    enc_sess = ort.InferenceSession(
        str(onnx_dir / "encoder.onnx"), sess_options=sess_opts, providers=["CPUExecutionProvider"],
    )
    init_sess = ort.InferenceSession(
        str(onnx_dir / "decoder_init.onnx"), sess_options=sess_opts, providers=["CPUExecutionProvider"],
    )
    step_sess = ort.InferenceSession(
        str(onnx_dir / "decoder.onnx"), sess_options=sess_opts, providers=["CPUExecutionProvider"],
    )
    print("      Done.")

    # -- run tests --
    print("\n[4/5] Running E2E translation tests ...")
    print("-" * 70)

    all_passed = True
    for idx, text in enumerate(TEST_TEXTS):
        print(f"\nTest {idx + 1}: {text!r}")

        # Tokenize
        enc = tokenizer(text, return_tensors="np", padding=False)
        input_ids_np = enc["input_ids"].astype(np.int64)
        attention_mask_np = enc["attention_mask"].astype(np.int64)

        # HF reference
        input_ids_pt = torch.tensor(input_ids_np)
        attention_mask_pt = torch.tensor(attention_mask_np)

        t0 = time.monotonic()
        hf_ids = translate_hf(
            hf_model, input_ids_pt, attention_mask_pt,
            decoder_start_token_id, eos_token_id,
        )
        hf_time = time.monotonic() - t0
        hf_text = tokenizer.decode(hf_ids, skip_special_tokens=True)

        # ONNX
        t0 = time.monotonic()
        onnx_ids = translate_onnx(
            enc_sess, init_sess, step_sess,
            input_ids_np, attention_mask_np,
            decoder_start_token_id, eos_token_id,
        )
        onnx_time = time.monotonic() - t0
        onnx_text = tokenizer.decode(onnx_ids, skip_special_tokens=True)

        # Compare token IDs (HF includes decoder_start_token_id in output, ONNX doesn't)
        hf_generated = hf_ids
        if hf_generated and hf_generated[0] == decoder_start_token_id:
            hf_generated = hf_generated[1:]  # strip decoder_start_token_id
        tokens_match = hf_generated == onnx_ids
        match_str = "✓ MATCH" if tokens_match else "✗ MISMATCH"

        print(f"      HF:    {hf_text!r}  ({len(hf_ids)} tokens, {hf_time:.3f}s)")
        print(f"      ONNX:  {onnx_text!r}  ({len(onnx_ids)} tokens, {onnx_time:.3f}s)")
        print(f"      Tokens: {match_str}")

        if not tokens_match:
            all_passed = False
            print(f"      HF tokens:    {hf_ids}")
            print(f"      ONNX tokens:  {onnx_ids}")
            # Also check logit-level comparison
            print("      Running step-by-step logit comparison ...")
            hf_logits = get_hf_logits_per_step(
                hf_model, input_ids_pt, attention_mask_pt)
            # Run ONNX step by step for logit comparison
            # (reuse translate_onnx but collect logits)
            onnx_logits_step = _collect_onnx_logits(
                enc_sess, init_sess, step_sess,
                input_ids_np, attention_mask_np,
                decoder_start_token_id, eos_token_id, len(hf_logits),
            )
            for s, (hl, ol) in enumerate(zip(hf_logits, onnx_logits_step)):
                max_diff = float(np.max(np.abs(hl - ol)))
                status = "OK" if max_diff < 1e-3 else f"DIFF={max_diff:.2e}"
                if max_diff >= 1e-3:
                    all_passed = False
                print(f"        Step {s}: max|logit_diff| = {max_diff:.6f}  [{status}]")
        else:
            # Even when tokens match, do logit comparison for first test
            if idx == 0:
                print("      Running step-by-step logit comparison (test 1) ...")
                hf_logits = get_hf_logits_per_step(
                    hf_model, input_ids_pt, attention_mask_pt)
                onnx_logits_step = _collect_onnx_logits(
                    enc_sess, init_sess, step_sess,
                    input_ids_np, attention_mask_np,
                    decoder_start_token_id, eos_token_id, len(hf_logits),
                )
                for s, (hl, ol) in enumerate(zip(hf_logits, onnx_logits_step)):
                    max_diff = float(np.max(np.abs(hl - ol)))
                    status = "OK" if max_diff < 1e-3 else f"DIFF={max_diff:.2e}"
                    if max_diff >= 1e-3:
                        all_passed = False
                    print(f"        Step {s}: max|logit_diff| = {max_diff:.6f}  [{status}]")

    # -- summary --
    print("\n" + "=" * 70)
    print("[5/5] Summary")
    if all_passed:
        print("      ALL TESTS PASSED ✓")
    else:
        print("      SOME TESTS FAILED ✗")
    print("=" * 70)
    return 0 if all_passed else 1


def _collect_onnx_logits(
    enc_sess, init_sess, step_sess,
    input_ids: np.ndarray,
    attention_mask: np.ndarray,
    decoder_start_token_id: int,
    eos_token_id: int,
    num_steps: int,
) -> list[np.ndarray]:
    """Run ONNX step by step, collecting logits for comparison."""
    step_input_names = {i.name for i in step_sess.get_inputs()}
    num_layers = 6
    logits_list = []

    # Encoder
    enc_out = enc_sess.run(
        ["last_hidden_state"],
        {"input_ids": input_ids, "attention_mask": attention_mask},
    )
    encoder_hidden_states = enc_out[0]

    # Auto-cast to match decoder input type
    init_enc_type = _get_input_type(init_sess, "encoder_hidden_states")
    if init_enc_type is not None and encoder_hidden_states.dtype != init_enc_type:
        encoder_hidden_states = encoder_hidden_states.astype(init_enc_type)

    # Decoder init
    decoder_input = np.array([[decoder_start_token_id]], dtype=np.int64)
    init_outputs = init_sess.run(
        None,
        {
            "input_ids": decoder_input,
            "encoder_hidden_states": encoder_hidden_states,
            "encoder_attention_mask": attention_mask,
        },
    )
    init_output_dict = dict(zip(
        [o.name for o in init_sess.get_outputs()], init_outputs
    ))
    logits_list.append(init_output_dict["logits"][0, 0, :])

    next_token_id = int(np.argmax(init_output_dict["logits"][0, -1, :]))
    past_kv_dict = _map_init_output_to_step_input(
        init_output_dict, step_input_names, num_layers
    )
    _cast_kv_types(past_kv_dict, init_sess, step_sess)

    for _ in range(num_steps - 1):
        if next_token_id == eos_token_id:
            break

        decoder_input = np.array([[next_token_id]], dtype=np.int64)
        step_outputs = step_sess.run(
            None,
            {
                "input_ids": decoder_input,
                "encoder_attention_mask": attention_mask,
                **past_kv_dict,
            },
        )
        step_output_dict = dict(zip(
            [o.name for o in step_sess.get_outputs()], step_outputs
        ))
        logits_list.append(step_output_dict["logits"][0, 0, :])

        past_kv_dict = _map_step_output_to_step_input(
            step_output_dict, step_input_names, num_layers
        )
        next_token_id = int(np.argmax(step_output_dict["logits"][0, -1, :]))

    return logits_list


if __name__ == "__main__":
    raise SystemExit(main())
