#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "vc_lora/tdd_control_codec.hpp"

namespace vc_lora {

// Strong typing is intentional: a XIAO header label is not necessarily the
// same integer as the ESP32 GPIO behind that header.  The Arduino adapter must
// explicitly map each label to its board variant's Dn symbol.
enum class XiaoHeaderPin : std::uint8_t {
  D0 = 0U,
  D1 = 1U,
  D2 = 2U,
  D3 = 3U,
  D4 = 4U,
  D5 = 5U,
  D6 = 6U,
  D7 = 7U,
  D8 = 8U,
  D9 = 9U,
  D10 = 10U,
};

// These values are the product wiring/configuration contract.
struct FixedFirmwareContract {
  static inline constexpr XiaoHeaderPin e220_m0_pin = XiaoHeaderPin::D0;
  static inline constexpr XiaoHeaderPin e220_m1_pin = XiaoHeaderPin::D1;
  static inline constexpr XiaoHeaderPin e220_uart_tx_pin = XiaoHeaderPin::D2;
  static inline constexpr XiaoHeaderPin e220_uart_rx_pin = XiaoHeaderPin::D3;
  static inline constexpr XiaoHeaderPin pixhawk_uart_tx_pin =
      XiaoHeaderPin::D6;
  static inline constexpr XiaoHeaderPin pixhawk_uart_rx_pin =
      XiaoHeaderPin::D7;
  static inline constexpr XiaoHeaderPin e220_aux_pin = XiaoHeaderPin::D8;

  static inline constexpr std::uint32_t pixhawk_uart_bps = 57600U;
  static inline constexpr std::uint32_t e220_uart_bps = 115200U;
  static inline constexpr std::uint32_t e220_air_bps = 19200U;
  static inline constexpr std::size_t radio_chunk_bytes = 32U;
  static inline constexpr std::uint32_t partial_flush_ms = 50U;
  static inline constexpr std::uint32_t min_tx_gap_ms = 180U;
  // HIL observation on the fixed 19.2-kbps/32-byte E220 profile. AUX HIGH
  // only proves UART/internal-buffer admission; it does not prove that the
  // subpacket has completed its over-air service. Keep radio_busy asserted
  // for at least this interval after an all-bytes UART acceptance.
  static inline constexpr std::uint32_t e220_subpacket_service_floor_ms =
      550U;
  static inline constexpr std::uint32_t aux_high_stable_ms = 15U;
  static inline constexpr std::uint32_t aux_transition_timeout_ms = 2000U;
  static inline constexpr std::uint32_t downlink_send_ms = 3000U;
  static inline constexpr std::uint32_t uplink_guard_ms = 650U;
  static inline constexpr std::uint32_t uplink_window_ms = 300U;
  static inline constexpr std::uint32_t vehicle_receive_timeout_ms = 2000U;
  static inline constexpr std::uint32_t return_guard_ms = 650U;
  static inline constexpr std::uint32_t late_terminal_wait_ms = 1300U;
  static inline constexpr std::uint32_t heartbeat_hard_deadline_ms = 2500U;
  static inline constexpr std::uint32_t heartbeat_grant_reserve_ms =
      e220_subpacket_service_floor_ms + uplink_guard_ms +
      vehicle_receive_timeout_ms + late_terminal_wait_ms +
      e220_subpacket_service_floor_ms;

  static inline constexpr std::array<std::uint8_t, 8> e220_profile{{
      0x00U, 0x00U, 0xE5U, 0xC3U, 0x46U, 0x00U, 0x00U, 0x00U}};
};

static_assert(FixedFirmwareContract::e220_m0_pin == XiaoHeaderPin::D0,
              "production E220 M0 must remain on D0");
static_assert(FixedFirmwareContract::e220_m1_pin == XiaoHeaderPin::D1,
              "production E220 M1 must remain on D1");
static_assert(FixedFirmwareContract::e220_uart_tx_pin == XiaoHeaderPin::D2,
              "production XIAO TX -> E220 RXD must remain on D2");
static_assert(FixedFirmwareContract::e220_uart_rx_pin == XiaoHeaderPin::D3,
              "production XIAO RX <- E220 TXD must remain on D3");
static_assert(FixedFirmwareContract::pixhawk_uart_tx_pin == XiaoHeaderPin::D6,
              "production XIAO TX -> Pixhawk RX must remain on D6");
static_assert(FixedFirmwareContract::pixhawk_uart_rx_pin == XiaoHeaderPin::D7,
              "production XIAO RX <- Pixhawk TX must remain on D7");
static_assert(FixedFirmwareContract::e220_aux_pin == XiaoHeaderPin::D8,
              "production E220 AUX must remain on D8");
static_assert(FixedFirmwareContract::pixhawk_uart_bps == 57600U,
              "Pixhawk UART baud is a fixed product contract");
static_assert(FixedFirmwareContract::e220_uart_bps == 115200U,
              "E220 UART baud is a fixed product contract");
static_assert(FixedFirmwareContract::e220_air_bps == 19200U,
              "REG0=0xE5 fixes the E220-900T22S air rate at 19.2 kbps");
static_assert(FixedFirmwareContract::radio_chunk_bytes == 32U,
              "E220 physical writes must remain bounded to 32 bytes");
static_assert(FixedFirmwareContract::radio_chunk_bytes ==
                  kTddControlFrameSize,
              "one TDD control frame must equal one physical E220 chunk");
static_assert(FixedFirmwareContract::partial_flush_ms == 50U,
              "partial radio chunks must flush after 50 ms");
static_assert(FixedFirmwareContract::min_tx_gap_ms == 180U,
              "physical radio writes must remain at least 180 ms apart");
static_assert(
    FixedFirmwareContract::e220_subpacket_service_floor_ms == 550U,
    "observed E220 subpacket service floor is a fixed runtime contract");
static_assert(FixedFirmwareContract::downlink_send_ms == 3000U &&
                  FixedFirmwareContract::uplink_guard_ms == 650U &&
                  FixedFirmwareContract::uplink_window_ms == 300U &&
                  FixedFirmwareContract::vehicle_receive_timeout_ms ==
                      2000U &&
                  FixedFirmwareContract::return_guard_ms == 650U,
              "the production TDD schedule is a fixed firmware contract");
static_assert(FixedFirmwareContract::late_terminal_wait_ms == 1300U,
              "timeout-originated terminal wait must remain 1300 ms");
static_assert(FixedFirmwareContract::heartbeat_hard_deadline_ms == 2500U &&
                  FixedFirmwareContract::heartbeat_grant_reserve_ms == 5050U,
              "heartbeat deadline/Grant reserve contract changed");

enum class GroundUsbTransportEpochDisposition : std::uint8_t {
  Unchanged,
  RecoverableBoundary,
  UnsafeLoss,
};

// A HWCDC epoch change is recoverable only at a proven physical-publication
// boundary. bytes_committed is LocalEgress acceptance into HWCDC, whereas
// bytes_published is advanced only after flushTxComplete() proves that every
// accepted byte crossed the host-pickup boundary. Any active commit, retained
// LocalEgress byte, or watermark mismatch leaves delivery uncertain and must
// retain the production fail-closed behavior.
struct GroundUsbTransportEpochSnapshot {
  std::uint32_t known_epoch{0U};
  std::uint32_t observed_epoch{0U};
  std::uint64_t bytes_committed{0U};
  std::uint64_t bytes_published{0U};
  bool heartbeat_commit_active{false};
  bool parameter_commit_active{false};
  bool write_pending{false};
  std::size_t queued_bytes{0U};
};

constexpr GroundUsbTransportEpochDisposition
assess_ground_usb_transport_epoch(
    const GroundUsbTransportEpochSnapshot& snapshot) noexcept {
  if (snapshot.observed_epoch == snapshot.known_epoch) {
    return GroundUsbTransportEpochDisposition::Unchanged;
  }
  const bool delivery_uncertain =
      snapshot.heartbeat_commit_active ||
      snapshot.parameter_commit_active || snapshot.write_pending ||
      snapshot.queued_bytes != 0U ||
      snapshot.bytes_committed != snapshot.bytes_published;
  return delivery_uncertain
             ? GroundUsbTransportEpochDisposition::UnsafeLoss
             : GroundUsbTransportEpochDisposition::RecoverableBoundary;
}

struct BootSessionIdentity {
  std::uint32_t boot_id{0U};
  std::uint16_t session_id{0U};
};

constexpr std::uint32_t next_nonzero_boot_id(
    std::uint32_t previous) noexcept {
  return previous == 0xFFFFFFFFU ? 1U : previous + 1U;
}

constexpr std::uint16_t next_nonzero_session_id(
    std::uint16_t previous) noexcept {
  return previous == 0xFFFFU
             ? static_cast<std::uint16_t>(1U)
             : static_cast<std::uint16_t>(previous + 1U);
}

constexpr BootSessionIdentity next_boot_session(
    BootSessionIdentity previous) noexcept {
  return {next_nonzero_boot_id(previous.boot_id),
          next_nonzero_session_id(previous.session_id)};
}

enum class BootSessionStatus : std::uint8_t {
  AwaitingPersistence,
  Ready,
  FailClosed,
};

enum class BootSessionFault : std::uint8_t {
  None,
  PersistentReadFailed,
  PersistentWriteFailed,
};

// The new identity is deliberately only a candidate until the adapter has
// durably stored it.  This prevents a reset during persistence from reusing a
// wire session that was already exposed to the peer.
class BootSessionProvisioner {
 public:
  explicit BootSessionProvisioner(BootSessionIdentity previous,
                                  bool persistent_read_succeeded) noexcept;

  const BootSessionIdentity& candidate_for_persistence() const noexcept {
    return candidate_;
  }
  void confirm_persisted(bool succeeded) noexcept;
  bool lease(BootSessionIdentity& output) const noexcept;

  BootSessionStatus status() const noexcept { return status_; }
  BootSessionFault fault() const noexcept { return fault_; }
  bool fail_closed() const noexcept {
    return status_ == BootSessionStatus::FailClosed;
  }

 private:
  BootSessionIdentity candidate_{};
  BootSessionStatus status_{BootSessionStatus::FailClosed};
  BootSessionFault fault_{BootSessionFault::PersistentReadFailed};
};

enum class MonotonicTimeStatus : std::uint8_t {
  Uninitialized,
  Valid,
  FailClosed,
};

enum class MonotonicTimeFault : std::uint8_t {
  None,
  AmbiguousOrBackward,
  ExtendedOverflow,
};

// Sampling must occur at least once per 2^31 milliseconds.  Under that
// explicit contract, unsigned subtraction distinguishes one forward wrap from
// a backward/ambiguous jump and extends Arduino-style millis() to uint64_t.
class MonotonicMillis32 {
 public:
  static inline constexpr std::uint32_t max_sample_gap_ms = 0x7FFFFFFFU;

  bool sample(std::uint32_t raw_ms, std::uint64_t& output_ms) noexcept;
  MonotonicTimeStatus status() const noexcept { return status_; }
  MonotonicTimeFault fault() const noexcept { return fault_; }
  bool fail_closed() const noexcept {
    return status_ == MonotonicTimeStatus::FailClosed;
  }

 private:
  std::uint32_t previous_raw_ms_{0U};
  std::uint64_t extended_ms_{0U};
  MonotonicTimeStatus status_{MonotonicTimeStatus::Uninitialized};
  MonotonicTimeFault fault_{MonotonicTimeFault::None};
};

enum class E220WriteState : std::uint8_t {
  WaitingForStableHigh,
  Ready,
  AwaitingWriteResult,
  AwaitingAuxLow,
  AwaitingAuxHigh,
  FailClosed,
};

enum class E220WriteFault : std::uint8_t {
  None,
  InvalidWriteSize,
  UnexpectedWriteResult,
  PartialWrite,
  // Retained for source/telemetry compatibility.  The E220's documented
  // 400-byte buffer does not guarantee a LOW pulse after every <=32-byte
  // UART write, so the production state machine no longer raises this fault.
  AuxDidNotGoLow,
  AuxDidNotReturnHigh,
  NonMonotonicTime,
};

enum class E220WriteDisposition : std::uint8_t {
  AcceptedAll,
  Rejected,
  ContractViolation,
};

// Pure state machine for a physical E220 UART write.  A zero-byte result is a
// safe rejection and may retry the same bytes.  Any partial result is unsafe
// because the transmitted prefix is no longer knowable, so it fails closed.
// A full write completes only after both the observed E220 subpacket service
// floor and a stable AUX HIGH. The E220's documented 400-byte buffer does not
// guarantee a LOW pulse for every <=32-byte UART write. If LOW is observed,
// completion still uses the original full-write acceptance as the service
// floor origin and additionally waits for AUX to return HIGH continuously for
// the production stability interval. Remaining LOW is bounded by the
// transition timeout.
class E220WriteContract {
 public:
  bool observe_aux(bool aux_high, std::uint64_t now_ms) noexcept;
  bool begin_write(std::size_t requested_bytes) noexcept;
  E220WriteDisposition report_write_result(std::size_t written_bytes,
                                           std::uint64_t now_ms,
                                           bool aux_high) noexcept;
  bool take_write_completion() noexcept;

  bool ready_for_write() const noexcept {
    return state_ == E220WriteState::Ready;
  }
  bool fail_closed() const noexcept {
    return state_ == E220WriteState::FailClosed;
  }
  E220WriteState state() const noexcept { return state_; }
  E220WriteFault fault() const noexcept { return fault_; }
  std::size_t requested_bytes() const noexcept { return requested_bytes_; }

 private:
  bool accept_time(std::uint64_t now_ms) noexcept;
  void set_aux(bool aux_high, std::uint64_t now_ms) noexcept;
  void latch_fault(E220WriteFault fault) noexcept;

  E220WriteState state_{E220WriteState::WaitingForStableHigh};
  E220WriteFault fault_{E220WriteFault::None};
  std::size_t requested_bytes_{0U};
  std::uint64_t last_time_ms_{0U};
  std::uint64_t state_since_ms_{0U};
  std::uint64_t write_service_started_ms_{0U};
  std::uint64_t high_since_ms_{0U};
  bool has_time_{false};
  bool aux_high_{false};
  bool tracking_high_{false};
  bool completion_pending_{false};
};

enum class FirmwareStartupStatus : std::uint8_t {
  AwaitingChecks,
  Ready,
  FailClosed,
};

enum class FirmwareStartupFault : std::uint8_t {
  None,
  IdentityNotPersisted,
  ProfileReadInvalid,
  ProfileMismatch,
};

class FirmwareStartupContract {
 public:
  void confirm_identity_persisted(bool succeeded) noexcept;
  bool verify_e220_profile(const std::uint8_t* profile,
                           std::size_t size) noexcept;

  bool transmission_allowed() const noexcept;
  bool fail_closed() const noexcept {
    return fault_ != FirmwareStartupFault::None;
  }
  FirmwareStartupStatus status() const noexcept;
  FirmwareStartupFault fault() const noexcept { return fault_; }

 private:
  void latch_fault(FirmwareStartupFault fault) noexcept;

  bool identity_persisted_{false};
  bool profile_verified_{false};
  FirmwareStartupFault fault_{FirmwareStartupFault::None};
};

}  // namespace vc_lora
