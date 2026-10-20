#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODEL_DIR="${1:-$ROOT/light_on_ocr_0.8b/models}"
OUT_DIR="${2:-$ROOT/build-models}"
mkdir -p "$OUT_DIR"
source "$ROOT/.venv-model/bin/activate"
python "$ROOT/third_party/llama.cpp/convert_hf_to_gguf.py" "$MODEL_DIR" \
  --outtype bf16 --no-mtp \
  --outfile "$OUT_DIR/lightonocr3-0.8b-bf16.gguf"
python "$ROOT/third_party/llama.cpp/convert_hf_to_gguf.py" "$MODEL_DIR" \
  --mmproj --outtype f16 \
  --outfile "$OUT_DIR/mmproj-lightonocr3-0.8b-f16.gguf"
