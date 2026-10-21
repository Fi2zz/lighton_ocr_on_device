# Android 端到端验收 — 2026-10-21

## 已完成

- App 在 SM6435 / Android 16 真机启动。
- 模型状态卡片显示 `LightOnOCR-3-0.8B · 700 MB · 已就绪`（Q4_K_M + mmproj）。
- 设置入口、长边 1280、最大输出 4096 正常显示。
- 相册入口打开系统 Photo Picker；选中图片后进入预览。
- 识别过程中 UI 保持可交互，显示 `decode` 阶段和“已生成 N 字符”；推理在 `IsolateOcrWorker` 中运行，没有主线程 ANR。
- 取消已在真机验证：点击取消后数秒回到 ready，引擎保留可复用，worker isolate 未被杀死。
- 返回/重新选择、模型配置页、结果页由 widget test 覆盖。

## 未完成 / 限制

- 时间盒内没有把 8 张 sample 全部通过 UI 跑完；原生管线已用 `tool/ocr_cli` 和 `lib/main_ffi_smoke.dart` 验证同一份 1280/2048 图片。
- 系统 Photo Picker 中定位 `samples/report-1.jpg` 较麻烦；已把 sample 推到 `/sdcard/DCIM/Camera`，但本次验收误选了其他截图。建议手动验收时使用“相册 → 最近”或先清理其他图片。
- 真机 UI 的完整全页结果页没有在本次时间盒内完成截图；结果页渲染、复制、分享、耗时详情由 `test/result_page_test.dart` 覆盖。

## 真机数据（引用 smoke）

- 1280px / Q4_K_M / 8 threads：整页约 130s，11.4 tok/s，峰值 RSS 2.1GB。
- 2048px / Q4_K_M：encode 91s + prefill 39s + 512 token 51.5s；整页预计 4–5 分钟。
- 详细数据见 `docs/eval/2026-10-21-android-smoke.md`。

## 后续必须补的验收

1. 用 `samples/report-2..8` 逐张跑 UI，记录质量与耗时。
2. 验证“未配置 → 配置模型 → 导入 → 加载 → 识别”全流程。
3. 验证取消后立即再次识别、后台切换、删除模型后重新导入。
4. 记录 `adb shell dumpsys meminfo` 峰值。
