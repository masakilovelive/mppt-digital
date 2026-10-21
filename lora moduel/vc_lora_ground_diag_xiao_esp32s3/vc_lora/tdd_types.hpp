#pragma once

#include <cstddef>
#include <cstdint>

namespace vc_lora {

constexpr std::uint8_t kTddProtocolVersion = 3;

enum class ControlType : std::uint8_t {
  UlGrant = 1,
  UlDone = 2,
  UlIdle = 3,
  LinkStatus = 4,
};

struct TddControlMessage {
  std::uint8_t version{kTddProtocolVersion};
  ControlType type{ControlType::UlGrant};
  std::uint16_t session_id{0};
  std::uint16_t cycle_id{0};
  std::uint16_t guard_ms{0};
  std::uint16_t window_ms{0};
  std::uint16_t max_bytes{0};
  std::uint16_t actual_bytes{0};
};

struct TddConfig {
  std::uint32_t downlink_send_ms{3000};
  std::uint32_t uplink_guard_ms{650};
  std::uint32_t uplink_window_ms{300};
  std::uint32_t vehicle_receive_timeout_ms{2000};
  std::uint32_t return_guard_ms{650};
  // Timeout-originated ReturnGuard keeps the same-cycle Ground lease open
  // longer than the post-terminal direction guard.  The two intervals are
  // intentionally separate: a valid DONE/IDLE still needs only the fixed
  // return_guard_ms quiet period.
  std::uint32_t late_terminal_wait_ms{1300};
  std::uint32_t aux_stable_ms{15};
  std::uint32_t min_tx_gap_ms{180};
  std::uint32_t radio_uart_bps{115200};
  std::uint32_t radio_air_bps{19200};
  std::uint32_t action_retry_timeout_ms{2000};
  // A MAVLink-aware adapter may hold the nominal downlink boundary briefly
  // for one real Pixhawk heartbeat.  This does not change downlink_send_ms;
  // it only bounds how long the controller can wait after that boundary when
  // no heartbeat is available.
  // One nominal 1 Hz period plus 100 ms of polling/jitter margin covers every
  // heartbeat phase while still giving the no-heartbeat path a hard bound.
  std::uint32_t heartbeat_tail_wait_ms{1100};
  std::uint16_t uplink_max_bytes{64};
  std::uint16_t radio_chunk_bytes{32};
  std::uint16_t max_cycle_jump{32};
};

struct TddInput {
  std::uint64_t now_ms{0};
  bool aux_high{true};
  bool radio_tx_empty{true};
  bool local_tx_empty{true};
  std::uint32_t queued_bytes{0};
  // Optional adapter preview for an encoded physical write. Zero preserves
  // the legacy/raw byte estimate. When supplied, Ground schedules exactly
  // this application prefix and checks its actual encoded wire duration.
  std::uint16_t next_tx_application_bytes{0};
  std::uint16_t next_tx_wire_bytes{0};
  // Ground-only descriptor hint. Protocol v3 grants exactly one complete
  // MAVLink frame per cycle; its CRC-valid completion is the transaction
  // terminal, replacing the delayed second UL_DONE subpacket.
  std::uint16_t front_frame_bytes{0};
  // Optional MAVLink-aware downlink boundary hints. Generic/raw adapters leave
  // these false and retain the original immediate-drain behaviour.  The
  // active-frame hints let the controller distinguish an exact heartbeat retry
  // from an ordinary frame that is merely finishing across the boundary.
  bool heartbeat_tail_enabled{false};
  bool heartbeat_tail_available{false};
  bool heartbeat_tail_active{false};
  bool heartbeat_tail_active_started{false};
};

enum class LinkActionType : std::uint8_t {
  None = 0,
  SendGrant,
  SendDone,
  SendRadioData,
};

struct LinkAction {
  LinkActionType type{LinkActionType::None};
  std::uint32_t token{0};
  TddControlMessage control{};
  std::uint16_t byte_budget{0};
};

enum class TxResult : std::uint8_t {
  Accepted,
  Rejected,
};

enum class ControlDisposition : std::uint8_t {
  Accepted,
  Ignored,
  Duplicate,
  OldSession,
  OldCycle,
  FutureCycle,
  Invalid,
};

enum class SequenceOrder : std::uint8_t {
  Duplicate,
  Newer,
  Older,
};

constexpr SequenceOrder compare_sequence(std::uint16_t candidate,
                                         std::uint16_t current) noexcept {
  const auto delta = static_cast<std::uint16_t>(candidate - current);
  if (delta == 0U) {
    return SequenceOrder::Duplicate;
  }
  return delta < 0x8000U ? SequenceOrder::Newer : SequenceOrder::Older;
}

constexpr std::uint16_t sequence_distance(std::uint16_t candidate,
                                          std::uint16_t current) noexcept {
  return static_cast<std::uint16_t>(candidate - current);
}

constexpr bool valid_control_type(ControlType type) noexcept {
  return type == ControlType::UlGrant || type == ControlType::UlDone ||
         type == ControlType::UlIdle || type == ControlType::LinkStatus;
}

}  // namespace vc_lora
