#include "DecoderFrameQueue.hpp"

#include <utility>

namespace second_display::decoder {

DecoderFrameQueue::DecoderFrameQueue(std::size_t capacity, std::uint64_t maximumAgeUs)
    : capacity_(capacity), maximumAgeUs_(maximumAgeUs)
{
}

DecoderQueueResult DecoderFrameQueue::Enqueue(protocol::VideoFrame frame, std::uint64_t nowUs)
{
    const bool keyFrame = IsKeyFrame(frame);
    if (!frames_.empty() && nowUs >= frames_.front().receivedAtUs
        && nowUs - frames_.front().receivedAtUs > maximumAgeUs_) {
        const auto dropped = frames_.size() + 1;
        frames_.clear();
        waitingForKeyFrame_ = true;
        // Backlog is a stream discontinuity, not a fatal decoder failure. Keep
        // the active codec/reference state alive and wait for a fresh IDR.
        return {false, dropped, true, false};
    }
    if (waitingForKeyFrame_ && !keyFrame) return {false, 1, true, false};
    if (keyFrame) {
        const auto dropped = frames_.size();
        frames_.clear();
        waitingForKeyFrame_ = false;
        frames_.push_back({std::move(frame), nowUs});
        return {true, dropped, false, false};
    }
    if (capacity_ == 0 || frames_.size() >= capacity_) {
        const auto dropped = frames_.size() + 1;
        frames_.clear();
        waitingForKeyFrame_ = true;
        return {false, dropped, true, false};
    }
    frames_.push_back({std::move(frame), nowUs});
    return {true, 0, false, false};
}

std::optional<DecoderQueuedFrame> DecoderFrameQueue::Pop()
{
    if (frames_.empty()) return std::nullopt;
    auto frame = std::move(frames_.front());
    frames_.pop_front();
    return frame;
}

std::size_t DecoderFrameQueue::DropUntilKeyFrame()
{
    const auto dropped = frames_.size();
    frames_.clear();
    waitingForKeyFrame_ = true;
    return dropped;
}

void DecoderFrameQueue::Reset()
{
    frames_.clear();
    waitingForKeyFrame_ = true;
}

bool DecoderFrameQueue::IsKeyFrame(const protocol::VideoFrame& frame)
{
    return (frame.flags & 1U) != 0;
}

} // namespace second_display::decoder
