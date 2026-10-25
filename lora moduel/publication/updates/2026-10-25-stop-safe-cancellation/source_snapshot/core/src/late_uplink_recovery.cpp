#include "vc_lora/late_uplink_recovery.hpp"

#include <algorithm>

namespace vc_lora {

void VehicleLateUplinkRecovery::clear_transaction() noexcept {
  parser_ = {};
  bytes_ = {};
  received_bytes_ = 0U;
  buffered_bytes_ = 0U;
  frame_count_ = 0U;
  ready_ = false;
  invalid_ = false;
  overflow_ = false;
}

void VehicleLateUplinkRecovery::begin(std::uint16_t session_id,
                                      std::uint16_t cycle_id) noexcept {
  clear_transaction();
  session_id_ = session_id;
  cycle_id_ = cycle_id;
  active_ = true;
}

LateUplinkIngestStatus VehicleLateUplinkRecovery::ingest(
    std::uint8_t byte) noexcept {
  if (!active_ || ready_) {
    return LateUplinkIngestStatus::Inactive;
  }
  if (overflow_) {
    return LateUplinkIngestStatus::Overflow;
  }
  if (received_bytes_ == kVehicleLateUplinkRecoveryBytes) {
    // Fail the whole transaction immediately.  No prefix survives for a
    // later terminal, and firmware will not start a second quarantine for the
    // same cycle.
    discard();
    return LateUplinkIngestStatus::Overflow;
  }
  ++received_bytes_;

  MavlinkFrame frame{};
  const MavlinkParseStatus status = parser_.push(byte, frame);
  switch (status) {
    case MavlinkParseStatus::NeedMore:
      return LateUplinkIngestStatus::NeedMore;

    case MavlinkParseStatus::FrameReady:
      if (frame.size == 0U ||
          frame.size > bytes_.size() - buffered_bytes_) {
        discard();
        return LateUplinkIngestStatus::Overflow;
      }
      std::copy_n(frame.bytes.data(), frame.size,
                  bytes_.data() + buffered_bytes_);
      buffered_bytes_ += frame.size;
      ++frame_count_;
      return LateUplinkIngestStatus::FrameReady;

    case MavlinkParseStatus::Noise:
    case MavlinkParseStatus::BadLength:
    case MavlinkParseStatus::BadCrc:
    case MavlinkParseStatus::UnsupportedMessage:
    case MavlinkParseStatus::UnsupportedFlags:
      discard();
      return LateUplinkIngestStatus::Invalid;
  }
  discard();
  return LateUplinkIngestStatus::Invalid;
}

LateUplinkTerminalStatus VehicleLateUplinkRecovery::on_terminal(
    const TddControlMessage& message) noexcept {
  if (!active_ || ready_ || message.version != kTddProtocolVersion ||
      (message.type != ControlType::UlDone &&
       message.type != ControlType::UlIdle)) {
    return LateUplinkTerminalStatus::Ignored;
  }

  // A stale terminal must not destroy a current transaction.  The controller
  // still sees it and records its normal stale-session/cycle diagnostic.
  if (message.session_id != session_id_ || message.cycle_id != cycle_id_) {
    return LateUplinkTerminalStatus::Ignored;
  }

  active_ = false;
  const bool terminal_contract_valid =
      message.guard_ms == 0U && message.window_ms == 0U &&
      message.max_bytes == kVehicleLateUplinkRecoveryBytes;
  if (message.type == ControlType::UlIdle && terminal_contract_valid &&
      message.actual_bytes == 0U && received_bytes_ == 0U &&
      buffered_bytes_ == 0U && frame_count_ == 0U &&
      parser_.buffered_size() == 0U && !invalid_ && !overflow_) {
    clear_transaction();
    return LateUplinkTerminalStatus::Idle;
  }
  if (message.type != ControlType::UlDone || !terminal_contract_valid ||
      invalid_ || overflow_ || received_bytes_ == 0U ||
      message.actual_bytes == 0U || frame_count_ == 0U ||
      parser_.buffered_size() != 0U ||
      buffered_bytes_ != received_bytes_ ||
      message.actual_bytes != received_bytes_) {
    clear_transaction();
    return LateUplinkTerminalStatus::Discarded;
  }

  ready_ = true;
  return LateUplinkTerminalStatus::Ready;
}

bool VehicleLateUplinkRecovery::take_commit(
    std::uint8_t* output, std::size_t output_capacity,
    std::size_t& output_size, std::uint16_t& output_frames) noexcept {
  output_size = 0U;
  output_frames = 0U;
  if (!ready_ || output == nullptr || buffered_bytes_ == 0U ||
      output_capacity < buffered_bytes_) {
    return false;
  }

  std::copy_n(bytes_.data(), buffered_bytes_, output);
  output_size = buffered_bytes_;
  output_frames = frame_count_;
  clear_transaction();
  active_ = false;
  return true;
}

void VehicleLateUplinkRecovery::discard() noexcept {
  clear_transaction();
  active_ = false;
}

void VehicleLateUplinkRecovery::reset() noexcept {
  discard();
  session_id_ = 0U;
  cycle_id_ = 0U;
}

}  // namespace vc_lora
