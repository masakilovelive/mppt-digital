#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <vector>

#include "vc_lora/link_diagnostics.hpp"

namespace vc_lora::test {

enum class NodeId : std::uint8_t { Vehicle = 0, Ground = 1 };

constexpr std::size_t kMaxSimFrameBytes = 512;

struct RfMediumConfig {
  std::uint32_t uart_rate_bps{115'200};
  std::uint32_t air_rate_bps{19'200};
  std::uint16_t sub_packet_bytes{32};
  std::uint16_t min_tx_gap_ms{180};
  std::uint16_t turnaround_ms{500};
  std::uint16_t propagation_delay_ms{0};
  std::uint16_t uart_buffer_bytes{400};
  std::uint16_t loss_permyriad{0};
  std::uint16_t corruption_permyriad{0};
  // Test-only buffered-radio mode.  Zero preserves the original immediate
  // RF model.  A non-zero value separates local UART/AUX admission from
  // over-air service: accepted bytes occupy the E220's internal buffer while
  // each subpacket consumes this many milliseconds on air.
  std::uint16_t buffered_air_subpacket_service_ms{0};
};

struct SimPayload {
  std::array<std::uint8_t, kMaxSimFrameBytes> bytes{};
  std::size_t size{0};
};

struct RfDelivery {
  NodeId sender{NodeId::Vehicle};
  NodeId receiver{NodeId::Ground};
  std::uint64_t start_ms{0};
  std::uint64_t ready_ms{0};
  SimPayload payload{};
};

struct TxOutcome {
  bool accepted{false};
  std::uint64_t tx_id{0};
  std::uint64_t end_ms{0};
};

class RfMediumSim {
 public:
  RfMediumSim(const RfMediumConfig& config, std::uint32_t seed,
              LinkDiagnostics& diagnostics);

  TxOutcome transmit(NodeId sender, std::uint64_t now_ms,
                     const std::uint8_t* bytes, std::size_t size);
  void advance(std::uint64_t now_ms);
  bool pop_delivery(NodeId receiver, std::uint64_t now_ms,
                    RfDelivery& output);

  bool tx_empty(NodeId node, std::uint64_t now_ms) const noexcept;
  bool rx_active(NodeId node, std::uint64_t now_ms) const noexcept;
  bool uart_ready(NodeId node, std::uint64_t now_ms) const noexcept;
  std::uint64_t busy_until(NodeId node) const noexcept;
  std::uint64_t buffered_bytes(NodeId node) const noexcept;
  std::uint64_t uart_admission_count(NodeId node) const noexcept;
  std::uint64_t air_completion_count(NodeId node) const noexcept;
  std::uint64_t collision_count() const noexcept { return collision_count_; }
  std::uint64_t successful_deliveries() const noexcept {
    return successful_deliveries_;
  }
  std::uint64_t data_tx_count(NodeId node) const noexcept;
  std::uint64_t control_tx_count(NodeId node) const noexcept;
  std::size_t retained_transmission_count() const noexcept {
    return transmissions_.size();
  }
  std::size_t max_retained_transmission_count() const noexcept {
    return max_retained_transmission_count_;
  }
  std::size_t pending_delivery_count() const noexcept {
    return deliveries_.size();
  }
  std::size_t max_pending_delivery_count() const noexcept {
    return max_pending_delivery_count_;
  }
  std::uint64_t random_corruption_injection_count() const noexcept {
    return random_corruption_injection_count_;
  }
  std::uint64_t targeted_corruption_injection_count() const noexcept {
    return targeted_corruption_injection_count_;
  }
  void duplicate_next_control(NodeId sender) noexcept;
  void drop_next_control(NodeId sender) noexcept;
  void corrupt_next_control(NodeId sender) noexcept;

 private:
  struct Transmission {
    std::uint64_t id{0};
    NodeId sender{NodeId::Vehicle};
    std::uint64_t start_ms{0};
    std::uint64_t end_ms{0};
    SimPayload payload{};
    bool collided{false};
    bool turnaround_violation{false};
    bool finalized{false};
  };

  struct FaultFlags {
    bool duplicate_control{false};
    bool drop_control{false};
    bool corrupt_control{false};
  };

  static std::size_t node_index(NodeId node) noexcept;
  static NodeId other(NodeId node) noexcept;
  static bool is_control_payload(const std::uint8_t* bytes,
                                 std::size_t size) noexcept;
  bool receiver_transmitted_during(NodeId receiver,
                                   std::uint64_t start_ms,
                                   std::uint64_t end_ms) const noexcept;
  std::uint64_t duration_ms(std::size_t size) const noexcept;
  std::uint64_t uart_duration_ms(std::size_t size) const noexcept;
  bool random_hit(std::uint16_t permyriad);
  void finalize(Transmission& tx);
  void prune_finalized(std::uint64_t now_ms);
  bool needed_for_pending_delivery(
      const Transmission& transmission) const noexcept;

  RfMediumConfig config_{};
  LinkDiagnostics* diagnostics_{nullptr};
  std::uint32_t random_state_{0};
  std::vector<Transmission> transmissions_{};
  std::deque<RfDelivery> deliveries_{};
  std::array<std::uint64_t, 2> busy_until_{{0, 0}};
  std::array<std::uint64_t, 2> air_available_ms_{{0, 0}};
  std::array<std::uint64_t, 2> buffered_bytes_{{0, 0}};
  std::array<std::uint64_t, 2> uart_admission_count_{{0, 0}};
  std::array<std::uint64_t, 2> air_completion_count_{{0, 0}};
  std::array<std::uint64_t, 2> data_tx_count_{{0, 0}};
  std::array<std::uint64_t, 2> control_tx_count_{{0, 0}};
  std::array<FaultFlags, 2> faults_{};
  std::uint64_t next_tx_id_{1};
  std::uint64_t collision_count_{0};
  std::uint64_t successful_deliveries_{0};
  std::size_t max_retained_transmission_count_{0};
  std::size_t max_pending_delivery_count_{0};
  std::uint64_t random_corruption_injection_count_{0};
  std::uint64_t targeted_corruption_injection_count_{0};
  bool have_direction_{false};
  NodeId last_sender_{NodeId::Vehicle};
  std::uint64_t last_direction_end_ms_{0};
  bool have_pending_finalization_{false};
  std::uint64_t next_finalize_ms_{0};
};

}  // namespace vc_lora::test
