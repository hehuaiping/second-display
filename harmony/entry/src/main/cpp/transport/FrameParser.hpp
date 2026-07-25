#pragma once

#include "protocol/VideoFrame.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace second_display::transport {

struct FrameParserResult {
    std::vector<protocol::VideoFrame> frames;
    std::string errorCode;
    std::string detail;

    bool Ok() const { return errorCode.empty(); }
};

class FrameParser {
public:
    void BeginSession(std::string sessionId);
    FrameParserResult Feed(std::string_view sessionId, const std::uint8_t* bytes, std::size_t size);
    FrameParserResult Feed(std::string_view sessionId, const std::vector<std::uint8_t>& bytes);
    FrameParserResult Finish(std::string_view sessionId);
    std::size_t BufferedBytes() const { return buffer_.size() - readOffset_; }

private:
    FrameParserResult ParseAvailable();
    FrameParserResult Failure(std::string detail);
    bool SequenceIsNewer(std::uint32_t value) const;
    void CompactConsumed(bool force = false);

    std::string sessionId_;
    std::vector<std::uint8_t> buffer_;
    std::size_t readOffset_ = 0;
    std::optional<std::uint32_t> lastSequence_;
    bool failed_ = false;
};

} // namespace second_display::transport
