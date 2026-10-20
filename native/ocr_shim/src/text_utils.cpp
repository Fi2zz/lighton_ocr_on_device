#include "text_utils.h"

#include <cstdint>
#include <stdexcept>

namespace {

constexpr const char* kReplacement = "\xEF\xBF\xBD"; // U+FFFD
constexpr size_t kReplacementLen = 3;

// Returns the expected UTF-8 sequence length for a leading byte, or 0 when
// the byte cannot start a valid sequence.
size_t utf8_sequence_length(uint8_t lead) {
    if (lead <= 0x7F) return 1;
    if (lead >= 0xC2 && lead <= 0xDF) return 2;
    if (lead >= 0xE0 && lead <= 0xEF) return 3;
    if (lead >= 0xF0 && lead <= 0xF4) return 4;
    return 0;
}

bool is_continuation(uint8_t byte) {
    return (byte & 0xC0) == 0x80;
}

// Rejects overlong encodings, UTF-16 surrogates, and code points above U+10FFFF.
bool utf8_sequence_valid(const uint8_t* bytes, size_t len) {
    const uint8_t b1 = len >= 2 ? bytes[1] : 0;
    switch (len) {
        case 1:
            return bytes[0] <= 0x7F;
        case 2:
            return is_continuation(b1);
        case 3:
            if (!is_continuation(b1) || !is_continuation(bytes[2])) return false;
            if (bytes[0] == 0xE0 && b1 < 0xA0) return false;
            if (bytes[0] == 0xED && b1 > 0x9F) return false;
            return true;
        case 4:
            if (!is_continuation(b1) || !is_continuation(bytes[2]) || !is_continuation(bytes[3])) {
                return false;
            }
            if (bytes[0] == 0xF0 && b1 < 0x90) return false;
            if (bytes[0] == 0xF4 && b1 > 0x8F) return false;
            return true;
        default:
            return false;
    }
}

} // namespace

std::string ocr_build_prompt(const std::string& media_marker, const char* mode) {
    std::string body;
    if (mode != nullptr && std::string(mode) == "grounding") {
        body = "grounding";
    } else if (mode != nullptr && std::string(mode) == "plain") {
        body = "";
    } else {
        throw std::invalid_argument("mode must be plain or grounding");
    }

    return "<|im_start|>user\n" + media_marker + body + "<|im_end|>\n"
           "<|im_start|>assistant\n"
           " thinking\n\n"
           " response\n\n";
}

void Utf8StreamBuffer::append(const char* data, size_t len, const Utf8Emit& emit) {
    if (data != nullptr && len > 0) {
        pending_.append(data, len);
    }

    size_t i = 0;
    while (i < pending_.size()) {
        const uint8_t lead = static_cast<uint8_t>(pending_[i]);
        const size_t need = utf8_sequence_length(lead);

        if (need == 0) {
            emit(kReplacement, kReplacementLen);
            ++i;
            continue;
        }

        if (pending_.size() - i < need) {
            break; // wait for the rest of the sequence
        }

        if (!utf8_sequence_valid(
                reinterpret_cast<const uint8_t*>(pending_.data()) + i, need)) {
            emit(kReplacement, kReplacementLen);
            ++i;
            continue;
        }

        emit(pending_.data() + i, need);
        i += need;
    }

    if (i > 0) {
        pending_.erase(0, i);
    }
}

void Utf8StreamBuffer::flush(const Utf8Emit& emit) {
    if (!pending_.empty()) {
        emit(kReplacement, kReplacementLen);
        pending_.clear();
    }
}
