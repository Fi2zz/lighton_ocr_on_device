#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$ROOT/build/eval"
sips -Z 2048 -s format jpeg \
  "$ROOT/samples/report-1.jpg" \
  --out "$ROOT/build/eval/report-1-2048.jpg" >/dev/null
"$ROOT/build-llama/bin/llama-mtmd-cli" \
  -m "$ROOT/build-models/lightonocr3-0.8b-Q8_0.gguf" \
  --mmproj "$ROOT/build-models/mmproj-lightonocr3-0.8b-f16.gguf" \
  --image "$ROOT/build/eval/report-1-2048.jpg" \
  -p "<__media__>grounding" \
  -n 2048 --temp 0.2 -ngl 0 \
  > "$ROOT/build/eval/report-1-grounding.md"
