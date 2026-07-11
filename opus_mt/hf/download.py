#!/usr/bin/env python3
"""
Download an opus-mt model from HuggingFace Hub.

Usage:
    python download.py --model Helsinki-NLP/opus-mt-zh-en --output ./model_cache/

Requires: transformers, sentencepiece, huggingface_hub
"""

import argparse
import sys
from pathlib import Path

from huggingface_hub import snapshot_download
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer


def download_model(model_id: str, output_dir: Path) -> None:
    """Download a MarianMT model and tokenizer from HuggingFace."""

    # Step 1: Download all files first via snapshot_download.
    print(f"[1/2] Downloading files from '{model_id}' ...")
    snapshot_download(
        repo_id=model_id,
        local_dir=str(output_dir),
        local_dir_use_symlinks=False,
        ignore_patterns=["*.h5", "*.msgpack", "*.ot"],  # skip TF / rust files
    )

    # Step 2: Load from local path to verify.
    print(f"[2/2] Verifying model ...")
    tokenizer = AutoTokenizer.from_pretrained(str(output_dir))
    model = AutoModelForSeq2SeqLM.from_pretrained(str(output_dir))

    config = model.config
    names = [p.name for p in sorted(output_dir.iterdir())]
    print(f"      Files ({len(names)}):")
    for f in names:
        size = (output_dir / f).stat().st_size
        if size > 1_000_000:
            print(f"        {f}  ({size / 1_000_000:.1f} MB)")
        else:
            print(f"        {f}  ({size:,} B)")

    print(f"      Architecture:      {config.architectures[0]}")
    print(f"      d_model:            {config.d_model}")
    print(f"      Encoder layers:     {config.encoder_layers}")
    print(f"      Decoder layers:     {config.decoder_layers}")
    print(f"      Vocab size:         {config.vocab_size}")
    print(f"      pad_token_id:       {config.pad_token_id}")
    print(f"      eos_token_id:       {config.eos_token_id}")

    print("")
    print("=" * 60)
    print("Download complete!")
    print(f"Model:  {model_id}")
    print(f"Output: {output_dir}")
    print("=" * 60)


def main():
    parser = argparse.ArgumentParser(
        description="Download an opus-mt model from HuggingFace Hub"
    )
    parser.add_argument(
        "--model",
        required=True,
        help="HuggingFace model ID (e.g. Helsinki-NLP/opus-mt-zh-en)",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Output directory for the downloaded model files",
    )
    args = parser.parse_args()

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    download_model(args.model, output_dir)


if __name__ == "__main__":
    main()
