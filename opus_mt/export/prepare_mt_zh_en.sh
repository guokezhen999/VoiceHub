#!/bin/bash

conda activate opus-onnx

hf_repo=Helsinki-NLP/opus-mt-zh-en
local_dir=opus_mt/model/opus-mt-zh-en
calib_data=opus_mt/calib_data/zh.txt

. opus_mt/export/export_opus_mt.sh "${hf_repo}" "${local_dir}" --calib-data "${calib_data}"
