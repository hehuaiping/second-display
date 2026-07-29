#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace second_display::decoder {

/// 固定容量延迟窗口。写入时覆盖最旧样本，避免长时间运行产生无界分配。
template <std::size_t Capacity>
class LatencyWindow {
    static_assert(Capacity > 0, "LatencyWindow capacity must be positive");

public:
    void Add(std::uint64_t value)
    {
        values_[writeIndex_] = value;
        writeIndex_ = (writeIndex_ + 1) % Capacity;
        size_ = std::min(size_ + 1, Capacity);
    }

    void Reset()
    {
        writeIndex_ = 0;
        size_ = 0;
    }

    std::size_t Size() const
    {
        return size_;
    }

    std::uint64_t Percentile(double percentile) const
    {
        if (size_ == 0) return 0;
        const auto normalized = std::clamp(percentile, 0.0, 1.0);
        auto sorted = values_;
        // 固定容量窗口使用显式插入排序，避免 GCC 13 在小 std::array 上展开
        // std::sort 时产生错误的 -Warray-bounds 诊断；排序范围始终受 size_ 限制。
        for (std::size_t index = 1; index < size_; ++index) {
            const auto value = sorted[index];
            auto insertionIndex = index;
            while (insertionIndex > 0 && sorted[insertionIndex - 1] > value) {
                sorted[insertionIndex] = sorted[insertionIndex - 1];
                --insertionIndex;
            }
            sorted[insertionIndex] = value;
        }
        const auto rank = static_cast<std::size_t>(
            std::ceil(normalized * static_cast<double>(size_)));
        return sorted[std::min(size_ - 1, rank > 0 ? rank - 1 : 0)];
    }

    double Average() const
    {
        if (size_ == 0) return 0;
        long double total = 0;
        for (std::size_t index = 0; index < size_; ++index) {
            total += static_cast<long double>(values_[index]);
        }
        return static_cast<double>(total / static_cast<long double>(size_));
    }

private:
    std::array<std::uint64_t, Capacity> values_ {};
    std::size_t writeIndex_ = 0;
    std::size_t size_ = 0;
};

} // namespace second_display::decoder
