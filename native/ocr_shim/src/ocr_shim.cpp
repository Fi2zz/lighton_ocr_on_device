#include "ocr_shim.h"
#include "text_utils.h"

#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"

#include <atomic>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <exception>
#include <string>

#ifdef __ANDROID__
#  include <android/log.h>
#endif

#if defined(__APPLE__) || defined(__linux__)
#  include <sys/resource.h>
#endif

static_assert(sizeof(ocr_stats) == 56, "ocr_stats ABI changed");

struct ocr_engine {
    llama_model*   model = nullptr;
    llama_context* ctx   = nullptr;
    mtmd_context*  mtmd  = nullptr;
    const llama_vocab* vocab = nullptr;
    std::atomic<bool> cancel{false};
    int32_t n_batch = 4096;
    int32_t n_ctx   = 12288;
};

static void set_error(char* err, size_t cap, const char* code, const char* msg) {
    if (err != nullptr && cap > 0) {
        std::snprintf(err, cap, "%s: %s", code, msg != nullptr ? msg : "");
    }
}

static void ocr_log_callback(enum ggml_log_level level, const char* text, void* /*user_data*/) {
    (void) level;
    if (text == nullptr) {
        return;
    }
#ifdef __ANDROID__
    __android_log_print(ANDROID_LOG_INFO, "LightOnOCR", "%s", text);
#else
    std::fputs(text, stderr);
#endif
}

struct LoadProgressCtx {
    ocr_progress_cb cb;
    void* ud;
};

static bool load_progress_callback(float progress, void* user_data) {
    auto* ctx = static_cast<LoadProgressCtx*>(user_data);
    if (ctx != nullptr && ctx->cb != nullptr) {
        ctx->cb("load", progress, ctx->ud);
    }
    return true;
}

static int64_t peak_rss_kb() {
#if defined(__APPLE__) || defined(__linux__)
    struct rusage usage {};
    if (getrusage(RUSAGE_SELF, &usage) != 0) {
        return 0;
    }
#  ifdef __APPLE__
    return static_cast<int64_t>(usage.ru_maxrss / 1024);
#  else
    return static_cast<int64_t>(usage.ru_maxrss);
#  endif
#else
    return 0;
#endif
}

extern "C" {

ocr_engine* ocr_create(const char* model_path,
                       const char* mmproj_path,
                       int32_t n_threads,
                       int32_t n_ctx,
                       int32_t n_batch,
                       int32_t image_max_tokens,
                       ocr_progress_cb on_progress,
                       void* progress_ud,
                       char* err,
                       size_t err_cap) {
    if (err != nullptr && err_cap > 0) {
        err[0] = '\0';
    }
    if (model_path == nullptr || mmproj_path == nullptr) {
        set_error(err, err_cap, "E_LOAD", "model or mmproj path is null");
        return nullptr;
    }

    llama_log_set(ocr_log_callback, nullptr);
    mtmd_helper_log_set(ocr_log_callback, nullptr);

    auto* engine = new (std::nothrow) ocr_engine();
    if (engine == nullptr) {
        set_error(err, err_cap, "E_OOM", "failed to allocate engine");
        return nullptr;
    }
    engine->n_batch = n_batch > 0 ? n_batch : 4096;
    engine->n_ctx   = n_ctx > 0 ? n_ctx : 12288;

    bool backend_ready = false;
    try {
        llama_backend_init();
        backend_ready = true;

        LoadProgressCtx progress_ctx { on_progress, progress_ud };

        llama_model_params mparams = llama_model_default_params();
        mparams.n_gpu_layers = 0;
        mparams.progress_callback = load_progress_callback;
        mparams.progress_callback_user_data = &progress_ctx;

        engine->model = llama_model_load_from_file(model_path, mparams);
        if (engine->model == nullptr) {
            set_error(err, err_cap, "E_LOAD", "failed to load text model");
            ocr_destroy(engine);
            return nullptr;
        }

        llama_context_params cparams = llama_context_default_params();
        cparams.n_ctx           = static_cast<uint32_t>(engine->n_ctx);
        cparams.n_batch         = static_cast<uint32_t>(engine->n_batch);
        cparams.n_ubatch        = static_cast<uint32_t>(std::min<int32_t>(engine->n_batch, 512));
        cparams.n_threads       = n_threads > 0 ? n_threads : 4;
        cparams.n_threads_batch = n_threads > 0 ? n_threads : 4;
        cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;

        engine->ctx = llama_init_from_model(engine->model, cparams);
        if (engine->ctx == nullptr) {
            set_error(err, err_cap, "E_LOAD", "failed to create llama context");
            ocr_destroy(engine);
            return nullptr;
        }
        engine->vocab = llama_model_get_vocab(engine->model);

        mtmd_context_params tparams = mtmd_context_params_default();
        tparams.use_gpu          = false;
        tparams.print_timings    = false;
        tparams.n_threads        = n_threads > 0 ? n_threads : 4;
        tparams.image_max_tokens = image_max_tokens > 0 ? image_max_tokens : 4096;
        tparams.media_marker     = mtmd_default_marker();
        tparams.warmup           = false;

        engine->mtmd = mtmd_init_from_file(mmproj_path, engine->model, tparams);
        if (engine->mtmd == nullptr) {
            set_error(err, err_cap, "E_LOAD", "failed to load mmproj");
            ocr_destroy(engine);
            return nullptr;
        }
        if (!mtmd_support_vision(engine->mtmd)) {
            set_error(err, err_cap, "E_LOAD", "mmproj has no vision encoder");
            ocr_destroy(engine);
            return nullptr;
        }

        if (on_progress != nullptr) {
            on_progress("load", 1.0f, progress_ud);
        }
        return engine;
    } catch (const std::exception& ex) {
        set_error(err, err_cap, "E_LOAD", ex.what());
    } catch (...) {
        set_error(err, err_cap, "E_LOAD", "unknown exception while loading");
    }

    ocr_destroy(engine);
    if (backend_ready) {
        // ocr_destroy already calls llama_backend_free; kept for clarity.
    }
    return nullptr;
}

int32_t ocr_run(ocr_engine* engine,
                const uint8_t* /*rgb*/,
                int32_t /*width*/,
                int32_t /*height*/,
                const char* /*mode*/,
                int32_t /*max_tokens*/,
                float /*temperature*/,
                uint32_t /*seed*/,
                ocr_token_cb /*on_token*/,
                ocr_progress_cb /*on_progress*/,
                void* /*ud*/,
                ocr_stats* stats,
                char* err,
                size_t err_cap) {
    if (stats != nullptr) {
        std::memset(stats, 0, sizeof(*stats));
    }
    if (engine == nullptr) {
        set_error(err, err_cap, "E_LOAD", "engine is null");
        return -1;
    }
    set_error(err, err_cap, "E_DECODE", "not implemented yet");
    return -1;
}

void ocr_cancel(ocr_engine* engine) {
    if (engine != nullptr) {
        engine->cancel.store(true);
    }
}

void ocr_destroy(ocr_engine* engine) {
    if (engine == nullptr) {
        return;
    }
    engine->cancel.store(true);
    if (engine->mtmd != nullptr) {
        mtmd_free(engine->mtmd);
        engine->mtmd = nullptr;
    }
    if (engine->ctx != nullptr) {
        llama_free(engine->ctx);
        engine->ctx = nullptr;
    }
    if (engine->model != nullptr) {
        llama_model_free(engine->model);
        engine->model = nullptr;
    }
    llama_backend_free();
    delete engine;
}

size_t ocr_stats_size(void) {
    return sizeof(ocr_stats);
}

} // extern "C"
