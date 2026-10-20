#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
uv venv --python 3.12 .venv-model
source .venv-model/bin/activate
uv pip install --upgrade pip
uv pip install torch "transformers>=5.5.4" safetensors pillow numpy sentencepiece protobuf
