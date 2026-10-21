#pragma once

// Production Arduino adapter for the deterministic Phase 6 core.  This file
// is included once by either S3 sketch.  All protocol decisions remain in the
// Arduino-free core; this layer only owns XIAO pins, UART/USB, NVS and AUX.

#if (defined(VC_LORA_PHASE6_VEHICLE) + defined(VC_LORA_PHASE6_GROUND)) != 1
#error "Define exactly one VC_LORA_PHASE6_VEHICLE/VC_LORA_PHASE6_GROUND role"
#endif

#if defined(VC_LORA_HIL_DROP_NATIVE_PARAM_INDEX_930) && \
    (!defined(VC_LORA_PHASE6_GROUND) || \
     !defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS) || \
     defined(VC_LORA_PHASE6_VEHICLE))
#error "VC_LORA_HIL_DROP_NATIVE_PARAM_INDEX_930 requires Ground diagnostics"
#endif

#include <Arduino.h>
#include <Preferences.h>
#include <esp_timer.h>
#if defined(VC_LORA_PHASE6_GROUND)
#include <hal/usb_serial_jtag_ll.h>
#endif

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

#include <vc_lora/embedded_io_adapter.hpp>
#include <vc_lora/ground_parameter_download_proxy.hpp>
#include <vc_lora/ground_usb_heartbeat_pacer.hpp>
#include <vc_lora/ground_usb_host_presence_filter.hpp>
#include <vc_lora/ground_usb_ordered_frame_backlog.hpp>
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
                  FixedFirmwareContract::min_tx_gap_ms == 180U &&
                  FixedFirmwareContract::
                          e220_subpacket_service_floor_ms == 550U,
              "production E220 transaction contract changed");
static_assert(FixedFirmwareContract::radio_chunk_bytes ==
                   kTddControlFrameSize,
               "one TDD control frame must equal one physical E220 chunk");
static_assert(kTddProtocolVersion == 2U,
              "production TDD transport must use explicit UL_DONE v2");
static_assert(FixedFirmwareContract::downlink_send_ms == 3000U &&
                  FixedFirmwareContract::uplink_guard_ms == 650U &&
                  FixedFirmwareContract::uplink_window_ms == 300U &&
                  FixedFirmwareContract::vehicle_receive_timeout_ms ==
                      2000U &&
                  FixedFirmwareContract::return_guard_ms == 650U,
              "production TDD schedule changed");

constexpr std::size_t kSerialRxBytes = 4096U;
constexpr std::size_t kLoopReadBudget = 512U;
constexpr std::uint32_t kConfigResponseTimeoutMs = 500U;
constexpr std::uint32_t kConfigAuxTimeoutMs = 2000U;
constexpr std::uint32_t kConfigAuxHighStableMs = 5U;
constexpr std::uint32_t kConfigModeSettleMs = 200U;
constexpr std::uint32_t kConfigRxQuietMs = 5U;
constexpr std::uint32_t kConfigRxDrainTimeoutMs = 30U;
constexpr std::size_t kConfigRxDrainReadBudget = 64U;
constexpr std::size_t kProfileReadMaxAttempts = 3U;
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
// A connected Mission Planner can exert bounded USB backpressure. Preserve
// already admitted complete-frame FIFO order while capacity remains; once
// full, drop only the newly validated frame. Frames which arrive while CDC is
// disconnected are rejected before this FIFO and never advance the proxy.
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
  config.late_terminal_wait_ms =
      FixedFirmwareContract::late_terminal_wait_ms;
  config.aux_stable_ms = FixedFirmwareContract::aux_high_stable_ms;
  config.min_tx_gap_ms = FixedFirmwareContract::min_tx_gap_ms;
  config.radio_uart_bps = FixedFirmwareContract::e220_uart_bps;
  config.radio_air_bps = FixedFirmwareContract::e220_air_bps;
  config.action_retry_timeout_ms =
      FixedFirmwareContract::aux_transition_timeout_ms;
  config.heartbeat_grant_reserve_ms =
      FixedFirmwareContract::heartbeat_grant_reserve_ms;
  config.radio_chunk_bytes = static_cast<std::uint16_t>(
      FixedFirmwareContract::radio_chunk_bytes);
  return config;
}

constexpr TddConfig kTddConfig = product_tdd_config();

constexpr GroundParameterDownloadProxyConfig
product_parameter_proxy_config() noexcept {
  GroundParameterDownloadProxyConfig config{};
  config.list_strategy = GroundParameterListStrategy::NativeStream;
  return config;
}

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
GroundParameterDownloadProxy ground_parameter_proxy{
    product_parameter_proxy_config()};
GroundUsbHeartbeatPacer ground_usb_heartbeat_pacer{
    GroundUsbHeartbeatPacerConfig{}};
constexpr std::uint32_t kGroundUsbHostLossConfirmMs = 50U;
static_assert(kGroundUsbHostLossConfirmMs > 0U,
              "Ground USB host-loss confirmation must be positive");
GroundUsbHostPresenceFilter ground_usb_host_presence_filter{
    GroundUsbHostPresenceFilterConfig{kGroundUsbHostLossConfirmMs}};
GroundUsbOrderedFrameBacklog<> ground_usb_ordered_backlog{};
static_assert(kGroundUsbOrderedBacklogBytes + kLocalEgressBytes == 4320U,
              "Ground ordered+generic USB byte bound changed");
MavlinkStreamParser ground_usb_parser{};
MavlinkStreamParser ground_radio_application_parser{};
bool ground_usb_host_present_state{false};
bool ground_usb_endpoint_ready_state{false};
bool ground_paced_heartbeat_commit_active{false};
std::uint32_t ground_paced_heartbeat_commit_token{0U};
std::uint64_t ground_paced_heartbeat_commit_goal{0U};
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
std::uint8_t ground_paced_heartbeat_commit_sequence{0U};
#endif
bool ground_proxy_request_admitted{false};
bool ground_proxy_request_dequeued{false};
std::uint32_t ground_proxy_request_token{0U};
std::uint64_t ground_proxy_request_dequeue_goal{0U};
std::uint64_t ground_proxy_request_done_goal{0U};
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
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  vc_lora_ground_diag_observer::observe_runtime_fail_closed(
      bridge_ready, tdd_controller.state(), tdd_controller.cycle_id(),
      monotonic_now_ms());
#endif
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
  std::uint64_t high_since_ms = 0U;
  bool tracking_high = false;
  while (monotonic_now_ms() - started_ms < timeout_ms) {
    const std::uint64_t now_ms = monotonic_now_ms();
    if (!aux_high()) {
      tracking_high = false;
      delay(1);
      continue;
    }
    if (!tracking_high) {
      tracking_high = true;
      high_since_ms = now_ms;
    }
    if (now_ms - high_since_ms >= kConfigAuxHighStableMs) {
      return true;
    }
    delay(1);
  }
  return false;
}

bool drain_config_rx_until_quiet() noexcept {
  const std::uint64_t started_ms = monotonic_now_ms();
  std::uint64_t quiet_since_ms = started_ms;
  while (monotonic_now_ms() - started_ms < kConfigRxDrainTimeoutMs) {
    bool drained_byte = false;
    std::size_t read_budget = kConfigRxDrainReadBudget;
    while (read_budget > 0U &&
           monotonic_now_ms() - started_ms < kConfigRxDrainTimeoutMs &&
           e220_serial.available() > 0) {
      const int value = e220_serial.read();
      --read_budget;
      if (value >= 0) {
        drained_byte = true;
      }
    }
    const std::uint64_t now_ms = monotonic_now_ms();
    if (drained_byte) {
      quiet_since_ms = now_ms;
    } else if (now_ms - quiet_since_ms >= kConfigRxQuietMs) {
      return true;
    }
    delay(1);
  }
  return false;
}

bool start_e220_config_uart() noexcept {
  e220_serial.end();
  if (e220_serial.setRxBufferSize(kSerialRxBytes) != kSerialRxBytes) {
    return false;
  }
  e220_serial.begin(9600U, SERIAL_8N1, kE220RxPin, kE220TxPin);
  if (!static_cast<bool>(e220_serial)) {
    e220_serial.end();
    return false;
  }
  if (!drain_config_rx_until_quiet()) {
    e220_serial.end();
    return false;
  }
  return true;
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
  if (!drain_config_rx_until_quiet()) {
    return false;
  }
  if (!wait_aux_high_during_setup(kConfigAuxTimeoutMs) ||
      e220_serial.availableForWrite() < static_cast<int>(command_size)) {
    return false;
  }
  const std::size_t written = e220_serial.write(command, command_size);
  if (written != command_size) {
    return false;
  }
  // Do not call HardwareSerial::flush() here. ESP32 flush waits for TX idle
  // without a deadline. Starting the bounded response collector immediately
  // also captures a response that arrives while the final UART byte drains.
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

bool restart_e220_config_mode() noexcept {
  (void)drain_config_rx_until_quiet();
  e220_serial.end();
  digitalWrite(kE220M0Pin, LOW);
  digitalWrite(kE220M1Pin, LOW);
  delay(kConfigModeSettleMs);
  if (!wait_aux_high_during_setup(kConfigAuxTimeoutMs)) {
    digitalWrite(kE220M0Pin, HIGH);
    digitalWrite(kE220M1Pin, HIGH);
    delay(kConfigModeSettleMs);
    return false;
  }
  digitalWrite(kE220M0Pin, HIGH);
  digitalWrite(kE220M1Pin, HIGH);
  delay(kConfigModeSettleMs);
  if (!wait_aux_high_during_setup(kConfigAuxTimeoutMs)) {
    return false;
  }
  return start_e220_config_uart();
}

bool read_e220_profile_with_retry(
    std::array<std::uint8_t, 8U>& observed) noexcept {
  for (std::size_t attempt = 0U; attempt < kProfileReadMaxAttempts;
       ++attempt) {
    // A failed initial UART start must consume one attempt, not bypass the
    // retry loop. Re-enter the radio mode and recreate the UART on every
    // attempt so all three attempts have identical recovery semantics.
    if (!restart_e220_config_mode()) {
      continue;
    }
    observed = {};
    if (read_e220_profile(observed)) {
      return true;
    }
  }
  return false;
}

bool write_e220_profile() noexcept {
  std::array<std::uint8_t, 11U> command{};
  command[0] = 0xC0U;
  command[1] = 0x00U;
  command[2] = 0x08U;
  std::copy(FixedFirmwareContract::e220_profile.begin(),
            FixedFirmwareContract::e220_profile.end(), command.begin() + 3U);
  std::array<std::uint8_t, 11U> response{};
  if (!config_command(command.data(), command.size(), response.data(),
                      response.size()) ||
      response[0] != 0xC1U) {
    return false;
  }
  return std::equal(response.begin() + 1U, response.end(),
                    command.begin() + 1U);
}

bool prepare_and_verify_e220_profile() noexcept {
  digitalWrite(kE220M0Pin, HIGH);
  digitalWrite(kE220M1Pin, HIGH);
  pinMode(kE220M0Pin, OUTPUT);
  pinMode(kE220M1Pin, OUTPUT);
  pinMode(kE220AuxPin, INPUT_PULLUP);
  delay(120);

  std::array<std::uint8_t, 8U> observed{};
  bool valid = read_e220_profile_with_retry(observed);
  if (valid && observed != FixedFirmwareContract::e220_profile) {
    // The write may have been applied even if its UART echo was lost. Always
    // re-read the stored profile and let that authoritative value decide.
    (void)write_e220_profile();
    delay(200);
    observed = {};
    valid = read_e220_profile_with_retry(observed);
  }
  e220_serial.end();
  // A failed setup remains fail-closed in configuration mode. Never leave the
  // radio in normal mode after an interrupted retry sequence.
  digitalWrite(kE220M0Pin, HIGH);
  digitalWrite(kE220M1Pin, HIGH);
  delay(kConfigModeSettleMs);

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
  if (pump_local_egress_if_connected(adapter, port, true) ==
      LocalEgressPumpStatus::Invalid) {
    latch_runtime_fail_closed();
  }
}

#if defined(VC_LORA_PHASE6_GROUND)
bool ground_usb_host_present_now() noexcept {
  return Serial.isPlugged();
}

bool ground_usb_endpoint_ready_now(bool host_present) noexcept {
  return host_present && static_cast<bool>(Serial);
}

bool ground_usb_writer_available() noexcept {
  return ground_usb_endpoint_ready_state && Serial.availableForWrite() > 0;
}

#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
vc_lora_ground_diag_observer::GroundHeartbeatRuntimeContext
capture_ground_heartbeat_runtime_context() noexcept {
  vc_lora_ground_diag_observer::GroundHeartbeatRuntimeContext context{};
  const auto& egress = radio_application_endpoint.egress();
  context.usb_queued_bytes = static_cast<std::uint32_t>(
      std::min<std::size_t>(egress.queued_bytes(), 0xFFFFFFFFULL));
  context.ordered_backlog_bytes = static_cast<std::uint32_t>(
      std::min<std::size_t>(ground_usb_ordered_backlog.queued_bytes(),
                            0xFFFFFFFFULL));
  context.cycle = tdd_controller.cycle_id();
  context.ordered_backlog_frames = static_cast<std::uint16_t>(
      std::min<std::size_t>(ground_usb_ordered_backlog.queued_frames(),
                            0xFFFFU));
  context.state = static_cast<std::uint8_t>(tdd_controller.state());
  context.aux = aux_high() ? 1U : 0U;
  context.radio_busy = radio_busy ? 1U : 0U;
  context.pending_action = pending_radio_action.active ? 1U : 0U;
  context.pacer_queued = static_cast<std::uint8_t>(
      ground_usb_heartbeat_pacer.queued());
  context.pacer_pending =
      ground_usb_heartbeat_pacer.has_pending_emit() ? 1U : 0U;
  context.pacer_admitted =
      ground_usb_heartbeat_pacer.has_admitted_emit() ? 1U : 0U;
  context.usb_write_pending = egress.write_pending() ? 1U : 0U;
  context.usb_writer_available = ground_usb_writer_available() ? 1U : 0U;
  return context;
}
#endif
bool ground_usb_can_accept_downlink() noexcept {
  return ground_usb_host_present_state;
}

void update_ground_usb_connection(std::uint64_t now_ms) noexcept;

void pump_ground_usb_egress(std::uint64_t now_ms) noexcept {
  update_ground_usb_connection(now_ms);
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  const std::size_t diagnostic_queued_before =
      radio_application_endpoint.egress().queued_bytes();
  const std::uint64_t diagnostic_committed_before =
      radio_application_endpoint.egress().stats().bytes_committed;
#endif
  const LocalEgressPumpStatus status = pump_local_egress_if_connected(
      radio_application_endpoint.egress(), Serial,
      ground_usb_endpoint_ready_state);
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  vc_lora_ground_diag_observer::observe_usb_egress_pump(
      status, diagnostic_queued_before,
      radio_application_endpoint.egress().queued_bytes(),
      diagnostic_committed_before,
      radio_application_endpoint.egress().stats().bytes_committed,
      tdd_controller.state(), tdd_controller.cycle_id(), now_ms);
#endif
  if (status == LocalEgressPumpStatus::Invalid) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            UsbEgressInvalid);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
    latch_runtime_fail_closed();
  }
}

bool ground_same_wire_frame(const MavlinkFrame& left,
                            const MavlinkFrame& right) noexcept {
  return left.size == right.size && left.size > 0U &&
         left.size <= left.bytes.size() &&
         std::memcmp(left.bytes.data(), right.bytes.data(), left.size) == 0;
}

bool ground_is_primary_vehicle_heartbeat(
    const MavlinkFrame& frame) noexcept {
  return frame.message_id == 0U && frame.system_id == 1U &&
         frame.component_id == 1U;
}

#if defined(VC_LORA_HIL_DROP_NATIVE_PARAM_INDEX_930)
bool ground_hil_native_param_index_930_dropped = false;

bool should_drop_ground_hil_native_param_index_930(
    const MavlinkFrame& frame) noexcept {
  if (ground_hil_native_param_index_930_dropped ||
      ground_parameter_proxy.list_strategy() !=
          GroundParameterListStrategy::NativeStream ||
      !ground_parameter_proxy.active() ||
      ground_parameter_proxy.native_stream_recovery_active() ||
      ground_parameter_proxy.expected_index() != 930U ||
      !ground_usb_can_accept_downlink() || frame.message_id != 22U ||
      frame.system_id != 1U || frame.component_id != 1U ||
      frame.payload_length != 25U) {
    return false;
  }

  const std::uint16_t count =
      static_cast<std::uint16_t>(frame.payload()[4U]) |
      (static_cast<std::uint16_t>(frame.payload()[5U]) << 8U);
  const std::uint16_t index =
      static_cast<std::uint16_t>(frame.payload()[6U]) |
      (static_cast<std::uint16_t>(frame.payload()[7U]) << 8U);
  if (count != 932U || index != 930U) {
    return false;
  }

  ground_hil_native_param_index_930_dropped = true;
  return true;
}
#endif

void note_ground_usb_admission(const MavlinkFrame& frame,
                               ValidatedLocalIngressStatus status,
                               std::uint64_t now_ms) noexcept {
  const bool usb_queued =
      status == ValidatedLocalIngressStatus::QueuedFrame;
  (void)ground_parameter_proxy.on_vehicle_frame(frame, usb_queued, now_ms);
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  vc_lora_ground_diag_observer::observe_ground_downlink(
      frame,
      usb_queued
          ? vc_lora_ground_diag_observer::GroundDownlinkDisposition::
                EndpointQueued
          : vc_lora_ground_diag_observer::GroundDownlinkDisposition::
                EndpointDropped,
      now_ms);
  if (usb_queued) {
    const auto& egress = radio_application_endpoint.egress();
    vc_lora_ground_diag_observer::observe_target_egress_admission(
        frame, egress.stats().bytes_committed +
                   static_cast<std::uint64_t>(egress.queued_bytes()));
  }
#endif
  if (usb_queued) {
    ++link_diagnostics.mavlink_frames_forwarded;
  } else if (status == ValidatedLocalIngressStatus::DroppedOverflow) {
    ++link_diagnostics.uart_buffer_drop_count;
  } else if (status == ValidatedLocalIngressStatus::Invalid) {
    ++link_diagnostics.mavlink_crc_errors;
  } else if (status == ValidatedLocalIngressStatus::FailClosed ||
             radio_application_endpoint.fail_closed()) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            UsbEgressInvalid);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
    latch_runtime_fail_closed();
  }
}

void reject_ground_usb_frame(const MavlinkFrame& frame,
                             std::uint64_t now_ms) noexcept {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  vc_lora_ground_diag_observer::observe_ground_downlink(
      frame,
      vc_lora_ground_diag_observer::take_ground_downlink_disposition(),
      now_ms);
#endif
  (void)ground_parameter_proxy.on_vehicle_frame(frame, false, now_ms);
  ++link_diagnostics.uart_buffer_drop_count;
}

bool discard_ground_ordered_backlog(
    std::uint64_t now_ms) noexcept {
  while (!ground_usb_ordered_backlog.empty()) {
    MavlinkFrame frame{};
    bool heartbeat_marker = false;
    if (!ground_usb_ordered_backlog.peek(frame, heartbeat_marker)) {
      ground_usb_ordered_backlog.discard_all();
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
      vc_lora_ground_diag_observer::
          observe_ground_ordered_backlog_cleared();
      vc_lora_ground_diag_observer::arm_runtime_stop_reason(
          vc_lora_ground_diag_observer::GroundRuntimeStopReason::
              DownlinkOrderInvariant);
      // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
      latch_runtime_fail_closed();
      return false;
    }
    if (!heartbeat_marker) {
      reject_ground_usb_frame(frame, now_ms);
    }
    if (!ground_usb_ordered_backlog.discard_front()) {
      ground_usb_ordered_backlog.discard_all();
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
      vc_lora_ground_diag_observer::
          observe_ground_ordered_backlog_cleared();
      vc_lora_ground_diag_observer::arm_runtime_stop_reason(
          vc_lora_ground_diag_observer::GroundRuntimeStopReason::
              DownlinkOrderInvariant);
      // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
      latch_runtime_fail_closed();
      return false;
    }
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::observe_ground_ordered_backlog_removed(
        frame);
#endif
  }
  return true;
}

bool discard_ground_held_heartbeats(
    std::uint64_t now_ms) noexcept {
  if (ground_usb_heartbeat_pacer.queued() == 0U) {
    return true;
  }
  return ground_usb_heartbeat_pacer.discard_for_order(now_ms);
}

void update_ground_usb_connection(std::uint64_t now_ms) noexcept {
  const bool raw_host_present = ground_usb_host_present_now();
  const bool endpoint_ready =
      ground_usb_endpoint_ready_now(raw_host_present);
  ground_usb_endpoint_ready_state = endpoint_ready;
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  vc_lora_ground_diag_observer::observe_usb_connection(
      endpoint_ready, tdd_controller.state(), tdd_controller.cycle_id(),
      now_ms);
  vc_lora_ground_diag_observer::observe_usb_host_presence(
      raw_host_present, tdd_controller.state(), tdd_controller.cycle_id(),
      now_ms);
#endif
  const GroundUsbHostPresenceUpdate presence_update =
      ground_usb_host_presence_filter.observe(raw_host_present, now_ms);
  const bool host_present =
      ground_usb_host_presence_filter.confirmed_present();
  ground_usb_host_present_state = host_present;
  if (presence_update !=
          GroundUsbHostPresenceUpdate::ConfirmedConnected &&
      presence_update !=
          GroundUsbHostPresenceUpdate::ConfirmedDisconnected) {
    return;
  }
  ground_usb_heartbeat_pacer.set_usb_connected(host_present, now_ms);
  if (host_present) {
    return;
  }

  // Complete frames still in our descriptor backlog are retractable and are
  // rejected as whole frames. Bytes already admitted to LocalEgress cannot be
  // retracted on a mid-disconnect; retire the logical HB without calling it a
  // successful physical commit and leave that limitation externally visible.
  (void)discard_ground_ordered_backlog(now_ms);
  if (ground_paced_heartbeat_commit_active) {
    (void)ground_usb_heartbeat_pacer.complete_emit(
        ground_paced_heartbeat_commit_token, TxResult::Rejected, now_ms);
    ground_paced_heartbeat_commit_active = false;
    ground_paced_heartbeat_commit_token = 0U;
    ground_paced_heartbeat_commit_goal = 0U;
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    ground_paced_heartbeat_commit_sequence = 0U;
#endif
  }
  if (!discard_ground_held_heartbeats(now_ms)) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            HeartbeatPacerInvariant);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
    latch_runtime_fail_closed();
  }
  ground_usb_parser = {};
}

// Append one leased real heartbeat to the same byte FIFO used by every other
// Ground USB frame. The cumulative completion goal is frozen before any later
// frame is admitted, so later queue growth cannot acknowledge this HB early.
bool admit_ground_paced_heartbeat(
    const GroundUsbHeartbeatLease& lease,
    std::uint64_t now_ms) noexcept {
  auto& egress = radio_application_endpoint.egress();
  if (ground_paced_heartbeat_commit_active || egress.fail_closed()) {
    (void)ground_usb_heartbeat_pacer.complete_emit(
        lease.token, TxResult::Rejected, now_ms);
    return false;
  }

  const std::uint64_t committed_before = egress.stats().bytes_committed;
  const std::size_t queued_before = egress.queued_bytes();
  const ValidatedLocalIngressStatus status =
      radio_application_endpoint.admit_validated_frame(lease.frame);
  if (status != ValidatedLocalIngressStatus::QueuedFrame) {
    (void)ground_usb_heartbeat_pacer.complete_emit(
        lease.token, TxResult::Rejected, now_ms);
    if (status == ValidatedLocalIngressStatus::DroppedOverflow) {
      ++link_diagnostics.uart_buffer_drop_count;
    } else if (status == ValidatedLocalIngressStatus::Invalid) {
      ++link_diagnostics.mavlink_crc_errors;
    } else if (status == ValidatedLocalIngressStatus::FailClosed ||
               radio_application_endpoint.fail_closed()) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
      vc_lora_ground_diag_observer::arm_runtime_stop_reason(
          vc_lora_ground_diag_observer::GroundRuntimeStopReason::
              UsbEgressInvalid);
      // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
      latch_runtime_fail_closed();
    }
    return false;
  }

  // From this point the byte-only FIFO cannot retract the frame. Failure to
  // transfer ownership to the pacer is therefore an internal fail-stop fault.
  if (!ground_usb_heartbeat_pacer.mark_emit_admitted(lease.token)) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            HeartbeatPacerInvariant);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
    latch_runtime_fail_closed();
    return false;
  }
  ground_paced_heartbeat_commit_active = true;
  ground_paced_heartbeat_commit_token = lease.token;
  ground_paced_heartbeat_commit_goal =
      committed_before + static_cast<std::uint64_t>(queued_before) +
      static_cast<std::uint64_t>(lease.frame.size);
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  ground_paced_heartbeat_commit_sequence = lease.frame.sequence;
#endif
  ++link_diagnostics.mavlink_frames_forwarded;
  return true;
}

constexpr std::uint64_t kGroundUsbTransportFlushBudgetMs = 100U;

// HWCDC write acceptance only moves bytes into its private 256-byte ring.
// Drain that ring, wait for the endpoint to become writable after host pickup,
// then issue the LL flush once more. The second flush supplies the required
// short/ZLP transaction boundary when the preceding USB packet was 64 bytes.
bool flush_ground_paced_heartbeat_transport(
    std::uint64_t& flush_completed_ms) noexcept {
  const std::uint64_t flush_started_ms = monotonic_now_ms();
  Serial.flush();
  bool endpoint_ready = ground_usb_endpoint_ready_now(
      ground_usb_host_present_now());
  while (endpoint_ready && !usb_serial_jtag_ll_txfifo_writable()) {
    flush_completed_ms = monotonic_now_ms();
    if (flush_completed_ms - flush_started_ms >=
        kGroundUsbTransportFlushBudgetMs) {
      break;
    }
    delay(1U);
    endpoint_ready = ground_usb_endpoint_ready_now(
        ground_usb_host_present_now());
  }
  const bool endpoint_writable =
      endpoint_ready && usb_serial_jtag_ll_txfifo_writable();
  if (endpoint_writable) {
    usb_serial_jtag_ll_txfifo_flush();
  }
  flush_completed_ms = monotonic_now_ms();
  return endpoint_writable &&
         flush_completed_ms - flush_started_ms <=
             kGroundUsbTransportFlushBudgetMs;
}

void observe_ground_paced_heartbeat_commit(
    std::uint64_t now_ms) noexcept {
  if (!ground_paced_heartbeat_commit_active ||
      radio_application_endpoint.egress().stats().bytes_committed <
          ground_paced_heartbeat_commit_goal) {
    return;
  }
  std::uint64_t flush_completed_ms = now_ms;
  const bool transport_published =
      flush_ground_paced_heartbeat_transport(flush_completed_ms);
  update_ground_usb_connection(flush_completed_ms);
  if (!ground_paced_heartbeat_commit_active) {
    return;
  }
  const std::uint32_t token = ground_paced_heartbeat_commit_token;
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  const std::uint8_t heartbeat_sequence =
      ground_paced_heartbeat_commit_sequence;
  const auto heartbeat_context =
      capture_ground_heartbeat_runtime_context();
#endif
  ground_paced_heartbeat_commit_active = false;
  ground_paced_heartbeat_commit_token = 0U;
  ground_paced_heartbeat_commit_goal = 0U;
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  ground_paced_heartbeat_commit_sequence = 0U;
#endif
  const TxResult result =
      transport_published && ground_usb_endpoint_ready_state
          ? TxResult::Accepted
          : TxResult::Rejected;
  if (!ground_usb_heartbeat_pacer.complete_emit(
          token, result, flush_completed_ms)) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            HeartbeatPacerInvariant);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
    latch_runtime_fail_closed();
  }
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  else if (result == TxResult::Accepted) {
    vc_lora_ground_diag_observer::
        observe_ground_primary_heartbeat_usb_commit(
            heartbeat_sequence, heartbeat_context, flush_completed_ms);
  }
#endif
}

// Replay stops at the next heartbeat marker. This is the strict-order half of
// the pacer contract: a later MAVLink frame is never placed ahead of an older
// held heartbeat, and PARAM_VALUE advances only after endpoint admission.
bool replay_ground_usb_ordered_backlog(
    std::uint64_t now_ms) noexcept {
  while (!ground_usb_ordered_backlog.empty()) {
    MavlinkFrame frame{};
    bool heartbeat_marker = false;
    if (!ground_usb_ordered_backlog.peek(frame, heartbeat_marker)) {
      ground_usb_ordered_backlog.discard_all();
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
      vc_lora_ground_diag_observer::
          observe_ground_ordered_backlog_cleared();
      vc_lora_ground_diag_observer::arm_runtime_stop_reason(
          vc_lora_ground_diag_observer::GroundRuntimeStopReason::
              DownlinkOrderInvariant);
      // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
      latch_runtime_fail_closed();
      return false;
    }
    if (heartbeat_marker) {
      return true;
    }

    // The frame was classified when it entered this backlog, but proxy state
    // can change while an older paced heartbeat holds it here. In particular,
    // a native-stream timeout can switch to indexed recovery, or a PARAM_SET
    // can poison the session. Revalidate immediately before the irreversible
    // USB admission so stale #22 bytes cannot escape and then be requested a
    // second time.
    const GroundParameterProxyDisposition replay_preclassification =
        ground_parameter_proxy.preclassify_vehicle_frame(frame, now_ms);
    if (replay_preclassification ==
        GroundParameterProxyDisposition::Consumed) {
      if (!ground_usb_ordered_backlog.discard_front()) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
        vc_lora_ground_diag_observer::arm_runtime_stop_reason(
            vc_lora_ground_diag_observer::GroundRuntimeStopReason::
                DownlinkOrderInvariant);
        // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
        latch_runtime_fail_closed();
        return false;
      }
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
      vc_lora_ground_diag_observer::observe_ground_ordered_backlog_removed(
          frame);
      vc_lora_ground_diag_observer::observe_ground_downlink(
          frame,
          vc_lora_ground_diag_observer::GroundDownlinkDisposition::
              ProxyConsumed,
          now_ms);
#endif
      continue;
    }
    if (replay_preclassification ==
        GroundParameterProxyDisposition::Invalid) {
      (void)ground_usb_ordered_backlog.discard_front();
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
      vc_lora_ground_diag_observer::observe_ground_ordered_backlog_removed(
          frame);
      vc_lora_ground_diag_observer::observe_ground_downlink(
          frame,
          vc_lora_ground_diag_observer::GroundDownlinkDisposition::Invalid,
          now_ms);
#endif
      ++link_diagnostics.mavlink_crc_errors;
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
      vc_lora_ground_diag_observer::arm_runtime_stop_reason(
          vc_lora_ground_diag_observer::GroundRuntimeStopReason::
              DownlinkOrderInvariant);
      // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
      latch_runtime_fail_closed();
      return false;
    }

    auto& egress = radio_application_endpoint.egress();
    if (egress.fail_closed()) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
      vc_lora_ground_diag_observer::arm_runtime_stop_reason(
          vc_lora_ground_diag_observer::GroundRuntimeStopReason::
              UsbEgressInvalid);
      // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
      latch_runtime_fail_closed();
      return false;
    }
    if (egress.free_bytes() < frame.size) {
      return true;
    }
    const ValidatedLocalIngressStatus status =
        radio_application_endpoint.admit_validated_frame(frame);
    if (status != ValidatedLocalIngressStatus::QueuedFrame) {
      note_ground_usb_admission(frame, status, now_ms);
      if (bridge_ready) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
        vc_lora_ground_diag_observer::arm_runtime_stop_reason(
            vc_lora_ground_diag_observer::GroundRuntimeStopReason::
                DownlinkOrderInvariant);
        // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
        latch_runtime_fail_closed();
      }
      return false;
    }
    if (!ground_usb_ordered_backlog.pop_front()) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
      vc_lora_ground_diag_observer::arm_runtime_stop_reason(
          vc_lora_ground_diag_observer::GroundRuntimeStopReason::
              DownlinkOrderInvariant);
      // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
      latch_runtime_fail_closed();
      return false;
    }
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::observe_ground_ordered_backlog_removed(
        frame);
#endif
    note_ground_usb_admission(frame, status, now_ms);
  }
  return true;
}

// select_due() owns the hard-age expiry decision. If it removes even one
// pacer entry, the complete-frame FIFO still contains that entry's marker and
// can no longer be paired by position. Reject every retractable following
// frame (including #22 as usb_queued=false), clear the remaining held entries,
// and resume from the next fresh RF heartbeat instead of leaving a permanent
// marker head-of-line block.
void recover_ground_stale_pacer_pair(
    std::uint64_t now_ms) noexcept {
  (void)discard_ground_ordered_backlog(now_ms);
  if (!discard_ground_held_heartbeats(now_ms)) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            HeartbeatPacerInvariant);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
    latch_runtime_fail_closed();
  }
}

// Deadline admission happens only at an empty LocalEgress frame boundary. The
// heartbeat marker is removed only after its byte-exact pacer lease entered
// that FIFO; following complete frames are then replayed behind it, up to the
// next marker. An age deadline may therefore release queued HBs earlier than
// last_completion+2200 ms, keeping every completion within 2400 ms.
void service_ground_usb_heartbeat_pacer(
    std::uint64_t now_ms) noexcept {
  update_ground_usb_connection(now_ms);
  const bool endpoint_ready = ground_usb_endpoint_ready_state;
  auto& egress = radio_application_endpoint.egress();
  const bool writer_available = ground_usb_writer_available();
  ground_usb_heartbeat_pacer.observe_usb_egress(
      egress.queued_bytes(), egress.write_pending(), writer_available);

  if (!bridge_ready || !endpoint_ready) {
    return;
  }
  if (!replay_ground_usb_ordered_backlog(now_ms)) {
    return;
  }
  if (!endpoint_ready || !writer_available || !egress.empty() ||
      egress.write_pending() || ground_paced_heartbeat_commit_active) {
    return;
  }

  MavlinkFrame marker{};
  bool heartbeat_marker = false;
  if (!ground_usb_ordered_backlog.peek(marker, heartbeat_marker)) {
    if (!ground_usb_ordered_backlog.empty()) {
      ground_usb_ordered_backlog.discard_all();
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
      vc_lora_ground_diag_observer::
          observe_ground_ordered_backlog_cleared();
      vc_lora_ground_diag_observer::arm_runtime_stop_reason(
          vc_lora_ground_diag_observer::GroundRuntimeStopReason::
              DownlinkOrderInvariant);
      // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
      latch_runtime_fail_closed();
    } else if (ground_usb_heartbeat_pacer.queued() != 0U) {
      (void)discard_ground_held_heartbeats(now_ms);
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
      vc_lora_ground_diag_observer::arm_runtime_stop_reason(
          vc_lora_ground_diag_observer::GroundRuntimeStopReason::
              HeartbeatPacerInvariant);
      // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
      latch_runtime_fail_closed();
    }
    return;
  }
  if (!heartbeat_marker) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            DownlinkOrderInvariant);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
    latch_runtime_fail_closed();
    return;
  }

  const std::size_t held_before_select =
      ground_usb_heartbeat_pacer.queued();
  GroundUsbHeartbeatLease lease{};
  const bool selected =
      ground_usb_heartbeat_pacer.select_due(now_ms, false, lease);
  if (ground_usb_heartbeat_pacer.queued() != held_before_select) {
    if (selected &&
        !ground_usb_heartbeat_pacer.abort_pending_emit(lease.token)) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
      vc_lora_ground_diag_observer::arm_runtime_stop_reason(
          vc_lora_ground_diag_observer::GroundRuntimeStopReason::
              HeartbeatPacerInvariant);
      // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
      latch_runtime_fail_closed();
      return;
    }
    recover_ground_stale_pacer_pair(now_ms);
    return;
  }
  if (!selected) {
    return;
  }
  if (!ground_same_wire_frame(marker, lease.frame)) {
    if (!ground_usb_heartbeat_pacer.abort_pending_emit(lease.token)) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
      vc_lora_ground_diag_observer::arm_runtime_stop_reason(
          vc_lora_ground_diag_observer::GroundRuntimeStopReason::
              HeartbeatPacerInvariant);
      // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
      latch_runtime_fail_closed();
      return;
    }
    (void)discard_ground_ordered_backlog(now_ms);
    (void)discard_ground_held_heartbeats(now_ms);
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            HeartbeatPacerInvariant);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
    latch_runtime_fail_closed();
    return;
  }
  if (!admit_ground_paced_heartbeat(lease, now_ms) ||
      !ground_usb_ordered_backlog.pop_front()) {
    (void)discard_ground_ordered_backlog(now_ms);
    (void)discard_ground_held_heartbeats(now_ms);
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            HeartbeatPacerInvariant);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
    latch_runtime_fail_closed();
    return;
  }
  (void)replay_ground_usb_ordered_backlog(now_ms);
}
#endif

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

// Validate every immutable committed frame before any byte enters the D6
// egress. A native list fence may cancel only an unsent generic PARAM_VALUE
// backlog; it must never split an active frame or overlap an owned #20 target
// response. The second pass commits the fence only after exact D6 admission.
bool preflight_vehicle_uplink_transaction(
    const std::uint8_t* bytes, std::size_t size,
    std::uint16_t expected_frames) noexcept {
  if (bytes == nullptr || size == 0U || expected_frames == 0U) {
    return false;
  }
  MavlinkStreamParser parser{};
  std::uint16_t observed_frames = 0U;
  for (std::size_t index = 0U; index < size; ++index) {
    MavlinkFrame frame{};
    const MavlinkParseStatus parse_status = parser.push(bytes[index], frame);
    if (parse_status == MavlinkParseStatus::FrameReady) {
      ++observed_frames;
      if (frame.message_id == 21U &&
          (frame.payload_length != 2U || frame.signed_frame ||
           frame.payload()[0U] == 0U || frame.payload()[1U] == 0U ||
           !vehicle_scheduler.can_begin_native_parameter_list())) {
        return false;
      }
    } else if (parse_status != MavlinkParseStatus::NeedMore) {
      return false;
    }
  }
  return observed_frames == expected_frames && parser.buffered_size() == 0U;
}

// The late-uplink quarantine has already proved that this is an exact series
// of complete MAVLink frames. Re-parse the immutable commit only to retain the
// identity of each PARAM_REQUEST_READ and to commit a PARAM_REQUEST_LIST
// generation fence after the same bytes have entered the D6 Pixhawk egress.
// A full/busy/invalid tracker is a fail-stop condition: silently forgetting an
// admitted request would restore an unbounded or cross-generation delay.
bool remember_vehicle_parameter_requests(
    const std::uint8_t* bytes, std::size_t size,
    std::uint16_t expected_frames, std::uint64_t now_ms) noexcept {
  if (bytes == nullptr || size == 0U || expected_frames == 0U) {
    return false;
  }
  MavlinkStreamParser parser{};
  std::uint16_t observed_frames = 0U;
  for (std::size_t index = 0U; index < size; ++index) {
    MavlinkFrame frame{};
    const MavlinkParseStatus parse_status = parser.push(bytes[index], frame);
    if (parse_status == MavlinkParseStatus::FrameReady) {
      ++observed_frames;
      const MavlinkParameterRequestStatus request_status =
          frame.message_id == 21U
              ? vehicle_scheduler.begin_native_parameter_list(frame, now_ms)
              : vehicle_scheduler.remember_parameter_request(frame);
      if (request_status == MavlinkParameterRequestStatus::Full ||
          request_status == MavlinkParameterRequestStatus::Invalid ||
          request_status == MavlinkParameterRequestStatus::Busy) {
        return false;
      }
    } else if (parse_status != MavlinkParseStatus::NeedMore) {
      return false;
    }
  }
  return observed_frames == expected_frames && parser.buffered_size() == 0U;
}

bool vehicle_commit_uplink_transaction(std::uint64_t now_ms) noexcept {
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
      !preflight_vehicle_uplink_transaction(
          committed.data(), committed_size, committed_frames) ||
      radio_application_endpoint.egress().ingest(
          committed.data(), committed_size) != committed_size) {
    return false;
  }
  if (!remember_vehicle_parameter_requests(
          committed.data(), committed_size, committed_frames, now_ms)) {
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
#else
    ground_radio_application_parser.reset();
#endif
  }
}

#if defined(VC_LORA_PHASE6_GROUND)
// This function is reached only after the RF stream parser has produced one
// complete CRC-valid MAVLink frame. A primary real HB and every complete frame
// behind it enter the paired pacer/backlog state; all other traffic keeps the
// existing validated endpoint path. Neither path writes Serial directly.
void handle_ground_validated_frame(const MavlinkFrame& frame,
                                   std::uint64_t now_ms) noexcept {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  vc_lora_ground_diag_observer::observe_ground_validated_frame(frame,
                                                               now_ms);
  // RF supply is measured at the CRC-valid ingress boundary, independently
  // of whether USB is currently connected or able to accept this frame.
  if (ground_is_primary_vehicle_heartbeat(frame)) {
    vc_lora_ground_diag_observer::observe_ground_primary_heartbeat_rf(
        frame, capture_ground_heartbeat_runtime_context(), now_ms);
  }
#endif
  update_ground_usb_connection(now_ms);
  const GroundParameterProxyDisposition preclassification =
      ground_parameter_proxy.preclassify_vehicle_frame(frame, now_ms);
  if (preclassification == GroundParameterProxyDisposition::Consumed) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::observe_ground_downlink(
        frame,
        vc_lora_ground_diag_observer::GroundDownlinkDisposition::
            ProxyConsumed,
        now_ms);
#endif
    return;
  }
  if (preclassification == GroundParameterProxyDisposition::Invalid) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::observe_ground_downlink(
        frame,
        vc_lora_ground_diag_observer::GroundDownlinkDisposition::Invalid,
        now_ms);
#endif
    ++link_diagnostics.mavlink_crc_errors;
    return;
  }
#if defined(VC_LORA_HIL_DROP_NATIVE_PARAM_INDEX_930)
  if (should_drop_ground_hil_native_param_index_930(frame)) {
    return;
  }
#endif
  if (!ground_usb_can_accept_downlink()) {
    // HWCDC can accept bytes into its private 256-byte ring without a live
    // host consumer. Reject the complete frame before LocalEgress admission,
    // and report usb_queued=false so a matching proxied #22 cannot advance.
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_ground_downlink_disposition(
        vc_lora_ground_diag_observer::GroundDownlinkDisposition::
            DisconnectedRejected);
#endif
    reject_ground_usb_frame(frame, now_ms);
    return;
  }

  const bool primary_heartbeat =
      ground_is_primary_vehicle_heartbeat(frame);
  const bool exact_duplicate =
      primary_heartbeat &&
      ground_usb_heartbeat_pacer.contains_wire_heartbeat(frame);

  if (primary_heartbeat) {
    const std::size_t held_before = ground_usb_heartbeat_pacer.queued();
    const std::uint64_t expired_before =
        ground_usb_heartbeat_pacer.diagnostics().expired_heartbeats;
    if (exact_duplicate) {
      const GroundUsbHeartbeatIngestStatus duplicate_status =
          ground_usb_heartbeat_pacer.ingest(frame, now_ms);
      // An exact admitted/held/last-emitted duplicate is intentionally not
      // given a second marker. If expiry changed the FIFO during ingest, the
      // old markers no longer map one-to-one and both retractable sides drop.
      if (duplicate_status != GroundUsbHeartbeatIngestStatus::Held ||
          ground_usb_heartbeat_pacer.queued() != held_before ||
          ground_usb_heartbeat_pacer.diagnostics().expired_heartbeats !=
              expired_before) {
        recover_ground_stale_pacer_pair(now_ms);
        reject_ground_usb_frame(frame, now_ms);
      }
      return;
    }

    if (held_before >= GroundUsbHeartbeatPacer::capacity() ||
        !ground_usb_ordered_backlog.can_enqueue(frame)) {
      // Keep the already paired oldest reserve intact. enqueue() is invoked
      // only to record a frame-atomic byte/descriptor overflow diagnosis.
      if (!ground_usb_ordered_backlog.can_enqueue(frame)) {
        (void)ground_usb_ordered_backlog.enqueue(frame, true);
      }
      reject_ground_usb_frame(frame, now_ms);
      return;
    }

    const std::uint64_t duplicates_before_ingest =
        ground_usb_heartbeat_pacer.diagnostics().duplicate_ingests;
    const GroundUsbHeartbeatIngestStatus pace_status =
        ground_usb_heartbeat_pacer.ingest(frame, now_ms);
    const bool expired_during_ingest =
        ground_usb_heartbeat_pacer.diagnostics().expired_heartbeats !=
        expired_before;
    const bool recent_emitted_duplicate =
        !expired_during_ingest &&
        ground_usb_heartbeat_pacer.diagnostics().duplicate_ingests !=
            duplicates_before_ingest;
    if (recent_emitted_duplicate) {
      // contains_wire_heartbeat intentionally excludes last-emitted history.
      // A bounded replay is recognized by ingest diagnostics: drop only this
      // current replay and preserve any different held marker/backlog pair.
      reject_ground_usb_frame(frame, now_ms);
      return;
    }
    if (pace_status != GroundUsbHeartbeatIngestStatus::Held ||
        expired_during_ingest ||
        ground_usb_heartbeat_pacer.queued() != held_before + 1U) {
      // ingest() may expire an old entry or replace under a violated service
      // assumption. Never leave its marker paired with a different lease.
      recover_ground_stale_pacer_pair(now_ms);
      reject_ground_usb_frame(frame, now_ms);
      return;
    }
    if (ground_usb_ordered_backlog.enqueue(frame, true) !=
        GroundUsbOrderedBacklogStatus::Queued) {
      (void)discard_ground_ordered_backlog(now_ms);
      (void)discard_ground_held_heartbeats(now_ms);
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
      vc_lora_ground_diag_observer::arm_runtime_stop_reason(
          vc_lora_ground_diag_observer::GroundRuntimeStopReason::
              DownlinkOrderInvariant);
      // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
      latch_runtime_fail_closed();
    }
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    else {
      vc_lora_ground_diag_observer::observe_ground_ordered_backlog_enqueued(
          frame);
    }
#endif
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    if (bridge_ready) {
      vc_lora_ground_diag_observer::observe_ground_downlink(
          frame,
          vc_lora_ground_diag_observer::GroundDownlinkDisposition::
              BacklogQueued,
          now_ms);
    }
#endif
    return;
  }

  const GroundUsbHeartbeatIngestStatus pace_status =
      ground_usb_heartbeat_pacer.ingest(frame, now_ms);
  if (pace_status == GroundUsbHeartbeatIngestStatus::Invalid) {
    ++link_diagnostics.mavlink_crc_errors;
    return;
  }
  if (pace_status != GroundUsbHeartbeatIngestStatus::PassThrough) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            HeartbeatPacerInvariant);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
    latch_runtime_fail_closed();
    return;
  }

  if (!ground_usb_ordered_backlog.empty() ||
      ground_usb_heartbeat_pacer.queued() != 0U) {
    const GroundUsbOrderedBacklogStatus status =
        ground_usb_ordered_backlog.enqueue(frame, false);
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    if (status == GroundUsbOrderedBacklogStatus::Queued) {
      vc_lora_ground_diag_observer::observe_ground_ordered_backlog_enqueued(
          frame);
    }
#endif
    if (status != GroundUsbOrderedBacklogStatus::Queued) {
      reject_ground_usb_frame(frame, now_ms);
      if (status == GroundUsbOrderedBacklogStatus::Invalid) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
        vc_lora_ground_diag_observer::arm_runtime_stop_reason(
            vc_lora_ground_diag_observer::GroundRuntimeStopReason::
                DownlinkOrderInvariant);
        // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
        latch_runtime_fail_closed();
      }
    }
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    if (status == GroundUsbOrderedBacklogStatus::Queued) {
      vc_lora_ground_diag_observer::observe_ground_downlink(
          frame,
          vc_lora_ground_diag_observer::GroundDownlinkDisposition::
              BacklogQueued,
          now_ms);
    }
#endif
    return;
  }

  const ValidatedLocalIngressStatus status =
      radio_application_endpoint.admit_validated_frame(frame);
  note_ground_usb_admission(frame, status, now_ms);
}
#endif

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
      if (status == LateUplinkIngestStatus::Invalid) {
        vehicle_uplink_transaction_invalid = true;
        ++link_diagnostics.mavlink_crc_errors;
      } else if (status == LateUplinkIngestStatus::Overflow) {
        vehicle_uplink_transaction_invalid = true;
        ++link_diagnostics.uart_buffer_drop_count;
      }
#else
      MavlinkFrame frame{};
      const MavlinkParseStatus parse_status =
          ground_radio_application_parser.push(event.local_bytes[index],
                                               frame);
      if (parse_status == MavlinkParseStatus::FrameReady) {
        handle_ground_validated_frame(frame, now_ms);
        if (!bridge_ready) {
          break;
        }
      } else if (parse_status == MavlinkParseStatus::BadCrc) {
        ++link_diagnostics.mavlink_crc_errors;
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
                !vehicle_commit_uplink_transaction(now_ms)) {
              latch_runtime_fail_closed();
              break;
            }
          } else if (late_window) {
            if (!vehicle_commit_uplink_transaction(now_ms) ||
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
void service_ground_parameter_proxy(std::uint64_t now_ms) noexcept {
  // Observe source-FIFO completion before ticking the watchdog, so progress
  // exactly on the deadline is accepted. The second stage remains bounded
  // while waiting for this transaction's explicit UL_DONE UART admission.
  if (ground_proxy_request_admitted &&
      !ground_proxy_request_dequeued &&
      ground_ingress.stats().frames_dequeued >=
          ground_proxy_request_dequeue_goal) {
    if (!ground_parameter_proxy.mark_request_dequeued(
            ground_proxy_request_token, now_ms)) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
      vc_lora_ground_diag_observer::observe_proxy_watchdog(
          vc_lora_ground_diag_observer::GroundProxyWatchdogReason::
              MarkAdmissionFailed,
          ground_proxy_request_token, now_ms);
      vc_lora_ground_diag_observer::arm_runtime_stop_reason(
          vc_lora_ground_diag_observer::GroundRuntimeStopReason::
              ProxyMarkAdmissionFailed);
      // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
      latch_runtime_fail_closed();
      return;
    }
    ground_proxy_request_dequeued = true;
    ground_proxy_request_done_goal = link_diagnostics.done_tx + 1U;
  }

  // Observe explicit-DONE progress before the proxy's inclusive watchdog
  // tick. Completion which is already visible exactly at the stage deadline
  // is valid and must not be converted into a false abandoned-admission
  // fail-close.
  if (ground_proxy_request_admitted && ground_proxy_request_dequeued &&
      link_diagnostics.done_tx >= ground_proxy_request_done_goal) {
    // A fail-safe cancellation may have invalidated the lease after this one
    // request was admitted. It cannot be removed from a descriptor FIFO
    // safely; drain the bounded stale #20 and let the proxy reject its stale
    // token. The triggering PARAM_SET itself is never admitted or deferred.
    (void)ground_parameter_proxy.complete_request_tx(
        ground_proxy_request_token, TxResult::Accepted, now_ms);
    ground_proxy_request_admitted = false;
    ground_proxy_request_dequeued = false;
    ground_proxy_request_token = 0U;
    ground_proxy_request_dequeue_goal = 0U;
    ground_proxy_request_done_goal = 0U;
    return;
  }

  ground_parameter_proxy.tick(now_ms);

  if (ground_proxy_request_admitted &&
      ground_parameter_proxy.request_admission_abandoned(
          ground_proxy_request_token)) {
    // The descriptor FIFO cannot retract an admitted or partially drained
    // frame. Stop all transport activity; reboot clears both the stale bytes
    // and the logical lease, and no duplicate #20 can be generated meanwhile.
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::observe_proxy_watchdog(
        vc_lora_ground_diag_observer::GroundProxyWatchdogReason::
            AdmissionAbandoned,
        ground_proxy_request_token, now_ms);
#endif
    ground_proxy_request_admitted = false;
    ground_proxy_request_dequeued = false;
    ground_proxy_request_token = 0U;
    ground_proxy_request_dequeue_goal = 0U;
    ground_proxy_request_done_goal = 0U;
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            ProxyAdmissionAbandoned);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
    latch_runtime_fail_closed();
    return;
  }

  if (ground_proxy_request_admitted) {
    return;
  }

  MavlinkFrame request{};
  std::uint32_t token = 0U;
  if (!ground_parameter_proxy.peek_next_request(request, token)) {
    return;
  }

  const FrameIngressStatus status =
      ground_ingress.admit_validated_frame(request);
  if (status == FrameIngressStatus::Queued) {
    if (!ground_parameter_proxy.mark_request_admitted(token, now_ms)) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
      vc_lora_ground_diag_observer::observe_proxy_watchdog(
          vc_lora_ground_diag_observer::GroundProxyWatchdogReason::
              MarkAdmissionFailed,
          token, now_ms);
      vc_lora_ground_diag_observer::arm_runtime_stop_reason(
          vc_lora_ground_diag_observer::GroundRuntimeStopReason::
              ProxyMarkAdmissionFailed);
      // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
      latch_runtime_fail_closed();
      return;
    }
    ground_proxy_request_admitted = true;
    ground_proxy_request_dequeued = false;
    ground_proxy_request_token = token;
    ground_proxy_request_dequeue_goal =
        ground_ingress.stats().frames_dequeued +
        ground_ingress.queued_frames();
    ground_proxy_request_done_goal = 0U;
    return;
  }

  (void)ground_parameter_proxy.complete_request_tx(
      token, TxResult::Rejected, now_ms);
  // A generated, locally encoded complete frame can only be Queued here.
  // Any other result is an internal/capacity fault, never an input retry.
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  vc_lora_ground_diag_observer::observe_proxy_watchdog(
      vc_lora_ground_diag_observer::GroundProxyWatchdogReason::
          GeneratedIngressRejected,
      token, now_ms);
  vc_lora_ground_diag_observer::arm_runtime_stop_reason(
      vc_lora_ground_diag_observer::GroundRuntimeStopReason::
          ProxyGeneratedIngressRejected);
  // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
  latch_runtime_fail_closed();
}

#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
void process_ground_usb_byte(std::uint8_t byte,
                             std::uint64_t now_ms) noexcept {
  vc_lora_ground_diag_observer::observe_usb_byte(byte, now_ms);
  MavlinkFrame frame{};
  const MavlinkParseStatus parse_status = ground_usb_parser.push(byte, frame);
  if (parse_status != MavlinkParseStatus::FrameReady) {
    if (parse_status == MavlinkParseStatus::BadCrc) {
      ++link_diagnostics.mavlink_crc_errors;
    }
    return;
  }

  const GroundParameterProxyDisposition disposition =
      ground_parameter_proxy.on_gcs_frame(frame, now_ms);
  if (disposition == GroundParameterProxyDisposition::Consumed) {
    vc_lora_ground_diag_observer::observe_usb_frame(
        frame, disposition, FrameIngressStatus::Ignored);
    return;
  }
  if (disposition == GroundParameterProxyDisposition::Invalid) {
    vc_lora_ground_diag_observer::observe_usb_frame(
        frame, disposition, FrameIngressStatus::Ignored);
    ++link_diagnostics.mavlink_crc_errors;
    return;
  }

  const FrameIngressStatus queue_status =
      ground_ingress.admit_validated_frame(frame);
  vc_lora_ground_diag_observer::observe_usb_frame(frame, disposition,
                                                  queue_status);
  if (queue_status == FrameIngressStatus::DroppedOverflow ||
      queue_status == FrameIngressStatus::FailClosed ||
      ground_ingress.fail_closed()) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            GroundIngressFault);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
    latch_runtime_fail_closed();
  }
}
#endif
void collect_local_ingress(std::uint64_t now_ms) noexcept {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  const auto expired_query =
      vc_lora_ground_diag_observer::flush_query_candidate(now_ms);
  for (std::size_t index = 0U; index < expired_query.replay_size; ++index) {
    process_ground_usb_byte(expired_query.replay[index], now_ms);
    if (!bridge_ready) {
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
        static_cast<std::uint8_t>(value), now_ms);
    if (routed.consumed) {
      for (std::size_t index = 0U; index < routed.replay_size; ++index) {
        process_ground_usb_byte(routed.replay[index], now_ms);
        if (!bridge_ready) {
          return;
        }
      }
      continue;
    }
    process_ground_usb_byte(static_cast<std::uint8_t>(value), now_ms);
#else
    MavlinkFrame frame{};
    const MavlinkParseStatus parse_status =
        ground_usb_parser.push(static_cast<std::uint8_t>(value), frame);
    if (parse_status != MavlinkParseStatus::FrameReady) {
      if (parse_status == MavlinkParseStatus::BadCrc) {
        ++link_diagnostics.mavlink_crc_errors;
      }
      continue;
    }

    const GroundParameterProxyDisposition disposition =
        ground_parameter_proxy.on_gcs_frame(frame, now_ms);
    if (disposition == GroundParameterProxyDisposition::Consumed) {
      continue;
    }
    if (disposition == GroundParameterProxyDisposition::Invalid) {
      ++link_diagnostics.mavlink_crc_errors;
      continue;
    }

    const FrameIngressStatus queue_status =
        ground_ingress.admit_validated_frame(frame);
    if (queue_status == FrameIngressStatus::DroppedOverflow ||
        queue_status == FrameIngressStatus::FailClosed ||
        ground_ingress.fail_closed()) {
      latch_runtime_fail_closed();
    }
#endif
  }
  if (bridge_ready) {
    service_ground_parameter_proxy(now_ms);
  }
}
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
// Startup-stop/runtime-stop service path. All bytes are consumed by a private
// exact-query matcher and are never replayed into MAVLink or admitted to RF.
void collect_ground_fail_closed_query(std::uint64_t now_ms) noexcept {
  vc_lora_ground_diag_observer::observe_usb_connection(
      static_cast<bool>(Serial), tdd_controller.state(),
      tdd_controller.cycle_id(), now_ms);
  std::size_t consumed = 0U;
  while (Serial.available() > 0 && consumed < kLoopReadBudget) {
    const int value = Serial.read();
    if (value < 0) {
      break;
    }
    ++consumed;
    vc_lora_ground_diag_observer::consume_fail_closed_usb_byte(
        static_cast<std::uint8_t>(value));
  }
}
#endif
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
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            GroundIngressFault);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
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
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  vc_lora_ground_diag_observer::observe_radio_result(
      action.type, action.control.type, TxResult::Rejected, now_ms);
#endif
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
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            E220WriteFault);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
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
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            E220WriteFault);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
    latch_runtime_fail_closed();
    return false;
  }
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  vc_lora_ground_diag_observer::observe_radio_result(
      action.type, action.control.type, TxResult::Accepted,
      accepted_at_ms);
#endif

  // TxResult::Accepted means the physical UART accepted the complete block.
  // Commit the source/controller at this timestamp. E220WriteContract keeps
  // radio_busy asserted through the observed 550-ms subpacket service floor
  // and stable AUX HIGH; the nominal 180-ms start gap remains a lower bound.
  radio_busy = true;
  pending_radio_action = {action.token, application_bytes, payload, true};
  if (!finish_payload(TxResult::Accepted, accepted_at_ms)) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            GroundIngressFault);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
    latch_runtime_fail_closed();
    return false;
  }
  return true;
}

void observe_radio_completion(std::uint64_t now_ms) noexcept {
  (void)e220_write_contract.observe_aux(aux_high(), now_ms);
  if (e220_write_contract.fail_closed()) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            E220WriteFault);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
    latch_runtime_fail_closed();
    return;
  }
  if (e220_write_contract.take_write_completion()) {
    if (!radio_busy || pending_radio_action.active) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
      vc_lora_ground_diag_observer::arm_runtime_stop_reason(
          vc_lora_ground_diag_observer::GroundRuntimeStopReason::
              E220WriteFault);
      // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
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
    const bool continuing_started_transaction =
        tdd_controller.transaction_target_bytes() > 0U &&
        tdd_controller.actual_bytes() > 0U &&
        tdd_controller.actual_bytes() <
            tdd_controller.transaction_target_bytes();
    return TxGate::authorize_ground(
        tdd_controller.state(), TxClass::UplinkData,
        tdd_controller.has_valid_grant(), now_ms,
        tdd_controller.window_deadline_ms(), link_diagnostics,
        continuing_started_transaction);
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
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            TddControllerFault);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
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
  input.radio_tx_complete =
      !radio_busy && !pending_radio_action.active &&
      e220_write_contract.ready_for_write();
  input.radio_tx_empty = input.radio_tx_complete &&
                         e220_serial.availableForWrite() >=
                             static_cast<int>(
                                 FixedFirmwareContract::radio_chunk_bytes);
  input.local_tx_empty = !vehicle_scheduler.has_active_frame();
  input.queued_bytes = static_cast<std::uint32_t>(
      std::min<std::size_t>(vehicle_scheduler.queued_bytes(), 0xFFFFFFFFULL));
  const MavlinkHeartbeatCandidate heartbeat =
      vehicle_scheduler.heartbeat_candidate();
  input.heartbeat_tail_enabled = vehicle_scheduler.has_seen_heartbeat();
  input.heartbeat_tail_available = heartbeat.tail_available;
  input.heartbeat_tail_active = heartbeat.active;
  input.heartbeat_tail_active_started = heartbeat.active_started;
  if (heartbeat.present && heartbeat.tail_available) {
    input.heartbeat_deadline_valid = true;
    input.heartbeat_order = heartbeat.order;
    input.heartbeat_enqueued_ms = heartbeat.enqueued_ms;
    constexpr std::uint64_t kDeadlineMs =
        FixedFirmwareContract::heartbeat_hard_deadline_ms;
    const std::uint64_t maximum =
        std::numeric_limits<std::uint64_t>::max();
    input.heartbeat_deadline_ms =
        heartbeat.enqueued_ms > maximum - kDeadlineMs
            ? maximum
            : heartbeat.enqueued_ms + kDeadlineMs;
  }
  return input;
}
#else
TddInput make_tdd_input(std::uint64_t now_ms) noexcept {
  TddInput input{};
  input.now_ms = now_ms;
  input.aux_high = aux_high();
  input.radio_tx_complete =
      !radio_busy && !pending_radio_action.active &&
      e220_write_contract.ready_for_write();
  input.radio_tx_empty = input.radio_tx_complete &&
                         e220_serial.availableForWrite() >=
                             static_cast<int>(
                                 FixedFirmwareContract::radio_chunk_bytes);
  input.local_tx_empty = true;
  input.queued_bytes = static_cast<std::uint32_t>(
      std::min<std::size_t>(ground_ingress.queued_bytes(),
                            0xFFFFFFFFULL));
  input.front_frame_bytes = ground_ingress.front_frame_remaining();

  if (tdd_controller.has_valid_grant() && input.queued_bytes > 0U) {
    const std::size_t transaction_limit =
        tdd_controller.transaction_target_bytes() > 0U
            ? tdd_controller.transaction_target_bytes()
            : tdd_controller.granted_bytes();
    const std::size_t remaining =
        tdd_controller.actual_bytes() < transaction_limit
            ? static_cast<std::size_t>(transaction_limit -
                                       tdd_controller.actual_bytes())
            : 0U;
    const std::size_t preview_limit = std::min<std::size_t>(
        {ground_ingress.front_frame_remaining(),
         FixedFirmwareContract::radio_chunk_bytes, remaining});
    if (preview_limit > 0U) {
      std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> preview{};
      const std::size_t preview_size =
          ground_ingress.peek(preview.data(), preview_limit);
      const EncodedLinkDataChunk encoded = encode_link_data(
          preview.data(), preview_size,
          FixedFirmwareContract::radio_chunk_bytes);
      input.next_tx_application_bytes = narrow_u16(encoded.input_consumed);
      input.next_tx_wire_bytes =
          ground_ingress.front_frame_wire_bytes();
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
  ground_parameter_proxy.reset();
  ground_usb_ordered_backlog.reset();
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  vc_lora_ground_diag_observer::observe_ground_ordered_backlog_cleared();
#endif
  const bool raw_host_present = ground_usb_host_present_now();
  ground_usb_host_presence_filter.reset(raw_host_present, now_ms);
  ground_usb_host_present_state =
      ground_usb_host_presence_filter.confirmed_present();
  ground_usb_endpoint_ready_state =
      ground_usb_endpoint_ready_now(raw_host_present);
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  vc_lora_ground_diag_observer::observe_usb_connection(
      ground_usb_endpoint_ready_state, tdd_controller.state(),
      tdd_controller.cycle_id(), now_ms);
  vc_lora_ground_diag_observer::observe_usb_host_presence(
      raw_host_present, tdd_controller.state(),
      tdd_controller.cycle_id(), now_ms);
#endif
  ground_usb_heartbeat_pacer.set_usb_connected(
      ground_usb_host_present_state, now_ms);
  ground_usb_parser = {};
  ground_radio_application_parser = {};
  ground_paced_heartbeat_commit_active = false;
  ground_paced_heartbeat_commit_token = 0U;
  ground_paced_heartbeat_commit_goal = 0U;
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  ground_paced_heartbeat_commit_sequence = 0U;
#endif
  ground_proxy_request_admitted = false;
  ground_proxy_request_dequeued = false;
  ground_proxy_request_token = 0U;
  ground_proxy_request_dequeue_goal = 0U;
  ground_proxy_request_done_goal = 0U;
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
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  if (!bridge_ready || runtime_fail_closed) {
    collect_ground_fail_closed_query(monotonic_now_ms());
    return;
  }
#else
  if (!bridge_ready || runtime_fail_closed) {
    return;
  }
#endif
  const std::uint64_t now_ms = monotonic_now_ms();
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  vc_lora_ground_diag_observer::observe_ground_controller(
      tdd_controller.state(), tdd_controller.cycle_id(), now_ms);
#endif
  observe_radio_completion(now_ms);
  if (!bridge_ready || runtime_fail_closed) {
    return;
  }
#if defined(VC_LORA_PHASE6_VEHICLE)
  service_pixhawk_link_heartbeat(now_ms);
  if (!bridge_ready) {
    return;
  }
  deliver_radio_bytes(now_ms);
  collect_local_ingress(now_ms);
#else
  // Classify a newly arrived GCS PARAM_SET before admitting a same-loop late
  // PARAM_VALUE to USB. Bytes already queued or partially written in an
  // earlier loop remain physically unretractable and are diagnosed by the
  // parameter proxy's conservative race-window counter.
  collect_local_ingress(now_ms);
  if (!bridge_ready) {
    return;
  }
  deliver_radio_bytes(now_ms);
#endif
#if defined(VC_LORA_PHASE6_VEHICLE)
  // Either ingress service above may latch a permanent stop (including a
  // Full/Invalid PARAM_REQUEST_READ identity after D6 FIFO admission). Never
  // turn those retained bytes into a physical Pixhawk write once that happens.
  if (!bridge_ready || runtime_fail_closed) {
    return;
  }
  pump_local_egress(radio_application_endpoint.egress(), pixhawk_serial);
#else
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  if (!vc_lora_ground_diag_observer::usb_report_active) {
#endif
  service_ground_usb_heartbeat_pacer(now_ms);
  pump_ground_usb_egress(now_ms);
  observe_ground_paced_heartbeat_commit(now_ms);
  // If the first pump completed the active normal frame, admit and write the
  // due HB at that exact frame boundary instead of waiting another loop.
  service_ground_usb_heartbeat_pacer(now_ms);
  pump_ground_usb_egress(now_ms);
  observe_ground_paced_heartbeat_commit(now_ms);
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
  }
#endif
#endif
  if (!bridge_ready) {
    return;
  }
  const LinkAction action = tdd_controller.tick(make_tdd_input(now_ms));
#if !defined(VC_LORA_PHASE6_VEHICLE)
  // Once a DATA prefix has been physically accepted it cannot be rolled back.
  // If UART readiness/zero-write rejection prevents DATA+UL_DONE from
  // completing inside the absolute Vehicle receive lease, the controller
  // latches an abandoned transaction. Propagate that fault before any later
  // frame can be admitted or a partial terminal can be emitted.
  if (tdd_controller.fail_closed()) {
#if defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
    vc_lora_ground_diag_observer::arm_runtime_stop_reason(
        vc_lora_ground_diag_observer::GroundRuntimeStopReason::
            TddControllerFault);
    // VC_LORA_GROUND_RUNTIME_REASON_COVERED
#endif
    latch_runtime_fail_closed();
    return;
  }
#endif
  process_action(action, now_ms);
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
