#!/bin/bash

conda activate opus-onnx

hf_repo=Helsinki-NLP/opus-mt_tiny_zho-eng
local_dir=opus_mt/model/opus-mt-tiny-zh-en
calib_data=opus_mt/calib_data/zh.txt
. opus_mt/export/export_opus_mt.sh "${hf_repo}" "${local_dir}" --static --calib-data "${calib_data}"