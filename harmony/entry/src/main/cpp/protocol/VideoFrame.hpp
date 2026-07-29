#pragma once

#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace second_display::protocol {

inline constexpr std::size_t kVideoFrameHeaderSize = 32;
inline constexpr std::size_t kMaximumVideoPayloadSize = 16 * 1024 * 1024;

enum class VideoFrameType : std::uint8_t { Video = 1, CodecConfig = 2 };

class VideoPayload {
public:
    using Storage = std::vector<std::uint8_t>;
    using const_iterator = const std::uint8_t*;

    VideoPayload() = default;
    VideoPayload(std::initializer_list<std::uint8_t> bytes);
    VideoPayload(const Storage& bytes);
    VideoPayload(Storage&& bytes);

    VideoPayload& operator=(const Storage& bytes);
    VideoPayload& operator=(Storage&& bytes);

    static std::optional<VideoPayload> SharedSlice(
        std::shared_ptr<const Storage> storage, std::size_t offset, std::size_t size);

    std::size_t size() const { return size_; }
    bool empty() const { return size_ == 0; }
    const std::uint8_t* data() const;
    const_iterator begin() const { return data(); }
    const_iterator end() const { return data() + size_; }
    std::uint8_t operator[](std::size_t index) const { return data()[index]; }
    bool CopyTo(std::uint8_t* destination, std::size_t capacity) const;
    bool SharesStorageWith(const VideoPayload& other) const;
    bool operator==(const VideoPayload& other) const;

private:
    VideoPayload(
        std::shared_ptr<const Storage> storage, std::size_t offset, std::size_t size);
    void AssignOwned(Storage bytes);

    std::shared_ptr<const Storage> storage_;
    std::size_t offset_ = 0;
    std::size_t size_ = 0;
};

struct VideoFrame {
    VideoFrameType frameType = VideoFrameType::Video;
    std::uint16_t flags = 0;
    std::uint32_t sequence = 0;
    std::uint64_t ptsUs = 0;
    std::uint64_t captureUs = 0;
    VideoPayload payload;

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
