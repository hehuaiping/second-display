#pragma once

#include "protocol/VideoFrame.hpp"

#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>

namespace second_display::decoder {

struct DecoderQueueResult {
    bool accepted = false;
    std::size_t droppedFrames = 0;
    bool requestKeyFrame = false;
    bool resetDecoder = false;
};

struct DecoderQueuedFrame {
    protocol::VideoFrame frame;
    std::uint64_t receivedAtUs = 0;
};

class DecoderFrameQueue {
public:
    explicit DecoderFrameQueue(std::size_t capacity = 2, std::uint64_t maximumAgeUs = 120000);
    DecoderQueueResult Enqueue(protocol::VideoFrame frame, std::uint64_t nowUs);
    std::optional<DecoderQueuedFrame> Pop();
    std::size_t DropUntilKeyFrame();
    void Reset();
    std::size_t Size() const { return frames_.size(); }
    bool WaitingForKeyFrame() const { return waitingForKeyFrame_; }

private:
    static bool IsKeyFrame(const protocol::VideoFrame& frame);

    std::size_t capacity_;
    std::uint64_t maximumAgeUs_;
    std::deque<DecoderQueuedFrame> frames_;
    bool waitingForKeyFrame_ = true;
};

} // namespace second_display::decoder
