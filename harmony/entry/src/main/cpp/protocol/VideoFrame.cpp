#include "VideoFrame.hpp"

#include "ControlMessage.hpp"

#include <algorithm>
#include <array>
#include <limits>

namespace second_display::protocol {
namespace {

constexpr std::array<std::uint8_t, 4> kMagic = {'S', 'D', 'S', '1'};

template <typename Integer>
void AppendNetwork(Integer value, std::vector<std::uint8_t>& output)
{
    for (std::size_t index = 0; index < sizeof(Integer); ++index) {
        const auto shift = static_cast<unsigned>((sizeof(Integer) - index - 1) * 8);
        output.push_back(static_cast<std::uint8_t>((value >> shift) & 0xFF));
    }
}

template <typename Integer>
Integer ReadNetwork(const std::vector<std::uint8_t>& input, std::size_t offset)
{
    Integer result = 0;
    for (std::size_t index = 0; index < sizeof(Integer); ++index) {
        result = static_cast<Integer>((result << 8) | input[offset + index]);
    }
    return result;
}

VideoEncodeResult EncodeFailure(std::string detail)
{
    return {std::nullopt, std::string(kProtocolErrorCode), std::move(detail)};
}

VideoDecodeResult DecodeFailure(std::string detail)
{
    return {std::nullopt, std::string(kProtocolErrorCode), std::move(detail)};
}

} // namespace

bool VideoFrame::operator==(const VideoFrame& other) const
{
    return frameType == other.frameType && flags == other.flags && sequence == other.sequence
        && ptsUs == other.ptsUs && captureUs == other.captureUs && payload == other.payload;
}

VideoEncodeResult EncodeVideoFrame(const VideoFrame& frame)
{
    if (frame.payload.size() > kMaximumVideoPayloadSize
        || frame.payload.size() > std::numeric_limits<std::uint32_t>::max()) {
        return EncodeFailure("video payload exceeds 16 MiB");
    }
    const auto rawType = static_cast<std::uint8_t>(frame.frameType);
    if (rawType != 1 && rawType != 2) return EncodeFailure("invalid video frame type");
    std::vector<std::uint8_t> output;
    output.reserve(kVideoFrameHeaderSize + frame.payload.size());
    output.insert(output.end(), kMagic.begin(), kMagic.end());
    output.push_back(1);
    output.push_back(rawType);
    AppendNetwork(frame.flags, output);
    AppendNetwork(frame.sequence, output);
    AppendNetwork(frame.ptsUs, output);
    AppendNetwork(frame.captureUs, output);
    AppendNetwork(static_cast<std::uint32_t>(frame.payload.size()), output);
    output.insert(output.end(), frame.payload.begin(), frame.payload.end());
    return {std::move(output), "", ""};
}

VideoDecodeResult DecodeVideoFrame(const std::vector<std::uint8_t>& bytes)
{
    if (bytes.size() < kVideoFrameHeaderSize) return DecodeFailure("truncated video frame header");
    if (!std::equal(kMagic.begin(), kMagic.end(), bytes.begin())) return DecodeFailure("invalid video frame magic");
    if (bytes[4] != 1) return DecodeFailure("unsupported video frame version");
    if (bytes[5] != 1 && bytes[5] != 2) return DecodeFailure("invalid video frame type");
    const auto payloadLength = ReadNetwork<std::uint32_t>(bytes, 28);
    if (payloadLength > kMaximumVideoPayloadSize) return DecodeFailure("video payload exceeds 16 MiB");
    if (bytes.size() != kVideoFrameHeaderSize + static_cast<std::size_t>(payloadLength)) {
        return DecodeFailure("truncated or trailing video payload");
    }
    VideoFrame frame;
    frame.frameType = static_cast<VideoFrameType>(bytes[5]);
    frame.flags = ReadNetwork<std::uint16_t>(bytes, 6);
    frame.sequence = ReadNetwork<std::uint32_t>(bytes, 8);
    frame.ptsUs = ReadNetwork<std::uint64_t>(bytes, 12);
    frame.captureUs = ReadNetwork<std::uint64_t>(bytes, 20);
    frame.payload.assign(bytes.begin() + kVideoFrameHeaderSize, bytes.end());
    return {std::move(frame), "", ""};
}

} // namespace second_display::protocol

