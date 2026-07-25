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

template <typename Integer>
Integer ReadNetwork(const std::vector<std::uint8_t>& bytes, std::size_t offset)
{
    Integer value = 0;
    for (std::size_t index = 0; index < sizeof(Integer); ++index) {
        value = static_cast<Integer>((value << 8) | bytes[offset + index]);
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
    readOffset_ = 0;
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
        if (BufferedBytes() >= kMaximumBufferedFrame) {
            return Failure("video frame buffer exceeded limit");
        }
        const auto available = kMaximumBufferedFrame - BufferedBytes();
        const auto amount = std::min({size - offset, available, kAppendChunkSize});
        if (readOffset_ > 0 && buffer_.size() + amount > kMaximumBufferedFrame) {
            CompactConsumed(true);
        }
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
    if (BufferedBytes() != 0) return Failure("video channel ended with a truncated frame");
    return {};
}

FrameParserResult FrameParser::ParseAvailable()
{
    FrameParserResult result;
    while (BufferedBytes() >= protocol::kVideoFrameHeaderSize) {
        const auto frameStart = readOffset_;
        if (!std::equal(kMagic.begin(), kMagic.end(), buffer_.begin() + frameStart)) {
            return Failure("invalid video frame magic");
        }
        if (buffer_[frameStart + 4] != 1) return Failure("unsupported video frame version");
        if (buffer_[frameStart + 5] != 1 && buffer_[frameStart + 5] != 2) {
            return Failure("invalid video frame type");
        }
        const auto payloadLength = ReadNetwork<std::uint32_t>(buffer_, frameStart + 28);
        if (payloadLength > protocol::kMaximumVideoPayloadSize) {
            return Failure("video payload exceeds 16 MiB");
        }
        const auto frameSize = protocol::kVideoFrameHeaderSize + static_cast<std::size_t>(payloadLength);
        if (BufferedBytes() < frameSize) break;

        protocol::VideoFrame frame;
        frame.frameType = static_cast<protocol::VideoFrameType>(buffer_[frameStart + 5]);
        frame.flags = ReadNetwork<std::uint16_t>(buffer_, frameStart + 6);
        frame.sequence = ReadNetwork<std::uint32_t>(buffer_, frameStart + 8);
        frame.ptsUs = ReadNetwork<std::uint64_t>(buffer_, frameStart + 12);
        frame.captureUs = ReadNetwork<std::uint64_t>(buffer_, frameStart + 20);
        const auto payloadStart = frameStart + protocol::kVideoFrameHeaderSize;
        frame.payload.assign(
            buffer_.begin() + payloadStart,
            buffer_.begin() + frameStart + frameSize);
        if (!IsAnnexB(frame.payload)) return Failure("video payload is not Annex B");
        if (!SequenceIsNewer(frame.sequence)) return Failure("video sequence moved backwards");
        lastSequence_ = frame.sequence;
        result.frames.push_back(std::move(frame));
        readOffset_ += frameSize;
    }
    CompactConsumed();
    return result;
}

FrameParserResult FrameParser::Failure(std::string detail)
{
    failed_ = true;
    buffer_.clear();
    readOffset_ = 0;
    return {{}, std::string(protocol::kProtocolErrorCode), std::move(detail)};
}

bool FrameParser::SequenceIsNewer(std::uint32_t value) const
{
    if (!lastSequence_.has_value()) return true;
    const std::uint32_t distance = value - *lastSequence_;
    return distance != 0 && distance < (std::numeric_limits<std::uint32_t>::max() / 2U + 1U);
}

void FrameParser::CompactConsumed(bool force)
{
    if (readOffset_ == 0) return;
    if (readOffset_ == buffer_.size()) {
        buffer_.clear();
        readOffset_ = 0;
        return;
    }
    constexpr std::size_t kCompactionThreshold = 64 * 1024;
    if (!force && readOffset_ < kCompactionThreshold) return;
    buffer_.erase(buffer_.begin(), buffer_.begin() + readOffset_);
    readOffset_ = 0;
}

} // namespace second_display::transport
