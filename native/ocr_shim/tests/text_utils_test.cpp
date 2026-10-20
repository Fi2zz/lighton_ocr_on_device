#include "text_utils.h"

#include <cassert>
#include <cstdlib>
#include <iostream>
#include <string>

static void expect_eq(const std::string& got, const std::string& want) {
    if (got != want) {
        std::cerr << "got:  [" << got << "]\nwant: [" << want << "]\n";
        std::abort();
    }
}

static void test_prompt_plain() {
    const std::string expected =
        "<|im_start|>user\n<__media__><|im_end|>\n"
        "<|im_start|>assistant\n"
        " thinking\n\n"
        " response\n\n";
    expect_eq(ocr_build_prompt("<__media__>", "plain"), expected);
}

static void test_prompt_grounding() {
    const std::string expected =
        "<|im_start|>user\n<__media__>grounding<|im_end|>\n"
        "<|im_start|>assistant\n"
        " thinking\n\n"
        " response\n\n";
    expect_eq(ocr_build_prompt("<__media__>", "grounding"), expected);
}

static void test_utf8_split() {
    Utf8StreamBuffer buf;
    std::string out;
    auto emit = [&](const char* d, size_t n) { out.append(d, n); };
    const char bytes[] = "\xE6\xB5\x8B"; // 测
    buf.append(bytes, 1, emit);
    assert(out.empty());
    buf.append(bytes + 1, 2, emit);
    expect_eq(out, "测");
    buf.flush(emit);
    expect_eq(out, "测");
}

static void test_utf8_mixed_ascii() {
    Utf8StreamBuffer buf;
    std::string out;
    auto emit = [&](const char* d, size_t n) { out.append(d, n); };
    const char bytes[] = {'A', '\xE6', '\xB5', '\x8B', 'B'};
    buf.append(bytes, 2, emit);
    buf.append(bytes + 2, 3, emit);
    expect_eq(out, "A测B");
}

static void test_utf8_invalid() {
    Utf8StreamBuffer buf;
    std::string out;
    auto emit = [&](const char* d, size_t n) { out.append(d, n); };
    const char bytes[] = "\xFF";
    buf.append(bytes, 1, emit);
    buf.flush(emit);
    expect_eq(out, "\xEF\xBF\xBD"); // U+FFFD
}

int main() {
    test_prompt_plain();
    test_prompt_grounding();
    test_utf8_split();
    test_utf8_mixed_ascii();
    test_utf8_invalid();
    std::cout << "text_utils_test: ok\n";
    return 0;
}
