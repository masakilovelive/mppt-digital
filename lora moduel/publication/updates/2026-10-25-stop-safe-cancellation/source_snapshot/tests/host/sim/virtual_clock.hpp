#pragma once

#include <cstdint>

namespace vc_lora::test {

class VirtualClock {
 public:
  std::uint64_t now_ms() const noexcept { return now_ms_; }
  void advance_ms(std::uint64_t delta_ms) noexcept { now_ms_ += delta_ms; }
  void set_ms(std::uint64_t value_ms) noexcept { now_ms_ = value_ms; }

 private:
  std::uint64_t now_ms_{0};
};

class LocalClock {
 public:
  LocalClock(std::int64_t offset_ms = 0, std::int32_t skew_ppm = 0) noexcept
      : offset_ms_(offset_ms), skew_ppm_(skew_ppm) {}

  std::uint64_t now_ms(std::uint64_t physical_ms) const noexcept {
    const auto scaled = static_cast<std::int64_t>(
        (physical_ms * static_cast<std::uint64_t>(1'000'000 + skew_ppm_)) /
        1'000'000U);
    const std::int64_t local = scaled + offset_ms_;
    return local < 0 ? 0U : static_cast<std::uint64_t>(local);
  }

 private:
  std::int64_t offset_ms_{0};
  std::int32_t skew_ppm_{0};
};

}  // namespace vc_lora::test
