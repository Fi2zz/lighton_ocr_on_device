import 'ocr_types.dart';

String ocrErrorMessage(OcrException error) {
  return switch (error.code) {
    OcrErrorCode.modelMissing => '请先导入主模型和 mmproj',
    OcrErrorCode.ggufInvalid => '文件不是有效的 GGUF，或类型选错',
    OcrErrorCode.load => '模型加载失败，查看详情',
    OcrErrorCode.oom => '内存不足，请降低图片长边或换更小的量化',
    OcrErrorCode.encode => '图片编码失败，换一张图片',
    OcrErrorCode.decode => '推理失败，查看详情',
    OcrErrorCode.mode => '内部错误：未知的识别模式',
    OcrErrorCode.cancelled => '已取消',
    OcrErrorCode.workerCrash => '推理进程退出，可重试',
    OcrErrorCode.busy => '正在识别，请稍候',
    _ => '${error.code}：${error.message}',
  };
}
