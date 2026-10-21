# 真机参数矩阵 — 2026-10-21

## 结论

当前设备（SM6435 / 8GB / Android 16）选择：

| 参数 | 默认 |
|---|---|
| 量化 | Q4_K_M + Q4_0 output/token embeddings (`Q4KM-headQ4`) |
| 长边 | 1280 |
| 线程 | 8 |
| 最大输出 | 4096 |
| 模式 | grounding |

2048px + Q4_K_M 作为“精度模式”，适合公式/小字多的页面，代价是 4–5 分钟/页。

## 已测组合

### 1280 / Q4KM-headQ4 / 8 threads（整页）

- encode 16.5s；image embedding decode 12.7s；文本 86.4s / 1032 tokens。
- 端到端约 115s；约 11.9 tok/s；峰值 RSS 1.93GB。
- 比标准 Q4_K_M 快约 20%，内存少约 100MB；body 仍是 Q4_K_M。

### 1280 / Q4_K_M / 8 threads（整页）

- encode 16.7s；image embedding decode 11.7s；文本 99.1s / 1134 tokens。
- 端到端约 130s；11.4 tok/s；峰值 RSS 2.1GB。
- 中文正文、题号、选项稳定；部分数学公式误读（如 `(-3)+5` → `(-3)^{5}`）。

### 2048 / Q4_K_M / 8 threads（512 token 抽样）

- encode 91.1s；image embedding decode 39.4s；文本 51.5s / 512 tokens。
- 9.9 tok/s；峰值 RSS 2.3GB。
- 按同速估算整页 240–300s；公式准确度明显优于 1280。

### 1280 / Q8_0 / 8 threads（32 token 抽样）

- encode 17.5s；文本 7.7s / 32 tokens（约 4.1 tok/s）；峰值 RSS 2.6GB。
- Q8 的 decode 明显慢于 Q4；整页预计 4 分钟以上，不作为默认。

### 640 / Q4_K_M / 8 threads（16 token 抽样）

- encode 2.7s；文本 1.3s / 16 tokens；峰值 RSS 2.4GB。
- 只用于验证 debug `-O0` 修复，不作为 OCR 质量档。

## 构建参数影响

- Flutter debug native 默认 `-O0`：300-token vision encode 超过 3 分钟。
- 给 debug 加 `-O3` 后，同一 640px 输入 encode 2.7s。
- Android 显式设置 `GGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16`。

## 质量说明

1280px 适合正文型文档；数学公式、极小字号建议切 2048px。640px 不适合正式 OCR。
