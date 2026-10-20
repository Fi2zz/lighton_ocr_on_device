#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  define OCR_API __declspec(dllexport)
#else
#  define OCR_API __attribute__((visibility("default")))
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

OCR_API ocr_engine* ocr_create(const char* model_path,
                               const char* mmproj_path,
                               int32_t n_threads,
                               int32_t n_ctx,
                               int32_t n_batch,
                               int32_t image_max_tokens,
                               ocr_progress_cb on_progress,
                               void* progress_ud,
                               char* err,
                               size_t err_cap);

OCR_API int32_t ocr_run(ocr_engine* engine,
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

OCR_API void ocr_cancel(ocr_engine* engine);
OCR_API void ocr_destroy(ocr_engine* engine);
OCR_API size_t ocr_stats_size(void);

#ifdef __cplusplus
}
#endif
