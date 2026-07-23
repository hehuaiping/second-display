#include "Json.hpp"

#include <charconv>
#include <cerrno>
#include <cstdlib>
#include <limits>

namespace second_display::protocol {

JsonValue::JsonValue() = default;

JsonValue JsonValue::Boolean(bool value)
{
    JsonValue result;
    result.type_ = JsonType::Boolean;
    result.boolean_ = value;
    return result;
}

JsonValue JsonValue::Number(std::string value)
{
    JsonValue result;
    result.type_ = JsonType::Number;
    result.scalar_ = std::move(value);
    return result;
}

JsonValue JsonValue::String(std::string value)
{
    JsonValue result;
    result.type_ = JsonType::String;
    result.scalar_ = std::move(value);
    return result;
}

JsonValue JsonValue::Array(std::vector<JsonValue> value)
{
    JsonValue result;
    result.type_ = JsonType::Array;
    result.array_ = std::move(value);
    return result;
}

JsonValue JsonValue::Object(std::map<std::string, JsonValue> value)
{
    JsonValue result;
    result.type_ = JsonType::Object;
    result.object_ = std::move(value);
    return result;
}

JsonType JsonValue::Type() const { return type_; }

const JsonValue* JsonValue::Get(std::string_view key) const
{
    if (type_ != JsonType::Object) {
        return nullptr;
    }
    const auto iterator = object_.find(std::string(key));
    return iterator == object_.end() ? nullptr : &iterator->second;
}

const std::vector<JsonValue>* JsonValue::AsArray() const
{
    return type_ == JsonType::Array ? &array_ : nullptr;
}

std::optional<std::string> JsonValue::AsString() const
{
    return type_ == JsonType::String ? std::optional<std::string>(scalar_) : std::nullopt;
}

std::optional<std::uint64_t> JsonValue::AsUInt64() const
{
    if (type_ != JsonType::Number || scalar_.empty() || scalar_.front() == '-') {
        return std::nullopt;
    }
    std::uint64_t result = 0;
    const auto conversion = std::from_chars(scalar_.data(), scalar_.data() + scalar_.size(), result);
    if (conversion.ec != std::errc() || conversion.ptr != scalar_.data() + scalar_.size()) {
        return std::nullopt;
    }
    return result;
}

std::optional<double> JsonValue::AsDouble() const
{
    if (type_ != JsonType::Number) {
        return std::nullopt;
    }
    char* end = nullptr;
    errno = 0;
    const double result = std::strtod(scalar_.c_str(), &end);
    if (errno == ERANGE || end != scalar_.c_str() + scalar_.size()) {
        return std::nullopt;
    }
    return result;
}

std::optional<bool> JsonValue::AsBoolean() const
{
    return type_ == JsonType::Boolean ? std::optional<bool>(boolean_) : std::nullopt;
}

namespace {

class Parser {
public:
    explicit Parser(std::string_view input) : input_(input) {}

    JsonParseResult Parse()
    {
        SkipWhitespace();
        auto value = ParseValue(0);
        if (!value.has_value()) {
            return {std::nullopt, error_.empty() ? "invalid JSON" : error_};
        }
        SkipWhitespace();
        if (position_ != input_.size()) {
            return {std::nullopt, "trailing JSON data"};
        }
        return {std::move(value), ""};
    }

private:
    std::optional<JsonValue> ParseValue(std::size_t depth)
    {
        if (depth > 32) {
            SetError("JSON nesting exceeds 32 levels");
            return std::nullopt;
        }
        SkipWhitespace();
        if (position_ >= input_.size()) {
            SetError("unexpected end of JSON");
            return std::nullopt;
        }
        switch (input_[position_]) {
            case '{': return ParseObject(depth + 1);
            case '[': return ParseArray(depth + 1);
            case '"': {
                auto string = ParseString();
                return string.has_value() ? std::optional<JsonValue>(JsonValue::String(std::move(*string)))
                                          : std::nullopt;
            }
            case 't': return ParseLiteral("true", JsonValue::Boolean(true));
            case 'f': return ParseLiteral("false", JsonValue::Boolean(false));
            case 'n': return ParseLiteral("null", JsonValue());
            default: return ParseNumber();
        }
    }

    std::optional<JsonValue> ParseObject(std::size_t depth)
    {
        ++position_;
        SkipWhitespace();
        std::map<std::string, JsonValue> object;
        if (Consume('}')) {
            return JsonValue::Object(std::move(object));
        }
        while (position_ < input_.size()) {
            auto key = ParseString();
            if (!key.has_value()) {
                return std::nullopt;
            }
            SkipWhitespace();
            if (!Consume(':')) {
                SetError("expected ':' after object key");
                return std::nullopt;
            }
            auto value = ParseValue(depth);
            if (!value.has_value()) {
                return std::nullopt;
            }
            object.insert_or_assign(std::move(*key), std::move(*value));
            SkipWhitespace();
            if (Consume('}')) {
                return JsonValue::Object(std::move(object));
            }
            if (!Consume(',')) {
                SetError("expected ',' in object");
                return std::nullopt;
            }
            SkipWhitespace();
        }
        SetError("unterminated object");
        return std::nullopt;
    }

    std::optional<JsonValue> ParseArray(std::size_t depth)
    {
        ++position_;
        SkipWhitespace();
        std::vector<JsonValue> array;
        if (Consume(']')) {
            return JsonValue::Array(std::move(array));
        }
        while (position_ < input_.size()) {
            auto value = ParseValue(depth);
            if (!value.has_value()) {
                return std::nullopt;
            }
            array.push_back(std::move(*value));
            SkipWhitespace();
            if (Consume(']')) {
                return JsonValue::Array(std::move(array));
            }
            if (!Consume(',')) {
                SetError("expected ',' in array");
                return std::nullopt;
            }
            SkipWhitespace();
        }
        SetError("unterminated array");
        return std::nullopt;
    }

    std::optional<std::string> ParseString()
    {
        if (!Consume('"')) {
            SetError("expected string");
            return std::nullopt;
        }
        std::string result;
        while (position_ < input_.size()) {
            const char character = input_[position_++];
            if (character == '"') {
                return result;
            }
            if (static_cast<unsigned char>(character) < 0x20) {
                SetError("control character in string");
                return std::nullopt;
            }
            if (character != '\\') {
                result.push_back(character);
                continue;
            }
            if (position_ >= input_.size()) {
                SetError("unterminated string escape");
                return std::nullopt;
            }
            const char escaped = input_[position_++];
            switch (escaped) {
                case '"': result.push_back('"'); break;
                case '\\': result.push_back('\\'); break;
                case '/': result.push_back('/'); break;
                case 'b': result.push_back('\b'); break;
                case 'f': result.push_back('\f'); break;
                case 'n': result.push_back('\n'); break;
                case 'r': result.push_back('\r'); break;
                case 't': result.push_back('\t'); break;
                case 'u': {
                    if (!AppendUnicodeEscape(result)) {
                        return std::nullopt;
                    }
                    break;
                }
                default:
                    SetError("invalid string escape");
                    return std::nullopt;
            }
        }
        SetError("unterminated string");
        return std::nullopt;
    }

    bool AppendUnicodeEscape(std::string& output)
    {
        if (position_ + 4 > input_.size()) {
            SetError("truncated Unicode escape");
            return false;
        }
        std::uint32_t codePoint = 0;
        for (int index = 0; index < 4; ++index) {
            const char digit = input_[position_++];
            codePoint <<= 4;
            if (digit >= '0' && digit <= '9') codePoint |= static_cast<std::uint32_t>(digit - '0');
            else if (digit >= 'a' && digit <= 'f') codePoint |= static_cast<std::uint32_t>(digit - 'a' + 10);
            else if (digit >= 'A' && digit <= 'F') codePoint |= static_cast<std::uint32_t>(digit - 'A' + 10);
            else {
                SetError("invalid Unicode escape");
                return false;
            }
        }
        if (codePoint <= 0x7F) {
            output.push_back(static_cast<char>(codePoint));
        } else if (codePoint <= 0x7FF) {
            output.push_back(static_cast<char>(0xC0 | (codePoint >> 6)));
            output.push_back(static_cast<char>(0x80 | (codePoint & 0x3F)));
        } else {
            output.push_back(static_cast<char>(0xE0 | (codePoint >> 12)));
            output.push_back(static_cast<char>(0x80 | ((codePoint >> 6) & 0x3F)));
            output.push_back(static_cast<char>(0x80 | (codePoint & 0x3F)));
        }
        return true;
    }

    std::optional<JsonValue> ParseNumber()
    {
        const std::size_t start = position_;
        if (Peek('-')) ++position_;
        if (Consume('0')) {
            if (position_ < input_.size() && input_[position_] >= '0' && input_[position_] <= '9') {
                SetError("leading zero in number");
                return std::nullopt;
            }
        } else if (!ConsumeDigits()) {
            SetError("invalid number");
            return std::nullopt;
        }
        if (Consume('.')) {
            if (!ConsumeDigits()) {
                SetError("invalid number fraction");
                return std::nullopt;
            }
        }
        if (Peek('e') || Peek('E')) {
            ++position_;
            if (Peek('+') || Peek('-')) ++position_;
            if (!ConsumeDigits()) {
                SetError("invalid number exponent");
                return std::nullopt;
            }
        }
        return JsonValue::Number(std::string(input_.substr(start, position_ - start)));
    }

    std::optional<JsonValue> ParseLiteral(std::string_view literal, JsonValue value)
    {
        if (input_.substr(position_, literal.size()) != literal) {
            SetError("invalid JSON literal");
            return std::nullopt;
        }
        position_ += literal.size();
        return value;
    }

    bool ConsumeDigits()
    {
        const std::size_t start = position_;
        while (position_ < input_.size() && input_[position_] >= '0' && input_[position_] <= '9') {
            ++position_;
        }
        return position_ > start;
    }

    void SkipWhitespace()
    {
        while (position_ < input_.size()) {
            const char value = input_[position_];
            if (value != ' ' && value != '\n' && value != '\r' && value != '\t') break;
            ++position_;
        }
    }

    bool Consume(char expected)
    {
        if (!Peek(expected)) return false;
        ++position_;
        return true;
    }

    bool Peek(char expected) const
    {
        return position_ < input_.size() && input_[position_] == expected;
    }

    void SetError(std::string message)
    {
        if (error_.empty()) error_ = std::move(message);
    }

    std::string_view input_;
    std::size_t position_ = 0;
    std::string error_;
};

} // namespace

JsonParseResult ParseJson(std::string_view input)
{
    return Parser(input).Parse();
}

} // namespace second_display::protocol

