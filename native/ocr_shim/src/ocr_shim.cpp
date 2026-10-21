#include "ocr_shim.h"
#include "text_utils.h"

#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"

#include <atomic>
#include <cerrno>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <exception>
#include <new>
#include <string>
#include <vector>

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
    int32_t n_batch = 2048;
    int32_t n_ctx   = 12288;
    double load_ms  = 0.0;
};

enum {
    OCR_RUN_OK = 0,
    OCR_RUN_ERROR = 1,
    OCR_RUN_CANCELLED = 3,
    OCR_RUN_OOM = 4,
    OCR_RUN_ENCODE = 5,
    OCR_RUN_DECODE = 6,
    OCR_RUN_MODE = 7,
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

    const int64_t load_start = ggml_time_us();
    llama_log_set(ocr_log_callback, nullptr);
    mtmd_helper_log_set(ocr_log_callback, nullptr);

    auto* engine = new (std::nothrow) ocr_engine();
    if (engine == nullptr) {
        set_error(err, err_cap, "E_OOM", "failed to allocate engine");
        return nullptr;
    }
    engine->n_batch = n_batch > 0 ? n_batch : 2048;
    engine->n_ctx   = n_ctx > 0 ? n_ctx : 8192;

    try {
        llama_backend_init();

        LoadProgressCtx progress_ctx { on_progress, progress_ud };

        llama_model_params mparams = llama_model_default_params();
        mparams.n_gpu_layers = 0;
        mparams.progress_callback = load_progress_callback;
        mparams.progress_callback_user_data = &progress_ctx;

        engine->model = llama_model_load_from_file(model_path, mparams);
        if (engine->model == nullptr) {
            set_error(err, err_cap, errno == ENOMEM ? "E_OOM" : "E_LOAD", "failed to load text model");
            ocr_destroy(engine);
            return nullptr;
        }

        llama_context_params cparams = llama_context_default_params();
        cparams.n_ctx           = static_cast<uint32_t>(engine->n_ctx);
        cparams.n_batch         = static_cast<uint32_t>(engine->n_batch);
        cparams.n_ubatch        = static_cast<uint32_t>(std::min<int32_t>(engine->n_batch, 256));
        cparams.n_threads       = n_threads > 0 ? n_threads : 4;
        cparams.n_threads_batch = n_threads > 0 ? n_threads : 4;
        cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;

        engine->ctx = llama_init_from_model(engine->model, cparams);
        if (engine->ctx == nullptr) {
            set_error(err, err_cap, errno == ENOMEM ? "E_OOM" : "E_LOAD", "failed to create llama context");
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
        engine->load_ms = (ggml_time_us() - load_start) / 1000.0;
        return engine;
    } catch (const std::bad_alloc&) {
        set_error(err, err_cap, "E_OOM", "out of memory while loading");
    } catch (const std::exception& ex) {
        set_error(err, err_cap, "E_LOAD", ex.what());
    } catch (...) {
        set_error(err, err_cap, "E_LOAD", "unknown exception while loading");
    }

    ocr_destroy(engine);
    return nullptr;
}

int32_t ocr_run(ocr_engine* engine,
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
                size_t err_cap) {
    if (stats != nullptr) {
        std::memset(stats, 0, sizeof(*stats));
    }
    if (engine == nullptr) {
        set_error(err, err_cap, "E_LOAD", "engine is null");
        return OCR_RUN_ERROR;
    }
    if (rgb == nullptr || width <= 0 || height <= 0) {
        set_error(err, err_cap, "E_ENCODE", "invalid image buffer");
        return OCR_RUN_ENCODE;
    }

    engine->cancel.store(false);

    std::string prompt;
    try {
        prompt = ocr_build_prompt(mtmd_default_marker(), mode);
    } catch (const std::exception& ex) {
        set_error(err, err_cap, "E_MODE", ex.what());
        return OCR_RUN_MODE;
    }

    llama_memory_clear(llama_get_memory(engine->ctx), true);

    mtmd_bitmap* bitmap = mtmd_bitmap_init(
        static_cast<uint32_t>(width), static_cast<uint32_t>(height), rgb);
    if (bitmap == nullptr) {
        set_error(err, err_cap, "E_ENCODE", "failed to allocate image bitmap");
        return OCR_RUN_ENCODE;
    }

    mtmd_input_chunks* chunks = mtmd_input_chunks_init();
    if (chunks == nullptr) {
        mtmd_bitmap_free(bitmap);
        set_error(err, err_cap, "E_OOM", "failed to allocate input chunks");
        return OCR_RUN_OOM;
    }

    mtmd_input_text text { prompt.c_str(), prompt.size(), false, true };
    const int32_t tokenize_rc = mtmd_tokenize(engine->mtmd, chunks, &text, &bitmap, 1);
    mtmd_bitmap_free(bitmap);
    if (tokenize_rc != 0) {
        mtmd_input_chunks_free(chunks);
        set_error(err, err_cap, "E_ENCODE", "mtmd_tokenize failed");
        return OCR_RUN_ENCODE;
    }

    const size_t n_chunks = mtmd_input_chunks_size(chunks);
    if (n_chunks == 0) {
        mtmd_input_chunks_free(chunks);
        set_error(err, err_cap, "E_ENCODE", "empty input chunks");
        return OCR_RUN_ENCODE;
    }

    llama_pos n_past = 0;
    int32_t image_tokens = 0;
    double encode_ms = 0.0;
    double prefill_ms = 0.0;

    for (size_t i = 0; i < n_chunks; ++i) {
        if (engine->cancel.load()) {
            mtmd_input_chunks_free(chunks);
            set_error(err, err_cap, "E_CANCELLED", "cancelled during prompt evaluation");
            return OCR_RUN_CANCELLED;
        }

        const mtmd_input_chunk* chunk = mtmd_input_chunks_get(chunks, i);
        const bool is_last = (i + 1 == n_chunks);
        const mtmd_input_chunk_type type = mtmd_input_chunk_get_type(chunk);

        if (type == MTMD_INPUT_CHUNK_TYPE_TEXT) {
            const int64_t t0 = ggml_time_us();
            llama_pos new_past = n_past;
            const int32_t rc = mtmd_helper_eval_chunk_single(
                engine->mtmd, engine->ctx, chunk, n_past, 0, engine->n_batch,
                is_last, &new_past);
            prefill_ms += (ggml_time_us() - t0) / 1000.0;
            if (rc != 0) {
                mtmd_input_chunks_free(chunks);
                set_error(err, err_cap, "E_DECODE", "text chunk evaluation failed");
                return OCR_RUN_DECODE;
            }
            n_past = new_past;
        } else if (type == MTMD_INPUT_CHUNK_TYPE_IMAGE) {
            if (on_progress != nullptr) {
                on_progress("encode", 0.0f, ud);
            }
            const int64_t t0 = ggml_time_us();
            const int32_t encode_rc = mtmd_encode_chunk(engine->mtmd, chunk);
            encode_ms += (ggml_time_us() - t0) / 1000.0;
            if (encode_rc != 0) {
                mtmd_input_chunks_free(chunks);
                set_error(err, err_cap, "E_ENCODE", "image encoding failed");
                return OCR_RUN_ENCODE;
            }
            float* embd = mtmd_get_output_embd(engine->mtmd);
            if (embd == nullptr) {
                mtmd_input_chunks_free(chunks);
                set_error(err, err_cap, "E_ENCODE", "image embeddings missing");
                return OCR_RUN_ENCODE;
            }
            if (on_progress != nullptr) {
                on_progress("encode", 1.0f, ud);
            }

            const int64_t t1 = ggml_time_us();
            llama_pos new_past = n_past;
            const int32_t decode_rc = mtmd_helper_decode_image_chunk(
                engine->mtmd, engine->ctx, chunk, embd, n_past, 0, engine->n_batch,
                &new_past, nullptr, nullptr);
            prefill_ms += (ggml_time_us() - t1) / 1000.0;
            if (decode_rc != 0) {
                mtmd_input_chunks_free(chunks);
                set_error(err, err_cap, "E_DECODE", "image embedding decode failed");
                return OCR_RUN_DECODE;
            }
            n_past = new_past;
            image_tokens += static_cast<int32_t>(mtmd_input_chunk_get_n_tokens(chunk));
        } else {
            mtmd_input_chunks_free(chunks);
            set_error(err, err_cap, "E_ENCODE", "unsupported input chunk type");
            return OCR_RUN_ENCODE;
        }
    }

    const int32_t prompt_tokens = static_cast<int32_t>(mtmd_helper_get_n_tokens(chunks));
    mtmd_input_chunks_free(chunks);

    int32_t max_new = max_tokens > 0 ? max_tokens : 4096;
    const int32_t context_left = engine->n_ctx - static_cast<int32_t>(n_past);
    if (max_new > context_left) {
        max_new = context_left;
    }
    if (max_new <= 0) {
        set_error(err, err_cap, "E_DECODE", "context is full");
        return OCR_RUN_DECODE;
    }

    llama_sampler* sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(sampler, llama_sampler_init_top_k(20));
    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9f, 1));
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature > 0.0f ? temperature : 0.2f));
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(seed));

    Utf8StreamBuffer utf8;
    auto emit = [&](const char* data, size_t len) {
        if (on_token != nullptr) {
            on_token(data, static_cast<int32_t>(len), ud);
        }
    };

    int32_t generated = 0;
    int32_t run_rc = OCR_RUN_OK;
    const int64_t decode_start = ggml_time_us();
    llama_batch batch = llama_batch_init(1, 0, 1);

    for (int32_t i = 0; i < max_new; ++i) {
        if (engine->cancel.load()) {
            run_rc = OCR_RUN_CANCELLED;
            break;
        }

        const llama_token token = llama_sampler_sample(sampler, engine->ctx, -1);
        llama_sampler_accept(sampler, token);
        if (llama_vocab_is_eog(engine->vocab, token)) {
            break;
        }

        char piece[256];
        const int32_t piece_len = llama_token_to_piece(
            engine->vocab, token, piece, sizeof(piece), 0, false);
        if (piece_len < 0) {
            run_rc = OCR_RUN_DECODE;
            break;
        }
        if (piece_len > 0) {
            utf8.append(piece, static_cast<size_t>(piece_len), emit);
            generated++;
        }

        if (on_progress != nullptr && (i % 16) == 0) {
            on_progress("decode", static_cast<float>(i) / static_cast<float>(max_new), ud);
        }
        if (i + 1 >= max_new) {
            break;
        }
        if (n_past + 1 >= engine->n_ctx) {
            break;
        }

        batch.n_tokens = 1;
        batch.token[0] = token;
        batch.pos[0] = n_past;
        batch.n_seq_id[0] = 1;
        batch.seq_id[0][0] = 0;
        batch.logits[0] = true;

        const int32_t decode_rc = llama_decode(engine->ctx, batch);
        if (decode_rc != 0) {
            if (errno == ENOMEM) {
                set_error(err, err_cap, "E_OOM", "out of memory while decoding");
                run_rc = OCR_RUN_OOM;
            } else {
                run_rc = OCR_RUN_DECODE;
            }
            break;
        }
        n_past++;
    }

    llama_batch_free(batch);
    utf8.flush(emit);

    const double decode_ms = (ggml_time_us() - decode_start) / 1000.0;
    llama_sampler_free(sampler);

    if (stats != nullptr) {
        stats->prompt_tokens = prompt_tokens;
        stats->output_tokens = generated;
        stats->image_tokens = image_tokens;
        stats->load_ms = engine->load_ms;
        stats->encode_ms = encode_ms;
        stats->prefill_ms = prefill_ms;
        stats->decode_ms = decode_ms;
        stats->peak_rss_kb = peak_rss_kb();
    }

    if (on_progress != nullptr) {
        on_progress("decode", 1.0f, ud);
    }

    if (run_rc == OCR_RUN_CANCELLED) {
        set_error(err, err_cap, "E_CANCELLED", "cancelled by user");
        return OCR_RUN_CANCELLED;
    }
    if (run_rc == OCR_RUN_OOM) {
        return OCR_RUN_OOM;
    }
    if (run_rc != OCR_RUN_OK) {
        set_error(err, err_cap, "E_DECODE", "generation failed");
        return OCR_RUN_DECODE;
    }
    return OCR_RUN_OK;
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
