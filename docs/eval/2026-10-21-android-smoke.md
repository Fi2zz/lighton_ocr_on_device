# Android FFI / OCR Smoke — 2026-10-21

## 设备与环境

- 设备：SM6435（8GB RAM），Android 16（API 36），arm64-v8a。
- Flutter 3.44.8 / Dart 3.12.2。
- 模型：`LightOnOCR-3-0.8B` Q4_K_M GGUF（505MB）+ mmproj F16（195MB）。
- 运行入口：`lib/main_ffi_smoke.dart`，OCR 在 `Isolate.run` 中执行，避免主线程 ANR。
- 图片：`samples/report-1.jpg`，长边 1280 / 2048。

## 结论

- `ocr_stats_size = 56`，Dart/C ABI 对齐正确。
- 模型可从应用私有目录加载，FFI 调用、token 回调、stats 均正常。
- **debug native 必须加 `-O3`**。Flutter debug 默认 `-O0` 时，300-token vision encode 超过 3 分钟；加 `-O3` 后同一张 640px 图 encode 2.7s。
- 1280px + Q4_K_M 是当前设备的可用默认：整页约 130s，峰值 RSS 约 2.1GB。
- 2048px + Q4_K_M 质量更好，但整页约 4 分钟；作为精度选项保留。
- 1280px 对中文正文和布局稳定，数学公式有局部误读；2048px 明显更好。

## 实测数据

### 1280px / Q4_K_M / 8 threads（整页）

| 指标 | 值 |
|---|---|
| 加载 | ~2s |
| 图片编码 | 16.7s |
| 图像 embedding 解码 | 11.7s |
| 文本生成 | 99.1s / 1134 tokens（约 11.4 tok/s） |
| 端到端 | 约 130s |
| 峰值 RSS | 2.1GB |
| prompt / image tokens | 1216 / 1200 |

### 2048px / Q4_K_M / 8 threads（512 token 抽样）

| 指标 | 值 |
|---|---|
| 图片编码 | 91.1s |
| 图像 embedding 解码 | 39.4s |
| 文本生成 | 51.5s / 512 tokens（约 9.9 tok/s） |
| 峰值 RSS | 2.3GB |
| prompt / image tokens | 3024 / 3008 |

按同速估算，2048px 整页约 240–300s。

### 640px / Q4_K_M / 8 threads（16 token 抽样）

| 指标 | 值 |
|---|---|
| 图片编码 | 2.7s |
| 文本生成 | 1.3s / 16 tokens |
| 峰值 RSS | 2.4GB |

640px 只用于验证 `-O3` 修复，不作为 OCR 默认。

## 输出片段（1280px）

```markdown
![header](409,75,592,100) 初中数学周测

![header](409,108,591,123) 考试时间：45分钟 满分：100分

![title](198,157,591,174) 一、选择题（每题4分，共32分）

![list](218,180,591,205)
1. 计算 $(-3)^{5}$ 的结果是（C）
...
```

中文正文、题号、选项基本正确；`(-3)+5`、`2x-3=7` 等公式在 1280px 下被误读，2048px 结果更准确。

## 已知问题

- `find_slot: non-consecutive token position` 警告来自 llama.cpp 的 M-RoPE/KV 位置检查；本样本输出正常，但需要持续观察长文档。
- 2048px 在 8GB 中端机上接近 4 分钟，不适合作为默认。
- Q8_0 质量更好但更慢；当前设备默认 Q4_K_M。
