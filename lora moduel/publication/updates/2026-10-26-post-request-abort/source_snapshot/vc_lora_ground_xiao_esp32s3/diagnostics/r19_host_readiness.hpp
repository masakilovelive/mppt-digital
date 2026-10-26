#pragma once

#include <cstddef>
#include <cstdint>
#include <limits>
#include "high_speed/r19_usb_clock_sync.hpp"

namespace vc_lora::experimental {

// This is an OPT-IN USB-only diagnostic protocol. It is not MAVLink flight
// arming, authentication, proof of a kernel-pending Read, or a product startup
// policy. Never forward this reserved namespace to RF, Pixhawk, or a GCS.
// In particular, receipt of an OUT request does not prove that the PC read IN.
enum class R19HostReadinessMode : std::uint8_t {
  Disabled = 0U, SyncOnly = 1U, ExplicitHostArm = 2U
};
enum class R19HostReadinessRole : std::uint8_t { Ground = 1U, Vehicle = 2U };
enum class R19HostReadinessOpcode : std::uint8_t { Arm = 1U, Ready = 2U };
enum class R19HostReadinessState : std::uint8_t {
  Disabled, WaitingClock, ClockRequested, WaitingArm, Armed,
  TimedOut, EpochAborted, SessionAborted, ClockRegressed, InvalidConfiguration
};

inline constexpr std::uint8_t r19_host_arm_request_component = 195U;
inline constexpr std::uint8_t r19_host_arm_response_component = 196U;
inline constexpr std::uint8_t r19_host_arm_pc_reply_read = 0x01U;
inline constexpr std::uint8_t r19_host_arm_continuous_reader = 0x02U;
inline constexpr std::uint8_t r19_host_arm_required_proof =
    r19_host_arm_pc_reply_read | r19_host_arm_continuous_reader;

struct R19HostReadinessCommand final {
  R19HostReadinessOpcode opcode{R19HostReadinessOpcode::Arm};
  R19HostReadinessRole role{R19HostReadinessRole::Ground};
  std::uint8_t proof_flags{0U};
  std::uint64_t reader_session{0U};
  std::uint64_t nonce{0U};
  std::uint64_t boot_id{0U};
  std::uint32_t usb_epoch{0U};
  std::uint64_t reply_device_us{0U};
};

namespace r19_host_readiness_detail {
inline bool valid_role(R19HostReadinessRole role) noexcept {
  return role == R19HostReadinessRole::Ground ||
         role == R19HostReadinessRole::Vehicle;
}
inline bool valid_command(const R19HostReadinessCommand& command) noexcept {
  const bool arm = command.opcode == R19HostReadinessOpcode::Arm;
  const bool ready = command.opcode == R19HostReadinessOpcode::Ready;
  return (arm || ready) && valid_role(command.role) &&
      command.proof_flags == (arm ? r19_host_arm_required_proof : 0U) &&
      command.reader_session != 0U && command.boot_id != 0U &&
      r19_valid_clock_nonce(command.nonce) &&
      command.reply_device_us != 0U &&
      command.reply_device_us <= static_cast<std::uint64_t>(
          std::numeric_limits<std::int64_t>::max()) / 1000U;
}
inline void store_le(std::uint8_t* out, std::uint64_t value,
                     unsigned width) noexcept {
  for (unsigned i = 0U; i < width; ++i)
    out[i] = static_cast<std::uint8_t>(value >> (8U * i));
}
inline std::uint64_t load_le(const std::uint8_t* in,
                              unsigned width) noexcept {
  std::uint64_t value = 0U;
  for (unsigned i = 0U; i < width; ++i)
    value |= static_cast<std::uint64_t>(in[i]) << (8U * i);
  return value;
}
}  // namespace r19_host_readiness_detail

// Canonical private binary envelope: unsigned MAVLink2 STATUSTEXT, sys249,
// comp195 ARM or comp196 READY, exact payload54/frame66. The payload is NOT
// a human-readable STATUSTEXT; local diagnostic demux must consume it first.
// Offset: 0 R19A(4), 4 version=1, 5 opcode, 6 role, 7 proof,
// 8 reader_session:u64, 16 nonce:u64, 24 boot_id:u64, 32 usb_epoch:u32,
// 36 reply_device_us:u64, 44 reserved zero(8), 52 A5 5A. All integers LE.
// READY teaches the PC the same-boot binding absent from the existing private
// nonce TIMESYNC reply. A new nonce/session must be used after reader teardown.
inline bool r19_is_host_readiness_namespace(const MavlinkFrame& frame) noexcept {
  return frame.system_id == r19_clock_system_id &&
      (frame.component_id == r19_host_arm_request_component ||
       frame.component_id == r19_host_arm_response_component);
}

inline bool r19_encode_host_readiness_frame(std::uint8_t sequence,
    const R19HostReadinessCommand& command, MavlinkFrame& frame) noexcept {
  using namespace r19_host_readiness_detail;
  if (!valid_command(command)) return false;
  std::uint8_t payload[54]{};
  payload[0] = 'R'; payload[1] = '1'; payload[2] = '9'; payload[3] = 'A';
  payload[4] = 1U;
  payload[5] = static_cast<std::uint8_t>(command.opcode);
  payload[6] = static_cast<std::uint8_t>(command.role);
  payload[7] = command.proof_flags;
  store_le(payload + 8U, command.reader_session, 8U);
  store_le(payload + 16U, command.nonce, 8U);
  store_le(payload + 24U, command.boot_id, 8U);
  store_le(payload + 32U, command.usb_epoch, 4U);
  store_le(payload + 36U, command.reply_device_us, 8U);
  payload[52] = 0xA5U; payload[53] = 0x5AU;
  return encode_mavlink_v2(sequence, r19_clock_system_id,
      command.opcode == R19HostReadinessOpcode::Arm
          ? r19_host_arm_request_component : r19_host_arm_response_component,
      253U, payload, sizeof(payload), frame);
}

inline bool r19_decode_host_readiness_frame(const MavlinkFrame& frame,
    R19HostReadinessCommand& command) noexcept {
  using namespace r19_host_readiness_detail;
  if (frame.size != 66U || frame.bytes[2] != 0U || frame.bytes[3] != 0U)
    return false;
  MavlinkFrame validated{};
  if (validate_mavlink_frame(frame.bytes.data(), frame.size, validated) !=
          MavlinkParseStatus::FrameReady ||
      !r19_is_host_readiness_namespace(validated) ||
      validated.message_id != 253U || validated.version != MavlinkVersion::V2 ||
      validated.signed_frame || validated.payload_length != 54U) return false;
  const auto* payload = validated.payload();
  if (payload[0] != 'R' || payload[1] != '1' || payload[2] != '9' ||
      payload[3] != 'A' || payload[4] != 1U ||
      payload[52] != 0xA5U || payload[53] != 0x5AU) return false;
  for (unsigned i = 44U; i < 52U; ++i)
    if (payload[i] != 0U) return false;
  R19HostReadinessCommand parsed{};
  parsed.opcode = static_cast<R19HostReadinessOpcode>(payload[5]);
  parsed.role = static_cast<R19HostReadinessRole>(payload[6]);
  parsed.proof_flags = payload[7];
  parsed.reader_session = load_le(payload + 8U, 8U);
  parsed.nonce = load_le(payload + 16U, 8U);
  parsed.boot_id = load_le(payload + 24U, 8U);
  parsed.usb_epoch = static_cast<std::uint32_t>(load_le(payload + 32U, 4U));
  parsed.reply_device_us = load_le(payload + 36U, 8U);
  if (!valid_command(parsed) || validated.component_id !=
      (parsed.opcode == R19HostReadinessOpcode::Arm
          ? r19_host_arm_request_component : r19_host_arm_response_component))
    return false;
  command = parsed;
  return true;
}

struct R19HostReadinessSnapshot final {
  R19HostReadinessMode mode{R19HostReadinessMode::Disabled};
  R19HostReadinessRole role{R19HostReadinessRole::Ground};
  R19HostReadinessState state{R19HostReadinessState::Disabled};
  std::uint64_t boot_id{0U};
  std::uint64_t reader_session{0U};
  std::uint64_t nonce{0U};
  std::uint64_t request_device_us{0U};
  std::uint64_t reply_device_us{0U};
  std::uint64_t deadline_us{0U};
  std::uint64_t armed_device_us{0U};
  std::uint32_t usb_epoch{0U};
  bool pc_reply_read_claimed{false};
  bool continuous_reader_claimed{false};
};

// Single-owner task context, fixed storage, no Arduino/clock/heap access.
// This does not change USB writes, the 106ms completion contract, radio/TDD,
// diagnostics, MAVLink parsing, or Pixhawk traffic. The caller may consult the
// admission method before ANY initial Ground USB product enqueue, keeping the
// pre-ARM boundary clean. It must keep servicing diagnostics, MAVLink input,
// RF/Pixhawk and all other work while this gate waits or fails closed.
class R19HostReadinessGate final {
 public:
  bool begin_session(R19HostReadinessMode mode, R19HostReadinessRole role,
      std::uint64_t boot_id, std::uint32_t usb_epoch,
      std::uint64_t reader_session, std::uint64_t now_us,
      std::uint64_t arm_timeout_us) noexcept {
    if (begun_) return false;
    begun_ = true;
    state_.mode = mode; state_.role = role;
    if (mode == R19HostReadinessMode::Disabled) return true;
    state_.state = R19HostReadinessState::InvalidConfiguration;
    if ((mode != R19HostReadinessMode::SyncOnly &&
         mode != R19HostReadinessMode::ExplicitHostArm) ||
        !r19_host_readiness_detail::valid_role(role) || boot_id == 0U ||
        reader_session == 0U || arm_timeout_us == 0U ||
        arm_timeout_us > std::numeric_limits<std::uint64_t>::max() - now_us)
      return false;
    state_.boot_id = boot_id; state_.usb_epoch = usb_epoch;
    state_.reader_session = reader_session;
    state_.deadline_us = now_us + arm_timeout_us;
    last_device_us_ = now_us;
    state_.state = R19HostReadinessState::WaitingClock;
    return true;
  }

  bool observe_clock_request(std::uint64_t nonce, std::uint32_t usb_epoch,
                              std::uint64_t now_us) noexcept {
    if (!advance(usb_epoch, state_.reader_session, now_us) ||
        state_.state != R19HostReadinessState::WaitingClock ||
        !r19_valid_clock_nonce(nonce)) return false;
    state_.nonce = nonce; state_.request_device_us = now_us;
    state_.state = R19HostReadinessState::ClockRequested;
    return true;
  }

  // Call only after accepting publication of this matching reply to the USB
  // diagnostic egress. Publication is not proof of delivery to the PC.
  bool record_clock_reply(std::uint64_t nonce, std::uint64_t reply_device_us,
      std::uint32_t usb_epoch, std::uint64_t now_us) noexcept {
    if (!advance(usb_epoch, state_.reader_session, now_us) ||
        state_.state != R19HostReadinessState::ClockRequested ||
        nonce != state_.nonce || reply_device_us == 0U ||
        reply_device_us < state_.request_device_us || reply_device_us > now_us ||
        reply_device_us > static_cast<std::uint64_t>(
            std::numeric_limits<std::int64_t>::max()) / 1000U) return false;
    state_.reply_device_us = reply_device_us;
    state_.state = R19HostReadinessState::WaitingArm;
    return true;
  }

  bool ready_command(R19HostReadinessCommand& command) const noexcept {
    if (state_.state != R19HostReadinessState::WaitingArm) return false;
    command = R19HostReadinessCommand{};
    command.opcode = R19HostReadinessOpcode::Ready;
    command.role = state_.role; command.reader_session = state_.reader_session;
    command.nonce = state_.nonce; command.boot_id = state_.boot_id;
    command.usb_epoch = state_.usb_epoch;
    command.reply_device_us = state_.reply_device_us;
    return true;
  }

  bool accept_arm(const R19HostReadinessCommand& command,
      std::uint32_t current_usb_epoch, std::uint64_t now_us) noexcept {
    if (!advance(current_usb_epoch, state_.reader_session, now_us) ||
        state_.mode != R19HostReadinessMode::ExplicitHostArm ||
        state_.role != R19HostReadinessRole::Ground ||
        state_.state != R19HostReadinessState::WaitingArm ||
        !r19_host_readiness_detail::valid_command(command) ||
        command.opcode != R19HostReadinessOpcode::Arm ||
        command.role != state_.role || command.boot_id != state_.boot_id ||
        command.usb_epoch != state_.usb_epoch ||
        command.reader_session != state_.reader_session ||
        command.nonce != state_.nonce ||
        command.reply_device_us != state_.reply_device_us) return false;
    state_.pc_reply_read_claimed = true;
    state_.continuous_reader_claimed = true;
    state_.armed_device_us = now_us;
    state_.state = R19HostReadinessState::Armed;
    return true;
  }

  void poll(std::uint32_t current_usb_epoch,
      std::uint64_t current_reader_session, std::uint64_t now_us) noexcept {
    (void)advance(current_usb_epoch, current_reader_session, now_us);
  }

  bool allow_initial_ground_usb_heartbeat() const noexcept {
    if (state_.mode == R19HostReadinessMode::Disabled ||
        state_.mode == R19HostReadinessMode::SyncOnly) return true;
    if (state_.mode != R19HostReadinessMode::ExplicitHostArm) return false;
    return state_.role == R19HostReadinessRole::Vehicle ||
        (state_.role == R19HostReadinessRole::Ground &&
         state_.state == R19HostReadinessState::Armed);
  }
  bool allow_ground_usb_product_admission() const noexcept {
    return allow_initial_ground_usb_heartbeat();
  }
  const R19HostReadinessSnapshot& snapshot() const noexcept { return state_; }

 private:
  bool advance(std::uint32_t usb_epoch, std::uint64_t reader_session,
                 std::uint64_t now_us) noexcept {
    if (!begun_ || state_.mode == R19HostReadinessMode::Disabled ||
        state_.state == R19HostReadinessState::TimedOut ||
        state_.state == R19HostReadinessState::EpochAborted ||
        state_.state == R19HostReadinessState::SessionAborted ||
        state_.state == R19HostReadinessState::ClockRegressed ||
        state_.state == R19HostReadinessState::InvalidConfiguration) return false;
    if (usb_epoch != state_.usb_epoch)
      state_.state = R19HostReadinessState::EpochAborted;
    else if (reader_session != state_.reader_session)
      state_.state = R19HostReadinessState::SessionAborted;
    else if (now_us < last_device_us_)
      state_.state = R19HostReadinessState::ClockRegressed;
    else if (state_.state != R19HostReadinessState::Armed &&
             now_us > state_.deadline_us)
      state_.state = R19HostReadinessState::TimedOut;
    else { last_device_us_ = now_us; return true; }
    return false;
  }

  R19HostReadinessSnapshot state_{};
  std::uint64_t last_device_us_{0U};
  bool begun_{false};
};

static_assert(sizeof(R19HostReadinessGate) <= 128U,
              "host readiness is a bounded diagnostic record, not a queue");

}  // namespace vc_lora::experimental
