#pragma once

// Production Arduino adapter for the deterministic Phase 6 core.  This file
// is included once by either S3 sketch.  All protocol decisions remain in the
// Arduino-free core; this layer only owns XIAO pins, UART/USB, NVS and AUX.

#if (defined(VC_LORA_PHASE6_VEHICLE) + defined(VC_LORA_PHASE6_GROUND)) != 1
#error "Define exactly one VC_LORA_PHASE6_VEHICLE/VC_LORA_PHASE6_GROUND role"
#endif

#ifndef VC_LORA_R19_HIGH_SPEED_CANDIDATE
#define VC_LORA_R19_HIGH_SPEED_CANDIDATE 0
#endif
#if VC_LORA_R19_HIGH_SPEED_CANDIDATE != 0 && \
    VC_LORA_R19_HIGH_SPEED_CANDIDATE != 1
#error "VC_LORA_R19_HIGH_SPEED_CANDIDATE must be 0 or 1"
#endif

#ifndef VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 0
#endif
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS != 0 && \
    VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS != 1
#error "VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS must be 0 or 1"
#endif
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS && \
    !VC_LORA_R19_HIGH_SPEED_CANDIDATE
#error "R19 runtime diagnostics require the R19 candidate"
#endif

// Experimental USB-only cause isolation, never an implicit product policy.
// 0 preserves the existing diagnostic behaviour; 1 observes private clock
// exchange only; 2 holds initial Ground product USB admission until explicit
// same-boot/epoch/session HostArm. This is NOT Pixhawk flight arming.
#ifndef VC_LORA_R19_USB_READINESS_MODE
#define VC_LORA_R19_USB_READINESS_MODE 0
#endif
#if VC_LORA_R19_USB_READINESS_MODE < 0 || VC_LORA_R19_USB_READINESS_MODE > 2
#error "VC_LORA_R19_USB_READINESS_MODE must be 0, 1 or 2"
#endif
#if VC_LORA_R19_USB_READINESS_MODE && !VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
#error "R19 USB readiness modes require runtime diagnostics"
#endif

// Fixed JTAG-only per-frame evidence is a separate, explicit opt-in. It never
// changes the accepted R18 path, radio settings, or the 106-ms USB contract.
#ifndef VC_LORA_R19_TIMED_PATH_DIAGNOSTICS
#define VC_LORA_R19_TIMED_PATH_DIAGNOSTICS 0
#endif
#if VC_LORA_R19_TIMED_PATH_DIAGNOSTICS != 0 && VC_LORA_R19_TIMED_PATH_DIAGNOSTICS != 1
#error "VC_LORA_R19_TIMED_PATH_DIAGNOSTICS must be 0 or 1"
#endif
#if VC_LORA_R19_TIMED_PATH_DIAGNOSTICS && \
    (!VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS || VC_LORA_R19_USB_READINESS_MODE == 0)
#error "R19 timed-path diagnostics require runtime diagnostics and explicit readiness mode 1 or 2"
#endif

#ifndef VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
#define VC_LORA_R19_AUX_READINESS_DIAGNOSTICS 0
#endif
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS != 0 && VC_LORA_R19_AUX_READINESS_DIAGNOSTICS != 1
#error "VC_LORA_R19_AUX_READINESS_DIAGNOSTICS must be 0 or 1"
#endif
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS && \
    (!VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS || !VC_LORA_R19_TIMED_PATH_DIAGNOSTICS || VC_LORA_R19_USB_READINESS_MODE != 2)
#error "R19 AUX/readiness diagnostics require timed-path ExplicitHostArm diagnostics"
#endif

#ifndef VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD
#define VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD 0
#endif
#if VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD != 0 && VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD != 1
#error "VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD must be 0 or 1"
#endif
#if VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD && !VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
#error "Diagnostic USB first-failure evidence requires runtime diagnostics"
#endif

#ifndef VC_LORA_R19_GRANT_DIAGNOSTICS
#define VC_LORA_R19_GRANT_DIAGNOSTICS 0
#endif
#if VC_LORA_R19_GRANT_DIAGNOSTICS != 0 && VC_LORA_R19_GRANT_DIAGNOSTICS != 1
#error "VC_LORA_R19_GRANT_DIAGNOSTICS must be 0 or 1"
#endif
#if VC_LORA_R19_GRANT_DIAGNOSTICS && \
    (!VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS || !VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD || !VC_LORA_R19_AUX_READINESS_DIAGNOSTICS || VC_LORA_R19_USB_READINESS_MODE != 2)
#error "Grant diagnostics require full ExplicitHostArm diagnostic mode"
#endif

// Host-assisted reservation is a separate diagnostic capability, never an
// implicit change to the accepted standard path or an on-air reservation.
#ifndef VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
#define VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS 0
#endif
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS != 0 && VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS != 1
#error "VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS must be 0 or 1"
#endif
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS && !VC_LORA_R19_GRANT_DIAGNOSTICS
#error "Grant reservation requires full Grant/ExplicitHostArm diagnostics"
#endif
#ifndef VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS
#define VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS 0
#endif
#if VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS != 0 && VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS != 1
#error "Grant reservation stop diagnostics must be 0 or 1"
#endif
#if VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS && !VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
#error "Grant reservation stop diagnostics require Grant reservation diagnostics"
#endif

#include <Arduino.h>
#include <Preferences.h>
#include <esp_timer.h>
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
#include <driver/gpio.h>
#include <hal/gpio_ll.h>
#endif
#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
#include <esp_random.h>
#if defined(VC_LORA_PHASE6_VEHICLE)
#include <driver/uart.h>
#endif
#endif
#if defined(VC_LORA_PHASE6_GROUND)
#include <hal/usb_serial_jtag_ll.h>
#endif

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>

#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
#include "high_speed/e220_high_speed_transport_model.hpp"
#include "high_speed/high_speed_phase6_adapter.hpp"
#include "high_speed/phase6_bulk_rx_tail_ledger.hpp"
#include "high_speed/phase6_high_speed_radio_session.hpp"
#include "high_speed/phase6_high_speed_role_config.hpp"
#include "high_speed/phase6_radio_writer_arbiter.hpp"
#include "high_speed/peer_completion_receipt.hpp"
#include "high_speed/vc_lora_high_speed_candidate.hpp"
#endif
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
#include "high_speed/r19_runtime_fail_diagnostic.hpp"
#include "high_speed/r19_runtime_stage_record.hpp"
#include "high_speed/r19_first_usb_failure_record.hpp"
#if VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD
#include "high_speed/r19_diagnostic_usb_failure_record.hpp"
#endif
#if VC_LORA_R19_GRANT_DIAGNOSTICS
#include "high_speed/r19_grant_diagnostic_record.hpp"
#endif
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
#include "high_speed/r19_grant_reservation.hpp"
#include "high_speed/r19_grant_reservation_record.hpp"
#if VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS
#include "high_speed/r19_grant_reservation_stop_record.hpp"
#endif
#endif
#if VC_LORA_R19_TIMED_PATH_DIAGNOSTICS
#include "high_speed/r19_timed_path_record.hpp"
#endif
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
#include "high_speed/r19_aux_readiness_record.hpp"
#endif
#if VC_LORA_R19_USB_READINESS_MODE != 0
#include "diagnostics/r19_host_readiness.hpp"
#else
#include "high_speed/r19_usb_clock_sync.hpp"
#endif
#endif

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

#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
using experimental::GroundHighSpeedPhase6Adapter;
using experimental::GroundUsbHostCommitEvent;
using experimental::HighSpeedCandidateContract;
using experimental::HighSpeedPhase6AdapterStatus;
using experimental::HighSpeedPhase6Output;
using experimental::HighSpeedPhase6OutputType;
using experimental::Phase6HighSpeedRadioSession;
using experimental::Phase6HighSpeedRadioSessionStatus;
using experimental::Phase6HighSpeedRadioWrite;
using experimental::Phase6HighSpeedRoleEntropy;
using experimental::Phase6HighSpeedStreamLimits;
using experimental::Phase6RadioTailEvidence;
using experimental::Phase6RadioWriterArbiter;
using experimental::Phase6RadioWriterLease;
using experimental::Phase6RadioWriterOwner;
using experimental::Phase6RadioWriterStatus;
using experimental::Phase6RadioWriterUartResult;
using experimental::PeerCompletionReceiptFields;
using experimental::PeerCompletionReceiptFrame;
using experimental::PeerCompletionReceiptKind;
using experimental::PeerCompletionReceiptLedger;
using experimental::PeerCompletionReceiptLedgerStatus;
using experimental::PeerCompletionReceiptProducer;
using experimental::PeerCompletionReceiptProducerStatus;
using experimental::PeerCompletionReceiptProof;
using experimental::PeerCompletionReceiptWrite;
using experimental::PeerCompletionReceiptWriteDisposition;
using experimental::R19BulkRxTailLedger;
using experimental::TerminalAckReassembler;
using experimental::TransferToken;
using experimental::VehicleHighSpeedPhase6Adapter;

#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
using experimental::R19RuntimeAliveDiagnosticPublisher;
using experimental::R19RuntimeAliveEvidence;
using experimental::R19RuntimeAliveState;
using experimental::R19RuntimeDiagnosticAction;
using experimental::R19RuntimeDiagnosticCadence;
using experimental::R19RuntimeDiagnosticTransportFailureReason;
using experimental::R19RuntimeDiagnosticTransportTrace;
using experimental::R19RuntimeFailDiagnosticPublisher;
using experimental::R19RuntimeFailLatch;
using experimental::R19RuntimeFailRole;
using experimental::R19RuntimeFailStatusSnapshot;
using experimental::R19RuntimeFailWriteView;
using experimental::R19RuntimeFailWriteStatus;
using experimental::R19RuntimeBuildFingerprint;
using experimental::R19RuntimeStage;
using experimental::R19RuntimeStageCounter;
using experimental::R19RuntimeStageRecord;
using experimental::R19RuntimeStageRole;
using experimental::R19GroundUsbCommitEvidence;
using experimental::R19GroundUsbCommitFailureReason;
using experimental::R19GroundUsbCommitRecord;

constexpr std::size_t kR19RuntimeFailDiagnosticWriteChunkBytes = 32U;
constexpr std::size_t kR19RuntimeDiagnosticBootstrapFrameBytes = 63U;
constexpr std::uint32_t kR19RuntimeFailDiagnosticVehicleBaud = 115200U;
constexpr std::uint32_t kR19RuntimeFailDiagnosticFlushBudgetMs = 100U;
constexpr std::uint64_t kR19RuntimeDiagnosticFrameBudgetMs = 500U;
constexpr std::uint64_t kR19RuntimeDiagnosticRecoveryBudgetMs = 120000U;
// This is a diagnostic-generation marker, not a source digest. Exact candidate
// identity comes from the sealed artifact/readback SHA-256 evidence.
constexpr R19RuntimeBuildFingerprint
    kR19RuntimeDiagnosticGenerationFingerprint{
    0x52313944U, 0x53544731U, 0x32303236U, 0x31303033U};
constexpr std::uint32_t kR19RuntimeStageTransportFailureDomain =
    0x54520000U;
enum class R19RuntimeDiagnosticTransportRecovery : std::uint8_t {
  None = 0U,
  FrameFlush,
  GroundBoundaryFlush,
};
#if defined(VC_LORA_PHASE6_GROUND)
constexpr R19RuntimeStageRole kR19RuntimeStageRole =
    R19RuntimeStageRole::Ground;
#else
constexpr R19RuntimeStageRole kR19RuntimeStageRole =
    R19RuntimeStageRole::Vehicle;
#endif

// This diagnostic-only object has a stable unmangled name and a fixed 68-byte
// layout. It is read directly through JTAG; no snapshot is routed to USB CDC,
// E220, or the Pixhawk UART.
extern "C" {
__attribute__((used, aligned(4))) R19RuntimeStageRecord
    vc_lora_r19_runtime_stage_record{};
__attribute__((used, aligned(4))) R19GroundUsbCommitRecord
    vc_lora_r19_ground_usb_commit_record{};
__attribute__((used, aligned(4))) experimental::R19FirstUsbFailureRecord
    vc_lora_r19_first_usb_failure_record{};
#if VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD
__attribute__((used, aligned(4))) experimental::R19DiagnosticUsbFailureRecord
    vc_lora_r19_diagnostic_usb_failure_record{};
#endif
#if VC_LORA_R19_GRANT_DIAGNOSTICS
__attribute__((used, aligned(4))) experimental::R19GrantDiagnosticRecord
    vc_lora_r19_grant_diagnostic_record{};
#endif
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
__attribute__((used, aligned(4))) experimental::R19GrantReservationRecord
    vc_lora_r19_grant_reservation_record{};
#if VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS
__attribute__((used, aligned(4))) experimental::R19GrantReservationStopRecord
    vc_lora_r19_grant_reservation_stop_record{};
#endif
#endif
#if VC_LORA_R19_TIMED_PATH_DIAGNOSTICS
__attribute__((used, aligned(4))) experimental::R19TimedPathRecord
    vc_lora_r19_timed_path_record{};
#endif
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
__attribute__((used, aligned(4))) experimental::R19AuxReadinessRecord
    vc_lora_r19_aux_readiness_record{};
#endif
}

#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
std::uint64_t monotonic_now_ms() noexcept;
experimental::R19GrantReservationController r19_grant_reservation{};
std::uint64_t r19_grant_reservation_boot_id{0U};
MavlinkFrame r19_grant_reservation_reply{};
std::size_t r19_grant_reservation_reply_offset{0U};
std::uint32_t r19_grant_reservation_reply_epoch{0U};
std::uint64_t r19_grant_reservation_reply_deadline_ms{0U};
std::uint8_t r19_grant_reservation_sequence{0U};
bool r19_grant_reservation_reply_active{false};
bool r19_grant_reservation_reply_fault{false};
bool r19_grant_reservation_negotiation_started{false};
#if defined(VC_LORA_PHASE6_VEHICLE)
LinkAction r19_reserved_grant_action{};
bool r19_reserved_grant_action_valid{false};
bool r19_reserved_grant_releasing{false};
bool r19_reserved_grant_uart_accepted{false};
bool r19_cancel_unwritten_reserved_grant(std::uint64_t now_ms) noexcept;
#endif
bool r19_intercept_grant_reservation_usb_frame(const MavlinkFrame&) noexcept;
void r19_note_grant_reservation() noexcept;
void r19_abort_grant_reservation(std::uint32_t detail) noexcept;
bool r19_service_grant_reservation_reply() noexcept;
void r19_tick_grant_reservation() noexcept;
#if defined(VC_LORA_PHASE6_GROUND)
bool r19_reservation_ground_boundary_clean() noexcept;
#endif
#endif

#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
experimental::R19BootInstance r19_aux_readiness_boot_instance{};
using experimental::R19UsbReadinessEvent;
using experimental::R19UsbIntervalKind;

// Four fixed interval aggregates, not a per-loop event stream. The loop flag
// means the ordinary AUX observer was bypassed, not that the USB call failed.
class R19AuxReadinessIntervalScope {
 public:
  explicit R19AuxReadinessIntervalScope(R19UsbIntervalKind kind,
      bool bypassed_aux = true) noexcept
      : kind_(kind), begin_us_(static_cast<std::uint64_t>(esp_timer_get_time())),
        bypassed_aux_(bypassed_aux) {}
  ~R19AuxReadinessIntervalScope() noexcept {
    (void)vc_lora_r19_aux_readiness_record.ready.interval(kind_, begin_us_,
        static_cast<std::uint64_t>(esp_timer_get_time()), bypassed_aux_);
  }
  void normal_aux_observed() noexcept { bypassed_aux_ = false; }
 private:
  R19UsbIntervalKind kind_;
  std::uint64_t begin_us_;
  bool bypassed_aux_;
};

void r19_note_usb_readiness_event(R19UsbReadinessEvent event,
    std::uint32_t a = 0U, std::uint32_t b = 0U,
    std::uint32_t c = 0U, std::uint32_t d = 0U) noexcept {
  (void)vc_lora_r19_aux_readiness_record.ready.event(event,
      static_cast<std::uint64_t>(esp_timer_get_time()), a, b, c, d);
}
#endif

#if defined(VC_LORA_PHASE6_GROUND) && VC_LORA_R19_USB_READINESS_MODE != 0
experimental::R19HostReadinessGate r19_host_readiness_gate{};
std::uint64_t r19_usb_readiness_boot_id{0U};
std::uint64_t r19_usb_readiness_reader_session{0U};
bool r19_usb_readiness_initialized{false};
bool r19_usb_readiness_configured{false};
std::uint64_t r19_usb_readiness_acquisition_deadline_us{0U};
bool r19_usb_ready_publication_complete{false};
// Independent diagnostic session acquisition budget, NOT a replacement for
// the unchanged 106-ms product Heartbeat admission-to-publication deadline.
constexpr std::uint64_t kR19UsbReadinessArmTimeoutUs = 120000000U;

void r19_begin_usb_readiness_diagnostic() noexcept {
#if VC_LORA_R19_USB_READINESS_MODE != 0
  // Local session identity is taught to the PC by READY; it is not guessed
  // from ordinary MAVLink, nor authentication of the host's Read claim.
  r19_usb_readiness_reader_session = r19_usb_readiness_boot_id ^
      0x5231395245414459ULL;
  if (r19_usb_readiness_reader_session == 0U)
    r19_usb_readiness_reader_session = 1U;
  const auto now_us = static_cast<std::uint64_t>(esp_timer_get_time());
  r19_usb_readiness_acquisition_deadline_us =
      now_us > std::numeric_limits<std::uint64_t>::max() -
                   kR19UsbReadinessArmTimeoutUs
          ? std::numeric_limits<std::uint64_t>::max()
          : now_us + kR19UsbReadinessArmTimeoutUs;
  // The wrapper is closed before any product admission. Bind the concrete
  // USB loss epoch only on the first validated diagnostic request, because
  // host enumeration/reset can legitimately change it after setup. Until
  // then the gate's inert default object is NEVER consulted for permission.
  r19_usb_readiness_configured = r19_usb_readiness_boot_id != 0U;
#endif
}
#endif

void r19_mark_runtime_stage(R19RuntimeStage stage) noexcept {
  (void)vc_lora_r19_runtime_stage_record.mark_stage(
      experimental::r19_runtime_stage_bit(stage));
}

void r19_increment_runtime_stage_counter(
    R19RuntimeStageCounter counter) noexcept {
  (void)vc_lora_r19_runtime_stage_record.increment_counter(counter);
}

void r19_initialize_runtime_stage_record() noexcept {
  // New instance identity is diagnostic metadata only; it does not replace
  // the persisted RF/TDD session identity or change any normal build.
  experimental::R19BootInstance instance{
      esp_random(), esp_random(), esp_random(), esp_random()};
  if ((instance[0] | instance[1] | instance[2] | instance[3]) == 0U)
    instance[3] = 1U;
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
  if ((instance[0] | instance[1]) == 0U) instance[0] = 1U;
  r19_grant_reservation_boot_id = static_cast<std::uint64_t>(instance[0]) |
      (static_cast<std::uint64_t>(instance[1]) << 32U);
  if (r19_grant_reservation_boot_id == 0U) r19_grant_reservation_boot_id = 1U;
  (void)vc_lora_r19_grant_reservation_record.initialize(
      static_cast<experimental::R19GrantReservationRole>(kR19RuntimeStageRole),
      kR19RuntimeDiagnosticGenerationFingerprint, instance);
#if VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS
  (void)vc_lora_r19_grant_reservation_stop_record.initialize(
      static_cast<experimental::R19GrantReservationRole>(kR19RuntimeStageRole),
      kR19RuntimeDiagnosticGenerationFingerprint, instance);
#endif
#endif
#if defined(VC_LORA_PHASE6_GROUND) && VC_LORA_R19_USB_READINESS_MODE != 0
  r19_usb_readiness_boot_id = static_cast<std::uint64_t>(instance[0]) |
      (static_cast<std::uint64_t>(instance[1]) << 32U);
  if (r19_usb_readiness_boot_id == 0U) r19_usb_readiness_boot_id = 1U;
#endif
  (void)vc_lora_r19_first_usb_failure_record.initialize(
      kR19RuntimeStageRole, kR19RuntimeDiagnosticGenerationFingerprint, instance);
#if VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD
  (void)vc_lora_r19_diagnostic_usb_failure_record.initialize(
      kR19RuntimeStageRole, kR19RuntimeDiagnosticGenerationFingerprint, instance);
#endif
#if VC_LORA_R19_GRANT_DIAGNOSTICS
  (void)vc_lora_r19_grant_diagnostic_record.initialize(
      kR19RuntimeStageRole, kR19RuntimeDiagnosticGenerationFingerprint, instance);
#endif
#if VC_LORA_R19_TIMED_PATH_DIAGNOSTICS
  (void)vc_lora_r19_timed_path_record.initialize(
      kR19RuntimeStageRole, kR19RuntimeDiagnosticGenerationFingerprint, instance,
#if defined(VC_LORA_PHASE6_VEHICLE)
      1U);  // Vehicle USB diagnostics support clock-only, never Ground HostArm.
#else
      VC_LORA_R19_USB_READINESS_MODE);
#endif
#endif
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  r19_aux_readiness_boot_instance = instance;
  (void)vc_lora_r19_aux_readiness_record.aux.initialize(
      kR19RuntimeStageRole, kR19RuntimeDiagnosticGenerationFingerprint, instance);
  (void)vc_lora_r19_aux_readiness_record.ready.initialize(
      kR19RuntimeStageRole, kR19RuntimeDiagnosticGenerationFingerprint, instance);
  // The ISR-owned section is initialized later, after GPIO input setup and
  // strictly before interrupt attachment. Main never writes it after attach.
#endif
  (void)vc_lora_r19_ground_usb_commit_record.initialize(
      kR19RuntimeStageRole, kR19RuntimeDiagnosticGenerationFingerprint);
  if (vc_lora_r19_runtime_stage_record.initialize(
          kR19RuntimeStageRole,
          kR19RuntimeDiagnosticGenerationFingerprint)) {
    r19_increment_runtime_stage_counter(R19RuntimeStageCounter::Boot);
    r19_mark_runtime_stage(R19RuntimeStage::SetupEntered);
  }
}

void r19_latch_runtime_stage_transport_failure(
    R19RuntimeDiagnosticTransportFailureReason reason,
    std::uint64_t now_ms) noexcept {
  const std::uint32_t reason_code = static_cast<std::uint32_t>(reason);
  if (reason_code == 0U) {
    return;
  }
  (void)vc_lora_r19_runtime_stage_record.latch_first_failure(
      kR19RuntimeStageTransportFailureDomain | reason_code,
      static_cast<std::uint32_t>(now_ms & 0xFFFFFFFFU));
}
#if defined(VC_LORA_PHASE6_GROUND)
constexpr std::uint64_t kR19RuntimeFailGroundConvergenceBudgetMs = 500U;
constexpr std::uint64_t kR19RuntimeAliveGroundConvergenceBudgetMs = 500U;
enum class R19RuntimeFailGroundBoundaryStatus : std::uint8_t {
  Idle = 0U,
  WaitingHost,
  DrainingAdmitted,
  Clean,
  Impossible,
};
#endif
static_assert(!experimental::
                   r19_runtime_fail_diagnostic_deployment_authorized,
               "runtime-fail diagnostic candidates are not deployable");
static_assert(R19RuntimeFailDiagnosticPublisher::wire_bytes ==
                  kR19RuntimeDiagnosticBootstrapFrameBytes &&
                  R19RuntimeAliveDiagnosticPublisher::wire_bytes ==
                      kR19RuntimeDiagnosticBootstrapFrameBytes,
              "diagnostic bootstrap requires one fixed 63-byte wire image");
#if defined(VC_LORA_PHASE6_GROUND)
static_assert(static_cast<std::uint8_t>(GroundTddState::DoneDrain) <= 0x7FU,
              "Ground TDD state no longer fits diagnostic status packing");
#else
static_assert(static_cast<std::uint8_t>(VehicleTddState::ReturnGuard) <=
                  0x7FU,
              "Vehicle TDD state no longer fits diagnostic status packing");
#endif

R19RuntimeFailLatch r19_runtime_fail_latch{};
R19RuntimeFailDiagnosticPublisher r19_runtime_fail_publisher{};
R19RuntimeAliveDiagnosticPublisher r19_runtime_alive_publisher{};
R19RuntimeDiagnosticCadence r19_runtime_diagnostic_cadence{};
R19RuntimeDiagnosticAction r19_runtime_diagnostic_action{
    R19RuntimeDiagnosticAction::None};
bool r19_runtime_fail_diagnostic_staged{false};
bool r19_runtime_fail_diagnostic_flush_pending{false};
bool r19_runtime_diagnostic_bootstrap_pending{false};
bool r19_runtime_fail_diagnostic_published{false};
bool r19_runtime_fail_diagnostic_transport_failed{false};
R19RuntimeDiagnosticTransportRecovery
    r19_runtime_diagnostic_transport_recovery{
        R19RuntimeDiagnosticTransportRecovery::None};
std::uint32_t r19_runtime_diagnostic_recovery_epoch{0U};
std::uint64_t r19_runtime_diagnostic_recovery_until_ms{0U};
#if defined(VC_LORA_PHASE6_GROUND)
std::uint64_t r19_runtime_diagnostic_recovery_target_bytes{0U};
#endif
R19RuntimeDiagnosticTransportTrace r19_runtime_diagnostic_transport_trace{};
bool r19_runtime_diagnostic_committed_this_service{false};
#if defined(VC_LORA_PHASE6_GROUND)
experimental::R19HwcdcFlushCallEvidence r19_product_flush_call{};
std::uint32_t r19_product_flush_attempt{0U};
std::uint32_t r19_product_flush_budget_ms{0U};
std::uint64_t r19_product_flush_started_us{0U};
std::uint64_t r19_product_flush_finished_us{0U};
bool r19_product_flush_api_called{false};
MavlinkStreamParser r19_failed_usb_clock_parser{};
MavlinkFrame r19_usb_clock_reply{};
bool r19_usb_clock_reply_pending{false};
bool r19_usb_clock_reply_active{false};
bool r19_usb_clock_reply_fault{false};
std::size_t r19_usb_clock_reply_offset{0U};
std::uint32_t r19_usb_clock_reply_epoch{0U};
std::uint64_t r19_usb_clock_reply_deadline_ms{0U};
std::uint8_t r19_usb_clock_sequence{0U};
#if VC_LORA_R19_USB_READINESS_MODE != 0
enum class R19UsbPrivateReplyKind : std::uint8_t { Clock, Ready };
R19UsbPrivateReplyKind r19_usb_private_reply_kind{R19UsbPrivateReplyKind::Clock};
std::uint64_t r19_usb_clock_reply_nonce{0U};
std::uint64_t r19_usb_clock_reply_device_us{0U};
#endif

bool r19_intercept_usb_clock_request(const MavlinkFrame& frame) noexcept {
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
  if (r19_intercept_grant_reservation_usb_frame(frame)) return true;
#else
  // A disabled diagnostic namespace is still private: never leak it to RF.
  if (frame.system_id == 249U &&
      (frame.component_id == 197U || frame.component_id == 198U)) return true;
#endif
#if VC_LORA_R19_USB_READINESS_MODE != 0
  if (experimental::r19_is_host_readiness_namespace(frame)) {
    // Consume invalid/stale/replayed diagnostic ARM and READY locally too.
    // OUT receipt alone is not evidence of a physical USB IN completion.
#if VC_LORA_R19_USB_READINESS_MODE == 2
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
    r19_note_usb_readiness_event(R19UsbReadinessEvent::ArmReceived,
        frame.component_id, Serial.txLossEpoch(),
        r19_usb_ready_publication_complete ? 1U : 0U,
        static_cast<std::uint32_t>(r19_host_readiness_gate.snapshot().state));
#endif
    experimental::R19HostReadinessCommand command{};
    if (r19_usb_readiness_initialized &&
        r19_usb_ready_publication_complete &&
        !r19_usb_clock_reply_pending && !r19_usb_clock_reply_active &&
        !r19_usb_clock_reply_fault &&
        experimental::r19_decode_host_readiness_frame(frame, command)) {
#if VC_LORA_R19_TIMED_PATH_DIAGNOSTICS
      const auto armed_us = static_cast<std::uint64_t>(esp_timer_get_time());
      const auto armed_epoch = Serial.txLossEpoch();
      const bool arm_accepted =
          r19_host_readiness_gate.accept_arm(command, armed_epoch, armed_us);
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
      r19_note_usb_readiness_event(R19UsbReadinessEvent::ArmAccepted,
          arm_accepted ? 1U : 0U, armed_epoch,
          static_cast<std::uint32_t>(r19_host_readiness_gate.snapshot().state),
          command.proof_flags);
#endif
      if (arm_accepted) {
        (void)vc_lora_r19_timed_path_record.observe_arm(command.reader_session,
            command.nonce, armed_epoch, armed_us);
      }
#else
      (void)r19_host_readiness_gate.accept_arm(command, Serial.txLossEpoch(),
          static_cast<std::uint64_t>(esp_timer_get_time()));
#endif
    }
#endif
    return true;
  }
#endif
  if (!experimental::r19_is_usb_clock_namespace(frame)) return false;
  // Consume the whole diagnostic namespace locally, including invalid or busy
  // requests. None may reach the product parameter proxy/radio path.
  std::uint64_t nonce = 0U;
  if (r19_usb_clock_reply_pending || r19_usb_clock_reply_active ||
      r19_usb_clock_reply_fault ||
      !experimental::r19_decode_usb_clock_request(frame, nonce)) return true;
  const auto sampled_us = static_cast<std::uint64_t>(esp_timer_get_time());
#if VC_LORA_R19_USB_READINESS_MODE != 0
  if (!r19_usb_readiness_configured) return true;
  if (sampled_us >= r19_usb_readiness_acquisition_deadline_us) return true;
  if (!r19_usb_readiness_initialized) {
    r19_usb_readiness_initialized = r19_host_readiness_gate.begin_session(
        static_cast<experimental::R19HostReadinessMode>(
            VC_LORA_R19_USB_READINESS_MODE),
        experimental::R19HostReadinessRole::Ground,
        r19_usb_readiness_boot_id, Serial.txLossEpoch(),
        r19_usb_readiness_reader_session, sampled_us,
        r19_usb_readiness_acquisition_deadline_us - sampled_us);
  }
  if (!r19_usb_readiness_initialized ||
      !r19_host_readiness_gate.observe_clock_request(
          nonce, Serial.txLossEpoch(), sampled_us)) return true;
#endif
  if (!experimental::r19_encode_usb_clock_response(
          r19_usb_clock_sequence, nonce, sampled_us, r19_usb_clock_reply) ||
      !vc_lora_r19_first_usb_failure_record.observe_clock_sync(nonce, sampled_us))
    return true;
#if VC_LORA_R19_TIMED_PATH_DIAGNOSTICS
  (void)vc_lora_r19_timed_path_record.observe_session(
      r19_usb_readiness_reader_session, nonce,
      r19_host_readiness_gate.snapshot().usb_epoch, sampled_us);
#endif
#if VC_LORA_R19_USB_READINESS_MODE != 0
  r19_usb_clock_reply_nonce = nonce;
  r19_usb_clock_reply_device_us = sampled_us;
  r19_usb_private_reply_kind = R19UsbPrivateReplyKind::Clock;
#endif
  r19_usb_clock_reply_pending = true;
  return true;
}

void r19_collect_failed_usb_clock_requests() noexcept {
  if (!runtime_fail_closed) return;
  for (std::size_t n = 0U; n < 128U && Serial.available() > 0; ++n) {
    const int byte = Serial.read();
    if (byte < 0) break;
    MavlinkFrame frame{};
    if (r19_failed_usb_clock_parser.push(static_cast<std::uint8_t>(byte), frame) ==
        MavlinkParseStatus::FrameReady)
      (void)r19_intercept_usb_clock_request(frame);
  }
}
#endif
#if defined(VC_LORA_PHASE6_VEHICLE) && VC_LORA_R19_USB_READINESS_MODE != 0
MavlinkStreamParser r19_vehicle_usb_clock_parser{};
MavlinkFrame r19_vehicle_usb_clock_reply{};
bool r19_vehicle_usb_clock_seen{false};
bool r19_vehicle_usb_clock_pending{false};
bool r19_vehicle_usb_clock_active{false};
bool r19_vehicle_usb_clock_fault{false};
std::size_t r19_vehicle_usb_clock_offset{0U};
std::uint32_t r19_vehicle_usb_clock_epoch{0U};
std::uint64_t r19_vehicle_usb_clock_deadline_ms{0U};

void r19_collect_vehicle_usb_clock_requests() noexcept {
  // COM3 is a diagnostic endpoint, not a Pixhawk/RF tunnel. Consume every
  // local USB byte but only one canonical private clock request per boot can
  // produce a reply. ARM/READY, invalid frames and replayed nonces stay local.
  for (std::size_t n = 0U; n < 128U && Serial.available() > 0; ++n) {
    const int byte = Serial.read();
    if (byte < 0) break;
    MavlinkFrame frame{};
    if (r19_vehicle_usb_clock_parser.push(static_cast<std::uint8_t>(byte), frame)
            != MavlinkParseStatus::FrameReady) continue;
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
    if (r19_intercept_grant_reservation_usb_frame(frame)) continue;
#endif
    if (r19_vehicle_usb_clock_seen || r19_vehicle_usb_clock_fault) continue;
    std::uint64_t nonce = 0U;
    if (!experimental::r19_decode_usb_clock_request(frame, nonce)) continue;
    const auto sampled_us = static_cast<std::uint64_t>(esp_timer_get_time());
    experimental::R19FirstUsbFailureSnapshot snapshot{};
    if (!vc_lora_r19_first_usb_failure_record.try_snapshot(snapshot) ||
        !snapshot.valid_header() ||
        !experimental::r19_encode_usb_clock_response(0U, nonce, sampled_us,
            r19_vehicle_usb_clock_reply)) continue;
    const auto epoch = Serial.txLossEpoch();
    if (!vc_lora_r19_first_usb_failure_record.observe_clock_sync(nonce,
            sampled_us)) continue;
    // The 512-byte timed-path record is Ground product Heartbeat evidence.
    // Vehicle clock sync belongs to the existing boot-bound 384-byte record;
    // never call Ground-only session/ARM methods or invent those witnesses.
    r19_vehicle_usb_clock_seen = true;
    r19_vehicle_usb_clock_epoch = epoch;
    r19_vehicle_usb_clock_pending = true;
  }
}
#endif
std::uint32_t r19_runtime_fail_diagnostic_transport_epoch{0U};
std::uint64_t r19_runtime_diagnostic_frame_deadline_ms{0U};
std::uint8_t r19_runtime_diagnostic_mavlink_sequence{0U};

#if VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD
// Main-task call-local value. Only the separate fixed JTAG record is immutable;
// this scratch value may advance through bounded attempts until a terminal
// publisher failure. It is cleared at every logical frame boundary, so a
// pre-API failure never borrows a previous frame's successful FIFO snapshot.
experimental::R19DiagnosticUsbFailureEvidence r19_diagnostic_usb_call{};
std::uint32_t r19_diagnostic_usb_flush_attempt{0U};
std::uint32_t r19_diagnostic_usb_accepted_frame_bytes{0U};

void r19_reset_diagnostic_usb_call() noexcept {
  r19_diagnostic_usb_call = {};
  r19_diagnostic_usb_accepted_frame_bytes = 0U;
}

void r19_latch_diagnostic_usb_failure(
    R19RuntimeDiagnosticTransportFailureReason reason,
    std::uint32_t source_line) noexcept {
  auto evidence = r19_diagnostic_usb_call;
  evidence.reason = static_cast<std::uint32_t>(reason);
  evidence.source_line = source_line;
  evidence.action = static_cast<std::uint32_t>(r19_runtime_diagnostic_action);
  evidence.diagnostic_sequence = static_cast<std::uint8_t>(
      r19_runtime_diagnostic_mavlink_sequence -
      (r19_runtime_fail_diagnostic_staged ? 1U : 0U));
  evidence.bootstrap_flags =
      (r19_runtime_diagnostic_bootstrap_pending ? 1U : 0U) |
      (r19_runtime_fail_diagnostic_staged ? 2U : 0U) |
      (r19_runtime_fail_diagnostic_flush_pending ? 4U : 0U) |
      (r19_runtime_diagnostic_transport_recovery !=
          R19RuntimeDiagnosticTransportRecovery::None ? 8U : 0U);
  if ((evidence.wrapper_flags & 1U) == 0U)
    evidence.expected_epoch = r19_runtime_fail_diagnostic_transport_epoch;
  evidence.observed_epoch = Serial.txLossEpoch();
  evidence.failure_observed_us = static_cast<std::uint64_t>(esp_timer_get_time());
  if (evidence.deadline_us == 0U)
    evidence.deadline_us = r19_runtime_diagnostic_frame_deadline_ms * 1000U;
  evidence.expected_frame_bytes = r19_runtime_fail_diagnostic_staged
      ? static_cast<std::uint32_t>(kR19RuntimeDiagnosticBootstrapFrameBytes) : 0U;
  evidence.accepted_frame_bytes = r19_runtime_fail_diagnostic_staged
      ? r19_diagnostic_usb_accepted_frame_bytes : 0U;
  if ((evidence.wrapper_flags & 1U) != 0U &&
      evidence.sdk.transaction_token == evidence.diagnostic_sequence + 1U &&
      evidence.sdk.attempt_id == evidence.attempt_id &&
      evidence.sdk.expected_loss_epoch == evidence.expected_epoch &&
      evidence.sdk.timeout_ms == evidence.budget_ms &&
      evidence.sdk.raw_return == ((evidence.wrapper_flags & 2U) != 0U ? 1U : 0U))
    evidence.wrapper_flags |= 16U;
  if (evidence.deadline_us != 0U && evidence.finished_us < evidence.deadline_us)
    evidence.wrapper_flags |= 8U;
  (void)vc_lora_r19_diagnostic_usb_failure_record.latch_first_failure(evidence);
}
#endif

void r19_clear_diagnostic_transport_recovery() noexcept {
  r19_runtime_diagnostic_transport_recovery =
      R19RuntimeDiagnosticTransportRecovery::None;
  r19_runtime_diagnostic_recovery_epoch = 0U;
  r19_runtime_diagnostic_recovery_until_ms = 0U;
#if defined(VC_LORA_PHASE6_GROUND)
  r19_runtime_diagnostic_recovery_target_bytes = 0U;
#endif
}

void r19_fail_diagnostic_transport(
    R19RuntimeDiagnosticTransportFailureReason reason,
    std::uint64_t now_ms,
#if defined(__GNUC__) || defined(__clang__)
    std::uint32_t source_line = __builtin_LINE()) noexcept {
#else
    std::uint32_t source_line = 0U) noexcept {
#endif
#if VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD
  r19_latch_diagnostic_usb_failure(reason, source_line);
#else
  (void)source_line;
#endif
  r19_latch_runtime_stage_transport_failure(reason, now_ms);
  r19_runtime_diagnostic_transport_trace.latch_failure(reason, now_ms);
  r19_clear_diagnostic_transport_recovery();
  r19_runtime_fail_diagnostic_transport_failed = true;
}

bool r19_flush_runtime_diagnostic(std::uint32_t expected_epoch,
    std::uint32_t budget_ms, std::uint64_t& completed_ms,
    std::uint64_t deadline_ms = 0U) noexcept;

bool r19_arm_diagnostic_transport_recovery(
    R19RuntimeDiagnosticTransportRecovery recovery,
    std::uint32_t expected_epoch, std::uint64_t now_ms,
    std::uint64_t target_bytes = 0U) noexcept {
  if (recovery == R19RuntimeDiagnosticTransportRecovery::None ||
      !r19_runtime_fail_diagnostic_transport_failed ||
      r19_runtime_diagnostic_transport_recovery !=
          R19RuntimeDiagnosticTransportRecovery::None ||
      Serial.txLossEpoch() != expected_epoch ||
      now_ms > std::numeric_limits<std::uint64_t>::max() -
                   kR19RuntimeDiagnosticRecoveryBudgetMs) {
    return false;
  }
  r19_runtime_diagnostic_transport_recovery = recovery;
  r19_runtime_diagnostic_recovery_epoch = expected_epoch;
  r19_runtime_diagnostic_recovery_until_ms =
      now_ms + kR19RuntimeDiagnosticRecoveryBudgetMs;
#if defined(VC_LORA_PHASE6_GROUND)
  r19_runtime_diagnostic_recovery_target_bytes = target_bytes;
#else
  (void)target_bytes;
#endif
  r19_mark_runtime_stage(R19RuntimeStage::TransportRecoveryEntered);
  return true;
}
#if defined(VC_LORA_PHASE6_GROUND)
R19RuntimeFailGroundBoundaryStatus r19_runtime_fail_ground_boundary_status{
    R19RuntimeFailGroundBoundaryStatus::Idle};
std::uint32_t r19_runtime_fail_ground_boundary_epoch{0U};
std::uint64_t r19_runtime_fail_ground_boundary_deadline_ms{0U};
bool r19_runtime_alive_ground_reservation_active{false};
std::uint32_t r19_runtime_alive_ground_reservation_epoch{0U};
std::uint64_t r19_runtime_alive_ground_reservation_deadline_ms{0U};
#endif
#endif

// This is the sole owner arbitration point for the physical E220 UART.
Phase6RadioWriterArbiter e220_writer_arbiter{};
Phase6RadioWriterLease standard_radio_writer_lease{};
LinkActionType standard_radio_writer_action_type{LinkActionType::None};
TddControlMessage standard_radio_writer_control{};
bool standard_radio_writer_tail_pending{false};

struct R19StandardVehicleGrantTailEvidence final {
  Phase6RadioTailEvidence tail{};
  TddControlMessage grant{};
  bool valid{false};
};

R19StandardVehicleGrantTailEvidence
    retained_standard_vehicle_grant_tail{};

bool r19_product_route_selected{false};
bool r19_standard_tdd_frozen{false};
// R19 acceleration is intentionally single-shot for one boot.  Its evidence
// owners are one-shot by construction; after a clean session later #21 frames
// use the unchanged R18 parameter proxy until a future explicit rearm design.
bool r19_acceleration_consumed{false};
bool r19_role_adapter_constructed{false};
bool r19_session_owners_constructed{false};

enum class R19RadioStreamPurpose : std::uint8_t {
  None = 0U,
  GroundNegotiationRequest,
  VehicleNegotiationResponse,
  VehicleBulkDownlink,
  GroundTerminalAck,
};

alignas(Phase6HighSpeedRadioSession)
    std::array<std::uint8_t, sizeof(Phase6HighSpeedRadioSession)>
        r19_radio_session_storage{};
Phase6HighSpeedRadioSession* r19_radio_session{nullptr};
R19RadioStreamPurpose r19_radio_stream_purpose{R19RadioStreamPurpose::None};
std::uint32_t r19_next_radio_stream_token{0xC1000000U};
bool r19_radio_buffer_credit_pending{false};
bool r19_retained_radio_action_final{false};
bool r19_radio_final_action_committed{false};
TransferToken r19_radio_final_transfer_token{};
std::uint32_t r19_radio_final_action_token{0U};
std::uint32_t r19_radio_final_writer_generation{0U};

PeerCompletionReceiptLedger r19_peer_receipt_ledger{};
PeerCompletionReceiptProducer r19_peer_receipt_producer{};
bool r19_peer_receipt_ledger_armed{false};
bool r19_peer_receipt_proof_delivered{false};
PeerCompletionReceiptKind r19_peer_receipt_ledger_kind{
    PeerCompletionReceiptKind::None};
bool r19_peer_receipt_producer_staged{false};
bool r19_peer_receipt_standard_tail_pending{false};
PeerCompletionReceiptKind r19_peer_receipt_producer_kind{
    PeerCompletionReceiptKind::None};
std::uint64_t r19_peer_receipt_send_not_before_ms{0U};
std::uint64_t r19_peer_receipt_send_deadline_ms{0U};
std::uint64_t r19_standard_resume_not_before_ms{0U};
constexpr std::uint64_t kR19PeerReceiptReceiveMarginMs = 650U;
constexpr std::uint64_t kR19PeerReceiptDeadlineMs =
    BulkSessionTiming::peer_completion_receipt_timeout_ms;
static_assert(BulkSessionTiming::peer_completion_receipt_timeout_ms ==
              BulkSessionTiming::direction_guard_ms +
                  FixedFirmwareContract::e220_subpacket_service_floor_ms +
                  kR19PeerReceiptReceiveMarginMs);
static_assert(kR19PeerReceiptDeadlineMs == 1300U);
static_assert(kR19PeerReceiptDeadlineMs <
              FixedFirmwareContract::heartbeat_hard_deadline_ms);

#if defined(VC_LORA_PHASE6_GROUND)
alignas(GroundHighSpeedPhase6Adapter)
    std::array<std::uint8_t, sizeof(GroundHighSpeedPhase6Adapter)>
        r19_role_adapter_storage{};
GroundHighSpeedPhase6Adapter* r19_ground_adapter{nullptr};

// One immutable request copy for a pre-negotiation decline. This is neither a
// second radio request nor a new timing origin: the failed adapter and its
// original t0 remain untouched after the standard-path handoff.
MavlinkFrame r19_held_parameter_request{};
bool r19_held_parameter_request_valid{false};
std::uint64_t r19_held_parameter_request_origin_ms{0U};
std::uint64_t r19_held_parameter_request_loss_epoch{0U};
std::uint32_t r19_pre_negotiation_fallback_count{0U};
std::uint64_t r19_pre_negotiation_fallback_ms{0U};

alignas(BulkDataStreamDecoder)
    std::array<std::uint8_t, sizeof(BulkDataStreamDecoder)>
        r19_bulk_decoder_storage{};
alignas(BulkTranscriptLedger)
    std::array<std::uint8_t, sizeof(BulkTranscriptLedger)>
        r19_bulk_transcript_storage{};
alignas(BulkHeartbeatSlaLedger)
    std::array<std::uint8_t, sizeof(BulkHeartbeatSlaLedger)>
        r19_bulk_sla_storage{};
alignas(experimental::GroundTerminalAckProducer)
    std::array<std::uint8_t,
               sizeof(experimental::GroundTerminalAckProducer)>
        r19_terminal_producer_storage{};
BulkDataStreamDecoder* r19_bulk_decoder{nullptr};
BulkTranscriptLedger* r19_bulk_transcript{nullptr};
BulkHeartbeatSlaLedger* r19_bulk_sla{nullptr};
experimental::GroundTerminalAckProducer* r19_terminal_producer{nullptr};
R19BulkRxTailLedger r19_bulk_rx_tail_ledger{};
bool r19_have_ground_usb_heartbeat_commit{false};
std::uint64_t r19_last_ground_usb_heartbeat_commit_ms{0U};
bool r19_ground_usb_commit_active{false};
bool r19_ground_usb_commit_final{false};
std::uint32_t r19_ground_usb_commit_token{0U};
std::uint32_t r19_ground_usb_commit_loss_epoch{0U};
std::uint64_t r19_ground_usb_commit_goal{0U};
std::uint64_t r19_ground_usb_commit_deadline_ms{0U};
bool r19_ground_negotiation_response_pending{false};
BulkNegotiationFrame r19_ground_negotiation_response{};
std::uint64_t r19_ground_negotiation_response_ms{0U};
#else
alignas(VehicleHighSpeedPhase6Adapter)
    std::array<std::uint8_t, sizeof(VehicleHighSpeedPhase6Adapter)>
        r19_role_adapter_storage{};
VehicleHighSpeedPhase6Adapter* r19_vehicle_adapter{nullptr};

alignas(BulkDataTxLease)
    std::array<std::uint8_t, sizeof(BulkDataTxLease)>
        r19_bulk_tx_lease_storage{};
alignas(BulkDataStreamDecoder)
    std::array<std::uint8_t, sizeof(BulkDataStreamDecoder)>
        r19_tx_mirror_decoder_storage{};
alignas(BulkTranscriptLedger)
    std::array<std::uint8_t, sizeof(BulkTranscriptLedger)>
        r19_sender_transcript_storage{};
BulkDataTxLease* r19_bulk_tx_lease{nullptr};
BulkDataStreamDecoder* r19_tx_mirror_decoder{nullptr};
BulkTranscriptLedger* r19_sender_transcript{nullptr};
experimental::VehicleTerminalAckExpectedFactory
    r19_terminal_expected_factory{};
alignas(TerminalAckReassembler)
    std::array<std::uint8_t, sizeof(TerminalAckReassembler)>
        r19_terminal_reassembler_storage{};
TerminalAckReassembler* r19_terminal_reassembler{nullptr};
bool r19_terminal_record_reassembled{false};
bool r19_terminal_window_open{false};
bool r19_vehicle_bulk_semantic_complete{false};
bool r19_pixhawk_commit_active{false};
std::uint32_t r19_pixhawk_commit_token{0U};
std::uint64_t r19_pixhawk_commit_goal{0U};
std::uint64_t r19_pixhawk_commit_deadline_ms{0U};
std::uint64_t r19_vehicle_bulk_radio_not_before_ms{0U};
constexpr std::uint64_t kR19PixhawkCommitDeadlineMs = 100U;
#endif
#endif

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

constexpr GroundUsbHeartbeatPacerConfig
product_ground_usb_heartbeat_pacer_config() noexcept {
  GroundUsbHeartbeatPacerConfig config{};
  // One successful PARAM_VALUE publication fence may precede a due HB. Move
  // the host-gap trigger forward by that fixed 100-ms budget and include it
  // in the hard-age completion allowance without changing TDD timing.
  config.soft_due_ms = 2100U;
  config.loop_jitter_budget_ms = 200U;
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
    product_ground_usb_heartbeat_pacer_config()};
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
std::uint32_t ground_usb_observed_loss_epoch{0U};
std::uint64_t ground_usb_transport_published_bytes{0U};
bool ground_paced_heartbeat_commit_active{false};
std::uint32_t ground_paced_heartbeat_commit_token{0U};
std::uint64_t ground_paced_heartbeat_commit_goal{0U};
std::uint64_t ground_paced_heartbeat_commit_deadline_ms{0U};
std::uint32_t ground_paced_heartbeat_commit_loss_epoch{0U};
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
// Current product transaction context only. The fixed JTAG record latches a
// failed observation once and is never reused by the later R19F publisher.
std::uint64_t r19_ground_heartbeat_commit_started_ms{0U};
std::uint64_t r19_ground_heartbeat_committed_base{0U};
std::uint32_t r19_ground_heartbeat_expected_frame_bytes{0U};
std::uint64_t r19_ground_usb_last_flush_started_ms{0U};
bool r19_ground_heartbeat_flush_result_observed{false};
bool r19_ground_heartbeat_transport_published{false};
#endif
bool ground_parameter_publish_commit_active{false};
MavlinkFrame ground_parameter_publish_commit_frame{};
std::uint64_t ground_parameter_publish_commit_goal{0U};
std::uint64_t ground_parameter_publish_commit_deadline_ms{0U};
std::uint32_t ground_parameter_publish_commit_loss_epoch{0U};
bool ground_proxy_request_admitted{false};
bool ground_proxy_request_dequeued{false};
std::uint32_t ground_proxy_request_token{0U};
std::uint64_t ground_proxy_request_dequeue_goal{0U};
std::uint64_t ground_proxy_request_done_goal{0U};
std::uint64_t ground_proxy_request_progress_bytes{0U};
GroundTddController tdd_controller(kTddConfig, link_diagnostics);
#endif

#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
bool aux_high() noexcept;
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
void latch_runtime_fail_closed_at(std::uint16_t source_line) noexcept;
void r19_service_runtime_fail_diagnostic() noexcept;
#define latch_runtime_fail_closed()                                      \
  latch_runtime_fail_closed_at(static_cast<std::uint16_t>(__LINE__))
#else
void latch_runtime_fail_closed() noexcept;
#endif
void r19_service_peer_receipt_producer(std::uint64_t now_ms) noexcept;
void r19_finish_candidate_if_ready(std::uint64_t now_ms) noexcept;

std::uint64_t r19_entropy_sample() noexcept {
  const std::uint64_t high = static_cast<std::uint64_t>(esp_random());
  const std::uint64_t low = static_cast<std::uint64_t>(esp_random());
  return (high << 32U) | low;
}

bool setup_r19_high_speed_role_adapter() noexcept {
  if (r19_role_adapter_constructed || boot_identity.boot_id == 0U ||
      boot_identity.session_id == 0U) {
    latch_runtime_fail_closed();
    return false;
  }
  const Phase6HighSpeedRoleEntropy entropy{r19_entropy_sample(),
                                           r19_entropy_sample()};
  if (!experimental::role_config_detail::entropy_valid(entropy)) {
    latch_runtime_fail_closed();
    return false;
  }
#if defined(VC_LORA_PHASE6_GROUND)
  const GroundBulkSessionConfig config =
      experimental::make_r19_ground_bulk_session_config(
          BulkSessionFeature::Enabled, boot_identity, entropy);
  r19_ground_adapter = ::new (static_cast<void*>(
      r19_role_adapter_storage.data())) GroundHighSpeedPhase6Adapter(config);
  if (r19_ground_adapter == nullptr || r19_ground_adapter->fail_closed()) {
    latch_runtime_fail_closed();
    return false;
  }
#else
  const VehicleBulkSessionConfig config =
      experimental::make_r19_vehicle_bulk_session_config(
          BulkSessionFeature::Enabled, boot_identity, entropy);
  r19_vehicle_adapter = ::new (static_cast<void*>(
      r19_role_adapter_storage.data())) VehicleHighSpeedPhase6Adapter(config);
  if (r19_vehicle_adapter == nullptr || r19_vehicle_adapter->fail_closed()) {
    latch_runtime_fail_closed();
    return false;
  }
#endif
  r19_role_adapter_constructed = true;
  return true;
}

bool r19_adapter_fail_closed() noexcept {
#if defined(VC_LORA_PHASE6_GROUND)
  return r19_ground_adapter == nullptr || r19_ground_adapter->fail_closed();
#else
  return r19_vehicle_adapter == nullptr || r19_vehicle_adapter->fail_closed();
#endif
}

bool r19_now32(std::uint64_t now_ms, std::uint32_t& output) noexcept {
  if (now_ms > static_cast<std::uint64_t>(
                   std::numeric_limits<std::uint32_t>::max())) {
    latch_runtime_fail_closed();
    return false;
  }
  output = static_cast<std::uint32_t>(now_ms);
  return true;
}

Phase6HighSpeedStreamLimits r19_radio_stream_limits(
    R19RadioStreamPurpose purpose) noexcept {
  switch (purpose) {
    case R19RadioStreamPurpose::GroundNegotiationRequest:
    case R19RadioStreamPurpose::VehicleNegotiationResponse:
      return {1U, 32U, 32U};
    case R19RadioStreamPurpose::VehicleBulkDownlink:
      return {2000U, 64000U, 32U};
    case R19RadioStreamPurpose::GroundTerminalAck:
      return {8U, 256U, 32U};
    case R19RadioStreamPurpose::None:
    default:
      return {};
  }
}

experimental::Direction r19_radio_stream_direction(
    R19RadioStreamPurpose purpose) noexcept {
  return purpose == R19RadioStreamPurpose::GroundNegotiationRequest ||
                 purpose == R19RadioStreamPurpose::GroundTerminalAck
             ? experimental::Direction::Uplink
             : experimental::Direction::Downlink;
}

bool r19_radio_stream_session_id(
    R19RadioStreamPurpose purpose,
    std::uint64_t& session_id) noexcept {
  session_id = 0U;
#if defined(VC_LORA_PHASE6_GROUND)
  if (purpose == R19RadioStreamPurpose::GroundNegotiationRequest) {
    session_id =
        (static_cast<std::uint64_t>(boot_identity.boot_id) << 16U) |
        static_cast<std::uint64_t>(boot_identity.session_id);
  } else if (purpose == R19RadioStreamPurpose::GroundTerminalAck &&
             r19_ground_adapter != nullptr) {
    session_id = r19_ground_adapter->identity().session_id;
  }
#else
  if ((purpose == R19RadioStreamPurpose::VehicleNegotiationResponse ||
       purpose == R19RadioStreamPurpose::VehicleBulkDownlink) &&
      r19_vehicle_adapter != nullptr) {
    session_id = r19_vehicle_adapter->identity().session_id;
  }
#endif
  return session_id != 0U;
}

bool r19_peer_receipt_fields(
    PeerCompletionReceiptKind kind,
    PeerCompletionReceiptFields& fields) noexcept {
  fields = {};
#if defined(VC_LORA_PHASE6_GROUND)
  if (r19_ground_adapter == nullptr) {
    return false;
  }
  const BulkNegotiationIdentity& identity = r19_ground_adapter->identity();
  const std::uint64_t subject_id =
      kind == PeerCompletionReceiptKind::NegotiationResponseConsumed
          ? identity.lease_id
          : kind == PeerCompletionReceiptKind::TerminalRecordConsumed
                ? r19_ground_adapter->terminal_record_id()
                : 0U;
  fields = {kind, identity.session_id,
            r19_ground_adapter->transfer_tag(), subject_id};
#else
  if (r19_vehicle_adapter == nullptr) {
    return false;
  }
  const BulkNegotiationIdentity& identity = r19_vehicle_adapter->identity();
  const std::uint64_t subject_id =
      kind == PeerCompletionReceiptKind::NegotiationResponseConsumed
          ? identity.lease_id
          : kind == PeerCompletionReceiptKind::TerminalRecordConsumed &&
                    r19_terminal_reassembler != nullptr
                ? r19_terminal_reassembler->last_accepted_record_id()
                : 0U;
  fields = {kind, identity.session_id,
            r19_vehicle_adapter->transfer_tag(), subject_id};
#endif
  return fields.valid();
}

bool r19_arm_peer_receipt_ledger(
    PeerCompletionReceiptKind kind,
    std::uint64_t now_ms) noexcept {
  PeerCompletionReceiptFields fields{};
  std::uint32_t now32 = 0U;
  if (r19_peer_receipt_ledger_armed || r19_radio_session == nullptr ||
      !r19_radio_final_action_committed ||
      !r19_radio_final_transfer_token.valid() ||
      !r19_peer_receipt_fields(kind, fields) ||
      !r19_now32(now_ms, now32) ||
      now32 > std::numeric_limits<std::uint32_t>::max() -
                  static_cast<std::uint32_t>(kR19PeerReceiptDeadlineMs)) {
    latch_runtime_fail_closed();
    return false;
  }
  const std::uint32_t deadline =
      now32 + static_cast<std::uint32_t>(kR19PeerReceiptDeadlineMs);
  if (r19_peer_receipt_ledger.arm(fields, deadline, now32) !=
          PeerCompletionReceiptLedgerStatus::Armed ||
      r19_peer_receipt_ledger.bind_final_transfer(
          r19_radio_final_transfer_token, now32) !=
          PeerCompletionReceiptLedgerStatus::FinalTokenBound) {
    latch_runtime_fail_closed();
    return false;
  }
  r19_peer_receipt_ledger_armed = true;
  r19_peer_receipt_ledger_kind = kind;
  return true;
}

bool r19_stage_peer_receipt(
    PeerCompletionReceiptKind kind,
    std::uint64_t now_ms) noexcept {
  PeerCompletionReceiptFields fields{};
  std::uint32_t now32 = 0U;
  if (r19_peer_receipt_producer_staged ||
      r19_peer_receipt_standard_tail_pending ||
      !r19_peer_receipt_fields(kind, fields) ||
      !r19_now32(now_ms, now32) ||
      now_ms > std::numeric_limits<std::uint64_t>::max() -
                   kR19PeerReceiptDeadlineMs) {
    latch_runtime_fail_closed();
    return false;
  }
  if (r19_peer_receipt_producer.stage(fields, now32) !=
      PeerCompletionReceiptProducerStatus::Staged) {
    latch_runtime_fail_closed();
    return false;
  }
  r19_peer_receipt_producer_staged = true;
  r19_peer_receipt_producer_kind = kind;
  r19_peer_receipt_send_not_before_ms =
      now_ms + BulkSessionTiming::direction_guard_ms;
  r19_peer_receipt_send_deadline_ms =
      now_ms + kR19PeerReceiptDeadlineMs;
  return true;
}

bool r19_begin_radio_stream(R19RadioStreamPurpose purpose,
                            std::uint64_t now_ms) noexcept {
  std::uint32_t now32 = 0U;
  std::uint64_t session_id = 0U;
  if (r19_radio_session != nullptr ||
      purpose == R19RadioStreamPurpose::None ||
      r19_next_radio_stream_token ==
          std::numeric_limits<std::uint32_t>::max() ||
      !r19_now32(now_ms, now32) ||
      !r19_radio_stream_session_id(purpose, session_id)) {
    latch_runtime_fail_closed();
    return false;
  }
  r19_radio_session = ::new (static_cast<void*>(
      r19_radio_session_storage.data()))
      Phase6HighSpeedRadioSession(e220_writer_arbiter, session_id);
  ++r19_next_radio_stream_token;
  if (r19_radio_session == nullptr ||
      r19_radio_session->begin(
          r19_next_radio_stream_token,
          r19_radio_stream_direction(purpose),
          r19_radio_stream_limits(purpose), now32) !=
          Phase6HighSpeedRadioSessionStatus::StreamStarted) {
    latch_runtime_fail_closed();
    return false;
  }
  r19_radio_stream_purpose = purpose;
  r19_radio_buffer_credit_pending = false;
  r19_retained_radio_action_final = false;
  r19_radio_final_action_committed = false;
  r19_radio_final_transfer_token = {};
  r19_radio_final_action_token = 0U;
  r19_radio_final_writer_generation = 0U;
  return true;
}

R19RadioStreamPurpose r19_radio_purpose_for_output(
    const HighSpeedPhase6Output& output) noexcept {
#if defined(VC_LORA_PHASE6_GROUND)
  if (output.semantic == HighSpeedActionType::SendNegotiationRequest) {
    return R19RadioStreamPurpose::GroundNegotiationRequest;
  }
  if (output.semantic == HighSpeedActionType::SendTerminalEvidence) {
    return R19RadioStreamPurpose::GroundTerminalAck;
  }
#else
  if (output.semantic == HighSpeedActionType::SendNegotiationResponse) {
    return R19RadioStreamPurpose::VehicleNegotiationResponse;
  }
  if (output.semantic == HighSpeedActionType::SendBulkFragment) {
    return R19RadioStreamPurpose::VehicleBulkDownlink;
  }
#endif
  return R19RadioStreamPurpose::None;
}

bool r19_radio_output_is_final(
    const HighSpeedPhase6Output& output) noexcept {
  switch (r19_radio_stream_purpose) {
    case R19RadioStreamPurpose::GroundNegotiationRequest:
      return output.semantic == HighSpeedActionType::SendNegotiationRequest;
    case R19RadioStreamPurpose::VehicleNegotiationResponse:
      return output.semantic == HighSpeedActionType::SendNegotiationResponse;
    case R19RadioStreamPurpose::GroundTerminalAck:
      return output.semantic == HighSpeedActionType::SendTerminalEvidence &&
             r19_radio_session != nullptr &&
             r19_radio_session->uart_record_count() + 1U == 8U;
    case R19RadioStreamPurpose::VehicleBulkDownlink: {
#if defined(VC_LORA_PHASE6_VEHICLE)
      if (output.semantic != HighSpeedActionType::SendBulkFragment ||
          output.size != BulkDataFragment{}.size() ||
          r19_tx_mirror_decoder == nullptr) {
        return false;
      }
      BulkDataFragment fragment{};
      std::copy_n(output.bytes.begin(), fragment.size(), fragment.begin());
      BulkDataDecodedFragment decoded{};
      return BulkDataWireCodec::decode_fragment(fragment, decoded) ==
                 BulkDataWireStatus::FragmentReady &&
             decoded.kind == BulkDataFragmentKind::ParameterTail &&
             r19_tx_mirror_decoder->parameter_count() + 1U ==
                 r19_tx_mirror_decoder->expected_parameter_count();
#else
      return false;
#endif
    }
    case R19RadioStreamPurpose::None:
    default:
      return false;
  }
}

bool route_r19_high_speed_radio_output(
    const HighSpeedPhase6Output& output,
    std::uint64_t now_ms) noexcept {
  if (output.type != HighSpeedPhase6OutputType::RadioWrite ||
      output.token == 0U || output.writer_generation == 0U ||
      output.size == 0U || output.size > 32U) {
    latch_runtime_fail_closed();
    return false;
  }
  const R19RadioStreamPurpose purpose =
      r19_radio_purpose_for_output(output);
  if (purpose == R19RadioStreamPurpose::None ||
      (r19_radio_session == nullptr &&
       !r19_begin_radio_stream(purpose, now_ms)) ||
      r19_radio_stream_purpose != purpose ||
      r19_radio_session == nullptr) {
    latch_runtime_fail_closed();
    return false;
  }
  std::uint32_t now32 = 0U;
  r19_retained_radio_action_final = r19_radio_output_is_final(output);
  if (!r19_now32(now_ms, now32) ||
      r19_radio_session->retain_adapter_action(
          output, r19_retained_radio_action_final, now32) !=
          Phase6HighSpeedRadioSessionStatus::ActionRetained) {
    latch_runtime_fail_closed();
    return false;
  }
  return true;
}

bool r19_complete_adapter_radio_output(std::uint32_t token,
                                       std::uint64_t now_ms) noexcept {
#if defined(VC_LORA_PHASE6_GROUND)
  const bool accepted = r19_ground_adapter != nullptr &&
         r19_ground_adapter->complete_output(
             token, TxResult::Accepted, now_ms) ==
             HighSpeedPhase6AdapterStatus::Accepted;
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
  if (accepted && r19_radio_stream_purpose ==
          R19RadioStreamPurpose::GroundNegotiationRequest &&
      !r19_grant_reservation_negotiation_started) {
    r19_grant_reservation.on_ground_negotiation_started(now_ms);
    r19_note_grant_reservation();
    if (r19_grant_reservation.failed()) {
      latch_runtime_fail_closed();
      return false;
    }
    r19_grant_reservation_negotiation_started = true;
  }
#endif
  return accepted;
#else
  return r19_vehicle_adapter != nullptr &&
         r19_vehicle_adapter->complete_output(
             token, TxResult::Accepted, now_ms) ==
             HighSpeedPhase6AdapterStatus::Accepted;
#endif
}

bool r19_account_vehicle_bulk_fragment(
    const Phase6HighSpeedRadioWrite& write) noexcept {
#if defined(VC_LORA_PHASE6_GROUND)
  (void)write;
  return true;
#else
  if (r19_radio_stream_purpose !=
          R19RadioStreamPurpose::VehicleBulkDownlink ||
      r19_tx_mirror_decoder == nullptr ||
      r19_sender_transcript == nullptr ||
      write.size != BulkDataFragment{}.size()) {
    return r19_radio_stream_purpose !=
           R19RadioStreamPurpose::VehicleBulkDownlink;
  }
  BulkDataFragment fragment{};
  std::copy_n(write.bytes.begin(), fragment.size(), fragment.begin());
  MavlinkFrame decoded{};
  BulkDataStreamStatus status = BulkDataStreamStatus::NeedMore;
  for (std::size_t index = 0U; index < fragment.size(); ++index) {
    status = r19_tx_mirror_decoder->push_byte(fragment[index], decoded);
    if (index + 1U != fragment.size() &&
        status != BulkDataStreamStatus::NeedMore) {
      return false;
    }
  }
  if (status == BulkDataStreamStatus::FragmentAccepted) {
    return decoded.size == 0U;
  }
  if (status != BulkDataStreamStatus::FrameReady || decoded.size == 0U ||
      r19_sender_transcript->append(decoded) !=
          BulkTranscriptStatus::EntryAccepted) {
    return false;
  }
  return true;
#endif
}

bool r19_finalize_vehicle_bulk_owners(
    std::uint64_t now_ms) noexcept {
#if defined(VC_LORA_PHASE6_GROUND)
  (void)now_ms;
  return false;
#else
  if (r19_vehicle_bulk_semantic_complete ||
      r19_vehicle_adapter == nullptr || r19_bulk_tx_lease == nullptr ||
      r19_tx_mirror_decoder == nullptr ||
      r19_sender_transcript == nullptr ||
      r19_terminal_reassembler != nullptr ||
      !r19_tx_mirror_decoder->finish() ||
      r19_tx_mirror_decoder->seal_session() !=
          BulkDataStreamLifecycleStatus::Sealed ||
      r19_sender_transcript->seal_session() !=
          BulkTranscriptStatus::Sealed ||
      r19_vehicle_adapter->complete_bulk_downlink(
          *r19_bulk_tx_lease, now_ms) !=
          HighSpeedPhase6AdapterStatus::TerminalReady) {
    return false;
  }
  experimental::TerminalAckExpectedEvidence expected{};
  if (r19_terminal_expected_factory.make_expected(
          r19_vehicle_adapter->identity(), *r19_sender_transcript,
          expected) != experimental::TerminalAckProducerStatus::ExpectedReady) {
    return false;
  }
  r19_terminal_reassembler = ::new (static_cast<void*>(
      r19_terminal_reassembler_storage.data()))
      TerminalAckReassembler(expected);
  if (r19_terminal_reassembler == nullptr) {
    return false;
  }
  r19_vehicle_bulk_semantic_complete = true;
  return true;
#endif
}

void r19_destroy_radio_session() noexcept {
  if (r19_radio_session != nullptr) {
    r19_radio_session->~Phase6HighSpeedRadioSession();
  }
  r19_radio_session = nullptr;
  r19_radio_stream_purpose = R19RadioStreamPurpose::None;
  r19_radio_buffer_credit_pending = false;
  r19_retained_radio_action_final = false;
  r19_radio_final_action_committed = false;
  r19_radio_final_transfer_token = {};
  r19_radio_final_action_token = 0U;
  r19_radio_final_writer_generation = 0U;
}

bool r19_finalize_peer_proven_radio_stream(
    std::uint64_t now_ms) noexcept {
  if (r19_radio_session == nullptr ||
      !r19_peer_receipt_ledger_armed ||
      !r19_peer_receipt_proof_delivered ||
      r19_radio_session->last_status() !=
          Phase6HighSpeedRadioSessionStatus::ExplicitRestoreRequired) {
    latch_runtime_fail_closed();
    return false;
  }
  const HighSpeedTailDrainEvidence tail{
      r19_radio_final_action_token, true, now_ms};
#if defined(VC_LORA_PHASE6_GROUND)
  if (r19_radio_stream_purpose !=
          R19RadioStreamPurpose::GroundTerminalAck ||
      r19_peer_receipt_ledger_kind !=
          PeerCompletionReceiptKind::TerminalRecordConsumed ||
      r19_ground_adapter == nullptr ||
      r19_ground_adapter->on_radio_tail(tail, now_ms) !=
          HighSpeedPhase6AdapterStatus::Complete) {
    latch_runtime_fail_closed();
    return false;
  }
#else
  if (r19_radio_stream_purpose !=
          R19RadioStreamPurpose::VehicleNegotiationResponse ||
      r19_peer_receipt_ledger_kind !=
          PeerCompletionReceiptKind::NegotiationResponseConsumed ||
      r19_vehicle_adapter == nullptr ||
      r19_vehicle_adapter->on_radio_tail(tail, now_ms) !=
          HighSpeedPhase6AdapterStatus::TailAccepted) {
    latch_runtime_fail_closed();
    return false;
  }
#endif
  std::uint32_t now32 = 0U;
  if (!r19_now32(now_ms, now32) ||
      r19_radio_session->restore_standard(true, now32) !=
          Phase6HighSpeedRadioSessionStatus::StandardRestored) {
    latch_runtime_fail_closed();
    return false;
  }
  r19_destroy_radio_session();
  r19_peer_receipt_ledger_armed = false;
#if defined(VC_LORA_PHASE6_GROUND)
  if (now_ms > std::numeric_limits<std::uint64_t>::max() -
                   BulkSessionTiming::direction_guard_ms) {
    latch_runtime_fail_closed();
    return false;
  }
  r19_standard_resume_not_before_ms =
      now_ms + BulkSessionTiming::direction_guard_ms;
#endif
  return true;
}

void r19_service_radio_session(std::uint64_t now_ms) noexcept {
  if (r19_radio_session == nullptr || runtime_fail_closed) {
    return;
  }
  std::uint32_t now32 = 0U;
  if (!r19_now32(now_ms, now32) ||
      r19_radio_session->observe_aux(now32, aux_high()) !=
          Phase6HighSpeedRadioSessionStatus::StreamActive) {
    latch_runtime_fail_closed();
    return;
  }
  if (r19_peer_receipt_ledger_armed &&
      !r19_peer_receipt_proof_delivered) {
    const PeerCompletionReceiptLedgerStatus receipt_status =
        r19_peer_receipt_ledger.tick(now32);
    if (receipt_status != PeerCompletionReceiptLedgerStatus::Armed &&
        receipt_status !=
            PeerCompletionReceiptLedgerStatus::FinalTokenBound &&
        receipt_status !=
            PeerCompletionReceiptLedgerStatus::ReceiptRetained &&
        receipt_status != PeerCompletionReceiptLedgerStatus::ProofReady) {
      latch_runtime_fail_closed();
      return;
    }
  }
  if (r19_radio_buffer_credit_pending) {
    const Phase6HighSpeedRadioSessionStatus credit =
        r19_radio_session->release_buffer_credit_from_local_aux(
            now32, r19_radio_session->last_transfer_token());
    if (credit ==
        Phase6HighSpeedRadioSessionStatus::AwaitBufferCredit) {
      // A continuous AUX-HIGH burst may legitimately consume several 32-byte
      // records before the E220's documented 400-byte buffer backpressures.
      // Keep the latest token pending, but let the admission gate decide
      // whether another same-direction record fits after the 3-ms gap.
    } else if (credit ==
               Phase6HighSpeedRadioSessionStatus::ExplicitRestoreRequired) {
      r19_radio_buffer_credit_pending = false;
      if (!r19_peer_receipt_proof_delivered ||
          !r19_finalize_peer_proven_radio_stream(now_ms)) {
        return;
      }
      return;
    } else if (credit !=
               Phase6HighSpeedRadioSessionStatus::BufferCreditReleased) {
      latch_runtime_fail_closed();
      return;
    } else {
      r19_radio_buffer_credit_pending = false;
    }
  }
  if (!r19_radio_session->pending_action()) {
    return;
  }
  if (e220_serial.availableForWrite() <
      static_cast<int>(HighSpeedCandidateContract::radio_chunk_bytes)) {
    return;
  }
  Phase6HighSpeedRadioWrite write{};
  const Phase6HighSpeedRadioSessionStatus admission =
      r19_radio_session->assess_write(now32, write);
  if (admission == Phase6HighSpeedRadioSessionStatus::AwaitAdmission) {
    return;
  }
  if (admission != Phase6HighSpeedRadioSessionStatus::WriteReady ||
      !write.valid()) {
    latch_runtime_fail_closed();
    return;
  }
  const std::size_t written = e220_serial.write(write.bytes.data(), write.size);
  if (written != write.size ||
      r19_radio_session->complete_uart(
          write.action_token, write.writer_generation,
          write.wire_ordinal, written, now32) !=
          Phase6HighSpeedRadioSessionStatus::WriteCommitted ||
      !r19_complete_adapter_radio_output(write.action_token, now_ms) ||
      !r19_account_vehicle_bulk_fragment(write)) {
    latch_runtime_fail_closed();
    return;
  }
  r19_radio_buffer_credit_pending = true;
  if (r19_retained_radio_action_final) {
    r19_radio_final_action_committed = true;
    r19_radio_final_transfer_token =
        r19_radio_session->last_transfer_token();
    r19_radio_final_action_token = write.action_token;
    r19_radio_final_writer_generation = write.writer_generation;
#if defined(VC_LORA_PHASE6_GROUND)
    if (r19_radio_stream_purpose ==
            R19RadioStreamPurpose::GroundTerminalAck &&
        !r19_arm_peer_receipt_ledger(
            PeerCompletionReceiptKind::TerminalRecordConsumed, now_ms)) {
      return;
    }
#else
    if (r19_radio_stream_purpose ==
            R19RadioStreamPurpose::VehicleNegotiationResponse &&
        !r19_arm_peer_receipt_ledger(
            PeerCompletionReceiptKind::NegotiationResponseConsumed,
            now_ms)) {
      return;
    }
#endif
    if (r19_radio_stream_purpose ==
            R19RadioStreamPurpose::VehicleBulkDownlink &&
        !r19_finalize_vehicle_bulk_owners(now_ms)) {
      latch_runtime_fail_closed();
      return;
    }
  }
  r19_retained_radio_action_final = false;
}

bool r19_complete_action_stream_from_remote_arrival(
    std::uint64_t now_ms) noexcept {
  if (r19_radio_session == nullptr ||
      !r19_radio_final_action_committed ||
      r19_radio_buffer_credit_pending) {
    return false;
  }
  std::uint32_t now32 = 0U;
  if (!r19_now32(now_ms, now32) ||
      r19_radio_session->complete_stream_from_remote_arrival(
          r19_radio_final_transfer_token, now32) !=
          Phase6HighSpeedRadioSessionStatus::ExplicitRestoreRequired) {
    latch_runtime_fail_closed();
    return false;
  }
  const HighSpeedTailDrainEvidence tail{
      r19_radio_final_action_token, true, now_ms};
#if defined(VC_LORA_PHASE6_GROUND)
  const bool tail_accepted = r19_ground_adapter != nullptr &&
      r19_ground_adapter->on_radio_tail(tail, now_ms) ==
          HighSpeedPhase6AdapterStatus::TailAccepted;
#else
  const bool tail_accepted = r19_vehicle_adapter != nullptr &&
      r19_vehicle_adapter->on_radio_tail(tail, now_ms) ==
          HighSpeedPhase6AdapterStatus::TailAccepted;
#endif
  if (!tail_accepted ||
      r19_radio_session->restore_standard(true, now32) !=
          Phase6HighSpeedRadioSessionStatus::StandardRestored) {
    latch_runtime_fail_closed();
    return false;
  }
  r19_radio_session->~Phase6HighSpeedRadioSession();
  r19_radio_session = nullptr;
  r19_radio_stream_purpose = R19RadioStreamPurpose::None;
  r19_radio_final_action_committed = false;
  r19_radio_final_transfer_token = {};
  r19_radio_final_action_token = 0U;
  r19_radio_final_writer_generation = 0U;
  return true;
}

bool r19_complete_bulk_stream_from_remote_arrival(
    std::uint64_t now_ms) noexcept {
#if defined(VC_LORA_PHASE6_GROUND)
  (void)now_ms;
  return false;
#else
  if (r19_radio_session == nullptr ||
      r19_radio_stream_purpose !=
          R19RadioStreamPurpose::VehicleBulkDownlink ||
      !r19_radio_final_action_committed ||
      r19_radio_buffer_credit_pending ||
      r19_vehicle_adapter == nullptr ||
      r19_radio_session->uart_record_count() == 0U) {
    return false;
  }
  std::uint32_t now32 = 0U;
  if (!r19_now32(now_ms, now32) ||
      r19_radio_session->complete_stream_from_remote_arrival(
          r19_radio_final_transfer_token, now32) !=
          Phase6HighSpeedRadioSessionStatus::ExplicitRestoreRequired) {
    latch_runtime_fail_closed();
    return false;
  }
  const HighSpeedStreamTailEvidence tail{
      r19_vehicle_adapter->transfer_tag(),
      r19_radio_session->uart_record_count() - 1U,
      r19_radio_session->uart_record_count(),
      r19_radio_final_action_token,
      r19_radio_final_writer_generation,
      true,
      now_ms};
  if (r19_vehicle_adapter->on_bulk_tail(tail, now_ms) !=
          HighSpeedPhase6AdapterStatus::TailAccepted ||
      r19_radio_session->restore_standard(true, now32) !=
          Phase6HighSpeedRadioSessionStatus::StandardRestored) {
    latch_runtime_fail_closed();
    return false;
  }
  r19_radio_session->~Phase6HighSpeedRadioSession();
  r19_radio_session = nullptr;
  r19_radio_stream_purpose = R19RadioStreamPurpose::None;
  r19_radio_final_action_committed = false;
  r19_radio_final_transfer_token = {};
  r19_radio_final_action_token = 0U;
  r19_radio_final_writer_generation = 0U;
  return true;
#endif
}

bool r19_route_peer_completion_receipt(
    const TddDemuxEvent& event, std::uint64_t now_ms) noexcept {
  if (!event.has_peer_completion_receipt || event.has_bulk_negotiation ||
      event.has_bulk_data || event.has_terminal_ack ||
      !r19_peer_receipt_ledger_armed ||
      r19_peer_receipt_proof_delivered || r19_radio_session == nullptr) {
    latch_runtime_fail_closed();
    return false;
  }
#if defined(VC_LORA_PHASE6_GROUND)
  if (r19_radio_stream_purpose !=
          R19RadioStreamPurpose::GroundTerminalAck ||
      r19_peer_receipt_ledger_kind !=
          PeerCompletionReceiptKind::TerminalRecordConsumed) {
    latch_runtime_fail_closed();
    return false;
  }
#else
  if (r19_radio_stream_purpose !=
          R19RadioStreamPurpose::VehicleNegotiationResponse ||
      r19_peer_receipt_ledger_kind !=
          PeerCompletionReceiptKind::NegotiationResponseConsumed) {
    latch_runtime_fail_closed();
    return false;
  }
#endif
  std::uint32_t now32 = 0U;
  PeerCompletionReceiptFrame frame{};
  std::copy(event.peer_completion_receipt.begin(),
            event.peer_completion_receipt.end(), frame.begin());
  if (!r19_now32(now_ms, now32) ||
      r19_peer_receipt_ledger.consume_peer_receipt(frame, now32) !=
          PeerCompletionReceiptLedgerStatus::ProofReady) {
    latch_runtime_fail_closed();
    return false;
  }
  PeerCompletionReceiptProof proof{};
  if (r19_peer_receipt_ledger.take_proof(proof, now32) !=
          PeerCompletionReceiptLedgerStatus::ProofIssued ||
      !proof.valid()) {
    latch_runtime_fail_closed();
    return false;
  }
  const Phase6HighSpeedRadioSessionStatus completed =
      r19_radio_session->complete_stream_from_peer_receipt(proof, now32);
  if (completed !=
          Phase6HighSpeedRadioSessionStatus::AwaitBufferCredit &&
      completed !=
          Phase6HighSpeedRadioSessionStatus::ExplicitRestoreRequired) {
    latch_runtime_fail_closed();
    return false;
  }
  r19_peer_receipt_proof_delivered = true;
#if defined(VC_LORA_PHASE6_VEHICLE)
  if (now_ms > std::numeric_limits<std::uint64_t>::max() -
                   BulkSessionTiming::direction_guard_ms) {
    latch_runtime_fail_closed();
    return false;
  }
  r19_vehicle_bulk_radio_not_before_ms =
      now_ms + BulkSessionTiming::direction_guard_ms;
#endif
  if (completed ==
          Phase6HighSpeedRadioSessionStatus::ExplicitRestoreRequired &&
      !r19_finalize_peer_proven_radio_stream(now_ms)) {
    return false;
  }
  return true;
}

#if defined(VC_LORA_PHASE6_GROUND)
void r19_note_ground_adapter_diagnostics(std::uint32_t source_line) noexcept {
#if VC_LORA_R19_GRANT_DIAGNOSTICS
  if (r19_ground_adapter == nullptr) return;
  const bool first_failure = r19_ground_adapter->failure_latched();
  const auto& snapshot = first_failure
      ? r19_ground_adapter->first_failure_diagnostics()
      : r19_ground_adapter->diagnostics();
  (void)vc_lora_r19_grant_diagnostic_record.observe(
      experimental::make_r19_grant_diagnostic_evidence(snapshot, source_line),
      first_failure);
#else
  (void)source_line;
#endif
}

bool r19_intercept_ground_usb_frame(const MavlinkFrame& frame,
                                    std::uint64_t now_ms) noexcept {
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
  // Private commands can span a millisecond during the ingress loop. Take
  // the actual whole-request callback time once, before starting its owner.
  now_ms = monotonic_now_ms();
  if (frame.message_id == 21U &&
      (!r19_grant_reservation.ground_request_allowed() ||
       !r19_reservation_ground_boundary_clean() ||
       frame.size != 14U || frame.payload_length != 2U || frame.signed_frame ||
       frame.payload()[0U] != 1U || frame.payload()[1U] != 1U)) {
    r19_abort_grant_reservation(1U);
    return true;
  }
#endif
  if (r19_acceleration_consumed) {
    // A later Mission Planner refresh is valid, but remains on the already
    // accepted R18 path; never reuse a consumed VCRC ledger or producer.
    return false;
  }
  if (r19_ground_adapter == nullptr) {
    latch_runtime_fail_closed();
    return true;
  }
  if (r19_ground_adapter->complete()) {
    // Clean restore/guard has not yet published the one-shot fallback latch.
    return true;
  }
  const HighSpeedPhase6AdapterStatus status =
      r19_ground_adapter->on_ground_usb_frame(
          frame, static_cast<std::uint64_t>(ground_usb_observed_loss_epoch),
          now_ms);
  r19_note_ground_adapter_diagnostics(__LINE__);
  switch (status) {
    case HighSpeedPhase6AdapterStatus::Held: {
      if (!r19_have_ground_usb_heartbeat_commit ||
          r19_last_ground_usb_heartbeat_commit_ms > now_ms ||
          r19_held_parameter_request_valid ||
          r19_pre_negotiation_fallback_count != 0U ||
          Serial.txLossEpoch() != ground_usb_observed_loss_epoch) {
        latch_runtime_fail_closed();
        return true;
      }
      r19_held_parameter_request = frame;
      r19_held_parameter_request_origin_ms = now_ms;
      r19_held_parameter_request_loss_epoch =
          static_cast<std::uint64_t>(ground_usb_observed_loss_epoch);
      r19_held_parameter_request_valid = true;
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
      const auto& baseline = r19_ground_adapter->diagnostics();
      r19_grant_reservation.on_ground_held(now_ms,
          baseline.standard_grant_session, baseline.standard_grant_cycle, now_ms);
      r19_note_grant_reservation();
      if (r19_grant_reservation.failed()) {
        latch_runtime_fail_closed();
        return true;
      }
#endif
      r19_product_route_selected = true;
      return true;
    }
    case HighSpeedPhase6AdapterStatus::Busy:
      return true;
    case HighSpeedPhase6AdapterStatus::PassThrough:
      return false;
    case HighSpeedPhase6AdapterStatus::FailClosed:
    case HighSpeedPhase6AdapterStatus::ClockRegression:
    case HighSpeedPhase6AdapterStatus::DeadlineExceeded:
      latch_runtime_fail_closed();
      return true;
    default:
      latch_runtime_fail_closed();
      return true;
  }
}
#endif

#if defined(VC_LORA_PHASE6_GROUND)
bool r19_construct_ground_session_owners(std::uint64_t now_ms) noexcept {
  if (r19_session_owners_constructed || r19_ground_adapter == nullptr ||
      !r19_have_ground_usb_heartbeat_commit ||
      r19_last_ground_usb_heartbeat_commit_ms > r19_ground_adapter->t0_ms() ||
      r19_ground_adapter->t0_ms() > now_ms ||
      r19_ground_adapter->transfer_tag() == 0U) {
    latch_runtime_fail_closed();
    return false;
  }
  r19_bulk_decoder = ::new (static_cast<void*>(
      r19_bulk_decoder_storage.data()))
      BulkDataStreamDecoder(r19_ground_adapter->transfer_tag());
  r19_bulk_transcript = ::new (static_cast<void*>(
      r19_bulk_transcript_storage.data()))
      BulkTranscriptLedger(r19_ground_adapter->identity(),
                           r19_ground_adapter->transfer_tag());
  r19_bulk_sla = ::new (static_cast<void*>(r19_bulk_sla_storage.data()))
      BulkHeartbeatSlaLedger(r19_ground_adapter->transfer_tag());
  r19_terminal_producer = ::new (static_cast<void*>(
      r19_terminal_producer_storage.data()))
      experimental::GroundTerminalAckProducer();
  if (r19_bulk_decoder == nullptr || r19_bulk_transcript == nullptr ||
      r19_bulk_sla == nullptr || r19_terminal_producer == nullptr ||
      r19_bulk_decoder->latched() || !r19_bulk_transcript->active() ||
      r19_bulk_sla->capture_baseline(
          r19_last_ground_usb_heartbeat_commit_ms) !=
          BulkHeartbeatSlaStatus::BaselineCaptured ||
      r19_bulk_sla->start_request(r19_ground_adapter->t0_ms()) !=
          BulkHeartbeatSlaStatus::RequestStarted ||
      r19_bulk_rx_tail_ledger.arm(r19_ground_adapter->transfer_tag(),
                                  now_ms) !=
          experimental::R19BulkRxTailLedgerStatus::Armed ||
      !radio_demux.set_bulk_data_route_mode(BulkDataRouteMode::Enabled)) {
    latch_runtime_fail_closed();
    return false;
  }
  r19_session_owners_constructed = true;
  return true;
}
#else
bool r19_construct_vehicle_session_owners() noexcept {
  if (r19_session_owners_constructed || r19_vehicle_adapter == nullptr ||
      r19_vehicle_adapter->transfer_tag() == 0U) {
    latch_runtime_fail_closed();
    return false;
  }
  r19_bulk_tx_lease = ::new (static_cast<void*>(
      r19_bulk_tx_lease_storage.data()))
      BulkDataTxLease(vehicle_scheduler, r19_vehicle_adapter->transfer_tag());
  r19_tx_mirror_decoder = ::new (static_cast<void*>(
      r19_tx_mirror_decoder_storage.data()))
      BulkDataStreamDecoder(r19_vehicle_adapter->transfer_tag());
  r19_sender_transcript = ::new (static_cast<void*>(
      r19_sender_transcript_storage.data()))
      BulkTranscriptLedger(r19_vehicle_adapter->identity(),
                           r19_vehicle_adapter->transfer_tag());
  if (r19_bulk_tx_lease == nullptr || r19_tx_mirror_decoder == nullptr ||
      r19_sender_transcript == nullptr || r19_bulk_tx_lease->latched() ||
      r19_tx_mirror_decoder->latched() ||
      !r19_sender_transcript->active()) {
    latch_runtime_fail_closed();
    return false;
  }
  r19_session_owners_constructed = true;
  return true;
}
#endif

#if defined(VC_LORA_PHASE6_GROUND)
bool r19_process_pending_ground_negotiation_response(
    std::uint64_t now_ms) noexcept {
  if (!r19_ground_negotiation_response_pending) {
    return true;
  }
  if (r19_radio_session == nullptr ||
      r19_radio_stream_purpose !=
          R19RadioStreamPurpose::GroundNegotiationRequest ||
      !r19_radio_final_action_committed) {
    latch_runtime_fail_closed();
    return false;
  }
  if (r19_radio_buffer_credit_pending) {
    return true;
  }
  // A raw VCBN arrival is not remote-tail evidence. Validate its CRC and exact
  // pending request/session/Grant correlation without mutating either owner;
  // only that correlated peer response can close the request stream.
  if (!r19_ground_adapter->prevalidate_negotiation_response(
          r19_ground_negotiation_response.data(),
          r19_ground_negotiation_response.size(), now_ms) ||
      !r19_complete_action_stream_from_remote_arrival(now_ms) ||
      r19_ground_adapter->on_negotiation_response(
          r19_ground_negotiation_response.data(),
          r19_ground_negotiation_response.size(), now_ms) !=
          HighSpeedPhase6AdapterStatus::BulkEnabled ||
      !r19_construct_ground_session_owners(now_ms) ||
      !r19_stage_peer_receipt(
          PeerCompletionReceiptKind::NegotiationResponseConsumed,
          now_ms)) {
    latch_runtime_fail_closed();
    return false;
  }
  r19_ground_negotiation_response_pending = false;
  r19_ground_negotiation_response = {};
  r19_ground_negotiation_response_ms = 0U;
  return true;
}
#endif

bool r19_route_bulk_negotiation(
    const TddDemuxEvent& event, std::uint64_t now_ms) noexcept {
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
  now_ms = monotonic_now_ms();
#endif
  if (!event.has_bulk_negotiation || event.has_bulk_data ||
      event.has_terminal_ack || event.has_peer_completion_receipt ||
      !r19_role_adapter_constructed) {
    latch_runtime_fail_closed();
    return false;
  }
#if defined(VC_LORA_PHASE6_GROUND)
  if (!r19_product_route_selected || !r19_standard_tdd_frozen ||
      r19_ground_adapter == nullptr || r19_session_owners_constructed ||
      r19_ground_negotiation_response_pending) {
    latch_runtime_fail_closed();
    return false;
  }
  // Arrival of the complete correlated VCBN response is the peer-side proof
  // that the one-record Ground request left the air. AUX alone is never used
  // as this tail proof.
  r19_ground_negotiation_response = event.bulk_negotiation_record;
  r19_ground_negotiation_response_ms = now_ms;
  r19_ground_negotiation_response_pending = true;
  r19_service_radio_session(now_ms);
  return !runtime_fail_closed &&
         r19_process_pending_ground_negotiation_response(now_ms);
#else
  if (r19_product_route_selected || r19_vehicle_adapter == nullptr ||
      !retained_standard_vehicle_grant_tail.valid) {
    latch_runtime_fail_closed();
    return false;
  }
  const Phase6RadioTailEvidence& local_tail =
      retained_standard_vehicle_grant_tail.tail;
  const TddControlMessage& grant =
      retained_standard_vehicle_grant_tail.grant;
  const HighSpeedStandardGrantEvidence retained_evidence{
      grant.session_id,
      grant.cycle_id,
      local_tail.lease.action_token,
      local_tail.lease.writer_generation,
      true,
      local_tail.physical_tail_complete,
      local_tail.completed_ms};
  if (r19_vehicle_adapter->on_negotiation_request_with_retained_grant(
          grant, retained_evidence,
          event.bulk_negotiation_record.data(),
          event.bulk_negotiation_record.size(), now_ms) !=
          HighSpeedPhase6AdapterStatus::Ready) {
    latch_runtime_fail_closed();
    return false;
  }
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
  r19_grant_reservation.on_vehicle_vcbn(grant.session_id, grant.cycle_id, now_ms);
  r19_note_grant_reservation();
  if (r19_grant_reservation.failed()) {
    latch_runtime_fail_closed();
    return false;
  }
#endif
  retained_standard_vehicle_grant_tail = {};
  r19_product_route_selected = true;
  r19_standard_tdd_frozen = true;
  return r19_construct_vehicle_session_owners();
#endif
}

bool r19_route_bulk_data(const TddDemuxEvent& event,
                         std::uint64_t now_ms) noexcept {
  if (!event.has_bulk_data || event.has_bulk_negotiation ||
      event.has_terminal_ack || event.has_peer_completion_receipt) {
    latch_runtime_fail_closed();
    return false;
  }
#if defined(VC_LORA_PHASE6_VEHICLE)
  latch_runtime_fail_closed();
  return false;
#else
  if (!r19_session_owners_constructed || r19_ground_adapter == nullptr ||
      r19_bulk_decoder == nullptr || r19_bulk_transcript == nullptr ||
      r19_bulk_sla == nullptr) {
    latch_runtime_fail_closed();
    return false;
  }
  BulkDataFragment fragment{};
  std::copy(event.bulk_data_fragment.begin(),
            event.bulk_data_fragment.end(), fragment.begin());
  MavlinkFrame decoded{};
  const experimental::R19BulkRxTailLedgerStatus ledger_status =
      r19_bulk_rx_tail_ledger.accept_decoder_fragment(
          *r19_bulk_decoder, fragment, decoded, now_ms);
  const bool final_record =
      ledger_status ==
      experimental::R19BulkRxTailLedgerStatus::FinalIdentityReady;
  if (ledger_status !=
          experimental::R19BulkRxTailLedgerStatus::FragmentAccepted &&
      !final_record) {
    latch_runtime_fail_closed();
    return false;
  }
  if (final_record) {
    HighSpeedLocalRxRecordIdentity identity{};
    if (r19_bulk_rx_tail_ledger.issue_final_identity(identity, now_ms) !=
            experimental::R19BulkRxTailLedgerStatus::IdentityIssued ||
        r19_ground_adapter->bind_final_bulk_rx_record(identity, now_ms) !=
            HighSpeedPhase6AdapterStatus::Ready) {
      latch_runtime_fail_closed();
      return false;
    }
    const HighSpeedStreamTailEvidence tail{
        identity.transfer_tag,
        identity.final_wire_ordinal,
        identity.fragment_count,
        identity.rx_record_token,
        identity.rx_ledger_generation,
        true,
        now_ms};
    if (r19_ground_adapter->on_bulk_tail(tail, now_ms) !=
        HighSpeedPhase6AdapterStatus::TailAccepted) {
      latch_runtime_fail_closed();
      return false;
    }
  }
  if (decoded.size == 0U) {
    return false;
  }
  if (r19_ground_adapter->on_decoded_bulk_frame(
          decoded, *r19_bulk_transcript, *r19_bulk_sla, now_ms) !=
      HighSpeedPhase6AdapterStatus::UsbFrameStaged) {
    latch_runtime_fail_closed();
    return false;
  }
  // Yield the UART drain loop at each complete MAVLink frame. The adapter owns
  // one host-visible commit at a time; unread E220 UART bytes remain buffered.
  return true;
#endif
}

#if defined(VC_LORA_PHASE6_VEHICLE)
bool r19_terminal_receipt_stage_ready() noexcept {
  // A priority-standard VCRC cannot acquire the one physical writer while the
  // bulk HighSpeed lease is still held.  Keep servicing the bulk session until
  // its final local buffer credit and correlated remote terminal arrival have
  // closed that lease; only then may the receipt producer be staged.
  return r19_radio_session == nullptr;
}

bool r19_complete_vehicle_terminal_if_ready(
    std::uint64_t now_ms) noexcept {
  if (!r19_terminal_record_reassembled || !r19_terminal_window_open) {
    return true;
  }
  if (r19_vehicle_adapter == nullptr || r19_terminal_reassembler == nullptr) {
    latch_runtime_fail_closed();
    return false;
  }
  if (!r19_terminal_receipt_stage_ready()) {
    return true;
  }
  if (r19_vehicle_adapter->complete()) {
    return r19_peer_receipt_producer_staged ||
           r19_peer_receipt_standard_tail_pending ||
           r19_peer_receipt_producer.committed();
  }
  if (r19_vehicle_adapter->on_terminal_reassembler(
          *r19_terminal_reassembler, now_ms) !=
          HighSpeedPhase6AdapterStatus::Complete ||
      !r19_stage_peer_receipt(
          PeerCompletionReceiptKind::TerminalRecordConsumed, now_ms)) {
    latch_runtime_fail_closed();
    return false;
  }
  return true;
}
#endif

bool r19_route_terminal_ack(const TddDemuxEvent& event,
                            std::uint64_t now_ms) noexcept {
  if (!event.has_terminal_ack || event.has_bulk_negotiation ||
      event.has_bulk_data || event.has_peer_completion_receipt) {
    latch_runtime_fail_closed();
    return false;
  }
#if defined(VC_LORA_PHASE6_GROUND)
  latch_runtime_fail_closed();
  return false;
#else
  if (r19_terminal_reassembler == nullptr || r19_vehicle_adapter == nullptr) {
    latch_runtime_fail_closed();
    return false;
  }
  experimental::TerminalAckFragment fragment{};
  std::copy(event.terminal_ack_fragment.begin(),
            event.terminal_ack_fragment.end(), fragment.begin());
  if (r19_terminal_reassembler->push(fragment) !=
      experimental::TerminalAckError::None) {
    latch_runtime_fail_closed();
    return false;
  }
  if (!r19_terminal_reassembler->complete()) {
    return false;
  }
  if (r19_terminal_reassembler->finish() !=
      experimental::TerminalAckError::None) {
    latch_runtime_fail_closed();
    return false;
  }
  r19_terminal_record_reassembled = true;
  // Only the fully reassembled and internally correlated 8-fragment VCTA is
  // peer-arrival evidence for the final VCB1 stream. A first/middle fragment
  // cannot release the HighSpeed writer lease or unlock direction.
  if (r19_radio_session != nullptr) {
    if (r19_radio_stream_purpose !=
        R19RadioStreamPurpose::VehicleBulkDownlink) {
      latch_runtime_fail_closed();
      return false;
    }
    r19_service_radio_session(now_ms);
    if (!r19_radio_buffer_credit_pending &&
        !r19_complete_bulk_stream_from_remote_arrival(now_ms)) {
      return false;
    }
  }
  if (!r19_complete_vehicle_terminal_if_ready(now_ms)) {
    return false;
  }
  return true;
#endif
}

#if defined(VC_LORA_PHASE6_GROUND)
void r19_observe_ground_grant(const TddControlMessage& message,
                              ControlDisposition disposition,
                              std::uint64_t now_ms) noexcept {
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
  now_ms = monotonic_now_ms();
#endif
#if VC_LORA_R19_GRANT_DIAGNOSTICS
  if (message.type == ControlType::UlGrant) {
    (void)vc_lora_r19_grant_diagnostic_record.observe_grant_event(
        experimental::R19GrantDiagnosticEvent::GrantReceivedRaw, now_ms,
        message.session_id, message.cycle_id, 0U, 0U, __LINE__,
        static_cast<std::uint32_t>(disposition));
  }
#endif
  if (message.type != ControlType::UlGrant ||
      disposition != ControlDisposition::Accepted) {
    return;
  }
  if (r19_acceleration_consumed) {
    // The one accelerated session is complete. Standard Grants continue to
    // the R18 TDD controller without touching the consumed candidate owner.
    return;
  }
  if (r19_ground_adapter == nullptr || r19_standard_tdd_frozen) {
    latch_runtime_fail_closed();
    return;
  }
  const HighSpeedPhase6AdapterStatus status =
      r19_ground_adapter->hold_standard_uplink()
          ? r19_ground_adapter->on_fresh_grant(
                message.session_id, message.cycle_id, now_ms)
          : r19_ground_adapter->observe_standard_grant(
                message.session_id, message.cycle_id, now_ms);
  r19_note_ground_adapter_diagnostics(__LINE__);
  if (status != HighSpeedPhase6AdapterStatus::Ready) {
    latch_runtime_fail_closed();
    return;
  }
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
  if (r19_grant_reservation.initialized()) {
    if (r19_ground_adapter->hold_standard_uplink()) {
      r19_grant_reservation.on_ground_grant(message.session_id, message.cycle_id,
          now_ms);
    } else {
      r19_grant_reservation.on_ground_baseline(message.session_id,
          message.cycle_id, now_ms);
    }
    r19_note_grant_reservation();
    if (r19_grant_reservation.failed()) {
      latch_runtime_fail_closed();
      return;
    }
  }
#endif
  if (r19_ground_adapter->hold_standard_uplink()) {
    r19_standard_tdd_frozen = true;
  }
}
#endif

#if defined(VC_LORA_PHASE6_GROUND)
bool r19_route_ground_usb_output(const HighSpeedPhase6Output& output,
                                 std::uint64_t now_ms) noexcept;
bool r19_service_pre_negotiation_fallback(std::uint64_t now_ms) noexcept;
#else
bool r19_route_pixhawk_output(const HighSpeedPhase6Output& output,
                              std::uint64_t now_ms) noexcept;
#endif

void r19_service_high_speed_product_route(
    std::uint64_t now_ms) noexcept {
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
  now_ms = monotonic_now_ms();
#endif
  if (!r19_product_route_selected || runtime_fail_closed ||
      !r19_role_adapter_constructed) {
    return;
  }
  r19_finish_candidate_if_ready(now_ms);
  if (!r19_product_route_selected || runtime_fail_closed) {
    return;
  }
  r19_service_peer_receipt_producer(now_ms);
  if (runtime_fail_closed || r19_peer_receipt_producer_staged ||
      r19_peer_receipt_standard_tail_pending) {
    return;
  }
  const HighSpeedPhase6AdapterStatus tick_status =
#if defined(VC_LORA_PHASE6_GROUND)
      r19_ground_adapter == nullptr
          ? HighSpeedPhase6AdapterStatus::FailClosed
          : r19_ground_adapter->tick(now_ms);
#else
      r19_vehicle_adapter == nullptr
          ? HighSpeedPhase6AdapterStatus::FailClosed
          : r19_vehicle_adapter->tick(now_ms);
#endif
#if defined(VC_LORA_PHASE6_GROUND)
  r19_note_ground_adapter_diagnostics(__LINE__);
#endif
  if (tick_status != HighSpeedPhase6AdapterStatus::NoAction) {
#if defined(VC_LORA_PHASE6_GROUND)
    if (r19_service_pre_negotiation_fallback(now_ms)) {
      return;
    }
#endif
    latch_runtime_fail_closed();
    return;
  }
  r19_service_radio_session(now_ms);
#if defined(VC_LORA_PHASE6_GROUND)
  if (!runtime_fail_closed &&
      !r19_process_pending_ground_negotiation_response(now_ms)) {
    return;
  }
  if (r19_peer_receipt_producer_staged ||
      r19_peer_receipt_standard_tail_pending) {
    return;
  }
#endif
#if defined(VC_LORA_PHASE6_VEHICLE)
  if (r19_terminal_record_reassembled && r19_radio_session != nullptr &&
      r19_radio_stream_purpose ==
          R19RadioStreamPurpose::VehicleBulkDownlink &&
      !r19_radio_buffer_credit_pending &&
      !r19_complete_bulk_stream_from_remote_arrival(now_ms)) {
    return;
  }
  if (!runtime_fail_closed && r19_terminal_record_reassembled &&
      r19_terminal_window_open &&
      !r19_complete_vehicle_terminal_if_ready(now_ms)) {
    return;
  }
  if (r19_peer_receipt_producer_staged ||
      r19_peer_receipt_standard_tail_pending) {
    return;
  }
#endif
  if (runtime_fail_closed ||
      (r19_radio_session != nullptr &&
       r19_radio_session->pending_action())) {
    return;
  }
#if defined(VC_LORA_PHASE6_GROUND)
  if (r19_session_owners_constructed &&
      (r19_ground_usb_commit_active ||
       ground_paced_heartbeat_commit_active ||
       ground_parameter_publish_commit_active ||
       !ground_usb_ordered_backlog.empty() ||
       ground_usb_heartbeat_pacer.queued() != 0U ||
       radio_application_endpoint.egress().write_pending() ||
       radio_application_endpoint.egress().queued_bytes() != 0U)) {
    return;
  }
#else
  if (r19_pixhawk_commit_active) {
    return;
  }
  if (r19_vehicle_adapter->bulk_tx_enabled() &&
      !r19_vehicle_bulk_semantic_complete &&
      r19_bulk_tx_lease != nullptr &&
      vehicle_scheduler.queued_bytes() != 0U &&
      (r19_radio_session == nullptr ||
       r19_radio_stream_purpose ==
           R19RadioStreamPurpose::VehicleBulkDownlink)) {
    if (r19_vehicle_bulk_radio_not_before_ms == 0U) {
      latch_runtime_fail_closed();
      return;
    }
    if (now_ms < r19_vehicle_bulk_radio_not_before_ms) {
      return;
    }
    const HighSpeedPhase6AdapterStatus staged =
        r19_vehicle_adapter->stage_next_bulk_fragment(
            *r19_bulk_tx_lease, now_ms);
    if (staged != HighSpeedPhase6AdapterStatus::ActionReady) {
      latch_runtime_fail_closed();
      return;
    }
  }
#endif
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS && defined(VC_LORA_PHASE6_GROUND)
  // Tick above keeps the original owner deadlines alive. The first VCBN
  // additionally needs a causally observed Vehicle physical-tail permit;
  // receiving a Grant alone does not prove that the peer writer drained.
  if (!r19_grant_reservation_negotiation_started &&
      !r19_grant_reservation.negotiation_allowed(now_ms)) return;
#endif
  const HighSpeedPhase6Output output =
#if defined(VC_LORA_PHASE6_GROUND)
      r19_ground_adapter->poll(now_ms);
#else
      r19_vehicle_adapter->poll(now_ms);
#endif
  switch (output.type) {
    case HighSpeedPhase6OutputType::None:
      return;
    case HighSpeedPhase6OutputType::RadioWrite:
      if (!route_r19_high_speed_radio_output(output, now_ms)) {
        return;
      }
      r19_service_radio_session(now_ms);
      return;
    case HighSpeedPhase6OutputType::GroundUsbWrite:
#if defined(VC_LORA_PHASE6_GROUND)
      (void)r19_route_ground_usb_output(output, now_ms);
#else
      latch_runtime_fail_closed();
#endif
      return;
    case HighSpeedPhase6OutputType::PixhawkWrite:
#if defined(VC_LORA_PHASE6_VEHICLE)
      (void)r19_route_pixhawk_output(output, now_ms);
#else
      latch_runtime_fail_closed();
#endif
      return;
    case HighSpeedPhase6OutputType::OpenTerminalAckWindow:
#if defined(VC_LORA_PHASE6_VEHICLE)
      if (r19_terminal_reassembler == nullptr ||
          r19_vehicle_adapter->complete_output(
              output.token, TxResult::Accepted, now_ms) !=
              HighSpeedPhase6AdapterStatus::WindowOpened) {
        latch_runtime_fail_closed();
        return;
      }
      r19_terminal_window_open = true;
      (void)r19_complete_vehicle_terminal_if_ready(now_ms);
#else
      latch_runtime_fail_closed();
#endif
      return;
    default:
      latch_runtime_fail_closed();
      return;
  }
}
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

#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
// ISR records observed edges independently of the USB/main loop. Its timestamp
// is handler execution, not an oscilloscope-certified physical edge time.
void IRAM_ATTR r19_aux_readiness_irq(void*) noexcept {
  const auto now_us = static_cast<std::uint64_t>(esp_timer_get_time());
  const bool level = gpio_ll_get_level(GPIO_LL_GET_HW(GPIO_PORT_0),
      static_cast<std::uint32_t>(kE220AuxPin)) != 0;
  (void)vc_lora_r19_aux_readiness_record.edges.observe_edge(now_us, level);
}

void r19_attach_aux_readiness_irq() noexcept {
  const auto sampled_us = static_cast<std::uint64_t>(esp_timer_get_time());
  const bool initial_level = digitalRead(kE220AuxPin) == HIGH;
  const bool initialized = vc_lora_r19_aux_readiness_record.edges.initialize(
      kR19RuntimeStageRole, kR19RuntimeDiagnosticGenerationFingerprint,
      r19_aux_readiness_boot_instance, sampled_us, initial_level);
  // Do not quietly borrow an existing ISR service with unknown IRAM flags.
  // An attachment error makes the edge evidence incomplete, not an E220 fault.
  esp_err_t install = initialized ? gpio_install_isr_service(ESP_INTR_FLAG_IRAM)
                                 : ESP_ERR_INVALID_STATE;
  esp_err_t type = ESP_ERR_INVALID_STATE;
  esp_err_t add = ESP_ERR_INVALID_STATE;
  esp_err_t enable = ESP_ERR_INVALID_STATE;
  if (install == ESP_OK) {
    type = gpio_set_intr_type(static_cast<gpio_num_t>(kE220AuxPin),
        GPIO_INTR_ANYEDGE);
    if (type == ESP_OK) {
      add = gpio_isr_handler_add(static_cast<gpio_num_t>(kE220AuxPin),
          r19_aux_readiness_irq, nullptr);
      if (add == ESP_OK)
        enable = gpio_intr_enable(static_cast<gpio_num_t>(kE220AuxPin));
    }
  }
  (void)vc_lora_r19_aux_readiness_record.ready.event(
      R19UsbReadinessEvent::IrqAttach,
      static_cast<std::uint64_t>(esp_timer_get_time()),
      static_cast<std::uint32_t>(install), static_cast<std::uint32_t>(type),
      static_cast<std::uint32_t>(add), static_cast<std::uint32_t>(enable));
}

void r19_note_e220_aux_state(E220WriteState before) noexcept {
  const auto now_us = static_cast<std::uint64_t>(esp_timer_get_time());
  const auto after = e220_write_contract.state();
  if (before != after)
    (void)vc_lora_r19_aux_readiness_record.aux.observe_state(now_us,
        static_cast<std::uint32_t>(before), static_cast<std::uint32_t>(after),
        static_cast<std::uint32_t>(e220_write_contract.fault()));
  if (e220_write_contract.fail_closed())
    (void)vc_lora_r19_aux_readiness_record.aux.latch_fault(now_us,
        static_cast<std::uint32_t>(e220_write_contract.fault()),
        static_cast<std::uint32_t>(after));
}

void r19_note_e220_uart_acceptance(std::uint64_t begin_us,
    std::size_t requested, std::size_t written) noexcept {
  (void)vc_lora_r19_aux_readiness_record.aux.observe_uart(begin_us,
      static_cast<std::uint64_t>(esp_timer_get_time()),
      static_cast<std::uint32_t>(requested), static_cast<std::uint32_t>(written),
      static_cast<std::uint32_t>(e220_write_contract.state()));
}
#endif

// Only E220WriteContract samples enter the polling cadence record. Other
// incidental/startup reads must not make a starved contract observer look fast.
bool aux_high(std::uint64_t supplied_now_ms) noexcept {
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  const auto begin_us = static_cast<std::uint64_t>(esp_timer_get_time());
  const bool level = digitalRead(kE220AuxPin) == HIGH;
  const auto end_us = static_cast<std::uint64_t>(esp_timer_get_time());
  (void)vc_lora_r19_aux_readiness_record.aux.observe_gpio(begin_us, end_us,
      supplied_now_ms, level,
      static_cast<std::uint32_t>(e220_write_contract.state()));
  return level;
#else
  (void)supplied_now_ms;
  return digitalRead(kE220AuxPin) == HIGH;
#endif
}

bool aux_high() noexcept { return digitalRead(kE220AuxPin) == HIGH; }

void r19_observe_e220_aux(std::uint64_t now_ms) noexcept {
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  const auto before = e220_write_contract.state();
#endif
  (void)e220_write_contract.observe_aux(aux_high(now_ms), now_ms);
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  r19_note_e220_aux_state(before);
#endif
}

#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
R19RuntimeFailStatusSnapshot r19_runtime_fail_status_snapshot() noexcept {
  const std::uint8_t radio_session_status =
      r19_radio_session == nullptr
          ? static_cast<std::uint8_t>(
                Phase6HighSpeedRadioSessionStatus::Idle)
          : static_cast<std::uint8_t>(r19_radio_session->last_status());
#if defined(VC_LORA_PHASE6_GROUND)
  const std::uint8_t tdd_state =
      static_cast<std::uint8_t>(tdd_controller.state());
  const std::uint32_t usb_loss_epoch = ground_usb_observed_loss_epoch;
#else
  const std::uint8_t tdd_state =
      static_cast<std::uint8_t>(tdd_controller.state());
  const std::uint32_t usb_loss_epoch = Serial.txLossEpoch();
#endif
  return {
      static_cast<std::uint8_t>(startup_contract.fault()),
      static_cast<std::uint8_t>(e220_write_contract.state()),
      static_cast<std::uint8_t>(e220_write_contract.fault()),
      static_cast<std::uint8_t>(e220_writer_arbiter.last_status()),
      radio_session_status,
      r19_adapter_fail_closed(),
      tdd_state,
      usb_loss_epoch,
  };
}

void latch_runtime_fail_closed_at(std::uint16_t source_line) noexcept {
  (void)r19_runtime_fail_latch.latch(
#if defined(VC_LORA_PHASE6_GROUND)
      R19RuntimeFailRole::Ground,
#else
      R19RuntimeFailRole::Vehicle,
#endif
      source_line, monotonic_now_ms(), r19_runtime_fail_status_snapshot());
  runtime_fail_closed = true;
  bridge_ready = false;
}

void capture_r19_startup_contract_failure() noexcept {
  latch_runtime_fail_closed();
}
#else
void latch_runtime_fail_closed() noexcept {
  runtime_fail_closed = true;
  bridge_ready = false;
}
#endif

#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
void clear_standard_radio_writer_lease() noexcept {
  standard_radio_writer_lease = {};
  standard_radio_writer_action_type = LinkActionType::None;
  standard_radio_writer_control = {};
  standard_radio_writer_tail_pending = false;
}

bool acquire_standard_radio_writer_lease(
    const LinkAction& action) noexcept {
  if (standard_radio_writer_lease.valid() ||
      standard_radio_writer_tail_pending ||
      e220_writer_arbiter.write_active()) {
    latch_runtime_fail_closed();
    return false;
  }
  Phase6RadioWriterLease lease{};
  const Phase6RadioWriterStatus status = e220_writer_arbiter.request(
      Phase6RadioWriterOwner::StandardTdd, action.token, lease);
  if (status != Phase6RadioWriterStatus::LeaseGranted || !lease.valid()) {
    latch_runtime_fail_closed();
    return false;
  }
  standard_radio_writer_lease = lease;
  standard_radio_writer_action_type = action.type;
  standard_radio_writer_control = action.control;
  return true;
}

bool release_rejected_standard_radio_writer_lease(
    std::uint64_t now_ms) noexcept {
  if (!standard_radio_writer_lease.valid() ||
      standard_radio_writer_tail_pending) {
    latch_runtime_fail_closed();
    return false;
  }
  const Phase6RadioWriterStatus status = e220_writer_arbiter.complete_uart(
      standard_radio_writer_lease,
      Phase6RadioWriterUartResult::Rejected, now_ms);
  if (status != Phase6RadioWriterStatus::RejectedReleased) {
    latch_runtime_fail_closed();
    return false;
  }
  clear_standard_radio_writer_lease();
  return true;
}

bool retain_accepted_standard_radio_writer_lease(
    std::uint64_t now_ms) noexcept {
  if (!standard_radio_writer_lease.valid() ||
      standard_radio_writer_tail_pending) {
    latch_runtime_fail_closed();
    return false;
  }
  const Phase6RadioWriterStatus status = e220_writer_arbiter.complete_uart(
      standard_radio_writer_lease,
      Phase6RadioWriterUartResult::Accepted, now_ms);
  if (status != Phase6RadioWriterStatus::AcceptedAwaitingTail) {
    latch_runtime_fail_closed();
    return false;
  }
  standard_radio_writer_tail_pending = true;
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS && defined(VC_LORA_PHASE6_VEHICLE)
  if (r19_reserved_grant_releasing &&
      standard_radio_writer_action_type == LinkActionType::SendGrant) {
    r19_grant_reservation.on_grant_write_accepted(
        standard_radio_writer_control.session_id,
        standard_radio_writer_control.cycle_id,
        standard_radio_writer_lease.action_token,
        standard_radio_writer_lease.writer_generation, now_ms);
    r19_note_grant_reservation();
    if (r19_grant_reservation.failed()) {
      latch_runtime_fail_closed();
      return false;
    }
    r19_reserved_grant_uart_accepted = true;
  }
#endif
#if VC_LORA_R19_GRANT_DIAGNOSTICS && defined(VC_LORA_PHASE6_VEHICLE)
  if (standard_radio_writer_action_type == LinkActionType::SendGrant) {
    (void)vc_lora_r19_grant_diagnostic_record.observe_grant_event(
        experimental::R19GrantDiagnosticEvent::GrantWriteAccepted, now_ms,
        standard_radio_writer_control.session_id,
        standard_radio_writer_control.cycle_id,
        standard_radio_writer_lease.action_token,
        standard_radio_writer_lease.writer_generation, __LINE__);
  }
#endif
  return true;
}

bool observe_r19_radio_writer_physical_tail(
    const Phase6RadioTailEvidence& evidence,
    std::uint64_t now_ms) noexcept {
  const Phase6RadioWriterStatus status =
      e220_writer_arbiter.observe_physical_tail(evidence, now_ms);
  if (status != Phase6RadioWriterStatus::TailReleased) {
    latch_runtime_fail_closed();
    return false;
  }
  return true;
}

bool complete_standard_radio_writer_physical_tail(
    std::uint64_t now_ms) noexcept {
  if (!standard_radio_writer_lease.valid() ||
      !standard_radio_writer_tail_pending) {
    latch_runtime_fail_closed();
    return false;
  }
  const Phase6RadioTailEvidence evidence{
      standard_radio_writer_lease, true, now_ms};
  if (!observe_r19_radio_writer_physical_tail(evidence, now_ms)) {
    return false;
  }
#if defined(VC_LORA_PHASE6_VEHICLE)
  if (standard_radio_writer_action_type ==
      LinkActionType::SendGrant) {
    if (standard_radio_writer_control.type != ControlType::UlGrant) {
      latch_runtime_fail_closed();
      return false;
    }
    retained_standard_vehicle_grant_tail = {
        evidence, standard_radio_writer_control, true};
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
    if (r19_reserved_grant_uart_accepted) {
      r19_grant_reservation.on_tail(standard_radio_writer_control.session_id,
          standard_radio_writer_control.cycle_id, evidence.lease.action_token,
          evidence.lease.writer_generation, now_ms);
      r19_note_grant_reservation();
      if (r19_grant_reservation.failed()) {
        latch_runtime_fail_closed();
        return false;
      }
      r19_reserved_grant_uart_accepted = false;
    }
#endif
#if VC_LORA_R19_GRANT_DIAGNOSTICS
    (void)vc_lora_r19_grant_diagnostic_record.observe_grant_event(
        experimental::R19GrantDiagnosticEvent::GrantPhysicalTail, now_ms,
        standard_radio_writer_control.session_id,
        standard_radio_writer_control.cycle_id,
        evidence.lease.action_token, evidence.lease.writer_generation, __LINE__);
#endif
  }
#endif
  clear_standard_radio_writer_lease();
  return true;
}

void r19_service_peer_receipt_producer(
    std::uint64_t now_ms) noexcept {
  if (!r19_peer_receipt_producer_staged ||
      r19_peer_receipt_standard_tail_pending || runtime_fail_closed) {
    return;
  }
  if (now_ms < r19_peer_receipt_send_not_before_ms) {
    return;
  }
  if (now_ms > r19_peer_receipt_send_deadline_ms) {
    latch_runtime_fail_closed();
    return;
  }
  r19_observe_e220_aux(now_ms);
  if (e220_write_contract.fail_closed()) {
    latch_runtime_fail_closed();
    return;
  }
  if (radio_busy || pending_radio_action.active ||
      e220_writer_arbiter.write_active() ||
      !e220_write_contract.ready_for_write() ||
      e220_serial.availableForWrite() <
          static_cast<int>(PeerCompletionReceiptFrame{}.size())) {
    return;
  }
  std::uint32_t now32 = 0U;
  PeerCompletionReceiptWrite write{};
  if (!r19_now32(now_ms, now32) ||
      r19_peer_receipt_producer.poll(now32, write) !=
          PeerCompletionReceiptProducerStatus::WriteReady ||
      !write.valid()) {
    latch_runtime_fail_closed();
    return;
  }
  LinkAction receipt_action{};
  receipt_action.type = LinkActionType::None;
  receipt_action.token = write.action_token;
  receipt_action.byte_budget = static_cast<std::uint16_t>(write.size);
  if (!acquire_standard_radio_writer_lease(receipt_action)) {
    return;
  }
  if (!e220_write_contract.begin_write(write.size)) {
    if (r19_peer_receipt_producer.complete_write(
            write.action_token, write.writer_generation,
            PeerCompletionReceiptWriteDisposition::Rejected, 0U,
            now32) != PeerCompletionReceiptProducerStatus::RetryRetained ||
        !release_rejected_standard_radio_writer_lease(now_ms)) {
      latch_runtime_fail_closed();
    }
    return;
  }
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  const auto write_begin_us = static_cast<std::uint64_t>(esp_timer_get_time());
#endif
  const std::size_t written =
      e220_serial.write(write.bytes.data(), write.size);
  const std::uint64_t accepted_at_ms = monotonic_now_ms();
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  r19_note_e220_uart_acceptance(write_begin_us, write.size, written);
  const auto before_write_result = e220_write_contract.state();
#endif
  std::uint32_t accepted_at32 = 0U;
  const E220WriteDisposition disposition =
      e220_write_contract.report_write_result(
          written, accepted_at_ms, aux_high(accepted_at_ms));
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  r19_note_e220_aux_state(before_write_result);
#endif
  if (!r19_now32(accepted_at_ms, accepted_at32)) {
    return;
  }
  if (disposition == E220WriteDisposition::Rejected && written == 0U) {
    if (r19_peer_receipt_producer.complete_write(
            write.action_token, write.writer_generation,
            PeerCompletionReceiptWriteDisposition::Rejected, 0U,
            accepted_at32) !=
            PeerCompletionReceiptProducerStatus::RetryRetained ||
        !release_rejected_standard_radio_writer_lease(accepted_at_ms)) {
      latch_runtime_fail_closed();
    }
    return;
  }
  if (disposition != E220WriteDisposition::AcceptedAll ||
      written != write.size ||
      r19_peer_receipt_producer.complete_write(
          write.action_token, write.writer_generation,
          PeerCompletionReceiptWriteDisposition::Accepted, written,
          accepted_at32) != PeerCompletionReceiptProducerStatus::Committed ||
      !retain_accepted_standard_radio_writer_lease(accepted_at_ms)) {
    latch_runtime_fail_closed();
    return;
  }
  radio_busy = true;
  r19_peer_receipt_standard_tail_pending = true;
}

void r19_finish_candidate_if_ready(std::uint64_t now_ms) noexcept {
  if (!r19_product_route_selected || !r19_standard_tdd_frozen ||
      runtime_fail_closed || r19_standard_resume_not_before_ms == 0U ||
      now_ms < r19_standard_resume_not_before_ms) {
    return;
  }
#if defined(VC_LORA_PHASE6_GROUND)
  const bool role_complete =
      r19_ground_adapter != nullptr && r19_ground_adapter->complete() &&
      r19_peer_receipt_proof_delivered &&
      r19_peer_receipt_ledger_kind ==
          PeerCompletionReceiptKind::TerminalRecordConsumed;
#else
  const bool role_complete =
      r19_vehicle_adapter != nullptr && r19_vehicle_adapter->complete() &&
      r19_peer_receipt_producer.committed() &&
      r19_peer_receipt_producer_kind ==
          PeerCompletionReceiptKind::TerminalRecordConsumed;
#endif
  if (!role_complete || r19_radio_session != nullptr || radio_busy ||
      pending_radio_action.active || r19_peer_receipt_producer_staged ||
      r19_peer_receipt_standard_tail_pending ||
      !e220_writer_arbiter.can_poll_standard()) {
    return;
  }
  if (!radio_demux.set_bulk_data_route_mode(BulkDataRouteMode::Disabled)) {
    latch_runtime_fail_closed();
    return;
  }
  r19_standard_tdd_frozen = false;
  r19_product_route_selected = false;
  r19_standard_resume_not_before_ms = 0U;
  r19_acceleration_consumed = true;
}

bool activate_r19_high_speed_candidate() noexcept {
  if (r19_acceleration_consumed) {
    return false;
  }
  if (runtime_fail_closed || !bridge_ready) {
    return false;
  }
  const Phase6RadioWriterStatus status =
      e220_writer_arbiter.activate_high_speed();
  if (status != Phase6RadioWriterStatus::HighSpeedActivated) {
    latch_runtime_fail_closed();
    return false;
  }
  return true;
}

bool complete_r19_high_speed_candidate() noexcept {
  const Phase6RadioWriterStatus status =
      e220_writer_arbiter.complete_high_speed();
  if (status != Phase6RadioWriterStatus::ExplicitRestoreRequired) {
    latch_runtime_fail_closed();
    return false;
  }
  return true;
}

bool restore_standard_tdd_after_r19_candidate(
    bool clean_session_confirmed) noexcept {
  const Phase6RadioWriterStatus status =
      e220_writer_arbiter.restore_standard(clean_session_confirmed);
  if (!clean_session_confirmed) {
    if (status == Phase6RadioWriterStatus::ExplicitRestoreRequired) {
      return false;
    }
    latch_runtime_fail_closed();
    return false;
  }
  if (status != Phase6RadioWriterStatus::StandardRestored) {
    latch_runtime_fail_closed();
    return false;
  }
  return true;
}

bool r19_standard_tdd_tick_allowed() noexcept {
  if (e220_writer_arbiter.fail_closed() ||
      e220_writer_arbiter.last_status() ==
          Phase6RadioWriterStatus::FailClosed) {
    latch_runtime_fail_closed();
    return false;
  }
  return !r19_standard_tdd_frozen &&
         !e220_writer_arbiter.high_speed_active() &&
         !e220_writer_arbiter.explicit_restore_required();
}

const R19StandardVehicleGrantTailEvidence&
r19_retained_standard_vehicle_grant_tail() noexcept {
  return retained_standard_vehicle_grant_tail;
}
#endif

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

bool ground_usb_can_accept_downlink() noexcept {
  return ground_usb_host_present_state;
}

void update_ground_usb_connection(std::uint64_t now_ms) noexcept;
void retire_ground_usb_publication_commits(std::uint64_t now_ms) noexcept;
bool discard_ground_ordered_backlog(std::uint64_t now_ms) noexcept;
bool discard_ground_held_heartbeats(std::uint64_t now_ms) noexcept;
void observe_candidate_ground_usb_output_commit(
    std::uint64_t now_ms) noexcept;

void discard_ground_usb_rx_bytes() noexcept {
  // BUS_RESET is a receive-stream boundary as well as a TX-loss epoch. Drain
  // bytes retained by HWCDC before resetting the MAVLink parser so a prefix
  // from the old USB session cannot join a suffix from the new session.
  while (Serial.available() > 0) {
    (void)Serial.read();
  }
}

// A USB reset invalidates the byte-stream boundary. It is recoverable only
// when every byte accepted by HWCDC was covered by a successful physical
// publication fence and no commit or LocalEgress byte remains. Any uncertain
// byte preserves the permanent fail-closed behavior.
bool ground_usb_transport_epoch_healthy(
    std::uint64_t now_ms) noexcept {
  const std::uint32_t observed = Serial.txLossEpoch();
#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
  if (r19_ground_usb_commit_active &&
      observed != ground_usb_observed_loss_epoch) {
    ground_usb_observed_loss_epoch = observed;
    latch_runtime_fail_closed();
    return false;
  }
#endif
  const auto& egress = radio_application_endpoint.egress();
  const GroundUsbTransportEpochSnapshot snapshot{
      ground_usb_observed_loss_epoch,
      observed,
      egress.stats().bytes_committed,
      ground_usb_transport_published_bytes,
      ground_paced_heartbeat_commit_active,
      ground_parameter_publish_commit_active,
      egress.write_pending(),
      egress.queued_bytes()};
  const GroundUsbTransportEpochDisposition disposition =
      assess_ground_usb_transport_epoch(snapshot);
  if (disposition == GroundUsbTransportEpochDisposition::Unchanged) {
    return true;
  }

  if (disposition !=
      GroundUsbTransportEpochDisposition::RecoverableBoundary) {
    retire_ground_usb_publication_commits(now_ms);
    ground_usb_observed_loss_epoch = observed;
    latch_runtime_fail_closed();
    return false;
  }

  discard_ground_usb_rx_bytes();
  const bool backlog_discarded = discard_ground_ordered_backlog(now_ms);
  const bool heartbeats_discarded = discard_ground_held_heartbeats(now_ms);
  ground_usb_parser = {};
  ground_usb_observed_loss_epoch = observed;
  if (!backlog_discarded || !heartbeats_discarded) {
    latch_runtime_fail_closed();
  }
  // End this loop at the recovered stream boundary. The next loop observes
  // the new baseline before accepting GCS bytes or publishing RF traffic.
  return false;
}

struct GroundUsbEpochCheckedWriter {
  int availableForWrite() noexcept { return Serial.availableForWrite(); }

  std::size_t write(const std::uint8_t* bytes,
                    std::size_t size) noexcept {
    return Serial.writeTxChecked(bytes, size,
                                 ground_usb_observed_loss_epoch);
  }
};

GroundUsbEpochCheckedWriter ground_usb_epoch_checked_writer{};

bool r19_product_usb_publication_allowed() noexcept {
#if VC_LORA_R19_USB_READINESS_MODE == 2
  const auto now_us = static_cast<std::uint64_t>(esp_timer_get_time());
  if (!r19_usb_readiness_initialized) {
    if (r19_usb_readiness_configured &&
        now_us >= r19_usb_readiness_acquisition_deadline_us)
      latch_runtime_fail_closed();
    return false;
  }
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  const auto before_gate_poll = r19_host_readiness_gate.snapshot().state;
#endif
  r19_host_readiness_gate.poll(Serial.txLossEpoch(),
      r19_usb_readiness_reader_session, now_us);
  const auto state = r19_host_readiness_gate.snapshot().state;
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  if (before_gate_poll != state)
    r19_note_usb_readiness_event(R19UsbReadinessEvent::GateUpdate,
        static_cast<std::uint32_t>(before_gate_poll),
        static_cast<std::uint32_t>(state), 0U, Serial.txLossEpoch());
#endif
#if VC_LORA_R19_TIMED_PATH_DIAGNOSTICS
  if (state == experimental::R19HostReadinessState::EpochAborted ||
      state == experimental::R19HostReadinessState::SessionAborted) {
    (void)vc_lora_r19_timed_path_record.latch_gate_abort(256U);
  } else if (state == experimental::R19HostReadinessState::ClockRegressed) {
    (void)vc_lora_r19_timed_path_record.latch_gate_abort(512U);
  }
#endif
  if (state == experimental::R19HostReadinessState::TimedOut ||
      state == experimental::R19HostReadinessState::EpochAborted ||
      state == experimental::R19HostReadinessState::SessionAborted ||
      state == experimental::R19HostReadinessState::ClockRegressed ||
      state == experimental::R19HostReadinessState::InvalidConfiguration) {
    latch_runtime_fail_closed();
    return false;
  }
  return r19_host_readiness_gate.allow_ground_usb_product_admission();
#else
  // Disabled and SyncOnly preserve the original product path byte-for-byte.
  return true;
#endif
}

void pump_ground_usb_egress(std::uint64_t now_ms) noexcept {
  if (!r19_product_usb_publication_allowed()) return;
  // A preceding publication fence can block for up to 100 ms.  Never feed
  // that stale loop-entry timestamp into the 50-ms host-presence filter or a
  // short post-fence USB dip can be misclassified as a confirmed disconnect.
  const std::uint64_t observed_ms =
      std::max(now_ms, monotonic_now_ms());
  update_ground_usb_connection(observed_ms);
  if (!ground_usb_transport_epoch_healthy(observed_ms)) {
    return;
  }
  const LocalEgressPumpStatus status = pump_local_egress_if_connected(
      radio_application_endpoint.egress(), ground_usb_epoch_checked_writer,
      ground_usb_endpoint_ready_state);
  if (status == LocalEgressPumpStatus::Invalid) {
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

// A preceding PARAM_VALUE publication consumes at most the 100-ms allowance
// included in product_ground_usb_heartbeat_pacer_config(). Longer uncertainty
// is a fail-stop, never a late success which could violate the 2500-ms SLA.
constexpr std::uint64_t kGroundUsbParameterCommitDeadlineMs = 100U;
// Once admitted, a 21-byte paced heartbeat owns at most its configured 6-ms
// physical-write allowance plus the 100-ms host-publication fence. This is an
// absolute admission-to-publication deadline: a partial HWCDC write may not
// hold the pacer/order barrier indefinitely under host backpressure.
constexpr std::uint64_t kGroundUsbHeartbeatCommitDeadlineMs = 106U;
static_assert(
    kGroundUsbHeartbeatCommitDeadlineMs ==
        static_cast<std::uint64_t>(
            product_ground_usb_heartbeat_pacer_config()
                .physical_write_budget_ms) +
            static_cast<std::uint64_t>(
                product_ground_usb_heartbeat_pacer_config()
                    .transport_flush_budget_ms),
    "Heartbeat commit deadline must match the pacer completion budget");

bool ground_parameter_requires_publish_commit(
    const MavlinkFrame& frame) noexcept {
  return frame.message_id == 22U && ground_parameter_proxy.active();
}

void clear_ground_parameter_publish_commit() noexcept {
  ground_parameter_publish_commit_active = false;
  ground_parameter_publish_commit_frame = {};
  ground_parameter_publish_commit_goal = 0U;
  ground_parameter_publish_commit_deadline_ms = 0U;
  ground_parameter_publish_commit_loss_epoch = 0U;
}

bool begin_ground_parameter_publish_commit(
    const MavlinkFrame& frame, std::uint64_t now_ms) noexcept {
  if (ground_parameter_publish_commit_active ||
      !ground_parameter_requires_publish_commit(frame)) {
    return false;
  }
  const auto& egress = radio_application_endpoint.egress();
  const std::uint64_t committed = egress.stats().bytes_committed;
  const std::uint64_t queued =
      static_cast<std::uint64_t>(egress.queued_bytes());
  const std::uint64_t maximum =
      std::numeric_limits<std::uint64_t>::max();
  if (committed > maximum - queued) {
    return false;
  }

  ground_parameter_publish_commit_active = true;
  ground_parameter_publish_commit_frame = frame;
  ground_parameter_publish_commit_goal = committed + queued;
  ground_parameter_publish_commit_deadline_ms =
      now_ms > maximum - kGroundUsbParameterCommitDeadlineMs
          ? maximum
          : now_ms + kGroundUsbParameterCommitDeadlineMs;
  ground_parameter_publish_commit_loss_epoch = Serial.txLossEpoch();
  return true;
}

void reject_ground_parameter_publish_commit(
    std::uint64_t now_ms) noexcept {
  if (!ground_parameter_publish_commit_active) {
    return;
  }
  const MavlinkFrame rejected = ground_parameter_publish_commit_frame;
  clear_ground_parameter_publish_commit();
  (void)ground_parameter_proxy.on_vehicle_frame(rejected, false, now_ms);
  ++link_diagnostics.uart_buffer_drop_count;
}

void note_ground_usb_admission(const MavlinkFrame& frame,
                               ValidatedLocalIngressStatus status,
                               std::uint64_t now_ms) noexcept {
  const bool usb_queued =
      status == ValidatedLocalIngressStatus::QueuedFrame;
  const bool defer_parameter_commit =
      usb_queued && ground_parameter_requires_publish_commit(frame);
  if (defer_parameter_commit) {
    if (!begin_ground_parameter_publish_commit(frame, now_ms)) {
      (void)ground_parameter_proxy.on_vehicle_frame(frame, false, now_ms);
      ++link_diagnostics.uart_buffer_drop_count;
      latch_runtime_fail_closed();
    }
  } else {
    (void)ground_parameter_proxy.on_vehicle_frame(frame, usb_queued, now_ms);
  }
  if (usb_queued) {
    ++link_diagnostics.mavlink_frames_forwarded;
  } else if (status == ValidatedLocalIngressStatus::DroppedOverflow) {
    ++link_diagnostics.uart_buffer_drop_count;
  } else if (status == ValidatedLocalIngressStatus::Invalid) {
    ++link_diagnostics.mavlink_crc_errors;
  } else if (status == ValidatedLocalIngressStatus::FailClosed ||
             radio_application_endpoint.fail_closed()) {
    latch_runtime_fail_closed();
  }
}

void reject_ground_usb_frame(const MavlinkFrame& frame,
                             std::uint64_t now_ms) noexcept {
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
      latch_runtime_fail_closed();
      return false;
    }
    if (!heartbeat_marker) {
      reject_ground_usb_frame(frame, now_ms);
    }
    if (!ground_usb_ordered_backlog.discard_front()) {
      ground_usb_ordered_backlog.discard_all();
      latch_runtime_fail_closed();
      return false;
    }
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

#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
R19GroundUsbCommitEvidence r19_ground_heartbeat_commit_evidence(
    R19GroundUsbCommitFailureReason reason, std::uint32_t source_line,
    std::uint64_t completed_ms, bool transport_observed = false,
    bool transport_published = false,
    std::uint64_t flush_started_ms = 0U) noexcept {
  R19GroundUsbCommitEvidence evidence{};
  evidence.reason = reason;
  evidence.predicate_observed_mask = transport_observed ? 7U : 6U;
  evidence.predicate_true_mask =
      (transport_observed && transport_published ? 1U : 0U) |
      (ground_usb_endpoint_ready_state ? 2U : 0U) |
      (completed_ms <= ground_paced_heartbeat_commit_deadline_ms ? 4U : 0U);
  evidence.source_line = source_line;
  evidence.token = ground_paced_heartbeat_commit_token;
  evidence.expected_epoch = ground_paced_heartbeat_commit_loss_epoch;
  evidence.observed_epoch = Serial.txLossEpoch();
  evidence.commit_started_ms = r19_ground_heartbeat_commit_started_ms;
  evidence.flush_started_ms = flush_started_ms;
  evidence.completed_ms = completed_ms;
  evidence.deadline_ms = ground_paced_heartbeat_commit_deadline_ms;
  evidence.committed_base = r19_ground_heartbeat_committed_base;
  evidence.commit_goal = ground_paced_heartbeat_commit_goal;
  evidence.bytes_committed =
      radio_application_endpoint.egress().stats().bytes_committed;
  evidence.expected_frame_bytes = r19_ground_heartbeat_expected_frame_bytes;
  const std::uint64_t accepted_bytes =
      evidence.bytes_committed > evidence.committed_base
          ? evidence.bytes_committed - evidence.committed_base : 0U;
  evidence.accepted_frame_bytes = static_cast<std::uint32_t>(
      std::min(accepted_bytes,
               static_cast<std::uint64_t>(evidence.expected_frame_bytes)));
  return evidence;
}

experimental::R19FirstUsbFailureEvidence r19_product_failure_evidence(
    std::uint32_t reason, std::uint32_t source_line,
    std::uint64_t completed_ms) noexcept {
  const auto old = r19_ground_heartbeat_commit_evidence(
      R19GroundUsbCommitFailureReason::PublicationRejected, source_line,
      completed_ms);
  experimental::R19FirstUsbFailureEvidence evidence{};
  evidence.reason = reason;
  evidence.source_line = source_line;
  evidence.token = old.token;
  evidence.attempt_id = r19_product_flush_api_called
      ? r19_product_flush_call.attempt_id : 0U;
  evidence.budget_ms = r19_product_flush_budget_ms;
  evidence.expected_epoch = old.expected_epoch;
  evidence.observed_epoch = old.observed_epoch;
  evidence.started_us = r19_product_flush_api_called
      ? r19_product_flush_started_us : old.commit_started_ms * 1000U;
  evidence.finished_us = r19_product_flush_api_called
      ? r19_product_flush_finished_us : completed_ms * 1000U;
  evidence.deadline_us = old.deadline_ms * 1000U;
  evidence.expected_frame_bytes = old.expected_frame_bytes;
  evidence.accepted_frame_bytes = old.accepted_frame_bytes;
  evidence.wrapper_flags =
      (r19_product_flush_api_called ? 1U : 0U) |
      (r19_product_flush_api_called && r19_product_flush_call.raw_return != 0U ? 2U : 0U) |
      (ground_usb_endpoint_ready_state ? 4U : 0U) |
      (completed_ms <= old.deadline_ms ? 8U : 0U);
  evidence.sdk = r19_product_flush_call;
  return evidence;
}

void r19_latch_product_failure(
    experimental::R19FirstUsbFailureEvidence evidence) noexcept {
  const auto sample = static_cast<std::uint64_t>(esp_timer_get_time());
  evidence.failure_observed_us = sample;
  (void)vc_lora_r19_first_usb_failure_record.latch_first_failure(evidence);
#if VC_LORA_R19_TIMED_PATH_DIAGNOSTICS
  (void)vc_lora_r19_timed_path_record.latch_accepted(
      evidence.token, evidence.accepted_frame_bytes, sample);
  if (r19_product_flush_api_called) {
    (void)vc_lora_r19_timed_path_record.latch_sdk_observation(
        evidence.token, evidence.sdk, sample);
  }
  // The pre-API failure's old ms timestamp is rounded down. Do not pretend it
  // is a microsecond-precise enqueue time: use the separately observed first
  // enqueue and the actual failure-decision sample. Called APIs retain their
  // real esp_timer start/return observations without changing the old record.
  experimental::R19TimedPathSnapshot trace{};
  if (vc_lora_r19_timed_path_record.try_snapshot(trace)) {
    (void)vc_lora_r19_timed_path_record.latch_failure(evidence.token,
        evidence.reason, evidence.observed_epoch,
        r19_product_flush_api_called ? evidence.started_us : trace.enqueue_us,
        r19_product_flush_api_called ? evidence.finished_us : sample, sample);
  }
#endif
}

#if VC_LORA_R19_TIMED_PATH_DIAGNOSTICS
void r19_latch_product_completion(std::uint32_t token,
    std::uint32_t expected_epoch) noexcept {
  const auto sample = static_cast<std::uint64_t>(esp_timer_get_time());
  (void)vc_lora_r19_timed_path_record.latch_accepted(
      token, r19_ground_heartbeat_expected_frame_bytes, sample);
  (void)vc_lora_r19_timed_path_record.latch_sdk_observation(
      token, r19_product_flush_call, sample);
  (void)vc_lora_r19_timed_path_record.latch_completed(
      token, expected_epoch, sample);
}
#endif
#endif

void reject_ground_paced_heartbeat_commit(
    std::uint64_t now_ms) noexcept {
  if (!ground_paced_heartbeat_commit_active) {
    return;
  }
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  r19_latch_product_failure(r19_product_failure_evidence(4U, __LINE__, now_ms));
  (void)vc_lora_r19_ground_usb_commit_record.latch_first_failure(
      r19_ground_heartbeat_commit_evidence(
          R19GroundUsbCommitFailureReason::Retired, __LINE__, now_ms,
          r19_ground_heartbeat_flush_result_observed,
          r19_ground_heartbeat_transport_published,
          r19_ground_heartbeat_flush_result_observed
              ? r19_ground_usb_last_flush_started_ms : 0U));
#endif
  const std::uint32_t token = ground_paced_heartbeat_commit_token;
  ground_paced_heartbeat_commit_active = false;
  ground_paced_heartbeat_commit_token = 0U;
  ground_paced_heartbeat_commit_goal = 0U;
  ground_paced_heartbeat_commit_deadline_ms = 0U;
  ground_paced_heartbeat_commit_loss_epoch = 0U;
  if (!ground_usb_heartbeat_pacer.complete_emit(
          token, TxResult::Rejected, now_ms)) {
    latch_runtime_fail_closed();
  }
}

void retire_ground_usb_publication_commits(
    std::uint64_t now_ms) noexcept {
  reject_ground_parameter_publish_commit(now_ms);
  reject_ground_paced_heartbeat_commit(now_ms);
}

bool ground_usb_runtime_healthy_or_retire(
    std::uint64_t now_ms) noexcept {
  const std::uint64_t observed_ms =
      std::max(now_ms, monotonic_now_ms());
  if (bridge_ready && !runtime_fail_closed &&
      ground_usb_transport_epoch_healthy(observed_ms)) {
    return true;
  }
  retire_ground_usb_publication_commits(observed_ms);
  return false;
}

void update_ground_usb_connection(std::uint64_t now_ms) noexcept {
  const bool raw_host_present = ground_usb_host_present_now();
  const bool endpoint_ready =
      ground_usb_endpoint_ready_now(raw_host_present);
  ground_usb_endpoint_ready_state = endpoint_ready;
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
  // retracted on a mid-disconnect; retire either physical-publication commit
  // without reporting it as successful and stop the bridge fail-safe.
  const auto& egress = radio_application_endpoint.egress();
  const bool had_irreversible_usb_bytes =
      ground_paced_heartbeat_commit_active ||
      ground_parameter_publish_commit_active ||
#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
      r19_ground_usb_commit_active ||
#endif
      egress.write_pending() || egress.queued_bytes() != 0U ||
      egress.stats().bytes_committed !=
          ground_usb_transport_published_bytes;
  retire_ground_usb_publication_commits(now_ms);
  if (had_irreversible_usb_bytes) {
    latch_runtime_fail_closed();
  }
  (void)discard_ground_ordered_backlog(now_ms);
  if (!discard_ground_held_heartbeats(now_ms)) {
    latch_runtime_fail_closed();
  }
  discard_ground_usb_rx_bytes();
  ground_usb_parser = {};
}

// Append one leased real heartbeat to the same byte FIFO used by every other
// Ground USB frame. The cumulative completion goal is frozen before any later
// frame is admitted, so later queue growth cannot acknowledge this HB early.
bool admit_ground_paced_heartbeat(
    const GroundUsbHeartbeatLease& lease,
    std::uint64_t now_ms) noexcept {
  if (!r19_product_usb_publication_allowed()) {
    // This lease is still retractable: no product byte entered LocalEgress.
    (void)ground_usb_heartbeat_pacer.complete_emit(
        lease.token, TxResult::Rejected, now_ms);
    return false;
  }
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
      latch_runtime_fail_closed();
    }
    return false;
  }

  // From this point the byte-only FIFO cannot retract the frame. Failure to
  // transfer ownership to the pacer is therefore an internal fail-stop fault.
  if (!ground_usb_heartbeat_pacer.mark_emit_admitted(lease.token)) {
    latch_runtime_fail_closed();
    return false;
  }
  ground_paced_heartbeat_commit_active = true;
  ground_paced_heartbeat_commit_token = lease.token;
  ground_paced_heartbeat_commit_goal =
      committed_before + static_cast<std::uint64_t>(queued_before) +
      static_cast<std::uint64_t>(lease.frame.size);
  const std::uint64_t maximum =
      std::numeric_limits<std::uint64_t>::max();
  ground_paced_heartbeat_commit_deadline_ms =
      now_ms > maximum - kGroundUsbHeartbeatCommitDeadlineMs
          ? maximum
          : now_ms + kGroundUsbHeartbeatCommitDeadlineMs;
  ground_paced_heartbeat_commit_loss_epoch = Serial.txLossEpoch();
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  r19_ground_heartbeat_commit_started_ms = now_ms;
  r19_ground_heartbeat_committed_base =
      committed_before + static_cast<std::uint64_t>(queued_before);
  r19_ground_heartbeat_expected_frame_bytes =
      static_cast<std::uint32_t>(lease.frame.size);
  r19_ground_heartbeat_flush_result_observed = false;
  r19_ground_heartbeat_transport_published = false;
  r19_product_flush_call = {};
  r19_product_flush_api_called = false;
  r19_product_flush_budget_ms = 0U;
  r19_product_flush_started_us = 0U;
  r19_product_flush_finished_us = 0U;
#if VC_LORA_R19_TIMED_PATH_DIAGNOSTICS
  (void)vc_lora_r19_timed_path_record.latch_enqueue(lease.frame, lease.token,
      ground_paced_heartbeat_commit_loss_epoch,
      static_cast<std::uint64_t>(esp_timer_get_time()),
      ground_paced_heartbeat_commit_deadline_ms * 1000U);
#endif
#endif
  ++link_diagnostics.mavlink_frames_forwarded;
  return true;
}

constexpr std::uint64_t kGroundUsbTransportFlushBudgetMs = 100U;

// HWCDC write acceptance only moves bytes into its private ring. The pinned
// core extension proves ring+stash drain, an unchanged loss epoch, final FIFO
// host pickup, and the terminating short/ZLP boundary without discarding on
// timeout. A void Serial.flush() is deliberately forbidden here.
bool flush_ground_usb_transport(
    std::uint32_t expected_loss_epoch, std::uint32_t budget_ms,
    std::uint64_t& flush_completed_ms) noexcept {
  const std::uint64_t flush_started_ms = monotonic_now_ms();
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  r19_ground_usb_last_flush_started_ms = flush_started_ms;
#endif
  const bool transport_published =
      budget_ms != 0U &&
      Serial.flushTxComplete(budget_ms, expected_loss_epoch);
  flush_completed_ms = monotonic_now_ms();
  return transport_published &&
         flush_completed_ms - flush_started_ms <=
             static_cast<std::uint64_t>(budget_ms);
}

#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
bool flush_ground_product_usb_with_evidence(
    std::uint32_t expected_epoch, std::uint32_t budget_ms,
    std::uint64_t& completed_ms) noexcept {
  r19_product_flush_started_us =
      static_cast<std::uint64_t>(esp_timer_get_time());
  r19_ground_usb_last_flush_started_ms = r19_product_flush_started_us / 1000U;
  r19_product_flush_budget_ms = budget_ms;
  r19_product_flush_call = {};
  r19_product_flush_call.transaction_token = ground_paced_heartbeat_commit_token;
  if (r19_product_flush_attempt != std::numeric_limits<std::uint32_t>::max())
    ++r19_product_flush_attempt;
  r19_product_flush_call.attempt_id = r19_product_flush_attempt;
  r19_product_flush_api_called = budget_ms != 0U;
  const bool raw = budget_ms != 0U && Serial.flushTxCompleteDiagnostic(
      budget_ms, expected_epoch, r19_product_flush_call);
  r19_product_flush_finished_us =
      static_cast<std::uint64_t>(esp_timer_get_time());
  completed_ms = r19_product_flush_finished_us / 1000U;
  return raw && completed_ms - r19_ground_usb_last_flush_started_ms <= budget_ms;
}
#endif

void observe_ground_paced_heartbeat_commit(
    std::uint64_t now_ms) noexcept {
  if (!ground_paced_heartbeat_commit_active) {
    return;
  }
  const std::uint64_t observed_ms =
      std::max(now_ms, monotonic_now_ms());
  update_ground_usb_connection(observed_ms);
  if (!ground_paced_heartbeat_commit_active) {
    return;
  }
  if (!ground_usb_transport_epoch_healthy(observed_ms)) {
    return;
  }
  if (observed_ms >= ground_paced_heartbeat_commit_deadline_ms) {
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    r19_latch_product_failure(r19_product_failure_evidence(2U, __LINE__, observed_ms));
    (void)vc_lora_r19_ground_usb_commit_record.latch_first_failure(
        r19_ground_heartbeat_commit_evidence(
            R19GroundUsbCommitFailureReason::BeforeFlushDeadline,
            __LINE__, observed_ms));
#endif
    reject_ground_paced_heartbeat_commit(observed_ms);
    latch_runtime_fail_closed();
    return;
  }
  if (!ground_usb_endpoint_ready_state) {
    return;
  }
  if (radio_application_endpoint.egress().stats().bytes_committed <
      ground_paced_heartbeat_commit_goal) {
    return;
  }
  const std::uint64_t remaining_ms =
      ground_paced_heartbeat_commit_deadline_ms - observed_ms;
  std::uint64_t flush_completed_ms = observed_ms;
  const bool transport_published =
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
      flush_ground_product_usb_with_evidence(
#else
      flush_ground_usb_transport(
#endif
          ground_paced_heartbeat_commit_loss_epoch,
          static_cast<std::uint32_t>(remaining_ms),
          flush_completed_ms);
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  // Connection refresh can retire this commit. Preserve its already-known
  // flush result before that path freezes the first-failure record.
  r19_ground_heartbeat_flush_result_observed = true;
  r19_ground_heartbeat_transport_published = transport_published;
#endif
  update_ground_usb_connection(flush_completed_ms);
  if (!ground_paced_heartbeat_commit_active) {
    return;
  }
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  // Freeze all three predicates before clearing transaction ownership. A later
  // diagnostic flush or endpoint change cannot overwrite this first sample.
  R19GroundUsbCommitEvidence commit_evidence =
      r19_ground_heartbeat_commit_evidence(
          R19GroundUsbCommitFailureReason::PublicationRejected, __LINE__,
          flush_completed_ms, true, transport_published,
          r19_ground_usb_last_flush_started_ms);
  auto first_usb_evidence = r19_product_failure_evidence(
      1U, __LINE__, flush_completed_ms);
  if (commit_evidence.predicate_true_mask != 7U) {
    r19_latch_product_failure(first_usb_evidence);
    (void)vc_lora_r19_ground_usb_commit_record.latch_first_failure(commit_evidence);
  }
#endif
  const std::uint32_t token = ground_paced_heartbeat_commit_token;
  ground_paced_heartbeat_commit_active = false;
  ground_paced_heartbeat_commit_token = 0U;
  ground_paced_heartbeat_commit_goal = 0U;
  const std::uint64_t deadline_ms =
      ground_paced_heartbeat_commit_deadline_ms;
  ground_paced_heartbeat_commit_deadline_ms = 0U;
  ground_paced_heartbeat_commit_loss_epoch = 0U;
  const bool publication_succeeded =
      transport_published && ground_usb_endpoint_ready_state &&
      flush_completed_ms <= deadline_ms;
  if (publication_succeeded) {
    ground_usb_transport_published_bytes =
        radio_application_endpoint.egress().stats().bytes_committed;
#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
    r19_have_ground_usb_heartbeat_commit = true;
    r19_last_ground_usb_heartbeat_commit_ms = flush_completed_ms;
#endif
  }
  const TxResult result = publication_succeeded ? TxResult::Accepted
                                                : TxResult::Rejected;
  if (!ground_usb_heartbeat_pacer.complete_emit(
          token, result, flush_completed_ms)) {
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    commit_evidence.reason = R19GroundUsbCommitFailureReason::PacerCompletionRejected;
    commit_evidence.source_line = __LINE__;
    first_usb_evidence.reason = 3U;
    first_usb_evidence.source_line = __LINE__;
    r19_latch_product_failure(first_usb_evidence);
    (void)vc_lora_r19_ground_usb_commit_record.latch_first_failure(commit_evidence);
#endif
    latch_runtime_fail_closed();
  }
#if VC_LORA_R19_TIMED_PATH_DIAGNOSTICS
  else if (publication_succeeded) {
    r19_latch_product_completion(token, commit_evidence.expected_epoch);
  }
#endif
  if (result == TxResult::Rejected) {
    latch_runtime_fail_closed();
  }
}

void observe_ground_parameter_publish_commit(
    std::uint64_t now_ms) noexcept {
  if (!ground_parameter_publish_commit_active) {
    return;
  }
  const std::uint64_t observed_ms =
      std::max(now_ms, monotonic_now_ms());
  update_ground_usb_connection(observed_ms);
  if (!ground_parameter_publish_commit_active) {
    return;
  }
  if (!ground_usb_transport_epoch_healthy(observed_ms)) {
    return;
  }
  if (observed_ms >= ground_parameter_publish_commit_deadline_ms) {
    reject_ground_parameter_publish_commit(observed_ms);
    latch_runtime_fail_closed();
    return;
  }
  if (!ground_usb_endpoint_ready_state) {
    return;
  }
  if (radio_application_endpoint.egress().stats().bytes_committed <
      ground_parameter_publish_commit_goal) {
    return;
  }

  const std::uint64_t remaining_ms =
      ground_parameter_publish_commit_deadline_ms - observed_ms;
  std::uint64_t flush_completed_ms = observed_ms;
  const bool transport_published =
      flush_ground_usb_transport(
          ground_parameter_publish_commit_loss_epoch,
          static_cast<std::uint32_t>(remaining_ms), flush_completed_ms);
  update_ground_usb_connection(flush_completed_ms);
  if (!ground_parameter_publish_commit_active) {
    return;
  }
  if (!transport_published || !ground_usb_endpoint_ready_state ||
      flush_completed_ms > ground_parameter_publish_commit_deadline_ms) {
    reject_ground_parameter_publish_commit(flush_completed_ms);
    latch_runtime_fail_closed();
    return;
  }

  ground_usb_transport_published_bytes =
      radio_application_endpoint.egress().stats().bytes_committed;
  const MavlinkFrame published = ground_parameter_publish_commit_frame;
  clear_ground_parameter_publish_commit();
  const GroundParameterProxyDisposition disposition =
      ground_parameter_proxy.on_vehicle_frame(published, true,
                                              flush_completed_ms);
  if (disposition == GroundParameterProxyDisposition::Invalid) {
    ++link_diagnostics.mavlink_crc_errors;
    latch_runtime_fail_closed();
  }
}

// Replay stops at the next heartbeat marker or active physical publication.
// A later MAVLink frame is never placed ahead of an older held heartbeat, and
// a tracked PARAM_VALUE advances only after its result-bearing HWCDC fence.
bool replay_ground_usb_ordered_backlog(
    std::uint64_t now_ms) noexcept {
  if (!r19_product_usb_publication_allowed()) return true;
  if (ground_paced_heartbeat_commit_active) {
    return true;
  }
  if (ground_parameter_publish_commit_active) {
    return true;
  }
  while (!ground_usb_ordered_backlog.empty()) {
    MavlinkFrame frame{};
    bool heartbeat_marker = false;
    if (!ground_usb_ordered_backlog.peek(frame, heartbeat_marker)) {
      ground_usb_ordered_backlog.discard_all();
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
        latch_runtime_fail_closed();
        return false;
      }
      continue;
    }
    if (replay_preclassification ==
        GroundParameterProxyDisposition::Invalid) {
      (void)ground_usb_ordered_backlog.discard_front();
      ++link_diagnostics.mavlink_crc_errors;
      latch_runtime_fail_closed();
      return false;
    }

    auto& egress = radio_application_endpoint.egress();
    if (egress.fail_closed()) {
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
        latch_runtime_fail_closed();
      }
      return false;
    }
    if (!ground_usb_ordered_backlog.pop_front()) {
      latch_runtime_fail_closed();
      return false;
    }
    note_ground_usb_admission(frame, status, now_ms);
    if (ground_parameter_publish_commit_active) {
      return true;
    }
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
    latch_runtime_fail_closed();
  }
}

void r19_expire_waiting_host_heartbeats(std::uint64_t now_ms) noexcept {
#if VC_LORA_R19_USB_READINESS_MODE == 2
  const auto held = ground_usb_heartbeat_pacer.queued();
  const auto expired =
      ground_usb_heartbeat_pacer.diagnostics().expired_heartbeats;
  ground_usb_heartbeat_pacer.expire(now_ms);
  if (held != ground_usb_heartbeat_pacer.queued() || expired !=
          ground_usb_heartbeat_pacer.diagnostics().expired_heartbeats)
    recover_ground_stale_pacer_pair(now_ms);
#else
  (void)now_ms;
#endif
}

// Deadline admission happens only at an empty LocalEgress frame boundary. The
// heartbeat marker is removed only after its byte-exact pacer lease entered
// that FIFO. Following frames stay in the descriptor backlog until the HB's
// result-bearing physical publication commit completes. An age deadline may
// release queued HBs before last_completion+2100 ms when required by the
// 2400-ms RF-age ceiling.
void service_ground_usb_heartbeat_pacer(
    std::uint64_t now_ms) noexcept {
  // The caller can have spent up to 100 ms in a preceding PARAM publication
  // fence. Refresh here so that stale loop-entry time cannot consume the new
  // heartbeat's 106-ms admission-to-publication budget.
  const std::uint64_t observed_ms =
      std::max(now_ms, monotonic_now_ms());
  update_ground_usb_connection(observed_ms);
  if (!r19_product_usb_publication_allowed()) {
    r19_expire_waiting_host_heartbeats(observed_ms);
    return;
  }
  if (!ground_usb_transport_epoch_healthy(observed_ms)) {
    return;
  }
  const bool endpoint_ready = ground_usb_endpoint_ready_state;
  auto& egress = radio_application_endpoint.egress();
  const bool writer_available = ground_usb_writer_available();
  ground_usb_heartbeat_pacer.observe_usb_egress(
      egress.queued_bytes(), egress.write_pending(), writer_available);

  if (!bridge_ready || !endpoint_ready) {
    return;
  }
  if (ground_paced_heartbeat_commit_active ||
      ground_parameter_publish_commit_active) {
    return;
  }
  if (!replay_ground_usb_ordered_backlog(observed_ms)) {
    return;
  }
  if (!endpoint_ready || !writer_available || !egress.empty() ||
      egress.write_pending() || ground_paced_heartbeat_commit_active ||
      ground_parameter_publish_commit_active) {
    return;
  }

  MavlinkFrame marker{};
  bool heartbeat_marker = false;
  if (!ground_usb_ordered_backlog.peek(marker, heartbeat_marker)) {
    if (!ground_usb_ordered_backlog.empty()) {
      ground_usb_ordered_backlog.discard_all();
      latch_runtime_fail_closed();
    } else if (ground_usb_heartbeat_pacer.queued() != 0U) {
      (void)discard_ground_held_heartbeats(observed_ms);
      latch_runtime_fail_closed();
    }
    return;
  }
  if (!heartbeat_marker) {
    latch_runtime_fail_closed();
    return;
  }

  const std::size_t held_before_select =
      ground_usb_heartbeat_pacer.queued();
  GroundUsbHeartbeatLease lease{};
  const bool selected =
      ground_usb_heartbeat_pacer.select_due(observed_ms, false, lease);
  if (ground_usb_heartbeat_pacer.queued() != held_before_select) {
    if (selected &&
        !ground_usb_heartbeat_pacer.abort_pending_emit(lease.token)) {
      latch_runtime_fail_closed();
      return;
    }
    recover_ground_stale_pacer_pair(observed_ms);
    return;
  }
  if (!selected) {
    return;
  }
  if (!ground_same_wire_frame(marker, lease.frame)) {
    if (!ground_usb_heartbeat_pacer.abort_pending_emit(lease.token)) {
      latch_runtime_fail_closed();
      return;
    }
    (void)discard_ground_ordered_backlog(observed_ms);
    (void)discard_ground_held_heartbeats(observed_ms);
    latch_runtime_fail_closed();
    return;
  }
  if (!admit_ground_paced_heartbeat(lease, observed_ms) ||
      !ground_usb_ordered_backlog.pop_front()) {
    (void)discard_ground_ordered_backlog(observed_ms);
    (void)discard_ground_held_heartbeats(observed_ms);
    latch_runtime_fail_closed();
    return;
  }
}
#endif

#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
#if defined(VC_LORA_PHASE6_GROUND)
// R19A may be inserted between complete product MAVLink frames. Logical
// descriptor backlog and radio bytes which have not entered LocalEgress do
// not dirty that physical USB boundary; they remain retained while the
// diagnostic owns one short reservation.
bool r19_ground_runtime_alive_boundary_clean(
    bool diagnostic_host_gate_ready) noexcept {
  const auto& egress = radio_application_endpoint.egress();
  return diagnostic_host_gate_ready &&
         !ground_paced_heartbeat_commit_active &&
         !ground_parameter_publish_commit_active &&
         !r19_ground_usb_commit_active && egress.empty() &&
         !egress.write_pending() &&
         egress.stats().bytes_committed ==
             ground_usb_transport_published_bytes;
}

bool r19_ground_runtime_fail_boundary_clean(
    bool diagnostic_host_gate_ready) noexcept {
  const auto& egress = radio_application_endpoint.egress();
  return diagnostic_host_gate_ready &&
         !ground_paced_heartbeat_commit_active &&
         !ground_parameter_publish_commit_active &&
         !r19_ground_usb_commit_active &&
         ground_usb_ordered_backlog.empty() &&
         ground_usb_heartbeat_pacer.queued() == 0U && egress.empty() &&
         !egress.write_pending() &&
         egress.stats().bytes_committed ==
             ground_usb_transport_published_bytes;
}

bool r19_ground_runtime_fail_boundary_recovery_safe() noexcept {
  const auto& egress = radio_application_endpoint.egress();
  return r19_runtime_fail_ground_boundary_status ==
             R19RuntimeFailGroundBoundaryStatus::DrainingAdmitted &&
         !ground_paced_heartbeat_commit_active &&
         !ground_parameter_publish_commit_active &&
         !r19_ground_usb_commit_active &&
         ground_usb_ordered_backlog.empty() &&
         ground_usb_heartbeat_pacer.queued() == 0U && egress.empty() &&
         !egress.write_pending() &&
         egress.stats().bytes_committed >
             ground_usb_transport_published_bytes;
}

void r19_retire_ground_candidate_usb_commit() noexcept {
  r19_ground_usb_commit_active = false;
  r19_ground_usb_commit_final = false;
  r19_ground_usb_commit_token = 0U;
  r19_ground_usb_commit_loss_epoch = 0U;
  r19_ground_usb_commit_goal = 0U;
  r19_ground_usb_commit_deadline_ms = 0U;
}

bool r19_mark_ground_runtime_fail_boundary_impossible(
    R19RuntimeDiagnosticTransportFailureReason reason) noexcept {
  r19_runtime_fail_ground_boundary_status =
      R19RuntimeFailGroundBoundaryStatus::Impossible;
  r19_fail_diagnostic_transport(reason, monotonic_now_ms());
  return false;
}

// Fail-close prevents the normal product loop from advancing.  The diagnostic
// stream may nevertheless share COM6 with complete MAVLink frames which were
// already admitted to LocalEgress.  Finish only that fixed admitted set, fence
// its physical USB completion, retire all product commit ownership, and then
// expose a clean frame boundary for R19A/R19F.  Descriptor backlog and held
// heartbeats have not entered the byte FIFO and are rejected rather than
// admitted after the fault.
bool r19_converge_ground_runtime_fail_boundary(
    std::uint64_t now_ms,
    bool diagnostic_host_gate_ready = true) noexcept {
  if (r19_runtime_fail_ground_boundary_status ==
      R19RuntimeFailGroundBoundaryStatus::Clean) {
    return r19_ground_runtime_fail_boundary_clean(
        diagnostic_host_gate_ready);
  }
  if (r19_runtime_fail_ground_boundary_status ==
      R19RuntimeFailGroundBoundaryStatus::Impossible) {
    return false;
  }
  if (r19_ground_runtime_fail_boundary_clean(
          diagnostic_host_gate_ready)) {
    r19_runtime_fail_ground_boundary_status =
        R19RuntimeFailGroundBoundaryStatus::Clean;
    return true;
  }
  if (!Serial.isPlugged() || !static_cast<bool>(Serial)) {
    const auto& egress = radio_application_endpoint.egress();
    const bool irreversible_prefix =
        egress.write_pending() ||
        egress.stats().bytes_committed !=
            ground_usb_transport_published_bytes;
    if (r19_runtime_fail_ground_boundary_status ==
        R19RuntimeFailGroundBoundaryStatus::DrainingAdmitted) {
      return r19_mark_ground_runtime_fail_boundary_impossible(
          R19RuntimeDiagnosticTransportFailureReason::
              GroundBoundaryHostLostWhileDraining);
    }
    if (irreversible_prefix) {
      return r19_mark_ground_runtime_fail_boundary_impossible(
          R19RuntimeDiagnosticTransportFailureReason::
              GroundBoundaryHostAbsentWithIrreversiblePrefix);
    }
    r19_runtime_fail_ground_boundary_status =
        R19RuntimeFailGroundBoundaryStatus::WaitingHost;
    return false;
  }

  const std::uint64_t observed_ms =
      std::max(now_ms, monotonic_now_ms());
  if (r19_runtime_fail_ground_boundary_status ==
          R19RuntimeFailGroundBoundaryStatus::Idle ||
      r19_runtime_fail_ground_boundary_status ==
          R19RuntimeFailGroundBoundaryStatus::WaitingHost) {
    r19_runtime_fail_ground_boundary_status =
        R19RuntimeFailGroundBoundaryStatus::DrainingAdmitted;
    r19_runtime_fail_ground_boundary_epoch = Serial.txLossEpoch();
    const std::uint64_t maximum =
        std::numeric_limits<std::uint64_t>::max();
    r19_runtime_fail_ground_boundary_deadline_ms =
        observed_ms > maximum - kR19RuntimeFailGroundConvergenceBudgetMs
            ? maximum
            : observed_ms + kR19RuntimeFailGroundConvergenceBudgetMs;
  }
  if (Serial.txLossEpoch() != r19_runtime_fail_ground_boundary_epoch) {
    return r19_mark_ground_runtime_fail_boundary_impossible(
        R19RuntimeDiagnosticTransportFailureReason::
            GroundBoundaryEpochChanged);
  }
  if (observed_ms >= r19_runtime_fail_ground_boundary_deadline_ms) {
    if (Serial.txLossEpoch() ==
            r19_runtime_fail_ground_boundary_epoch &&
        r19_ground_runtime_fail_boundary_recovery_safe()) {
      const std::uint64_t target_bytes =
          radio_application_endpoint.egress().stats().bytes_committed;
      const bool failed = r19_mark_ground_runtime_fail_boundary_impossible(
          R19RuntimeDiagnosticTransportFailureReason::
              GroundBoundaryDeadlineExpired);
      (void)r19_arm_diagnostic_transport_recovery(
          R19RuntimeDiagnosticTransportRecovery::GroundBoundaryFlush,
          r19_runtime_fail_ground_boundary_epoch, observed_ms,
          target_bytes);
      return failed;
    }
    return r19_mark_ground_runtime_fail_boundary_impossible(
        R19RuntimeDiagnosticTransportFailureReason::
            GroundBoundaryDeadlineExpired);
  }

  retire_ground_usb_publication_commits(observed_ms);
  r19_retire_ground_candidate_usb_commit();
  if (!discard_ground_ordered_backlog(observed_ms)) {
    return r19_mark_ground_runtime_fail_boundary_impossible(
        R19RuntimeDiagnosticTransportFailureReason::
            GroundBoundaryOrderedBacklogDiscardFailed);
  }
  if (!discard_ground_held_heartbeats(observed_ms)) {
    return r19_mark_ground_runtime_fail_boundary_impossible(
        R19RuntimeDiagnosticTransportFailureReason::
            GroundBoundaryHeldHeartbeatDiscardFailed);
  }

  auto& egress = radio_application_endpoint.egress();
  const LocalEgressPumpStatus pump_status =
      pump_local_egress_if_connected(
          egress, ground_usb_epoch_checked_writer, true);
  if (pump_status == LocalEgressPumpStatus::Invalid) {
    return r19_mark_ground_runtime_fail_boundary_impossible(
        R19RuntimeDiagnosticTransportFailureReason::
            GroundBoundaryEgressPumpInvalid);
  }
  if (!egress.empty() || egress.write_pending()) {
    return false;
  }

  std::uint64_t completed_ms = observed_ms;
  const bool flushed = r19_flush_runtime_diagnostic(
      r19_runtime_fail_ground_boundary_epoch,
      kR19RuntimeFailDiagnosticFlushBudgetMs, completed_ms,
      r19_runtime_fail_ground_boundary_deadline_ms);
  if (!flushed) {
    if (Serial.txLossEpoch() ==
            r19_runtime_fail_ground_boundary_epoch &&
        completed_ms < r19_runtime_fail_ground_boundary_deadline_ms) {
      // A bounded flush wait may miss one host pickup while the already
      // admitted bytes remain owned by the same USB epoch. Keep the absolute
      // deadline and retry only the physical fence; never replay the frame.
      return false;
    }
    if (Serial.txLossEpoch() ==
            r19_runtime_fail_ground_boundary_epoch &&
        r19_ground_runtime_fail_boundary_recovery_safe()) {
      // The admitted prefix is complete and remains in the same USB epoch.
      // Preserve the hard-deadline failure as first-wins evidence, then keep
      // ownership of the clean boundary until a later flush observes the
      // endpoint after Windows has opened the user-space COM handle.
      const std::uint64_t target_bytes =
          radio_application_endpoint.egress().stats().bytes_committed;
      const bool failed = r19_mark_ground_runtime_fail_boundary_impossible(
          R19RuntimeDiagnosticTransportFailureReason::
              GroundBoundaryFlushFailed);
      (void)r19_arm_diagnostic_transport_recovery(
          R19RuntimeDiagnosticTransportRecovery::GroundBoundaryFlush,
          r19_runtime_fail_ground_boundary_epoch, completed_ms,
          target_bytes);
      return failed;
    }
    return r19_mark_ground_runtime_fail_boundary_impossible(
        R19RuntimeDiagnosticTransportFailureReason::
            GroundBoundaryFlushFailed);
  }
  if (Serial.txLossEpoch() != r19_runtime_fail_ground_boundary_epoch) {
    return r19_mark_ground_runtime_fail_boundary_impossible(
        R19RuntimeDiagnosticTransportFailureReason::
            GroundBoundaryFlushEpochChanged);
  }
  if (completed_ms >= r19_runtime_fail_ground_boundary_deadline_ms) {
    if (r19_ground_runtime_fail_boundary_recovery_safe()) {
      const std::uint64_t target_bytes =
          radio_application_endpoint.egress().stats().bytes_committed;
      const bool failed = r19_mark_ground_runtime_fail_boundary_impossible(
          R19RuntimeDiagnosticTransportFailureReason::
              GroundBoundaryFlushLate);
      (void)r19_arm_diagnostic_transport_recovery(
          R19RuntimeDiagnosticTransportRecovery::GroundBoundaryFlush,
          r19_runtime_fail_ground_boundary_epoch, completed_ms,
          target_bytes);
      return failed;
    }
    return r19_mark_ground_runtime_fail_boundary_impossible(
        R19RuntimeDiagnosticTransportFailureReason::
            GroundBoundaryFlushLate);
  }
  ground_usb_transport_published_bytes = egress.stats().bytes_committed;
  r19_runtime_fail_ground_boundary_status =
      R19RuntimeFailGroundBoundaryStatus::Clean;
  return r19_ground_runtime_fail_boundary_clean(
      diagnostic_host_gate_ready);
}

bool r19_recover_ground_runtime_fail_boundary_flush() noexcept {
  const std::uint64_t now_ms = monotonic_now_ms();
  const auto& egress = radio_application_endpoint.egress();
  if (r19_runtime_diagnostic_transport_recovery !=
          R19RuntimeDiagnosticTransportRecovery::GroundBoundaryFlush ||
      r19_runtime_fail_ground_boundary_status !=
          R19RuntimeFailGroundBoundaryStatus::Impossible ||
      r19_runtime_diagnostic_recovery_epoch !=
          r19_runtime_fail_ground_boundary_epoch ||
      Serial.txLossEpoch() != r19_runtime_diagnostic_recovery_epoch ||
      now_ms >= r19_runtime_diagnostic_recovery_until_ms ||
      !ground_usb_ordered_backlog.empty() ||
      ground_usb_heartbeat_pacer.queued() != 0U ||
      ground_paced_heartbeat_commit_active ||
      ground_parameter_publish_commit_active ||
      r19_ground_usb_commit_active || !egress.empty() ||
      egress.write_pending() ||
      egress.stats().bytes_committed !=
          r19_runtime_diagnostic_recovery_target_bytes) {
    r19_clear_diagnostic_transport_recovery();
    return false;
  }

  // No payload is replayed here.  The earlier convergence already drained
  // the immutable admitted prefix; this retry observes only the physical USB
  // completion fence which may settle after the original 500-ms deadline.
  std::uint64_t completed_ms = now_ms;
  if (!r19_flush_runtime_diagnostic(
          r19_runtime_diagnostic_recovery_epoch,
          kR19RuntimeFailDiagnosticFlushBudgetMs, completed_ms,
          r19_runtime_diagnostic_recovery_until_ms)) {
    return false;
  }
  if (Serial.txLossEpoch() != r19_runtime_diagnostic_recovery_epoch ||
      completed_ms >= r19_runtime_diagnostic_recovery_until_ms) {
    r19_clear_diagnostic_transport_recovery();
    return false;
  }

  ground_usb_transport_published_bytes =
      r19_runtime_diagnostic_recovery_target_bytes;
  r19_runtime_fail_ground_boundary_status =
      R19RuntimeFailGroundBoundaryStatus::Clean;
  r19_clear_diagnostic_transport_recovery();
  r19_runtime_fail_diagnostic_transport_failed = false;
  r19_increment_runtime_stage_counter(R19RuntimeStageCounter::Retry);
  r19_mark_runtime_stage(R19RuntimeStage::TransportRecoveryCompleted);
  return true;
}

bool r19_ground_runtime_alive_reservation_pending() noexcept {
  const R19RuntimeDiagnosticAction pending =
      r19_runtime_diagnostic_action != R19RuntimeDiagnosticAction::None
          ? r19_runtime_diagnostic_action
          : r19_runtime_diagnostic_cadence.pending_action();
  return pending == R19RuntimeDiagnosticAction::Armed ||
         pending == R19RuntimeDiagnosticAction::Alive;
}

void r19_reset_ground_runtime_alive_reservation() noexcept {
  r19_runtime_alive_ground_reservation_active = false;
  r19_runtime_alive_ground_reservation_epoch = 0U;
  r19_runtime_alive_ground_reservation_deadline_ms = 0U;
}

bool r19_ground_runtime_alive_reservation_valid(
    std::uint64_t now_ms) noexcept {
  if (!r19_runtime_alive_ground_reservation_active) {
    return true;
  }
  if (Serial.txLossEpoch() !=
      r19_runtime_alive_ground_reservation_epoch) {
    r19_fail_diagnostic_transport(
        R19RuntimeDiagnosticTransportFailureReason::
            GroundReservationEpochChanged,
        now_ms);
    return false;
  }
  if (now_ms >= r19_runtime_alive_ground_reservation_deadline_ms) {
    r19_fail_diagnostic_transport(
        R19RuntimeDiagnosticTransportFailureReason::
            GroundReservationDeadlineExpired,
        now_ms);
    return false;
  }
  return true;
}

// Once R19A is due, stop admitting later product traffic and finish only the
// LocalEgress bytes/commit already owned at that instant. This finite prefix
// is fenced physically before R19A is allowed to stage. Unread E220 bytes and
// complete descriptor backlog remain intact for the next product loop.
void r19_drain_ground_runtime_alive_boundary(
    std::uint64_t now_ms) noexcept {
  const std::uint64_t observed_ms =
      std::max(now_ms, monotonic_now_ms());
  if (!r19_runtime_alive_ground_reservation_active) {
    // Enumeration and a host opening COM6 can occur long after boot.  The
    // bounded convergence budget protects a transaction whose USB endpoint is
    // plugged and open; it must not run while no host endpoint exists. Actual
    // write capacity remains governed by the hard bounded transaction below.
    // Once active, however, a disconnect remains subject to the same hard
    // deadline and is handled by the validity/transport checks below.
    if (!Serial.isPlugged() || !static_cast<bool>(Serial)) {
      return;
    }
    if (observed_ms > std::numeric_limits<std::uint64_t>::max() -
                          kR19RuntimeAliveGroundConvergenceBudgetMs) {
      r19_fail_diagnostic_transport(
          R19RuntimeDiagnosticTransportFailureReason::
              GroundReservationDeadlineOverflow,
          observed_ms);
      return;
    }
    r19_runtime_alive_ground_reservation_active = true;
    r19_runtime_alive_ground_reservation_epoch = Serial.txLossEpoch();
    r19_runtime_alive_ground_reservation_deadline_ms =
        observed_ms + kR19RuntimeAliveGroundConvergenceBudgetMs;
  }
  if (!r19_ground_runtime_alive_reservation_valid(observed_ms)) {
    return;
  }
  update_ground_usb_connection(observed_ms);
  if (!ground_usb_runtime_healthy_or_retire(observed_ms)) {
    return;
  }

  pump_ground_usb_egress(observed_ms);
  if (!ground_usb_runtime_healthy_or_retire(observed_ms)) {
    return;
  }
  observe_ground_paced_heartbeat_commit(observed_ms);
  observe_ground_parameter_publish_commit(observed_ms);
  observe_candidate_ground_usb_output_commit(observed_ms);
  if (!ground_usb_runtime_healthy_or_retire(observed_ms)) {
    return;
  }

  auto& egress = radio_application_endpoint.egress();
  if (ground_paced_heartbeat_commit_active ||
      ground_parameter_publish_commit_active ||
      r19_ground_usb_commit_active || !egress.empty() ||
      egress.write_pending()) {
    return;
  }
  if (egress.stats().bytes_committed ==
      ground_usb_transport_published_bytes) {
    return;
  }

  const std::uint32_t expected_epoch = Serial.txLossEpoch();
  std::uint64_t completed_ms = observed_ms;
  const bool flushed = r19_flush_runtime_diagnostic(
      expected_epoch, kR19RuntimeFailDiagnosticFlushBudgetMs,
      completed_ms, r19_runtime_alive_ground_reservation_deadline_ms);
  if (!flushed) {
    if (Serial.txLossEpoch() == expected_epoch &&
        completed_ms <
            r19_runtime_alive_ground_reservation_deadline_ms) {
      // Preserve the reservation and its absolute deadline. The admitted
      // product bytes are complete, so the next service retries only flush.
      return;
    }
    r19_fail_diagnostic_transport(
        R19RuntimeDiagnosticTransportFailureReason::
            GroundReservationFlushFailed,
        completed_ms);
    return;
  }
  if (Serial.txLossEpoch() != expected_epoch) {
    r19_fail_diagnostic_transport(
        R19RuntimeDiagnosticTransportFailureReason::
            GroundReservationFlushEpochChanged,
        completed_ms);
    return;
  }
  if (completed_ms >=
      r19_runtime_alive_ground_reservation_deadline_ms) {
    r19_fail_diagnostic_transport(
        R19RuntimeDiagnosticTransportFailureReason::
            GroundReservationFlushLate,
        completed_ms);
    return;
  }
  ground_usb_transport_published_bytes =
      egress.stats().bytes_committed;
}
#endif

constexpr R19RuntimeFailRole r19_runtime_diagnostic_role() noexcept {
#if defined(VC_LORA_PHASE6_GROUND)
  return R19RuntimeFailRole::Ground;
#else
  return R19RuntimeFailRole::Vehicle;
#endif
}

bool r19_stage_runtime_diagnostic(
    R19RuntimeDiagnosticAction action, std::uint64_t now_ms,
    bool defer_deadline_for_bootstrap) noexcept {
#if VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD
  r19_reset_diagnostic_usb_call();
#endif
  if (!defer_deadline_for_bootstrap &&
      now_ms > std::numeric_limits<std::uint64_t>::max() -
                   kR19RuntimeDiagnosticFrameBudgetMs) {
    return false;
  }
  bool staged = false;
  if (action == R19RuntimeDiagnosticAction::FailRepeat) {
    if (!r19_runtime_fail_latch.latched()) {
      return false;
    }
    staged = r19_runtime_fail_publisher.bound_evidence().valid()
                 ? r19_runtime_fail_publisher.stage_repeat(
                       r19_runtime_diagnostic_mavlink_sequence)
                 : r19_runtime_fail_publisher.stage(
                       r19_runtime_fail_latch.evidence(),
                       r19_runtime_diagnostic_mavlink_sequence);
  } else if (action == R19RuntimeDiagnosticAction::Armed ||
             action == R19RuntimeDiagnosticAction::Alive) {
    const R19RuntimeAliveEvidence evidence{
        r19_runtime_diagnostic_role(),
        action == R19RuntimeDiagnosticAction::Armed
            ? R19RuntimeAliveState::Armed
            : R19RuntimeAliveState::Alive,
        r19_runtime_diagnostic_cadence.diagnostic_sequence(),
        now_ms,
        r19_runtime_fail_status_snapshot()};
    staged = r19_runtime_alive_publisher.stage(
        evidence, r19_runtime_diagnostic_mavlink_sequence);
  }
  if (!staged) {
    return false;
  }
  ++r19_runtime_diagnostic_mavlink_sequence;
  r19_runtime_diagnostic_action = action;
  r19_runtime_fail_diagnostic_staged = true;
  r19_runtime_fail_diagnostic_transport_epoch = Serial.txLossEpoch();
  r19_runtime_diagnostic_frame_deadline_ms =
      defer_deadline_for_bootstrap
          ? 0U
          : now_ms + kR19RuntimeDiagnosticFrameBudgetMs;
  return true;
}

R19RuntimeFailWriteView r19_runtime_diagnostic_pending_write() noexcept {
  return r19_runtime_diagnostic_action ==
                 R19RuntimeDiagnosticAction::FailRepeat
             ? r19_runtime_fail_publisher.pending_write()
             : r19_runtime_alive_publisher.pending_write();
}

R19RuntimeFailWriteStatus r19_complete_runtime_diagnostic_write(
    std::size_t accepted_bytes) noexcept {
  return r19_runtime_diagnostic_action ==
                 R19RuntimeDiagnosticAction::FailRepeat
             ? r19_runtime_fail_publisher.complete_write(accepted_bytes)
             : r19_runtime_alive_publisher.complete_write(accepted_bytes);
}

bool r19_runtime_diagnostic_pending() noexcept {
  return r19_runtime_diagnostic_action ==
                 R19RuntimeDiagnosticAction::FailRepeat
             ? r19_runtime_fail_publisher.pending()
             : r19_runtime_alive_publisher.pending();
}

bool r19_restart_completed_runtime_diagnostic_write() noexcept {
  const bool restarted = r19_runtime_diagnostic_action ==
                 R19RuntimeDiagnosticAction::FailRepeat
             ? r19_runtime_fail_publisher.restart_complete_write()
             : r19_runtime_alive_publisher.restart_complete_write();
#if VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD
  // A bootstrap BUS_RESET starts a new USB stream epoch. The former complete
  // image was discarded by HWCDC, not accepted twice in the current stream.
  // Preserve the immutable first failure, but never carry its retry scratch
  // count or a previous epoch's FIFO snapshot into the fresh 63-byte image.
  if (restarted) r19_reset_diagnostic_usb_call();
#endif
  return restarted;
}

bool r19_flush_runtime_diagnostic(std::uint32_t expected_epoch,
    std::uint32_t budget_ms, std::uint64_t& completed_ms,
    std::uint64_t deadline_ms) noexcept {
#if VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD
  auto& call = r19_diagnostic_usb_call;
  call = {};
  call.started_us = static_cast<std::uint64_t>(esp_timer_get_time());
  call.budget_ms = budget_ms;
  call.expected_epoch = expected_epoch;
  call.deadline_us = (deadline_ms != 0U ? deadline_ms :
      r19_runtime_diagnostic_frame_deadline_ms) * 1000U;
  if (r19_diagnostic_usb_flush_attempt != std::numeric_limits<std::uint32_t>::max())
    ++r19_diagnostic_usb_flush_attempt;
  call.attempt_id = r19_diagnostic_usb_flush_attempt;
  call.sdk.transaction_token = static_cast<std::uint32_t>(
      static_cast<std::uint8_t>(r19_runtime_diagnostic_mavlink_sequence -
          (r19_runtime_fail_diagnostic_staged ? 1U : 0U))) + 1U;
  call.sdk.attempt_id = call.attempt_id;
  // Wrapper EndpointReady is the pre-call admission sample; the terminal
  // FIFO/pickup state is exclusively call.sdk's coherent terminal snapshot.
  const bool endpoint_ready = static_cast<bool>(Serial);
#if defined(VC_LORA_PHASE6_GROUND)
  r19_ground_usb_last_flush_started_ms = call.started_us / 1000U;
#endif
  const bool called = budget_ms != 0U;
  const bool raw = called && Serial.flushTxCompleteDiagnostic(
      budget_ms, expected_epoch, call.sdk);
  if (!called) call.sdk = {};
  call.finished_us = static_cast<std::uint64_t>(esp_timer_get_time());
  call.wrapper_flags = (called ? 1U : 0U) | (raw ? 2U : 0U) |
      (endpoint_ready ? 4U : 0U);
  completed_ms = call.finished_us / 1000U;
#if defined(VC_LORA_PHASE6_GROUND)
  return raw && completed_ms - call.started_us / 1000U <= budget_ms;
#else
  return raw;
#endif
#else
  (void)deadline_ms;
#if defined(VC_LORA_PHASE6_GROUND)
  return flush_ground_usb_transport(expected_epoch, budget_ms, completed_ms);
#else
  const bool raw = Serial.flushTxComplete(budget_ms, expected_epoch);
  completed_ms = monotonic_now_ms();
  return raw;
#endif
#endif
}

bool r19_recover_runtime_diagnostic_frame_flush() noexcept {
  if (r19_runtime_diagnostic_transport_recovery !=
      R19RuntimeDiagnosticTransportRecovery::FrameFlush) {
    return false;
  }
  const std::uint64_t now_ms = monotonic_now_ms();
  if (!r19_runtime_fail_diagnostic_transport_failed ||
      !r19_runtime_fail_diagnostic_staged ||
      !r19_runtime_fail_diagnostic_flush_pending ||
      r19_runtime_diagnostic_action == R19RuntimeDiagnosticAction::None ||
      r19_runtime_diagnostic_pending() ||
      r19_runtime_diagnostic_recovery_epoch !=
          r19_runtime_fail_diagnostic_transport_epoch ||
      Serial.txLossEpoch() != r19_runtime_diagnostic_recovery_epoch ||
      now_ms >= r19_runtime_diagnostic_recovery_until_ms) {
    r19_clear_diagnostic_transport_recovery();
    return false;
  }

  // The publisher is complete and the original failure remains latched.  A
  // later call is allowed to retry only the physical same-epoch fence; it must
  // never replay any prefix or reset the absolute-deadline evidence.
  std::uint64_t flush_completed_ms = now_ms;
  const bool flushed = r19_flush_runtime_diagnostic(
      r19_runtime_diagnostic_recovery_epoch,
      kR19RuntimeFailDiagnosticFlushBudgetMs, flush_completed_ms);
  if (!flushed) {
    if (Serial.txLossEpoch() != r19_runtime_diagnostic_recovery_epoch ||
        flush_completed_ms >= r19_runtime_diagnostic_recovery_until_ms) {
      r19_clear_diagnostic_transport_recovery();
    }
    return false;
  }
  if (Serial.txLossEpoch() != r19_runtime_diagnostic_recovery_epoch ||
      flush_completed_ms >= r19_runtime_diagnostic_recovery_until_ms) {
    r19_clear_diagnostic_transport_recovery();
    return false;
  }

  r19_mark_runtime_stage(R19RuntimeStage::FlushCompleted);
  const R19RuntimeDiagnosticAction action =
      r19_runtime_diagnostic_action;
  r19_clear_diagnostic_transport_recovery();
  if (!r19_runtime_diagnostic_cadence.commit(action,
                                             flush_completed_ms)) {
    r19_fail_diagnostic_transport(
        R19RuntimeDiagnosticTransportFailureReason::CadenceCommitRejected,
        flush_completed_ms);
    return false;
  }
  if (action == R19RuntimeDiagnosticAction::FailRepeat) {
    r19_runtime_fail_diagnostic_published = true;
  } else if (!r19_runtime_alive_publisher.reset()) {
    r19_fail_diagnostic_transport(
        R19RuntimeDiagnosticTransportFailureReason::
            AlivePublisherResetRejected,
        flush_completed_ms);
    return false;
  }

  r19_runtime_fail_diagnostic_staged = false;
  r19_runtime_fail_diagnostic_flush_pending = false;
  r19_runtime_diagnostic_bootstrap_pending = false;
  r19_runtime_diagnostic_action = R19RuntimeDiagnosticAction::None;
  r19_runtime_diagnostic_frame_deadline_ms = 0U;
#if defined(VC_LORA_PHASE6_GROUND)
  if (action != R19RuntimeDiagnosticAction::FailRepeat) {
    r19_reset_ground_runtime_alive_reservation();
  }
#endif
  r19_runtime_fail_diagnostic_transport_failed = false;
  r19_increment_runtime_stage_counter(R19RuntimeStageCounter::Retry);
  r19_mark_runtime_stage(R19RuntimeStage::TransportRecoveryCompleted);
  r19_runtime_diagnostic_committed_this_service = true;
#if VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD
  r19_reset_diagnostic_usb_call();
#endif
  return true;
}

void r19_service_runtime_fail_diagnostic() noexcept {
  r19_runtime_diagnostic_committed_this_service = false;
  if (r19_runtime_fail_diagnostic_transport_failed) {
#if defined(VC_LORA_PHASE6_GROUND)
    if (r19_runtime_diagnostic_transport_recovery ==
        R19RuntimeDiagnosticTransportRecovery::GroundBoundaryFlush) {
      if (r19_recover_ground_runtime_fail_boundary_flush()) {
        r19_runtime_diagnostic_committed_this_service = true;
      }
      return;
    }
#endif
    if (r19_runtime_diagnostic_transport_recovery ==
        R19RuntimeDiagnosticTransportRecovery::FrameFlush) {
      (void)r19_recover_runtime_diagnostic_frame_flush();
      return;
    }
    return;
  }
  const std::uint64_t now_ms = monotonic_now_ms();
  if (r19_runtime_diagnostic_cadence.fail_closed()) {
    r19_fail_diagnostic_transport(
        R19RuntimeDiagnosticTransportFailureReason::
            CadenceFailClosedObserved,
        now_ms);
    return;
  }

  // A staged liveness image which has not emitted a byte is retractable.  If
  // immutable first-failure evidence arrived while USB was backpressured,
  // abandon that zero-prefix R19A and let the cadence select R19F in this same
  // service call.  A partial or fully written R19A is deliberately retained
  // to completion so the next frame still begins at a proved boundary.
  if (r19_runtime_fail_latch.latched() &&
      (r19_runtime_diagnostic_action ==
           R19RuntimeDiagnosticAction::Armed ||
       r19_runtime_diagnostic_action ==
           R19RuntimeDiagnosticAction::Alive) &&
      r19_runtime_fail_diagnostic_staged &&
      !r19_runtime_fail_diagnostic_flush_pending &&
      r19_runtime_alive_publisher.cancel_if_unwritten()) {
    r19_runtime_fail_diagnostic_staged = false;
    r19_runtime_diagnostic_bootstrap_pending = false;
    r19_runtime_diagnostic_action = R19RuntimeDiagnosticAction::None;
    r19_runtime_diagnostic_frame_deadline_ms = 0U;
    --r19_runtime_diagnostic_mavlink_sequence;
  }
  if (r19_runtime_fail_diagnostic_staged &&
      r19_runtime_diagnostic_frame_deadline_ms != 0U &&
      now_ms >= r19_runtime_diagnostic_frame_deadline_ms) {
    const bool recoverable =
        r19_runtime_fail_diagnostic_flush_pending &&
        !r19_runtime_diagnostic_pending() &&
        Serial.txLossEpoch() ==
            r19_runtime_fail_diagnostic_transport_epoch;
    r19_fail_diagnostic_transport(
        R19RuntimeDiagnosticTransportFailureReason::FrameDeadlineExpired,
        now_ms);
    if (recoverable) {
      (void)r19_arm_diagnostic_transport_recovery(
          R19RuntimeDiagnosticTransportRecovery::FrameFlush,
          r19_runtime_fail_diagnostic_transport_epoch, now_ms);
    }
    return;
  }
  const R19RuntimeDiagnosticAction action =
      r19_runtime_diagnostic_action != R19RuntimeDiagnosticAction::None
          ? r19_runtime_diagnostic_action
          : r19_runtime_diagnostic_cadence.due(
                now_ms, r19_runtime_fail_latch.latched());
  if (action == R19RuntimeDiagnosticAction::None) {
    return;
  }

  // HWCDC's physical-plug and writable-ring evidence is independent of its
  // cached connected bit.  That bit cannot become true until the first host
  // IN pickup, so a read-only capture needs one complete-frame bootstrap.
  const bool host_plugged = Serial.isPlugged();
  // Cached HWCDC readiness is a host-IN witness in the diagnostic core and
  // therefore stronger than the fallible IDF SOF watchdog.  TX-ring capacity
  // is likewise available before either witness is true, allowing one exact
  // complete-frame bootstrap to wait safely for a read-only host.
  const bool endpoint_ready = static_cast<bool>(Serial);
  const int pre_stage_available = Serial.availableForWrite();
  const bool bootstrap_ready =
      !endpoint_ready &&
      pre_stage_available >=
          static_cast<int>(kR19RuntimeDiagnosticBootstrapFrameBytes);
  r19_mark_runtime_stage(R19RuntimeStage::HostGateObserved);
  r19_runtime_diagnostic_transport_trace.observe_host_gate(
      host_plugged, endpoint_ready, pre_stage_available, now_ms);
#if defined(VC_LORA_PHASE6_GROUND)
  if (action == R19RuntimeDiagnosticAction::FailRepeat) {
    r19_reset_ground_runtime_alive_reservation();
  } else if (!r19_ground_runtime_alive_reservation_valid(now_ms)) {
    return;
  }
  const bool diagnostic_host_gate_ready =
      endpoint_ready || r19_runtime_diagnostic_bootstrap_pending ||
      bootstrap_ready;
  const bool clean_boundary =
      action == R19RuntimeDiagnosticAction::FailRepeat
          ? r19_converge_ground_runtime_fail_boundary(
                now_ms, diagnostic_host_gate_ready)
          : r19_ground_runtime_alive_boundary_clean(
                diagnostic_host_gate_ready);
  if (!clean_boundary) {
    return;
  }
#else
  // Host presence/CDC connection can become true before the endpoint exposes
  // any TX capacity.  Starting the immutable frame deadline in that interval
  // turns a harmless late-open/backpressure condition into a permanent
  // zero-byte diagnostic stop.  Acquire capacity before staging; after the
  // first byte attempt, the existing absolute deadline remains authoritative.
  if (!endpoint_ready && !r19_runtime_diagnostic_bootstrap_pending &&
      !bootstrap_ready) {
    return;
  }
  if (!r19_runtime_fail_diagnostic_staged && endpoint_ready &&
      pre_stage_available <= 0) {
    return;
  }
#endif

  const bool stage_with_bootstrap =
      !r19_runtime_fail_diagnostic_staged && !endpoint_ready &&
      bootstrap_ready;
  if (!r19_runtime_fail_diagnostic_staged) {
    if (!r19_stage_runtime_diagnostic(action, now_ms,
                                      stage_with_bootstrap)) {
      r19_fail_diagnostic_transport(
          R19RuntimeDiagnosticTransportFailureReason::StageRejected, now_ms);
      return;
    }
    r19_mark_runtime_stage(R19RuntimeStage::FrameStaged);
  }
  if (stage_with_bootstrap) {
    r19_runtime_diagnostic_bootstrap_pending = true;
  }

  const std::uint32_t observed_transport_epoch = Serial.txLossEpoch();
  if (observed_transport_epoch !=
      r19_runtime_fail_diagnostic_transport_epoch) {
    if (r19_runtime_diagnostic_bootstrap_pending) {
      if (r19_runtime_fail_diagnostic_flush_pending) {
        if (!r19_restart_completed_runtime_diagnostic_write()) {
          r19_fail_diagnostic_transport(
              R19RuntimeDiagnosticTransportFailureReason::
                  PublisherWriteStateInvalid,
              now_ms);
          return;
        }
        r19_increment_runtime_stage_counter(
            R19RuntimeStageCounter::Retry);
      }
      // BUS_RESET defines a new host byte-stream session.  The old session's
      // queued/prefix bytes were discarded by HWCDC; retry the exact frame and
      // MAVLink sequence without committing cadence or starting a deadline.
      r19_runtime_fail_diagnostic_flush_pending = false;
      r19_runtime_fail_diagnostic_transport_epoch = observed_transport_epoch;
      r19_runtime_diagnostic_frame_deadline_ms = 0U;
      return;
    }
    r19_fail_diagnostic_transport(
        R19RuntimeDiagnosticTransportFailureReason::EpochChangedBeforeWrite,
        now_ms);
    return;
  }

  if (r19_runtime_diagnostic_pending()) {
    if (r19_runtime_diagnostic_bootstrap_pending && endpoint_ready) {
      // The host opened before the bootstrap enqueue succeeded.  Return to
      // the ordinary <=32-byte checked writer and start its existing bounded
      // transaction now; no diagnostic byte has been accepted yet.
      if (now_ms > std::numeric_limits<std::uint64_t>::max() -
                       kR19RuntimeDiagnosticFrameBudgetMs) {
        r19_fail_diagnostic_transport(
            R19RuntimeDiagnosticTransportFailureReason::
                FlushDeadlineInvalidOrExpired,
            now_ms);
        return;
      }
      r19_runtime_diagnostic_bootstrap_pending = false;
      r19_runtime_diagnostic_frame_deadline_ms =
          now_ms + kR19RuntimeDiagnosticFrameBudgetMs;
    }
    const R19RuntimeFailWriteView write =
        r19_runtime_diagnostic_pending_write();
    const bool bootstrap_write =
        r19_runtime_diagnostic_bootstrap_pending && !endpoint_ready;
#if defined(VC_LORA_PHASE6_GROUND)
    const int available =
        bootstrap_write ? pre_stage_available : Serial.availableForWrite();
#else
    // The pre-stage sample is the acquired write gate for this service call.
    // Re-probing here creates a check/check race which can start the immutable
    // deadline yet skip the bounded epoch-checked write entirely.
    const int available = pre_stage_available;
#endif
    if (write.bytes == nullptr || write.size == 0U || available <= 0 ||
        (bootstrap_write &&
         (write.size != kR19RuntimeDiagnosticBootstrapFrameBytes ||
          available < static_cast<int>(
                          kR19RuntimeDiagnosticBootstrapFrameBytes)))) {
      return;
    }
    const std::size_t write_size =
        bootstrap_write
            ? kR19RuntimeDiagnosticBootstrapFrameBytes
            : std::min<std::size_t>(
                  {write.size, kR19RuntimeFailDiagnosticWriteChunkBytes,
                   static_cast<std::size_t>(available)});
    r19_increment_runtime_stage_counter(
        R19RuntimeStageCounter::PublishAttempt);
    r19_mark_runtime_stage(R19RuntimeStage::WriteAttempted);
    const std::size_t accepted =
        bootstrap_write
            ? Serial.writeTxBootstrapFrameChecked(
                  write.bytes, write_size,
                  r19_runtime_fail_diagnostic_transport_epoch)
            : Serial.writeTxChecked(
                  write.bytes, write_size,
                  r19_runtime_fail_diagnostic_transport_epoch);
    if (accepted > 0U) {
      r19_mark_runtime_stage(R19RuntimeStage::WriteAccepted);
    }
    r19_runtime_diagnostic_transport_trace.observe_write_attempt(
        action, monotonic_now_ms(), available, write_size, accepted,
        r19_runtime_fail_diagnostic_transport_epoch, Serial.txLossEpoch());
    if (accepted > write_size) {
      r19_fail_diagnostic_transport(
          R19RuntimeDiagnosticTransportFailureReason::AcceptedBeyondRequest,
          monotonic_now_ms());
      return;
    }
    const R19RuntimeFailWriteStatus write_status =
        r19_complete_runtime_diagnostic_write(accepted);
#if VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD
    r19_diagnostic_usb_accepted_frame_bytes += static_cast<std::uint32_t>(accepted);
#endif
    if (write_status == R19RuntimeFailWriteStatus::Invalid) {
      r19_fail_diagnostic_transport(
          R19RuntimeDiagnosticTransportFailureReason::
              PublisherWriteStateInvalid,
          monotonic_now_ms());
      return;
    }
    if (write_status != R19RuntimeFailWriteStatus::Complete) {
      return;
    }
    r19_runtime_fail_diagnostic_flush_pending = true;
  }

  if (!r19_runtime_fail_diagnostic_flush_pending) {
    return;
  }
  const std::uint64_t flush_started_ms = monotonic_now_ms();
  if (r19_runtime_diagnostic_bootstrap_pending && !endpoint_ready) {
    // The complete frame is already retained in HWCDC.  Its own IN_EMPTY
    // interrupt will establish the cached endpoint bit after the first host
    // pickup.  Do not burn a flush/frame/reservation deadline before COM open.
    return;
  }
  if (r19_runtime_diagnostic_bootstrap_pending &&
      r19_runtime_diagnostic_frame_deadline_ms == 0U) {
    if (flush_started_ms > std::numeric_limits<std::uint64_t>::max() -
                               kR19RuntimeDiagnosticFrameBudgetMs) {
      r19_fail_diagnostic_transport(
          R19RuntimeDiagnosticTransportFailureReason::
              FlushDeadlineInvalidOrExpired,
          flush_started_ms);
      return;
    }
    r19_runtime_diagnostic_frame_deadline_ms =
        flush_started_ms + kR19RuntimeDiagnosticFrameBudgetMs;
  }
  if (r19_runtime_diagnostic_frame_deadline_ms == 0U ||
      flush_started_ms >= r19_runtime_diagnostic_frame_deadline_ms) {
    const bool recoverable =
        r19_runtime_diagnostic_frame_deadline_ms != 0U &&
        !r19_runtime_diagnostic_pending() &&
        Serial.txLossEpoch() ==
            r19_runtime_fail_diagnostic_transport_epoch;
    if (!recoverable) {
      r19_runtime_fail_diagnostic_flush_pending = false;
    }
    r19_fail_diagnostic_transport(
        R19RuntimeDiagnosticTransportFailureReason::
            FlushDeadlineInvalidOrExpired,
        flush_started_ms);
    if (recoverable) {
      (void)r19_arm_diagnostic_transport_recovery(
          R19RuntimeDiagnosticTransportRecovery::FrameFlush,
          r19_runtime_fail_diagnostic_transport_epoch,
          flush_started_ms);
    }
    return;
  }
  const std::uint64_t flush_remaining_ms =
      r19_runtime_diagnostic_frame_deadline_ms - flush_started_ms;
  const std::uint32_t flush_budget_ms = static_cast<std::uint32_t>(
      std::min<std::uint64_t>(kR19RuntimeFailDiagnosticFlushBudgetMs,
                              flush_remaining_ms));
  std::uint64_t flush_completed_ms = flush_started_ms;
  const bool flushed = r19_flush_runtime_diagnostic(
      r19_runtime_fail_diagnostic_transport_epoch,
      flush_budget_ms,
      flush_completed_ms);
  if (!flushed) {
    const std::uint32_t failed_flush_epoch = Serial.txLossEpoch();
    if (r19_runtime_diagnostic_bootstrap_pending &&
        failed_flush_epoch !=
            r19_runtime_fail_diagnostic_transport_epoch) {
      if (!r19_restart_completed_runtime_diagnostic_write()) {
        r19_runtime_fail_diagnostic_flush_pending = false;
        r19_fail_diagnostic_transport(
            R19RuntimeDiagnosticTransportFailureReason::
                PublisherWriteStateInvalid,
            flush_completed_ms);
        return;
      }
      r19_increment_runtime_stage_counter(
          R19RuntimeStageCounter::Retry);
      r19_runtime_fail_diagnostic_flush_pending = false;
      r19_runtime_fail_diagnostic_transport_epoch = failed_flush_epoch;
      r19_runtime_diagnostic_frame_deadline_ms = 0U;
      return;
    }
    if (failed_flush_epoch ==
            r19_runtime_fail_diagnostic_transport_epoch &&
        flush_completed_ms < r19_runtime_diagnostic_frame_deadline_ms) {
      // A stable endpoint may need more than one bounded wait to pick up the
      // already-complete frame. Retain publisher completion and retry only
      // flush until the original absolute deadline; never replay payload.
      return;
    }
    const bool recoverable =
        failed_flush_epoch ==
            r19_runtime_fail_diagnostic_transport_epoch &&
        !r19_runtime_diagnostic_pending();
    if (!recoverable) {
      r19_runtime_fail_diagnostic_flush_pending = false;
    }
    r19_fail_diagnostic_transport(
        R19RuntimeDiagnosticTransportFailureReason::FlushFailed,
        flush_completed_ms, __LINE__);
    if (recoverable) {
      (void)r19_arm_diagnostic_transport_recovery(
          R19RuntimeDiagnosticTransportRecovery::FrameFlush,
          r19_runtime_fail_diagnostic_transport_epoch,
          flush_completed_ms);
    }
    return;
  }
  r19_mark_runtime_stage(R19RuntimeStage::FlushCompleted);
  if (Serial.txLossEpoch() != r19_runtime_fail_diagnostic_transport_epoch) {
    if (r19_runtime_diagnostic_bootstrap_pending &&
        r19_restart_completed_runtime_diagnostic_write()) {
      r19_increment_runtime_stage_counter(
          R19RuntimeStageCounter::Retry);
      r19_runtime_fail_diagnostic_flush_pending = false;
      r19_runtime_fail_diagnostic_transport_epoch = Serial.txLossEpoch();
      r19_runtime_diagnostic_frame_deadline_ms = 0U;
      return;
    }
    r19_runtime_fail_diagnostic_flush_pending = false;
    r19_fail_diagnostic_transport(
        R19RuntimeDiagnosticTransportFailureReason::EpochChangedAfterFlush,
        flush_completed_ms);
    return;
  }
  if (flush_completed_ms >= r19_runtime_diagnostic_frame_deadline_ms) {
    const bool recoverable =
        !r19_runtime_diagnostic_pending() &&
        Serial.txLossEpoch() ==
            r19_runtime_fail_diagnostic_transport_epoch;
    r19_fail_diagnostic_transport(
        R19RuntimeDiagnosticTransportFailureReason::FlushCompletedLate,
        flush_completed_ms);
    if (recoverable) {
      (void)r19_arm_diagnostic_transport_recovery(
          R19RuntimeDiagnosticTransportRecovery::FrameFlush,
          r19_runtime_fail_diagnostic_transport_epoch,
          flush_completed_ms);
    }
    return;
  }
  r19_runtime_fail_diagnostic_flush_pending = false;
  if (!r19_runtime_diagnostic_cadence.commit(action,
                                             flush_completed_ms)) {
    r19_fail_diagnostic_transport(
        R19RuntimeDiagnosticTransportFailureReason::CadenceCommitRejected,
        flush_completed_ms);
    return;
  }
  if (action == R19RuntimeDiagnosticAction::FailRepeat) {
    r19_runtime_fail_diagnostic_published = true;
  } else if (!r19_runtime_alive_publisher.reset()) {
    r19_fail_diagnostic_transport(
        R19RuntimeDiagnosticTransportFailureReason::
            AlivePublisherResetRejected,
        flush_completed_ms);
    return;
  }
  r19_runtime_fail_diagnostic_staged = false;
  r19_runtime_diagnostic_bootstrap_pending = false;
  r19_runtime_diagnostic_action = R19RuntimeDiagnosticAction::None;
  r19_runtime_diagnostic_frame_deadline_ms = 0U;
#if defined(VC_LORA_PHASE6_GROUND)
  if (action != R19RuntimeDiagnosticAction::FailRepeat) {
    r19_reset_ground_runtime_alive_reservation();
  }
#endif
  r19_runtime_diagnostic_committed_this_service = true;
#if VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD
  r19_reset_diagnostic_usb_call();
#endif
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
  update_ground_usb_connection(now_ms);
  if (!ground_usb_transport_epoch_healthy(now_ms)) {
    reject_ground_usb_frame(frame, now_ms);
    return;
  }
  const bool primary_heartbeat =
      ground_is_primary_vehicle_heartbeat(frame);
  if (ground_parameter_publish_commit_active &&
      frame.message_id == 22U && ground_usb_can_accept_downlink()) {
    // Do not semantically classify the next stream index until the preceding
    // PARAM_VALUE is physically published. At high RF rates it is a future
    // index only temporarily, so retain the complete descriptor in order.
    const GroundUsbOrderedBacklogStatus status =
        ground_usb_ordered_backlog.enqueue(frame, false);
    if (status != GroundUsbOrderedBacklogStatus::Queued) {
      reject_ground_usb_frame(frame, now_ms);
      latch_runtime_fail_closed();
    }
    return;
  }
  const GroundParameterProxyDisposition preclassification =
      ground_parameter_proxy.preclassify_vehicle_frame(frame, now_ms);
  if (preclassification == GroundParameterProxyDisposition::Consumed) {
    return;
  }
  if (preclassification == GroundParameterProxyDisposition::Invalid) {
    ++link_diagnostics.mavlink_crc_errors;
    return;
  }
  if (!ground_usb_can_accept_downlink()) {
    // HWCDC can accept bytes into its private 256-byte ring without a live
    // host consumer. Reject the complete frame before LocalEgress admission,
    // and report usb_queued=false so a matching proxied #22 cannot advance.
    reject_ground_usb_frame(frame, now_ms);
    return;
  }

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
      latch_runtime_fail_closed();
    }
    return;
  }

  const GroundUsbHeartbeatIngestStatus pace_status =
      ground_usb_heartbeat_pacer.ingest(frame, now_ms);
  if (pace_status == GroundUsbHeartbeatIngestStatus::Invalid) {
    ++link_diagnostics.mavlink_crc_errors;
    return;
  }
  if (pace_status != GroundUsbHeartbeatIngestStatus::PassThrough) {
    latch_runtime_fail_closed();
    return;
  }

  if (!r19_product_usb_publication_allowed() ||
      !ground_usb_ordered_backlog.empty() ||
      ground_usb_heartbeat_pacer.queued() != 0U ||
      ground_paced_heartbeat_commit_active ||
      ground_parameter_publish_commit_active) {
    const GroundUsbOrderedBacklogStatus status =
        ground_usb_ordered_backlog.enqueue(frame, false);
    if (status != GroundUsbOrderedBacklogStatus::Queued) {
      reject_ground_usb_frame(frame, now_ms);
      if (status == GroundUsbOrderedBacklogStatus::Invalid) {
        latch_runtime_fail_closed();
      }
    }
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
#if defined(VC_LORA_PHASE6_VEHICLE)
    // Any physical receive activity during timeout recovery restarts the
    // fixed 650-ms no-transmit interval before cycle advance.
    (void)tdd_controller.note_return_guard_activity(now_ms);
#endif
    const TddDemuxEvent event =
        radio_demux.push(static_cast<std::uint8_t>(value));
#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
    const std::uint8_t r19_route_count =
        static_cast<std::uint8_t>(event.has_bulk_negotiation) +
        static_cast<std::uint8_t>(event.has_bulk_data) +
        static_cast<std::uint8_t>(event.has_terminal_ack) +
        static_cast<std::uint8_t>(event.has_peer_completion_receipt);
    if (r19_route_count > 1U) {
      latch_runtime_fail_closed();
      break;
    }
    if (event.has_bulk_negotiation) {
      (void)r19_route_bulk_negotiation(event, now_ms);
      if (!bridge_ready || runtime_fail_closed) {
        break;
      }
      continue;
    }
    if (event.has_bulk_data) {
      const bool host_frame_staged = r19_route_bulk_data(event, now_ms);
      if (!bridge_ready || runtime_fail_closed) {
        break;
      }
      if (host_frame_staged) {
        return;
      }
      continue;
    }
    if (event.has_terminal_ack) {
      (void)r19_route_terminal_ack(event, now_ms);
      if (!bridge_ready || runtime_fail_closed) {
        break;
      }
      continue;
    }
    if (event.has_peer_completion_receipt) {
      (void)r19_route_peer_completion_receipt(event, now_ms);
      if (!bridge_ready || runtime_fail_closed) {
        break;
      }
      continue;
    }
#endif
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
        const ControlDisposition disposition =
            tdd_controller.on_control(event.control.message, now_ms);
#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
        r19_observe_ground_grant(event.control.message, disposition, now_ms);
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

#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
bool r19_route_pixhawk_output(const HighSpeedPhase6Output& output,
                              std::uint64_t now_ms) noexcept {
  if (output.type != HighSpeedPhase6OutputType::PixhawkWrite ||
      output.semantic !=
          HighSpeedActionType::SendPixhawkParameterRequest ||
      output.token == 0U || output.size == 0U ||
      r19_pixhawk_commit_active) {
    latch_runtime_fail_closed();
    return false;
  }
  MavlinkFrame frame{};
  if (validate_mavlink_frame(output.bytes.data(), output.size, frame) !=
          MavlinkParseStatus::FrameReady ||
      frame.message_id != 21U) {
    latch_runtime_fail_closed();
    return false;
  }
  if (now_ms > std::numeric_limits<std::uint64_t>::max() -
                   kR19PixhawkCommitDeadlineMs) {
    latch_runtime_fail_closed();
    return false;
  }
  auto& egress = radio_application_endpoint.egress();
  const std::uint64_t committed_before = egress.stats().bytes_committed;
  const std::size_t queued_before = egress.queued_bytes();
  if (radio_application_endpoint.admit_validated_frame(frame) !=
          ValidatedLocalIngressStatus::QueuedFrame ||
      r19_vehicle_adapter->complete_output(
          output.token, TxResult::Accepted, now_ms) !=
          HighSpeedPhase6AdapterStatus::AwaitPixhawkCommit) {
    latch_runtime_fail_closed();
    return false;
  }
  r19_pixhawk_commit_active = true;
  r19_pixhawk_commit_token = output.token;
  r19_pixhawk_commit_goal =
      committed_before + static_cast<std::uint64_t>(queued_before) +
      static_cast<std::uint64_t>(frame.size);
  r19_pixhawk_commit_deadline_ms =
      now_ms + kR19PixhawkCommitDeadlineMs;
  return true;
}

void r19_observe_pixhawk_output_tail(std::uint64_t now_ms) noexcept {
  if (!r19_pixhawk_commit_active) {
    return;
  }
  const std::uint64_t observed_ms =
      std::max(now_ms, monotonic_now_ms());
  if (radio_application_endpoint.egress().stats().bytes_committed <
      r19_pixhawk_commit_goal) {
    if (observed_ms >= r19_pixhawk_commit_deadline_ms) {
      latch_runtime_fail_closed();
    }
    return;
  }

  // A complete HardwareSerial write is only FIFO acceptance. Poll the ESP-IDF
  // UART2 drain bit without blocking, and retain the exact adapter action
  // until a bounded physical-tail observation succeeds.
  const esp_err_t status = uart_wait_tx_done(UART_NUM_2, 0);
  if (status == ESP_ERR_TIMEOUT) {
    if (observed_ms >= r19_pixhawk_commit_deadline_ms) {
      latch_runtime_fail_closed();
    }
    return;
  }
  if (status != ESP_OK ||
      observed_ms > r19_pixhawk_commit_deadline_ms) {
    latch_runtime_fail_closed();
    return;
  }
  const std::uint64_t completed_ms = observed_ms;
  const HighSpeedTailDrainEvidence tail{
      r19_pixhawk_commit_token, true, completed_ms};
  r19_pixhawk_commit_active = false;
  r19_pixhawk_commit_token = 0U;
  r19_pixhawk_commit_goal = 0U;
  r19_pixhawk_commit_deadline_ms = 0U;
  if (r19_vehicle_adapter == nullptr ||
      r19_vehicle_adapter->on_pixhawk_request_tail(tail, completed_ms) !=
          HighSpeedPhase6AdapterStatus::BulkEnabled) {
    latch_runtime_fail_closed();
  }
}
#endif

void observe_candidate_pixhawk_output_tail(
    std::uint64_t now_ms) noexcept {
#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
  r19_observe_pixhawk_output_tail(now_ms);
#else
  (void)now_ms;
#endif
}
#else
#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
bool r19_ground_output_is_final_parameter(
    const MavlinkFrame& frame) noexcept {
  if (frame.message_id != 22U || frame.payload_length < 8U) {
    return false;
  }
  const std::uint16_t count = static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(frame.payload_byte_or_zero(4U)) |
      static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(frame.payload_byte_or_zero(5U))
          << 8U));
  const std::uint16_t index = static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(frame.payload_byte_or_zero(6U)) |
      static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(frame.payload_byte_or_zero(7U))
          << 8U));
  return count == BulkSessionAccounting::parameter_count &&
         index + 1U == count;
}

bool r19_route_ground_usb_output(const HighSpeedPhase6Output& output,
                                 std::uint64_t now_ms) noexcept {
  // Preserve the adapter's pending output token while HostArm is pending;
  // never complete/reissue a potentially accepted product payload.
  if (!r19_product_usb_publication_allowed()) return false;
  if (output.type != HighSpeedPhase6OutputType::GroundUsbWrite ||
      output.token == 0U || output.size == 0U ||
      r19_ground_usb_commit_active ||
      !ground_usb_transport_epoch_healthy(now_ms) ||
      !ground_usb_endpoint_ready_state) {
    latch_runtime_fail_closed();
    return false;
  }
  MavlinkFrame frame{};
  if (validate_mavlink_frame(output.bytes.data(), output.size, frame) !=
      MavlinkParseStatus::FrameReady) {
    latch_runtime_fail_closed();
    return false;
  }
  auto& egress = radio_application_endpoint.egress();
  const std::uint64_t committed_before = egress.stats().bytes_committed;
  const std::size_t queued_before = egress.queued_bytes();
  if (radio_application_endpoint.admit_validated_frame(frame) !=
          ValidatedLocalIngressStatus::QueuedFrame ||
      r19_ground_adapter->complete_output(
          output.token, TxResult::Accepted, now_ms) !=
          HighSpeedPhase6AdapterStatus::AwaitUsbCommit) {
    latch_runtime_fail_closed();
    return false;
  }
  r19_ground_usb_commit_active = true;
  r19_ground_usb_commit_final =
      r19_ground_output_is_final_parameter(frame);
  r19_ground_usb_commit_token = output.token;
  r19_ground_usb_commit_loss_epoch = ground_usb_observed_loss_epoch;
  r19_ground_usb_commit_goal =
      committed_before + static_cast<std::uint64_t>(queued_before) +
      static_cast<std::uint64_t>(frame.size);
  constexpr std::uint64_t kR19GroundUsbCommitDeadlineMs = 200U;
  r19_ground_usb_commit_deadline_ms =
      now_ms > std::numeric_limits<std::uint64_t>::max() -
                   kR19GroundUsbCommitDeadlineMs
          ? std::numeric_limits<std::uint64_t>::max()
          : now_ms + kR19GroundUsbCommitDeadlineMs;
  return true;
}

void r19_observe_ground_usb_output_commit(
    std::uint64_t now_ms) noexcept {
  if (!r19_ground_usb_commit_active) {
    return;
  }
  const std::uint64_t observed_ms =
      std::max(now_ms, monotonic_now_ms());
  update_ground_usb_connection(observed_ms);
  if (!r19_ground_usb_commit_active ||
      !ground_usb_transport_epoch_healthy(observed_ms)) {
    return;
  }
  if (observed_ms >= r19_ground_usb_commit_deadline_ms) {
    latch_runtime_fail_closed();
    return;
  }
  if (!ground_usb_endpoint_ready_state ||
      radio_application_endpoint.egress().stats().bytes_committed <
          r19_ground_usb_commit_goal) {
    return;
  }
  const std::uint64_t remaining_ms =
      r19_ground_usb_commit_deadline_ms - observed_ms;
  std::uint64_t completed_ms = observed_ms;
  const bool published = flush_ground_usb_transport(
      r19_ground_usb_commit_loss_epoch,
      static_cast<std::uint32_t>(remaining_ms), completed_ms);
  update_ground_usb_connection(completed_ms);
  if (!published || !ground_usb_endpoint_ready_state ||
      completed_ms > r19_ground_usb_commit_deadline_ms ||
      Serial.txLossEpoch() != r19_ground_usb_commit_loss_epoch) {
    latch_runtime_fail_closed();
    return;
  }
  const GroundUsbHostCommitEvent event{
      r19_ground_usb_commit_token,
      r19_ground_usb_commit_loss_epoch,
      completed_ms};
  const bool final = r19_ground_usb_commit_final;
  r19_ground_usb_commit_active = false;
  r19_ground_usb_commit_final = false;
  r19_ground_usb_commit_token = 0U;
  r19_ground_usb_commit_loss_epoch = 0U;
  r19_ground_usb_commit_goal = 0U;
  r19_ground_usb_commit_deadline_ms = 0U;
  ground_usb_transport_published_bytes =
      radio_application_endpoint.egress().stats().bytes_committed;
  const HighSpeedPhase6AdapterStatus committed =
      final
          ? r19_ground_adapter->on_final_ground_usb_host_commit(
                event, *r19_bulk_decoder, *r19_bulk_transcript,
                *r19_bulk_sla, *r19_terminal_producer)
          : r19_ground_adapter->on_ground_usb_host_commit(event);
  if (committed != (final ? HighSpeedPhase6AdapterStatus::TerminalReady
                          : HighSpeedPhase6AdapterStatus::UsbCommitted)) {
    latch_runtime_fail_closed();
  }
}
#endif

void observe_candidate_ground_usb_output_commit(
    std::uint64_t now_ms) noexcept {
#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
  r19_observe_ground_usb_output_commit(now_ms);
#else
  (void)now_ms;
#endif
}

void service_ground_parameter_proxy(std::uint64_t now_ms) noexcept {
  if (ground_parameter_publish_commit_active) {
    // The saved #22 owns the expected index until its USB publication result
    // is known. Do not let the ordinary response watchdog change that state.
    return;
  }
  // Observe source-FIFO completion before ticking the watchdog, so progress
  // exactly on the deadline is accepted. The second stage remains bounded
  // while waiting for this transaction's explicit UL_DONE UART admission.
  if (ground_proxy_request_admitted &&
      !ground_proxy_request_dequeued &&
      ground_ingress.stats().frames_dequeued >=
          ground_proxy_request_dequeue_goal) {
    if (!ground_parameter_proxy.mark_request_dequeued(
            ground_proxy_request_token, now_ms)) {
      ground_proxy_request_progress_bytes = 0U;
      latch_runtime_fail_closed();
      return;
    }
    ground_proxy_request_dequeued = true;
    ground_proxy_request_done_goal = link_diagnostics.done_tx + 1U;
    ground_proxy_request_progress_bytes = 0U;
  }

  // Admission starts a bounded no-progress watchdog, not a fixed total queue
  // residence timer. Since FIFO order is immutable, every committed byte
  // before this request belongs to the finite prefix which was already ahead
  // of it; later GCS traffic cannot extend the wait from behind the request.
  const std::uint64_t committed_bytes =
      ground_ingress.stats().bytes_committed;
  if (ground_proxy_request_admitted &&
      !ground_proxy_request_dequeued &&
      committed_bytes > ground_proxy_request_progress_bytes) {
    if (!ground_parameter_proxy.mark_request_queue_progress(
            ground_proxy_request_token, now_ms)) {
      ground_proxy_request_progress_bytes = 0U;
      latch_runtime_fail_closed();
      return;
    }
    ground_proxy_request_progress_bytes = committed_bytes;
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
    ground_proxy_request_progress_bytes = 0U;
    return;
  }

  ground_parameter_proxy.tick(now_ms);

  if (ground_proxy_request_admitted &&
      ground_parameter_proxy.request_admission_abandoned(
          ground_proxy_request_token)) {
    // The descriptor FIFO cannot retract an admitted or partially drained
    // frame. Stop all transport activity; reboot clears both the stale bytes
    // and the logical lease, and no duplicate #20 can be generated meanwhile.
    ground_proxy_request_admitted = false;
    ground_proxy_request_dequeued = false;
    ground_proxy_request_token = 0U;
    ground_proxy_request_dequeue_goal = 0U;
    ground_proxy_request_done_goal = 0U;
    ground_proxy_request_progress_bytes = 0U;
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
    ground_proxy_request_progress_bytes =
        ground_ingress.stats().bytes_committed;
    return;
  }

  (void)ground_parameter_proxy.complete_request_tx(
      token, TxResult::Rejected, now_ms);
  // A generated, locally encoded complete frame can only be Queued here.
  // Any other result is an internal/capacity fault, never an input retry.
  latch_runtime_fail_closed();
}

// Both normal GCS ingress and the one clean pre-negotiation decline use this
// exact proxy/descriptor admission path. A Consumed result is not by itself
// proof that a fallback request was admitted; that caller proves the new
// NativeStream lease and its ordinary physical-commit watchdog separately.
bool admit_ground_standard_frame(const MavlinkFrame& frame,
                                 std::uint64_t now_ms) noexcept {
  const GroundParameterProxyDisposition disposition =
      ground_parameter_proxy.on_gcs_frame(frame, now_ms);
  if (disposition == GroundParameterProxyDisposition::Consumed) {
    return true;
  }
  if (disposition == GroundParameterProxyDisposition::Invalid) {
    ++link_diagnostics.mavlink_crc_errors;
    return false;
  }
  const FrameIngressStatus status =
      ground_ingress.admit_validated_frame(frame);
  if (status == FrameIngressStatus::DroppedOverflow ||
      status == FrameIngressStatus::FailClosed || ground_ingress.fail_closed()) {
    latch_runtime_fail_closed();
    return false;
  }
  return status == FrameIngressStatus::Queued;
}

#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
bool r19_service_pre_negotiation_fallback(std::uint64_t now_ms) noexcept {
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
  // This experiment evaluates reservation, never a successful slow fallback.
  (void)now_ms;
  return false;
#else
  if (!bridge_ready || runtime_fail_closed || !r19_product_route_selected ||
      !r19_role_adapter_constructed || r19_ground_adapter == nullptr ||
      !r19_ground_adapter->failure_latched() || r19_acceleration_consumed ||
      !r19_held_parameter_request_valid ||
      r19_pre_negotiation_fallback_count != 0U ||
      !ground_usb_host_present_state || !ground_usb_endpoint_ready_state ||
      r19_held_parameter_request_loss_epoch !=
          static_cast<std::uint64_t>(ground_usb_observed_loss_epoch) ||
      r19_held_parameter_request_loss_epoch !=
          static_cast<std::uint64_t>(Serial.txLossEpoch())) {
    return false;
  }
  const auto& first = r19_ground_adapter->first_failure_diagnostics();
  if (first.event != experimental::GroundHighSpeedDiagnosticEvent::Tick ||
      first.observed_ms != now_ms || !first.request_origin_valid ||
      !first.await_fresh_grant_started_valid ||
      first.request_origin_ms != r19_held_parameter_request_origin_ms ||
      first.await_fresh_grant_started_ms !=
          r19_held_parameter_request_origin_ms ||
      now_ms < r19_held_parameter_request_origin_ms ||
      now_ms - r19_held_parameter_request_origin_ms <=
          BulkSessionTiming::grant_wait_budget_ms ||
      now_ms - r19_held_parameter_request_origin_ms >
          BulkSessionTiming::hard_lease_ms ||
      !first.owner_result_valid || !first.coordinator_result_valid ||
      first.owner_state_before != GroundBulkSessionState::AwaitFreshGrant ||
      first.owner_state_after != GroundBulkSessionState::FailClosed ||
      first.coordinator_state_before != GroundHighSpeedTddState::AwaitFreshGrant ||
      first.coordinator_state_after != GroundHighSpeedTddState::FailClosed ||
      first.owner_result != BulkSessionResult::GrantDeadlineExceeded ||
      first.owner_last_error != BulkSessionResult::GrantDeadlineExceeded ||
      first.coordinator_result != HighSpeedCoordinatorResult::GrantDeadlineExceeded ||
      first.coordinator_last_error != HighSpeedCoordinatorResult::GrantDeadlineExceeded ||
      first.adapter_status != HighSpeedPhase6AdapterStatus::FailClosed ||
      first.adapter_failure_reason != HighSpeedPhase6AdapterStatus::FailClosed ||
      first.fresh_grant_observed_valid || first.coordinator_grant_staged_valid) {
    return false;
  }
  // A possible VCBN prefix is irreversible. Only a never-negotiated local
  // request may decline; no active stream, session, receipt or explicit
  // restoration state can be converted into a standard-path retry.
  if (r19_standard_tdd_frozen || r19_session_owners_constructed ||
      r19_radio_session != nullptr ||
      r19_radio_stream_purpose != R19RadioStreamPurpose::None ||
      r19_radio_buffer_credit_pending || r19_retained_radio_action_final ||
      r19_radio_final_action_committed || r19_radio_final_action_token != 0U ||
      r19_radio_final_writer_generation != 0U ||
      r19_bulk_decoder != nullptr || r19_bulk_transcript != nullptr ||
      r19_bulk_sla != nullptr || r19_terminal_producer != nullptr ||
      r19_ground_usb_commit_active || r19_ground_negotiation_response_pending ||
      r19_peer_receipt_ledger_armed || r19_peer_receipt_proof_delivered ||
      r19_peer_receipt_ledger_kind != PeerCompletionReceiptKind::None ||
      r19_peer_receipt_producer_staged || r19_peer_receipt_standard_tail_pending ||
      r19_peer_receipt_producer_kind != PeerCompletionReceiptKind::None ||
      r19_peer_receipt_send_not_before_ms != 0U ||
      r19_peer_receipt_send_deadline_ms != 0U ||
      r19_standard_resume_not_before_ms != 0U ||
      e220_writer_arbiter.fail_closed() ||
      e220_writer_arbiter.high_speed_active() ||
      e220_writer_arbiter.explicit_restore_required() ||
      e220_writer_arbiter.high_speed_stream_uart_records() != 0U ||
      e220_writer_arbiter.high_speed_stream_accepted_bytes() != 0U) {
    return false;
  }
  // Existing StandardTdd work keeps its exact lease. Queuing the complete
  // request behind that work needs neither takeover nor an unbounded wait.
  const auto& active = e220_writer_arbiter.active_lease();
  if (e220_writer_arbiter.write_active()) {
    if (!active.valid() || active.owner != Phase6RadioWriterOwner::StandardTdd ||
        !standard_radio_writer_lease.valid() ||
        standard_radio_writer_action_type == LinkActionType::None ||
        standard_radio_writer_lease.owner != active.owner ||
        standard_radio_writer_lease.action_token != active.action_token ||
        standard_radio_writer_lease.writer_generation != active.writer_generation) {
      return false;
    }
  } else if (standard_radio_writer_lease.valid() ||
             standard_radio_writer_tail_pending) {
    return false;
  }
  MavlinkFrame checked{};
  const auto& held = r19_held_parameter_request;
  if (validate_mavlink_frame(held.bytes.data(), held.size, checked) !=
          MavlinkParseStatus::FrameReady || checked.message_id != 21U ||
      checked.payload_length != 2U || checked.signed_frame ||
      checked.payload()[0U] == 0U || checked.payload()[1U] == 0U ||
      ground_parameter_proxy.active() || ground_proxy_request_admitted ||
      ground_proxy_request_dequeued || ground_proxy_request_token != 0U ||
      ground_ingress.fail_closed() || !ground_ingress.empty()) {
    return false;
  }
  // The public descriptor API exposes remaining bytes, not the original
  // front-frame length. A nonempty FIFO therefore cannot prove that no
  // application prefix was committed. Decline conservatively rather than
  // reinterpret a suffix or mutate an existing standard transaction.
  const auto leases_before =
      ground_parameter_proxy.diagnostics().native_list_requests_leased;
  if (leases_before == std::numeric_limits<decltype(leases_before)>::max() ||
      !admit_ground_standard_frame(held, now_ms)) {
    return false;
  }
  MavlinkFrame leased{};
  std::uint32_t token = 0U;
  if (!ground_parameter_proxy.peek_next_request(leased, token) || token == 0U ||
      ground_parameter_proxy.diagnostics().native_list_requests_leased !=
          leases_before + 1U || leased.size != held.size ||
      !std::equal(held.bytes.begin(), held.bytes.begin() + held.size,
                  leased.bytes.begin())) {
    return false;
  }
  service_ground_parameter_proxy(now_ms);
  if (!bridge_ready || runtime_fail_closed || !ground_proxy_request_admitted ||
      ground_proxy_request_token != token || ground_ingress.fail_closed() ||
      !ground_usb_host_present_state || !ground_usb_endpoint_ready_state ||
      r19_held_parameter_request_loss_epoch !=
          static_cast<std::uint64_t>(ground_usb_observed_loss_epoch) ||
      r19_held_parameter_request_loss_epoch !=
          static_cast<std::uint64_t>(Serial.txLossEpoch())) {
    // USB reset can race the synchronous proxy/queue admission. The request
    // remains unsent in the ordinary FIFO; preserve it and fail closed rather
    // than mark a changed-epoch handoff successful or attempt a second enqueue.
    return false;
  }
  // This is a decline, not successful R19 completion: never reset/rearm the
  // failed adapter, invent VCRC evidence, or move its original t0/28s lease.
  r19_acceleration_consumed = true;
  r19_product_route_selected = false;
  r19_held_parameter_request_valid = false;
  r19_pre_negotiation_fallback_count = 1U;
  r19_pre_negotiation_fallback_ms = now_ms;
  return true;
#endif
}
#endif

void collect_local_ingress(std::uint64_t now_ms) noexcept {
  std::size_t consumed = 0U;
  while (Serial.available() > 0 && consumed < kLoopReadBudget &&
         bridge_ready) {
    const int value = Serial.read();
    if (value < 0) {
      break;
    }
    ++consumed;
    MavlinkFrame frame{};
    const MavlinkParseStatus parse_status =
        ground_usb_parser.push(static_cast<std::uint8_t>(value), frame);
    if (parse_status != MavlinkParseStatus::FrameReady) {
      if (parse_status == MavlinkParseStatus::BadCrc) {
        ++link_diagnostics.mavlink_crc_errors;
      }
      continue;
    }

#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    if (r19_intercept_usb_clock_request(frame)) continue;
#endif
#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
    if (r19_intercept_ground_usb_frame(frame, now_ms)) {
      continue;
    }
    if (!bridge_ready || runtime_fail_closed) {
      return;
    }
#endif
    (void)admit_ground_standard_frame(frame, now_ms);
  }
  if (bridge_ready) {
    service_ground_parameter_proxy(now_ms);
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
#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
  if (!startup_contract.transmission_allowed() ||
      runtime_fail_closed || wire == nullptr || wire_size == 0U ||
      wire_size > FixedFirmwareContract::radio_chunk_bytes) {
    reject_action(action, payload, application_bytes, now_ms);
    return false;
  }
  bool reuse_reserved_writer = false;
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS && defined(VC_LORA_PHASE6_VEHICLE)
  const auto& lease = e220_writer_arbiter.active_lease();
  reuse_reserved_writer = r19_reserved_grant_releasing &&
      r19_reserved_grant_action_valid &&
      action.type == LinkActionType::SendGrant &&
      action.token == r19_reserved_grant_action.token &&
      action.control.session_id == r19_reserved_grant_action.control.session_id &&
      action.control.cycle_id == r19_reserved_grant_action.control.cycle_id &&
      standard_radio_writer_lease.valid() && lease.valid() &&
      lease.owner == Phase6RadioWriterOwner::StandardTdd &&
      lease.action_token == action.token &&
      lease.writer_generation == standard_radio_writer_lease.writer_generation &&
      !standard_radio_writer_tail_pending;
#endif
  if (radio_busy || pending_radio_action.active ||
      (e220_writer_arbiter.write_active() && !reuse_reserved_writer)) {
    latch_runtime_fail_closed();
    return false;
  }
  if (!reuse_reserved_writer && !acquire_standard_radio_writer_lease(action)) {
    return false;
  }
#else
  if (!startup_contract.transmission_allowed() ||
      runtime_fail_closed || radio_busy || pending_radio_action.active ||
      wire == nullptr || wire_size == 0U ||
      wire_size > FixedFirmwareContract::radio_chunk_bytes) {
    reject_action(action, payload, application_bytes, now_ms);
    return false;
  }
#endif

  r19_observe_e220_aux(now_ms);
  if (e220_write_contract.fail_closed()) {
    latch_runtime_fail_closed();
    return false;
  }
  if (!e220_write_contract.ready_for_write() ||
      e220_serial.availableForWrite() < static_cast<int>(wire_size) ||
      !e220_write_contract.begin_write(wire_size)) {
#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
    if (!release_rejected_standard_radio_writer_lease(now_ms)) {
      return false;
    }
#endif
    reject_action(action, payload, application_bytes, now_ms);
    return false;
  }

#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  const auto write_begin_us = static_cast<std::uint64_t>(esp_timer_get_time());
#endif
  const std::size_t written = e220_serial.write(wire, wire_size);
  const std::uint64_t accepted_at_ms = monotonic_now_ms();
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  r19_note_e220_uart_acceptance(write_begin_us, wire_size, written);
  const auto before_write_result = e220_write_contract.state();
#endif
  const E220WriteDisposition disposition =
      e220_write_contract.report_write_result(written, accepted_at_ms,
                                              aux_high(accepted_at_ms));
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  r19_note_e220_aux_state(before_write_result);
#endif
  if (disposition == E220WriteDisposition::Rejected) {
#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
    if (!release_rejected_standard_radio_writer_lease(accepted_at_ms)) {
      return false;
    }
#endif
    reject_action(action, payload, application_bytes, accepted_at_ms);
    return false;
  }
  if (disposition != E220WriteDisposition::AcceptedAll) {
    latch_runtime_fail_closed();
    return false;
  }

#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
  if (!retain_accepted_standard_radio_writer_lease(accepted_at_ms)) {
    return false;
  }
#endif
  // TxResult::Accepted means the physical UART accepted the complete block.
  // Commit the source/controller at this timestamp. E220WriteContract keeps
  // radio_busy asserted through the observed 550-ms subpacket service floor
  // and stable AUX HIGH; the nominal 180-ms start gap remains a lower bound.
  radio_busy = true;
  pending_radio_action = {action.token, application_bytes, payload, true};
  if (!finish_payload(TxResult::Accepted, accepted_at_ms)) {
    latch_runtime_fail_closed();
    return false;
  }
  return true;
}

void observe_radio_completion(std::uint64_t now_ms) noexcept {
  r19_observe_e220_aux(now_ms);
  if (e220_write_contract.fail_closed()) {
    latch_runtime_fail_closed();
    return;
  }
  if (e220_write_contract.take_write_completion()) {
    if (!radio_busy || pending_radio_action.active) {
      latch_runtime_fail_closed();
      return;
    }
#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
    const bool peer_receipt_tail =
        r19_peer_receipt_standard_tail_pending;
    if (!complete_standard_radio_writer_physical_tail(now_ms)) {
      return;
    }
    if (peer_receipt_tail) {
      if (!r19_peer_receipt_producer.committed() ||
          r19_peer_receipt_producer_kind ==
              PeerCompletionReceiptKind::None ||
          now_ms > std::numeric_limits<std::uint64_t>::max() -
                       BulkSessionTiming::direction_guard_ms) {
        latch_runtime_fail_closed();
        return;
      }
      r19_peer_receipt_standard_tail_pending = false;
      r19_peer_receipt_producer_staged = false;
#if defined(VC_LORA_PHASE6_VEHICLE)
      if (r19_peer_receipt_producer_kind ==
          PeerCompletionReceiptKind::TerminalRecordConsumed) {
        r19_standard_resume_not_before_ms =
            now_ms + BulkSessionTiming::direction_guard_ms;
      }
#endif
    }
#endif
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
#if VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS
  input.inhibit_new_grant=r19_grant_reservation.inhibit_new_grant();
#endif
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

#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
void r19_note_grant_reservation() noexcept {
  (void)vc_lora_r19_grant_reservation_record.observe(
      r19_grant_reservation.snapshot());
}

#if defined(VC_LORA_PHASE6_GROUND)
bool r19_reservation_ground_boundary_clean() noexcept {
  return !r19_product_route_selected && !r19_acceleration_consumed &&
      !ground_parameter_proxy.active() && !ground_proxy_request_admitted &&
      !ground_proxy_request_dequeued && ground_ingress.empty() &&
      !ground_ingress.fail_closed() && !radio_busy && !pending_radio_action.active &&
      !e220_writer_arbiter.write_active() &&
      tdd_controller.state() == GroundTddState::WaitGrant;
}
#endif

void r19_abort_grant_reservation(std::uint32_t detail) noexcept {
  if (!r19_grant_reservation.initialized()) {
    (void)r19_grant_reservation.initialize(
#if defined(VC_LORA_PHASE6_GROUND)
        experimental::R19GrantReservationRole::Ground,
#else
        experimental::R19GrantReservationRole::Vehicle,
#endif
        r19_grant_reservation_boot_id, Serial.txLossEpoch(), monotonic_now_ms());
  }
  r19_grant_reservation.abort(
      experimental::R19GrantReservationReason::ExternalFault,
      monotonic_now_ms(), detail);
  r19_note_grant_reservation();
  latch_runtime_fail_closed();
}

bool r19_intercept_grant_reservation_usb_frame(
    const MavlinkFrame& frame) noexcept {
  using Op = experimental::R19GrantReservationOpcode;
  using Role = experimental::R19GrantReservationRole;
  if (!experimental::r19_is_grant_reservation_namespace(frame)) return false;
  experimental::R19GrantReservationWireMessage command{};
  if (!experimental::r19_decode_grant_reservation_frame(frame.bytes.data(),
          frame.size, false, command) || runtime_fail_closed || !bridge_ready) {
    r19_abort_grant_reservation(2U);
    return true;
  }
  const auto now_ms = monotonic_now_ms();
#if !VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS
  if(command.wire_version!=1U) {
    r19_abort_grant_reservation(15U);return true;
  }
#else
  if(command.wire_version!=2U) {
    r19_abort_grant_reservation(15U);return true;
  }
#endif
  if (!r19_grant_reservation.initialized()) {
    if (command.opcode != Op::HelloRequest) {
      r19_abort_grant_reservation(3U);
      return true;
    }
#if defined(VC_LORA_PHASE6_GROUND)
    if (!r19_usb_readiness_initialized ||
        !r19_host_readiness_gate.allow_ground_usb_product_admission() ||
        !r19_have_ground_usb_heartbeat_commit) {
      r19_abort_grant_reservation(4U);
      return true;
    }
    (void)r19_grant_reservation.initialize(Role::Ground,
#else
    if (!r19_vehicle_usb_clock_seen || r19_vehicle_usb_clock_pending ||
        r19_vehicle_usb_clock_active || r19_vehicle_usb_clock_fault) {
      r19_abort_grant_reservation(5U);
      return true;
    }
    (void)r19_grant_reservation.initialize(Role::Vehicle,
#endif
        r19_grant_reservation_boot_id, Serial.txLossEpoch(), now_ms);
  }
  r19_grant_reservation.observe_local_epoch(Serial.txLossEpoch(), now_ms);
#if VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS
  if(command.opcode==Op::CancelRequest) {
    if(!r19_grant_reservation.cancel_request_matches(command)) {
      r19_abort_grant_reservation(16U);return true;
    }
#if defined(VC_LORA_PHASE6_VEHICLE)
    if(!r19_grant_reservation.cancellation_pending() &&
       !r19_cancel_unwritten_reserved_grant(now_ms)) {
      r19_abort_grant_reservation(17U);return true;
    }
#else
    if(r19_product_route_selected || r19_grant_reservation_negotiation_started ||
       !r19_reservation_ground_boundary_clean()) {
      r19_abort_grant_reservation(18U);return true;
    }
#endif
  }
#endif
#if defined(VC_LORA_PHASE6_GROUND)
  if ((command.opcode == Op::BindGround || command.opcode == Op::BindPeerGround) &&
      !r19_reservation_ground_boundary_clean()) {
    r19_abort_grant_reservation(6U);
    return true;
  }
#endif
  (void)r19_grant_reservation.handle_command(command, now_ms);
  r19_note_grant_reservation();
  if (r19_grant_reservation.failed()) latch_runtime_fail_closed();
  return true;
}

void r19_tick_grant_reservation() noexcept {
  const auto now_ms = monotonic_now_ms();
  r19_observe_e220_aux(now_ms);
  if (r19_grant_reservation.initialized()) {
    r19_grant_reservation.observe_local_epoch(Serial.txLossEpoch(), now_ms);
    (void)r19_grant_reservation.tick(now_ms);
    if (e220_write_contract.fail_closed() || runtime_fail_closed)
      r19_grant_reservation.abort(
          experimental::R19GrantReservationReason::ExternalFault, now_ms, 7U);
    r19_note_grant_reservation();
    if (r19_grant_reservation.failed()) latch_runtime_fail_closed();
  }
}

// One logical 66-byte reply owns USB until whole-frame completion. Partial
// prefixes are never replayed; polling, AUX and original deadlines continue.
bool r19_service_grant_reservation_reply() noexcept {
  if (r19_grant_reservation_reply_fault) return true;
  const auto* reply = r19_grant_reservation.peek_reply();
  if (reply == nullptr) return false;
  auto now_ms = monotonic_now_ms();
  if (!r19_grant_reservation_reply_active) {
    if (r19_runtime_fail_diagnostic_staged ||
        r19_runtime_fail_diagnostic_flush_pending ||
        r19_runtime_fail_diagnostic_transport_failed ||
        r19_runtime_diagnostic_committed_this_service ||
        !Serial.isPlugged() || !static_cast<bool>(Serial)) return false;
#if defined(VC_LORA_PHASE6_GROUND)
    const auto& egress = radio_application_endpoint.egress();
    if (r19_usb_clock_reply_pending || r19_usb_clock_reply_active ||
        r19_usb_clock_reply_fault || ground_paced_heartbeat_commit_active ||
        ground_parameter_publish_commit_active || r19_ground_usb_commit_active ||
        !egress.empty() || egress.write_pending() ||
        egress.stats().bytes_committed != ground_usb_transport_published_bytes)
      return false;
#else
    if (r19_vehicle_usb_clock_pending || r19_vehicle_usb_clock_active ||
        r19_vehicle_usb_clock_fault) return false;
#endif
    if (!experimental::r19_encode_grant_reservation_frame(*reply, true,
            r19_grant_reservation_sequence, r19_grant_reservation_reply)) {
      r19_abort_grant_reservation(8U);
      return true;
    }
    r19_grant_reservation_reply_active = true;
    r19_grant_reservation_reply_offset = 0U;
    r19_grant_reservation_reply_epoch = Serial.txLossEpoch();
    r19_grant_reservation_reply_deadline_ms = now_ms + 106U;
  }
  if (Serial.txLossEpoch() != r19_grant_reservation_reply_epoch ||
      now_ms >= r19_grant_reservation_reply_deadline_ms) {
    r19_grant_reservation_reply_fault = true;
    r19_abort_grant_reservation(9U);
    return true;
  }
  if (r19_grant_reservation_reply_offset < r19_grant_reservation_reply.size) {
    const auto available = Serial.availableForWrite();
    if (available <= 0) return true;
    const auto count = std::min<std::size_t>({32U,
        static_cast<std::size_t>(available), r19_grant_reservation_reply.size -
            r19_grant_reservation_reply_offset});
    const auto written = Serial.writeTxChecked(
        r19_grant_reservation_reply.bytes.data() +
            r19_grant_reservation_reply_offset, count,
        r19_grant_reservation_reply_epoch);
    if (written > count) {
      r19_grant_reservation_reply_fault = true;
      r19_abort_grant_reservation(10U);
      return true;
    }
    r19_grant_reservation_reply_offset += written;
    if (r19_grant_reservation_reply_offset != r19_grant_reservation_reply.size)
      return true;
  }
  now_ms = monotonic_now_ms();
  const auto remaining = now_ms < r19_grant_reservation_reply_deadline_ms
      ? r19_grant_reservation_reply_deadline_ms - now_ms : 0U;
  const bool published = remaining != 0U && Serial.flushTxComplete(
      static_cast<std::uint32_t>(remaining), r19_grant_reservation_reply_epoch);
  if (!published || Serial.txLossEpoch() != r19_grant_reservation_reply_epoch ||
      !Serial.isPlugged() || !static_cast<bool>(Serial) ||
      monotonic_now_ms() > r19_grant_reservation_reply_deadline_ms) {
    r19_grant_reservation_reply_fault = true;
    r19_abort_grant_reservation(11U);
    return true;
  }
  const auto opcode = reply->opcode;
  (void)r19_grant_reservation.pop_reply();
  r19_grant_reservation.note_reply_completed(opcode, monotonic_now_ms());
  ++r19_grant_reservation_sequence;
  r19_grant_reservation_reply_active = false;
  r19_note_grant_reservation();
  if (r19_grant_reservation.failed()) latch_runtime_fail_closed();
  return true;
}

#if defined(VC_LORA_PHASE6_VEHICLE)
bool r19_cancel_unwritten_reserved_grant(std::uint64_t now_ms) noexcept {
  const auto lease=e220_writer_arbiter.active_lease();
  if(!r19_grant_reservation.cancellation_available() ||
     now_ms>=r19_grant_reservation.hold_deadline_ms() ||
     !r19_reserved_grant_action_valid || r19_reserved_grant_uart_accepted ||
     r19_reserved_grant_releasing || radio_busy || pending_radio_action.active ||
     standard_radio_writer_tail_pending ||
     standard_radio_writer_action_type!=LinkActionType::SendGrant ||
     !lease.valid() || lease.owner!=Phase6RadioWriterOwner::StandardTdd ||
     lease.action_token!=r19_reserved_grant_action.token ||
     lease.action_token!=standard_radio_writer_lease.action_token ||
     lease.writer_generation!=standard_radio_writer_lease.writer_generation ||
     Serial.txLossEpoch()!=r19_grant_reservation.snapshot().own_epoch ||
     !r19_grant_reservation.holding()) return false;
  const auto& action=r19_reserved_grant_action;
  if(!tdd_controller.cancel_unsent_grant(action.token,action.control.session_id,
      action.control.cycle_id,now_ms)) return false;
  if(!release_rejected_standard_radio_writer_lease(now_ms)) return false;
  r19_reserved_grant_action_valid=false;
  return true;
}

bool r19_hold_generated_grant(const LinkAction& action,
    std::uint64_t now_ms) noexcept {
  now_ms = monotonic_now_ms();
  if (!r19_grant_reservation.awaiting_grant() ||
      action.type != LinkActionType::SendGrant) return false;
  const auto input = make_tdd_input(now_ms);
  const auto deadline = input.heartbeat_deadline_valid && input.heartbeat_tail_available
      ? std::min(now_ms + 750U, input.heartbeat_deadline_ms)
      : now_ms + 750U;
  if (r19_reserved_grant_action_valid || radio_busy || pending_radio_action.active ||
      !e220_write_contract.ready_for_write() || !aux_high() ||
      deadline <= now_ms || !acquire_standard_radio_writer_lease(action)) {
    r19_abort_grant_reservation(12U);
    return true;
  }
  r19_reserved_grant_action = action;
  r19_reserved_grant_action_valid = true;
  (void)r19_grant_reservation.on_prepared(action.control.session_id,
      action.control.cycle_id, action.token,
      standard_radio_writer_lease.writer_generation, deadline, now_ms);
  r19_note_grant_reservation();
  if (r19_grant_reservation.failed()) latch_runtime_fail_closed();
  return true;
}

bool r19_service_reserved_grant(std::uint64_t now_ms) noexcept {
  now_ms = monotonic_now_ms();
  if (!r19_reserved_grant_action_valid) return false;
  const auto lease = e220_writer_arbiter.active_lease();
  const auto input = make_tdd_input(now_ms);
#if VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS
  using Stop=experimental::R19GrantReservationStopSnapshot;
  Stop stop{};
  stop.now_ms=now_ms;stop.heartbeat_deadline_ms=input.heartbeat_deadline_ms;
  stop.hold_deadline_ms=r19_grant_reservation.hold_deadline_ms();
  stop.heartbeat_order=input.heartbeat_order;
  stop.reserve_ms=FixedFirmwareContract::heartbeat_grant_reserve_ms;
  stop.expected_token=r19_reserved_grant_action.token;
  stop.expected_generation=standard_radio_writer_lease.writer_generation;
  stop.active_token=lease.action_token;stop.active_generation=lease.writer_generation;
  stop.active_owner=static_cast<std::uint32_t>(lease.owner);
  stop.current_usb_epoch=Serial.txLossEpoch();
  stop.predicates=(input.heartbeat_deadline_valid?Stop::heartbeat_valid:0U) |
      (input.heartbeat_tail_available?Stop::heartbeat_available:0U) |
      (input.aux_high?Stop::aux_high:0U) | (lease.valid()?Stop::lease_valid:0U) |
      (r19_grant_reservation.failed()?Stop::reservation_failed:0U) |
      (radio_busy?Stop::radio_busy:0U) |
      (pending_radio_action.active?Stop::pending_action:0U) |
      (standard_radio_writer_tail_pending?Stop::tail_pending:0U) |
      (r19_grant_reservation.should_release()?Stop::release_requested:0U);
  if (experimental::r19_grant_reservation_stop_reason(stop)!=
      experimental::R19GrantReservationStopReason::None) {
#if VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS
    const bool only_heartbeat=experimental::r19_grant_reservation_stop_reason(stop)==
        experimental::R19GrantReservationStopReason::HeartbeatDeadlineConflict &&
        (stop.predicates&Stop::aux_high)!=0U && (stop.predicates&Stop::lease_valid)!=0U &&
        stop.active_owner==1U && stop.active_token==stop.expected_token &&
        stop.active_generation==stop.expected_generation &&
        (stop.predicates&(Stop::radio_busy|Stop::pending_action|Stop::tail_pending))==0U;
    if(only_heartbeat && r19_grant_reservation.cancellation_supported() &&
       r19_cancel_unwritten_reserved_grant(now_ms) &&
       r19_grant_reservation.begin_cancel(now_ms,true)) {
      stop.predicates|=Stop::zero_uart_proven|Stop::old_cycle_retired|Stop::old_lease_retired;
      (void)vc_lora_r19_grant_reservation_stop_record.latch(stop,true);
      r19_note_grant_reservation();return true;
    }
#endif
    // Preserve the legacy journal/first-failure policy. The separate record
    // explains the exact local branch; it neither ignores a new heartbeat nor
    // claims a safe 2500-ms return through the conservative 5050-ms RF path.
#if VC_LORA_R19_GRANT_RESERVATION_STOP_DIAGNOSTICS
    (void)vc_lora_r19_grant_reservation_stop_record.latch(stop);
#endif
    r19_abort_grant_reservation(13U);
    return true;
  }
#else
  const bool heartbeat_urgent=input.heartbeat_deadline_valid &&
      input.heartbeat_tail_available && (input.heartbeat_deadline_ms<=now_ms ||
      input.heartbeat_deadline_ms-now_ms<=FixedFirmwareContract::heartbeat_grant_reserve_ms);
  if(r19_grant_reservation.failed() || heartbeat_urgent || !input.aux_high ||
     !lease.valid() || lease.owner!=Phase6RadioWriterOwner::StandardTdd ||
     lease.action_token!=r19_reserved_grant_action.token ||
     lease.writer_generation!=standard_radio_writer_lease.writer_generation ||
     radio_busy || pending_radio_action.active || standard_radio_writer_tail_pending) {
    r19_abort_grant_reservation(13U);return true;
  }
#endif
  if (!r19_grant_reservation.should_release()) return true;
  r19_reserved_grant_releasing = true;
  process_action(r19_reserved_grant_action, now_ms);
  r19_reserved_grant_releasing = false;
  r19_reserved_grant_action_valid = false;
  if (!r19_reserved_grant_uart_accepted || runtime_fail_closed)
    r19_abort_grant_reservation(14U);
  return true;
}
#endif
#endif

#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS && defined(VC_LORA_PHASE6_GROUND)
// Exclusive, bounded writer for a 28-byte clock reply or 66-byte READY record.
// Keep each API write within the SDK's 32-byte limit without splitting the
// logical frame or replaying an accepted prefix. Faults retain ownership rather
// than inserting another diagnostic/product frame or resuming normal traffic.
bool r19_service_usb_clock_reply() noexcept {
  if (r19_usb_clock_reply_fault) return true;
  if (!r19_usb_clock_reply_active && !r19_usb_clock_reply_pending) return false;
  const auto now_ms = monotonic_now_ms();
  if (!r19_usb_clock_reply_active) {
    const auto& egress = radio_application_endpoint.egress();
    if (r19_runtime_fail_diagnostic_staged ||
        r19_runtime_fail_diagnostic_flush_pending ||
        r19_runtime_fail_diagnostic_transport_failed ||
        r19_runtime_diagnostic_committed_this_service ||
        ground_paced_heartbeat_commit_active ||
        ground_parameter_publish_commit_active || r19_ground_usb_commit_active ||
        !egress.empty() || egress.write_pending() ||
        egress.stats().bytes_committed != ground_usb_transport_published_bytes ||
        (runtime_fail_closed && r19_runtime_fail_ground_boundary_status !=
            R19RuntimeFailGroundBoundaryStatus::Clean) ||
        !Serial.isPlugged() || !static_cast<bool>(Serial)) return false;
    r19_usb_clock_reply_active = true;
    r19_usb_clock_reply_pending = false;
    r19_usb_clock_reply_offset = 0U;
    r19_usb_clock_reply_epoch = Serial.txLossEpoch();
    r19_usb_clock_reply_deadline_ms =
        now_ms > std::numeric_limits<std::uint64_t>::max() - 500U
            ? std::numeric_limits<std::uint64_t>::max() : now_ms + 500U;
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
    if (r19_usb_private_reply_kind == R19UsbPrivateReplyKind::Ready)
      r19_note_usb_readiness_event(R19UsbReadinessEvent::ReadyPublishBegin,
          r19_usb_clock_reply_epoch,
          static_cast<std::uint32_t>(r19_usb_clock_reply.size));
#endif
  }
  if (Serial.txLossEpoch() != r19_usb_clock_reply_epoch ||
      now_ms >= r19_usb_clock_reply_deadline_ms) {
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
    r19_note_usb_readiness_event(R19UsbReadinessEvent::ReadySuppressed,
        1U, Serial.txLossEpoch(), r19_usb_clock_reply_epoch,
        static_cast<std::uint32_t>(r19_usb_private_reply_kind));
#endif
    r19_usb_clock_reply_fault = true;
    return true;
  }
  if (r19_usb_clock_reply_offset < r19_usb_clock_reply.size) {
    const int available = Serial.availableForWrite();
    if (available <= 0) return true;
    const auto remaining = r19_usb_clock_reply.size - r19_usb_clock_reply_offset;
    const auto count = std::min(
        {remaining, static_cast<std::size_t>(available),
         kR19RuntimeFailDiagnosticWriteChunkBytes});
    const auto accepted = Serial.writeTxChecked(
        r19_usb_clock_reply.bytes.data() + r19_usb_clock_reply_offset,
        count, r19_usb_clock_reply_epoch);
    if (accepted > count) {
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
      r19_note_usb_readiness_event(R19UsbReadinessEvent::ReadySuppressed,
          2U, static_cast<std::uint32_t>(accepted),
          static_cast<std::uint32_t>(count),
          static_cast<std::uint32_t>(r19_usb_private_reply_kind));
#endif
      r19_usb_clock_reply_fault = true; return true;
    }
    r19_usb_clock_reply_offset += accepted;
    if (r19_usb_clock_reply_offset != r19_usb_clock_reply.size) return true;
  }
  const auto remaining_ms = r19_usb_clock_reply_deadline_ms - now_ms;
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  const auto diagnostic_flush_budget_ms = static_cast<std::uint32_t>(
      std::min<std::uint64_t>(remaining_ms, 100U));
  const auto diagnostic_deadline_us = std::min(r19_usb_clock_reply_deadline_ms,
      std::numeric_limits<std::uint64_t>::max() / 1000U) * 1000U;
  r19_note_usb_readiness_event(R19UsbReadinessEvent::ClockFlushContext,
      diagnostic_flush_budget_ms, r19_usb_clock_reply_epoch,
      static_cast<std::uint32_t>(diagnostic_deadline_us),
      static_cast<std::uint32_t>(diagnostic_deadline_us >> 32U));
  r19_note_usb_readiness_event(R19UsbReadinessEvent::ClockFlushBegin,
      static_cast<std::uint32_t>(r19_usb_private_reply_kind),
      r19_usb_clock_reply_epoch,
      static_cast<std::uint32_t>(r19_usb_clock_reply.size),
      static_cast<std::uint32_t>(r19_usb_clock_reply_offset));
#endif
  const bool complete = Serial.flushTxComplete(
      static_cast<std::uint32_t>(std::min<std::uint64_t>(remaining_ms,100U)),
      r19_usb_clock_reply_epoch);
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  r19_note_usb_readiness_event(R19UsbReadinessEvent::ClockFlushEnd,
      complete ? 1U : 0U, Serial.txLossEpoch(),
      static_cast<std::uint32_t>(r19_usb_private_reply_kind));
#endif
  if (complete && Serial.txLossEpoch() == r19_usb_clock_reply_epoch &&
      monotonic_now_ms() <= r19_usb_clock_reply_deadline_ms) {
    r19_usb_clock_reply_active = false;
    ++r19_usb_clock_sequence;
#if VC_LORA_R19_USB_READINESS_MODE != 0
    if (r19_usb_private_reply_kind == R19UsbPrivateReplyKind::Clock) {
      const auto completed_us =
          static_cast<std::uint64_t>(esp_timer_get_time());
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
      const auto before_gate = r19_host_readiness_gate.snapshot().state;
#endif
      const bool gate_updated = r19_host_readiness_gate.record_clock_reply(
              r19_usb_clock_reply_nonce, r19_usb_clock_reply_device_us,
              r19_usb_clock_reply_epoch, completed_us);
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
      r19_note_usb_readiness_event(R19UsbReadinessEvent::GateUpdate,
          static_cast<std::uint32_t>(before_gate),
          static_cast<std::uint32_t>(r19_host_readiness_gate.snapshot().state),
          gate_updated ? 1U : 0U, r19_usb_clock_reply_epoch);
#endif
      if (!gate_updated) {
        r19_usb_clock_reply_fault = true;
        return true;
      }
#if VC_LORA_R19_USB_READINESS_MODE == 2
      experimental::R19HostReadinessCommand ready{};
      const bool ready_command_ok = r19_host_readiness_gate.ready_command(ready);
      const bool ready_encoded = ready_command_ok &&
          experimental::r19_encode_host_readiness_frame(
              r19_usb_clock_sequence, ready, r19_usb_clock_reply);
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
      r19_note_usb_readiness_event(R19UsbReadinessEvent::ReadyEncode,
          ready_command_ok ? 1U : 0U, ready_encoded ? 1U : 0U,
          r19_usb_clock_reply_epoch,
          static_cast<std::uint32_t>(r19_usb_clock_reply.size));
#endif
      if (!ready_encoded) {
        r19_usb_clock_reply_fault = true;
        return true;
      }
      // Same exact-once writer and clean boundary; no diagnostic/product
      // writer can run between this reply and its binding READY record.
      r19_usb_private_reply_kind = R19UsbPrivateReplyKind::Ready;
      r19_usb_clock_reply_pending = true;
#endif
    } else {
      r19_usb_ready_publication_complete = true;
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
      r19_note_usb_readiness_event(R19UsbReadinessEvent::ReadyPublishEnd,
          1U, r19_usb_clock_reply_epoch,
          static_cast<std::uint32_t>(r19_usb_clock_reply.size));
#endif
    }
#endif
  }
  return true;
}

void r19_observe_ground_aux_without_completion() noexcept {
  // USB-owned and fail-closed exits still observe the physical AUX state.
  // Do not consume completion, release an RF lease/tail, or progress traffic.
  r19_observe_e220_aux(monotonic_now_ms());
  if (e220_write_contract.fail_closed()) {
    latch_runtime_fail_closed();
  }
}

bool r19_observe_usb_clock_reply_service() noexcept {
  // A pending READY also owns the boundary when its start is blocked and the
  // service returns false. Preserve that ownership while observing AUX only.
  const bool private_boundary_held =
      r19_usb_clock_reply_active || r19_usb_clock_reply_fault
#if VC_LORA_R19_USB_READINESS_MODE == 2
      || (r19_usb_clock_reply_pending &&
          r19_usb_private_reply_kind == R19UsbPrivateReplyKind::Ready)
#endif
      ;
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  const auto begin_us = static_cast<std::uint64_t>(esp_timer_get_time());
#endif
  const bool occupied = r19_service_usb_clock_reply();
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  (void)vc_lora_r19_aux_readiness_record.ready.interval(
      R19UsbIntervalKind::PrivateReply, begin_us,
      static_cast<std::uint64_t>(esp_timer_get_time()), occupied);
#endif
  if (occupied || private_boundary_held) {
    // Do not consume radio completion or release a physical writer/lease here.
    // Keep the normal-observer bypass diagnostic distinct from this sample.
    r19_observe_e220_aux(monotonic_now_ms());
    if (e220_write_contract.fail_closed()) {
      latch_runtime_fail_closed();
    }
  }
  return occupied;
}
#endif

#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS && \
    defined(VC_LORA_PHASE6_VEHICLE) && VC_LORA_R19_USB_READINESS_MODE != 0
bool r19_service_vehicle_usb_clock_reply() noexcept {
  if (r19_vehicle_usb_clock_fault) return true;
  if (!r19_vehicle_usb_clock_active && !r19_vehicle_usb_clock_pending)
    return false;
  const auto now_ms = monotonic_now_ms();
  if (!r19_vehicle_usb_clock_active) {
    // A retained 63-byte diagnostic prefix or flush owns USB until its
    // existing recovery releases it. Never insert a clock reply into it.
    if (r19_runtime_fail_diagnostic_staged ||
        r19_runtime_fail_diagnostic_flush_pending ||
        r19_runtime_fail_diagnostic_transport_failed ||
        r19_runtime_diagnostic_committed_this_service ||
        r19_runtime_diagnostic_bootstrap_pending ||
        !Serial.isPlugged() || !static_cast<bool>(Serial)) return false;
    if (Serial.txLossEpoch() != r19_vehicle_usb_clock_epoch ||
        now_ms > std::numeric_limits<std::uint64_t>::max() -
            kR19RuntimeDiagnosticFrameBudgetMs) {
      r19_vehicle_usb_clock_fault = true;
      return true;
    }
    r19_vehicle_usb_clock_pending = false;
    r19_vehicle_usb_clock_active = true;
    r19_vehicle_usb_clock_offset = 0U;
    r19_vehicle_usb_clock_deadline_ms =
        now_ms + kR19RuntimeDiagnosticFrameBudgetMs;
  }
  if (Serial.txLossEpoch() != r19_vehicle_usb_clock_epoch ||
      now_ms >= r19_vehicle_usb_clock_deadline_ms) {
    r19_vehicle_usb_clock_fault = true;
    return true;
  }
  if (r19_vehicle_usb_clock_offset < r19_vehicle_usb_clock_reply.size) {
    const int available = Serial.availableForWrite();
    if (available <= 0) return true;
    const auto count = std::min({
        r19_vehicle_usb_clock_reply.size - r19_vehicle_usb_clock_offset,
        static_cast<std::size_t>(available),
        kR19RuntimeFailDiagnosticWriteChunkBytes});
    const auto accepted = Serial.writeTxChecked(
        r19_vehicle_usb_clock_reply.bytes.data() + r19_vehicle_usb_clock_offset,
        count, r19_vehicle_usb_clock_epoch);
    if (accepted > count) {
      r19_vehicle_usb_clock_fault = true;
      return true;
    }
    r19_vehicle_usb_clock_offset += accepted;
    if (r19_vehicle_usb_clock_offset < r19_vehicle_usb_clock_reply.size)
      return true;
  }
  const auto flush_started_ms = monotonic_now_ms();
  if (flush_started_ms >= r19_vehicle_usb_clock_deadline_ms) {
    r19_vehicle_usb_clock_fault = true;
    return true;
  }
  const auto budget = static_cast<std::uint32_t>(std::min(
      r19_vehicle_usb_clock_deadline_ms - flush_started_ms,
      static_cast<std::uint64_t>(kR19RuntimeFailDiagnosticFlushBudgetMs)));
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  const auto deadline_us = r19_vehicle_usb_clock_deadline_ms * 1000U;
  r19_note_usb_readiness_event(R19UsbReadinessEvent::ClockFlushContext,
      budget, r19_vehicle_usb_clock_epoch,
      static_cast<std::uint32_t>(deadline_us),
      static_cast<std::uint32_t>(deadline_us >> 32U));
  r19_note_usb_readiness_event(R19UsbReadinessEvent::ClockFlushBegin,
      0U, r19_vehicle_usb_clock_epoch,
      static_cast<std::uint32_t>(r19_vehicle_usb_clock_reply.size),
      static_cast<std::uint32_t>(r19_vehicle_usb_clock_offset));
#endif
  const bool complete = Serial.flushTxComplete(budget,
      r19_vehicle_usb_clock_epoch);
  const auto completed_ms = monotonic_now_ms();
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  r19_note_usb_readiness_event(R19UsbReadinessEvent::ClockFlushEnd,
      complete ? 1U : 0U, Serial.txLossEpoch(), 0U, 0U);
#endif
  if (Serial.txLossEpoch() != r19_vehicle_usb_clock_epoch ||
      completed_ms > r19_vehicle_usb_clock_deadline_ms) {
    r19_vehicle_usb_clock_fault = true;
  } else if (complete) {
    r19_vehicle_usb_clock_active = false;
  }
  return true;
}

bool r19_observe_vehicle_usb_clock_reply_service() noexcept {
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  const auto begin_us = static_cast<std::uint64_t>(esp_timer_get_time());
#endif
  const bool occupied = r19_service_vehicle_usb_clock_reply();
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  (void)vc_lora_r19_aux_readiness_record.ready.interval(
      R19UsbIntervalKind::PrivateReply, begin_us,
      static_cast<std::uint64_t>(esp_timer_get_time()), occupied);
#endif
  if (occupied) {
    // Observe only: do not consume RF completion or release writer ownership.
    r19_observe_e220_aux(monotonic_now_ms());
    if (e220_write_contract.fail_closed()) latch_runtime_fail_closed();
  }
  return occupied;
}
#endif

void setup_bridge() noexcept {
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  r19_initialize_runtime_stage_record();
#endif
  digitalWrite(kE220M0Pin, HIGH);
  digitalWrite(kE220M1Pin, HIGH);
  pinMode(kE220M0Pin, OUTPUT);
  pinMode(kE220M1Pin, OUTPUT);
  pinMode(kE220AuxPin, INPUT_PULLUP);
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  r19_attach_aux_readiness_irq();
#endif

#if defined(VC_LORA_PHASE6_GROUND)
  // This USB CDC stream is exclusively valid Mission Planner MAVLink. The
  // default and deployable builds never emit text or diagnostics. An explicit
  // non-deployable R19 diagnostic candidate may emit standard STATUSTEXT
  // liveness/failure frames only at a proved-clean USB frame boundary.
  Serial.begin(FixedFirmwareContract::pixhawk_uart_bps);
#elif VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  // Vehicle COM3 is independent of D6/D7 Pixhawk UART and the E220 UART.
  Serial.begin(kR19RuntimeFailDiagnosticVehicleBaud);
#endif
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  r19_mark_runtime_stage(R19RuntimeStage::SerialBeginReturned);
#if defined(VC_LORA_PHASE6_GROUND) && VC_LORA_R19_USB_READINESS_MODE != 0
  r19_begin_usb_readiness_diagnostic();
#endif
  const std::uint64_t diagnostic_start_ms = monotonic_now_ms();
  if (!r19_runtime_diagnostic_cadence.start(diagnostic_start_ms)) {
    r19_fail_diagnostic_transport(
        R19RuntimeDiagnosticTransportFailureReason::CadenceStartRejected,
        diagnostic_start_ms);
  } else {
    r19_mark_runtime_stage(R19RuntimeStage::CadenceStarted);
  }
#endif

  const bool identity_ready = provision_boot_identity(boot_identity);
  startup_contract.confirm_identity_persisted(identity_ready);
  const bool e220_profile_ready = prepare_and_verify_e220_profile();
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  if (identity_ready) {
    r19_mark_runtime_stage(R19RuntimeStage::IdentityReady);
  }
  if (e220_profile_ready) {
    r19_mark_runtime_stage(R19RuntimeStage::E220ProfileChecked);
  }
#else
  (void)e220_profile_ready;
#endif
  if (!startup_contract.transmission_allowed()) {
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    capture_r19_startup_contract_failure();
#endif
    return;
  }
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  r19_mark_runtime_stage(R19RuntimeStage::StartupAllowed);
#endif

  start_e220_normal_mode();
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  r19_mark_runtime_stage(R19RuntimeStage::E220NormalMode);
#endif
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
  const bool raw_host_present = ground_usb_host_present_now();
  ground_usb_host_presence_filter.reset(raw_host_present, now_ms);
  ground_usb_host_present_state =
      ground_usb_host_presence_filter.confirmed_present();
  ground_usb_endpoint_ready_state =
      ground_usb_endpoint_ready_now(raw_host_present);
  ground_usb_observed_loss_epoch = Serial.txLossEpoch();
  ground_usb_transport_published_bytes =
      radio_application_endpoint.egress().stats().bytes_committed;
  ground_usb_heartbeat_pacer.set_usb_connected(
      ground_usb_host_present_state, now_ms);
  ground_usb_parser = {};
  ground_radio_application_parser = {};
  ground_paced_heartbeat_commit_active = false;
  ground_paced_heartbeat_commit_token = 0U;
  ground_paced_heartbeat_commit_goal = 0U;
  ground_paced_heartbeat_commit_deadline_ms = 0U;
  ground_paced_heartbeat_commit_loss_epoch = 0U;
  ground_parameter_publish_commit_active = false;
  ground_parameter_publish_commit_frame = {};
  ground_parameter_publish_commit_goal = 0U;
  ground_parameter_publish_commit_deadline_ms = 0U;
  ground_parameter_publish_commit_loss_epoch = 0U;
  ground_proxy_request_admitted = false;
  ground_proxy_request_dequeued = false;
  ground_proxy_request_token = 0U;
  ground_proxy_request_dequeue_goal = 0U;
  ground_proxy_request_done_goal = 0U;
  ground_proxy_request_progress_bytes = 0U;
#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
  r19_have_ground_usb_heartbeat_commit = false;
  r19_last_ground_usb_heartbeat_commit_ms = 0U;
#endif
  tdd_controller.reset(now_ms);
#endif
#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
  if (!setup_r19_high_speed_role_adapter()) {
    return;
  }
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  r19_mark_runtime_stage(R19RuntimeStage::AdapterReady);
#endif
#endif
  r19_observe_e220_aux(now_ms);
  bridge_ready = !e220_write_contract.fail_closed();
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  if (!bridge_ready) {
    latch_runtime_fail_closed();
  } else {
    r19_mark_runtime_stage(R19RuntimeStage::SetupComplete);
  }
#endif
}

void loop_bridge() noexcept {
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  R19AuxReadinessIntervalScope loop_interval(R19UsbIntervalKind::Loop);
#endif
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
  // Do not let an unrelated private USB reply conceal AUX transitions or a
  // reservation expiry. Complete only the genuine existing RF tail service.
  r19_tick_grant_reservation();
  if (bridge_ready && !runtime_fail_closed)
    observe_radio_completion(monotonic_now_ms());
  if (r19_grant_reservation_reply_active || r19_grant_reservation_reply_fault) {
    (void)r19_service_grant_reservation_reply();
    return;
  }
#endif
  r19_increment_runtime_stage_counter(R19RuntimeStageCounter::Loop);
  r19_mark_runtime_stage(R19RuntimeStage::LoopEntered);
#if defined(VC_LORA_PHASE6_GROUND)
  r19_collect_failed_usb_clock_requests();
  if (r19_usb_clock_reply_active || r19_usb_clock_reply_fault
#if VC_LORA_R19_USB_READINESS_MODE == 2
      || (r19_usb_clock_reply_pending &&
          r19_usb_private_reply_kind == R19UsbPrivateReplyKind::Ready)
#endif
      ) {
    (void)r19_observe_usb_clock_reply_service();
    return;
  }
#elif VC_LORA_R19_USB_READINESS_MODE != 0
  r19_collect_vehicle_usb_clock_requests();
  if (r19_vehicle_usb_clock_active || r19_vehicle_usb_clock_fault) {
    (void)r19_observe_vehicle_usb_clock_reply_service();
    return;
  }
#endif
  {
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
    R19AuxReadinessIntervalScope diagnostic_interval(
        R19UsbIntervalKind::RuntimeDiagnostic, false);
#endif
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
    if (r19_grant_reservation.peek_reply() == nullptr ||
        r19_runtime_fail_diagnostic_staged ||
        r19_runtime_fail_diagnostic_flush_pending || runtime_fail_closed)
#endif
      r19_service_runtime_fail_diagnostic();
  }
#if defined(VC_LORA_PHASE6_GROUND)
  if (r19_observe_usb_clock_reply_service()) return;
  // COM6 is shared with Mission Planner. Never allow normal USB egress to
  // interleave between the fixed 32+31 byte diagnostic suffix writes. A
  // diagnostic transport fault after any possible prefix owns the boundary;
  // only the bounded same-epoch, flush-only recovery above may release it.
  if (r19_runtime_fail_diagnostic_staged ||
      r19_runtime_fail_diagnostic_flush_pending ||
      r19_runtime_fail_diagnostic_transport_failed ||
      r19_runtime_diagnostic_committed_this_service) {
    r19_observe_ground_aux_without_completion();
    return;
  }
  if (r19_ground_runtime_alive_reservation_pending()) {
    {
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
      R19AuxReadinessIntervalScope drain_interval(R19UsbIntervalKind::AliveDrain);
#endif
      r19_drain_ground_runtime_alive_boundary(monotonic_now_ms());
    }
    r19_observe_ground_aux_without_completion();
    return;
  }
#elif VC_LORA_R19_USB_READINESS_MODE != 0
  if (r19_observe_vehicle_usb_clock_reply_service()) return;
#endif
#endif
  if (!bridge_ready || runtime_fail_closed) {
#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS && defined(VC_LORA_PHASE6_GROUND)
    r19_observe_ground_aux_without_completion();
#endif
    return;
  }
  const std::uint64_t now_ms = monotonic_now_ms();
  observe_radio_completion(now_ms);
#if VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
  loop_interval.normal_aux_observed();
#endif
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
  update_ground_usb_connection(now_ms);
  if (!ground_usb_runtime_healthy_or_retire(now_ms)) {
    return;
  }
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
  observe_candidate_pixhawk_output_tail(now_ms);
#else
  service_ground_usb_heartbeat_pacer(now_ms);
  if (!ground_usb_runtime_healthy_or_retire(now_ms)) {
    return;
  }
  pump_ground_usb_egress(now_ms);
  if (!ground_usb_runtime_healthy_or_retire(now_ms)) {
    return;
  }
  observe_ground_paced_heartbeat_commit(now_ms);
  observe_ground_parameter_publish_commit(now_ms);
  observe_candidate_ground_usb_output_commit(now_ms);
  if (!ground_usb_runtime_healthy_or_retire(now_ms)) {
    return;
  }
  // If the first pump completed the active normal frame, admit and write the
  // due HB at that exact frame boundary instead of waiting another loop.
  service_ground_usb_heartbeat_pacer(now_ms);
  if (!ground_usb_runtime_healthy_or_retire(now_ms)) {
    return;
  }
  pump_ground_usb_egress(now_ms);
  if (!ground_usb_runtime_healthy_or_retire(now_ms)) {
    return;
  }
  observe_ground_paced_heartbeat_commit(now_ms);
  observe_ground_parameter_publish_commit(now_ms);
  observe_candidate_ground_usb_output_commit(now_ms);
  if (!ground_usb_runtime_healthy_or_retire(now_ms)) {
    return;
  }
#endif
  if (!bridge_ready) {
    return;
  }
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS
  if (r19_service_grant_reservation_reply()) return;
#if defined(VC_LORA_PHASE6_VEHICLE)
  if (r19_service_reserved_grant(now_ms)) return;
#endif
#endif
#if VC_LORA_R19_HIGH_SPEED_CANDIDATE
  r19_service_high_speed_product_route(now_ms);
  if (!bridge_ready || runtime_fail_closed) {
    return;
  }
  if (!r19_standard_tdd_tick_allowed()) {
    return;
  }
#endif
  const LinkAction action = tdd_controller.tick(make_tdd_input(now_ms));
#if VC_LORA_R19_GRANT_DIAGNOSTICS && defined(VC_LORA_PHASE6_VEHICLE)
  if (action.type == LinkActionType::SendGrant) {
    (void)vc_lora_r19_grant_diagnostic_record.observe_grant_event(
        experimental::R19GrantDiagnosticEvent::GrantGenerated, now_ms,
        action.control.session_id, action.control.cycle_id,
        action.token, 0U, __LINE__);
  }
#endif
#if VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS && defined(VC_LORA_PHASE6_VEHICLE)
  if (r19_hold_generated_grant(action, now_ms)) return;
#endif
#if !defined(VC_LORA_PHASE6_VEHICLE)
  // Once a DATA prefix has been physically accepted it cannot be rolled back.
  // If UART readiness/zero-write rejection prevents DATA+UL_DONE from
  // completing inside the absolute Vehicle receive lease, the controller
  // latches an abandoned transaction. Propagate that fault before any later
  // frame can be admitted or a partial terminal can be emitted.
  if (tdd_controller.fail_closed()) {
    latch_runtime_fail_closed();
    return;
  }
#endif
  process_action(action, now_ms);
#if defined(VC_LORA_PHASE6_VEHICLE)
  synchronize_vehicle_uplink_recovery();
#endif
  // Cover timeout/action transitions that close a receive window without an
  // accompanying radio byte in this loop iteration.
  reset_closed_radio_ingress();
}

#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
#undef latch_runtime_fail_closed
#endif

}  // namespace vc_lora_phase6_firmware

void setup() { vc_lora_phase6_firmware::setup_bridge(); }

void loop() { vc_lora_phase6_firmware::loop_bridge(); }
