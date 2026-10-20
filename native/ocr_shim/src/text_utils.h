#pragma once

#include <cstddef>
#include <functional>
#include <string>

using Utf8Emit = std::function<void(const char*, size_t)>;

std::string ocr_build_prompt(const std::string& media_marker, const char* mode);

class Utf8StreamBuffer {
public:
    void append(const char* data, size_t len, const Utf8Emit& emit);
    void flush(const Utf8Emit& emit);

private:
    std::string pending_;
};
