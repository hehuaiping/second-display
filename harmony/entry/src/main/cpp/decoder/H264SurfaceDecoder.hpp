#pragma once

#include "DecoderFrameQueue.hpp"
#include "LatencyWindow.hpp"

#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

struct OH_AVBuffer;
struct OH_AVCodec;
struct OH_AVFormat;
struct NativeWindow;
typedef struct NativeWindow OHNativeWindow;

namespace second_display::decoder {

class H264SurfaceDecoder {
public:
    enum class Codec {
        H264,
        HEVC,
    };

    struct Statistics {
        std::uint64_t decodedFrames = 0;
        std::uint64_t renderedFrames = 0;
        std::uint64_t staleOutputDrops = 0;
        std::uint64_t lastInputQueueLatencyUs = 0;
        std::uint64_t lastDecodeLatencyUs = 0;
        std::uint64_t lastOutputLatencyUs = 0;
        std::uint64_t decodeOutputP95Us = 0;
        std::size_t inFlightFrames = 0;
        bool lowLatencyEnabled = false;
        bool immediateRenderingEnabled = true;
        bool timedRenderingEnabled = false;
        bool boundedBufferCountsEnabled = false;
    };

    using KeyFrameRequest = std::function<void(bool resetDecoder)>;
    using FatalErrorHandler = std::function<void(std::string)>;

    H264SurfaceDecoder();
    ~H264SurfaceDecoder();
    H264SurfaceDecoder(const H264SurfaceDecoder&) = delete;
    H264SurfaceDecoder& operator=(const H264SurfaceDecoder&) = delete;

    bool Configure(
        OHNativeWindow* window,
        std::uint32_t width,
        std::uint32_t height,
        double framesPerSecond,
        Codec codec,
        std::uint64_t generation,
        std::string& error);
    DecoderQueueResult Submit(protocol::VideoFrame frame, std::uint64_t nowUs);
    void Stop();
    bool IsRunning() const;
    std::uint64_t Generation() const;
    Statistics GetStatistics() const;
    void ResetStatistics();
    void SetKeyFrameRequestHandler(KeyFrameRequest handler);
    void SetFatalErrorHandler(FatalErrorHandler handler);

private:
    struct InputBuffer {
        std::uint32_t index = 0;
        OH_AVBuffer* buffer = nullptr;
    };

    struct SubmittedFrame {
        std::int64_t ptsUs = 0;
        std::uint64_t receivedAtUs = 0;
        std::uint64_t submittedAtUs = 0;
    };

    struct CallbackContext {
        H264SurfaceDecoder* owner = nullptr;
        std::uint64_t generation = 0;
    };

    static void OnError(OH_AVCodec* codec, std::int32_t errorCode, void* userData);
    static void OnStreamChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData);
    static void OnNeedInputBuffer(OH_AVCodec* codec, std::uint32_t index, OH_AVBuffer* buffer, void* userData);
    static void OnNewOutputBuffer(OH_AVCodec* codec, std::uint32_t index, OH_AVBuffer* buffer, void* userData);

    void HandleError(OH_AVCodec* codec, std::int32_t errorCode, std::uint64_t generation);
    void HandleInput(
        OH_AVCodec* codec, std::uint32_t index, OH_AVBuffer* buffer, std::uint64_t generation);
    void HandleOutput(
        OH_AVCodec* codec, std::uint32_t index, OH_AVBuffer* buffer, std::uint64_t generation);
    bool ConfigureAttempt(
        OHNativeWindow* window,
        std::uint32_t width,
        std::uint32_t height,
        double framesPerSecond,
        Codec codec,
        std::uint64_t generation,
        bool enableLowLatency,
        std::string& error);
    std::optional<std::string> DrainLocked();

    mutable std::mutex mutex_;
    OH_AVCodec* codec_ = nullptr;
    std::unique_ptr<CallbackContext> callbackContext_;
    DecoderFrameQueue frames_;
    std::deque<InputBuffer> inputBuffers_;
    std::deque<SubmittedFrame> submittedFrames_;
    std::uint64_t generation_ = 0;
    bool running_ = false;
    std::uint64_t decodedFrames_ = 0;
    std::uint64_t renderedFrames_ = 0;
    std::uint64_t staleOutputDrops_ = 0;
    std::uint64_t lastInputQueueLatencyUs_ = 0;
    std::uint64_t lastDecodeLatencyUs_ = 0;
    std::uint64_t lastOutputLatencyUs_ = 0;
    LatencyWindow<256> decodeOutputLatenciesUs_;
    std::uint64_t maximumOutputAgeUs_ = 25000;
    bool lowLatencyEnabled_ = false;
    bool timedRenderingEnabled_ = false;
    bool boundedBufferCountsEnabled_ = false;
    KeyFrameRequest requestKeyFrame_;
    FatalErrorHandler fatalError_;

    // 低于五帧会让 Mate 60 Pro 的硬件解码流水线退化到约 30 FPS；入口队列仍保持
    // 两帧 latest-wins，过期输出只在后方至少积压两帧时释放。
    static constexpr std::size_t kMaximumInFlightFrames = 5;
};

} // namespace second_display::decoder
