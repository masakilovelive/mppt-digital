#include "test_support.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>

#include "vc_lora/runtime_contract.hpp"

namespace vc_lora::test {
namespace {

void finish_report(TestReport& report, const std::string& detail) {
  report.detail = detail;
  report.trace.record({0, "host", "FW_RUNTIME_CONTRACT", 0,
                       report.passed ? "PASS" : "FAIL", true, 0, 0, 0});
}

void test_session_contract(TestReport& report) {
  const BootSessionIdentity empty{};
  BootSessionProvisioner first_boot{empty, true};
  report.check(first_boot.status() == BootSessionStatus::AwaitingPersistence,
               "first boot did not wait for durable persistence");
  report.check(first_boot.candidate_for_persistence().boot_id == 1U,
               "zero boot ID was not skipped on first boot");
  report.check(first_boot.candidate_for_persistence().session_id == 1U,
               "zero session ID was not skipped on first boot");

  BootSessionIdentity leased{77U, 77U};
  report.check(!first_boot.lease(leased),
               "identity became usable before persistence confirmation");
  report.check(leased.boot_id == 77U && leased.session_id == 77U,
               "failed lease modified the caller output");
  first_boot.confirm_persisted(true);
  report.check(first_boot.lease(leased),
               "durably persisted identity did not become usable");
  report.check(leased.boot_id == 1U && leased.session_id == 1U,
               "leased first-boot identity is incorrect");

  BootSessionProvisioner ordinary{{41U, 0x1234U}, true};
  report.check(ordinary.candidate_for_persistence().boot_id == 42U,
               "boot ID did not advance monotonically");
  report.check(ordinary.candidate_for_persistence().session_id == 0x1235U,
               "session ID did not advance monotonically");

  BootSessionProvisioner wrapped{
      {std::numeric_limits<std::uint32_t>::max(),
       std::numeric_limits<std::uint16_t>::max()},
      true};
  report.check(wrapped.candidate_for_persistence().boot_id == 1U,
               "boot ID wrap did not skip zero");
  report.check(wrapped.candidate_for_persistence().session_id == 1U,
               "session ID wrap did not skip zero");

  BootSessionProvisioner read_failed{{12U, 13U}, false};
  report.check(read_failed.fail_closed(),
               "persistent-state read failure did not fail closed");
  report.check(read_failed.fault() == BootSessionFault::PersistentReadFailed,
               "persistent read failure reported the wrong fault");
  read_failed.confirm_persisted(true);
  report.check(!read_failed.lease(leased),
               "failed persistent read recovered without a reboot");

  BootSessionProvisioner write_failed{{12U, 13U}, true};
  write_failed.confirm_persisted(false);
  report.check(write_failed.fail_closed(),
               "persistent-state write failure did not fail closed");
  report.check(write_failed.fault() == BootSessionFault::PersistentWriteFailed,
               "persistent write failure reported the wrong fault");

  finish_report(report,
                "nonzero persistent boot/session sequence, transactional "
                "activation, wrap, and storage fail-close");
}

void test_time_contract(TestReport& report) {
  MonotonicMillis32 clock{};
  std::uint64_t now = 0U;
  report.check(clock.sample(0xFFFFFFF0U, now),
               "initial 32-bit clock sample was rejected");
  report.check(now == 0xFFFFFFF0ULL,
               "initial 32-bit clock sample was extended incorrectly");
  report.check(clock.sample(0xFFFFFFFFU, now) &&
                   now == 0xFFFFFFFFULL,
               "pre-wrap time did not remain monotonic");
  report.check(clock.sample(0U, now) && now == 0x100000000ULL,
               "millis wrap was not extended to 64 bits");
  report.check(clock.sample(0x20U, now) && now == 0x100000020ULL,
               "post-wrap time was extended incorrectly");
  report.check(clock.sample(0x20U, now) && now == 0x100000020ULL,
               "equal time sample was not idempotent");

  MonotonicMillis32 regression{};
  report.check(regression.sample(1000U, now),
               "regression fixture initialization failed");
  report.check(!regression.sample(999U, now),
               "backward time jump was interpreted as a valid long delay");
  report.check(regression.fail_closed(),
               "backward time jump did not latch fail-close");
  report.check(regression.fault() == MonotonicTimeFault::AmbiguousOrBackward,
               "backward time jump reported the wrong fault");
  report.check(!regression.sample(1001U, now),
               "invalid clock recovered without a reset");

  MonotonicMillis32 ambiguous{};
  report.check(ambiguous.sample(0U, now),
               "ambiguous-gap fixture initialization failed");
  report.check(!ambiguous.sample(0x80000000U, now),
               "half-range ambiguous clock gap was accepted");

  finish_report(report,
                "32-bit millis wrap extension with latched rejection of "
                "ambiguous/backward samples");
}

void stabilize_initial_aux(E220WriteContract& contract, TestReport& report,
                           std::uint64_t start_ms) {
  report.check(!contract.observe_aux(true, start_ms),
               "AUX became ready without the stability interval");
  report.check(!contract.observe_aux(true, start_ms + 14U),
               "AUX became ready before 15 ms stable HIGH");
  report.check(contract.observe_aux(true, start_ms + 15U),
               "AUX did not become ready after 15 ms stable HIGH");
}

void test_aux_write_contract(TestReport& report) {
  E220WriteContract contract{};
  stabilize_initial_aux(contract, report, 0U);
  report.check(contract.ready_for_write(),
               "stable initial AUX HIGH did not enable a radio write");
  report.check(contract.begin_write(32U),
               "valid 32-byte all-or-nothing write was not admitted");
  report.check(contract.report_write_result(32U, 20U, true) ==
                   E220WriteDisposition::AcceptedAll,
               "full 32-byte write was not accepted atomically");
  report.check(!contract.ready_for_write(),
               "next write was enabled before the E220 service floor");
  report.check(!contract.observe_aux(
                   true, 20U +
                             FixedFirmwareContract::
                                 e220_subpacket_service_floor_ms -
                             1U),
               "continuous AUX HIGH completed before the observed E220 "
               "service floor");
  report.check(contract.observe_aux(
                   true, 20U +
                             FixedFirmwareContract::
                                 e220_subpacket_service_floor_ms),
               "continuous AUX HIGH did not complete at the observed E220 "
               "service floor");
  report.check(contract.take_write_completion(),
               "high-only write did not emit one completion event");
  report.check(!contract.take_write_completion(),
               "high-only completion event was not one-shot");

  E220WriteContract low_pulse{};
  stabilize_initial_aux(low_pulse, report, 0U);
  report.check(low_pulse.begin_write(32U),
               "LOW-pulse fixture could not begin a write");
  report.check(low_pulse.report_write_result(32U, 20U, true) ==
                   E220WriteDisposition::AcceptedAll,
               "LOW-pulse fixture write was not accepted");
  report.check(!low_pulse.observe_aux(false, 100U),
               "AUX LOW incorrectly completed the write");
  report.check(!low_pulse.observe_aux(true, 300U),
               "returning AUX HIGH completed without a stability interval");
  report.check(!low_pulse.observe_aux(true, 314U),
               "returning AUX HIGH completed before 15 ms stable");
  report.check(!low_pulse.observe_aux(true, 315U),
               "AUX LOW->HIGH completed before the E220 service floor");
  report.check(!low_pulse.observe_aux(
                   true, 20U +
                             FixedFirmwareContract::
                                 e220_subpacket_service_floor_ms -
                             1U),
               "stable returned AUX completed one millisecond before the "
               "E220 service floor");
  report.check(low_pulse.observe_aux(
                   true, 20U +
                             FixedFirmwareContract::
                                 e220_subpacket_service_floor_ms),
               "AUX LOW->HIGH stable transition did not wait for the E220 "
               "service floor");
  report.check(low_pulse.take_write_completion(),
               "completed write did not emit one completion event");
  report.check(!low_pulse.take_write_completion(),
               "completion event was not one-shot");
  report.check(low_pulse.ready_for_write(),
               "successful completion did not re-enable writes");

  E220WriteContract low_at_dwell{};
  stabilize_initial_aux(low_at_dwell, report, 0U);
  report.check(low_at_dwell.begin_write(1U),
               "dwell-boundary LOW fixture could not begin a write");
  report.check(low_at_dwell.report_write_result(1U, 16U, true) ==
                   E220WriteDisposition::AcceptedAll,
               "dwell-boundary LOW fixture write was not accepted");
  const std::uint64_t service_boundary =
      16U + FixedFirmwareContract::e220_subpacket_service_floor_ms;
  report.check(!low_at_dwell.observe_aux(false, service_boundary),
               "LOW at the service-floor boundary lost priority to "
               "completion");
  report.check(!low_at_dwell.observe_aux(true, service_boundary + 1U),
               "post-boundary HIGH completed without 15 ms stability");
  report.check(low_at_dwell.observe_aux(
                   true, service_boundary +
                             FixedFirmwareContract::aux_high_stable_ms +
                             1U),
               "post-boundary LOW->HIGH did not complete after 15 ms");

  E220WriteContract rejected{};
  stabilize_initial_aux(rejected, report, 0U);
  report.check(rejected.begin_write(17U),
               "rejection fixture could not begin a write");
  report.check(rejected.report_write_result(0U, 16U, true) ==
                   E220WriteDisposition::Rejected,
               "zero-byte UART result was not treated as a safe rejection");
  report.check(rejected.ready_for_write() && !rejected.fail_closed(),
               "zero-byte rejection did not preserve exact retry eligibility");
  report.check(rejected.begin_write(17U),
               "exact retry was not admitted after zero-byte rejection");

  E220WriteContract partial{};
  stabilize_initial_aux(partial, report, 0U);
  report.check(partial.begin_write(32U),
               "partial-write fixture could not begin a write");
  report.check(partial.report_write_result(16U, 16U, true) ==
                   E220WriteDisposition::ContractViolation,
               "partial physical write was not rejected");
  report.check(partial.fail_closed() &&
                   partial.fault() == E220WriteFault::PartialWrite,
               "partial physical write did not latch fail-close");

  E220WriteContract oversized{};
  stabilize_initial_aux(oversized, report, 0U);
  report.check(!oversized.begin_write(33U),
               "write larger than the fixed 32-byte chunk was admitted");
  report.check(oversized.fail_closed() &&
                   oversized.fault() == E220WriteFault::InvalidWriteSize,
               "oversized write did not latch fail-close");

  E220WriteContract no_high{};
  stabilize_initial_aux(no_high, report, 0U);
  report.check(no_high.begin_write(1U),
               "AUX-high timeout fixture could not begin a write");
  report.check(no_high.report_write_result(1U, 16U, false) ==
                   E220WriteDisposition::AcceptedAll,
               "accepted write with already-low AUX was mishandled");
  report.check(!no_high.observe_aux(false, 2015U),
               "AUX-high timeout fired before its inclusive boundary");
  report.check(!no_high.fail_closed(),
               "AUX-high timeout failed before its boundary");
  report.check(!no_high.observe_aux(false, 2016U),
               "timed-out AUX HIGH transition reported ready");
  report.check(no_high.fault() == E220WriteFault::AuxDidNotReturnHigh,
               "missing stable AUX HIGH did not latch the expected fault");

  E220WriteContract backward_time{};
  stabilize_initial_aux(backward_time, report, 0U);
  report.check(backward_time.begin_write(1U) &&
                   backward_time.report_write_result(1U, 100U, true) ==
                       E220WriteDisposition::AcceptedAll,
               "backward-time fixture could not accept its full write");
  report.check(!backward_time.observe_aux(true, 99U) &&
                   backward_time.fail_closed() &&
                   backward_time.fault() ==
                       E220WriteFault::NonMonotonicTime,
               "backward E220 service time did not latch fail-close");
  report.check(!backward_time.observe_aux(true, 1'000U) &&
                   !backward_time.ready_for_write(),
               "non-monotonic E220 write contract recovered after failure");

  finish_report(report,
                "E220 <=32-byte atomic write, zero-byte exact retry, "
                "550 ms service floor plus LOW->HIGH stable completion, "
                "and bounded fail-close");
}

void test_fixed_and_startup_contract(TestReport& report) {
  static_assert(FixedFirmwareContract::e220_m0_pin == XiaoHeaderPin::D0);
  static_assert(FixedFirmwareContract::e220_m1_pin == XiaoHeaderPin::D1);
  static_assert(FixedFirmwareContract::e220_uart_tx_pin == XiaoHeaderPin::D2);
  static_assert(FixedFirmwareContract::e220_uart_rx_pin == XiaoHeaderPin::D3);
  static_assert(FixedFirmwareContract::pixhawk_uart_tx_pin ==
                XiaoHeaderPin::D6);
  static_assert(FixedFirmwareContract::pixhawk_uart_rx_pin ==
                XiaoHeaderPin::D7);
  static_assert(FixedFirmwareContract::e220_aux_pin == XiaoHeaderPin::D8);
  static_assert(FixedFirmwareContract::pixhawk_uart_bps == 57600U);
  static_assert(FixedFirmwareContract::e220_uart_bps == 115200U);
  static_assert(FixedFirmwareContract::e220_air_bps == 19200U);
  static_assert(FixedFirmwareContract::radio_chunk_bytes == 32U);
  static_assert(FixedFirmwareContract::partial_flush_ms == 50U);
  static_assert(FixedFirmwareContract::min_tx_gap_ms == 180U);
  static_assert(
      FixedFirmwareContract::e220_subpacket_service_floor_ms == 550U);
  static_assert(FixedFirmwareContract::aux_high_stable_ms == 15U);
  static_assert(FixedFirmwareContract::downlink_send_ms == 3000U);
  static_assert(FixedFirmwareContract::uplink_guard_ms == 650U);
  static_assert(FixedFirmwareContract::uplink_window_ms == 300U);
  static_assert(FixedFirmwareContract::vehicle_receive_timeout_ms == 2000U);
  static_assert(FixedFirmwareContract::return_guard_ms == 650U);
  static_assert(FixedFirmwareContract::late_terminal_wait_ms == 1300U);
  static_assert(FixedFirmwareContract::heartbeat_hard_deadline_ms == 2500U);
  static_assert(FixedFirmwareContract::heartbeat_grant_reserve_ms == 5050U);
  static_assert(FixedFirmwareContract::e220_profile[0] == 0x00U);
  static_assert(FixedFirmwareContract::e220_profile[2] == 0xE5U);
  static_assert(FixedFirmwareContract::e220_profile[3] == 0xC3U);
  static_assert(FixedFirmwareContract::e220_profile[4] == 0x46U);

  const std::array<std::uint8_t, 8> exact_profile{
      {0x00U, 0x00U, 0xE5U, 0xC3U, 0x46U, 0x00U, 0x00U, 0x00U}};
  FirmwareStartupContract valid{};
  report.check(!valid.transmission_allowed(),
               "startup gate allowed TX before any verification");
  valid.confirm_identity_persisted(true);
  report.check(!valid.transmission_allowed(),
               "startup gate allowed TX before E220 profile verification");
  report.check(valid.verify_e220_profile(exact_profile.data(),
                                         exact_profile.size()),
               "exact production E220 profile was rejected");
  report.check(valid.transmission_allowed() &&
                   valid.status() == FirmwareStartupStatus::Ready,
               "verified identity/profile did not open the startup TX gate");

  auto wrong_profile = exact_profile;
  wrong_profile[3] ^= 0x01U;
  FirmwareStartupContract mismatch{};
  mismatch.confirm_identity_persisted(true);
  report.check(!mismatch.verify_e220_profile(wrong_profile.data(),
                                             wrong_profile.size()),
               "mismatched E220 profile was accepted");
  report.check(mismatch.fail_closed() &&
                   mismatch.fault() == FirmwareStartupFault::ProfileMismatch,
               "profile mismatch did not latch fail-close");
  report.check(!mismatch.verify_e220_profile(exact_profile.data(),
                                             exact_profile.size()),
               "latched profile fault recovered without reboot");
  report.check(!mismatch.transmission_allowed(),
               "profile mismatch allowed radio transmission");

  FirmwareStartupContract short_read{};
  short_read.confirm_identity_persisted(true);
  report.check(!short_read.verify_e220_profile(exact_profile.data(), 7U),
               "short E220 profile read was accepted");
  report.check(short_read.fault() ==
                   FirmwareStartupFault::ProfileReadInvalid,
               "short profile read reported the wrong fail-close fault");

  FirmwareStartupContract persistence_failure{};
  persistence_failure.confirm_identity_persisted(false);
  report.check(persistence_failure.fail_closed() &&
                   !persistence_failure.transmission_allowed(),
               "identity persistence failure did not keep TX disabled");

  finish_report(report,
                "compile-time fixed pin/UART/profile values and startup "
                "identity/profile fail-close gate");
}

void test_ground_usb_transport_epoch_contract(TestReport& report) {
  GroundUsbTransportEpochSnapshot snapshot{};
  snapshot.known_epoch = 7U;
  snapshot.observed_epoch = 7U;
  snapshot.bytes_committed = 81U;
  snapshot.bytes_published = 37U;
  snapshot.heartbeat_commit_active = true;
  snapshot.parameter_commit_active = true;
  snapshot.write_pending = true;
  snapshot.queued_bytes = 21U;
  report.check(
      assess_ground_usb_transport_epoch(snapshot) ==
          GroundUsbTransportEpochDisposition::Unchanged,
      "an unchanged USB transport epoch was misclassified");

  snapshot = {};
  snapshot.known_epoch = 7U;
  snapshot.observed_epoch = 8U;
  report.check(
      assess_ground_usb_transport_epoch(snapshot) ==
          GroundUsbTransportEpochDisposition::RecoverableBoundary,
      "an empty boot-time USB reset was not recoverable");

  snapshot.bytes_committed = 932U;
  snapshot.bytes_published = 932U;
  report.check(
      assess_ground_usb_transport_epoch(snapshot) ==
          GroundUsbTransportEpochDisposition::RecoverableBoundary,
      "a fully published idle USB session was not recoverable");

  snapshot.heartbeat_commit_active = true;
  report.check(
      assess_ground_usb_transport_epoch(snapshot) ==
          GroundUsbTransportEpochDisposition::UnsafeLoss,
      "an in-flight heartbeat crossed a recoverable USB reset");
  snapshot.heartbeat_commit_active = false;

  snapshot.parameter_commit_active = true;
  report.check(
      assess_ground_usb_transport_epoch(snapshot) ==
          GroundUsbTransportEpochDisposition::UnsafeLoss,
      "an in-flight PARAM_VALUE crossed a recoverable USB reset");
  snapshot.parameter_commit_active = false;

  snapshot.write_pending = true;
  report.check(
      assess_ground_usb_transport_epoch(snapshot) ==
          GroundUsbTransportEpochDisposition::UnsafeLoss,
      "a partial LocalEgress write crossed a recoverable USB reset");
  snapshot.write_pending = false;

  snapshot.queued_bytes = 1U;
  report.check(
      assess_ground_usb_transport_epoch(snapshot) ==
          GroundUsbTransportEpochDisposition::UnsafeLoss,
      "queued LocalEgress bytes crossed a recoverable USB reset");
  snapshot.queued_bytes = 0U;

  snapshot.bytes_committed = 933U;
  report.check(
      assess_ground_usb_transport_epoch(snapshot) ==
          GroundUsbTransportEpochDisposition::UnsafeLoss,
      "an accepted but unpublished byte crossed a recoverable USB reset");

  snapshot.bytes_committed = 931U;
  report.check(
      assess_ground_usb_transport_epoch(snapshot) ==
          GroundUsbTransportEpochDisposition::UnsafeLoss,
      "a regressed publication watermark was accepted");

  snapshot.bytes_committed = 932U;
  snapshot.known_epoch = std::numeric_limits<std::uint32_t>::max();
  snapshot.observed_epoch = 0U;
  report.check(
      assess_ground_usb_transport_epoch(snapshot) ==
          GroundUsbTransportEpochDisposition::RecoverableBoundary,
      "a clean wrapped USB epoch was not recoverable");

  finish_report(report,
                "clean USB transport boundaries recover only at a proven "
                "physical publication watermark; every uncertain byte "
                "remains fail-closed");
}

}  // namespace

TestReport run_runtime_contract_test(const std::string& test_id,
                                     std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "FW-SESSION-001") {
    test_session_contract(report);
  } else if (test_id == "FW-TIME-001") {
    test_time_contract(report);
  } else if (test_id == "FW-AUX-001") {
    test_aux_write_contract(report);
  } else if (test_id == "FW-CONTRACT-001") {
    test_fixed_and_startup_contract(report);
  } else if (test_id == "FW-USB-EPOCH-RECOVERY-001") {
    test_ground_usb_transport_epoch_contract(report);
  } else {
    report.check(false, "unknown runtime contract test ID");
    finish_report(report, "unknown runtime contract test");
  }
  return report;
}

}  // namespace vc_lora::test
