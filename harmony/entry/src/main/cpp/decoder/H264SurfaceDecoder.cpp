#include "H264SurfaceDecoder.hpp"
#include "DecoderOutputPolicy.hpp"

#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avformat.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <limits>
#include <string_view>
#include <utility>

namespace second_display::decoder {
namespace {

bool Check(OH_AVErrCode value, std::string_view operation, std::string& error)
{
    if (value == AV_ERR_OK) return true;
    error = std::string(operation) + " failed with " + std::to_string(static_cast<int>(value));
    return false;
}

std::uint64_t MonotonicMicroseconds()
{
    return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

const char* MimeFor(H264SurfaceDecoder::Codec codec)
{
    return codec == H264SurfaceDecoder::Codec::HEVC
        ? OH_AVCODEC_MIMETYPE_VIDEO_HEVC
        : OH_AVCODEC_MIMETYPE_VIDEO_AVC;
}

bool SupportsHardwareLowLatencyDecoder(H264SurfaceDecoder::Codec codec)
{
    OH_AVCapability* capability = OH_AVCodec_GetCapabilityByCategory(
        MimeFor(codec), false, HARDWARE);
    return capability != nullptr
        && OH_AVCapability_IsFeatureSupported(capability, VIDEO_LOW_LATENCY);
}

} // namespace

H264SurfaceDecoder::H264SurfaceDecoder() = default;

H264SurfaceDecoder::~H264SurfaceDecoder()
{
    Stop();
}

bool H264SurfaceDecoder::Configure(
    OHNativeWindow* window,
    std::uint32_t width,
    std::uint32_t height,
    double framesPerSecond,
    Codec codec,
    std::uint64_t generation,
    std::string& error)
{
    Stop();
    const bool supportsLowLatency = SupportsHardwareLowLatencyDecoder(codec);
    if (ConfigureAttempt(
            window, width, height, framesPerSecond, codec, generation, supportsLowLatency, error)) {
        return true;
    }
    if (!supportsLowLatency) return false;

    // 某些厂商解码器虽声明低延迟能力，却会在特定分辨率或帧率下拒绝可选参数。
    // 此时无参数重建，保证优化能力不可用时仍能回退到兼容解码路径。
    Stop();
    error.clear();
    return ConfigureAttempt(window, width, height, framesPerSecond, codec, generation, false, error);
}

bool H264SurfaceDecoder::ConfigureAttempt(
    OHNativeWindow* window,
    std::uint32_t width,
    std::uint32_t height,
    double framesPerSecond,
    Codec streamCodec,
    std::uint64_t generation,
    bool enableLowLatency,
    std::string& error)
{
    if (window == nullptr || width == 0 || height == 0 || framesPerSecond <= 0
        || width > static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max())
        || height > static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max())) {
        error = "DECODER_FATAL: invalid decoder configuration";
        return false;
    }

    const char* mime = MimeFor(streamCodec);
    OH_AVCodec* codec = OH_VideoDecoder_CreateByMime(mime);
    if (codec == nullptr) {
        error = streamCodec == Codec::HEVC
            ? "DECODER_FATAL: unable to create HEVC decoder"
            : "DECODER_FATAL: unable to create H.264 decoder";
        return false;
    }
    {
        std::lock_guard lock(mutex_);
        codec_ = codec;
        generation_ = generation;
        // 回调上下文固定携带创建时的 generation，Stop 后到达的旧回调会被身份检查丢弃。
        callbackContext_ = std::make_unique<CallbackContext>(CallbackContext {this, generation});
        frames_.Reset();
        inputBuffers_.clear();
        submittedFrames_.clear();
    }

    OH_AVCodecCallback callbacks {
        .onError = OnError,
        .onStreamChanged = OnStreamChanged,
        .onNeedInputBuffer = OnNeedInputBuffer,
        .onNewOutputBuffer = OnNewOutputBuffer,
    };
    OH_AVFormat* format = OH_AVFormat_Create();
    if (format == nullptr) {
        error = "DECODER_FATAL: unable to create decoder format";
        Stop();
        return false;
    }
    const bool lowLatencyEnabled = enableLowLatency
        && OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
    const bool formatValid = OH_AVFormat_SetStringValue(format, OH_MD_KEY_CODEC_MIME, mime)
        && OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, static_cast<std::int32_t>(width))
        && OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, static_cast<std::int32_t>(height))
        && OH_AVFormat_SetDoubleValue(format, OH_MD_KEY_FRAME_RATE, framesPerSecond)
        && OH_AVFormat_SetIntValue(format, OH_MD_KEY_MAX_INPUT_SIZE,
            static_cast<std::int32_t>(protocol::kMaximumVideoPayloadSize));
    if (!formatValid
        || !Check(OH_VideoDecoder_RegisterCallback(codec, callbacks, callbackContext_.get()),
            "register callback", error)
        || !Check(OH_VideoDecoder_Configure(codec, format), "configure decoder", error)
        || !Check(OH_VideoDecoder_SetSurface(codec, window), "set decoder surface", error)
        || !Check(OH_VideoDecoder_Prepare(codec), "prepare decoder", error)) {
        OH_AVFormat_Destroy(format);
        if (error.rfind("DECODER_FATAL", 0) != 0) error = "DECODER_FATAL: " + error;
        Stop();
        return false;
    }
    OH_AVFormat_Destroy(format);
    bool generationChanged = false;
    {
        std::lock_guard lock(mutex_);
        if (codec_ != codec || generation_ != generation) {
            error = "DECODER_FATAL: decoder generation changed during configure";
            generationChanged = true;
        } else {
            running_ = true;
            lowLatencyEnabled_ = lowLatencyEnabled;
        }
    }
    if (generationChanged) {
        Stop();
        return false;
    }
    if (!Check(OH_VideoDecoder_Start(codec), "start decoder", error)) {
        error = "DECODER_FATAL: " + error;
        Stop();
        return false;
    }
    return true;
}

DecoderQueueResult H264SurfaceDecoder::Submit(protocol::VideoFrame frame, std::uint64_t nowUs)
{
    KeyFrameRequest request;
    FatalErrorHandler fatal;
    std::optional<std::string> fatalMessage;
    DecoderQueueResult result;
    {
        std::lock_guard lock(mutex_);
        if (!running_ || codec_ == nullptr) return {false, 1, true, false};
        // 解码器回调可能已交付可写输入缓冲：先消费它们，再应用两帧入口上限，
        // 避免把 TCP 的短时聚合误判为真实解码背压。
        fatalMessage = DrainLocked();
        if (fatalMessage.has_value()) {
            result = {false, 1, false, false};
            fatal = fatalError_;
        } else {
            result = frames_.Enqueue(std::move(frame), nowUs);
            if (result.requestKeyFrame) request = requestKeyFrame_;
            fatalMessage = DrainLocked();
            if (fatalMessage.has_value()) fatal = fatalError_;
        }
    }
    if (request) request(result.resetDecoder);
    if (fatal && fatalMessage.has_value()) fatal(*fatalMessage);
    return result;
}

void H264SurfaceDecoder::Stop()
{
    OH_AVCodec* codec = nullptr;
    std::unique_ptr<CallbackContext> callbackContext;
    {
        std::lock_guard lock(mutex_);
        // 先推进 generation 并清空队列，再停止底层解码器，防止异步输出回调复活旧会话。
        generation_ += 1;
        running_ = false;
        frames_.Reset();
        inputBuffers_.clear();
        submittedFrames_.clear();
        lowLatencyEnabled_ = false;
        codec = codec_;
        codec_ = nullptr;
        callbackContext = std::move(callbackContext_);
    }
    if (codec != nullptr) {
        OH_VideoDecoder_Stop(codec);
        OH_VideoDecoder_Destroy(codec);
    }
}

bool H264SurfaceDecoder::IsRunning() const
{
    std::lock_guard lock(mutex_);
    return running_;
}

std::uint64_t H264SurfaceDecoder::Generation() const
{
    std::lock_guard lock(mutex_);
    return generation_;
}

H264SurfaceDecoder::Statistics H264SurfaceDecoder::GetStatistics() const
{
    std::lock_guard lock(mutex_);
    return {decodedFrames_, renderedFrames_, staleOutputDrops_, lastInputQueueLatencyUs_,
        lastDecodeLatencyUs_, lastOutputLatencyUs_, submittedFrames_.size(),
        lowLatencyEnabled_, true};
}

void H264SurfaceDecoder::ResetStatistics()
{
    std::lock_guard lock(mutex_);
    decodedFrames_ = 0;
    renderedFrames_ = 0;
    staleOutputDrops_ = 0;
    lastInputQueueLatencyUs_ = 0;
    lastDecodeLatencyUs_ = 0;
    lastOutputLatencyUs_ = 0;
}

void H264SurfaceDecoder::SetKeyFrameRequestHandler(KeyFrameRequest handler)
{
    std::lock_guard lock(mutex_);
    requestKeyFrame_ = std::move(handler);
}

void H264SurfaceDecoder::SetFatalErrorHandler(FatalErrorHandler handler)
{
    std::lock_guard lock(mutex_);
    fatalError_ = std::move(handler);
}

void H264SurfaceDecoder::OnError(OH_AVCodec* codec, std::int32_t errorCode, void* userData)
{
    const auto* context = static_cast<CallbackContext*>(userData);
    if (context != nullptr && context->owner != nullptr) {
        context->owner->HandleError(codec, errorCode, context->generation);
    }
}

void H264SurfaceDecoder::OnStreamChanged(OH_AVCodec*, OH_AVFormat*, void*)
{
}

void H264SurfaceDecoder::OnNeedInputBuffer(
    OH_AVCodec* codec, std::uint32_t index, OH_AVBuffer* buffer, void* userData)
{
    const auto* context = static_cast<CallbackContext*>(userData);
    if (context != nullptr && context->owner != nullptr) {
        context->owner->HandleInput(codec, index, buffer, context->generation);
    }
}

void H264SurfaceDecoder::OnNewOutputBuffer(
    OH_AVCodec* codec, std::uint32_t index, OH_AVBuffer* buffer, void* userData)
{
    const auto* context = static_cast<CallbackContext*>(userData);
    if (context != nullptr && context->owner != nullptr) {
        context->owner->HandleOutput(codec, index, buffer, context->generation);
    }
}

void H264SurfaceDecoder::HandleError(
    OH_AVCodec* codec, std::int32_t errorCode, std::uint64_t generation)
{
    FatalErrorHandler handler;
    {
        std::lock_guard lock(mutex_);
        if (codec != codec_ || generation != generation_) return;
        running_ = false;
        handler = fatalError_;
    }
    if (handler) handler("DECODER_FATAL: OH_VideoDecoder error " + std::to_string(errorCode));
}

void H264SurfaceDecoder::HandleInput(
    OH_AVCodec* codec, std::uint32_t index, OH_AVBuffer* buffer, std::uint64_t generation)
{
    FatalErrorHandler fatal;
    std::optional<std::string> fatalMessage;
    {
        std::lock_guard lock(mutex_);
        if (codec != codec_ || generation != generation_ || !running_ || buffer == nullptr) return;
        inputBuffers_.push_back({index, buffer});
        fatalMessage = DrainLocked();
        if (fatalMessage.has_value()) fatal = fatalError_;
    }
    if (fatal && fatalMessage.has_value()) fatal(*fatalMessage);
}

void H264SurfaceDecoder::HandleOutput(
    OH_AVCodec* codec, std::uint32_t index, OH_AVBuffer* buffer, std::uint64_t generation)
{
    FatalErrorHandler fatal;
    std::string message;
    {
        std::lock_guard lock(mutex_);
        if (codec != codec_ || generation != generation_ || !running_ || buffer == nullptr) return;
        OH_AVCodecBufferAttr attributes {};
        const bool hasAttributes = OH_AVBuffer_GetBufferAttr(buffer, &attributes) == AV_ERR_OK;
        auto submitted = submittedFrames_.end();
        if (hasAttributes) {
            submitted = std::find_if(submittedFrames_.begin(), submittedFrames_.end(),
                [&attributes](const SubmittedFrame& frame) { return frame.ptsUs == attributes.pts; });
        }
        if (submitted == submittedFrames_.end() && !submittedFrames_.empty()) {
            submitted = submittedFrames_.begin();
        }
        std::uint64_t latencyUs = 0;
        std::uint64_t decodeLatencyUs = 0;
        if (submitted != submittedFrames_.end()) {
            const auto nowUs = MonotonicMicroseconds();
            if (nowUs >= submitted->receivedAtUs) latencyUs = nowUs - submitted->receivedAtUs;
            if (nowUs >= submitted->submittedAtUs) decodeLatencyUs = nowUs - submitted->submittedAtUs;
            submittedFrames_.erase(submitted);
        }
        decodedFrames_ += 1;
        lastDecodeLatencyUs_ = decodeLatencyUs;
        lastOutputLatencyUs_ = latencyUs;
        const bool hasNewerFrame = !submittedFrames_.empty() || frames_.Size() > 0;
        // 已经过期且后方有更新画面时直接释放输出，优先保障交互时延而不是完整播放每一帧。
        const auto decision = DecideDecoderOutput(latencyUs, kMaximumOutputAgeUs, hasNewerFrame);
        const auto result = decision.render
            ? OH_VideoDecoder_RenderOutputBuffer(codec, index)
            : OH_VideoDecoder_FreeOutputBuffer(codec, index);
        if (result == AV_ERR_OK) {
            if (!decision.render) {
                staleOutputDrops_ += 1;
            } else {
                renderedFrames_ += 1;
            }
            const auto drainError = DrainLocked();
            if (drainError.has_value()) {
                running_ = false;
                fatal = fatalError_;
                message = *drainError;
            }
        } else {
            running_ = false;
            fatal = fatalError_;
            message = std::string("DECODER_FATAL: ")
                + (decision.render ? "render output failed with " : "free stale output failed with ")
                + std::to_string(static_cast<int>(result));
        }
    }
    if (fatal) fatal(std::move(message));
}

std::optional<std::string> H264SurfaceDecoder::DrainLocked()
{
    while (running_ && codec_ != nullptr && !inputBuffers_.empty()
        && submittedFrames_.size() < kMaximumInFlightFrames) {
        auto frame = frames_.Pop();
        if (!frame.has_value()) return std::nullopt;
        const auto input = inputBuffers_.front();
        inputBuffers_.pop_front();
        const auto capacity = OH_AVBuffer_GetCapacity(input.buffer);
        auto* destination = OH_AVBuffer_GetAddr(input.buffer);
        if (capacity < 0 || destination == nullptr
            || frame->frame.payload.size() > static_cast<std::size_t>(capacity)
            || frame->frame.payload.size() > static_cast<std::size_t>(std::numeric_limits<std::int32_t>::max())) {
            running_ = false;
            return "DECODER_FATAL: decoder input buffer is invalid or too small";
        }
        std::memcpy(destination, frame->frame.payload.data(), frame->frame.payload.size());
        OH_AVCodecBufferAttr attributes {
            .pts = static_cast<std::int64_t>(frame->frame.ptsUs),
            .size = static_cast<std::int32_t>(frame->frame.payload.size()),
            .offset = 0,
            .flags = (frame->frame.flags & 1U) != 0 ? AVCODEC_BUFFER_FLAGS_SYNC_FRAME : AVCODEC_BUFFER_FLAGS_NONE,
        };
        if (frame->frame.frameType == protocol::VideoFrameType::CodecConfig) {
            attributes.flags |= AVCODEC_BUFFER_FLAGS_CODEC_DATA;
        }
        if (OH_AVBuffer_SetBufferAttr(input.buffer, &attributes) != AV_ERR_OK) {
            running_ = false;
            return "DECODER_FATAL: unable to submit decoder input buffer";
        }
        const auto submittedAtUs = MonotonicMicroseconds();
        lastInputQueueLatencyUs_ = submittedAtUs >= frame->receivedAtUs
            ? submittedAtUs - frame->receivedAtUs : 0;
        submittedFrames_.push_back({attributes.pts, frame->receivedAtUs, submittedAtUs});
        if (OH_VideoDecoder_PushInputBuffer(codec_, input.index) != AV_ERR_OK) {
            submittedFrames_.pop_back();
            running_ = false;
            return "DECODER_FATAL: unable to submit decoder input buffer";
        }
    }
    return std::nullopt;
}

} // namespace second_display::decoder
