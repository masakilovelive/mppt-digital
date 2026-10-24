#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>

#include "rf_medium_sim.hpp"

namespace vc_lora::test {

class E220Sim {
 public:
  E220Sim(NodeId node, RfMediumSim& medium) noexcept
      : node_(node), medium_(&medium) {}

  TxOutcome write(std::uint64_t now_ms, const std::uint8_t* bytes,
                  std::size_t size) {
    if (!aux_high(now_ms)) {
      return {};
    }
    return medium_->transmit(node_, now_ms, bytes, size);
  }

  bool aux_high(std::uint64_t now_ms) const noexcept {
    return now_ms >= std::max(external_busy_until_ms_,
                              medium_->busy_until(node_)) &&
           medium_->uart_ready(node_, now_ms) &&
           !medium_->rx_active(node_, now_ms);
  }

  bool tx_empty(std::uint64_t now_ms) const noexcept {
    return medium_->tx_empty(node_, now_ms);
  }

  void force_aux_low_until(std::uint64_t physical_ms) noexcept {
    external_busy_until_ms_ =
        std::max(external_busy_until_ms_, physical_ms);
  }

  NodeId node() const noexcept { return node_; }

 private:
  NodeId node_{NodeId::Vehicle};
  RfMediumSim* medium_{nullptr};
  std::uint64_t external_busy_until_ms_{0};
};

}  // namespace vc_lora::test
