#pragma once

#include <cstdint>

namespace vc_lora {

enum class DecodeStatus : std::uint8_t;

struct LinkDiagnostics {
  std::uint64_t grant_tx{0};
  std::uint64_t grant_rx{0};
  std::uint64_t done_tx{0};
  std::uint64_t done_rx{0};
  std::uint64_t idle_tx{0};
  std::uint64_t idle_rx{0};
  std::uint64_t uplink_transactions{0};
  std::uint64_t uplink_payload_bytes{0};
  std::uint64_t downlink_transactions{0};
  std::uint64_t downlink_payload_bytes{0};
  std::uint64_t uplink_timeouts{0};
  std::uint64_t expired_windows{0};
  std::uint64_t insufficient_window_count{0};
  std::uint64_t action_retries{0};
  // A Ground transaction consumed at least one application byte but could
  // not physically finish DATA+UL_DONE inside its absolute receive lease.
  // Such a transaction is unrecoverable without reboot and is counted once.
  std::uint64_t abandoned_uplink_transactions{0};
  std::uint64_t duplicate_grants{0};
  std::uint64_t stale_cycles{0};
  std::uint64_t future_cycles{0};
  std::uint64_t stale_sessions{0};
  std::uint64_t session_changes{0};
  std::uint64_t invalid_done{0};
  std::uint64_t control_crc_errors{0};
  std::uint64_t control_unknown_version{0};
  std::uint64_t control_unknown_type{0};
  std::uint64_t control_malformed{0};
  std::uint64_t invalid_crc_state_transition{0};
  std::uint64_t tx_gate_violation{0};
  std::uint64_t tx_during_rx_window_count{0};
  std::uint64_t ground_tx_without_valid_grant{0};
  std::uint64_t control_bytes_leaked_to_local_uart{0};
  std::uint64_t collision_count{0};
  std::uint64_t packet_loss_count{0};
  std::uint64_t turnaround_drop_count{0};
  std::uint64_t half_duplex_drop_count{0};
  std::uint64_t uart_buffer_drop_count{0};
  std::uint64_t uplink_data_outside_receive_window{0};
  std::uint64_t ground_usb_rx_bytes{0};
  std::uint64_t ground_usb_accepted_bytes{0};
  std::uint64_t ground_usb_dropped_bytes{0};
  std::uint64_t ground_usb_dequeued_bytes{0};
  std::uint64_t ground_buffer_overflow_count{0};
  std::uint64_t ground_payload_order_errors{0};
  std::uint64_t ground_queue_underflow_count{0};
  std::uint64_t mavlink_frames_ingested{0};
  std::uint64_t mavlink_frames_forwarded{0};
  std::uint64_t mavlink_frames_filtered{0};
  std::uint64_t mavlink_msg194_filtered_frames{0};
  std::uint64_t mavlink_msg194_filtered_bytes{0};
  std::uint64_t mavlink_crc_errors{0};
  std::uint64_t mavlink_parser_resets{0};
  std::uint64_t mavlink_queue_drop_frames{0};
  std::uint64_t mavlink_queue_drop_bytes{0};
  std::uint64_t partial_mavlink_delivered{0};
  std::uint64_t max_mavlink_queue_frames{0};
  std::uint64_t max_mavlink_queue_bytes{0};
  std::uint64_t heartbeat_valid{0};
  std::uint64_t heartbeat_max_gap_ms{0};
  std::uint64_t heartbeat_grant_deferrals{0};
  std::uint64_t heartbeat_deadline_misses{0};
  std::uint64_t param_requests_rx{0};
  std::uint64_t param_values_rx{0};
  std::uint64_t param_sets_rx{0};
  std::uint64_t param_updates{0};
  std::uint64_t command_long_rx{0};
  std::uint64_t command_ack_rx{0};
  std::uint64_t max_vehicle_queue{0};
  std::uint64_t max_ground_queue{0};

  void clear() noexcept;
  void note_decode_status(DecodeStatus status) noexcept;
};

}  // namespace vc_lora
