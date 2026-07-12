#!/bin/bash
# export_opus_mt.sh
#
# Stages:
#   1  Download model from HuggingFace       → <output>/hf/
#   2  Convert FP32 + share weights          → <output>/onnx/  +  <output>/onnx_fp32/
#   3  INT8 encoder + FP32 decoders          → <output>/onnx_int8/
#
# Final file layout:
#   onnx_fp32/   encoder.onnx  decoder.onnx  decoder_init.onnx  decoder.onnx.data  (+ vocab/spm/config)
#   onnx_int8/   encoder.onnx  decoder.onnx  decoder_init.onnx  decoder.onnx.data  (+ vocab/spm/config)
#
# Usage (run from VoiceHub project root):
#   ./opus_mt/export/export_opus_mt.sh Helsinki-NLP/opus-mt-zh-en opus_mt/model/zh-en
#   ./opus_mt/export/export_opus_mt.sh Helsinki-NLP/opus-mt-zh-en opus_mt/model/zh-en 2 3
#   ./opus_mt/export/export_opus_mt.sh Helsinki-NLP/opus-mt-zh-en opus_mt/model/zh-en 3 --calib-data calib_zh.txt
#
# Thin wrappers (just source this script):
#   . opus_mt/export/export_opus_mt.sh "${hf_repo}" "${local_dir}" --calib-data "${calib_data}"
#
# Prerequisites:
#   conda activate opus-onnx

# ---- paths ------------------------------------------------------------------

HF_SCRIPTS="opus_mt/hf"

# ---- python -----------------------------------------------------------------

PYTHON="${PYTHON:-python3}"
if [[ -x /Users/guokezhen/anaconda3/envs/opus-onnx/bin/python ]]; then
    PYTHON="/Users/guokezhen/anaconda3/envs/opus-onnx/bin/python"
elif command -v conda &>/dev/null; then
    _p="$(conda run -n opus-onnx which python 2>/dev/null)" && PYTHON="$_p"
fi

# ---- parse args -------------------------------------------------------------

MODEL_ID=""
OUT_DIR=""
START_STAGE=1
END_STAGE=3
CALIB_DATA=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --calib-data)  CALIB_DATA="$2"; shift 2 ;;
        [1-4])
            if [[ -z "${_s:-}" ]]; then START_STAGE="$1"; _s=1
            else END_STAGE="$1"; fi
            shift ;;
        *)
            if [[ -z "$MODEL_ID" ]]; then MODEL_ID="$1"
            elif [[ -z "$OUT_DIR" ]]; then OUT_DIR="$1"
            else echo "ERROR: Unexpected argument: $1" >&2; exit 1
            fi
            shift ;;
    esac
done

if [[ -z "$MODEL_ID" ]] || [[ -z "$OUT_DIR" ]]; then
    echo "Usage: $0 <hf_repo> <output_dir> [start_stage] [end_stage] [--calib-data FILE]"
    echo ""
    echo "Stages:"
    echo "  1  Download            → <output>/hf/"
    echo "  2  FP32 export + share → <output>/onnx/ + <output>/onnx_fp32/"
    echo "  3  INT8 enc + FP32 decoders → <output>/onnx_int8/"
    echo ""
    echo "Final layout:"
    echo "  onnx_fp32/   encoder.onnx  decoder.onnx  decoder_init.onnx  decoder.onnx.data"
    echo "  onnx_int8/   encoder.onnx [INT8] + decoder files [FP32]"
    echo ""
    echo "Examples:"
    echo "  $0 Helsinki-NLP/opus-mt-zh-en opus_mt/model/zh-en"
    echo "  $0 Helsinki-NLP/opus-mt-zh-en opus_mt/model/zh-en 2 3"
    echo "  $0 Helsinki-NLP/opus-mt-zh-en opus_mt/model/zh-en 3 --calib-data calib_zh.txt"
    echo ""
    exit 1
fi

DIR_HF="${OUT_DIR}/hf"
DIR_ONNX="${OUT_DIR}/onnx"
DIR_FP32="${OUT_DIR}/onnx_fp32"
DIR_INT8="${OUT_DIR}/onnx_int8"

# ---- helpers ----------------------------------------------------------------

should_run() { [[ "$1" -ge "$START_STAGE" ]] && [[ "$1" -le "$END_STAGE" ]]; }

should_skip_dir() {
    local dir="$1"; shift
    local all_ok=true
    for f in "$@"; do
        [[ -f "${dir}/${f}" ]] || { all_ok=false; break; }
    done
    $all_ok
}

# ---- banner -----------------------------------------------------------------

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  opus-mt ONNX Export                                       ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Model:      ${MODEL_ID}"
echo "║  Output:     ${OUT_DIR}/"
echo "║  Stages:     ${START_STAGE} → ${END_STAGE}"
[[ -n "$CALIB_DATA" ]] && echo "║  Calib:      ${CALIB_DATA}"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ---- stage 1: download ------------------------------------------------------

if should_run 1; then
    echo "[1/3] Downloading → ${DIR_HF}/"
    if [[ -f "${DIR_HF}/config.json" ]]; then
        echo "      SKIPPED — already downloaded"
    else
        mkdir -p "${DIR_HF}"
        ${PYTHON} "${HF_SCRIPTS}/download.py" --model "${MODEL_ID}" --output "${DIR_HF}"
    fi
    echo ""
fi

# ---- stage 2: fp32 export + share -------------------------------------------

if should_run 2; then
    echo "[2/3] FP32 export + share → ${DIR_FP32}/"
    if should_skip_dir "${DIR_FP32}" "encoder.onnx" "decoder.onnx" "decoder_init.onnx" "decoder.onnx.data" "source.spm" "target.spm" "vocab.json" "config.json"; then
        echo "      SKIPPED — fp32 output already exists"
    else
        mkdir -p "${DIR_ONNX}" "${DIR_FP32}"

        echo "      [2a] Exporting FP32 ONNX ..."
        ${PYTHON} "${HF_SCRIPTS}/convert_to_onnx.py" --input "${DIR_HF}" --output "${DIR_ONNX}"

        echo "      [2b] Sharing decoder weights ..."
        ${PYTHON} "${HF_SCRIPTS}/share_weights.py" --input "${DIR_ONNX}" --output "${DIR_ONNX}"

        echo "      [2c] Assembling ${DIR_FP32}/ ..."
        for f in encoder.onnx decoder.onnx decoder_init.onnx decoder.onnx.data source.spm target.spm vocab.json config.json; do
            cp "${DIR_ONNX}/${f}" "${DIR_FP32}/${f}"
        done

        echo "      [2d] Cleaning intermediate files ..."
        rm -f "${DIR_ONNX}/decoder_model_init.onnx" "${DIR_ONNX}/decoder_model.onnx"
    fi
    echo ""
fi

# ---- stage 3: int8 encoder + assemble ---------------------------------------

if should_run 3; then
    echo "[3/3] INT8 encoder + FP32 decoders → ${DIR_INT8}/"
    if should_skip_dir "${DIR_INT8}" "encoder.onnx" "decoder.onnx" "decoder_init.onnx" "decoder.onnx.data" "source.spm" "target.spm" "vocab.json" "config.json"; then
        echo "      SKIPPED — int8 output already exists"
    else
        mkdir -p "${DIR_INT8}"

        echo "      [3a] Quantizing encoder (INT8) ..."
        if [[ -n "$CALIB_DATA" ]]; then
            ${PYTHON} "${HF_SCRIPTS}/quantize_encoder.py" \
                --input "${DIR_FP32}/encoder.onnx" \
                --output "${DIR_INT8}" \
                --hf-dir "${DIR_HF}" \
                --calibration-data "${CALIB_DATA}"
        else
            ${PYTHON} "${HF_SCRIPTS}/quantize_encoder.py" \
                --input "${DIR_FP32}/encoder.onnx" \
                --output "${DIR_INT8}" \
                --hf-dir "${DIR_HF}" \
                --calibration-data /dev/null
        fi

        echo "      [3b] Copying FP32 decoder files ..."
        for f in decoder.onnx decoder_init.onnx decoder.onnx.data; do
            cp "${DIR_FP32}/${f}" "${DIR_INT8}/${f}"
        done

        echo "      [3c] Copying supporting files ..."
        for f in source.spm target.spm vocab.json config.json; do
            cp "${DIR_FP32}/${f}" "${DIR_INT8}/${f}"
        done
    fi
    echo ""
fi

# ---- summary ----------------------------------------------------------------

echo "Done → ${OUT_DIR}/"
echo ""
for pair in "fp32  ${DIR_FP32}" "int8  ${DIR_INT8}" "中间  ${DIR_ONNX}" "hf    ${DIR_HF}"; do
    label="${pair%% *}"
    dir="${pair#* }"
    if [[ -d "$dir" ]] && [[ -n "$(ls "$dir" 2>/dev/null)" ]]; then
        total=$(du -sh "$dir" | cut -f1)
        echo "  ${label}  ${total}  ${dir}"
        for f in "$dir"/*; do
            [[ -f "$f" ]] && printf "    %-6s  %s\n" "$(du -sh "$f" | cut -f1)" "$(basename "$f")"
        done
    fi
done
