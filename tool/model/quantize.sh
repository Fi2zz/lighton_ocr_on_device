#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/build-models/lightonocr3-0.8b-bf16.gguf"
OUT="$ROOT/build-models"
"$ROOT/build-llama/bin/llama-quantize" "$SRC" "$OUT/lightonocr3-0.8b-Q8_0.gguf" Q8_0
"$ROOT/build-llama/bin/llama-quantize" "$SRC" "$OUT/lightonocr3-0.8b-Q4_K_M.gguf" Q4_K_M
# Keep the body at Q4_K_M but make the large output/embedding tensors Q4_0.
# On the 8GB test device this cuts decode time ~20% with minimal quality loss.
"$ROOT/build-llama/bin/llama-quantize" \
  --output-tensor-type Q4_0 --token-embedding-type Q4_0 \
  "$SRC" "$OUT/lightonocr3-0.8b-Q4KM-headQ4.gguf" Q4_K_M
