# LightOnOCR-3-0.8B 端侧 Flutter 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Android 真机上完全离线运行 LightOnOCR-3-0.8B，输入单张图片，输出可复制/分享的 Markdown。

**Architecture:** llama.cpp + libmtmd 静态链接进一个 `libocrshim.so`，通过 Dart FFI 在常驻 worker isolate 中调用；Flutter UI 只负责选图、模型导入、状态展示和结果渲染。模型以 GGUF 形式由用户导入应用私有目录，M0 先用 `llama-mtmd-cli` 证明 checkpoint 可跑通。

**Tech Stack:** Flutter 3.44.8 / Dart 3.12.2、llama.cpp HEAD、libmtmd、Dart FFI、`image`、`file_picker`、`image_picker`、`path_provider`、`share_plus`、`flutter_markdown`、`wakelock_plus`。

**Spec:** `docs/superpowers/specs/2026-10-20-lightonocr-flutter-design.md`

## Global Constraints

- 只做 Android，`arm64-v8a`，`minSdk = 26`；iOS/macOS App 不在范围内。
- 运行时完全离线；不得在 App 内发起模型下载或任何 OCR 网络请求。
- 模型/量化产物不进入 git：`*.gguf`、`build-models/`、`build/eval/`、`.venv-model/` 必须被忽略。
- 默认配置：`mode=grounding`、`longestEdge=1280`、`maxTokens=2048`、`nCtx=8192`、`nBatch=2048`、`nUbatch=256`、`imageMaxTokens=4096`、`seed=42`、`nThreads=min(8, Platform.numberOfProcessors)`、`temperature=0.2`。空 prompt 的 `plain` 模式保留，但不是默认。
- 默认量化 `Q4KM-headQ4`（body Q4_K_M，output/token embedding Q4_0；8GB 中端机实测）；Q8_0 作为质量选项。
- Prompt 必须逐字节匹配（`thinking` 与 `response` 各有一个前导空格）：

  ```
  <|im_start|>user\n<__media__>{prompt}<|im_end|>\n<|im_start|>assistant\n thinking\n\n response\n\n
  ```

  `{prompt}` 为空或 `grounding`。
- native 错误一律写入 `E_XXX: message` 缓冲区；不得静默返回。
- UI 文案使用中文；结果页必须同时提供“渲染”和“原文”。
- 不新增 llama.cpp 之外的 native 依赖；不引入 ffigen。
- 每个任务结束前必须跑该任务指定的测试/构建命令，并提交。
- Android 16 需要 16KB page 对齐；链接参数必须包含 `-Wl,-z,max-page-size=16384`。

## Review Focus

- **选错/损坏的 GGUF**：用户把 mmproj 当主模型、或选了非 GGUF 文件时，界面必须显示 `E_GGUF_INVALID`，不能崩溃，也不能留下半拷贝文件。由 Task 10 的 `gguf_probe_test` 与 `model_store_test` 覆盖。
- **多字节字符跨 token**：中文/emoji 被拆到多个 token 时不能出现乱码或替换字符。由 Task 3 的 `utf8_split_*` 测试覆盖。
- **旋转/竖拍照片**：EXIF 方向必须校正，长边缩放保持比例且不放大，否则识别区域会错位。由 Task 11 的 `prepare_image_*` 测试覆盖。
- **生成中取消/切后台**：取消后引擎仍可复用，下一次识别不能收到上一次的残留 token。由 Task 5 的 native 取消测试和 Task 12 的 `service_cancel_*` 测试覆盖。
- **低内存/加载失败**：模型加载失败或 OOM 时必须释放 native 资源，允许重试，不能把 UI 卡在 loading。由 Task 4 的失败路径和 Task 12 的 `service_load_failure_then_retry` 覆盖。

---

## Task 1: 模型转换环境与 GGUF 产物

**Files:**
- Create: `tool/model/setup_env.sh`
- Create: `tool/model/convert.sh`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `light_on_ocr_0.8b/models/` 原始 HF 权重。
- Produces: `build-models/lightonocr3-0.8b-bf16.gguf`、`build-models/mmproj-lightonocr3-0.8b-f16.gguf`。

- [ ] **Step 1: 写 `tool/model/setup_env.sh`**

脚本内容固定为：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
uv venv --python 3.12 .venv-model
source .venv-model/bin/activate
uv pip install --upgrade pip
uv pip install torch "transformers>=5.5.4" safetensors pillow numpy sentencepiece protobuf
```

> 说明：`third_party/llama.cpp/requirements/requirements-convert_legacy_llama.txt` 把 `transformers` 钉在 4.57.6，但本模型需要 ≥5.5.4；这里显式覆盖，不要直接 `pip install -r requirements.txt`。

- [ ] **Step 2: 运行环境脚本并验证**

Run: `bash tool/model/setup_env.sh`
Expected: 退出码 0；随后运行：

```bash
.venv-model/bin/python -c "import transformers, torch, PIL; print(transformers.__version__, torch.__version__, PIL.__version__)"
```

Expected: 打印三个版本号，`transformers` ≥ 5.5.4。

- [ ] **Step 3: 写 `tool/model/convert.sh`**

```bash
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
```

> 本 checkpoint 的 `mtp_num_hidden_layers` 为 0，llama.cpp 转换器会因此断言失败；文本转换必须加 `--no-mtp`。mmproj 转换不要加。

- [ ] **Step 4: 运行转换**

Run: `bash tool/model/convert.sh`
Expected: 两个文件存在。

- [ ] **Step 5: 验证 GGUF 头**

Run:

```bash
xxd -l 4 build-models/lightonocr3-0.8b-bf16.gguf
xxd -l 4 build-models/mmproj-lightonocr3-0.8b-f16.gguf
```

Expected: 两次都输出 `4747 5546`（ASCII `GGUF`）。

- [ ] **Step 6: 更新 `.gitignore`**

追加：

```gitignore
*.gguf
build-models/
build/eval/
.venv-model/
```

- [ ] **Step 7: 确认大文件未被跟踪**

Run: `git status --short | rg "gguf|build-models|venv-model"`
Expected: 无输出。

- [ ] **Step 8: 提交**

```bash
git add .gitignore tool/model/setup_env.sh tool/model/convert.sh
git commit -m "feat(model): add GGUF conversion pipeline"
```

---

## Task 2: M0 冒烟验证（硬门槛）

**Files:**
- Create: `tool/model/quantize.sh`
- Create: `tool/model/smoke_macos.sh`

**Interfaces:**
- Consumes: Task 1 的 BF16 主模型与 F16 mmproj。
- Produces: `build-models/lightonocr3-0.8b-Q8_0.gguf`、`build-models/lightonocr3-0.8b-Q4_K_M.gguf`、`build-models/lightonocr3-0.8b-Q4KM-headQ4.gguf`、`build/eval/report-1.md`、`build/eval/report-1-2048.jpg`。

- [ ] **Step 1: 写 `tool/model/quantize.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/build-models/lightonocr3-0.8b-bf16.gguf"
OUT="$ROOT/build-models"
"$ROOT/build-llama/bin/llama-quantize" "$SRC" "$OUT/lightonocr3-0.8b-Q8_0.gguf" Q8_0
"$ROOT/build-llama/bin/llama-quantize" "$SRC" "$OUT/lightonocr3-0.8b-Q4_K_M.gguf" Q4_K_M
"$ROOT/build-llama/bin/llama-quantize" --output-tensor-type Q4_0 --token-embedding-type Q4_0 \
  "$SRC" "$OUT/lightonocr3-0.8b-Q4KM-headQ4.gguf" Q4_K_M
```

- [ ] **Step 2: 编译 `llama-mtmd-cli`**

Run:

```bash
cmake -S third_party/llama.cpp -B build-llama \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DGGML_METAL=ON \
  -DGGML_NATIVE=ON
cmake --build build-llama --target llama-mtmd-cli llama-quantize -j
```

Expected: `build-llama/bin/llama-mtmd-cli` 与 `llama-quantize` 存在。

- [ ] **Step 3: 运行量化**

Run: `bash tool/model/quantize.sh`
Expected: Q8_0 约 0.8–1.0GB，Q4_K_M 明显更小；两个文件头均为 `GGUF`。

- [ ] **Step 4: 写 `tool/model/smoke_macos.sh`**

```bash
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
```

> M0 实测：空 prompt（`<__media__>`）会输出图像描述；`grounding` 才能得到完整转录。因此冒烟和 App 默认都用 `grounding`。

- [ ] **Step 5: 运行 M0 冒烟**

Run: `bash tool/model/smoke_macos.sh`
Expected: 退出码 0；`build/eval/report-1-grounding.md` 非空。

- [ ] **Step 6: 检查输出质量**

Run:

```bash
wc -c build/eval/report-1-grounding.md
rg -n "<\|im_end\|>|<\|endoftext\|>" build/eval/report-1-grounding.md || true
```

Expected: 字节数 > 100；不得出现特殊 token。人工查看文件，至少能辨认试卷标题或题干。

- [ ] **Step 7: 硬门槛**

如果 Step 5 或 Step 6 失败：停止后续任务，记录失败命令、llama.cpp 报错、mmproj 元数据中的 `clip.projector_type`，不要继续 M1。

- [ ] **Step 8: 提交**

```bash
git add tool/model/quantize.sh tool/model/smoke_macos.sh
git commit -m "feat(model): add quantization and macOS smoke gate"
```

---

## Task 3: Native 文本工具（Prompt 与 UTF-8 缓冲）

**Files:**
- Create: `native/ocr_shim/src/text_utils.h`
- Create: `native/ocr_shim/src/text_utils.cpp`
- Create: `native/ocr_shim/tests/text_utils_test.cpp`
- Create: `native/ocr_shim/tests/CMakeLists.txt`

**Interfaces:**
- Produces:
  - `std::string ocr_build_prompt(const std::string& media_marker, const char* mode);`
  - `class Utf8StreamBuffer { void append(const char* data, size_t len, const Emit& emit); void flush(const Emit& emit); };`
  - `using Emit = std::function<void(const char*, size_t)>;`

- [ ] **Step 1: 写失败测试**

`text_utils_test.cpp`：

```cpp
#include "text_utils.h"
#include <cassert>
#include <iostream>
#include <string>

static void expect_eq(const std::string& got, const std::string& want) {
    if (got != want) {
        std::cerr << "got:  [" << got << "]\nwant: [" << want << "]\n";
        std::abort();
    }
}

static void test_prompt_plain() {
    const std::string expected =
        "<|im_start|>user\n<__media__><|im_end|>\n"
        "<|im_start|>assistant\n"
        " thinking\n\n"
        " response\n\n";
    expect_eq(ocr_build_prompt("<__media__>", "plain"), expected);
}

static void test_prompt_grounding() {
    const std::string expected =
        "<|im_start|>user\n<__media__>grounding<|im_end|>\n"
        "<|im_start|>assistant\n"
        " thinking\n\n"
        " response\n\n";
    expect_eq(ocr_build_prompt("<__media__>", "grounding"), expected);
}

static void test_utf8_split() {
    Utf8StreamBuffer buf;
    std::string out;
    auto emit = [&](const char* d, size_t n) { out.append(d, n); };
    const char bytes[] = "\xE6\xB5\x8B"; // 测
    buf.append(bytes, 1, emit);
    assert(out.empty());
    buf.append(bytes + 1, 2, emit);
    expect_eq(out, "测");
    buf.flush(emit);
    expect_eq(out, "测");
}

static void test_utf8_mixed_ascii() {
    Utf8StreamBuffer buf;
    std::string out;
    auto emit = [&](const char* d, size_t n) { out.append(d, n); };
    const char bytes[] = {'A', '\xE6', '\xB5', '\x8B', 'B'};
    buf.append(bytes, 2, emit);
    buf.append(bytes + 2, 3, emit);
    expect_eq(out, "A测B");
}

static void test_utf8_invalid() {
    Utf8StreamBuffer buf;
    std::string out;
    auto emit = [&](const char* d, size_t n) { out.append(d, n); };
    const char bytes[] = "\xFF";
    buf.append(bytes, 1, emit);
    buf.flush(emit);
    expect_eq(out, "\xEF\xBF\xBD"); // U+FFFD
}

int main() {
    test_prompt_plain();
    test_prompt_grounding();
    test_utf8_split();
    test_utf8_mixed_ascii();
    test_utf8_invalid();
    std::cout << "text_utils_test: ok\n";
    return 0;
}
```

- [ ] **Step 2: 运行测试，确认失败**

```bash
cmake -S native/ocr_shim/tests -B build/native-text-tests -DCMAKE_BUILD_TYPE=Debug
cmake --build build/native-text-tests -j
```

Expected: 编译失败，提示 `text_utils.h` 不存在。

- [ ] **Step 3: 写 `text_utils.h`**

```cpp
#pragma once
#include <cstddef>
#include <functional>
#include <string>

using Utf8Emit = std::function<void(const char*, size_t)>;

std::string ocr_build_prompt(const std::string& media_marker, const char* mode);

class Utf8StreamBuffer {
public:
    void append(const char* data, size_t len, const Utf8Emit& emit);
    void flush(const Utf8Emit& emit);
private:
    std::string pending_;
};
```

- [ ] **Step 4: 实现 `text_utils.cpp`**

规则：

- `ocr_build_prompt`：`mode=="plain"` 时正文为空；`mode=="grounding"` 时正文为 `grounding`；其他值抛 `std::invalid_argument`。
- UTF-8 解析：只处理合法的 1–4 字节序列；不完整序列留在 `pending_`；非法字节输出 `\xEF\xBF\xBD` 并前进 1 字节。

- [ ] **Step 5: 写测试 CMake**

```cmake
cmake_minimum_required(VERSION 3.22)
project(ocr_text_utils_tests CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_executable(text_utils_test text_utils_test.cpp ../src/text_utils.cpp)
target_include_directories(text_utils_test PRIVATE ../src)
enable_testing()
add_test(NAME text_utils_test COMMAND text_utils_test)
```

- [ ] **Step 6: 运行测试，确认通过**

```bash
cmake -S native/ocr_shim/tests -B build/native-text-tests -DCMAKE_BUILD_TYPE=Debug
cmake --build build/native-text-tests -j
ctest --test-dir build/native-text-tests --output-on-failure
```

Expected: `100% tests passed, 0 tests failed out of 1`。

- [ ] **Step 7: 提交**

```bash
git add native/ocr_shim/src/text_utils.h native/ocr_shim/src/text_utils.cpp \
        native/ocr_shim/tests/text_utils_test.cpp native/ocr_shim/tests/CMakeLists.txt
git commit -m "feat(native): add prompt builder and UTF-8 stream buffer"
```

---

## Task 4: Native C ABI、CMake 与模型加载

**Files:**
- Create: `native/ocr_shim/include/ocr_shim.h`
- Create: `native/ocr_shim/src/ocr_shim.cpp`
- Create: `native/ocr_shim/CMakeLists.txt`
- Create: `tool/ocr_cli/CMakeLists.txt`
- Create: `tool/ocr_cli/main.cpp`

**Interfaces:**
- Produces: `ocr_create` / `ocr_destroy` / `ocr_stats_size` 与 `tool/ocr_cli --info`、`--load-only`。
- Consumes: Task 3 的 `ocr_build_prompt`、`Utf8StreamBuffer`。

- [ ] **Step 1: 写 `ocr_shim.h`**

完整 C ABI（`_pad` 必须保留）：

```c
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OCR_STATS_ABI_VERSION 1

typedef struct ocr_engine ocr_engine;

typedef struct {
    int32_t prompt_tokens;
    int32_t output_tokens;
    int32_t image_tokens;
    int32_t _pad;
    double load_ms;
    double encode_ms;
    double prefill_ms;
    double decode_ms;
    int64_t peak_rss_kb;
} ocr_stats;

typedef void (*ocr_token_cb)(const char* utf8, int32_t len, void* ud);
typedef void (*ocr_progress_cb)(const char* stage, float fraction, void* ud);

ocr_engine* ocr_create(const char* model_path,
                       const char* mmproj_path,
                       int32_t n_threads,
                       int32_t n_ctx,
                       int32_t n_batch,
                       int32_t image_max_tokens,
                       ocr_progress_cb on_progress,
                       void* progress_ud,
                       char* err,
                       size_t err_cap);

int32_t ocr_run(ocr_engine* engine,
                const uint8_t* rgb,
                int32_t width,
                int32_t height,
                const char* mode,
                int32_t max_tokens,
                float temperature,
                uint32_t seed,
                ocr_token_cb on_token,
                ocr_progress_cb on_progress,
                void* ud,
                ocr_stats* stats,
                char* err,
                size_t err_cap);

void ocr_cancel(ocr_engine* engine);
void ocr_destroy(ocr_engine* engine);
size_t ocr_stats_size(void);

#ifdef __cplusplus
}
#endif
```

- [ ] **Step 2: 写 `native/ocr_shim/CMakeLists.txt`**

关键配置：

```cmake
cmake_minimum_required(VERSION 3.22)
project(ocr_shim CXX C)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_MTMD ON CACHE BOOL "" FORCE)
set(LLAMA_CURL OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
if (ANDROID)
  set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+fp16" CACHE STRING "" FORCE)
endif()
if (APPLE)
  set(GGML_METAL ON CACHE BOOL "" FORCE)
  set(GGML_NATIVE ON CACHE BOOL "" FORCE)
else()
  set(GGML_METAL OFF CACHE BOOL "" FORCE)
  set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
  set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
endif()
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/llama.cpp
                 ${CMAKE_BINARY_DIR}/llama.cpp)
add_library(ocr_shim SHARED src/ocr_shim.cpp src/text_utils.cpp)
target_include_directories(ocr_shim PUBLIC include PRIVATE src)
target_link_libraries(ocr_shim PRIVATE mtmd llama ggml)
set_target_properties(ocr_shim PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON)
```

Android 额外链接参数：

```cmake
if (ANDROID)
  target_link_options(ocr_shim PRIVATE "-Wl,-z,max-page-size=16384")
endif()
```

- [ ] **Step 3: 写 `tool/ocr_cli/CMakeLists.txt`**

```cmake
cmake_minimum_required(VERSION 3.22)
project(ocr_cli CXX C)
set(CMAKE_CXX_STANDARD 17)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../native/ocr_shim ocr_shim)
add_executable(ocr_cli main.cpp)
target_link_libraries(ocr_cli PRIVATE ocr_shim)
```

- [ ] **Step 4: 实现 `ocr_create` / `ocr_destroy` / `ocr_stats_size`**

`ocr_create` 顺序：

1. `llama_backend_init()`。
2. `llama_model_params`：`n_gpu_layers=0`、`use_mmap=true`、`progress_callback` 转发 `"load"` 进度。
3. `llama_model_load_from_file`。
4. `llama_context_params`：`n_ctx`、`n_batch`、`n_ubatch=min(n_batch, 256)`、`n_threads`、`flash_attn_type=LLAMA_FLASH_ATTN_TYPE_AUTO`。
5. `llama_init_from_model`。
6. `mtmd_context_params_default()`：`use_gpu=false`、`print_timings=false`、`n_threads`、`image_max_tokens`、`media_marker=mtmd_default_marker()`。
7. `mtmd_init_from_file(mmproj_path, model, params)`；若 `!mtmd_support_vision` 则失败。
8. 任一步失败：释放已创建资源，写 `err`，返回 `nullptr`。若错误文本包含 `out of memory` 或 `failed to allocate`，错误码用 `E_OOM`，否则用 `E_LOAD`。

`ocr_destroy`：释放 sampler（如有）、mtmd、context、model，最后 `llama_backend_free()`。
`ocr_stats_size`：`return sizeof(ocr_stats);`。
在 `ocr_shim.cpp` 加 `static_assert(sizeof(ocr_stats) == 56, "ocr_stats ABI changed");`。

日志：在 `ocr_create` 开头调用 `llama_log_set` 与 `mtmd_helper_log_set`，把 `ggml`/llama 日志转发到 stderr；Android 下用 `__android_log_print(ANDROID_LOG_INFO, "LightOnOCR", ...)`，其他平台用 `fprintf(stderr, ...)`。Dart 侧不依赖日志判断成败。

- [ ] **Step 5: 写 CLI 参数与 `--info` / `--load-only`**

支持：

```
--info
--load-only
--model <path> --mmproj <path>
--image <ppm> --mode plain|grounding
--max-tokens <int> --temp <float> --seed <int>
--cancel-after-ms <int>
```

`--info` 只打印 `stats_size=<n>`，不需要模型。
`--load-only` 调 `ocr_create` 后立即 `ocr_destroy`，成功打印 `load_ok`。

- [ ] **Step 6: 编译并验证 ABI**

```bash
cmake -S tool/ocr_cli -B build/ocr_cli -DCMAKE_BUILD_TYPE=Release
cmake --build build/ocr_cli -j
build/ocr_cli/ocr_cli --info
```

Expected: `stats_size=56`。

- [ ] **Step 7: 验证模型加载**

```bash
build/ocr_cli/ocr_cli --load-only \
  --model build-models/lightonocr3-0.8b-Q8_0.gguf \
  --mmproj build-models/mmproj-lightonocr3-0.8b-f16.gguf
```

Expected: 退出码 0，打印 `load_ok`。

- [ ] **Step 8: 验证失败路径**

```bash
build/ocr_cli/ocr_cli --load-only --model /nope.gguf --mmproj /nope.gguf; echo "exit=$?"
```

Expected: 非 0 退出码，stderr 含 `E_LOAD:`。

- [ ] **Step 9: 提交**

```bash
git add native/ocr_shim/include/ocr_shim.h native/ocr_shim/src/ocr_shim.cpp \
        native/ocr_shim/CMakeLists.txt tool/ocr_cli/CMakeLists.txt tool/ocr_cli/main.cpp
git commit -m "feat(native): add C ABI, CMake build, and model loading"
```

---

## Task 5: Native 生成循环、统计与取消

**Files:**
- Modify: `native/ocr_shim/src/ocr_shim.cpp`
- Modify: `tool/ocr_cli/main.cpp`
- Create: `tool/model/smoke_shim.sh`

**Interfaces:**
- Produces: 可用的 `ocr_run`，输出 `ocr_stats`，支持 `ocr_cancel`。
- Consumes: Task 4 的引擎句柄、Task 3 的 prompt/UTF-8。

- [ ] **Step 1: 写 `smoke_shim.sh`**

脚本先由 `.venv-model` 的 Pillow 把 sample 转成长边 2048 的 PPM：

```bash
.venv-model/bin/python - <<'PY'
from PIL import Image
im = Image.open("samples/report-1.jpg").convert("RGB")
im.thumbnail((2048, 2048))
im.save("build/eval/report-1-2048.ppm")
print(im.width, im.height)
PY
```

然后调用：

```bash
build/ocr_cli/ocr_cli \
  --model build-models/lightonocr3-0.8b-Q8_0.gguf \
  --mmproj build-models/mmproj-lightonocr3-0.8b-f16.gguf \
  --image build/eval/report-1-2048.ppm \
  --mode grounding --max-tokens 2048 --temp 0.2 --seed 42
```

- [ ] **Step 2: CLI 实现 P6 PPM 读取**

`readPpm(path)` 返回 `{width, height, std::vector<uint8_t> rgb}`；只接受 `P6`、最大值 255、无注释。失败时 `E_ENCODE`。

- [ ] **Step 3: 实现 `ocr_run` 的 prompt / tokenize / eval**

固定流程：

1. `llama_memory_clear(llama_get_memory(ctx), true)`。
2. `ocr_build_prompt(mtmd_default_marker(), mode)`。
3. `mtmd_bitmap_init(width, height, rgb)`。
4. `mtmd_input_text { prompt.data(), prompt.size(), false, true }`。
5. `mtmd_tokenize(ctx, chunks, &text, &bitmap, 1)`；成功后 `mtmd_bitmap_free`。
6. 遍历 chunks：
   - 文本 chunk：`mtmd_helper_eval_chunk_single(..., logits_last, &n_past)`，计时累加到 `prefill_ms`。
   - 图片 chunk：`mtmd_encode_chunk`（计时 `encode_ms`）→ `mtmd_get_output_embd` → `mtmd_helper_decode_image_chunk`（计时 `prefill_ms`）。
7. `prompt_tokens = mtmd_helper_get_n_tokens(chunks)`，`image_tokens` 累加图片 chunk 的 token 数。
8. 释放 chunks。

- [ ] **Step 4: 实现采样循环**

- 采样链：`top_k(20)` → `top_p(0.9, 1)` → `temp(temperature)` → `dist(seed)`。
- `mode` 不是 `plain`/`grounding` 时立即返回 `E_MODE`。
- `llama_sampler_sample(smpl, ctx, -1)`；`llama_sampler_accept`。
- `llama_vocab_is_eog` 命中即停止。
- `llama_token_to_piece` 后交给 `Utf8StreamBuffer`，再回调 `on_token`。
- 每个生成 token 用 `llama_batch_init(1,0,1)` 解码：`pos=n_past`、`seq_id=0`、`logits=true`；`n_past++`。
- 若 `n_past + 1 >= n_ctx`，优雅停止并返回已有文本。
- `ocr_cancel` 在每个 token 前检查；命中时返回 `E_CANCELLED`。
- `llama_decode` 失败时：错误文本含 `out of memory`/`failed to allocate` → `E_OOM`，否则 `E_DECODE`。
- 结束后 `flush` UTF-8 缓冲，填充 `output_tokens`、`decode_ms`、`peak_rss_kb`。

- [ ] **Step 5: 实现取消测试路径**

CLI 的 `--cancel-after-ms N`：启动一个 `std::thread`，`sleep_for(N)` 后调用 `ocr_cancel`。主线程等待 `ocr_run` 返回。

- [ ] **Step 6: 编译并跑通**

```bash
cmake --build build/ocr_cli -j
bash tool/model/smoke_shim.sh > build/eval/shim-report-1.md
wc -c build/eval/shim-report-1.md
```

Expected: 输出 > 100 字节；文件末尾包含 `stats:` JSON 行。

- [ ] **Step 7: 验证取消**

```bash
build/ocr_cli/ocr_cli \
  --model build-models/lightonocr3-0.8b-Q8_0.gguf \
  --mmproj build-models/mmproj-lightonocr3-0.8b-f16.gguf \
  --image build/eval/report-1-2048.ppm \
  --mode grounding --max-tokens 4096 --cancel-after-ms 50; echo "exit=$?"
```

Expected: 非 0 退出码（3），错误码 `E_CANCELLED`。

- [ ] **Step 8: 提交**

```bash
git add native/ocr_shim/src/ocr_shim.cpp tool/ocr_cli/main.cpp tool/model/smoke_shim.sh
git commit -m "feat(native): implement generation loop, stats, and cancellation"
```

---

## Task 6: Android CMake / Gradle 集成

**Files:**
- Modify: `android/app/build.gradle.kts`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `android/gradle.properties`
- Create: `android/app/src/main/cpp/CMakeLists.txt`

**Interfaces:**
- Produces: debug APK 内含 `lib/arm64-v8a/libocrshim.so`，16KB 对齐。
- Consumes: Task 4/5 的 `native/ocr_shim`。

- [ ] **Step 1: 写 `android/app/src/main/cpp/CMakeLists.txt`**

```cmake
cmake_minimum_required(VERSION 3.22)
project(lightonocr_app CXX C)

# Flutter debug native builds default to -O0; llama.cpp at -O0 is unusable.
set(CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG} -O3")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -O3")
set(CMAKE_ASM_FLAGS_DEBUG "${CMAKE_ASM_FLAGS_DEBUG} -O3")

add_subdirectory(
  ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../native/ocr_shim
  ocr_shim)
```

- [ ] **Step 2: 修改 `android/app/build.gradle.kts`**

在 `android { ... }` 中：

- `ndkVersion = flutter.ndkVersion`
- `defaultConfig.minSdk = 26`
- `defaultConfig.ndk { abiFilters += listOf("arm64-v8a") }`
- `defaultConfig.externalNativeBuild.cmake.arguments += listOf("-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON")`
- `externalNativeBuild.cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.22.1" }`
- `packaging { jniLibs { useLegacyPackaging = true } }`
- `android/gradle.properties` 增加 `disable-abi-filtering=true`，否则 Flutter 插件会清空 `abiFilters` 并重新加入 arm32/x86。

- [ ] **Step 3: 修改 `AndroidManifest.xml`**

- `<application ... android:extractNativeLibs="true">`
- 增加 `<uses-permission android:name="android.permission.CAMERA" />`

- [ ] **Step 4: 构建 debug APK**

Run: `flutter build apk --debug`
Expected: 构建成功。

- [ ] **Step 5: 检查 .so 被打包**

```bash
unzip -l build/app/outputs/flutter-apk/app-debug.apk | rg "libocrshim.so"
```

Expected: 存在 `lib/arm64-v8a/libocrshim.so`。

- [ ] **Step 6: 检查 16KB 对齐**

```bash
unzip -o build/app/outputs/flutter-apk/app-debug.apk lib/arm64-v8a/libocrshim.so -d build/apk-check
READELF=$(ls "$HOME"/Library/Android/sdk/ndk/*/toolchains/llvm/prebuilt/*/bin/llvm-readelf | tail -1)
"$READELF" -l build/apk-check/lib/arm64-v8a/libocrshim.so | rg "LOAD"
```

Expected: 至少一个 `LOAD` 的 `Align` 为 `0x4000`。

- [ ] **Step 7: 提交**

```bash
git add android/app/build.gradle.kts android/app/src/main/AndroidManifest.xml \
        android/gradle.properties android/app/src/main/cpp/CMakeLists.txt
git commit -m "build(android): integrate llama.cpp shim with 16KB page alignment"
```

---

## Task 7: Dart 类型与配置

**Files:**
- Modify: `pubspec.yaml`
- Create: `lib/src/ocr/ocr_types.dart`
- Create: `test/ocr_types_test.dart`

**Interfaces:**
- Produces: `OcrMode`、`OcrConfig`、`OcrStats`、`OcrResult`、`OcrProgress`、`OcrException`、`OcrErrorCode`。

- [ ] **Step 1: 添加依赖**

在 `pubspec.yaml` 的 `dependencies` 下加入：

```yaml
  file_picker: ^13.1.0
  image: ^4.12.0
  ffi: ^2.2.0
  path: ^1.9.1
```

Run: `flutter pub get`
Expected: 解析成功，`pubspec.lock` 更新。

- [ ] **Step 2: 写失败测试**

`test/ocr_types_test.dart` 断言：

```dart
test('defaults match spec', () {
  const c = OcrConfig();
  expect(c.longestEdge, 1280);
  expect(c.maxTokens, 4096);
  expect(c.nCtx, 12288);
  expect(c.nBatch, 2048);
  expect(c.imageMaxTokens, 4096);
  expect(c.seed, 42);
  expect(c.nThreads, greaterThan(0));
});

test('json round trip', () {
  const c = OcrConfig(longestEdge: 1536, maxTokens: 2048, nThreads: 4);
  expect(OcrConfig.fromJson(c.toJson()).toJson(), c.toJson());
});

test('stats tokens per second', () {
  const s = OcrStats(
    promptTokens: 100, outputTokens: 50, imageTokens: 300,
    loadMs: 100, encodeMs: 100, prefillMs: 100, decodeMs: 1000,
    peakRssKb: 1000,
  );
  expect(s.totalMs, 1300);
  expect(s.tokensPerSecond, 50);
});

test('exception carries code and message', () {
  final e = OcrException('E_LOAD', 'boom');
  expect(e.code, 'E_LOAD');
  expect(e.toString(), contains('E_LOAD'));
});
```

- [ ] **Step 3: 运行测试，确认失败**

Run: `flutter test test/ocr_types_test.dart`
Expected: 编译失败，`ocr_types.dart` 不存在。

- [ ] **Step 4: 实现 `ocr_types.dart`**

- `OcrConfig` 字段与默认值按 Global Constraints；`copyWith`、`toJson`、`fromJson`。
- `const OcrConfig()` 的 `nThreads` 固定默认值为 `4`；`OcrConfig.forDevice()` 使用 `min(6, Platform.numberOfProcessors)`。`ModelStore.loadConfig` 的缺失/损坏回退使用 `forDevice()`。
- `OcrStats.totalMs` 为四段之和；`tokensPerSecond = outputTokens / (decodeMs / 1000)`，`decodeMs <= 0` 时为 0。
- `OcrErrorCode` 常量：`modelMissing`、`ggufInvalid`、`load`、`oom`、`encode`、`decode`、`mode`、`cancelled`、`workerCrash`、`busy`。

- [ ] **Step 5: 运行测试，确认通过**

Run: `flutter test test/ocr_types_test.dart`
Expected: All tests passed。

- [ ] **Step 6: 提交**

```bash
git add pubspec.yaml pubspec.lock lib/src/ocr/ocr_types.dart test/ocr_types_test.dart
git commit -m "feat(dart): add OCR types and configuration"
```

---

## Task 8: Dart FFI 绑定与 macOS 冒烟

**Files:**
- Create: `lib/src/ocr/ocr_ffi.dart`
- Create: `tool/ffi_smoke.dart`

**Interfaces:**
- Consumes: Task 4 的 C ABI。
- Produces:
  - `OcrFfi.open({String? libraryPath})`
  - `int statsSize()`
  - `Pointer<OcrEngine> create({required String modelPath, required String mmprojPath, required OcrConfig config, required OcrProgressCallback onProgress})`
  - `OcrStats run({required Pointer<OcrEngine> engine, required Uint8List rgb, required int width, required int height, required OcrMode mode, required int maxTokens, required double temperature, required int seed, required OcrTokenCallback onToken, required OcrProgressCallback onProgress})`
  - `void cancel(Pointer<OcrEngine>)`
  - `void destroy(Pointer<OcrEngine>)`

- [ ] **Step 1: 写 `tool/ffi_smoke.dart`**

```dart
import 'dart:io';
import 'package:lighton_ocr_on_device/src/ocr/ocr_ffi.dart';

void main() {
  final path = Platform.environment['OCR_SHIM_LIB'] ??
      'build/ocr_cli/ocr_shim/libocrshim.dylib';
  final ffi = OcrFfi.open(libraryPath: path);
  final size = ffi.statsSize();
  stdout.writeln('stats_size=$size');
  if (size != 56) exitCode = 1;
}
```

- [ ] **Step 2: 运行，确认失败**

Run: `dart run tool/ffi_smoke.dart`
Expected: 编译失败，`ocr_ffi.dart` 不存在。

- [ ] **Step 3: 实现 `ocr_ffi.dart`**

- `final class OcrEngine extends Opaque {}`。
- `OcrFfi.open({String? libraryPath})`：`libraryPath` 为空时，Android 用 `libocrshim.so`，其他平台用 `libocrshim.dylib`。
- `final class OcrStatsNative extends Struct` 字段顺序与 C 完全一致；`@Int32` ×4、`@Double` ×4、`@Int64`。
- 手写 `lookupFunction`，函数签名与 `ocr_shim.h` 一致。
- 字符串用 `toNativeUtf8()`，错误缓冲 `calloc<Uint8>(1024)`。
- token 回调：`utf8.decode(ptr.asTypedList(len))`。
- progress 回调：`stagePtr.cast<Utf8>().toDartString()`。
- `create` / `run` 在 native 返回失败时抛 `OcrException(code, message)`；错误码取 `message` 冒号前部分。
- `NativeCallable.isolateLocal` 在调用结束后 `close()`；`create` 的 progress callable 在 `create` 返回后关闭。
- `statsSize()` 直接返回 native 的 `size_t`。

- [ ] **Step 4: 运行 macOS 冒烟**

Run: `dart run tool/ffi_smoke.dart`
Expected: `stats_size=56`，退出码 0。

- [ ] **Step 5: 提交**

```bash
git add lib/src/ocr/ocr_ffi.dart tool/ffi_smoke.dart
git commit -m "feat(dart): add FFI bindings and ABI smoke check"
```

---

## Task 9: 常驻 Worker Isolate

**Files:**
- Create: `lib/src/ocr/ocr_worker.dart`
- Create: `test/ocr_worker_protocol_test.dart`

**Interfaces:**
- Produces:
  - `sealed class WorkerCommand` / `WorkerEvent` 及子类。
  - `abstract class OcrWorker`：
    - `Stream<WorkerEvent> get events`
    - `Future<void> start()`
    - `Future<void> load({required String modelPath, required String mmprojPath, required OcrConfig config})`
    - `Future<void> run({required Uint8List encodedImage, required int longestEdge, required OcrMode mode, required int maxTokens})`
    - `Future<void> cancel()`
    - `Future<void> dispose()`
  - `IsolateOcrWorker`：`start()` 启动 isolate；native 库只在 `LoadCommand` 时打开。
- Consumes: Task 8 的 `OcrFfi`。

- [ ] **Step 1: 写失败测试**

`test/ocr_worker_protocol_test.dart`：

```dart
test('worker starts and disposes without loading native', () async {
  final worker = IsolateOcrWorker();
  await worker.start();
  await worker.dispose();
  expect(worker.isRunning, isFalse);
});

test('run command carries transferable bytes', () {
  final bytes = Uint8List.fromList([1, 2, 3, 4]);
  final cmd = RunCommand(encodedImage: bytes, longestEdge: 2048, mode: OcrMode.plain, maxTokens: 4096);
  expect(cmd.encodedImage, bytes);
});
```

- [ ] **Step 2: 运行，确认失败**

Run: `flutter test test/ocr_worker_protocol_test.dart`
Expected: 编译失败，`ocr_worker.dart` 不存在。

- [ ] **Step 3: 实现协议与 isolate**

- `WorkerCommand`：`LoadCommand(modelPath, mmprojPath, config)`、`RunCommand(encodedImage, longestEdge, mode, maxTokens)`、`CancelCommand`、`DisposeCommand`。
- `WorkerEvent`：`LoadingEvent(fraction)`、`ProgressEvent(progress)`、`TokenEvent(text)`、`DoneEvent(result)`、`FailedEvent(code, message)`。
- `ocrWorkerMain(SendPort uiPort)`：
  1. 建 `ReceivePort`，把 `sendPort` 发回 UI。
  2. 收到 `LoadCommand` 才 `OcrFfi.open()` 并 `create`；创建成功后先发 `LoadingEvent(1.0)`（若回调未到 1.0）。
  3. `RunCommand`：先 `prepareImage`（Task 11 实现；本任务先调用占位函数会编译失败，因此 Task 11 必须在本任务前完成，见依赖说明），发 `ProgressEvent(stage:'preprocess')`，再 `run`。
  4. `CancelCommand` 调 `ocr_cancel`。
  5. `DisposeCommand` 销毁引擎、关端口、退出。
- `IsolateOcrWorker`：
  - `start()`：`ReceivePort` + `Isolate.spawn`，等待 worker 的 `SendPort`。
  - `events` 为 broadcast stream。
  - `run` 把 `Uint8List` 包装为 `TransferableTypedData`。
  - `dispose()` 发 `DisposeCommand`，等待 200ms 后 `Isolate.kill(priority: Isolate.immediate)`。
  - `isRunning` 暴露 isolate 状态。
  - `onError` / `onExit` 时把 `isRunning` 置 false，并向 `events` 发 `FailedEvent('E_WORKER_CRASH', message)`；下一次 `load` 重新 spawn。

**依赖说明：** 本任务依赖 Task 11 的 `prepareImage`。执行顺序可把 Task 11 提前到 Task 9 之前；若按编号执行，先把 Task 11 完成再回到 Task 9。

- [ ] **Step 4: 运行测试，确认通过**

Run: `flutter test test/ocr_worker_protocol_test.dart`
Expected: All tests passed；测试不会打开 native 库。

- [ ] **Step 5: 提交**

```bash
git add lib/src/ocr/ocr_worker.dart test/ocr_worker_protocol_test.dart
git commit -m "feat(dart): add resident OCR worker isolate"
```

---

## Task 10: GGUF 探测与模型仓库

**Files:**
- Create: `lib/src/models/gguf_probe.dart`
- Create: `lib/src/models/model_store.dart`
- Create: `test/gguf_probe_test.dart`
- Create: `test/model_store_test.dart`

**Interfaces:**
- Produces:
  - `enum GgufKind { main, mmproj, unknown }`
  - `Future<GgufKind> GgufProbe.detect(File file)`
  - `class ModelInfo { File main; File mmproj; int totalBytes; }`
  - `abstract class ModelRepository { Future<ModelInfo?> load(); Future<OcrConfig> loadConfig(); Future<void> saveConfig(OcrConfig); Future<void> deleteAll(); }`
  - `class ModelStore implements ModelRepository`：`ModelStore({required Directory root, int minMainBytes = 300 * 1024 * 1024, int minMmprojBytes = 50 * 1024 * 1024})`、`importMain(File, {onProgress})`、`importMmproj(File, {onProgress})`。

- [ ] **Step 1: 写 GGUF 失败测试**

`test/gguf_probe_test.dart`：

- 临时文件写入 `GGUF` + `qwen35` → `GgufKind.main`。
- 写入 `GGUF` + `clip.projector_type` → `GgufKind.mmproj`。
- 写入 `not gguf` → `GgufKind.unknown`。

- [ ] **Step 2: 运行，确认失败**

Run: `flutter test test/gguf_probe_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现 `gguf_probe.dart`**

读取前 4MB；检查 `47 47 55 46`；在字节中搜索 ASCII `qwen35` 或 `general.architecture` → main；搜索 `clip.` 或 `qwen3vl` → mmproj；同时命中时优先 mmproj（mmproj 也含 `general.architecture`）。

- [ ] **Step 4: 写 ModelStore 失败测试**

`test/model_store_test.dart` 覆盖：

- 导入合法主模型/mmproj 后，`load()` 返回完整 `ModelInfo`，文件名被规范化为 `lightonocr3-0.8b.gguf` / `mmproj-lightonocr3-0.8b.gguf`。
- 导入非 GGUF 抛 `OcrException`，错误码 `E_GGUF_INVALID`，目标目录不残留半成品。
- 主模型小于 300MB 或 mmproj 小于 50MB 抛 `E_GGUF_INVALID`。
- 配置文件读写 round-trip；损坏 JSON 回退到默认 `OcrConfig`。
- `deleteAll()` 后 `load()` 返回 null。

测试文件用临时目录；`ModelStore` 传 `minMainBytes: 1024`、`minMmprojBytes: 512`，用小文件覆盖大小校验，不写 300MB。

- [ ] **Step 5: 运行，确认失败**

Run: `flutter test test/model_store_test.dart`
Expected: 编译失败。

- [ ] **Step 6: 实现 `model_store.dart`**

- 目录：`<root>/models/`。
- 规范文件名：`lightonocr3-0.8b.gguf`、`mmproj-lightonocr3-0.8b.gguf`。
- 导入：校验 kind、大小；写 `.part` 临时文件；1MB 分块拷贝并回调进度；成功后 `rename`；失败删除 `.part`。
- 配置：`models/config.json`；字段按 spec 7.6，额外 `seed`。
- `loadConfig` 捕获 `FormatException`/`FileSystemException`，返回 `OcrConfig.forDevice()`。

- [ ] **Step 7: 运行测试，确认通过**

Run:

```bash
flutter test test/gguf_probe_test.dart test/model_store_test.dart
```

Expected: All tests passed。

- [ ] **Step 8: 提交**

```bash
git add lib/src/models/gguf_probe.dart lib/src/models/model_store.dart \
        test/gguf_probe_test.dart test/model_store_test.dart
git commit -m "feat(dart): add GGUF validation and model store"
```

---

## Task 11: 图片预处理

**Files:**
- Create: `lib/src/image/image_preprocess.dart`
- Create: `test/image_preprocess_test.dart`

**Interfaces:**
- Produces:
  - `class PreparedImage { Uint8List rgb; int width; int height; }`
  - `Future<PreparedImage> prepareImage(Uint8List encoded, {int longestEdge = 2048})`

- [ ] **Step 1: 写失败测试**

`test/image_preprocess_test.dart`：

- 先创建 EXIF 方向 6 的 fixture：

```bash
mkdir -p test/fixtures
.venv-model/bin/python - <<'PY'
from PIL import Image
im = Image.new("RGB", (200, 400), "white")
exif = im.getexif()
exif[274] = 6
im.save("test/fixtures/exif_orientation_6.jpg", exif=exif)
PY
```

- 生成 4000×2000 PNG，`longestEdge=2048` → `width=2048`、`height=1024`、`rgb.length == 2048*1024*3`。
- 生成 2000×4000 PNG → `width=1024`、`height=2048`。
- 生成 400×200 PNG → 保持 400×200（不放大）。
- 读取 `test/fixtures/exif_orientation_6.jpg` → 输出宽高交换为 400×200。
- 传入随机字节 → 抛 `OcrException`，`code == 'E_ENCODE'`。

- [ ] **Step 2: 运行，确认失败**

Run: `flutter test test/image_preprocess_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现 `prepareImage`**

使用 `package:image`：

```dart
final decoded = img.decodeImage(encoded);
if (decoded == null) throw OcrException('E_ENCODE', 'decode failed');
final oriented = img.bakeOrientation(decoded);
final target = _fitLongestEdge(oriented.width, oriented.height, longestEdge);
final resized = img.copyResize(oriented, width: target.width, height: target.height, interpolation: img.Interpolation.average);
final rgb = resized.getBytes(order: img.ChannelOrder.rgb);
return PreparedImage(rgb: rgb, width: resized.width, height: resized.height);
```

`_fitLongestEdge` 规则：`max(w,h) <= longestEdge` 原样返回；否则按比例缩放并 `round()`，最小边至少 1。

- [ ] **Step 4: 运行测试，确认通过**

Run: `flutter test test/image_preprocess_test.dart`
Expected: All tests passed。

- [ ] **Step 5: 提交**

```bash
git add lib/src/image/image_preprocess.dart test/image_preprocess_test.dart
git commit -m "feat(dart): add EXIF-aware image preprocessing"
```

---

## Task 11b: Grounding 输出解析

**Files:**
- Create: `lib/src/ocr/grounding.dart`
- Create: `test/grounding_test.dart`

**Interfaces:**
- Produces:
  - `class GroundingBlock { final String label; final List<int> bbox; final String text; final bool continues; }`
  - `List<GroundingBlock> parseGrounding(String raw)`
  - `String groundingToMarkdown(String raw, {Set<String> drop = const {}})`

- [ ] **Step 1: 写失败测试**

`test/grounding_test.dart`：

```dart
test('parses two blocks', () {
  final blocks = parseGrounding(
    '![title](10,20,30,40) # Hi\n\n![text](50,60,70,80) Body',
  );
  expect(blocks, hasLength(2));
  expect(blocks[0].label, 'title');
  expect(blocks[0].bbox, [10, 20, 30, 40]);
  expect(blocks[0].text, '# Hi');
  expect(blocks[1].text, 'Body');
});

test('continuation joins with a space', () {
  final md = groundingToMarkdown(
    '![text](0,0,10,10) one\n![text+](0,0,10,10) two',
  );
  expect(md, 'one two');
});

test('no markers returns raw', () {
  expect(groundingToMarkdown('plain text'), 'plain text');
});

test('drop removes header and footer', () {
  final md = groundingToMarkdown(
    '![header](0,0,10,10) H\n![text](0,0,10,10) Body\n![footer](0,0,10,10) F',
    drop: {'header', 'footer'},
  );
  expect(md, 'Body');
});

test('repairs dollar entities', () {
  expect(groundingToMarkdown('![text](0,0,10,10) a &dollar;x&dollar; b'), 'a \$x\$ b');
});
```

- [ ] **Step 2: 运行，确认失败**

Run: `flutter test test/grounding_test.dart`
Expected: 编译失败，`grounding.dart` 不存在。

- [ ] **Step 3: 实现 `grounding.dart`**

- Marker 正则：`!\[([A-Za-z_][\w-]*?)(\+?)\]\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)[ \t]*`。
- `parseGrounding`：每个 marker 的 text 到下一个 marker 前；`trim()`；`continues = group(2) == '+'`。
- 没有 marker 时返回空列表。
- `groundingToMarkdown`：没有 marker 直接返回 `raw.trim()`；有 marker 时按 blocks 拼接，`drop` 中的 label 跳过，`continues` 且前一个保留块存在时用空格追加，否则用 `\n\n` 连接；最后把 `&dollar;` 替换为 `\$`。

- [ ] **Step 4: 运行测试，确认通过**

Run: `flutter test test/grounding_test.dart`
Expected: All tests passed。

- [ ] **Step 5: 提交**

```bash
git add lib/src/ocr/grounding.dart test/grounding_test.dart
git commit -m "feat(dart): parse grounding output into markdown"
```

---

## Task 12: OcrService 状态机

**Files:**
- Create: `lib/src/ocr/ocr_service.dart`
- Create: `test/ocr_service_test.dart`

**Interfaces:**
- Consumes: `ModelRepository`、`OcrWorker`、`prepareImage`。
- Produces:
  - `enum OcrServiceState { unconfigured, loading, ready, running, cancelling, failed }`
  - `class OcrService extends ChangeNotifier`：`initialize`、`loadModel`、`recognize({required Uint8List encodedImage, OcrMode mode = OcrMode.grounding})`、`cancel`、`reset`、`updateConfig`。

- [ ] **Step 1: 写失败测试**

`test/ocr_service_test.dart` 使用 `FakeModelRepository` 与 `FakeOcrWorker`：

- `initialize()` 无模型 → `unconfigured`。
- `initialize()` 有模型 → `ready`。
- `recognize()` → 依次 `loading`（首次）、`running`，最终 `ready`，`result.text` 正确。
- 第二次 `recognize()` 不再发 `LoadCommand`。
- `cancel()` → `cancelling` → `ready`，`partialText` 清空。
- `load` 失败 → `failed`，`error.code == 'E_LOAD'`；再次 `recognize()` 可重试。
- 运行中再次 `recognize()` → `error.code == 'E_BUSY'`。
- 模型缺失时 `recognize()` → `unconfigured`，不调用 worker。

- [ ] **Step 2: 运行，确认失败**

Run: `flutter test test/ocr_service_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现 `OcrService`**

- 构造：`ModelRepository modelStore`、`OcrWorker Function() workerFactory`。
- `initialize()`：`modelStore.load()`；完整则 `ready`，否则 `unconfigured`。
- `_ensureLoaded()`：worker 为 null 时创建并 `start`；发 `LoadCommand`；等待 `LoadingEvent(1.0)` 或 `FailedEvent`。
- `recognize()`：检查状态、模型；清空 `partialText`/`result`/`error`；首次触发 `_ensureLoaded`；发 `RunCommand`（默认 `mode=OcrMode.grounding`）；订阅事件直到 `DoneEvent`/`FailedEvent`。
- `TokenEvent` 追加到 `partialText` 并 `notifyListeners()`。
- `cancel()`：状态改 `cancelling`，调 `worker.cancel()`；等待 `FailedEvent(E_CANCELLED)`，超时 3s 则重建 worker 并回到 `ready`。
- `reset()`：`worker.dispose()`，worker 置空，状态回到 `ready`/`unconfigured`。
- `updateConfig()`：保存到 repository；`longestEdge`/`maxTokens` 立即生效，`nCtx`/`nThreads` 变更时提示需 `reset()`。
- `dispose()`：`unawaited(worker?.dispose())`。

- [ ] **Step 4: 运行测试，确认通过**

Run: `flutter test test/ocr_service_test.dart`
Expected: All tests passed。

- [ ] **Step 5: 提交**

```bash
git add lib/src/ocr/ocr_service.dart test/ocr_service_test.dart
git commit -m "feat(dart): add OCR service state machine"
```

---

## Task 13: App Shell 与模型配置页

**Files:**
- Modify: `lib/main.dart`
- Create: `lib/app.dart`
- Create: `lib/src/ui/model_setup_page.dart`
- Create: `lib/src/ui/widgets/model_status_card.dart`
- Create: `lib/src/models/model_file_picker.dart`
- Create: `test/model_setup_page_test.dart`

**Interfaces:**
- Produces:
  - `class LightOnOcrApp extends StatelessWidget`（`service`、`store`）。
  - `class ModelSetupPage extends StatefulWidget`（`store`、`picker`、`service`）。
  - `abstract class ModelFilePicker { Future<File?> pickGgufFile(); }`
  - `class DeviceModelFilePicker implements ModelFilePicker`。

- [ ] **Step 1: 写失败 Widget 测试**

`test/model_setup_page_test.dart`：

- 用 `ModelStore` 指向临时目录，`FakeModelFilePicker` 返回 null。
- pump `ModelSetupPage`；找到“主模型”“mmproj”“导入”三个文案。
- 两个槽位都显示“未导入”。

- [ ] **Step 2: 运行，确认失败**

Run: `flutter test test/model_setup_page_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现文件选择器**

```dart
abstract class ModelFilePicker {
  Future<File?> pickGgufFile();
}

class DeviceModelFilePicker implements ModelFilePicker {
  @override
  Future<File?> pickGgufFile() async {
    final result = await FilePicker.pickFile(type: FileType.any);
    final path = result?.path;
    return path == null ? null : File(path);
  }
}
```

- [ ] **Step 4: 实现模型配置页**

- 两个卡片：主模型、mmproj；显示文件名/大小/校验状态。
- “导入”按钮调用 picker → `store.importMain` / `importMmproj`，显示 `LinearProgressIndicator`。
- 导入失败显示 `OcrException.code` 与中文说明。
- “加载模型”调用 `service.loadModel()`；“释放内存”调用 `service.reset()`；“删除模型”调用 `store.deleteAll()`。
- 成功后 `Navigator.pop(context)`。

- [ ] **Step 5: 实现 `app.dart` 与 `main.dart`**

`main.dart`：

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = await getApplicationSupportDirectory();
  final store = ModelStore(root: root);
  final service = OcrService(modelStore: store, workerFactory: IsolateOcrWorker.new);
  await service.initialize();
  runApp(LightOnOcrApp(service: service, store: store));
}
```

`app.dart`：`MaterialApp`（Material 3，中文标题），`home` 为 `HomePage`（Task 14；本任务可先放占位 `Scaffold`，Task 14 替换）。

- [ ] **Step 6: 运行测试，确认通过**

Run: `flutter test test/model_setup_page_test.dart`
Expected: All tests passed。

- [ ] **Step 7: 提交**

```bash
git add lib/main.dart lib/app.dart lib/src/ui/model_setup_page.dart \
        lib/src/ui/widgets/model_status_card.dart lib/src/models/model_file_picker.dart \
        test/model_setup_page_test.dart
git commit -m "feat(ui): add app shell and model setup page"
```

---

## Task 14: 首页、选图与运行

**Files:**
- Create: `lib/src/ui/home_page.dart`
- Create: `lib/src/image/image_source.dart`
- Create: `test/home_page_test.dart`
- Modify: `lib/app.dart`

**Interfaces:**
- Produces:
  - `class HomePage extends StatefulWidget`（`service`、`store`、`imageSource`）。
  - `abstract class ImageSourceService { Future<Uint8List?> pickFromGallery(); Future<Uint8List?> takePhoto(); }`
  - `class DeviceImageSourceService implements ImageSourceService`。

- [ ] **Step 1: 写失败 Widget 测试**

`test/home_page_test.dart` 使用 `FakeImageSourceService` 与真实 `OcrService`（FakeModelRepository/FakeOcrWorker）：

- 未配置模型：显示“配置模型”，点击进入模型页。
- 已配置：显示“开始识别”。
- 点击“相册”，fake 返回 PNG 字节，显示图片预览。
- 点击“开始识别”，fake worker 返回文本，导航到 `ResultPage`，页面出现该文本。
- 运行中按钮显示“取消”。

- [ ] **Step 2: 运行，确认失败**

Run: `flutter test test/home_page_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现 `image_source.dart`**

```dart
abstract class ImageSourceService {
  Future<Uint8List?> pickFromGallery();
  Future<Uint8List?> takePhoto();
}

class DeviceImageSourceService implements ImageSourceService {
  final ImagePicker _picker = ImagePicker();
  @override
  Future<Uint8List?> pickFromGallery() async =>
      (await _picker.pickImage(source: ImageSource.gallery))?.readAsBytes();
  @override
  Future<Uint8List?> takePhoto() async =>
      (await _picker.pickImage(source: ImageSource.camera))?.readAsBytes();
}
```

- [ ] **Step 4: 实现首页**

- 顶部模型状态卡片；未配置时点击跳转 `ModelSetupPage`。
- 图片预览区：`Image.memory`；空状态两个按钮“拍照”“相册”。
- 参数：长边 `DropdownButton`（1024/1280/1536/2048），最大输出（2048/4096/8192）；变更调用 `service.updateConfig`。
- 主按钮：未配置“配置模型”；ready“开始识别”；running“取消”；loading 显示进度。
- 运行前 `wakelock_plus.enable()`，结束后 `disable()`。
- 识别成功 `Navigator.push(ResultPage(result: ..., imageBytes: ...))`。
- 错误用 `SnackBar`/错误卡片显示 `error.code` 与中文说明。

- [ ] **Step 5: 替换 `app.dart` 的占位首页**

`LightOnOcrApp.home` 改为 `HomePage(service: service, store: store, imageSource: DeviceImageSourceService())`。

- [ ] **Step 6: 运行测试，确认通过**

Run: `flutter test test/home_page_test.dart`
Expected: All tests passed。

- [ ] **Step 7: 提交**

```bash
git add lib/src/ui/home_page.dart lib/src/image/image_source.dart lib/app.dart test/home_page_test.dart
git commit -m "feat(ui): add home page, image picking, and run flow"
```

---

## Task 15: 结果页

**Files:**
- Create: `lib/src/ui/result_page.dart`
- Create: `test/result_page_test.dart`

**Interfaces:**
- Produces: `class ResultPage extends StatelessWidget`（`result`、`imageBytes`）。

- [ ] **Step 1: 写失败 Widget 测试**

`test/result_page_test.dart`：

- 传入 `OcrResult(text: '![title](10,20,30,40) # 标题\n\n![text](0,0,10,10) 正文', stats: ...)`；默认“渲染”tab 显示“标题”“正文”，不显示 `![title]` 标记。
- 切到“原文”tab，显示原始 `![title](10,20,30,40)` 标记与文本。
- 点击“复制”，`Clipboard.setData` 被调用（用 `TestDefaultBinaryMessengerBinding` mock 剪贴板通道）。
- 找到“分享”“重新识别”“换一张”按钮。

- [ ] **Step 2: 运行，确认失败**

Run: `flutter test test/result_page_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现结果页**

- `DefaultTabController(length: 2)`；`TabBar`：渲染 / 原文。
- 渲染：`MarkdownBody(data: groundingToMarkdown(result.text))`；原文：`SelectableText(result.text)`。
- 顶部操作：复制（默认复制渲染后的 Markdown）、分享（`SharePlus.instance.share(ShareParams(text: groundingToMarkdown(result.text)))`）。
- 底部 `ExpansionTile` 显示 `OcrStats`：load/encode/prefill/decode/total/tok/s/image tokens/peak RSS。
- “重新识别”`Navigator.pop(context, true)`；“换一张”`Navigator.pop(context, false)`。

- [ ] **Step 4: 运行测试，确认通过**

Run: `flutter test test/result_page_test.dart`
Expected: All tests passed。

- [ ] **Step 5: 提交**

```bash
git add lib/src/ui/result_page.dart test/result_page_test.dart
git commit -m "feat(ui): add result page with markdown, copy, and share"
```

---

## Task 16: Android FFI 冒烟（M1 验证）

**Files:**
- Create: `lib/main_ffi_smoke.dart`
- Create: `docs/eval/2026-10-20-android-smoke.md`

**Interfaces:**
- Consumes: Task 8 的 `OcrFfi`、Task 6 的 APK。
- Produces: 真机上的 `stats_size`、模型加载结果、一张图的输出与耗时记录。

- [ ] **Step 1: 写 `lib/main_ffi_smoke.dart`**

入口：

1. `WidgetsFlutterBinding.ensureInitialized()`。
2. 用 `getExternalStorageDirectory()` 得到 `/sdcard/Android/data/<pkg>/files`，读 `models/` 下的两个 GGUF。
3. `OcrFfi.open()`，打印 `stats_size`。
4. `create`，打印 `load_ok`。
5. 读 `models/report-1-2048.rgb` 与 `models/report-1-2048.size`（`W H` 文本），调用 `run`，把文本写到界面并打印 `stats`。
6. 任一失败显示错误码。

- [ ] **Step 2: 推送模型与测试图片**

```bash
PKG=com.example.lighton_ocr_on_device
adb shell mkdir -p /sdcard/Android/data/$PKG/files/models
adb push build-models/lightonocr3-0.8b-Q8_0.gguf /sdcard/Android/data/$PKG/files/models/lightonocr3-0.8b.gguf
adb push build-models/mmproj-lightonocr3-0.8b-f16.gguf /sdcard/Android/data/$PKG/files/models/mmproj-lightonocr3-0.8b.gguf
```

生成并推送 RGB：

```bash
.venv-model/bin/python - <<'PY'
from PIL import Image
im = Image.open("samples/report-1.jpg").convert("RGB")
im.thumbnail((2048, 2048))
open("build/eval/report-1-2048.raw", "wb").write(im.tobytes())
open("build/eval/report-1-2048.size", "w").write(f"{im.width} {im.height}\n")
print(im.width, im.height)
PY
adb push build/eval/report-1-2048.raw /sdcard/Android/data/$PKG/files/models/report-1-2048.rgb
adb push build/eval/report-1-2048.size /sdcard/Android/data/$PKG/files/models/report-1-2048.size
```

- [ ] **Step 3: 运行冒烟入口**

Run: `flutter run -t lib/main_ffi_smoke.dart -d <android-device>`
Expected: 界面/日志出现 `stats_size=56`、`load_ok`、非空 OCR 文本、`stats` JSON。

- [ ] **Step 4: 记录结果**

在 `docs/eval/2026-10-20-android-smoke.md` 记录：

- 设备型号、Android 版本、ABI。
- 模型文件大小。
- `stats_size`、load/encode/prefill/decode、tok/s、峰值 RSS。
- 输出前 10 行与是否出现乱码/循环。

- [ ] **Step 5: 提交**

```bash
git add lib/main_ffi_smoke.dart docs/eval/2026-10-20-android-smoke.md
git commit -m "test(android): add device FFI smoke entrypoint and results"
```

---

## Task 17: 真机端到端验收

**Files:**
- Create: `docs/eval/2026-10-20-device-acceptance.md`

**Interfaces:**
- Consumes: Task 13–15 的完整 UI、Task 16 的模型推送方式。
- Produces: 8 张 sample 的结果、错误路径记录、内存与耗时数据。

- [ ] **Step 1: 构建并安装**

```bash
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
for f in samples/report-*.jpg; do adb push "$f" /sdcard/Download/; done
adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
  -d file:///sdcard/Download/report-1.jpg
```

- [ ] **Step 2: 导入模型**

把两个 GGUF 放到 `/sdcard/Download/`，在 App 模型页分别导入；确认两个槽位显示“已就绪”。

- [ ] **Step 3: 跑 8 张 sample**

对 `samples/report-1.jpg` 到 `report-8.jpg`：

1. 相册选图。
2. 保持长边 2048、最大输出 2048。
3. 记录端到端耗时、stats、输出是否可读。
4. 保存结果截图或复制文本到验收文档。

- [ ] **Step 4: 验证错误路径**

- 未导入模型 → 点击“开始识别”应引导配置。
- 主模型槽位选 mmproj 文件 → `E_GGUF_INVALID`，无半成品。
- 识别中点击“取消” → 回到 ready，可立即再次识别。
- 识别中切后台再回来 → 不崩溃；若被系统杀死，重开后可重试。
- 模型页“释放内存”后再识别 → 自动重新加载。

- [ ] **Step 5: 记录内存**

```bash
adb shell dumpsys meminfo com.example.lighton_ocr_on_device | rg "TOTAL|Native Heap"
```

把峰值记录到验收文档。

- [ ] **Step 6: 提交**

```bash
git add docs/eval/2026-10-20-device-acceptance.md
git commit -m "test(android): record 8-sample acceptance results"
```

---

## Task 18: M4 参数矩阵与默认值

**Files:**
- Create: `docs/eval/2026-10-20-device-bench.md`
- Modify: `lib/src/ocr/ocr_types.dart`（仅在实测要求时改默认值）
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 17 的验收环境。
- Produces: 量化档位、默认长边、默认最大输出、线程数的最终选择与依据。

- [ ] **Step 1: 跑矩阵**

在真机上对 `report-1`、`report-5` 跑：

- 量化：Q4KM-headQ4、Q4_K_M、Q8_0。
- 长边：1280、1536、2048（1024 作为低质量快速档）。
- 线程：6、8。

每个组合记录端到端耗时、decode tok/s、峰值 RSS、输出质量（可读/局部错字/不可用）。

- [ ] **Step 2: 选默认值**

按 spec 第 13 节规则：

- 当前 8GB 中端机默认 Q4KM-headQ4；Q4_K_M 保底，Q8_0 作为质量选项。
- 默认长边 1280；2048 作为精度模式。
- 默认线程 8；其他设备以实测为准。

- [ ] **Step 3: 更新默认值**

只改 `OcrConfig` 的默认常量与 `README`，不改 native 逻辑。若默认值不变，本步骤不产生代码改动。

- [ ] **Step 4: 全量验证**

用最终默认值重跑 8 张 sample，确认没有回归；把最终结果写入 `docs/eval/2026-10-20-device-bench.md`。

- [ ] **Step 5: 提交**

```bash
git add docs/eval/2026-10-20-device-bench.md lib/src/ocr/ocr_types.dart README.md
git commit -m "perf(android): tune defaults from device benchmark matrix"
```

---

## Task 19: README 与最终验证

**Files:**
- Modify: `README.md`
- Create: `tool/model/README.md`

**Interfaces:**
- Consumes: 全部前置任务。
- Produces: 可复现的转换/导入/运行说明。

- [ ] **Step 1: 写 `tool/model/README.md`**

包含：

- `setup_env.sh`、`convert.sh`、`quantize.sh`、`smoke_macos.sh`、`smoke_shim.sh` 的用途与执行顺序。
- 预期产物文件名与大小范围。
- M0 失败时的排查入口（`clip.projector_type`、`qwen35` 架构）。

- [ ] **Step 2: 更新根 `README.md`**

包含：

- 项目定位与“纯端侧、离线”说明。
- Android 构建命令。
- 模型转换与导入步骤（`adb push` 到 `Download/` 后在 App 内导入）。
- 默认参数与已知限制（中文质量、HTML 表格、低内存设备）。
- 8 张 sample 的实测结果链接。

- [ ] **Step 3: 最终静态检查**

Run: `flutter analyze`
Expected: `No issues found!`。

- [ ] **Step 4: 最终单测**

Run: `flutter test`
Expected: All tests passed。

- [ ] **Step 5: 最终构建**

Run: `flutter build apk --debug`
Expected: 构建成功；`lib/arm64-v8a/libocrshim.so` 存在且 16KB 对齐。

- [ ] **Step 6: 提交**

```bash
git add README.md tool/model/README.md
git commit -m "docs: add conversion, import, and device run instructions"
```

---

## 执行顺序说明

- Task 1 → 2 是硬门槛；Task 2 失败则停止，不进入 native/Flutter。
- Task 9 依赖 Task 11；执行时可先做 Task 11，再做 Task 9。
- Task 16 是 M1/M2 的真机验证；Task 17–18 是 M3/M4 验收。
- 每个任务结束都提交；不要等全部完成再一次性提交。
