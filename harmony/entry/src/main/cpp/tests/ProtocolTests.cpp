#include "protocol/ControlMessage.hpp"
#include "protocol/Json.hpp"
#include "protocol/VideoFrame.hpp"
#include "decoder/DecoderFrameQueue.hpp"
#include "decoder/LatencyWindow.hpp"
#include "decoder/DecoderOutputPolicy.hpp"
#include "transport/FrameParser.hpp"

#include <fstream>
#include <iostream>
#include <iterator>
#include <optional>
#include <random>
#include <string>
#include <vector>

using namespace second_display::protocol;

namespace {

int failures = 0;

void Check(bool condition, const std::string& message)
{
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

std::optional<std::string> ReadFile(const std::string& path)
{
    std::ifstream stream(path, std::ios::binary);
    if (!stream) return std::nullopt;
    return std::string(std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>());
}

std::optional<std::vector<std::uint8_t>> Hex(std::string_view value)
{
    if (value.size() % 2 != 0) return std::nullopt;
    std::vector<std::uint8_t> bytes;
    bytes.reserve(value.size() / 2);
    for (std::size_t index = 0; index < value.size(); index += 2) {
        const auto digit = [](char input) -> std::optional<std::uint8_t> {
            if (input >= '0' && input <= '9') return static_cast<std::uint8_t>(input - '0');
            if (input >= 'a' && input <= 'f') return static_cast<std::uint8_t>(input - 'a' + 10);
            if (input >= 'A' && input <= 'F') return static_cast<std::uint8_t>(input - 'A' + 10);
            return std::nullopt;
        };
        const auto high = digit(value[index]);
        const auto low = digit(value[index + 1]);
        if (!high || !low) return std::nullopt;
        bytes.push_back(static_cast<std::uint8_t>((*high << 4) | *low));
    }
    return bytes;
}

ControlParseResult ParseVector(const std::string& root, const std::string& name)
{
    const auto contents = ReadFile(root + "/control/" + name);
    Check(contents.has_value(), "read " + name);
    return contents.has_value() ? ParseControlMessage(*contents)
                                : ControlParseResult {std::nullopt, false, std::string(kProtocolErrorCode), "missing vector"};
}

void TestControlVectors(const std::string& root)
{
    const auto full = ParseVector(root, "client_hello_full.json");
    Check(full.Ok() && full.message->kind == ControlMessageKind::ClientHello, "parse full clientHello");
    if (full.message) {
        Check(full.message->clientHello.deviceName == "Harmony Tablet", "clientHello deviceName");
        Check(full.message->clientHello.maxDecodeWidth == 2560, "clientHello max decode width");
    }

    const auto minimal = ParseVector(root, "client_hello_minimal.json");
    Check(minimal.Ok() && minimal.message->kind == ControlMessageKind::ClientHello, "parse minimal clientHello");
    if (minimal.message) {
        Check(minimal.message->clientHello.deviceName == "Unknown Device", "default deviceName");
        Check(minimal.message->clientHello.maxFps == 60, "default maxFps");
        Check(minimal.message->clientHello.maxDecodeWidth == 2560, "default maxDecodeWidth");
        Check(minimal.message->clientHello.orientation == "landscape", "default orientation");
    }

    const auto ready = ParseVector(root, "server_ready.json");
    Check(ready.Ok() && ready.message->kind == ControlMessageKind::ServerReady, "parse serverReady");
    if (ready.message) Check(ready.message->serverReady.bitrate == 16000000, "serverReady bitrate");

    const auto error = ParseVector(root, "error_minimal.json");
    Check(error.Ok() && error.message->kind == ControlMessageKind::Error, "parse error");
    if (error.message) {
        Check(error.message->error.message.empty(), "default error message");
        Check(error.message->error.generation == 0, "default generation");
    }

    const auto input = ParseVector(root, "input_scroll.json");
    Check(input.Ok() && input.message->kind == ControlMessageKind::InputEvent, "parse inputEvent");
    if (input.message) Check(input.message->inputEvent.deltaX == 0, "default deltaX");

    const auto keyFrame = ParseVector(root, "request_key_frame.json");
    Check(keyFrame.Ok() && keyFrame.message->kind == ControlMessageKind::RequestKeyFrame, "parse requestKeyFrame");
    if (keyFrame.message) Check(keyFrame.message->requestKeyFrame.reason == "decoderRecovery", "default keyframe reason");

    const auto heartbeat = ParseVector(root, "heartbeat.json");
    Check(heartbeat.Ok() && heartbeat.message->kind == ControlMessageKind::Heartbeat, "parse heartbeat");
    if (heartbeat.message) Check(heartbeat.message->heartbeat.sequence == 42, "heartbeat sequence");

    const auto heartbeatAck = ParseVector(root, "heartbeat_ack.json");
    Check(heartbeatAck.Ok() && heartbeatAck.message->kind == ControlMessageKind::HeartbeatAck,
        "parse heartbeat acknowledgement");
    if (heartbeatAck.message) Check(heartbeatAck.message->heartbeat.receivedAtUs == 1001200,
        "heartbeat acknowledgement timestamp");

    const auto unknown = ParseVector(root, "unknown.json");
    Check(unknown.Ok() && unknown.ignoredUnknown && !unknown.message, "ignore unknown control message");

    const auto oversized = ParseControlMessage(std::string(kMaximumControlMessageBytes + 1, ' '));
    Check(!oversized.Ok() && oversized.errorCode == kProtocolErrorCode, "reject oversized control message");
}

void TestVideoVector(const std::string& root)
{
    const auto vectorText = ReadFile(root + "/video/frame_golden.json");
    Check(vectorText.has_value(), "read video vector");
    if (!vectorText) return;
    const auto json = ParseJson(*vectorText);
    Check(json.value.has_value(), "parse video vector JSON");
    if (!json.value) return;
    const auto payloadHex = json.value->Get("payloadHex");
    const auto encodedHex = json.value->Get("encodedHex");
    const auto payloadString = payloadHex == nullptr ? std::nullopt : payloadHex->AsString();
    const auto encodedString = encodedHex == nullptr ? std::nullopt : encodedHex->AsString();
    Check(payloadString.has_value() && encodedString.has_value(), "video vector hex fields");
    if (!payloadString || !encodedString) return;
    const auto payload = Hex(*payloadString);
    const auto expected = Hex(*encodedString);
    Check(payload.has_value() && expected.has_value(), "decode vector hex");
    if (!payload || !expected) return;

    VideoFrame frame {VideoFrameType::Video, 1, 42, 1000000, 900000, *payload};
    const auto encoded = EncodeVideoFrame(frame);
    Check(encoded.bytes.has_value() && *encoded.bytes == *expected, "encode golden video frame");
    if (!encoded.bytes) return;
    const auto decoded = DecodeVideoFrame(*encoded.bytes);
    Check(decoded.frame.has_value() && *decoded.frame == frame, "round-trip video frame");

    auto badMagic = *encoded.bytes;
    badMagic[0] = 0;
    Check(DecodeVideoFrame(badMagic).errorCode == kProtocolErrorCode, "reject bad video magic");
    Check(DecodeVideoFrame(std::vector<std::uint8_t>(31)).errorCode == kProtocolErrorCode, "reject truncated header");
    auto oversized = std::vector<std::uint8_t>(encoded.bytes->begin(), encoded.bytes->begin() + kVideoFrameHeaderSize);
    oversized[28] = 0x01;
    oversized[29] = 0x00;
    oversized[30] = 0x00;
    oversized[31] = 0x01;
    Check(DecodeVideoFrame(oversized).errorCode == kProtocolErrorCode, "reject oversized payload");
}

std::vector<std::uint8_t> EncodedFrame(std::uint32_t sequence, bool keyFrame = false)
{
    VideoFrame frame {
        VideoFrameType::Video,
        static_cast<std::uint16_t>(keyFrame ? 1 : 0),
        sequence,
        static_cast<std::uint64_t>(sequence) * 1000,
        static_cast<std::uint64_t>(sequence) * 1000,
        {0, 0, 0, 1, static_cast<std::uint8_t>(keyFrame ? 0x65 : 0x41)},
    };
    const auto encoded = EncodeVideoFrame(frame);
    return encoded.bytes.value_or(std::vector<std::uint8_t> {});
}

void TestIncrementalFrameParser()
{
    using second_display::transport::FrameParser;
    const auto first = EncodedFrame(10, true);
    const auto second = EncodedFrame(11);
    std::vector<std::uint8_t> sticky = first;
    sticky.insert(sticky.end(), second.begin(), second.end());

    FrameParser parser;
    parser.BeginSession("current");
    const auto prefix = parser.Feed("current", sticky.data(), 7);
    Check(prefix.Ok() && prefix.frames.empty(), "incremental parser waits for partial header");
    const auto frames = parser.Feed("current", sticky.data() + 7, sticky.size() - 7);
    Check(frames.Ok() && frames.frames.size() == 2, "incremental parser handles sticky frames");
    Check(frames.frames.size() == 2
            && frames.frames[0].payload.SharesStorageWith(frames.frames[1].payload),
        "incremental parser shares bounded backing instead of copying each payload");
    std::uint8_t copiedPayload[5] {};
    Check(frames.frames.size() == 2
            && frames.frames[0].payload.CopyTo(copiedPayload, sizeof(copiedPayload))
            && std::equal(std::begin(copiedPayload), std::end(copiedPayload),
                frames.frames[0].payload.begin()),
        "video payload performs one bounded copy into decoder storage");
    Check(parser.BufferedBytes() == 0, "incremental parser releases fully consumed storage");
    Check(parser.Finish("current").Ok(), "incremental parser finishes on frame boundary");

    std::vector<std::uint8_t> manySticky;
    for (std::uint32_t sequence = 100; sequence < 2200; ++sequence) {
        const auto encoded = EncodedFrame(sequence, sequence == 100);
        manySticky.insert(manySticky.end(), encoded.begin(), encoded.end());
    }
    FrameParser compacting;
    compacting.BeginSession("compacting");
    const auto manyFrames = compacting.Feed("compacting", manySticky);
    Check(manyFrames.Ok() && manyFrames.frames.size() == 2100,
        "incremental parser parses many coalesced frames without per-frame compaction");
    Check(compacting.BufferedBytes() == 0, "incremental parser clears consumed sticky storage");

    const auto third = EncodedFrame(12);
    FrameParser trailing;
    trailing.BeginSession("trailing");
    std::vector<std::uint8_t> fullAndPartial = first;
    fullAndPartial.insert(fullAndPartial.end(), third.begin(), third.begin() + 19);
    const auto initial = trailing.Feed("trailing", fullAndPartial);
    Check(initial.Ok() && initial.frames.size() == 1 && trailing.BufferedBytes() == 19,
        "incremental parser preserves only an incomplete trailing frame");
    const auto completed = trailing.Feed(
        "trailing", third.data() + 19, third.size() - 19);
    Check(completed.Ok() && completed.frames.size() == 1 && trailing.BufferedBytes() == 0,
        "incremental parser completes a trailing frame after deferred compaction");
    Check(initial.frames.size() == 1 && initial.frames[0].payload.size() == 5
            && initial.frames[0].payload[4] == 0x65,
        "completed frame backing remains valid after parser reuses trailing storage");

    FrameParser oldSession;
    oldSession.BeginSession("new");
    Check(!oldSession.Feed("old", first).Ok(), "incremental parser rejects old session");

    FrameParser regression;
    regression.BeginSession("session");
    Check(regression.Feed("session", EncodedFrame(20, true)).Ok(), "accept initial sequence");
    Check(!regression.Feed("session", EncodedFrame(19)).Ok(), "reject sequence regression");

    FrameParser wrapping;
    wrapping.BeginSession("session");
    Check(wrapping.Feed("session", EncodedFrame(0xFFFFFFFFU, true)).Ok(), "accept high sequence");
    Check(wrapping.Feed("session", EncodedFrame(0)).Ok(), "accept sequence wrap");

    auto oversized = EncodedFrame(1, true);
    oversized.resize(kVideoFrameHeaderSize);
    oversized[28] = 1;
    oversized[29] = 0;
    oversized[30] = 0;
    oversized[31] = 1;
    FrameParser oversizedParser;
    oversizedParser.BeginSession("session");
    Check(!oversizedParser.Feed("session", oversized).Ok(), "incremental parser rejects oversized payload");

    FrameParser truncated;
    truncated.BeginSession("session");
    Check(truncated.Feed("session", first.data(), first.size() - 1).Ok(), "truncated frame awaits more data");
    Check(!truncated.Finish("session").Ok(), "truncated frame fails at end of stream");
}

void TestFrameParserFuzz()
{
    using second_display::transport::FrameParser;
    std::mt19937 generator(0x53445331U);
    std::uniform_int_distribution<int> lengthDistribution(0, 2048);
    std::uniform_int_distribution<int> byteDistribution(0, 255);
    for (int iteration = 0; iteration < 5000; ++iteration) {
        std::vector<std::uint8_t> input(static_cast<std::size_t>(lengthDistribution(generator)));
        for (auto& byte : input) byte = static_cast<std::uint8_t>(byteDistribution(generator));
        FrameParser parser;
        parser.BeginSession("fuzz");
        std::size_t offset = 0;
        while (offset < input.size()) {
            const auto chunk = std::min<std::size_t>(1 + (generator() % 97U), input.size() - offset);
            const auto result = parser.Feed("fuzz", input.data() + offset, chunk);
            offset += chunk;
            Check(parser.BufferedBytes() <= kVideoFrameHeaderSize + kMaximumVideoPayloadSize,
                "fuzz parser remains bounded");
            if (!result.Ok()) break;
        }
    }
}

void TestDecoderBackpressure()
{
    using second_display::decoder::DecoderFrameQueue;
    DecoderFrameQueue queue;
    const auto decodedDelta = DecodeVideoFrame(EncodedFrame(1)).frame;
    const auto decodedKey = DecodeVideoFrame(EncodedFrame(2, true)).frame;
    const auto decodedDeltaTwo = DecodeVideoFrame(EncodedFrame(3)).frame;
    const auto decodedDeltaThree = DecodeVideoFrame(EncodedFrame(4)).frame;
    Check(decodedDelta.has_value() && decodedKey.has_value() && decodedDeltaTwo.has_value()
        && decodedDeltaThree.has_value(), "decoder queue test frames decode");
    if (!decodedDelta.has_value() || !decodedKey.has_value() || !decodedDeltaTwo.has_value()
        || !decodedDeltaThree.has_value()) return;
    auto delta = *decodedDelta;
    auto key = *decodedKey;
    auto deltaTwo = *decodedDeltaTwo;
    auto deltaThree = *decodedDeltaThree;
    Check(!queue.Enqueue(delta, 1000).accepted && queue.WaitingForKeyFrame(), "decoder waits for IDR");
    Check(queue.Enqueue(key, 2000).accepted, "decoder accepts IDR");
    Check(queue.Enqueue(deltaTwo, 3000).accepted, "decoder accepts delta after IDR");
    const auto overflow = queue.Enqueue(deltaThree, 4000);
    Check(!overflow.accepted && overflow.requestKeyFrame && !overflow.resetDecoder,
        "decoder overflow drops to IDR without resetting codec");
    Check(queue.Size() == 0 && queue.WaitingForKeyFrame(), "decoder queue remains bounded");

    Check(queue.Enqueue(key, 5000).accepted, "decoder accepts fresh IDR");
    const auto staleResult = queue.Enqueue(delta, 200000);
    Check(!staleResult.accepted && staleResult.requestKeyFrame && !staleResult.resetDecoder,
        "decoder drops stale queue backlog without resetting codec");

    Check(queue.Enqueue(key, 201000).accepted, "decoder accepts IDR after stale recovery");
    Check(queue.Enqueue(deltaTwo, 202000).accepted, "decoder queues delta before output staleness");
    Check(queue.DropUntilKeyFrame() == 2, "decoder output staleness clears queued frames");
    Check(queue.Size() == 0 && queue.WaitingForKeyFrame(), "decoder waits for IDR after output staleness");
    const auto waiting = queue.Enqueue(deltaThree, 203000);
    Check(!waiting.accepted && waiting.requestKeyFrame && !waiting.resetDecoder,
        "decoder does not repeatedly reset while waiting for IDR");

    const auto freshOutput = second_display::decoder::DecideDecoderOutput(119999, 120000);
    Check(freshOutput.render && !freshOutput.requestKeyFrame && !freshOutput.resetDecoder,
        "decoder renders output inside latency budget");
    const auto staleOutput = second_display::decoder::DecideDecoderOutput(120001, 120000);
    Check(!staleOutput.render && !staleOutput.requestKeyFrame && !staleOutput.resetDecoder,
        "decoder drops stale presentation without resetting decoded reference state");
    const auto finalStaleOutput = second_display::decoder::DecideDecoderOutput(120001, 120000, false);
    Check(finalStaleOutput.render && !finalStaleOutput.requestKeyFrame && !finalStaleOutput.resetDecoder,
        "decoder still renders the newest late frame to preserve final desktop state");
}

void TestLatencyWindow()
{
    second_display::decoder::LatencyWindow<4> window;
    window.Add(10);
    window.Add(20);
    window.Add(30);
    Check(window.Size() == 3, "latency window tracks sample count");
    Check(window.Percentile(0.5) == 20, "latency window computes p50");
    Check(window.Percentile(0.95) == 30, "latency window computes p95");
    Check(window.Average() == 20, "latency window computes average");
    window.Add(40);
    window.Add(50);
    Check(window.Size() == 4 && window.Percentile(0) == 20,
        "latency window overwrites oldest sample");
}

} // namespace

int main(int argc, char** argv)
{
    if (argc != 2 || argv[1] == nullptr) {
        std::cerr << "usage: protocol_tests <shared-test-vectors>\n";
        return 2;
    }
    const std::string root(argv[1]);
    TestControlVectors(root);
    TestVideoVector(root);
    TestIncrementalFrameParser();
    TestFrameParserFuzz();
    TestDecoderBackpressure();
    TestLatencyWindow();
    if (failures == 0) std::cout << "Harmony C++ protocol tests passed\n";
    return failures == 0 ? 0 : 1;
}
