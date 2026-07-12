#!/usr/bin/env python3
"""
Convert decoder_model_init.onnx + decoder_model.onnx to share a single
weight file via ONNX external data.

Result:
  decoder.onnx          — lightweight index (~0.4 MB), refs → decoder.onnx.data
  decoder_init.onnx     — lightweight index (~0.4 MB), refs → decoder.onnx.data
  decoder.onnx.data     — all weights (~500 MB, shared + unique)

The 86 shared weights (embed_tokens, layer norms, biases, etc.) are stored
once. Init-only weights (cross-attn k/v proj, unique traced constants) and
step-only weights (unique traced constants) are appended.

Usage:
    python opus_mt/hf/share_weights.py --input opus_mt/model/opus-mt-zh-en/onnx
"""

import argparse
import functools
import operator
import shutil
import sys
from pathlib import Path

import numpy as np
import onnx
from onnx.external_data_helper import convert_model_to_external_data

_ONNX_TO_NP = {
    onnx.TensorProto.FLOAT: np.float32,
    onnx.TensorProto.INT8: np.int8,
    onnx.TensorProto.INT32: np.int32,
    onnx.TensorProto.INT64: np.int64,
    onnx.TensorProto.BOOL: np.bool_,
}


def _tensor_byte_size(t: onnx.TensorProto) -> int:
    """Compute the byte size of a tensor's data as stored in the proto."""
    if len(t.raw_data) > 0:
        return len(t.raw_data)
    # Typed fields — each element takes the field's native size, not dtype
    size = (len(t.float_data) + len(t.int32_data)) * 4 \
         + len(t.int64_data) * 8 \
         + len(t.double_data) * 8
    if size > 0:
        return size
    # Fallback: compute from dtype × dims
    return _compute_byte_size(t)


def _compute_byte_size(t: onnx.TensorProto) -> int:
    """Compute expected byte size from dims and data_type."""
    np_dtype = _ONNX_TO_NP.get(t.data_type, np.float32)
    num_elem = functools.reduce(operator.mul, t.dims, 1) if t.dims else 1
    return num_elem * np.dtype(np_dtype).itemsize


def share_weights(input_dir: Path, output_dir: Path):
    init_path = input_dir / "decoder_model_init.onnx"
    step_path = input_dir / "decoder_model.onnx"

    if not init_path.exists() or not step_path.exists():
        print("ERROR: decoder_model_init.onnx and decoder_model.onnx required", file=sys.stderr)
        sys.exit(1)

    output_dir.mkdir(parents=True, exist_ok=True)

    # ---- Step 1: Convert step model to external data ----
    print("[1/4] Converting step model to external data ...")
    step_model = onnx.load(str(step_path))
    convert_model_to_external_data(
        step_model,
        all_tensors_to_one_file=True,
        location="decoder.onnx.data",  # relative path
        size_threshold=0,
    )

    step_out = output_dir / "decoder.onnx"
    onnx.save(step_model, str(step_out))
    # NOTE: do NOT consolidate — we WANT the .data file to stay separate

    # Reload WITHOUT external data to get clean external_data references
    step_model = onnx.load(str(step_out), load_external_data=False)
    name_to_external = {}
    for t in step_model.graph.initializer:
        if len(t.external_data) > 0:
            ref = {e.key: e.value for e in t.external_data}
            name_to_external[t.name] = ref

    step_onnx_mb = step_out.stat().st_size / 1_000_000
    data_size_mb = (output_dir / "decoder.onnx.data").stat().st_size / 1_000_000
    print(f"      decoder.onnx: {step_onnx_mb:.2f} MB (index)")
    print(f"      decoder.onnx.data: {data_size_mb:.2f} MB ({len(step_model.graph.initializer)} initializers)")
    print(f"      Shared names: {len(name_to_external)}")

    # ---- Step 2: Compute offsets for init model initializers ----
    print("[2/4] Computing external data offsets for init model ...")
    init_model = onnx.load(str(init_path))

    # Find the end of step model's data in the .data file
    max_end = 0
    for ref in name_to_external.values():
        end = int(ref["offset"]) + int(ref["length"])
        if end > max_end:
            max_end = end

    shared_count = 0
    unique_count = 0
    current_offset = max_end

    for t in init_model.graph.initializer:
        _convert_to_raw_data(t)  # ensure data is in raw_data for accurate sizing
        my_len = len(t.raw_data)
        if t.name in name_to_external:
            ref = name_to_external[t.name]
            step_len = int(ref["length"])
            # Length may not match raw_data len due to serialization differences,
            # but if dims × dtype yields the same size, the data is the same weight.
            expect_len = _compute_byte_size(t)
            if step_len == expect_len:
                _set_external_data(t, ref["location"], int(ref["offset"]))
                shared_count += 1
            else:
                _set_external_data(t, "decoder.onnx.data", current_offset)
                current_offset += my_len
                unique_count += 1
        else:
            _set_external_data(t, "decoder.onnx.data", current_offset)
            current_offset += my_len
            unique_count += 1

    total_data_mb = (max_end + (current_offset - max_end)) / 1_000_000
    print(f"      Shared: {shared_count}, Unique: {unique_count}")
    print(f"      Total weight data: ~{total_data_mb:.1f} MB")

    # ---- Step 3: Verify shared initializer values match ----
    print("[3/4] Verifying shared weights are identical ...")
    _verify_shared_weights(init_path, step_path, name_to_external)

    # ---- Step 4: Save init model ----
    print("[4/4] Saving decoder_init.onnx ...")
    init_out = output_dir / "decoder_init.onnx"
    onnx.save(init_model, str(init_out))
    # NOTE: do NOT consolidate — keep external data separate

    init_onnx_mb = init_out.stat().st_size / 1_000_000
    print(f"      decoder_init.onnx: {init_onnx_mb:.2f} MB (index)")

    # ---- Summary ----
    data_file = output_dir / "decoder.onnx.data"
    print(f"\nDone. Output: {output_dir}")
    total_data = data_file.stat().st_size / 1_000_000
    print(f"  decoder.onnx          {step_onnx_mb:.1f} MB")
    print(f"  decoder_init.onnx     {init_onnx_mb:.1f} MB")
    print(f"  decoder.onnx.data     {total_data:.1f} MB  "
          f"(shared: {shared_count} weights, unique: {unique_count} init-only)")
    saved = (init_path.stat().st_size - init_onnx_mb * 1_000_000) / 1_000_000
    print(f"  Saved vs embedded:    ~{saved:.0f} MB (init model weights now external)")

    # Copy supporting files
    for f in input_dir.glob("*"):
        if f.suffix in (".json", ".spm") and not (output_dir / f.name).exists():
            shutil.copy2(f, output_dir / f.name)


def _set_external_data(tensor, location: str, offset: int):
    """Set external_data reference. tensor.raw_data must already be populated."""
    tensor.data_location = onnx.TensorProto.EXTERNAL
    del tensor.external_data[:]
    actual_len = len(tensor.raw_data)
    for key, value in [("location", location), ("offset", str(offset)), ("length", str(actual_len))]:
        entry = tensor.external_data.add()
        entry.key = key
        entry.value = value
    # NOTE: keep tensor.raw_data — onnx.save writes it to the .data file


def _convert_to_raw_data(tensor):
    """Convert float_data/int32_data/etc. to raw_data, respecting declared dtype."""
    if len(tensor.raw_data) > 0:
        return
    target_dtype = _ONNX_TO_NP.get(tensor.data_type, np.float32)
    if len(tensor.float_data) > 0:
        tensor.raw_data = np.array(list(tensor.float_data), dtype=np.float32).astype(target_dtype).tobytes()
        del tensor.float_data[:]
    elif len(tensor.int32_data) > 0:
        tensor.raw_data = np.array(list(tensor.int32_data), dtype=np.int32).astype(target_dtype).tobytes()
        del tensor.int32_data[:]
    elif len(tensor.int64_data) > 0:
        tensor.raw_data = np.array(list(tensor.int64_data), dtype=np.int64).astype(target_dtype).tobytes()
        del tensor.int64_data[:]
    elif len(tensor.double_data) > 0:
        tensor.raw_data = np.array(list(tensor.double_data), dtype=np.float64).astype(target_dtype).tobytes()
        del tensor.double_data[:]


def _verify_shared_weights(init_path, step_path, name_to_external):
    """Sanity check: shared-name initializers must have identical values."""
    init_model = onnx.load(str(init_path))
    step_model = onnx.load(str(step_path))

    step_tensors = {t.name: t for t in step_model.graph.initializer}
    mismatches = 0
    for t in init_model.graph.initializer:
        if t.name in name_to_external:
            if t.name in step_tensors:
                if t.raw_data != step_tensors[t.name].raw_data:
                    mismatches += 1
                    if mismatches <= 3:
                        print(f"      WARNING: {t.name} differs between init and step!")
    if mismatches > 0:
        print(f"      WARNING: {mismatches} initializers with same name have different values")
    else:
        print("      ✓ All shared initializers have identical values")


def _consolidate_onnx(path: Path):
    """Absorb any orphaned .data into the .onnx if needed."""
    data_file = Path(str(path) + ".data")
    if data_file.exists():
        m = onnx.load(str(path))
        onnx.save(m, str(path))
        data_file.unlink()
        print(f"      Consolidated: {path.name}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Share weights between decoder models via ONNX external data"
    )
    parser.add_argument("--input", required=True,
                        help="Directory with decoder_model_init.onnx and decoder_model.onnx")
    parser.add_argument("--output", default=None,
                        help="Output directory (default: <input>/shared/)")
    args = parser.parse_args()

    input_dir = Path(args.input)
    output_dir = Path(args.output) if args.output else input_dir / "shared"
    share_weights(input_dir, output_dir)


if __name__ == "__main__":
    main()
