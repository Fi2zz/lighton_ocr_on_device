# LightOnOCR 端侧性能优化结论

日期：2026-10-21  
设备：SM6435 / 8GB / Android 16 / arm64  
分支：`feature/lightonocr-flutter`  
模型：`Q4KM-headQ4`（442MB）+ `mmproj` F16（195MB）

## 1. 结论摘要

1. **之前 UI“8–15 分钟”的主要原因是环境干扰，不是模型本身。** 后台遗留了多个 `ocr_cli` 基准进程，长期占用 3–8 个 CPU 核；同时旧 UI 会在每个 token 时重建整页。清理进程并拆分 UI 重建范围后，真机可恢复到分钟级。
2. **线程数从 8 改为 4 是本轮最有效的无损优化。** SM6435 是 4 个大核 + 4 个小核，8 线程会引入小核和额外同步开销。4 线程下预填充约快 33%，解码约快 25–30%，编码约快 13%。
3. **CLIP warmup（flash attention）保留。** 加载时多花少量时间，但编码路径更稳定，实测 4 线程编码约快 8%。
4. **Q8 mmproj 和更大的 `n_ubatch` 都不划算。** Q8 编码慢约 18%，只省约 100MB；`n_ubatch=512` 对预填充仅快约 1%，却增加内存峰值。
5. **Vulkan GPU 暂不可用。** 这台 Adreno 驱动能初始化 Vulkan，但 llama.cpp 的 shader 在链接阶段失败（`Failed to link shaders`），文本和视觉后端都一样。
6. **当前 1024px/4 线程真机 UI 实测 93.2s/页。** 1280px 预计约 105–110s/页；CPU 调参已接近边界，进一步提速需要降低分辨率或改用 GPU/NPU/服务端。

## 2. 最终默认配置

| 参数 | 值 | 说明 |
|---|---|---|
| 量化 | `Q4KM-headQ4` | body Q4_K_M，output/token embedding Q4_0 |
| mmproj | F16 | Q8 编码更慢 |
| 长边 | 1280（UI 可切） | 1024 更快，2048 更准 |
| 最大输出 | 2048 | |
| 线程 | **4** | 旧配置会自动迁移 |
| `n_ctx` | 8192 | |
| `n_batch` | 2048 | |
| `n_ubatch` | 256 | 512 收益在噪声内 |
| 模式 | grounding | 结果页渲染时去掉坐标标记 |

旧 `config.json` 没有 `version` 字段时，`OcrConfig.fromJson` 会把线程迁移为 4，不需要用户手动清配置。

## 3. 真机实测

### 3.1 1024px / 4 线程 / UI

release APK，首张相册照片（768 image tokens）：

| 环节 | 耗时 |
|---|---:|
| 模型加载 | 2.2s |
| 图像预处理 | 762ms |
| 图像编码 | 9.8s |
| 预填充 | 6.6s |
| 生成 | 76.0s |
| 端到端 | **93.2s** |
| 速度 | 12.30 tok/s |
| 峰值内存 | 1.70GB |

### 3.2 线程数对比

1280px、Q4KM-headQ4、`max_tokens=64`，隔离 CLI：

| 线程 | 编码 | 预填充 | 生成 64 token | 解码速度 |
|---|---:|---:|---:|---:|
| 3 | 20.37s | 10.95s | 4.02s | 15.9 tok/s |
| **4** | **16.54s** | **8.49s** | **3.86s** | **16.6 tok/s** |
| 5 | 19.61s | 17.91s | 4.26s | 15.0 tok/s |
| 6 | 17.60s | 13.24s | — | — |
| 8 | 19.05s | 12.67s | 5.07–10.88s | 5.9–12.6 tok/s |

结论：**4 线程全面优于 8 线程**。5 线程开始引入小核，预填充明显退化。

### 3.3 CLIP warmup

| warmup | 编码 | 预填充 | 生成 64 token |
|---|---:|---:|---:|
| false | 17.84s | 9.76s | 3.99s |
| **true** | **16.54s** | **8.49s** | **3.86s** |

warmup 让 CLIP 在加载时选择 flash attention 并预分配 compute buffer；保留。

### 3.4 mmproj 量化

| mmproj | 编码 | 预填充 | 解码 64 token | RSS |
|---|---:|---:|---:|---:|
| **F16** | **16.51s** | **8.38s** | **3.93s** | 1.52GB |
| Q8_0 | 19.53s | 8.62s | 3.93s | 1.42GB |

Q8 省约 100MB，但编码慢约 18%，不采用。

## 4. 分辨率与准确度

| 长边 | 相对耗时 | 适用场景 |
|---|---|---|
| 768 | 约 0.5× | 只求快速预览，正文/小字下降 |
| 1024 | 约 0.7× | 速度优先；公式和极小字号一般 |
| **1280** | **1×（约 105–110s）** | **速度/准确度平衡，推荐** |
| 2048 | 约 2.5×（约 2.5–3 分钟） | 公式、密集小字、表格 |

生成阶段占总耗时约 80%，所以 1024→1280 只多约 10–15 秒，但准确度提升更明显。若目标是“既要速度又要准确度”，建议默认 **1280**。

## 5. 为什么没有继续做 CPU 微调

- 图像编码由 CLIP 视觉塔主导，主要随图像像素/patches 增长；CPU 上已经用 4 大核线程。
- 预填充由图像 token 数主导，且该模型含 recurrent 层，无法像纯 Transformer 那样完全并行。
- 解码受内存带宽限制，4 线程已是最佳；进一步依赖量化或 GPU。
- `n_ubatch`、线程数的收益已经测到边界；再调只是噪声。

## 6. 不可用/未采用的方案

| 方案 | 结果 |
|---|---|
| Vulkan GPU | 初始化成功，`Failed to link shaders`，不可用 |
| Q8 mmproj | 编码更慢 |
| `n_ubatch=512` | 预填充仅快约 1%，内存更高 |
| 8 线程 | 明显慢于 4 线程 |
| Q4_0 全模型 | 未采用；headQ4 已是更好的速度/质量折中 |

## 7. 复现方式

```bash
# 构建 release
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk

# 清理后台干扰后再测
adb shell am force-stop com.example.lighton_ocr_on_device
adb shell 'ps -A -o PID,NAME,ARGS | grep ocr_cli | grep -v grep'

# 隔离 CLI 基准（4 线程）
adb shell 'cd /data/local/tmp/locr && \
  LD_LIBRARY_PATH=. ./ocr_cli \
  --model models/main.gguf \
  --mmproj models/mmproj-f16.gguf \
  --image report-1-1280.ppm \
  --mode grounding --max-tokens 64 \
  --threads 4 --ctx 8192 --batch 2048'
```

## 8. 测量注意事项

- 测量前必须 **force-stop App**，并确认没有遗留的 `ocr_cli`/基准脚本；否则 CPU 被抢占，耗时会失真数倍。
- 本结论中的 1024px UI 数据为 release 包实测；1280px 全页为 CLI 编码/预填充数据 + UI 解码速度的估算。
- 设备内存接近满时，系统 swap 会显著拖慢解码。测试前建议重启，至少清理后台。
- 温度、后台应用、相册图片尺寸都会影响结果，建议同一张图、同一配置对比。

## 9. 后续建议

1. 默认 1280px + 4 线程；需要快速预览时切 1024px。
2. 公式/小字页面切 2048px，接受约 2.5–3 分钟。
3. 若要接近实时，优先考虑 GPU/NPU 或服务端；当前 Adreno Vulkan 路径不通。
4. 可选的下一步：增加“快速 768 / 标准 1280 / 精确 2048”预设，并把预计耗时直接显示在按钮旁。

## 10. 相关提交与文档

- `c7af05e` perf: reduce memory, batch UI updates, and add head-Q4 model
- `03abf89` feat(ui): show live OCR stage timings and partial result
- `b59aac5` perf: use four big-core threads and warm up CLIP
- `docs/eval/2026-10-21-thread-tuning.md`
- `docs/eval/2026-10-21-device-bench.md`
- `docs/eval/2026-10-21-device-acceptance.md`
