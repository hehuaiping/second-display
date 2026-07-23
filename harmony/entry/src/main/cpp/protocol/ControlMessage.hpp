#pragma once

#include "Json.hpp"

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace second_display::protocol {

inline constexpr std::size_t kMaximumControlMessageBytes = 64 * 1024;
inline constexpr std::string_view kProtocolErrorCode = "NET_PROTOCOL_MISMATCH";

enum class ControlMessageKind {
    ClientHello,
    ServerReady,
    Error,
    InputEvent,
    RequestKeyFrame,
    Heartbeat,
    HeartbeatAck,
};

struct ClientHello {
    std::string deviceId;
    std::string deviceName = "Unknown Device";
    std::uint64_t nativeWidth = 0;
    std::uint64_t nativeHeight = 0;
    double deviceScale = 2.0;
    std::uint64_t maxFps = 60;
    std::vector<std::string> codecs = {"h264"};
    std::uint64_t maxDecodeWidth = 0;
    std::uint64_t maxDecodeHeight = 0;
    std::string orientation = "landscape";
};

struct ServerReady {
    std::string sessionId;
    std::uint64_t logicalWidth = 0;
    std::uint64_t logicalHeight = 0;
    std::uint64_t framebufferWidth = 0;
    std::uint64_t framebufferHeight = 0;
    std::uint64_t refreshRate = 0;
    std::uint64_t serialNumber = 0;
    std::string codec;
    std::uint64_t streamWidth = 0;
    std::uint64_t streamHeight = 0;
    std::uint64_t fps = 0;
    std::uint64_t bitrate = 0;
};

struct ErrorMessage {
    std::string errorCode;
    std::string message;
    std::string sessionId;
    std::uint64_t generation = 0;
};

struct InputEvent {
    std::string sessionId;
    std::uint64_t sequence = 0;
    std::string eventType;
    std::optional<double> normalizedX;
    std::optional<double> normalizedY;
    double deltaX = 0;
    double deltaY = 0;
};

struct RequestKeyFrame {
    std::string sessionId;
    std::uint64_t sequence = 0;
    std::string reason = "decoderRecovery";
};

struct Heartbeat {
    std::string sessionId;
    std::uint64_t sequence = 0;
    std::uint64_t sentAtUs = 0;
    std::uint64_t receivedAtUs = 0;
};

struct ControlMessage {
    ControlMessageKind kind = ControlMessageKind::ClientHello;
    ClientHello clientHello;
    ServerReady serverReady;
    ErrorMessage error;
    InputEvent inputEvent;
    RequestKeyFrame requestKeyFrame;
    Heartbeat heartbeat;
};

struct ControlParseResult {
    std::optional<ControlMessage> message;
    bool ignoredUnknown = false;
    std::string errorCode;
    std::string detail;

    bool Ok() const { return message.has_value() || ignoredUnknown; }
};

ControlParseResult ParseControlMessage(std::string_view json);

} // namespace second_display::protocol
