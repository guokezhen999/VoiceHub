#!/usr/bin/env python3
"""
Shared utilities for INT8 quantization of ONNX MarianMT models.

Provides:
  - Graph analysis (find MatMul/Gather weights behind Transpose nodes)
  - Per-channel symmetric INT8 quantization
  - Graph rewriting (DequantizeLinear insertion)
  - External data sharing (init/step decoder share one .data file)
  - Static activation calibration helpers
  - Verification
"""

import sys
import tempfile
import time
from collections import OrderedDict
from pathlib import Path
from typing import Optional

import numpy as np
import onnx
from onnx import TensorProto, helper
from onnx.external_data_helper import convert_model_to_external_data
from onnxruntime.quantization import QuantType, CalibrationDataReader


# ===========================================================================
# ONNX dtype helpers
# ===========================================================================

_ONNX_TO_NP = {
    TensorProto.FLOAT: np.float32,
    TensorProto.INT8: np.int8,
    TensorProto.INT32: np.int32,
    TensorProto.INT64: np.int64,
    TensorProto.BOOL: np.bool_,
}


# ===========================================================================
# Graph analysis
# ===========================================================================

def find_quantizable_weights(model: onnx.ModelProto) -> dict:
    """Return {initializer_name: 'matmul'|'gather'} for quantizable weights."""
    graph = model.graph
    init_names = {t.name for t in graph.initializer}

    node_output_to_consumers = {}
    for node in graph.node:
        for out_name in node.output:
            node_output_to_consumers[out_name] = node_output_to_consumers.get(out_name, [])
        for node2 in graph.node:
            if node is node2:
                continue
            for inp in node2.input:
                if inp in node.output:
                    node_output_to_consumers[inp] = node_output_to_consumers.get(inp, [])
                    node_output_to_consumers[inp].append(node2)

    quantizable = OrderedDict()
    matmul_weights = set()

    for node in graph.node:
        if node.op_type == "Transpose":
            for inp in node.input:
                if inp in init_names:
                    for out_name in node.output:
                        for cons in node_output_to_consumers.get(out_name, []):
                            if cons.op_type == "MatMul":
                                matmul_weights.add(inp)
                                break

    for node in graph.node:
        if node.op_type == "Gather":
            for inp in node.input:
                if inp in init_names and inp not in quantizable:
                    quantizable[inp] = "gather"

    for wname in sorted(matmul_weights):
        if wname not in quantizable:
            quantizable[wname] = "matmul"

    return quantizable


# ===========================================================================
# Quantization
# ===========================================================================

class QuantInfo:
    __slots__ = ("int8_data", "scale", "zero_point")

    def __init__(self, int8_data: np.ndarray, scale: np.ndarray,
                 zero_point: np.ndarray):
        self.int8_data = int8_data
        self.scale = scale
        self.zero_point = zero_point


def quantize_weight_symmetric_per_channel(weight: np.ndarray) -> QuantInfo:
    """Per-channel symmetric INT8 quantization.

    For weight [M, K]: scale[i] = max(|W[i,:]|) / 127
    """
    if weight.ndim != 2:
        absmax = max(np.max(np.abs(weight)), 1e-12)
        scale = np.array([absmax / 127.0], dtype=np.float32)
        zp = np.array([0], dtype=np.int8)
        int8_data = np.clip(np.round(weight / scale[0]), -128, 127).astype(np.int8)
        return QuantInfo(int8_data, scale, zp)

    absmax = np.maximum(np.max(np.abs(weight), axis=1), 1e-12)
    scale = (absmax / 127.0).astype(np.float32)
    zp = np.zeros(weight.shape[0], dtype=np.int8)
    int8_data = np.clip(np.round(weight / scale[:, np.newaxis]), -128, 127).astype(np.int8)
    return QuantInfo(int8_data, scale, zp)


# ===========================================================================
# Graph transformation
# ===========================================================================

def _make_initializer(name: str, data: np.ndarray) -> TensorProto:
    if data.dtype == np.float32:
        dtype = TensorProto.FLOAT
    elif data.dtype == np.int8:
        dtype = TensorProto.INT8
    elif data.dtype == np.int32:
        dtype = TensorProto.INT32
    elif data.dtype == np.int64:
        dtype = TensorProto.INT64
    else:
        raise ValueError(f"Unsupported dtype: {data.dtype}")
    return helper.make_tensor(name=name, data_type=dtype, dims=list(data.shape),
                              vals=data.tobytes(), raw=True)


def _remove_initializer(graph: onnx.GraphProto, name: str):
    for i, init in enumerate(graph.initializer):
        if init.name == name:
            del graph.initializer[i]
            return


def insert_dequantize_linear(graph: onnx.GraphProto, weight_name: str, qi: QuantInfo):
    qname = weight_name + "_quantized"
    sname = weight_name + "_scale"
    zname = weight_name + "_zero_point"
    dq_output = weight_name + "_dequantized"

    _remove_initializer(graph, weight_name)
    graph.initializer.append(_make_initializer(qname, qi.int8_data))
    graph.initializer.append(_make_initializer(sname, qi.scale))
    graph.initializer.append(_make_initializer(zname, qi.zero_point))

    dq_node = helper.make_node(
        "DequantizeLinear",
        inputs=[qname, sname, zname],
        outputs=[dq_output],
        name=weight_name + "_DequantizeLinear",
        axis=0,
    )
    graph.node.insert(0, dq_node)

    for node in graph.node:
        for i, inp in enumerate(node.input):
            if inp == weight_name:
                node.input[i] = dq_output


def _init_to_numpy(init: TensorProto) -> np.ndarray:
    return onnx.numpy_helper.to_array(init)


def quantize_model(model: onnx.ModelProto,
                   quant_info_map: Optional[dict] = None) -> dict:
    graph = model.graph
    quantizable = find_quantizable_weights(model)
    print(f"      Found {len(quantizable)} quantizable weights "
          f"({sum(1 for v in quantizable.values() if v == 'matmul')} matmul, "
          f"{sum(1 for v in quantizable.values() if v == 'gather')} gather)")

    init_map = {t.name: t for t in graph.initializer}
    output_map = {}

    for wname, wtype in quantizable.items():
        if wname not in init_map:
            continue
        if quant_info_map is not None and wname in quant_info_map:
            qi = quant_info_map[wname]
        else:
            qi = quantize_weight_symmetric_per_channel(_init_to_numpy(init_map[wname]))
        insert_dequantize_linear(graph, wname, qi)
        output_map[wname] = qi

    return output_map


# ===========================================================================
# External data sharing
# ===========================================================================

def _set_external_data_ref(tensor: TensorProto, location: str, offset: int):
    tensor.data_location = TensorProto.EXTERNAL
    del tensor.external_data[:]
    for key, value in [("location", location), ("offset", str(offset)),
                       ("length", str(len(tensor.raw_data)))]:
        entry = tensor.external_data.add()
        entry.key = key
        entry.value = value


def _convert_to_raw_data(tensor: TensorProto):
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


def save_shared_models(init_model: onnx.ModelProto, step_model: onnx.ModelProto,
                       output_dir: Path):
    output_dir.mkdir(parents=True, exist_ok=True)
    data_location = "decoder.onnx.data"

    for model in [init_model, step_model]:
        for t in model.graph.initializer:
            if len(t.external_data) > 0:
                t.data_location = TensorProto.DEFAULT
                del t.external_data[:]

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp_step = Path(tmpdir) / "decoder_embedded.onnx"
        onnx.save(step_model, str(tmp_step))
        step_reloaded = onnx.load(str(tmp_step))
        convert_model_to_external_data(step_reloaded, all_tensors_to_one_file=True,
                                       location=data_location, size_threshold=0,
                                       convert_attribute=False)
        step_out = output_dir / "decoder.onnx"
        onnx.save(step_reloaded, str(step_out))

    step_index = onnx.load(str(step_out), load_external_data=False)
    name_to_external = {}
    for t in step_index.graph.initializer:
        if len(t.external_data) > 0:
            name_to_external[t.name] = {e.key: e.value for e in t.external_data}

    max_end = max((int(ref["offset"]) + int(ref["length"]) for ref in name_to_external.values()), default=0)
    init_shared, init_unique = 0, 0
    current_offset = max_end

    for t in init_model.graph.initializer:
        if len(t.raw_data) == 0:
            _convert_to_raw_data(t)
        my_len = len(t.raw_data)
        if t.name in name_to_external and int(name_to_external[t.name]["length"]) == my_len:
            _set_external_data_ref(t, name_to_external[t.name]["location"],
                                   int(name_to_external[t.name]["offset"]))
            init_shared += 1
        else:
            _set_external_data_ref(t, data_location, current_offset)
            current_offset += my_len
            init_unique += 1

    print(f"      decoder.onnx: {step_out.stat().st_size / 1e6:.2f} MB (index)")
    print(f"      decoder.onnx.data: {(output_dir / data_location).stat().st_size / 1e6:.2f} MB")
    print(f"      init: shared={init_shared}, unique={init_unique}")

    if init_unique > 0:
        with open(output_dir / data_location, "ab") as f:
            f.seek(max_end)
            for t in init_model.graph.initializer:
                if len(t.external_data) > 0:
                    ref = {e.key: e.value for e in t.external_data}
                    if int(ref.get("offset", 0)) >= max_end:
                        f.write(t.raw_data)

    for t in init_model.graph.initializer:
        if len(t.external_data) > 0:
            t.raw_data = b""

    init_out = output_dir / "decoder_init.onnx"
    onnx.save(init_model, str(init_out))
    print(f"      decoder_init.onnx: {init_out.stat().st_size / 1e6:.2f} MB (index)")


# ===========================================================================
# Calibration helpers
# ===========================================================================

def load_calibration_texts(path: str, max_lines: int = 500) -> list[str]:
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


def apply_static_activations(model_path: Path, output_path: Path,
                              reader: CalibrationDataReader):
    from onnxruntime.quantization import quantize_static
    quantize_static(
        model_input=str(model_path), model_output=str(output_path),
        calibration_data_reader=reader, weight_type=QuantType.QInt8,
        op_types_to_quantize=["MatMul", "Gather"],
    )
    data_file = Path(str(output_path) + ".data")
    if data_file.exists():
        data_file.unlink()


# ===========================================================================
# Verification
# ===========================================================================

def verify_shared_quantization(init_path: Path, step_path: Path) -> bool:
    init_m = onnx.load(str(init_path), load_external_data=False)
    step_m = onnx.load(str(step_path), load_external_data=False)
    init_inits = {t.name: t for t in init_m.graph.initializer}
    step_inits = {t.name: t for t in step_m.graph.initializer}

    mismatches = []
    for suffix in ["_quantized", "_scale", "_zero_point"]:
        init_q = {n.replace(suffix, ""): n for n in init_inits if n.endswith(suffix)}
        step_q = {n.replace(suffix, ""): n for n in step_inits if n.endswith(suffix)}
        for base in set(init_q) & set(step_q):
            i_t, s_t = init_inits[init_q[base]], step_inits[step_q[base]]
            if hasattr(i_t, "external_data") and len(i_t.external_data) > 0:
                i_ref = {e.key: e.value for e in i_t.external_data}
                s_ref = {e.key: e.value for e in s_t.external_data}
                if i_ref.get("offset") != s_ref.get("offset"):
                    mismatches.append(f"{suffix}: {base}")

    if mismatches:
        print(f"  {len(mismatches)} mismatches")
        for m in mismatches[:3]:
            print(f"    {m}")
    else:
        print("  All shared quantization parameters have identical offsets")

    init_dq = sum(1 for n in init_m.graph.node if n.op_type == "DequantizeLinear")
    step_dq = sum(1 for n in step_m.graph.node if n.op_type == "DequantizeLinear")
    init_int8 = sum(1 for t in init_m.graph.initializer if t.data_type == TensorProto.INT8)
    step_int8 = sum(1 for t in step_m.graph.initializer if t.data_type == TensorProto.INT8)
    print(f"  DequantizeLinear nodes: init={init_dq}, step={step_dq}")
    print(f"  INT8 initializers: init={init_int8}, step={step_int8}")
    return len(mismatches) == 0
