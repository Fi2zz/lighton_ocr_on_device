# 模型转换与量化

## 环境

```bash
bash tool/model/setup_env.sh
```

使用 `uv` + Python 3.12，安装 torch、transformers>=5.5.4、safetensors、pillow、numpy、sentencepiece、protobuf。

> 不要直接安装 `third_party/llama.cpp/requirements.txt`：它把 transformers 钉在 4.57.6，本模型需要 ≥5.5.4。

## 转换

```bash
bash tool/model/convert.sh
```

- 文本模型：`build-models/lightonocr3-0.8b-bf16.gguf`
- 视觉投影：`build-models/mmproj-lightonocr3-0.8b-f16.gguf`

该 checkpoint 的 `mtp_num_hidden_layers` 为 0，文本转换必须加 `--no-mtp`；mmproj 转换不要加。

## 量化

先构建：

```bash
cmake -S third_party/llama.cpp -B build-llama \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DGGML_METAL=ON -DGGML_NATIVE=ON
cmake --build build-llama --target llama-mtmd-cli llama-quantize -j
```

再运行：

```bash
bash tool/model/quantize.sh
```

产物：`Q8_0`、`Q4_K_M`。

## 冒烟

```bash
bash tool/model/smoke_macos.sh
```

使用 `llama-mtmd-cli` 对 `samples/report-1.jpg` 跑 `grounding`，输出到 `build/eval/report-1-grounding.md`。

shim 版本的冒烟：

```bash
bash tool/model/smoke_shim.sh > build/eval/shim-report-1.md
```

## 排查

- `assert self.opt_num_mtp_layers != 0`：文本转换漏了 `--no-mtp`。
- `clip.projector_type` 不是 `qwen3vl_merger`：mmproj 文件选错。
- 加载报 `qwen35` 未知：llama.cpp 版本过旧，确认 submodule 在 `3bb63cb` 或更新。
