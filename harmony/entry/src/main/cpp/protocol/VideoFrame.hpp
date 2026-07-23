#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace second_display::protocol {

inline constexpr std::size_t kVideoFrameHeaderSize = 32;
inline constexpr std::size_t kMaximumVideoPayloadSize = 16 * 1024 * 1024;

enum class VideoFrameType : std::uint8_t { Video = 1, CodecConfig = 2 };

struct VideoFrame {
    VideoFrameType frameType = VideoFrameType::Video;
    std::uint16_t flags = 0;
    std::uint32_t sequence = 0;
    std::uint64_t ptsUs = 0;
    std::uint64_t captureUs = 0;
    std::vector<std::uint8_t> payload;

    bool operator==(const VideoFrame& other) const;
};

struct VideoEncodeResult {
    std::optional<std::vector<std::uint8_t>> bytes;
    std::string errorCode;
    std::string detail;
};

struct VideoDecodeResult {
    std::optional<VideoFrame> frame;
    std::string errorCode;
    std::string detail;
};

VideoEncodeResult EncodeVideoFrame(const VideoFrame& frame);
VideoDecodeResult DecodeVideoFrame(const std::vector<std::uint8_t>& bytes);

} // namespace second_display::protocol

