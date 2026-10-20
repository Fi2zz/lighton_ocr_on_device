#include "ocr_shim.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

struct Args {
    bool info = false;
    bool load_only = false;
    std::string model;
    std::string mmproj;
    int32_t threads = 4;
    int32_t ctx = 12288;
    int32_t batch = 2048;
    int32_t image_max_tokens = 4096;
};

void progress(const char* stage, float fraction, void* /*ud*/) {
    std::fprintf(stderr, "%s %.0f%%\n", stage, fraction * 100.0f);
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
        } else if (arg == "--threads") {
            if (!parse_int(next("--threads"), &args->threads)) return false;
        } else if (arg == "--ctx") {
            if (!parse_int(next("--ctx"), &args->ctx)) return false;
        } else if (arg == "--batch") {
            if (!parse_int(next("--batch"), &args->batch)) return false;
        } else if (arg == "--image-max-tokens") {
            if (!parse_int(next("--image-max-tokens"), &args->image_max_tokens)) return false;
        } else {
            std::fprintf(stderr, "unknown argument: %s\n", arg.c_str());
            return false;
        }
    }
    return true;
}

} // namespace

int main(int argc, char** argv) {
    Args args;
    if (!parse_args(argc, argv, &args)) {
        std::fprintf(stderr,
                     "usage: %s --info | --load-only --model <gguf> --mmproj <gguf> "
                     "[--threads N] [--ctx N] [--batch N] [--image-max-tokens N]\n",
                     argv[0]);
        return 2;
    }

    if (args.info) {
        std::printf("stats_size=%zu\n", ocr_stats_size());
        return 0;
    }

    if (!args.load_only) {
        std::fprintf(stderr, "nothing to do; use --info or --load-only\n");
        return 2;
    }
    if (args.model.empty() || args.mmproj.empty()) {
        std::fprintf(stderr, "--load-only requires --model and --mmproj\n");
        return 2;
    }

    char err[1024] = {0};
    ocr_engine* engine = ocr_create(args.model.c_str(),
                                    args.mmproj.c_str(),
                                    args.threads,
                                    args.ctx,
                                    args.batch,
                                    args.image_max_tokens,
                                    progress,
                                    nullptr,
                                    err,
                                    sizeof(err));
    if (engine == nullptr) {
        std::fprintf(stderr, "%s\n", err);
        return 1;
    }

    std::printf("load_ok\n");
    ocr_destroy(engine);
    return 0;
}
