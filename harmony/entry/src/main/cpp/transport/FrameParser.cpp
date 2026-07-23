#include "FrameParser.hpp"

#include "protocol/ControlMessage.hpp"

#include <algorithm>
#include <array>
#include <limits>
#include <utility>

namespace second_display::transport {
namespace {

constexpr std::array<std::uint8_t, 4> kMagic = {'S', 'D', 'S', '1'};
constexpr std::size_t kMaximumBufferedFrame =
    protocol::kVideoFrameHeaderSize + protocol::kMaximumVideoPayloadSize;
constexpr std::size_t kAppendChunkSize = 64 * 1024;

std::uint32_t ReadNetworkUInt32(const std::vector<std::uint8_t>& bytes, std::size_t offset)
{
    std::uint32_t value = 0;
    for (std::size_t index = 0; index < 4; ++index) {
        value = static_cast<std::uint32_t>((value << 8) | bytes[offset + index]);
    }
    return value;
}

bool IsAnnexB(const std::vector<std::uint8_t>& payload)
{
    if (payload.size() < 4 || payload[0] != 0 || payload[1] != 0) return false;
    return payload[2] == 1 || (payload[2] == 0 && payload[3] == 1);
}

} // namespace

void FrameParser::BeginSession(std::string sessionId)
{
    sessionId_ = std::move(sessionId);
    buffer_.clear();
    lastSequence_.reset();
    failed_ = sessionId_.empty();
}

FrameParserResult FrameParser::Feed(
    std::string_view sessionId, const std::uint8_t* bytes, std::size_t size)
{
    if (failed_) return Failure("frame parser is in a failed state");
    if (sessionId.empty() || sessionId != sessionId_) return Failure("video frame belongs to an old session");
    if (size > 0 && bytes == nullptr) return Failure("video input pointer is null");

    FrameParserResult combined;
    std::size_t offset = 0;
    while (offset < size) {
        if (buffer_.size() >= kMaximumBufferedFrame) return Failure("video frame buffer exceeded limit");
        const auto available = kMaximumBufferedFrame - buffer_.size();
        const auto amount = std::min({size - offset, available, kAppendChunkSize});
        buffer_.insert(buffer_.end(), bytes + offset, bytes + offset + amount);
        offset += amount;
        auto parsed = ParseAvailable();
        if (!parsed.Ok()) return parsed;
        combined.frames.insert(
            combined.frames.end(),
            std::make_move_iterator(parsed.frames.begin()),
            std::make_move_iterator(parsed.frames.end()));
    }
    return combined;
}

FrameParserResult FrameParser::Feed(
    std::string_view sessionId, const std::vector<std::uint8_t>& bytes)
{
    return Feed(sessionId, bytes.data(), bytes.size());
}

FrameParserResult FrameParser::Finish(std::string_view sessionId)
{
    if (sessionId != sessionId_) return Failure("video channel ended for an old session");
    if (!buffer_.empty()) return Failure("video channel ended with a truncated frame");
    return {};
}

FrameParserResult FrameParser::ParseAvailable()
{
    FrameParserResult result;
    while (buffer_.size() >= protocol::kVideoFrameHeaderSize) {
        if (!std::equal(kMagic.begin(), kMagic.end(), buffer_.begin())) {
            return Failure("invalid video frame magic");
        }
        if (buffer_[4] != 1) return Failure("unsupported video frame version");
        if (buffer_[5] != 1 && buffer_[5] != 2) return Failure("invalid video frame type");
        const auto payloadLength = ReadNetworkUInt32(buffer_, 28);
        if (payloadLength > protocol::kMaximumVideoPayloadSize) {
            return Failure("video payload exceeds 16 MiB");
        }
        const auto frameSize = protocol::kVideoFrameHeaderSize + static_cast<std::size_t>(payloadLength);
        if (buffer_.size() < frameSize) break;

        std::vector<std::uint8_t> encoded(buffer_.begin(), buffer_.begin() + frameSize);
        auto decoded = protocol::DecodeVideoFrame(encoded);
        if (!decoded.frame.has_value()) return Failure(decoded.detail);
        if (!IsAnnexB(decoded.frame->payload)) return Failure("video payload is not Annex B");
        if (!SequenceIsNewer(decoded.frame->sequence)) return Failure("video sequence moved backwards");
        lastSequence_ = decoded.frame->sequence;
        result.frames.push_back(std::move(*decoded.frame));
        buffer_.erase(buffer_.begin(), buffer_.begin() + frameSize);
    }
    return result;
}

FrameParserResult FrameParser::Failure(std::string detail)
{
    failed_ = true;
    buffer_.clear();
    return {{}, std::string(protocol::kProtocolErrorCode), std::move(detail)};
}

bool FrameParser::SequenceIsNewer(std::uint32_t value) const
{
    if (!lastSequence_.has_value()) return true;
    const std::uint32_t distance = value - *lastSequence_;
    return distance != 0 && distance < (std::numeric_limits<std::uint32_t>::max() / 2U + 1U);
}

} // namespace second_display::transport
