#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$ROOT/build/eval"
"$ROOT/.venv-model/bin/python" - <<'PY'
from PIL import Image
im = Image.open("samples/report-1.jpg").convert("RGB")
im.thumbnail((2048, 2048))
im.save("build/eval/report-1-2048.ppm")
print(im.width, im.height)
PY
"$ROOT/build/ocr_cli/ocr_cli" \
  --model "$ROOT/build-models/lightonocr3-0.8b-Q8_0.gguf" \
  --mmproj "$ROOT/build-models/mmproj-lightonocr3-0.8b-f16.gguf" \
  --image "$ROOT/build/eval/report-1-2048.ppm" \
  --mode grounding --max-tokens 2048 --temp 0.2 --seed 42 --threads 4 --ctx 12288 --batch 2048
