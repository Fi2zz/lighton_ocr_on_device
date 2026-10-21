# LightOnOCR-3-0.8B 端侧 Flutter 适配设计

- 日期：2026-10-20
- 状态：已批准（2026-10-20）
- 范围：Android 优先的纯端侧单图 OCR Demo

## 1. 背景

本仓库需要把 `lightonai/LightOnOCR-3-0.8B` 适配到 Flutter，图片不离开设备。

已具备的材料：

- `light_on_ocr_0.8b/models/`：HF 原始权重（`model.safetensors` 约 1.6GB bf16）、tokenizer、预处理配置、chat template。
- `light_on_ocr_0.8b/LightOnOCR/`：官方客户端、CLI、grounding 解析与后处理参考实现。
- `samples/`：8 张真实中文试卷照片，用于质量与性能评估。
- `third_party/llama.cpp`：submodule，HEAD `3bb63cb`，已包含 `qwen35` 文本架构、`qwen3vl` 视觉投影和 `LLAMA_BUILD_MTMD` 构建开关。

环境：

- Flutter 3.44.8 / Dart 3.12.2。
- macOS 27 / Xcode 27，可编译 llama.cpp Apple 目标。
- Android 真机：SM6435、8GB RAM、Android 16（API 36）。
- 网络：PyPI 与 pub.dev 可访问，Hugging Face 不可访问；所有模型文件已在本地。

模型关键信息：

- 架构：`Qwen3_5ForConditionalGeneration`，24 层混合线性注意力 + 12 层视觉编码器。
- `tie_word_embeddings: true`，`attn_output_gate: true`，MRoPE。
- 视觉：`patch_size=16`、`spatial_merge_size=2`、`num_position_embeddings=2304`。
- 语言标签为 `en`，但论文标题与官方描述为多语言；中文效果必须实测。
- 许可证 Apache-2.0。

## 2. 目标与非目标

### 2.1 目标

1. 在 Android 真机上完全离线运行 LightOnOCR-3-0.8B，输入一张图片，输出 Markdown。
2. 模型以 GGUF 形式存放于应用私有目录，由用户通过系统文件选择器导入。
3. 显示可解释的运行状态：加载、图像编码、生成进度、耗时、tokens/s、内存。
4. 结果支持渲染/原文切换、复制、分享、重新识别。
5. 用 8 张 sample 给出真实的中文识别质量与真机性能记录。

### 2.2 非目标（第一版）

- iOS / macOS 桌面 App（仅保留 macOS CLI 验证）。
- PDF 多页、批量处理、历史记录。
- grounding 布局框叠加显示。
- 应用内模型下载。
- GPU/Vulkan 后端。
- 多模型管理、热切换。

## 3. 总体架构

```
Flutter UI
  HomePage / ResultPage / ModelSetupPage
        │
OcrService (ChangeNotifier, 状态机)
        │  SendPort / ReceivePort
OcrWorker (常驻后台 isolate)
        │  Dart FFI
libocrshim.so  (C ABI)
        │
libmtmd + libllama + ggml  (静态链接)
        │
GGUF: 主模型 + mmproj
```

设计原则：

- native 层只暴露少量 C ABI，Dart 不直接接触 mtmd 的 chunk/batch 生命周期。
- 模型只加载一次，常驻 worker isolate。
- 图片解码与预处理在 worker 内完成，UI isolate 不承担 CPU 重活。
- native 崩溃或 OOM 不拖垮 UI，错误可恢复。

## 4. 模型管线

### 4.1 转换环境

`tool/model/setup_env.sh`：

- 使用 `uv venv --python 3.12`。
- 安装 `torch`、`transformers>=5.5.4`、`safetensors`、`pillow`、`numpy`。
- 固定版本并生成 lock 文件；不依赖运行时联网。

### 4.2 转换与量化

`tool/model/convert.sh` 调用 `third_party/llama.cpp/convert_hf_to_gguf.py`：

```bash
python third_party/llama.cpp/convert_hf_to_gguf.py light_on_ocr_0.8b/models \
  --outtype bf16 \
  --outfile build-models/lightonocr3-0.8b-bf16.gguf

python third_party/llama.cpp/convert_hf_to_gguf.py light_on_ocr_0.8b/models \
  --mmproj \
  --outtype f16 \
  --outfile build-models/mmproj-lightonocr3-0.8b-f16.gguf
```

`tool/model/quantize.sh` 使用 `llama-quantize` 产出：

- `lightonocr3-0.8b-Q8_0.gguf`
- `lightonocr3-0.8b-Q4_K_M.gguf`

默认使用 Q4_K_M（8GB 中端机实测：1280px 整页约 130s）。Q8_0 作为质量选项保留；M4 根据实测结果按第 13 节的决策规则调整。

### 4.3 M0 冒烟验证

`tool/model/smoke-macos.sh`：

1. 用 CMake 编译 `llama-mtmd-cli`（Metal 开启）。
2. 对 `samples/report-1.jpg` 运行纯转录。
3. 保存原始输出到 `build/eval/report-1.md`。
4. 记录 load、image encode、prefill、decode 耗时与 tok/s。

通过标准：

- 两个 GGUF 均可加载，视觉塔无 tensor 缺失。
- 输出为非空 Markdown，至少能辨认试卷标题与题目内容。
- 无重复循环、无特殊 token 泄漏。

不通过时停止后续工作，先定位 llama.cpp 对 `qwen35` / `qwen3vl_merger` 的支持问题。

## 5. Native 核心

### 5.1 目录

```
native/ocr_shim/
  CMakeLists.txt
  include/ocr_shim.h
  src/ocr_shim.cpp
android/app/src/main/cpp/CMakeLists.txt
tool/ocr_cli/main.cpp
```

`tool/ocr_cli` 与 shim 使用同一份实现，用于 macOS 验证。

### 5.2 构建策略

- `BUILD_SHARED_LIBS=OFF`，`libllama`/`libmtmd`/`ggml` 静态链接进单个 `libocrshim.so`。
- `LLAMA_BUILD_TOOLS=OFF`、`LLAMA_BUILD_EXAMPLES=OFF`、`LLAMA_BUILD_TESTS=OFF`、`LLAMA_BUILD_SERVER=OFF`、`LLAMA_BUILD_MTMD=ON`。
- Android 第一版：`GGML_OPENMP=OFF`、`GGML_VULKAN=OFF`、`GGML_NATIVE=OFF`，只编 `arm64-v8a`。
- 导出符号仅保留 `ocr_*`；C++ 编译使用 `-fvisibility=hidden`。

### 5.3 C ABI

```c
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
```

约定：

- `mode` 只接受 `"plain"` 或 `"grounding"`；其他值返回 `E_MODE`。
- `ocr_create` 的进度回调用于报告模型加载进度，阶段名为 `"load"`。
- `ocr_run` 阻塞执行，只允许在 worker isolate 中调用；`seed` 默认 42，保证评测可复现。
- `ocr_cancel` 可从任意线程调用，内部使用 `std::atomic<bool>`；加载阶段不支持取消。
- 错误缓冲区写入 `E_XXX: message`，Dart 解析错误码。
- `ocr_stats_size()` 用于 Dart 启动时断言 `ffi.sizeOf<OcrStats>()` 与 C 一致。
- token 回调传入完整 UTF-8 片段；shim 内部缓冲不完整的多字节序列。

### 5.4 推理流程

0. 首次 `ocr_create` 时调用 `llama_backend_init()`；`ocr_destroy` 在最后一个引擎释放时调用 `llama_backend_free()`。
1. `mtmd_bitmap_init(width, height, rgb)`。
2. 组装 prompt，`mtmd_tokenize_from_parts` 生成 chunks。
3. `mtmd_helper_eval_chunks` 处理文本与图片 chunk，自动处理 M-RoPE 与 non-causal 注意力。
4. 采样链：`top_k` + `top_p(0.9)` + `temp(0.2)` + `dist`，默认 `top_k=20`，固定 `seed=42`。
5. 逐 token `llama_sampler_sample`，遇 EOG（`<|im_end|>`/`<|endoftext|>`）或达到 `max_tokens` 停止。
6. `llama_token_to_piece` 转 UTF-8，经边界缓冲后回调。
7. 统计各阶段耗时与峰值 RSS。
8. native 日志通过 `ggml_log_set` 转发到 Android logcat（tag `LightOnOCR`）；Dart 侧不依赖日志判断成败。

### 5.5 Prompt

必须精确复刻 `chat_template.jinja` 在 `enable_thinking=false` 时的输出：

```
<|im_start|>user\n<__media__>{prompt}<|im_end|>\n<|im_start|>assistant\n thinking\n\n response\n\n
```

- `plain`：`{prompt}` 为空字符串。**保留但非默认**：M0 实测该 checkpoint 在空 prompt 下会输出“图像描述”（`这张图片展示了…`），而不是完整转录。
- `grounding`：`{prompt}` 为 `grounding`。**第一版默认模式**：输出带 `![label](x1,y1,x2,y2)` 标记的完整 Markdown。渲染页去掉标记，原文页保留标记；不做布局框叠加。
- 不加 system prompt。
- `add_special=false`，Qwen 无 BOS。
- 不在两段之间插入额外换行；图片标记与文本直接相邻。

### 5.6 图片预处理与上下文参数

- Dart 侧将图片校正 EXIF 后缩放到长边 `longestEdge`，只缩不放。
- 默认 `longestEdge=1280`，可选 1024 / 1280 / 1536 / 2048。
- 默认：
  - `n_ctx=12288`
  - `n_batch=2048`
  - `n_ubatch=512`（移动端内存上限；由 native 固定为 `min(n_batch, 512)`）
  - `image_max_tokens=4096`
  - `n_threads=min(8, Platform.numberOfProcessors)`
- 若 mtmd 报 non-causal 且 `image_max_tokens > n_ubatch`，M4 调整 `image_max_tokens` 或 `n_ubatch`。
- 第一版 `use_gpu=false`。

## 6. Android 集成

`android/app/build.gradle.kts`：

- `minSdk = 26`
- `ndk.abiFilters += "arm64-v8a"`
- `externalNativeBuild.cmake.path = file("src/main/cpp/CMakeLists.txt")`
- `cmake.version = "3.22.1"`
- 链接参数 `-Wl,-z,max-page-size=16384`，适配 Android 16 的 16KB page；若所用 AGP/NDK 支持，同时开启 `ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES`，并在 M1 用 `readelf -l` 确认对齐。
- `AndroidManifest.xml` 设置 `android:extractNativeLibs="true"`，保证按 soname `dlopen`。
- `android/gradle.properties` 增加 `disable-abi-filtering=true`，避免 Flutter 插件重新加入 arm32/x86。
- `android/app/src/main/cpp/CMakeLists.txt` 在 `add_subdirectory` 前给 debug 追加 `-O3`：Flutter debug 默认 `-O0`，会让 llama.cpp 的 vision encode 慢 10–50 倍。
- 在 `native/ocr_shim/CMakeLists.txt` 的 `add_subdirectory` 前设置 `GGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16`；Android 需要显式开启 ARM 优化。
- `libocrshim.so` 额外链接 Android `log` 库（`__android_log_print`）。
- 相机权限由 `image_picker` 需要时声明；相册使用系统 Photo Picker，无需存储权限。

`android/app/src/main/cpp/CMakeLists.txt` 只做一件事：

```cmake
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../../../../native/ocr_shim ocr_shim)
```

## 7. Dart 层

### 7.1 目录

```
lib/
  main.dart
  app.dart
  src/
    ocr/ocr_types.dart
    ocr/ocr_ffi.dart
    ocr/ocr_worker.dart
    ocr/ocr_service.dart
    models/model_store.dart
    image/image_preprocess.dart
    ui/home_page.dart
    ui/result_page.dart
    ui/model_setup_page.dart
    ui/widgets/
```

### 7.2 FFI

- Android：`DynamicLibrary.open('libocrshim.so')`。
- 手写绑定，不引入 ffigen；函数数量少，便于审查。
- 字符串用 `package:ffi` 的 `malloc`/`Utf8`，调用后释放。
- `NativeCallable.isolateLocal` 注册 token/progress 回调。
- 启动时调用 `ocr_stats_size()`，与 `ffi.sizeOf<OcrStats>()` 比对失败则直接报错。

### 7.3 Worker isolate

常驻 isolate，协议：

| 消息 | 方向 | 内容 |
|---|---|---|
| `Load` | UI → worker | 主模型、mmproj、`OcrConfig` |
| `Run` | UI → worker | `TransferableTypedData` RGB、宽高、mode、maxTokens |
| `Cancel` | UI → worker | 取消当前任务 |
| `Dispose` | UI → worker | 释放 native 引擎并退出 |
| `Loading` | worker → UI | 加载进度 |
| `Progress` | worker → UI | stage + fraction |
| `Token` | worker → UI | 增量文本 |
| `Done` | worker → UI | `OcrResult`（文本 + stats） |
| `Failed` | worker → UI | 错误码 + 消息 |

规则：

- 同一时间只允许一个 `Run`；`OcrService` 在 UI 侧做互斥。
- worker 的 `onError`/`onExit` 转为 `E_WORKER_CRASH`，允许重建 worker。
- 加载失败不保留半初始化引擎。

### 7.4 状态机

`OcrService` 状态：

```
unconfigured → loading → ready → running → ready
                    ↘ failed ↗        ↘ cancelling → ready
```

- `unconfigured`：缺少模型文件或校验失败。
- `loading`：native 加载中，显示加载进度；该阶段不支持取消，完成后进入 `ready` 或 `failed`。
- `ready`：可运行。
- `running`：展示阶段与增量文本，可取消。
- `failed`：保留错误码与详情，可重试。

### 7.5 图片预处理

worker 内使用 `package:image`：

1. `decodeImage`
2. `bakeOrientation`（EXIF）
3. `copyResize`：长边缩放到目标值，保持比例，不放大
4. `getBytes(order: ChannelOrder.rgb)`

结果以 `TransferableTypedData` 发送，避免跨 isolate 复制。

若 `package:image` 无法解码输入格式（例如 HEIC），回退到 Flutter 引擎的 `instantiateImageCodec` 在 UI isolate 解码，再交给 worker；回退路径只处理少见的格式，正常 JPEG/PNG 不走该分支。

### 7.6 模型管理

- 目录：`<ApplicationSupportDirectory>/models/`。
- 配置：`models/config.json`，字段：
  - `mainModel`
  - `mmproj`
  - `longestEdge`
  - `maxTokens`
  - `nThreads`
  - `seed`（默认 42）
- 导入流程：
  1. `file_picker` 选择文件。
  2. 读取前 4MB 做校验。
  3. 流式拷贝，1MB 分块，回调进度。
  4. 成功后原子替换配置；失败删除半成品并保留旧配置。
- 校验：
  - 文件头为 `GGUF`。
  - 主模型包含 `qwen35` 或 `general.architecture` 字样。
  - mmproj 包含 `clip.` 或 `qwen3vl` 字样。
  - 主模型 ≥ 300MB，mmproj ≥ 50MB。
- 提供删除模型、释放内存。

### 7.7 UI

**首页**

- 模型状态卡片：未配置 / 已就绪（显示总大小）/ 加载中 / 错误。
- 图片预览；空状态提供“拍照”“相册”。
- 参数：长边 1536/2048/2560；最大输出 token 2048/4096/8192。
- 主按钮：未配置时“配置模型”，就绪时“开始识别”，运行中“取消”。
- 运行中显示阶段进度、已生成字数、保持屏幕常亮。

**结果页**

- Tab：渲染 / 原文。
- 渲染：用 `groundingToMarkdown` 去掉 `![label](x1,y1,x2,y2)` 标记，再交给 `flutter_markdown`。
- 原文：保留模型原始输出，包括坐标标记。
- 操作：复制、分享（默认分享渲染后的 Markdown）、重新识别、换一张。
- 可展开耗时详情：load / encode / prefill / decode / total / tok/s / image tokens / peak RSS。
- 错误时显示中文说明与“查看详情”。

**模型页**

- 两个文件槽位，分别显示文件名、大小、校验状态。
- 导入按钮与进度。
- 转换脚本提示（指向 `tool/model/`）。
- “加载模型”“删除模型”“释放内存”。

界面语言为中文，Material 3，文档工具风格，不做装饰性动效。

### 7.8 新增依赖

- `file_picker`：模型文件导入。
- `image`：解码、EXIF、缩放。
- `ffi`：native 内存与字符串。
- `path`：路径拼接。

已有依赖继续使用：`image_picker`、`path_provider`、`share_plus`、`flutter_markdown`、`wakelock_plus`。

## 8. 错误处理

错误码与用户提示：

| 错误码 | 含义 | 用户提示 |
|---|---|---|
| `E_MODEL_MISSING` | 模型文件不存在 | 请先导入主模型和 mmproj |
| `E_GGUF_INVALID` | 文件头或关键字段不符 | 文件不是有效的 GGUF，或类型选错 |
| `E_LOAD` | native 加载失败 | 模型加载失败，查看详情 |
| `E_OOM` | 内存不足 | 尝试降低图片长边或使用更小量化 |
| `E_ENCODE` | 图像编码失败 | 图片编码失败，换一张图片 |
| `E_DECODE` | 生成失败 | 推理失败，查看详情 |
| `E_MODE` | mode 参数非法 | 内部错误：未知的识别模式 |
| `E_CANCELLED` | 用户取消 | 已取消 |
| `E_WORKER_CRASH` | worker/native 崩溃 | 推理进程退出，可重试 |
| `E_BUSY` | 重复提交 | 正在识别，请稍候 |

native 层不得直接打印后静默返回；所有失败都写入错误缓冲区。

## 9. 测试与验收

### 9.1 单元测试

- Prompt 字节序列精确匹配，覆盖空 prompt 与 `grounding`。
- Grounding 解析：`![label](x1,y1,x2,y2)` 分块、`label+` 续块、无标记文本原样返回、渲染 Markdown 去掉标记。
- UTF-8 分片缓冲：多字节字符跨 token 不产生乱码。
- GGUF 头校验与主模型/mmproj 类型探测。
- 图片缩放：横图、竖图、正方形；只缩不放；EXIF 方向。
- `OcrService` 状态机：未配置 → 加载 → 运行 → 取消/失败 → 重试。
- 配置文件读写与损坏恢复。

### 9.2 Native 验证

- macOS `tool/ocr_cli` 对 8 张 sample 全跑。
- 输出保存到 `build/eval/`，包含文本、stats、峰值内存。
- 至少验证一次错误模型路径与一次取消。

### 9.3 真机验证

- `flutter analyze` 无 error。
- `flutter test` 全部通过。
- `flutter build apk --debug`，`adb install`。
- 导入两个 GGUF，逐张识别 8 张 sample。
- `adb logcat` 过滤 native 日志；`dumpsys meminfo` 记录峰值。
- 验证错误路径：未配置、选错文件、取消、后台切换。

### 9.4 验收指标

以 `samples/report-1.jpg`、1280px、Q4_K_M、8 threads 为默认基准：

| 指标 | 目标 | 可接受 |
|---|---|---|
| 端到端耗时 | ≤ 150s | ≤ 210s |
| 解码速度 | ≥ 10 tok/s | ≥ 6 tok/s |
| 峰值 native 内存 | ≤ 2.5GB | ≤ 3.0GB |
| 输出质量 | 标题/题干可辨认，无循环 | 主要段落可读，允许局部错字 |

2048px 精度模式另算：目标 ≤300s，可接受 ≤360s。若默认配置达不到“可接受”，按下面的顺序降级，并以最终采用的配置记录实测值。

指标不达标时的调整顺序：

1. 降到 1536px。
2. 降 `image_max_tokens`。
3. 降 `max_tokens`。
4. 换 Q4_K_M。
5. 仍不达标则如实记录，不把 Demo 宣传为可用产品。

## 10. 里程碑

| 阶段 | 内容 | 完成标准 |
|---|---|---|
| M0 | 转 GGUF、macOS 冒烟 | sample-1 输出可读 Markdown，记录基线 |
| M1 | Android native + FFI 冒烟 | 真机加载模型并跑通一张图 |
| M2 | Dart worker、模型导入、图片管线 | 非 UI 环境完成全链路 |
| M3 | Flutter 首页/结果页/模型页 | 真机完整走通，含错误与取消 |
| M4 | 8 张 sample 调优 | 给出默认参数与性能/质量记录 |

M0 是硬门槛；失败即停止并汇报。

## 11. 风险

| 风险 | 影响 | 应对 |
|---|---|---|
| llama.cpp 不支持该 checkpoint | 方案不可行 | M0 立即验证；失败则停止，给出证据 |
| 转换依赖冲突 | 无法产出 GGUF | `uv` 固定 Python 3.12 与 lock；只用本地权重 |
| 中文识别质量差 | Demo 不可用 | M0 用中文 sample 验证；如实记录，后续评估 4B 或其他模型 |
| 中端机性能不足 | 体验不可接受 | 按 9.4 顺序降参数量化；如实给出耗时 |
| Android 16 16KB page | `.so` 无法加载 | 链接参数 + flexible page sizes，M1 真机验证 |
| native 崩溃/OOM | App 崩溃 | worker 隔离、错误码、可重建；限制图片与上下文 |
| HTML 表格渲染差 | 结果页显示异常 | 保留“原文”tab；表格渲染后续再做 |

## 12. 交付物

- `tool/model/`：环境、转换、量化、冒烟脚本。
- `native/ocr_shim/`：C ABI 与实现。
- `android/app/src/main/cpp/CMakeLists.txt`：Gradle/CMake 集成。
- `tool/ocr_cli/`：macOS 验证 CLI。
- Flutter App：模型导入、单图识别、结果展示、复制/分享、统计。
- `test/`：单元测试。
- README：转换、导入、真机运行、已知限制。
- M4 实测记录：8 张 sample 的耗时、内存、质量说明。

## 13. 决策规则

以下参数不预先拍死，由 M4 数据决定：

- 量化档位：8GB 中端机默认 Q4_K_M；Q8_0 作为质量选项。若 Q8 在 1280px 下仍满足 9.4 可接受阈值，可在高端设备上切回 Q8。
- 默认 OCR 模式：`grounding`。空 prompt（`plain`）在该 checkpoint 上会退化为图像描述，不作为默认。
- 默认 `longestEdge`：1280（约 130s/页）；2048 作为精度模式（约 4–5 分钟/页）。
- 默认线程数：8（当前 SM6435 实测最优）；其他设备以实测为准。
- 默认 `maxTokens`：覆盖 sample 最长输出并留 20% 余量。

## 14. 变更记录

- 2026-10-20：初稿，基于三块设计确认结果。
- 2026-10-20：评审通过，进入实现计划阶段。
- 2026-10-20：M0 实测发现空 prompt 退化为图像描述；第一版默认改为 `grounding`，渲染时去掉坐标标记，不做布局框叠加。
- 2026-10-21：真机 smoke 发现 Flutter debug native `-O0` 导致 vision encode 数分钟；改为 debug 也加 `-O3`。1280px/Q4 整页约 130s，默认长边改为 1280，默认量化改为 Q4_K_M。
