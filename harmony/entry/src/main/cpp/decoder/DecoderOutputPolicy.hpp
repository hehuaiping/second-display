#pragma once

#include <cstdint>

namespace second_display::decoder {

struct DecoderOutputDecision {
    bool render = true;
    bool requestKeyFrame = false;
    bool resetDecoder = false;
};

constexpr DecoderOutputDecision DecideDecoderOutput(
    std::uint64_t latencyUs, std::uint64_t maximumAgeUs, bool hasNewerFrame = true)
{
    // The codec has already decoded this buffer, so discarding only its Surface
    // presentation cannot break the H.264 reference chain. Requesting an IDR or
    // rebuilding the decoder here turns a recoverable late frame into a stall.
    // Always present the newest available output even when the codec releases it
    // late. Otherwise an interaction can finish with the final desktop state
    // discarded and remain visibly one frame behind until the next update.
    if (latencyUs > maximumAgeUs && hasNewerFrame) return {false, false, false};
    return {true, false, false};
}

} // namespace second_display::decoder
