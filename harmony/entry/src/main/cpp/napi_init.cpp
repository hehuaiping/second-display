#include "decoder/H264SurfaceDecoder.hpp"
#if defined(SECOND_DISPLAY_ENABLE_DIAGNOSTICS)
#include "TestVectorData.hpp"
#endif
#include "transport/FrameParser.hpp"

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <napi/native_api.h>

#include <algorithm>
#include <cstdint>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

struct DecoderStatus {
    std::string code;
    bool running = false;
    std::uint64_t generation = 0;
    std::uint64_t testFrames = 0;
    std::uint64_t droppedFrames = 0;
    std::uint64_t networkFrames = 0;
    std::uint64_t decodedFrames = 0;
    std::uint64_t renderedFrames = 0;
    std::uint64_t staleOutputDrops = 0;
    std::uint64_t inputQueueLatencyUs = 0;
    std::uint64_t decodeLatencyUs = 0;
    std::uint64_t outputLatencyUs = 0;
    std::uint64_t decoderInFlight = 0;
    std::uint64_t keyFrameRequests = 0;
    std::uint64_t decoderRecoveries = 0;
    bool lowLatencyEnabled = false;
    bool immediateRenderingEnabled = true;
};

class ReceiverRuntime {
public:
    ReceiverRuntime()
    {
        decoder_.SetKeyFrameRequestHandler(
            [this](bool) { RecordKeyFrameRequest(); });
        decoder_.SetFatalErrorHandler([this](std::string error) { RecordFatal(std::move(error)); });
    }

    ~ReceiverRuntime()
    {
        StopTestPlayer();
        decoder_.Stop();
    }

    void SurfaceCreated(void* window)
    {
        SetSurface(static_cast<OHNativeWindow*>(window));
    }

    void SurfaceChanged(void* window)
    {
        SetSurface(static_cast<OHNativeWindow*>(window));
    }

    void SurfaceDestroyed(void* window)
    {
        StopTestPlayer();
        {
            std::lock_guard lock(stateMutex_);
            if (window_ != static_cast<OHNativeWindow*>(window)) return;
            window_ = nullptr;
            generation_ += 1;
            keyFrameRequestPending_ = false;
            statusCode_ = "WAITING_SURFACE";
        }
        std::lock_guard operationLock(operationMutex_);
        decoder_.Stop();
    }

    void Restart()
    {
        StopTestPlayer();
        OHNativeWindow* window = nullptr;
        {
            std::lock_guard lock(stateMutex_);
            window = window_;
        }
        SetSurface(window);
    }

    void Stop()
    {
        StopTestPlayer();
        {
            std::lock_guard lock(stateMutex_);
            generation_ += 1;
            keyFrameRequestPending_ = false;
            statusCode_ = window_ == nullptr ? "WAITING_SURFACE" : "STOPPED";
        }
        std::lock_guard operationLock(operationMutex_);
        decoder_.Stop();
    }

    DecoderStatus Status() const
    {
        const auto decoderStatistics = decoder_.GetStatistics();
        std::lock_guard lock(stateMutex_);
        return {
            statusCode_, decoder_.IsRunning(), generation_, testFrames_,
            droppedFrames_ + decoderStatistics.staleOutputDrops, networkFrames_,
            decoderStatistics.decodedFrames, decoderStatistics.renderedFrames,
            decoderStatistics.staleOutputDrops, decoderStatistics.lastInputQueueLatencyUs,
            decoderStatistics.lastDecodeLatencyUs, decoderStatistics.lastOutputLatencyUs,
            decoderStatistics.inFlightFrames, keyFrameRequests_, decoderRecoveries_,
            decoderStatistics.lowLatencyEnabled, decoderStatistics.immediateRenderingEnabled};
    }

    void BeginVideoSession(
        const std::string& sessionId,
        std::uint32_t width,
        std::uint32_t height,
        double framesPerSecond,
        second_display::decoder::H264SurfaceDecoder::Codec codec)
    {
        StopTestPlayer();
        if (sessionId.empty() || sessionId.size() > 128 || std::min(width, height) < 600U
            || std::max(width, height) < 800U
            || width > 8192U || height > 8192U || width % 2U != 0 || height % 2U != 0
            || !std::isfinite(framesPerSecond) || framesPerSecond < 1.0 || framesPerSecond > 120.0) {
            RecordProtocolError("invalid video session configuration");
            return;
        }
        {
            std::lock_guard parserLock(parserMutex_);
            videoSessionId_ = sessionId;
            parser_.BeginSession(sessionId);
        }
        OHNativeWindow* window = nullptr;
        std::uint64_t generation = 0;
        {
            std::lock_guard lock(stateMutex_);
            decoderWidth_ = width;
            decoderHeight_ = height;
            decoderFramesPerSecond_ = framesPerSecond;
            decoderCodec_ = codec;
            window = window_;
            generation_ += 1;
            generation = generation_;
            networkFrames_ = 0;
            droppedFrames_ = 0;
            keyFrameRequestPending_ = false;
            keyFrameRequests_ = 0;
            decoderRecoveries_ = 0;
            statusCode_ = window == nullptr ? "WAITING_SURFACE" : "CONFIGURING";
        }
        if (window == nullptr) return;

        std::string error;
        bool configured = false;
        {
            std::lock_guard operationLock(operationMutex_);
            decoder_.ResetStatistics();
            configured = decoder_.Configure(window, width, height, framesPerSecond, codec, generation, error);
        }
        std::lock_guard lock(stateMutex_);
        if (generation != generation_ || window != window_) return;
        statusCode_ = configured ? "STREAM_READY" : std::move(error);
    }

    void FeedVideoBytes(const std::string& sessionId, const std::uint8_t* bytes, std::size_t size)
    {
        second_display::transport::FrameParserResult parsed;
        {
            std::lock_guard parserLock(parserMutex_);
            if (sessionId != videoSessionId_) {
                RecordProtocolError("video data belongs to an old session");
                return;
            }
            parsed = parser_.Feed(sessionId, bytes, size);
        }
        if (!parsed.Ok()) {
            RecordProtocolError(parsed.detail);
            return;
        }
        for (auto& frame : parsed.frames) {
            const bool keyFrame = (frame.flags & 1U) != 0;
            const auto nowUs = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count());
            const auto result = decoder_.Submit(std::move(frame), nowUs);
            {
                std::lock_guard lock(stateMutex_);
                if (result.accepted) networkFrames_ += 1;
                droppedFrames_ += result.droppedFrames;
                if (result.accepted && keyFrame) {
                    keyFrameRequestPending_ = false;
                    if (decoder_.IsRunning()) statusCode_ = "STREAM_READY";
                }
            }
        }
    }

    void FinishVideoSession(const std::string& sessionId)
    {
        second_display::transport::FrameParserResult result;
        {
            std::lock_guard parserLock(parserMutex_);
            result = parser_.Finish(sessionId);
            videoSessionId_.clear();
        }
        if (!result.Ok()) RecordProtocolError(result.detail);
    }

    void StartTestPlayer(std::uint32_t durationSeconds)
    {
#if defined(SECOND_DISPLAY_ENABLE_DIAGNOSTICS)
        StopTestPlayer();
        if (durationSeconds == 0 || durationSeconds > 24U * 60U * 60U) {
            std::lock_guard lock(stateMutex_);
            statusCode_ = "DECODER_FATAL: invalid soak duration";
            return;
        }
        std::uint64_t generation = 0;
        {
            std::lock_guard lock(stateMutex_);
            if (window_ == nullptr || !decoder_.IsRunning()) {
                statusCode_ = "DECODER_FATAL: decoder surface is not ready";
                return;
            }
            generation = generation_;
            testFrames_ = 0;
            droppedFrames_ = 0;
            statusCode_ = "SOAK_RUNNING";
        }
        testStop_.store(false);
        testThread_ = std::thread([this, durationSeconds, generation] {
            PlayTestVector(durationSeconds, generation);
        });
#else
        (void)durationSeconds;
#endif
    }

    void StopTestPlayer()
    {
#if defined(SECOND_DISPLAY_ENABLE_DIAGNOSTICS)
        testStop_.store(true);
        testCondition_.notify_all();
        if (testThread_.joinable() && testThread_.get_id() != std::this_thread::get_id()) {
            testThread_.join();
        }
#endif
    }

    void RecordRegistrationFailure()
    {
        std::lock_guard lock(stateMutex_);
        statusCode_ = "DECODER_FATAL: unable to register XComponent callbacks";
    }

    void RecordProtocolError(std::string detail)
    {
        std::lock_guard lock(stateMutex_);
        statusCode_ = "NET_PROTOCOL_MISMATCH: " + std::move(detail);
    }

private:
    void SetSurface(OHNativeWindow* window)
    {
        StopTestPlayer();
        std::uint64_t generation = 0;
        std::uint32_t width = 0;
        std::uint32_t height = 0;
        double framesPerSecond = 0;
        second_display::decoder::H264SurfaceDecoder::Codec codec =
            second_display::decoder::H264SurfaceDecoder::Codec::H264;
        {
            std::lock_guard lock(stateMutex_);
            window_ = window;
            generation_ += 1;
            keyFrameRequestPending_ = false;
            generation = generation_;
            width = decoderWidth_;
            height = decoderHeight_;
            framesPerSecond = decoderFramesPerSecond_;
            codec = decoderCodec_;
            statusCode_ = window == nullptr ? "WAITING_SURFACE" : "CONFIGURING";
        }
        if (window == nullptr) return;

        std::string error;
        bool configured = false;
        {
            std::lock_guard operationLock(operationMutex_);
            configured = decoder_.Configure(window, width, height, framesPerSecond, codec, generation, error);
        }
        std::lock_guard lock(stateMutex_);
        if (generation != generation_ || window != window_) return;
        statusCode_ = configured ? "READY" : std::move(error);
    }

    void RecordKeyFrameRequest()
    {
        std::lock_guard lock(stateMutex_);
        if (window_ == nullptr) return;
        if (!keyFrameRequestPending_) {
            keyFrameRequestPending_ = true;
            keyFrameRequests_ += 1;
        }
        statusCode_ = "REQUEST_KEY_FRAME";
    }

    void RecordFatal(std::string error)
    {
        std::lock_guard lock(stateMutex_);
        if (decoder_.Generation() == generation_) statusCode_ = std::move(error);
    }

#if defined(SECOND_DISPLAY_ENABLE_DIAGNOSTICS)
    static std::vector<std::vector<std::uint8_t>> TestAccessUnits()
    {
        using second_display::decoder::kH264TestVector;
        using second_display::decoder::kH264TestVectorSize;
        std::vector<std::size_t> starts;
        for (std::size_t index = 0; index + 4 <= kH264TestVectorSize; ++index) {
            if (kH264TestVector[index] == 0 && kH264TestVector[index + 1] == 0
                && kH264TestVector[index + 2] == 0 && kH264TestVector[index + 3] == 1) {
                starts.push_back(index);
                index += 3;
            }
        }
        if (starts.size() < 5) return {};
        std::vector<std::vector<std::uint8_t>> units;
        const std::size_t firstEnd = starts[4];
        units.emplace_back(kH264TestVector, kH264TestVector + firstEnd);
        for (std::size_t index = 4; index < starts.size(); ++index) {
            const std::size_t end = index + 1 < starts.size() ? starts[index + 1] : kH264TestVectorSize;
            units.emplace_back(kH264TestVector + starts[index], kH264TestVector + end);
        }
        return units;
    }

    void PlayTestVector(std::uint32_t durationSeconds, std::uint64_t generation)
    {
        const auto units = TestAccessUnits();
        if (units.empty()) {
            RecordFatal("DECODER_FATAL: embedded H.264 vector is invalid");
            return;
        }
        const auto started = std::chrono::steady_clock::now();
        auto deadline = started;
        std::uint32_t sequence = 0;
        while (!testStop_.load()
            && std::chrono::steady_clock::now() - started < std::chrono::seconds(durationSeconds)) {
            {
                std::lock_guard lock(stateMutex_);
                if (generation != generation_) return;
            }
            const std::size_t unitIndex = sequence % units.size();
            const auto nowUs = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count());
            second_display::protocol::VideoFrame frame;
            frame.flags = unitIndex == 0 ? 1U : 0U;
            frame.sequence = sequence;
            frame.ptsUs = static_cast<std::uint64_t>(sequence) * 16667U;
            frame.captureUs = nowUs;
            frame.payload = units[unitIndex];
            const auto result = decoder_.Submit(std::move(frame), nowUs);
            {
                std::lock_guard lock(stateMutex_);
                if (generation != generation_) return;
                if (result.accepted) testFrames_ += 1;
                droppedFrames_ += result.droppedFrames;
            }
            sequence += 1;
            deadline += std::chrono::microseconds(16667);
            std::unique_lock waitLock(testMutex_);
            testCondition_.wait_until(waitLock, deadline, [this] { return testStop_.load(); });
        }
        std::lock_guard lock(stateMutex_);
        if (generation == generation_ && !testStop_.load()) statusCode_ = "SOAK_COMPLETE";
    }
#endif

    mutable std::mutex stateMutex_;
    std::mutex operationMutex_;
    second_display::decoder::H264SurfaceDecoder decoder_;
    OHNativeWindow* window_ = nullptr;
    std::uint64_t generation_ = 0;
    std::string statusCode_ = "WAITING_SURFACE";
#if defined(SECOND_DISPLAY_ENABLE_DIAGNOSTICS)
    std::atomic<bool> testStop_ = true;
    std::mutex testMutex_;
    std::condition_variable testCondition_;
    std::thread testThread_;
#endif
    std::uint64_t testFrames_ = 0;
    std::uint64_t droppedFrames_ = 0;
    std::uint64_t networkFrames_ = 0;
    bool keyFrameRequestPending_ = false;
    std::uint64_t keyFrameRequests_ = 0;
    std::uint64_t decoderRecoveries_ = 0;
    std::uint32_t decoderWidth_ = 1920;
    std::uint32_t decoderHeight_ = 1200;
    double decoderFramesPerSecond_ = 60.0;
    second_display::decoder::H264SurfaceDecoder::Codec decoderCodec_ =
        second_display::decoder::H264SurfaceDecoder::Codec::H264;
    std::mutex parserMutex_;
    second_display::transport::FrameParser parser_;
    std::string videoSessionId_;
};

ReceiverRuntime& Runtime()
{
    static ReceiverRuntime runtime;
    return runtime;
}

void OnSurfaceCreated(OH_NativeXComponent*, void* window)
{
    Runtime().SurfaceCreated(window);
}

void OnSurfaceChanged(OH_NativeXComponent*, void* window)
{
    Runtime().SurfaceChanged(window);
}

void OnSurfaceDestroyed(OH_NativeXComponent*, void* window)
{
    Runtime().SurfaceDestroyed(window);
}

OH_NativeXComponent_Callback g_surfaceCallbacks {
    .OnSurfaceCreated = OnSurfaceCreated,
    .OnSurfaceChanged = OnSurfaceChanged,
    .OnSurfaceDestroyed = OnSurfaceDestroyed,
    .DispatchTouchEvent = nullptr,
};

napi_value StatusObject(napi_env env)
{
    const DecoderStatus status = Runtime().Status();
    napi_value result = nullptr;
    napi_value code = nullptr;
    napi_value running = nullptr;
    napi_value generation = nullptr;
    napi_value testFrames = nullptr;
    napi_value droppedFrames = nullptr;
    napi_value networkFrames = nullptr;
    napi_value decodedFrames = nullptr;
    napi_value renderedFrames = nullptr;
    napi_value staleOutputDrops = nullptr;
    napi_value inputQueueLatencyUs = nullptr;
    napi_value decodeLatencyUs = nullptr;
    napi_value outputLatencyUs = nullptr;
    napi_value decoderInFlight = nullptr;
    napi_value keyFrameRequests = nullptr;
    napi_value decoderRecoveries = nullptr;
    napi_value lowLatencyEnabled = nullptr;
    napi_value immediateRenderingEnabled = nullptr;
    if (napi_create_object(env, &result) != napi_ok
        || napi_create_string_utf8(env, status.code.c_str(), status.code.size(), &code) != napi_ok
        || napi_get_boolean(env, status.running, &running) != napi_ok
        || napi_create_double(env, static_cast<double>(status.generation), &generation) != napi_ok
        || napi_create_double(env, static_cast<double>(status.testFrames), &testFrames) != napi_ok
        || napi_create_double(env, static_cast<double>(status.droppedFrames), &droppedFrames) != napi_ok
        || napi_create_double(env, static_cast<double>(status.networkFrames), &networkFrames) != napi_ok
        || napi_create_double(env, static_cast<double>(status.decodedFrames), &decodedFrames) != napi_ok
        || napi_create_double(env, static_cast<double>(status.renderedFrames), &renderedFrames) != napi_ok
        || napi_create_double(env, static_cast<double>(status.staleOutputDrops), &staleOutputDrops) != napi_ok
        || napi_create_double(env, static_cast<double>(status.inputQueueLatencyUs), &inputQueueLatencyUs) != napi_ok
        || napi_create_double(env, static_cast<double>(status.decodeLatencyUs), &decodeLatencyUs) != napi_ok
        || napi_create_double(env, static_cast<double>(status.outputLatencyUs), &outputLatencyUs) != napi_ok
        || napi_create_double(env, static_cast<double>(status.decoderInFlight), &decoderInFlight) != napi_ok
        || napi_create_double(env, static_cast<double>(status.keyFrameRequests), &keyFrameRequests) != napi_ok
        || napi_create_double(env, static_cast<double>(status.decoderRecoveries), &decoderRecoveries) != napi_ok
        || napi_get_boolean(env, status.lowLatencyEnabled, &lowLatencyEnabled) != napi_ok
        || napi_get_boolean(env, status.immediateRenderingEnabled, &immediateRenderingEnabled) != napi_ok) {
        return nullptr;
    }
    if (napi_set_named_property(env, result, "code", code) != napi_ok
        || napi_set_named_property(env, result, "running", running) != napi_ok
        || napi_set_named_property(env, result, "generation", generation) != napi_ok
        || napi_set_named_property(env, result, "testFrames", testFrames) != napi_ok
        || napi_set_named_property(env, result, "droppedFrames", droppedFrames) != napi_ok
        || napi_set_named_property(env, result, "networkFrames", networkFrames) != napi_ok
        || napi_set_named_property(env, result, "decodedFrames", decodedFrames) != napi_ok
        || napi_set_named_property(env, result, "renderedFrames", renderedFrames) != napi_ok
        || napi_set_named_property(env, result, "staleOutputDrops", staleOutputDrops) != napi_ok
        || napi_set_named_property(env, result, "inputQueueLatencyUs", inputQueueLatencyUs) != napi_ok
        || napi_set_named_property(env, result, "decodeLatencyUs", decodeLatencyUs) != napi_ok
        || napi_set_named_property(env, result, "outputLatencyUs", outputLatencyUs) != napi_ok
        || napi_set_named_property(env, result, "decoderInFlight", decoderInFlight) != napi_ok
        || napi_set_named_property(env, result, "keyFrameRequests", keyFrameRequests) != napi_ok
        || napi_set_named_property(env, result, "decoderRecoveries", decoderRecoveries) != napi_ok
        || napi_set_named_property(env, result, "lowLatencyEnabled", lowLatencyEnabled) != napi_ok
        || napi_set_named_property(env, result, "immediateRenderingEnabled", immediateRenderingEnabled) != napi_ok) {
        return nullptr;
    }
    return result;
}

bool ReadSessionId(napi_env env, napi_value value, std::string& sessionId)
{
    std::size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok
        || length == 0 || length > 128) {
        return false;
    }
    std::vector<char> storage(length + 1, '\0');
    std::size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, storage.data(), storage.size(), &copied) != napi_ok
        || copied != length) {
        return false;
    }
    sessionId.assign(storage.data(), copied);
    return true;
}

napi_value GetDecoderStatus(napi_env env, napi_callback_info)
{
    return StatusObject(env);
}

napi_value RestartDecoder(napi_env env, napi_callback_info)
{
    Runtime().Restart();
    return StatusObject(env);
}

napi_value StopDecoder(napi_env env, napi_callback_info)
{
    Runtime().Stop();
    return StatusObject(env);
}

#if defined(SECOND_DISPLAY_ENABLE_DIAGNOSTICS)
napi_value StartDecoderSoak(napi_env env, napi_callback_info info)
{
    std::size_t argumentCount = 1;
    napi_value arguments[1] = {nullptr};
    double duration = 0;
    if (napi_get_cb_info(env, info, &argumentCount, arguments, nullptr, nullptr) != napi_ok
        || argumentCount != 1
        || napi_get_value_double(env, arguments[0], &duration) != napi_ok
        || duration < 1.0 || duration > 86400.0) {
        Runtime().StartTestPlayer(0);
        return StatusObject(env);
    }
    Runtime().StartTestPlayer(static_cast<std::uint32_t>(duration));
    return StatusObject(env);
}

napi_value StopDecoderSoak(napi_env env, napi_callback_info)
{
    Runtime().StopTestPlayer();
    return StatusObject(env);
}
#endif

napi_value GetDecoderMaxFps(napi_env env, napi_callback_info info, const char* mime)
{
    std::size_t argumentCount = 2;
    napi_value arguments[2] = {nullptr, nullptr};
    double width = 0;
    double height = 0;
    std::uint32_t maximumFramesPerSecond = 0;
    if (napi_get_cb_info(env, info, &argumentCount, arguments, nullptr, nullptr) == napi_ok
        && argumentCount == 2
        && napi_get_value_double(env, arguments[0], &width) == napi_ok
        && napi_get_value_double(env, arguments[1], &height) == napi_ok
        && std::isfinite(width) && std::isfinite(height)
        && std::floor(width) == width && std::floor(height) == height
        && width >= 1.0 && height >= 1.0 && width <= 8192.0 && height <= 8192.0) {
        OH_AVCapability* capability = OH_AVCodec_GetCapabilityByCategory(
            mime, false, HARDWARE);
        if (capability != nullptr) {
            const auto videoWidth = static_cast<std::int32_t>(width);
            const auto videoHeight = static_cast<std::int32_t>(height);
            for (const std::int32_t candidate : {120, 90, 60}) {
                if (OH_AVCapability_AreVideoSizeAndFrameRateSupported(
                        capability, videoWidth, videoHeight, candidate)) {
                    maximumFramesPerSecond = static_cast<std::uint32_t>(candidate);
                    break;
                }
            }
            if (maximumFramesPerSecond == 0) {
                OH_AVRange range {-1, -1};
                if (OH_AVCapability_GetVideoFrameRateRangeForSize(
                        capability, videoWidth, videoHeight, &range) == AV_ERR_OK) {
                    for (const std::int32_t candidate : {120, 90, 60}) {
                        if (candidate >= range.minVal && candidate <= range.maxVal) {
                            maximumFramesPerSecond = static_cast<std::uint32_t>(candidate);
                            break;
                        }
                    }
                }
            }
        }
    }
    napi_value result = nullptr;
    if (napi_create_uint32(env, maximumFramesPerSecond, &result) != napi_ok) return nullptr;
    return result;
}

napi_value GetH264DecoderMaxFps(napi_env env, napi_callback_info info)
{
    return GetDecoderMaxFps(env, info, OH_AVCODEC_MIMETYPE_VIDEO_AVC);
}

napi_value GetHEVCDecoderMaxFps(napi_env env, napi_callback_info info)
{
    return GetDecoderMaxFps(env, info, OH_AVCODEC_MIMETYPE_VIDEO_HEVC);
}

napi_value BeginVideoSession(napi_env env, napi_callback_info info)
{
    std::size_t argumentCount = 5;
    napi_value arguments[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    std::string sessionId;
    std::string codec = "h264";
    double width = 0;
    double height = 0;
    double framesPerSecond = 0;
    if (napi_get_cb_info(env, info, &argumentCount, arguments, nullptr, nullptr) != napi_ok
        || (argumentCount != 4 && argumentCount != 5) || !ReadSessionId(env, arguments[0], sessionId)
        || napi_get_value_double(env, arguments[1], &width) != napi_ok
        || napi_get_value_double(env, arguments[2], &height) != napi_ok
        || napi_get_value_double(env, arguments[3], &framesPerSecond) != napi_ok
        || !std::isfinite(width) || !std::isfinite(height) || !std::isfinite(framesPerSecond)
        || std::floor(width) != width || std::floor(height) != height
        || std::min(width, height) < 600.0 || std::max(width, height) < 800.0
        || width > 8192.0 || height > 8192.0
        || static_cast<std::uint32_t>(width) % 2U != 0
        || static_cast<std::uint32_t>(height) % 2U != 0
        || framesPerSecond < 1.0 || framesPerSecond > 120.0) {
        Runtime().RecordProtocolError("invalid video session configuration");
        return StatusObject(env);
    }
    if (argumentCount == 5 && !ReadSessionId(env, arguments[4], codec)) {
        Runtime().RecordProtocolError("invalid video codec");
        return StatusObject(env);
    }
    second_display::decoder::H264SurfaceDecoder::Codec decoderCodec =
        second_display::decoder::H264SurfaceDecoder::Codec::H264;
    if (codec == "hevc") {
        decoderCodec = second_display::decoder::H264SurfaceDecoder::Codec::HEVC;
    } else if (codec != "h264") {
        Runtime().RecordProtocolError("unsupported video codec");
        return StatusObject(env);
    }
    Runtime().BeginVideoSession(
        sessionId,
        static_cast<std::uint32_t>(width),
        static_cast<std::uint32_t>(height),
        framesPerSecond,
        decoderCodec);
    return StatusObject(env);
}

napi_value FeedVideoBytes(napi_env env, napi_callback_info info)
{
    std::size_t argumentCount = 2;
    napi_value arguments[2] = {nullptr, nullptr};
    std::string sessionId;
    void* bytes = nullptr;
    std::size_t size = 0;
    napi_typedarray_type arrayType = napi_uint8_array;
    napi_value arrayBuffer = nullptr;
    std::size_t byteOffset = 0;
    if (napi_get_cb_info(env, info, &argumentCount, arguments, nullptr, nullptr) != napi_ok
        || argumentCount != 2 || !ReadSessionId(env, arguments[0], sessionId)
        || napi_get_typedarray_info(
            env, arguments[1], &arrayType, &size, &bytes, &arrayBuffer, &byteOffset) != napi_ok
        || arrayType != napi_uint8_array
        || (bytes == nullptr && size != 0)) {
        Runtime().RecordProtocolError("invalid video receive buffer");
        return StatusObject(env);
    }
    Runtime().FeedVideoBytes(sessionId, static_cast<const std::uint8_t*>(bytes), size);
    return StatusObject(env);
}

napi_value FinishVideoSession(napi_env env, napi_callback_info info)
{
    std::size_t argumentCount = 1;
    napi_value arguments[1] = {nullptr};
    std::string sessionId;
    if (napi_get_cb_info(env, info, &argumentCount, arguments, nullptr, nullptr) != napi_ok
        || argumentCount != 1 || !ReadSessionId(env, arguments[0], sessionId)) {
        Runtime().RecordProtocolError("invalid video session identifier");
        return StatusObject(env);
    }
    Runtime().FinishVideoSession(sessionId);
    return StatusObject(env);
}

napi_value Initialize(napi_env env, napi_value exports)
{
    napi_value xcomponentValue = nullptr;
    OH_NativeXComponent* component = nullptr;
    if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &xcomponentValue) == napi_ok
        && napi_unwrap(env, xcomponentValue, reinterpret_cast<void**>(&component)) == napi_ok
        && component != nullptr) {
        if (OH_NativeXComponent_RegisterCallback(component, &g_surfaceCallbacks) != 0) {
            Runtime().RecordRegistrationFailure();
        }
    }

    const napi_property_descriptor properties[] = {
        {"getDecoderStatus", nullptr, GetDecoderStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"restartDecoder", nullptr, RestartDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopDecoder", nullptr, StopDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
#if defined(SECOND_DISPLAY_ENABLE_DIAGNOSTICS)
        {"startDecoderSoak", nullptr, StartDecoderSoak, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopDecoderSoak", nullptr, StopDecoderSoak, nullptr, nullptr, nullptr, napi_default, nullptr},
#endif
        {"beginVideoSession", nullptr, BeginVideoSession, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"feedVideoBytes", nullptr, FeedVideoBytes, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"finishVideoSession", nullptr, FinishVideoSession, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getH264DecoderMaxFps", nullptr, GetH264DecoderMaxFps, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getHEVCDecoderMaxFps", nullptr, GetHEVCDecoderMaxFps, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    if (napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties) != napi_ok) {
        Runtime().RecordRegistrationFailure();
    }
    return exports;
}

} // namespace

static napi_module module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Initialize,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {nullptr},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule()
{
    napi_module_register(&module);
}
