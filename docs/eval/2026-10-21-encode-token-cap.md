# 图像编码与 token 上限实测结论 — 2026-10-21

设备：SM6435 / 8GB / Android 16 / arm64（4×Cortex-A78 @2.4GHz + 4×Cortex-A55 @1.8GHz）  
模型：`Q4KM-headQ4`（442MB）+ `mmproj` F16（195MB）  
输入：`samples/report-1.jpg`，长边 1280 / 2048 转 PPM  
工具：`tool/ocr_cli` 交叉编译为 arm64，直接调用与 App 相同的 `libocrshim.so`

> 本文补充 `2026-10-21-thread-tuning.md` 和 `2026-10-21-optimization-conclusion.md` 未覆盖的部分：图像编码的成本结构、1280 整页、2048 token cap 矩阵，以及质量观察。
> 代码状态：`b59aac5` 已把默认线程改为 4，并开启 CLIP warmup；本文数据用于验证和补充。

## 1. 结论摘要

1. **编码耗时随 image tokens 超线性增长。** 1280→2048，image tokens 从 1200 涨到 3008（2.5×），encode 从约 22s 涨到约 107s（约 5×）。用两组数据拟合 `T ≈ aN + bN²`，1280 下注意力约占编码的 78%，2048 下约占 90%。所以量化视觉塔只能影响剩下的一小部分，真正的大头是分辨率/token 数和注意力本身。
2. **4 线程相对 8 线程：encode 基本持平，prefill 快 20–25%，decode 快约 50%。** 1280 整页单次对比：8 线程 144.3s，4 线程 95.6s（-34%）。这与 `thread-tuning.md` 的结论一致，且说明收益主要来自生成阶段，不是编码。
3. **2048 模式下 cap 到 2560 tokens 是较稳的折中**：image tokens 3008→2494，encode 106.5→76.0s（-29%），prefill 38.8→33.6s（-13%），有效长边约 1865px。
4. **cap 到 2048 tokens 更快**：encode 51.6s（-52%），整页 211.4→138.8s（-34%），但公式质量有回归风险（见第 5 节），不建议直接设为默认。
5. **Q8 mmproj 在这台 SoC 上更慢**：1280 encode 约 27s vs F16 的 22s（+22%），只省约 100MB RSS。原因是没有 `i8mm`，F16 FMLA 路径更划算。只适合内存吃紧时用。
6. **1280 下 cap 到 1024 tokens 不值得**：只省约 5s encode，而且 999 tokens 已低于 clip 对 grounding 建议的 1024-token 下限。
7. **质量对比目前没有定论。** 源图公式区域太模糊，且 shim 把 `temperature=0` 强转为 0.2，输出带采样随机性；线程数和 cap 造成的差异无法与采样噪声区分。需要清晰样张 + 真 greedy 才能做严格评估。

## 2. 测试环境与数据可信度

- CLI 运行在 Android `system` cgroup，App 运行在 `top-app`；因此 CLI 的绝对值比历史 App 文档慢约 25–30%，本文只做同轮内相对比较。
- 第一次测量时 `com.example.lighton_ocr_on_device` 在后台占用约 400% CPU（累计 70 分钟 CPU 时间），encode 被拖到 141s；该组数据已丢弃。
- 2048 全量 + 8 线程的最后一次长跑期间，另一个 `ocr_cli`（351% CPU）和 App（383% CPU）同时运行，decode 仅 4.7 tok/s；**该次耗时不计入结论**，只保留其输出文本用于质量对比。
- 测量期间 Thermal Status 为 0，CPU 约 50–55°C，未观察到明确热节流；但长时间连续跑分仍有明显方差。
- 与 App 的交叉验证：App 8 线程、768 tokens 时 11.22 tok/s；CLI 8 线程、1280 全页 11.4 tok/s，量级一致。

## 3. 图像编码成本结构

| 输入 | image tokens | 有效长边 | encode（8 线程） | encode（4 线程） |
|---|---:|---:|---:|---:|
| 1280px | 1200 | 1280 | 22.1s | 23.2s |
| 1280px + cap 1024 | 999 | ≈1168px | 16.8–17.5s | — |
| 2048px + cap 2560 | 2494 | ≈1865px | 76.0s | — |
| 2048px + cap 2048 | 1976 | ≈1660px | 51.6s | 55.8s |
| 2048px 全量 | 3008 | 2048px | 106.5s | 117.1s |

拟合（N = merge 前 patch 数，N = 4 × image tokens）：

- 1280：线性部分约 3.7s，二次部分约 13s → 注意力约 78%
- 2048：线性部分约 9s，二次部分约 82s → 注意力约 90%

这只是两点拟合，且包含 cache/带宽效应，不是精确分解；但足以解释为什么 Q8 视觉塔收益有限（只作用于线性层/MLP）。

## 4. 1280 线程与整页

短跑（8 token，3 轮中位数）：

| 线程 | encode | prefill | decode 8 tok |
|---|---:|---:|---:|
| 8 | 22.1s | 14.7s | 0.55s |
| 6 | 33.6s | 17.3s | 0.53s |
| 4 | 23.2s | 11.6s | 0.36s |

长跑（128 token，2 轮）：

| 线程 | encode | prefill | decode | 速度 |
|---|---:|---:|---:|---:|
| 8 | 19.3–21.9s | 14.2–14.7s | 10.2–10.6s | 12.1–12.6 tok/s |
| 4 | 23.2s | 11.6s | 6.80s | **18.8 tok/s** |

整页（`max_tokens=2048`，单次）：

| 线程 | 输出 | encode | prefill | decode | 总计 | 速度 |
|---|---:|---:|---:|---:|---:|---:|
| 8 | 1224 tok | 19.4s | 17.4s | 107.6s | 144.3s | 11.4 tok/s |
| 4 | 1148 tok | 18.2s | 10.0s | 67.4s | **95.6s** | 17.0 tok/s |

结论：

- **6 线程最差**，会引入小核且工作分配不均，不要用。
- **4 线程是 prefill/decode 的最优档**；encode 与 8 线程在噪声范围内（有时略慢，有时略快）。
- 整页收益约 -34%，与 `thread-tuning.md` 的“prefill 快约 33%、decode 快 25–30%”方向一致。

> `thread-tuning.md` 记录 4 线程 encode 比 8 线程快约 13%；本文短跑中 4 线程略慢、整页略快，方向不一致。结合多轮方差，本文把 encode 的线程差异视为噪声，线程收益主要记在 prefill/decode 上。

## 5. 2048 token cap

短跑（128 token）：

| 配置 | image tokens | encode | prefill | decode | 速度 | RSS |
|---|---:|---:|---:|---:|---:|---:|
| t8 cap 4096 | 3008 | 106.5s | 38.8s | 12.45s | 10.3 tok/s | 1.75GB |
| t8 cap 2560 | 2494 | 76.0s | 33.6s | 12.24s | 10.5 tok/s | 1.69GB |
| t8 cap 2048 | 1976 | 51.6s | 24.6s | 11.16s | 11.5 tok/s | 1.63GB |
| t4 cap 4096 | 3008 | 117.1s | 32.3s | 8.07s | 15.9 tok/s | 1.75GB |
| t4 cap 2048 | 1976 | 55.8s | 20.7s | 7.32s | **17.5 tok/s** | 1.63GB |

整页（4 线程）：

| 配置 | 输出 | encode | prefill | decode | 总计 |
|---|---:|---:|---:|---:|---:|
| cap 4096（全量） | 928 tok | 118.4s | 32.2s | 60.8s | 211.4s |
| cap 2048 | 1006 tok | 57.2s | 20.0s | 61.6s | **138.8s** |

- cap 2048 的整页收益约 -34%，主要来自 encode 减半。
- cap 2560 的 encode 收益约 -29%，对公式/小字更保守，适合作为“精度档”的默认。
- 注意：`image_max_tokens` 是按面积降分辨率。cap 2048 对应有效长边约 1660px，不是 2048×1660/3008 的线性比例。

## 6. 质量观察（未形成定论）

对比文件（本地 `build/eval/`）：

- `ocr-2048-full.md`：4 线程，cap 4096
- `ocr-2048-cap2048.md`：4 线程，cap 2048
- `ocr-2048-full-t8.md`：8 线程，cap 4096
- `ocr-1280-t8.md` / `ocr-1280-t4.md`：1280 整页

2048 全量 vs cap 2048（同为 4 线程）：

- 题目文字基本一致；cap 版排版更好（LaTeX、下划线更规范）。
- 第 1 题 A 选项：全量 `-4`，cap 版 `-8`。
- 第 3 题：全量 `2^x·2^x`，cap 版 `2^x·2^1`。

8 线程 vs 4 线程（2048 全量）：

- 8 线程多识别出“姓名/用时/得分”抬头；4 线程漏掉这一行。
- 第 3 题：8 线程 `2^x·2^7`，4 线程 `2^x·2^x`。
- 标点风格不同（8 线程偏 ASCII，4 线程偏中文标点）。

为什么不能据此判定质量回归：

1. 源图第 3 题的指数区域本身很模糊，无法可靠确定 ground truth。
2. `native/ocr_shim/src/ocr_shim.cpp:356` 把 `temperature=0` 转成 `0.2`，并不是 greedy；top-k/top-p 也在生效。线程数变化会改变浮点累加顺序，进而改变采样路径，所以差异里混有采样随机性。
3. 两次整页运行的输出 token 数不同（1224 vs 1148、928 vs 1153），不是严格同分布对比。

因此：**没有证据表明 4 线程会造成系统性质量下降，但现有数据也不足以证明“质量完全不变”**。严格结论需要清晰样张 + 真 greedy + 多张图。

## 7. 建议

1. **保留 4 线程 + CLIP warmup**（已在 `b59aac5`）。4 线程是 prefill/decode 的主要收益来源，encode 基本不受影响。
2. **保留 F16 mmproj**；Q8 只用于内存吃紧场景。
3. **2048 精度档默认 cap 2560**；cap 2048 作为“更快”选项，等质量评估通过后再设为默认。
4. **1280 不做 token cap**。1200 tokens 已经接近 grounding 建议下限，再降到 999 收益很小、风险不小。
5. **修 `temperature=0` 语义**：显式走 greedy sampler，或增加 `--greedy`，否则质量 A/B 永远有采样噪声。
6. **可选：encode 8 线程 + prefill/decode 4 线程**。2048 下 encode 用 8 线程可比 4 线程省约 10s，但需要给 `ocr_create` 增加独立的 `encode_threads` 参数。
7. **进一步提速只能上 GPU/NPU**。Vulkan 当前 shader link 失败；`GGML_OPENCL` + Adreno 专用 kernel 是下一个候选，可只 offload mmproj，文本模型留在 CPU。

## 8. 复现

```bash
NDK=$HOME/Library/Android/sdk/ndk/28.2.13676358
cmake -S tool/ocr_cli -B build-android-cli \
  -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build-android-cli --target ocr_cli -j8

adb shell mkdir -p /data/local/tmp/locr/models
adb push build-android-cli/ocr_cli build-android-cli/ocr_shim/libocrshim.so /data/local/tmp/locr/
adb push build-models/lightonocr3-0.8b-Q4KM-headQ4.gguf /data/local/tmp/locr/models/main.gguf
adb push build-models/mmproj-lightonocr3-0.8b-f16.gguf /data/local/tmp/locr/models/mmproj-f16.gguf
adb push build/eval/report-1-1280.ppm build/eval/report-1-2048.ppm /data/local/tmp/locr/
adb shell 'chmod 755 /data/local/tmp/locr/ocr_cli'
```

单次运行：

```bash
adb shell 'cd /data/local/tmp/locr && LD_LIBRARY_PATH=. ./ocr_cli \
  --model models/main.gguf --mmproj models/mmproj-f16.gguf \
  --image report-1-1280.ppm --mode grounding --max-tokens 128 \
  --temp 0 --seed 42 --threads 4 --ctx 12288 --batch 2048'
```

测量前必须 `am force-stop com.example.lighton_ocr_on_device`，并确认没有遗留 `ocr_cli`；否则 CPU 被抢占，数据会差数倍。

## 9. 相关文档

- `docs/eval/2026-10-21-thread-tuning.md`：线程 / warmup / ubatch
- `docs/eval/2026-10-21-optimization-conclusion.md`：总体优化结论
- `docs/eval/2026-10-21-device-bench.md`：早期参数矩阵
- `docs/eval/2026-10-21-device-acceptance.md`：验收数据
