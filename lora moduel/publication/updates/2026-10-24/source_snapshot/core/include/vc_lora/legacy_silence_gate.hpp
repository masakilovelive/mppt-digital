#pragma once

#include <cstdint>

namespace vc_lora {

// Characterization model of the pre-GRANT ground logic. It deliberately
// preserves the defect so Phase 1 can prove why silence is not a lease.
class LegacySilenceGroundGate {
 public:
  LegacySilenceGroundGate(std::uint32_t tx_start_ms = 650,
                          std::uint32_t tx_duration_ms = 300,
                          std::uint32_t cycle_ms = 5000) noexcept
      : tx_start_ms_(tx_start_ms),
        tx_end_ms_(tx_start_ms + tx_duration_ms),
        cycle_ms_(cycle_ms) {}

  void reset(std::uint64_t now_ms) noexcept { last_receive_ms_ = now_ms; }
  void note_radio_receive(std::uint64_t now_ms) noexcept {
    last_receive_ms_ = now_ms;
  }

  bool transmit_allowed(std::uint64_t now_ms) noexcept {
    std::uint64_t silence_ms = now_ms - last_receive_ms_;
    if (silence_ms >= cycle_ms_) {
      last_receive_ms_ = now_ms;
      silence_ms = 0;
    }
    return silence_ms >= tx_start_ms_ && silence_ms < tx_end_ms_;
  }

 private:
  std::uint32_t tx_start_ms_{650};
  std::uint32_t tx_end_ms_{950};
  std::uint32_t cycle_ms_{5000};
  std::uint64_t last_receive_ms_{0};
};

}  // namespace vc_lora
