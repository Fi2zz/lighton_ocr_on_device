#include "ocr_shim.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {

struct Args {
    bool info = false;
    bool load_only = false;
    std::string model;
    std::string mmproj;
    std::string image;
    std::string mode = "grounding";
    int32_t threads = 4;
    int32_t ctx = 8192;
    int32_t batch = 2048;
    int32_t image_max_tokens = 4096;
    int32_t max_tokens = 4096;
    int32_t cancel_after_ms = 0;
    float temperature = 0.2f;
    uint32_t seed = 42;
};

struct Ppm {
    int32_t width = 0;
    int32_t height = 0;
    std::vector<uint8_t> rgb;
};

void progress(const char* stage, float fraction, void* /*ud*/) {
    std::fprintf(stderr, "%s %.0f%%\n", stage, fraction * 100.0f);
}

void token_out(const char* utf8, int32_t len, void* /*ud*/) {
    if (utf8 != nullptr && len > 0) {
        std::fwrite(utf8, 1, static_cast<size_t>(len), stdout);
        std::fflush(stdout);
    }
}

bool parse_int(const char* value, int32_t* out) {
    if (value == nullptr) {
        return false;
    }
    char* end = nullptr;
    const long parsed = std::strtol(value, &end, 10);
    if (end == value || *end != '\0' || parsed <= 0) {
        return false;
    }
    *out = static_cast<int32_t>(parsed);
    return true;
}

bool parse_uint(const char* value, uint32_t* out) {
    if (value == nullptr) {
        return false;
    }
    char* end = nullptr;
    const unsigned long parsed = std::strtoul(value, &end, 10);
    if (end == value || *end != '\0') {
        return false;
    }
    *out = static_cast<uint32_t>(parsed);
    return true;
}

bool parse_float(const char* value, float* out) {
    if (value == nullptr) {
        return false;
    }
    char* end = nullptr;
    const double parsed = std::strtod(value, &end);
    if (end == value || *end != '\0') {
        return false;
    }
    *out = static_cast<float>(parsed);
    return true;
}

bool parse_args(int argc, char** argv, Args* args) {
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto next = [&](const char* name) -> const char* {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "missing value for %s\n", name);
                return nullptr;
            }
            return argv[++i];
        };

        if (arg == "--info") {
            args->info = true;
        } else if (arg == "--load-only") {
            args->load_only = true;
        } else if (arg == "--model") {
            const char* value = next("--model");
            if (value == nullptr) return false;
            args->model = value;
        } else if (arg == "--mmproj") {
            const char* value = next("--mmproj");
            if (value == nullptr) return false;
            args->mmproj = value;
        } else if (arg == "--image") {
            const char* value = next("--image");
            if (value == nullptr) return false;
            args->image = value;
        } else if (arg == "--mode") {
            const char* value = next("--mode");
            if (value == nullptr) return false;
            args->mode = value;
        } else if (arg == "--threads") {
            if (!parse_int(next("--threads"), &args->threads)) return false;
        } else if (arg == "--ctx") {
            if (!parse_int(next("--ctx"), &args->ctx)) return false;
        } else if (arg == "--batch") {
            if (!parse_int(next("--batch"), &args->batch)) return false;
        } else if (arg == "--image-max-tokens") {
            if (!parse_int(next("--image-max-tokens"), &args->image_max_tokens)) return false;
        } else if (arg == "--max-tokens") {
            if (!parse_int(next("--max-tokens"), &args->max_tokens)) return false;
        } else if (arg == "--cancel-after-ms") {
            if (!parse_int(next("--cancel-after-ms"), &args->cancel_after_ms)) return false;
        } else if (arg == "--temp") {
            if (!parse_float(next("--temp"), &args->temperature)) return false;
        } else if (arg == "--seed") {
            if (!parse_uint(next("--seed"), &args->seed)) return false;
        } else {
            std::fprintf(stderr, "unknown argument: %s\n", arg.c_str());
            return false;
        }
    }
    return true;
}

bool read_ppm(const std::string& path, Ppm* out) {
    FILE* file = std::fopen(path.c_str(), "rb");
    if (file == nullptr) {
        std::fprintf(stderr, "cannot open image: %s\n", path.c_str());
        return false;
    }

    char magic[3] = {0};
    if (std::fscanf(file, "%2s", magic) != 1 || std::strcmp(magic, "P6") != 0) {
        std::fprintf(stderr, "image must be a binary P6 PPM\n");
        std::fclose(file);
        return false;
    }

    int32_t width = 0;
    int32_t height = 0;
    int32_t max_value = 0;
    if (std::fscanf(file, "%d %d %d", &width, &height, &max_value) != 3 ||
        width <= 0 || height <= 0 || max_value != 255) {
        std::fprintf(stderr, "invalid PPM header\n");
        std::fclose(file);
        return false;
    }
    // A single whitespace character separates the header from the raster.
    std::fgetc(file);

    const size_t expected = static_cast<size_t>(width) * static_cast<size_t>(height) * 3u;
    out->rgb.resize(expected);
    const size_t got = std::fread(out->rgb.data(), 1, expected, file);
    std::fclose(file);
    if (got != expected) {
        std::fprintf(stderr, "truncated PPM raster\n");
        return false;
    }
    out->width = width;
    out->height = height;
    return true;
}

ocr_engine* create_engine(const Args& args, char* err, size_t err_cap) {
    return ocr_create(args.model.c_str(),
                      args.mmproj.c_str(),
                      args.threads,
                      args.ctx,
                      args.batch,
                      args.image_max_tokens,
                      progress,
                      nullptr,
                      err,
                      err_cap);
}

} // namespace

int main(int argc, char** argv) {
    Args args;
    if (!parse_args(argc, argv, &args)) {
        std::fprintf(stderr,
                     "usage: %s --info | --load-only --model <gguf> --mmproj <gguf> | "
                     "--model <gguf> --mmproj <gguf> --image <ppm> [--mode grounding|plain] "
                     "[--max-tokens N] [--temp F] [--seed N] [--cancel-after-ms N]\n",
                     argv[0]);
        return 2;
    }

    if (args.info) {
        std::printf("stats_size=%zu\n", ocr_stats_size());
        return 0;
    }

    if (args.model.empty() || args.mmproj.empty()) {
        std::fprintf(stderr, "--model and --mmproj are required\n");
        return 2;
    }

    char err[1024] = {0};

    if (args.load_only && args.image.empty()) {
        ocr_engine* engine = create_engine(args, err, sizeof(err));
        if (engine == nullptr) {
            std::fprintf(stderr, "%s\n", err);
            return 1;
        }
        std::printf("load_ok\n");
        ocr_destroy(engine);
        return 0;
    }

    if (args.image.empty()) {
        std::fprintf(stderr, "nothing to do; use --info, --load-only, or --image\n");
        return 2;
    }

    Ppm ppm;
    if (!read_ppm(args.image, &ppm)) {
        return 5;
    }

    ocr_engine* engine = create_engine(args, err, sizeof(err));
    if (engine == nullptr) {
        std::fprintf(stderr, "%s\n", err);
        return 1;
    }

    std::thread cancel_thread;
    if (args.cancel_after_ms > 0) {
        cancel_thread = std::thread([engine, ms = args.cancel_after_ms]() {
            std::this_thread::sleep_for(std::chrono::milliseconds(ms));
            ocr_cancel(engine);
        });
    }

    ocr_stats stats {};
    const int32_t rc = ocr_run(engine,
                               ppm.rgb.data(),
                               ppm.width,
                               ppm.height,
                               args.mode.c_str(),
                               args.max_tokens,
                               args.temperature,
                               args.seed,
                               token_out,
                               progress,
                               nullptr,
                               &stats,
                               err,
                               sizeof(err));

    if (cancel_thread.joinable()) {
        cancel_thread.join();
    }

    std::printf("\nstats: {\"prompt_tokens\":%d,\"output_tokens\":%d,\"image_tokens\":%d,"
                "\"load_ms\":%.1f,\"encode_ms\":%.1f,\"prefill_ms\":%.1f,\"decode_ms\":%.1f,"
                "\"peak_rss_kb\":%lld}\n",
                stats.prompt_tokens,
                stats.output_tokens,
                stats.image_tokens,
                stats.load_ms,
                stats.encode_ms,
                stats.prefill_ms,
                stats.decode_ms,
                static_cast<long long>(stats.peak_rss_kb));

    ocr_destroy(engine);

    if (rc == 0) {
        return 0;
    }
    if (err[0] != '\0') {
        std::fprintf(stderr, "%s\n", err);
    }
    return rc;
}
