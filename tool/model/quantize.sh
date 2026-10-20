#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/build-models/lightonocr3-0.8b-bf16.gguf"
OUT="$ROOT/build-models"
"$ROOT/build-llama/bin/llama-quantize" "$SRC" "$OUT/lightonocr3-0.8b-Q8_0.gguf" Q8_0
"$ROOT/build-llama/bin/llama-quantize" "$SRC" "$OUT/lightonocr3-0.8b-Q4_K_M.gguf" Q4_K_M
