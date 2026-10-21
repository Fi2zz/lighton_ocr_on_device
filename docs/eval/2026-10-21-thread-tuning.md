# 2026-10-21 线程数 / warmup / ubatch 调优

设备：SM6435、8GB、Android 16、arm64。
模型：`Q4KM-headQ4` 442MB + `mmproj` F16 195MB。
输入：`report-1-1280.ppm`（1200 image tokens），`max_tokens=64`。
全部为隔离 `ocr_cli` 数据；测试前已强制停止 App，并清理遗留 `ocr_cli` 进程。

## 线程数（warmup=true，n_ubatch=256）

| threads | encode | prefill | decode 64 tok | decode tok/s | 备注 |
|---|---:|---:|---:|---:|---|
| 3 | 20.37s | 10.95s | 4.02s | 15.9 | |
| **4** | **16.54s** | **8.49s** | **3.86s** | **16.6** | **默认** |
| 5 | 19.61s | 17.91s | 4.26s | 15.0 | 引入小核后变慢 |
| 6 | 17.60s | 13.24s | — | — | |
| 8 | 19.05s | 12.67s | 5.07–10.88s | 5.9–12.6 | 旧默认；抖动大 |

结论：4 个大核线程明显优于 8 线程；预填充约快 33%，解码约快 25–30%。

## CLIP warmup

| warmup | threads | encode | prefill | decode 64 tok |
|---|---:|---:|---:|---:|
| false | 4 | 17.84s | 9.76s | 3.99s |
| **true** | **4** | **16.54s** | **8.49s** | **3.86s** |

warmup 让 CLIP 在加载时选择 flash-attention 并预分配 compute buffer；加载时间变化不大，保留。

## mmproj 量化

| mmproj | threads | encode | prefill | decode 64 tok | RSS |
|---|---:|---:|---:|---:|---:|
| **F16** | 4 | **16.51s** | **8.38s** | **3.93s** | 1.52GB |
| Q8_0 | 4 | 19.53s | 8.62s | 3.93s | 1.42GB |

Q8 省约 100MB，但编码慢约 18%，不采用。

## n_ubatch

| n_ubatch | prefill | decode 64 tok | RSS |
|---:|---:|---:|---:|
| 256 | 8.49s | 3.86s | 1.50GB |
| 512 | 8.38s | 3.93s | 1.52GB |

差异在噪声范围内；保留 256 以降低内存峰值。

## 结论

- 默认 `nThreads=4`，旧 `config.json` 自动迁移。
- 保留 `warmup=true`。
- 保留 F16 mmproj 和 `n_ubatch=256`。
- 1280/Q4KM-headQ4 预计整页约 90s（encode 16.5s + prefill 8.5s + decode 约 62s）。

## 真机 UI 验证（1024px，4 threads）

2026-10-21 17:23，release APK，首张相册照片（768 image tokens）：

| 环节 | 耗时 |
|---|---:|
| 模型加载 | 2.2s |
| 图像预处理 | 762ms |
| 图像编码 | 9.8s |
| 预填充 | 6.6s |
| 生成 | 76.0s |
| 端到端 | 93.2s |
| 速度 | 12.30 tok/s |
| 峰值内存 | 1.70GB |

这是清理后台基准进程后的真实 UI 数据；此前“15 分钟/8 分钟”的观测受遗留 `ocr_cli` 抢占 7–8 核影响，已作废。
