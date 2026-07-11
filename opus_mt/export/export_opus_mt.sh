#!/bin/bash
# export_opus_mt.sh
#
# Stages:
#   1  Download model from HuggingFace       → <output>/hf/
#   2  Convert to ONNX                       → <output>/onnx/
#   3  Quantize to INT8                      → <output>/onnx_int8/
#
# Usage (run from VoiceHub project root):
#   ./opus_mt/export/export_opus_mt.sh Helsinki-NLP/opus-mt-zh-en opus_mt/model/zh-en
#   ./opus_mt/export/export_opus_mt.sh Helsinki-NLP/opus-mt-zh-en opus_mt/model/zh-en 1 2
#   ./opus_mt/export/export_opus_mt.sh Helsinki-NLP/opus-mt-zh-en opus_mt/model/zh-en 3
#
# Prerequisites:
#   conda activate opus-onnx

# ---- paths (relative to VoiceHub project root) ------------------------------

HF_SCRIPTS="opus_mt/hf"

# ---- python -----------------------------------------------------------------

PYTHON="${PYTHON:-python3}"
if command -v conda &>/dev/null && conda env list 2>/dev/null | grep -q "opus-onnx"; then
    PYTHON="$(conda run -n opus-onnx which python 2>/dev/null || echo "$PYTHON")"
fi

# ---- parse args -------------------------------------------------------------

MODEL_ID=""
OUT_DIR=""
START_STAGE=1
END_STAGE=3
QUANT_METHOD="dynamic"
CALIB_DATA=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --static)      QUANT_METHOD="static"; shift ;;
        --calib-data)  CALIB_DATA="$2"; shift 2 ;;
        [1-3])
            if [[ -z "${_s:-}" ]]; then
                START_STAGE="$1"; _s=1
            else
                END_STAGE="$1"
            fi
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
    echo "Usage: $0 <hf_repo> <output_dir> [start_stage] [end_stage] [--static --calib-data FILE]"
    echo ""
    echo "Stages:"
    echo "  1  Download  → <output>/hf/"
    echo "  2  Convert   → <output>/onnx/"
    echo "  3  Quantize  → <output>/onnx_int8/"
    echo ""
    echo "Examples:"
    echo "  $0 Helsinki-NLP/opus-mt-zh-en opus_mt/model/zh-en"
    echo "  $0 Helsinki-NLP/opus-mt-zh-en opus_mt/model/zh-en 1 2"
    echo "  $0 Helsinki-NLP/opus-mt-zh-en opus_mt/model/zh-en 3 --static --calib-data calib_zh.txt"
    echo ""
    exit 1
fi

DIR_HF="${OUT_DIR}/hf"
DIR_ONNX="${OUT_DIR}/onnx"
DIR_INT8="${OUT_DIR}/onnx_int8"

# ---- helpers ----------------------------------------------------------------

should_run() { [[ "$1" -ge "$START_STAGE" ]] && [[ "$1" -le "$END_STAGE" ]]; }

# ---- banner -----------------------------------------------------------------

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  opus-mt ONNX Export                                       ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Model:      ${MODEL_ID}"
echo "║  Output:     ${OUT_DIR}/"
echo "║  Stages:     ${START_STAGE} → ${END_STAGE}"
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

# ---- stage 2: convert to ONNX -----------------------------------------------

if should_run 2; then
    echo "[2/3] Converting → ${DIR_ONNX}/"
    if [[ -f "${DIR_ONNX}/encoder_model.onnx" ]] && [[ -f "${DIR_ONNX}/decoder_model.onnx" ]]; then
        echo "      SKIPPED — already converted"
    else
        mkdir -p "${DIR_ONNX}"
        ${PYTHON} "${HF_SCRIPTS}/convert_to_onnx.py" --input "${DIR_HF}" --output "${DIR_ONNX}"
    fi
    echo ""
fi

# ---- stage 3: quantize ------------------------------------------------------

if should_run 3; then
    echo "[3/3] Quantizing [${QUANT_METHOD}] → ${DIR_INT8}/"
    if [[ -f "${DIR_INT8}/encoder_model.onnx" ]] && [[ -f "${DIR_INT8}/decoder_model.onnx" ]]; then
        echo "      SKIPPED — already quantized"
    else
        mkdir -p "${DIR_INT8}"
        if [[ "$QUANT_METHOD" == "static" ]]; then
            ${PYTHON} "${HF_SCRIPTS}/quantize.py" \
                --input "${DIR_ONNX}" --output "${DIR_INT8}" \
                --method static \
                --hf-dir "${DIR_HF}" \
                --calibration-data "${CALIB_DATA}"
        else
            ${PYTHON} "${HF_SCRIPTS}/quantize.py" \
                --input "${DIR_ONNX}" --output "${DIR_INT8}" \
                --method dynamic
        fi
    fi

    # Copy supporting files needed by the dylib.
    for f in vocab.json config.json source.spm target.spm tokenizer.json; do
        if [[ -f "${DIR_ONNX}/${f}" ]]; then
            cp "${DIR_ONNX}/${f}" "${DIR_INT8}/${f}"
        elif [[ -f "${DIR_HF}/${f}" ]]; then
            cp "${DIR_HF}/${f}" "${DIR_INT8}/${f}"
        fi
    done
    echo ""
fi

# ---- summary ----------------------------------------------------------------

echo "Done → ${OUT_DIR}/"
echo ""
for d in hf onnx onnx_int8; do
    dir="${OUT_DIR}/${d}"
    if [[ -d "$dir" ]] && [[ -n "$(ls "$dir" 2>/dev/null)" ]]; then
        echo "  ${d}/"
        for f in "$dir"/*; do
            [[ -f "$f" ]] && printf "    %-8s %s\n" "$(du -sh "$f" | cut -f1)" "$(basename "$f")"
        done
    fi
done
