#!/bin/bash

conda activate opus-onnx

hf_repo=Helsinki-NLP/opus-mt-zh-en
local_dir=marian/model/opus-mt-zh-en
calib_data=marian/calib_data/zh.txt
. marian/export/export_opus_mt.sh "${hf_repo}" "${local_dir}" --static --calib-data "${calib_data}"