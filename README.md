# LightOnOCR on-device Flutter

LightOnOCR-3-0.8B 的 Android 端侧 OCR Demo。图片不离开设备，使用 llama.cpp + libmtmd 在本地推理，Flutter 负责选图、模型导入和结果展示。

## 当前能力

- 单张图片 → Markdown OCR，默认 `grounding` 模式。
- 结果页支持渲染/原文切换、复制、分享、耗时与内存统计。
- 模型以 GGUF 形式保存在应用私有目录，由用户通过系统文件选择器导入。
- 推理运行在常驻 worker isolate，主线程不阻塞；支持取消。
- 无网络请求，无模型下载。

## 环境

- Flutter 3.44.8 / Dart 3.12.2。
- Android NDK 28.2、CMake 3.22.1。
- Android 真机：SM6435 / 8GB / Android 16（当前实测设备）。
- llama.cpp 作为 `third_party/llama.cpp` submodule。

## 1. 准备模型

```bash
bash tool/model/setup_env.sh
bash tool/model/convert.sh
```

先构建 `llama-mtmd-cli` / `llama-quantize`（见 `tool/model/README.md`），然后：

```bash
bash tool/model/quantize.sh
```

产物在 `build-models/`：

- `lightonocr3-0.8b-Q4_K_M.gguf`（当前设备默认，约 505MB）
- `lightonocr3-0.8b-Q8_0.gguf`（质量档，约 774MB）
- `mmproj-lightonocr3-0.8b-f16.gguf`（约 195MB）

模型和量化产物不会进入 git。

## 2. 构建与安装

```bash
flutter pub get
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

只支持 `arm64-v8a`。Android debug native 已强制 `-O3`；Android 使用 `armv8.2-a+dotprod+fp16` 并做了 16KB page 对齐。

## 3. 导入模型

方式 A（推荐给普通用户）：

1. 把主模型和 mmproj 放到手机 `Download/`。
2. 打开 App → 右上角设置 → 分别导入“主模型”和“mmproj”。
3. 两个槽位都显示“已导入”后，点“加载模型”。

方式 B（开发/自动化）：

```bash
PKG=com.example.lighton_ocr_on_device
adb push build-models/lightonocr3-0.8b-Q4_K_M.gguf /data/local/tmp/main.gguf
adb push build-models/mmproj-lightonocr3-0.8b-f16.gguf /data/local/tmp/mmproj.gguf
adb shell run-as $PKG mkdir -p files/models
adb shell run-as $PKG cp /data/local/tmp/main.gguf files/models/lightonocr3-0.8b.gguf
adb shell run-as $PKG cp /data/local/tmp/mmproj.gguf files/models/mmproj-lightonocr3-0.8b.gguf
```

App 启动后模型卡片应显示“已就绪”。

## 4. 使用

1. 相册/拍照选图。
2. 选择长边（默认 1280）和最大输出（默认 4096）。
3. 点“开始识别”；可取消。
4. 结果页查看渲染 Markdown 或原始输出，复制/分享。

## 实测性能（SM6435 / 8GB / Android 16）

| 配置 | 整页耗时 | 解码速度 | 峰值 RSS |
|---|---|---|---|
| 1280px + Q4_K_M + 8 threads | 约 130s | 11.4 tok/s | 2.1GB |
| 2048px + Q4_K_M | 约 4–5 分钟 | 9.9 tok/s（抽样） | 2.3GB |
| 1280px + Q8_0 | 约 4 分钟以上 | 4.1 tok/s（抽样） | 2.6GB |

详细数据：

- `docs/eval/2026-10-21-android-smoke.md`
- `docs/eval/2026-10-21-device-bench.md`
- `docs/eval/2026-10-21-device-acceptance.md`

## 已知限制

- 1280px 对中文正文稳定，但数学公式/极小字号会误读；公式多的页面请切 2048px。
- 2048px 在当前 8GB 中端机上约 4–5 分钟/页。
- 第一版只做单图，不做 PDF 多页、批量、历史记录。
- grounding 坐标只在“原文”中保留，不做布局框叠加。
- `flutter_markdown` 对 HTML 表格支持有限；表格内容以原文 tab 为准。
- 低内存设备可能被系统回收；模型越大越明显。native OOM 有时会直接杀进程，App 只能处理 native 返回的 `E_OOM`。
- 第一版只支持 JPEG/PNG；HEIC 会提示 `E_ENCODE`，请先转成 JPEG。

## 架构

```
Flutter UI (HomePage / ResultPage / ModelSetupPage)
        │ OcrService (ChangeNotifier 状态机)
        │ IsolateOcrWorker（常驻 worker isolate）
        │ Dart FFI
libocrshim.so (C ABI)
        │
libmtmd + libllama + ggml
        │
Q4_K_M / Q8_0 GGUF + mmproj
```

- `native/ocr_shim/`：C ABI、prompt、mtmd 推理循环、统计。
- `lib/src/ocr/`：类型、FFI、worker、service、grounding 解析。
- `lib/src/models/`：GGUF 探测、模型仓库、文件选择。
- `lib/src/ui/`：首页、结果页、模型配置页。

## 开发验证

```bash
flutter analyze
flutter test
bash tool/model/smoke_macos.sh          # llama-mtmd-cli，M0
dart run tool/ffi_smoke.dart --run      # macOS FFI
```

真机 FFI smoke：

```bash
flutter run -t lib/main_ffi_smoke.dart -d <android-device>
```

## 许可

模型与上游代码遵循各自许可证；本仓库代码见 `LICENSE`。
