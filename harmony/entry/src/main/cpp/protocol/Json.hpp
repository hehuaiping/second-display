#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace second_display::protocol {

enum class JsonType { Null, Boolean, Number, String, Array, Object };

class JsonValue {
public:
    JsonValue();

    static JsonValue Boolean(bool value);
    static JsonValue Number(std::string value);
    static JsonValue String(std::string value);
    static JsonValue Array(std::vector<JsonValue> value);
    static JsonValue Object(std::map<std::string, JsonValue> value);

    JsonType Type() const;
    const JsonValue* Get(std::string_view key) const;
    const std::vector<JsonValue>* AsArray() const;
    std::optional<std::string> AsString() const;
    std::optional<std::uint64_t> AsUInt64() const;
    std::optional<double> AsDouble() const;
    std::optional<bool> AsBoolean() const;

private:
    JsonType type_ = JsonType::Null;
    bool boolean_ = false;
    std::string scalar_;
    std::vector<JsonValue> array_;
    std::map<std::string, JsonValue> object_;
};

struct JsonParseResult {
    std::optional<JsonValue> value;
    std::string error;
};

JsonParseResult ParseJson(std::string_view input);

} // namespace second_display::protocol

