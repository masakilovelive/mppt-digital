#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/tdd_types.hpp"

namespace vc_lora {

// The product grant is fixed at 64 application bytes.  Keep the complete
// transaction outside the Pixhawk egress queue until a byte-exact UL_DONE
// proves that it belongs to this session/cycle and contains only complete,
// validated MAVLink frames.
constexpr std::size_t kVehicleLateUplinkRecoveryBytes = 64U;

enum class LateUplinkIngestStatus : std::uint8_t {
  NeedMore,
  FrameReady,
  Invalid,
  Overflow,
  Inactive,
};

enum class LateUplinkTerminalStatus : std::uint8_t {
  Ignored,
  Discarded,
  Idle,
  Ready,
};

class VehicleLateUplinkRecovery {
 public:
  void begin(std::uint16_t session_id, std::uint16_t cycle_id) noexcept;
  LateUplinkIngestStatus ingest(std::uint8_t byte) noexcept;
  LateUplinkTerminalStatus on_terminal(
      const TddControlMessage& message) noexcept;

  // Copies a validated transaction at most once.  An insufficient output
  // capacity leaves it ready so the caller can fail closed without losing the
  // evidence before deciding how to recover.
  bool take_commit(std::uint8_t* output, std::size_t output_capacity,
                   std::size_t& output_size,
                   std::uint16_t& output_frames) noexcept;

  void discard() noexcept;
  void reset() noexcept;

  bool active() const noexcept { return active_; }
  bool ready() const noexcept { return ready_; }
  std::uint16_t session_id() const noexcept { return session_id_; }
  std::uint16_t cycle_id() const noexcept { return cycle_id_; }
  std::size_t received_bytes() const noexcept { return received_bytes_; }
  std::size_t buffered_bytes() const noexcept { return buffered_bytes_; }
  std::uint16_t frame_count() const noexcept { return frame_count_; }

 private:
  void clear_transaction() noexcept;

  MavlinkStreamParser parser_{};
  std::array<std::uint8_t, kVehicleLateUplinkRecoveryBytes> bytes_{};
  std::uint16_t session_id_{0U};
  std::uint16_t cycle_id_{0U};
  std::size_t received_bytes_{0U};
  std::size_t buffered_bytes_{0U};
  std::uint16_t frame_count_{0U};
  bool active_{false};
  bool ready_{false};
  bool invalid_{false};
  bool overflow_{false};
};

}  // namespace vc_lora
