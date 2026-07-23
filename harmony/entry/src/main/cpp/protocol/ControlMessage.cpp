#include "ControlMessage.hpp"

#include <cmath>

namespace second_display::protocol {
namespace {

ControlParseResult Failure(std::string detail)
{
    return {std::nullopt, false, std::string(kProtocolErrorCode), std::move(detail)};
}

std::optional<std::string> StringField(const JsonValue& object, std::string_view key)
{
    const JsonValue* value = object.Get(key);
    return value == nullptr ? std::nullopt : value->AsString();
}

std::optional<std::uint64_t> UIntField(const JsonValue& object, std::string_view key)
{
    const JsonValue* value = object.Get(key);
    return value == nullptr ? std::nullopt : value->AsUInt64();
}

std::optional<double> DoubleField(const JsonValue& object, std::string_view key)
{
    const JsonValue* value = object.Get(key);
    return value == nullptr ? std::nullopt : value->AsDouble();
}

bool VersionIsSupported(const JsonValue& root, bool optional)
{
    const JsonValue* value = root.Get("protocolVersion");
    if (value == nullptr) return optional;
    const auto version = value->AsUInt64();
    return version.has_value() && *version == 1;
}

ControlParseResult ParseClientHello(const JsonValue& root)
{
    if (!VersionIsSupported(root, false)) return Failure("unsupported clientHello version");
    const auto deviceId = StringField(root, "deviceId");
    const auto nativeWidth = UIntField(root, "nativeWidth");
    const auto nativeHeight = UIntField(root, "nativeHeight");
    if (!deviceId.has_value() || !nativeWidth.has_value() || !nativeHeight.has_value()
        || *nativeWidth == 0 || *nativeHeight == 0) {
        return Failure("invalid clientHello required field");
    }
    ControlMessage message;
    message.kind = ControlMessageKind::ClientHello;
    message.clientHello.deviceId = *deviceId;
    message.clientHello.nativeWidth = *nativeWidth;
    message.clientHello.nativeHeight = *nativeHeight;
    message.clientHello.maxDecodeWidth = *nativeWidth;
    message.clientHello.maxDecodeHeight = *nativeHeight;
    if (const auto value = StringField(root, "deviceName")) message.clientHello.deviceName = *value;
    if (const auto value = DoubleField(root, "deviceScale")) message.clientHello.deviceScale = *value;
    if (const auto value = UIntField(root, "maxFps")) message.clientHello.maxFps = *value;
    if (const auto value = UIntField(root, "maxDecodeWidth")) message.clientHello.maxDecodeWidth = *value;
    if (const auto value = UIntField(root, "maxDecodeHeight")) message.clientHello.maxDecodeHeight = *value;
    if (const auto value = StringField(root, "orientation")) message.clientHello.orientation = *value;
    if (const JsonValue* codecs = root.Get("codecs")) {
        const auto* array = codecs->AsArray();
        if (array == nullptr || array->empty()) return Failure("invalid clientHello codecs");
        message.clientHello.codecs.clear();
        for (const auto& item : *array) {
            const auto codec = item.AsString();
            if (!codec.has_value()) return Failure("invalid clientHello codec");
            message.clientHello.codecs.push_back(*codec);
        }
    }
    if (message.clientHello.deviceScale <= 0 || message.clientHello.maxFps == 0
        || message.clientHello.maxDecodeWidth == 0 || message.clientHello.maxDecodeHeight == 0) {
        return Failure("invalid clientHello capability");
    }
    return {message, false, "", ""};
}

ControlParseResult ParseServerReady(const JsonValue& root)
{
    if (!VersionIsSupported(root, false)) return Failure("unsupported serverReady version");
    const auto sessionId = StringField(root, "sessionId");
    const JsonValue* display = root.Get("display");
    const JsonValue* stream = root.Get("stream");
    if (!sessionId.has_value() || display == nullptr || stream == nullptr) {
        return Failure("invalid serverReady required field");
    }
    ControlMessage message;
    message.kind = ControlMessageKind::ServerReady;
    message.serverReady.sessionId = *sessionId;
    const auto logicalWidth = UIntField(*display, "logicalWidth");
    const auto logicalHeight = UIntField(*display, "logicalHeight");
    const auto framebufferWidth = UIntField(*display, "framebufferWidth");
    const auto framebufferHeight = UIntField(*display, "framebufferHeight");
    const auto refreshRate = UIntField(*display, "refreshRate");
    const auto serialNumber = UIntField(*display, "serialNumber");
    const auto codec = StringField(*stream, "codec");
    const auto width = UIntField(*stream, "width");
    const auto height = UIntField(*stream, "height");
    const auto fps = UIntField(*stream, "fps");
    const auto bitrate = UIntField(*stream, "bitrate");
    if (!logicalWidth || !logicalHeight || !framebufferWidth || !framebufferHeight || !refreshRate
        || !serialNumber || !codec || !width || !height || !fps || !bitrate) {
        return Failure("invalid serverReady configuration");
    }
    message.serverReady.logicalWidth = *logicalWidth;
    message.serverReady.logicalHeight = *logicalHeight;
    message.serverReady.framebufferWidth = *framebufferWidth;
    message.serverReady.framebufferHeight = *framebufferHeight;
    message.serverReady.refreshRate = *refreshRate;
    message.serverReady.serialNumber = *serialNumber;
    message.serverReady.codec = *codec;
    message.serverReady.streamWidth = *width;
    message.serverReady.streamHeight = *height;
    message.serverReady.fps = *fps;
    message.serverReady.bitrate = *bitrate;
    return {message, false, "", ""};
}

ControlParseResult ParseError(const JsonValue& root)
{
    if (!VersionIsSupported(root, true)) return Failure("unsupported error version");
    const auto code = StringField(root, "errorCode");
    if (!code.has_value()) return Failure("errorCode is missing");
    ControlMessage message;
    message.kind = ControlMessageKind::Error;
    message.error.errorCode = *code;
    if (const auto value = StringField(root, "message")) message.error.message = *value;
    if (const auto value = StringField(root, "sessionId")) message.error.sessionId = *value;
    if (const auto value = UIntField(root, "generation")) message.error.generation = *value;
    return {message, false, "", ""};
}

ControlParseResult ParseInputEvent(const JsonValue& root)
{
    if (!VersionIsSupported(root, true)) return Failure("unsupported inputEvent version");
    const auto sessionId = StringField(root, "sessionId");
    const auto sequence = UIntField(root, "sequence");
    const auto eventType = StringField(root, "eventType");
    if (!sessionId || !sequence || !eventType) return Failure("invalid inputEvent required field");
    ControlMessage message;
    message.kind = ControlMessageKind::InputEvent;
    message.inputEvent.sessionId = *sessionId;
    message.inputEvent.sequence = *sequence;
    message.inputEvent.eventType = *eventType;
    message.inputEvent.normalizedX = DoubleField(root, "normalizedX");
    message.inputEvent.normalizedY = DoubleField(root, "normalizedY");
    if (const auto value = DoubleField(root, "deltaX")) message.inputEvent.deltaX = *value;
    if (const auto value = DoubleField(root, "deltaY")) message.inputEvent.deltaY = *value;
    const auto coordinateIsValid = [](const std::optional<double>& value) {
        return !value.has_value() || (*value >= 0 && *value <= 1 && std::isfinite(*value));
    };
    if (!coordinateIsValid(message.inputEvent.normalizedX)
        || !coordinateIsValid(message.inputEvent.normalizedY)) {
        return Failure("inputEvent coordinate is outside [0, 1]");
    }
    return {message, false, "", ""};
}

ControlParseResult ParseRequestKeyFrame(const JsonValue& root)
{
    if (!VersionIsSupported(root, true)) return Failure("unsupported requestKeyFrame version");
    const auto sessionId = StringField(root, "sessionId");
    const auto sequence = UIntField(root, "sequence");
    if (!sessionId || !sequence) return Failure("invalid requestKeyFrame required field");
    ControlMessage message;
    message.kind = ControlMessageKind::RequestKeyFrame;
    message.requestKeyFrame.sessionId = *sessionId;
    message.requestKeyFrame.sequence = *sequence;
    if (const auto reason = StringField(root, "reason")) message.requestKeyFrame.reason = *reason;
    return {message, false, "", ""};
}

ControlParseResult ParseHeartbeat(const JsonValue& root, bool acknowledgement)
{
    if (!VersionIsSupported(root, false)) return Failure("unsupported heartbeat version");
    const auto sessionId = StringField(root, "sessionId");
    const auto sequence = UIntField(root, "sequence");
    const auto sentAtUs = UIntField(root, "sentAtUs");
    if (!sessionId || !sequence || !sentAtUs) return Failure("invalid heartbeat required field");
    ControlMessage message;
    message.kind = acknowledgement ? ControlMessageKind::HeartbeatAck : ControlMessageKind::Heartbeat;
    message.heartbeat.sessionId = *sessionId;
    message.heartbeat.sequence = *sequence;
    message.heartbeat.sentAtUs = *sentAtUs;
    if (acknowledgement) {
        const auto receivedAtUs = UIntField(root, "receivedAtUs");
        if (!receivedAtUs) return Failure("heartbeat acknowledgement timestamp is missing");
        message.heartbeat.receivedAtUs = *receivedAtUs;
    }
    return {message, false, "", ""};
}

} // namespace

ControlParseResult ParseControlMessage(std::string_view json)
{
    if (json.size() > kMaximumControlMessageBytes) return Failure("control message exceeds 64 KiB");
    auto parsed = ParseJson(json);
    if (!parsed.value.has_value() || parsed.value->Type() != JsonType::Object) {
        return Failure(parsed.error.empty() ? "control message is not an object" : parsed.error);
    }
    const auto type = StringField(*parsed.value, "type");
    if (!type.has_value()) return Failure("control message type is missing");
    if (*type == "clientHello") return ParseClientHello(*parsed.value);
    if (*type == "serverReady") return ParseServerReady(*parsed.value);
    if (*type == "error") return ParseError(*parsed.value);
    if (*type == "inputEvent") return ParseInputEvent(*parsed.value);
    if (*type == "requestKeyFrame") return ParseRequestKeyFrame(*parsed.value);
    if (*type == "heartbeat") return ParseHeartbeat(*parsed.value, false);
    if (*type == "heartbeatAck") return ParseHeartbeat(*parsed.value, true);
    return {std::nullopt, true, "", ""};
}

} // namespace second_display::protocol
