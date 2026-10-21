#pragma once

// Production Arduino adapter for the deterministic Phase 6 core.  This file
// is included once by either S3 sketch.  All protocol decisions remain in the
// Arduino-free core; this layer only owns XIAO pins, UART/USB, NVS and AUX.

#if (defined(VC_LORA_PHASE6_VEHICLE) + defined(VC_LORA_PHASE6_GROUND)) != 1
#error "Define exactly one VC_LORA_PHASE6_VEHICLE/VC_LORA_PHASE6_GROUND role"
#endif

#include <Arduino.h>
#include <Preferences.h>
#include <esp_timer.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include <vc_lora/embedded_io_adapter.hpp>
#include <vc_lora/late_uplink_recovery.hpp>
#include <vc_lora/link_data_codec.hpp>
#include <vc_lora/link_diagnostics.hpp>
#include <vc_lora/mavlink_frame.hpp>
#include <vc_lora/mavlink_scheduler.hpp>
#include <vc_lora/runtime_contract.hpp>
#include <vc_lora/tdd_control_codec.hpp>
#include <vc_lora/tdd_ground.hpp>
#include <vc_lora/tdd_link_demux.hpp>
#include <vc_lora/tdd_vehicle.hpp>
#include <vc_lora/tx_gate.hpp>

#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
#include "vc_lora_ground_diag_observer.hpp"
#endif

namespace vc_lora_phase6_firmware {

using namespace vc_lora;

constexpr int xiao_board_pin(XiaoHeaderPin pin) noexcept {
  switch (pin) {
    case XiaoHeaderPin::D0:
      return D0;
    case XiaoHeaderPin::D1:
      return D1;
    case XiaoHeaderPin::D2:
      return D2;
    case XiaoHeaderPin::D3:
      return D3;
    case XiaoHeaderPin::D4:
      return D4;
    case XiaoHeaderPin::D5:
      return D5;
    case XiaoHeaderPin::D6:
      return D6;
    case XiaoHeaderPin::D7:
      return D7;
    case XiaoHeaderPin::D8:
      return D8;
    case XiaoHeaderPin::D9:
      return D9;
    case XiaoHeaderPin::D10:
      return D10;
  }
  return -1;
}

constexpr int kE220M0Pin =
    xiao_board_pin(FixedFirmwareContract::e220_m0_pin);
constexpr int kE220M1Pin =
    xiao_board_pin(FixedFirmwareContract::e220_m1_pin);
constexpr int kE220TxPin =
    xiao_board_pin(FixedFirmwareContract::e220_uart_tx_pin);
constexpr int kE220RxPin =
    xiao_board_pin(FixedFirmwareContract::e220_uart_rx_pin);
constexpr int kE220AuxPin =
    xiao_board_pin(FixedFirmwareContract::e220_aux_pin);
constexpr int kPixhawkTxPin =
    xiao_board_pin(FixedFirmwareContract::pixhawk_uart_tx_pin);
constexpr int kPixhawkRxPin =
    xiao_board_pin(FixedFirmwareContract::pixhawk_uart_rx_pin);

static_assert(kE220M0Pin == D0 && kE220M1Pin == D1,
              "E220 mode wiring must remain D0/D1");
static_assert(kE220TxPin == D2 && kE220RxPin == D3,
              "E220 UART wiring must remain TX D2 / RX D3");
static_assert(kE220AuxPin == D8, "E220 AUX wiring must remain D8");
static_assert(kPixhawkTxPin == D6 && kPixhawkRxPin == D7,
              "Pixhawk UART wiring must remain TX D6 / RX D7");
static_assert(FixedFirmwareContract::pixhawk_uart_bps == 57600U &&
                  FixedFirmwareContract::e220_uart_bps == 115200U,
              "production UART rates changed");
static_assert(FixedFirmwareContract::radio_chunk_bytes == 32U &&
                  FixedFirmwareContract::partial_flush_ms == 50U &&
                  FixedFirmwareContract::min_tx_gap_ms == 180U,
              "production E220 transaction contract changed");
static_assert(FixedFirmwareContract::radio_chunk_bytes ==
                  kTddControlFrameSize,
              "one TDD control frame must equal one physical E220 chunk");
static_assert(FixedFirmwareContract::downlink_send_ms == 3000U &&
                  FixedFirmwareContract::uplink_guard_ms == 650U &&
                  FixedFirmwareContract::uplink_window_ms == 300U &&
                  FixedFirmwareContract::vehicle_receive_timeout_ms ==
                      2000U &&
                  FixedFirmwareContract::return_guard_ms == 650U,
              "production TDD schedule changed");

#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
static_assert(kTddProtocolVersion == 3U &&
                  kTddControlFrameSize == 32U,
              "Ground diagnostics require control protocol v3 exact-32");
#endif

constexpr std::size_t kSerialRxBytes = 4096U;
constexpr std::size_t kLoopReadBudget = 512U;
constexpr std::uint32_t kConfigResponseTimeoutMs = 500U;
constexpr std::uint32_t kConfigAuxTimeoutMs = 2000U;
constexpr char kPreferencesNamespace[] = "vc_lora_p6";
constexpr char kIdentityKey[] = "identity";

HardwareSerial e220_serial(1);
#if defined(VC_LORA_PHASE6_VEHICLE)
HardwareSerial pixhawk_serial(2);
#endif

FirmwareStartupContract startup_contract{};
E220WriteContract e220_write_contract{};
BootSessionIdentity boot_identity{};
LinkDiagnostics link_diagnostics{};
TddLinkDemux radio_demux(true);
#if defined(VC_LORA_PHASE6_GROUND)
// Mission Planner may leave the CDC port unopened for an arbitrary time.
// Preserve complete-frame FIFO order while capacity remains; once full, drop
// only the newly validated frame and keep TDD/radio operation live so opening
// the port later drains the preserved stream and resumes automatically.
MavlinkValidatedLocalEgressAdapter<
    kLocalEgressBytes, kEmbeddedPhysicalWriteBytes,
    LocalEgressOverflowPolicy::DropNewestFrame>
    radio_application_endpoint{};
#else
// Pixhawk UART backpressure is a wiring/runtime fault, so Vehicle retains the
// stricter fail-closed policy.
MavlinkValidatedLocalEgressAdapter<> radio_application_endpoint{};
#endif
bool bridge_ready{false};
bool runtime_fail_closed{false};
bool radio_busy{false};

constexpr TddConfig product_tdd_config() noexcept {
  TddConfig config{};
  config.downlink_send_ms = FixedFirmwareContract::downlink_send_ms;
  config.uplink_guard_ms = FixedFirmwareContract::uplink_guard_ms;
  config.uplink_window_ms = FixedFirmwareContract::uplink_window_ms;
  config.vehicle_receive_timeout_ms =
      FixedFirmwareContract::vehicle_receive_timeout_ms;
  config.return_guard_ms = FixedFirmwareContract::return_guard_ms;
  config.aux_stable_ms = FixedFirmwareContract::aux_high_stable_ms;
  config.min_tx_gap_ms = FixedFirmwareContract::min_tx_gap_ms;
  config.radio_uart_bps = FixedFirmwareContract::e220_uart_bps;
  config.radio_air_bps = FixedFirmwareContract::e220_air_bps;
  config.action_retry_timeout_ms =
      FixedFirmwareContract::aux_transition_timeout_ms;
  config.radio_chunk_bytes = static_cast<std::uint16_t>(
      FixedFirmwareContract::radio_chunk_bytes);
  return config;
}

constexpr TddConfig kTddConfig = product_tdd_config();

#if defined(VC_LORA_PHASE6_VEHICLE)
MavlinkFrameScheduler vehicle_scheduler{};
VehicleTddController tdd_controller(kTddConfig, link_diagnostics);
VehicleLateUplinkRecovery vehicle_uplink_recovery{};
bool vehicle_uplink_cycle_started{false};
bool vehicle_uplink_transaction_invalid{false};
constexpr std::uint64_t kPixhawkLinkHeartbeatIntervalMs = 1000U;
std::uint64_t next_pixhawk_link_heartbeat_ms{0U};
std::uint8_t pixhawk_link_heartbeat_sequence{0U};
#else
GroundMavlinkIngressAdapter ground_ingress{};
GroundTddController tdd_controller(kTddConfig, link_diagnostics);
#endif

enum class PendingPayload : std::uint8_t {
  None,
  VehicleData,
  GroundData,
  Control,
};

struct PendingRadioAction {
  std::uint32_t token{0U};
  std::uint16_t application_bytes{0U};
  PendingPayload payload{PendingPayload::None};
  bool active{false};
};

PendingRadioAction pending_radio_action{};

std::uint64_t monotonic_now_ms() noexcept {
  const std::int64_t microseconds = esp_timer_get_time();
  return microseconds <= 0
             ? 0U
             : static_cast<std::uint64_t>(microseconds / 1000LL);
}

bool aux_high() noexcept { return digitalRead(kE220AuxPin) == HIGH; }

void latch_runtime_fail_closed() noexcept {
  runtime_fail_closed = true;
  bridge_ready = false;
}

#if defined(VC_LORA_PHASE6_VEHICLE)
// Keep the Pixhawk MAVLink route for the proxied GCS identity alive.  The
// heartbeat is encoded as one complete MAVLink frame and appended to the same
// backpressure FIFO as RF-originated requests; it never writes HardwareSerial
// directly, so a short UART write cannot interleave two MAVLink frames.
void service_pixhawk_link_heartbeat(std::uint64_t now_ms) noexcept {
  if (now_ms < next_pixhawk_link_heartbeat_ms) {
    return;
  }

  constexpr std::array<std::uint8_t, 9U> payload{
      0x00U, 0x00U, 0x00U, 0x00U,  // custom_mode
      0x06U,                       // MAV_TYPE_GCS
      0x08U,                       // MAV_AUTOPILOT_INVALID
      0x00U,                       // base_mode
      0x04U,                       // MAV_STATE_ACTIVE
      0x03U};                      // MAVLink version
  MavlinkFrame heartbeat{};
  if (!encode_mavlink_v2(pixhawk_link_heartbeat_sequence, 255U, 190U, 0U,
                         payload.data(), payload.size(), heartbeat)) {
    latch_runtime_fail_closed();
    return;
  }

  LocalEgressAdapter<>& egress = radio_application_endpoint.egress();
  if (egress.fail_closed() || egress.free_bytes() < heartbeat.size) {
    return;
  }
  if (egress.ingest(heartbeat.bytes.data(), heartbeat.size) !=
      heartbeat.size) {
    latch_runtime_fail_closed();
    return;
  }
  ++pixhawk_link_heartbeat_sequence;
  next_pixhawk_link_heartbeat_ms =
      now_ms + kPixhawkLinkHeartbeatIntervalMs;
}
#endif

std::uint16_t narrow_u16(std::size_t value) noexcept {
  return static_cast<std::uint16_t>(
      std::min<std::size_t>(value, 0xFFFFU));
}

void encode_identity(const BootSessionIdentity& identity,
                     std::array<std::uint8_t, 6U>& bytes) noexcept {
  bytes[0] = static_cast<std::uint8_t>(identity.boot_id & 0xFFU);
  bytes[1] = static_cast<std::uint8_t>((identity.boot_id >> 8U) & 0xFFU);
  bytes[2] = static_cast<std::uint8_t>((identity.boot_id >> 16U) & 0xFFU);
  bytes[3] = static_cast<std::uint8_t>((identity.boot_id >> 24U) & 0xFFU);
  bytes[4] = static_cast<std::uint8_t>(identity.session_id & 0xFFU);
  bytes[5] = static_cast<std::uint8_t>((identity.session_id >> 8U) & 0xFFU);
}

BootSessionIdentity decode_identity(
    const std::array<std::uint8_t, 6U>& bytes) noexcept {
  BootSessionIdentity identity{};
  identity.boot_id = static_cast<std::uint32_t>(bytes[0]) |
                     (static_cast<std::uint32_t>(bytes[1]) << 8U) |
                     (static_cast<std::uint32_t>(bytes[2]) << 16U) |
                     (static_cast<std::uint32_t>(bytes[3]) << 24U);
  identity.session_id = static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(bytes[4]) |
      static_cast<std::uint16_t>(static_cast<std::uint16_t>(bytes[5])
                                 << 8U));
  return identity;
}

bool provision_boot_identity(BootSessionIdentity& identity) noexcept {
  Preferences preferences;
  if (!preferences.begin(kPreferencesNamespace, false)) {
    return false;
  }

  BootSessionIdentity previous{};
  bool read_succeeded = true;
  const std::size_t stored_size = preferences.getBytesLength(kIdentityKey);
  if (stored_size == 6U) {
    std::array<std::uint8_t, 6U> stored{};
    read_succeeded =
        preferences.getBytes(kIdentityKey, stored.data(), stored.size()) ==
        stored.size();
    if (read_succeeded) {
      previous = decode_identity(stored);
    }
  } else if (stored_size != 0U) {
    read_succeeded = false;
  }

  BootSessionProvisioner provisioner(previous, read_succeeded);
  bool persisted = false;
  if (read_succeeded) {
    std::array<std::uint8_t, 6U> candidate_bytes{};
    encode_identity(provisioner.candidate_for_persistence(), candidate_bytes);
    persisted = preferences.putBytes(kIdentityKey, candidate_bytes.data(),
                                     candidate_bytes.size()) ==
                candidate_bytes.size();
    if (persisted) {
      std::array<std::uint8_t, 6U> verified{};
      persisted =
          preferences.getBytes(kIdentityKey, verified.data(), verified.size()) ==
              verified.size() &&
          verified == candidate_bytes;
    }
  }
  preferences.end();

  provisioner.confirm_persisted(persisted);
  return provisioner.lease(identity);
}

bool wait_aux_high_during_setup(std::uint32_t timeout_ms) noexcept {
  const std::uint64_t started_ms = monotonic_now_ms();
  while (!aux_high()) {
    if (monotonic_now_ms() - started_ms >= timeout_ms) {
      return false;
    }
    delay(1);
  }
  return true;
}

void drain_config_rx() noexcept {
  const std::uint64_t started_ms = monotonic_now_ms();
  while (monotonic_now_ms() - started_ms < 30U) {
    while (e220_serial.available() > 0) {
      (void)e220_serial.read();
    }
    delay(1);
  }
}

std::size_t collect_config_response(std::uint8_t* response,
                                    std::size_t capacity) noexcept {
  std::size_t received = 0U;
  const std::uint64_t started_ms = monotonic_now_ms();
  while (monotonic_now_ms() - started_ms < kConfigResponseTimeoutMs) {
    while (e220_serial.available() > 0 && received < capacity) {
      const int value = e220_serial.read();
      if (value >= 0) {
        response[received++] = static_cast<std::uint8_t>(value);
      }
    }
    if (received == capacity) {
      break;
    }
    delay(1);
  }
  return received;
}

bool config_command(const std::uint8_t* command, std::size_t command_size,
                    std::uint8_t* response,
                    std::size_t response_size) noexcept {
  if (command == nullptr || command_size == 0U || response == nullptr ||
      response_size == 0U) {
    return false;
  }
  drain_config_rx();
  if (!wait_aux_high_during_setup(kConfigAuxTimeoutMs) ||
      e220_serial.availableForWrite() < static_cast<int>(command_size)) {
    return false;
  }
  const std::size_t written = e220_serial.write(command, command_size);
  if (written != command_size) {
    return false;
  }
  e220_serial.flush();
  return collect_config_response(response, response_size) == response_size;
}

bool read_e220_profile(std::array<std::uint8_t, 8U>& profile) noexcept {
  constexpr std::array<std::uint8_t, 3U> command{{0xC1U, 0x00U, 0x08U}};
  std::array<std::uint8_t, 11U> response{};
  if (!config_command(command.data(), command.size(), response.data(),
                      response.size()) ||
      response[0] != 0xC1U || response[1] != 0x00U ||
      response[2] != 0x08U) {
    return false;
  }
  std::copy_n(response.begin() + 3U, profile.size(), profile.begin());
  return true;
}

bool write_e220_profile() noexcept {
  std::array<std::uint8_t, 11U> command{};
  command[0] = 0xC0U;
  command[1] = 0x00U;
  command[2] = 0x08U;
  std::copy(FixedFirmwareContract::e220_profile.begin(),
            FixedFirmwareContract::e220_profile.end(), command.begin() + 3U);
  std::array<std::uint8_t, 11U> response{};
  return config_command(command.data(), command.size(), response.data(),
                        response.size()) &&
         response[0] == 0xC1U && response[1] == 0x00U &&
         response[2] == 0x08U;
}

bool prepare_and_verify_e220_profile() noexcept {
  digitalWrite(kE220M0Pin, HIGH);
  digitalWrite(kE220M1Pin, HIGH);
  pinMode(kE220M0Pin, OUTPUT);
  pinMode(kE220M1Pin, OUTPUT);
  pinMode(kE220AuxPin, INPUT_PULLUP);
  delay(120);

  (void)e220_serial.setRxBufferSize(kSerialRxBytes);
  e220_serial.begin(9600U, SERIAL_8N1, kE220RxPin, kE220TxPin);
  std::array<std::uint8_t, 8U> observed{};
  bool valid = read_e220_profile(observed);
  if (valid && observed != FixedFirmwareContract::e220_profile) {
    valid = write_e220_profile();
    if (valid) {
      delay(200);
      observed = {};
      valid = read_e220_profile(observed);
    }
  }
  e220_serial.end();
  delay(20);

  if (!valid) {
    return startup_contract.verify_e220_profile(nullptr, 0U);
  }
  return startup_contract.verify_e220_profile(observed.data(),
                                               observed.size());
}

void start_e220_normal_mode() noexcept {
  digitalWrite(kE220M0Pin, LOW);
  digitalWrite(kE220M1Pin, LOW);
  delay(50);
  (void)e220_serial.setRxBufferSize(kSerialRxBytes);
  e220_serial.begin(FixedFirmwareContract::e220_uart_bps, SERIAL_8N1,
                    kE220RxPin, kE220TxPin);
}

template <typename Adapter, typename Port>
void pump_local_egress(Adapter& adapter, Port& port) noexcept {
  if (adapter.empty() || adapter.fail_closed()) {
    return;
  }
  std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> staged{};
  const std::size_t staged_size = adapter.peek(staged.data(), staged.size());
  if (staged_size == 0U) {
    return;
  }
  const int available = port.availableForWrite();
  if (available <= 0) {
    return;
  }
  const std::size_t requested = std::min<std::size_t>(
      staged_size, static_cast<std::size_t>(available));
  const std::size_t written = port.write(staged.data(), requested);
  if (written > requested ||
      adapter.complete_write(written) == UartWriteProgress::Invalid ||
      adapter.fail_closed()) {
    latch_runtime_fail_closed();
  }
}

// Start the transaction quarantine before the first Guard byte.  It remains
// the same parser/buffer across Guard, Receive and a timeout-originated
// ReturnGuard, so a MAVLink frame split by that state boundary stays intact.
#if defined(VC_LORA_PHASE6_VEHICLE)
void synchronize_vehicle_uplink_recovery() noexcept {
  if (tdd_controller.radio_receive_window()) {
    if (!vehicle_uplink_cycle_started) {
      vehicle_uplink_recovery.begin(tdd_controller.session_id(),
                                    tdd_controller.cycle_id());
      vehicle_uplink_cycle_started = true;
      vehicle_uplink_transaction_invalid = false;
    }
    return;
  }
  if (!tdd_controller.late_uplink_recovery_window()) {
    vehicle_uplink_recovery.discard();
    vehicle_uplink_cycle_started = false;
    vehicle_uplink_transaction_invalid = false;
  }
}

bool vehicle_uplink_ingress_open() noexcept {
  return tdd_controller.radio_receive_window() ||
         tdd_controller.late_uplink_recovery_window();
}

bool vehicle_commit_uplink_transaction() noexcept {
  const std::size_t bytes = vehicle_uplink_recovery.buffered_bytes();
  if (!vehicle_uplink_recovery.ready() || bytes == 0U ||
      radio_application_endpoint.fail_closed() ||
      radio_application_endpoint.egress().free_bytes() < bytes) {
    return false;
  }

  std::array<std::uint8_t, kVehicleLateUplinkRecoveryBytes> committed{};
  std::size_t committed_size = 0U;
  std::uint16_t committed_frames = 0U;
  if (!vehicle_uplink_recovery.take_commit(
          committed.data(), committed.size(), committed_size,
          committed_frames) ||
      committed_size != bytes || committed_frames == 0U ||
      radio_application_endpoint.egress().ingest(
          committed.data(), committed_size) != committed_size) {
    return false;
  }
  link_diagnostics.mavlink_frames_forwarded += committed_frames;
  return true;
}
#endif

// RF packet boundaries are not visible on the UART.  A dangling link escape,
// VCTD candidate, or partial MAVLink frame must therefore be discarded at a
// closed TDD receive boundary or it can consume bytes from the next cycle.
// reset_parser() intentionally leaves already validated egress frames queued.
void reset_closed_radio_ingress() noexcept {
  bool application_window_open = false;
#if defined(VC_LORA_PHASE6_VEHICLE)
  application_window_open = vehicle_uplink_ingress_open();
  // Vehicle application data is transaction-quarantined, never accumulated
  // in the ordinary endpoint parser before DONE confirmation.
  radio_application_endpoint.reset_parser();
#else
  application_window_open =
      tdd_controller.state() == GroundTddState::WaitGrant;
#endif
  if (!application_window_open) {
    radio_demux.reset();
    radio_application_endpoint.reset_parser();
#if defined(VC_LORA_PHASE6_VEHICLE)
    vehicle_uplink_recovery.discard();
#endif
  }
}

void deliver_radio_bytes(std::uint64_t now_ms) noexcept {
#if defined(VC_LORA_PHASE6_VEHICLE)
  synchronize_vehicle_uplink_recovery();
#endif
  // Clear anything retained while the window was closed before admitting a
  // byte from a newly opened window.
  reset_closed_radio_ingress();
  std::size_t consumed = 0U;
  while (e220_serial.available() > 0 && consumed < kLoopReadBudget &&
         bridge_ready) {
    const int value = e220_serial.read();
    if (value < 0) {
      break;
    }
    ++consumed;
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::observe_e220_raw(
        static_cast<std::uint8_t>(value), tdd_controller.state(),
        tdd_controller.cycle_id(), now_ms);
#endif
#if defined(VC_LORA_PHASE6_VEHICLE)
    // Any physical receive activity during timeout recovery restarts the
    // fixed 650-ms no-transmit interval before cycle advance.
    (void)tdd_controller.note_return_guard_activity(now_ms);
#endif
    const TddDemuxEvent event =
        radio_demux.push(static_cast<std::uint8_t>(value));
    bool application_window_open = false;
#if defined(VC_LORA_PHASE6_VEHICLE)
    application_window_open = vehicle_uplink_ingress_open();
    if (!application_window_open && event.local_size > 0U) {
      link_diagnostics.uplink_data_outside_receive_window += event.local_size;
    }
#else
    application_window_open =
        tdd_controller.state() == GroundTddState::WaitGrant;
    if (!application_window_open && event.local_size > 0U) {
      link_diagnostics.half_duplex_drop_count += event.local_size;
    }
#endif
    for (std::size_t index = 0U;
         application_window_open && index < event.local_size; ++index) {
#if defined(VC_LORA_PHASE6_VEHICLE)
      const LateUplinkIngestStatus status =
          vehicle_uplink_recovery.ingest(event.local_bytes[index]);
      if (status == LateUplinkIngestStatus::FrameReady) {
        const LateUplinkTerminalStatus terminal =
            vehicle_uplink_recovery.complete_frame();
        const bool capacity_ready =
            terminal == LateUplinkTerminalStatus::Ready &&
            !radio_application_endpoint.fail_closed() &&
            radio_application_endpoint.egress().free_bytes() >=
                vehicle_uplink_recovery.buffered_bytes();
        if (!capacity_ready || !vehicle_commit_uplink_transaction() ||
            !tdd_controller.complete_uplink_frame(now_ms)) {
          latch_runtime_fail_closed();
          break;
        }
        application_window_open = false;
      } else if (status == LateUplinkIngestStatus::Invalid) {
        vehicle_uplink_transaction_invalid = true;
        ++link_diagnostics.mavlink_crc_errors;
      } else if (status == LateUplinkIngestStatus::Overflow) {
        vehicle_uplink_transaction_invalid = true;
        ++link_diagnostics.uart_buffer_drop_count;
      }
#else
      const ValidatedLocalIngressStatus status =
          radio_application_endpoint.ingest_byte(event.local_bytes[index]);
      if (status == ValidatedLocalIngressStatus::QueuedFrame) {
        ++link_diagnostics.mavlink_frames_forwarded;
      } else if (status == ValidatedLocalIngressStatus::DroppedOverflow) {
        ++link_diagnostics.uart_buffer_drop_count;
        if (radio_application_endpoint.fail_closed()) {
          latch_runtime_fail_closed();
          break;
        }
      } else if (status == ValidatedLocalIngressStatus::FailClosed) {
        latch_runtime_fail_closed();
        break;
      }
#endif
    }
    if (!bridge_ready) {
      break;
    }
    if (event.has_control) {
      link_diagnostics.note_decode_status(event.control.status);
      if (event.control.status == DecodeStatus::Message) {
#if defined(VC_LORA_PHASE6_VEHICLE)
        const bool normal_window = tdd_controller.radio_receive_window();
        const bool late_window =
            tdd_controller.late_uplink_recovery_window();
        const LateUplinkTerminalStatus terminal =
            vehicle_uplink_recovery.on_terminal(event.control.message);

        if (terminal == LateUplinkTerminalStatus::Ready) {
          const bool capacity_ready =
              !radio_application_endpoint.fail_closed() &&
              radio_application_endpoint.egress().free_bytes() >=
                  vehicle_uplink_recovery.buffered_bytes();
          if (!capacity_ready) {
            latch_runtime_fail_closed();
            break;
          }

          if (normal_window) {
            const ControlDisposition disposition =
                tdd_controller.on_control(event.control.message, now_ms);
            if (disposition != ControlDisposition::Accepted ||
                !vehicle_commit_uplink_transaction()) {
              latch_runtime_fail_closed();
              break;
            }
          } else if (late_window) {
            if (!vehicle_commit_uplink_transaction() ||
                !tdd_controller.complete_late_uplink_terminal(
                    now_ms, ControlType::UlDone, true)) {
              latch_runtime_fail_closed();
              break;
            }
          } else {
            vehicle_uplink_recovery.discard();
          }
        } else if (terminal == LateUplinkTerminalStatus::Idle) {
          if (normal_window) {
            (void)tdd_controller.on_control(event.control.message, now_ms);
          } else if (late_window) {
            (void)tdd_controller.complete_late_uplink_terminal(
                now_ms, ControlType::UlIdle, true);
          }
        } else if (terminal == LateUplinkTerminalStatus::Discarded) {
          if (normal_window) {
            (void)tdd_controller.discard_current_uplink(now_ms);
          } else if (late_window) {
            (void)tdd_controller.complete_late_uplink_terminal(
                now_ms, event.control.message.type, false);
          }
        } else {
          // Preserve an in-flight current transaction when a stale terminal
          // is observed; the controller records its ordinary identity error.
          const bool current_terminal =
              event.control.message.version == kTddProtocolVersion &&
              (event.control.message.type == ControlType::UlDone ||
               event.control.message.type == ControlType::UlIdle) &&
              event.control.message.session_id ==
                  tdd_controller.session_id() &&
              event.control.message.cycle_id == tdd_controller.cycle_id();
          if (normal_window && vehicle_uplink_transaction_invalid &&
              current_terminal) {
            (void)tdd_controller.discard_current_uplink(now_ms);
          } else {
            (void)tdd_controller.on_control(event.control.message, now_ms);
          }
        }
#else
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
        vc_lora_ground_diag_observer::observe_radio_control_before(
            event.control.message, tdd_controller.state(),
            tdd_controller.cycle_id(), now_ms, link_diagnostics);
#endif
        (void)tdd_controller.on_control(event.control.message, now_ms);
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
        vc_lora_ground_diag_observer::observe_radio_control_after(
            event.control.message, tdd_controller.state(),
            tdd_controller.cycle_id(), now_ms, link_diagnostics);
#endif
#endif
      }
    }
  }
  // Bytes received after DONE/GRANT closes the window can leave a one-byte
  // demux prefix even within this same UART drain pass.
  reset_closed_radio_ingress();
}

#if defined(VC_LORA_PHASE6_VEHICLE)
void collect_local_ingress(std::uint64_t now_ms) noexcept {
  std::size_t consumed = 0U;
  while (pixhawk_serial.available() > 0 && consumed < kLoopReadBudget) {
    const int value = pixhawk_serial.read();
    if (value < 0) {
      break;
    }
    ++consumed;
    (void)vehicle_scheduler.ingest_byte(static_cast<std::uint8_t>(value),
                                        now_ms);
  }
}
#else
void collect_local_ingress(std::uint64_t) noexcept {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  const std::uint64_t diagnostic_now_ms = monotonic_now_ms();
  const auto expired_query =
      vc_lora_ground_diag_observer::flush_query_candidate(
          diagnostic_now_ms);
  for (std::size_t index = 0U; index < expired_query.replay_size; ++index) {
    const std::uint8_t replay_byte = expired_query.replay[index];
    const FrameIngressStatus replay_status =
        ground_ingress.ingest_byte(replay_byte);
    vc_lora_ground_diag_observer::observe_usb_ingress(
        replay_byte, replay_status, diagnostic_now_ms);
    if (replay_status == FrameIngressStatus::DroppedOverflow ||
        replay_status == FrameIngressStatus::FailClosed ||
        ground_ingress.fail_closed()) {
      latch_runtime_fail_closed();
      return;
    }
  }
#endif
  std::size_t consumed = 0U;
  while (Serial.available() > 0 && consumed < kLoopReadBudget &&
         bridge_ready) {
    const int value = Serial.read();
    if (value < 0) {
      break;
    }
    ++consumed;
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    const auto routed = vc_lora_ground_diag_observer::route_usb_byte(
        static_cast<std::uint8_t>(value), diagnostic_now_ms);
    if (routed.consumed) {
      for (std::size_t index = 0U; index < routed.replay_size; ++index) {
        const std::uint8_t replay_byte = routed.replay[index];
        const FrameIngressStatus replay_status =
            ground_ingress.ingest_byte(replay_byte);
        vc_lora_ground_diag_observer::observe_usb_ingress(
            replay_byte, replay_status, diagnostic_now_ms);
        if (replay_status == FrameIngressStatus::DroppedOverflow ||
            replay_status == FrameIngressStatus::FailClosed ||
            ground_ingress.fail_closed()) {
          latch_runtime_fail_closed();
          break;
        }
      }
      continue;
    }
#endif
    const FrameIngressStatus status =
        ground_ingress.ingest_byte(static_cast<std::uint8_t>(value));
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::observe_usb_ingress(
        static_cast<std::uint8_t>(value), status, diagnostic_now_ms);
#endif
    if (status == FrameIngressStatus::DroppedOverflow ||
        status == FrameIngressStatus::FailClosed ||
        ground_ingress.fail_closed()) {
      latch_runtime_fail_closed();
    }
  }
}
#endif

bool finish_payload(TxResult result, std::uint64_t now_ms) noexcept {
  if (!pending_radio_action.active) {
    return false;
  }
  bool source_ok = true;
  switch (pending_radio_action.payload) {
#if defined(VC_LORA_PHASE6_VEHICLE)
    case PendingPayload::VehicleData:
      source_ok = vehicle_scheduler.complete_send(
          result, pending_radio_action.application_bytes);
      break;
#else
    case PendingPayload::GroundData:
      source_ok = ground_ingress.complete_send(
          result, pending_radio_action.application_bytes);
      if (result == TxResult::Rejected) {
        source_ok = !ground_ingress.fail_closed();
      }
      break;
#endif
    case PendingPayload::Control:
      break;
    case PendingPayload::None:
    default:
      source_ok = false;
      break;
  }
  if (!source_ok) {
    latch_runtime_fail_closed();
    return false;
  }
  tdd_controller.complete_action(
      pending_radio_action.token, result, now_ms,
      pending_radio_action.payload == PendingPayload::Control
          ? 0xFFFFU
          : pending_radio_action.application_bytes);
  pending_radio_action = {};
  return true;
}

void reject_action(const LinkAction& action, PendingPayload payload,
                   std::uint16_t application_bytes,
                   std::uint64_t now_ms) noexcept {
  // No source lease exists when an unexpected empty queue is observed.  The
  // controller may retry, but there is nothing for the scheduler/ingress to
  // complete in that case.
  if (application_bytes == 0U && payload != PendingPayload::Control) {
    tdd_controller.complete_action(action.token, TxResult::Rejected, now_ms);
    return;
  }
  pending_radio_action = {action.token, application_bytes, payload, true};
  (void)finish_payload(TxResult::Rejected, now_ms);
}

bool start_radio_write(const LinkAction& action, PendingPayload payload,
                       std::uint16_t application_bytes,
                       const std::uint8_t* wire, std::size_t wire_size,
                       std::uint64_t now_ms) noexcept {
  if (!startup_contract.transmission_allowed() ||
      runtime_fail_closed || radio_busy || pending_radio_action.active ||
      wire == nullptr || wire_size == 0U ||
      wire_size > FixedFirmwareContract::radio_chunk_bytes) {
    reject_action(action, payload, application_bytes, now_ms);
    return false;
  }

  (void)e220_write_contract.observe_aux(aux_high(), now_ms);
  if (e220_write_contract.fail_closed()) {
    latch_runtime_fail_closed();
    return false;
  }
  if (!e220_write_contract.ready_for_write() ||
      e220_serial.availableForWrite() < static_cast<int>(wire_size) ||
      !e220_write_contract.begin_write(wire_size)) {
    reject_action(action, payload, application_bytes, now_ms);
    return false;
  }

  const std::size_t written = e220_serial.write(wire, wire_size);
  const std::uint64_t accepted_at_ms = monotonic_now_ms();
  const E220WriteDisposition disposition =
      e220_write_contract.report_write_result(written, accepted_at_ms,
                                              aux_high());
  if (disposition == E220WriteDisposition::Rejected) {
    reject_action(action, payload, application_bytes, accepted_at_ms);
    return false;
  }
  if (disposition != E220WriteDisposition::AcceptedAll) {
    latch_runtime_fail_closed();
    return false;
  }

  // TxResult::Accepted means the physical UART accepted the complete block.
  // Commit the source/controller at this start timestamp so the core's
  // 180-ms gap remains start-to-start.  E220WriteContract independently keeps
  // the radio busy until the post-write AUX completion contract is satisfied.
  radio_busy = true;
  pending_radio_action = {action.token, application_bytes, payload, true};
  if (!finish_payload(TxResult::Accepted, accepted_at_ms)) {
    latch_runtime_fail_closed();
    return false;
  }
  return true;
}

void observe_radio_completion(std::uint64_t now_ms) noexcept {
  (void)e220_write_contract.observe_aux(aux_high(), now_ms);
  if (e220_write_contract.fail_closed()) {
    latch_runtime_fail_closed();
    return;
  }
  if (e220_write_contract.take_write_completion()) {
    if (!radio_busy || pending_radio_action.active) {
      latch_runtime_fail_closed();
      return;
    }
    radio_busy = false;
  }
}

#if defined(VC_LORA_PHASE6_VEHICLE)
bool authorize_action(const LinkAction& action, std::uint64_t) noexcept {
  if (action.type == LinkActionType::SendRadioData) {
    return TxGate::authorize_vehicle(tdd_controller.state(),
                                     TxClass::DownlinkData,
                                     link_diagnostics);
  }
  if (action.type == LinkActionType::SendGrant) {
    return TxGate::authorize_vehicle(tdd_controller.state(),
                                     TxClass::GrantControl,
                                     link_diagnostics);
  }
  return action.type == LinkActionType::None;
}
#else
bool authorize_action(const LinkAction& action,
                      std::uint64_t now_ms) noexcept {
  if (action.type == LinkActionType::SendRadioData) {
    return TxGate::authorize_ground(
        tdd_controller.state(), TxClass::UplinkData,
        tdd_controller.has_valid_grant(), now_ms,
        tdd_controller.window_deadline_ms(), link_diagnostics);
  }
  if (action.type == LinkActionType::SendDone) {
    return TxGate::authorize_ground(
        tdd_controller.state(), TxClass::DoneControl,
        tdd_controller.has_valid_grant(), now_ms,
        tdd_controller.window_deadline_ms(), link_diagnostics);
  }
  return action.type == LinkActionType::None;
}
#endif

void process_action(const LinkAction& action,
                    std::uint64_t now_ms) noexcept {
  if (action.type == LinkActionType::None) {
    return;
  }
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  vc_lora_ground_diag_observer::observe_action_issued(
      action, tdd_controller.state(), tdd_controller.cycle_id(), now_ms);
#endif
  if (!authorize_action(action, now_ms)) {
    latch_runtime_fail_closed();
    return;
  }

  if (action.type == LinkActionType::SendRadioData) {
    std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> application{};
#if defined(VC_LORA_PHASE6_VEHICLE)
    const std::size_t available = vehicle_scheduler.peek(
        application.data(),
        std::min<std::size_t>(application.size(), action.byte_budget));
    constexpr PendingPayload payload = PendingPayload::VehicleData;
#else
    const std::size_t available = ground_ingress.peek(
        application.data(),
        std::min<std::size_t>(application.size(), action.byte_budget));
    constexpr PendingPayload payload = PendingPayload::GroundData;
#endif
    const EncodedLinkDataChunk encoded = encode_link_data(
        application.data(), available,
        FixedFirmwareContract::radio_chunk_bytes);
    if (encoded.input_consumed == 0U || encoded.wire_size == 0U) {
      reject_action(action, payload, 0U, now_ms);
      return;
    }
    (void)start_radio_write(
        action, payload, narrow_u16(encoded.input_consumed),
        encoded.wire_bytes.data(), encoded.wire_size, now_ms);
    return;
  }

  if (action.type == LinkActionType::SendGrant ||
      action.type == LinkActionType::SendDone) {
    std::array<std::uint8_t, kTddControlFrameSize> control{};
    std::size_t control_size = 0U;
    if (!encode_control(action.control, control.data(), control.size(),
                        control_size)) {
      reject_action(action, PendingPayload::Control, 0U, now_ms);
      return;
    }
    (void)start_radio_write(action, PendingPayload::Control, 0U,
                            control.data(), control_size, now_ms);
  }
}

#if defined(VC_LORA_PHASE6_VEHICLE)
TddInput make_tdd_input(std::uint64_t now_ms) noexcept {
  TddInput input{};
  input.now_ms = now_ms;
  input.aux_high = aux_high();
  input.radio_tx_empty = !radio_busy && !pending_radio_action.active &&
                         e220_write_contract.ready_for_write() &&
                         e220_serial.availableForWrite() >=
                             static_cast<int>(
                                 FixedFirmwareContract::radio_chunk_bytes);
  input.local_tx_empty = !vehicle_scheduler.has_active_frame();
  input.queued_bytes = static_cast<std::uint32_t>(
      std::min<std::size_t>(vehicle_scheduler.queued_bytes(), 0xFFFFFFFFULL));
  input.heartbeat_tail_enabled = vehicle_scheduler.has_seen_heartbeat();
  input.heartbeat_tail_available =
      vehicle_scheduler.has_pending_heartbeat();
  input.heartbeat_tail_active =
      vehicle_scheduler.active_frame_is_heartbeat();
  input.heartbeat_tail_active_started =
      vehicle_scheduler.active_frame_has_progress();
  return input;
}
#else
TddInput make_tdd_input(std::uint64_t now_ms) noexcept {
  TddInput input{};
  input.now_ms = now_ms;
  input.aux_high = aux_high();
  input.radio_tx_empty = !radio_busy && !pending_radio_action.active &&
                         e220_write_contract.ready_for_write() &&
                         e220_serial.availableForWrite() >=
                             static_cast<int>(
                                 FixedFirmwareContract::radio_chunk_bytes);
  input.local_tx_empty = true;
  input.queued_bytes = static_cast<std::uint32_t>(
      std::min<std::size_t>(ground_ingress.front_frame_remaining(),
                            0xFFFFFFFFULL));
  input.front_frame_bytes = ground_ingress.front_frame_remaining();

  if (tdd_controller.has_valid_grant() && input.queued_bytes > 0U) {
    const std::size_t remaining =
        tdd_controller.actual_bytes() < tdd_controller.granted_bytes()
            ? static_cast<std::size_t>(tdd_controller.granted_bytes() -
                                       tdd_controller.actual_bytes())
            : 0U;
    const std::size_t preview_limit = std::min<std::size_t>(
        {ground_ingress.queued_bytes(),
         FixedFirmwareContract::radio_chunk_bytes, remaining});
    if (preview_limit > 0U) {
      std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> preview{};
      const std::size_t preview_size =
          ground_ingress.peek(preview.data(), preview_limit);
      const EncodedLinkDataChunk encoded = encode_link_data(
          preview.data(), preview_size,
          FixedFirmwareContract::radio_chunk_bytes);
      input.next_tx_application_bytes = narrow_u16(encoded.input_consumed);
      input.next_tx_wire_bytes = narrow_u16(encoded.wire_size);
    }
  }
  return input;
}
#endif

void setup_bridge() noexcept {
  digitalWrite(kE220M0Pin, HIGH);
  digitalWrite(kE220M1Pin, HIGH);
  pinMode(kE220M0Pin, OUTPUT);
  pinMode(kE220M1Pin, OUTPUT);
  pinMode(kE220AuxPin, INPUT_PULLUP);

#if defined(VC_LORA_PHASE6_GROUND)
  // This USB CDC stream is exclusively Mission Planner MAVLink.  Never emit
  // text, diagnostics, control frames, or a synthetic heartbeat on it.
  Serial.begin(FixedFirmwareContract::pixhawk_uart_bps);
#endif

  const bool identity_ready = provision_boot_identity(boot_identity);
  startup_contract.confirm_identity_persisted(identity_ready);
  (void)prepare_and_verify_e220_profile();
  if (!startup_contract.transmission_allowed()) {
    return;
  }

  start_e220_normal_mode();
#if defined(VC_LORA_PHASE6_VEHICLE)
  (void)pixhawk_serial.setRxBufferSize(kSerialRxBytes);
  pixhawk_serial.begin(FixedFirmwareContract::pixhawk_uart_bps, SERIAL_8N1,
                       kPixhawkRxPin, kPixhawkTxPin);
#endif

  const std::uint64_t now_ms = monotonic_now_ms();
#if defined(VC_LORA_PHASE6_VEHICLE)
  tdd_controller.reset(boot_identity.session_id, 0U, now_ms);
#else
  tdd_controller.reset(now_ms);
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  vc_lora_ground_diag_observer::observe_ground_controller(
      tdd_controller.state(), tdd_controller.cycle_id(), now_ms);
#endif
#endif
  (void)e220_write_contract.observe_aux(aux_high(), now_ms);
  bridge_ready = !e220_write_contract.fail_closed();
}

void loop_bridge() noexcept {
  if (!bridge_ready || runtime_fail_closed) {
    return;
  }
  const std::uint64_t now_ms = monotonic_now_ms();
  observe_radio_completion(now_ms);
  if (!bridge_ready) {
    return;
  }
#if defined(VC_LORA_PHASE6_VEHICLE)
  service_pixhawk_link_heartbeat(now_ms);
  if (!bridge_ready) {
    return;
  }
#endif
  deliver_radio_bytes(now_ms);
  collect_local_ingress(now_ms);
#if defined(VC_LORA_PHASE6_VEHICLE)
  pump_local_egress(radio_application_endpoint.egress(), pixhawk_serial);
#else
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  if (!vc_lora_ground_diag_observer::usb_report_active) {
#endif
  pump_local_egress(radio_application_endpoint.egress(), Serial);
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  }
#endif
#endif
  if (!bridge_ready) {
    return;
  }
  process_action(tdd_controller.tick(make_tdd_input(now_ms)), now_ms);
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  vc_lora_ground_diag_observer::observe_ground_controller(
      tdd_controller.state(), tdd_controller.cycle_id(), now_ms);
#endif
#if defined(VC_LORA_PHASE6_VEHICLE)
  synchronize_vehicle_uplink_recovery();
#endif
  // Cover timeout/action transitions that close a receive window without an
  // accompanying radio byte in this loop iteration.
  reset_closed_radio_ingress();
}

}  // namespace vc_lora_phase6_firmware

void setup() { vc_lora_phase6_firmware::setup_bridge(); }

void loop() { vc_lora_phase6_firmware::loop_bridge(); }
