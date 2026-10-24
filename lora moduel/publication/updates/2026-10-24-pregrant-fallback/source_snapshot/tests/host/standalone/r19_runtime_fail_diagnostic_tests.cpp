#include <array>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <string>

#include "../../../firmware/high_speed/r19_runtime_fail_diagnostic.hpp"

namespace {

using vc_lora::MavlinkFrame;
using vc_lora::MavlinkParseStatus;
using vc_lora::experimental::R19RuntimeAliveDiagnosticPublisher;
using vc_lora::experimental::R19RuntimeAliveEvidence;
using vc_lora::experimental::R19RuntimeAliveState;
using vc_lora::experimental::R19RuntimeDiagnosticAction;
using vc_lora::experimental::R19RuntimeDiagnosticCadence;
using vc_lora::experimental::R19RuntimeDiagnosticTransportFailureReason;
using vc_lora::experimental::R19RuntimeDiagnosticTransportTrace;
using vc_lora::experimental::R19RuntimeFailDiagnosticPublisher;
using vc_lora::experimental::R19RuntimeFailEvidence;
using vc_lora::experimental::R19RuntimeFailLatch;
using vc_lora::experimental::R19RuntimeFailRole;
using vc_lora::experimental::R19RuntimeFailStatusSnapshot;
using vc_lora::experimental::R19RuntimeFailWriteStatus;

struct TestReport {
  std::size_t checks{0U};
  std::size_t failures{0U};

  void check(bool condition, const char* message) noexcept {
    ++checks;
    if (!condition) {
      ++failures;
      std::cerr << "FAIL: " << message << '\n';
    }
  }
};

constexpr R19RuntimeFailStatusSnapshot first_snapshot() noexcept {
  return {0x01U, 0x02U, 0x03U, 0x04U, 0x05U, true, 0x06U,
          0x00000007U};
}

constexpr R19RuntimeFailStatusSnapshot later_snapshot() noexcept {
  return {0x11U, 0x12U, 0x13U, 0x14U, 0x15U, false, 0x16U,
          0x1718191AU};
}

void test_first_failure_wins(TestReport& report) {
  R19RuntimeFailLatch latch{};
  report.check(!latch.latched(), "a new latch was already set");
  report.check(!latch.latch(R19RuntimeFailRole::Ground, 0U, 10U,
                            first_snapshot()),
               "source line zero was accepted");
  report.check(!latch.latched(), "invalid evidence changed the latch");
  report.check(latch.latch(R19RuntimeFailRole::Ground, 466U, 1234U,
                           first_snapshot()),
               "the first valid failure was rejected");
  report.check(!latch.latch(R19RuntimeFailRole::Vehicle, 999U, 5678U,
                            later_snapshot()),
               "a later failure overwrote the first failure");

  const R19RuntimeFailEvidence& evidence = latch.evidence();
  report.check(evidence.valid(), "latched evidence is invalid");
  report.check(evidence.role == R19RuntimeFailRole::Ground &&
                   evidence.source_line == 466U &&
                   evidence.monotonic_ms == 1234U,
               "role, source line, or timestamp did not remain first-wins");
  report.check(evidence.status == first_snapshot(),
               "the first status snapshot was not retained exactly");
}

void test_invalid_role_is_rejected(TestReport& report) {
  R19RuntimeFailLatch latch{};
  const auto invalid_role = static_cast<R19RuntimeFailRole>(0x7FU);
  report.check(!latch.latch(invalid_role, 17U, 0U, first_snapshot()) &&
                   !latch.latched(),
               "an out-of-domain role was accepted");
}

void test_crc_valid_statustext(TestReport& report) {
  R19RuntimeFailLatch latch{};
  report.check(latch.latch(R19RuntimeFailRole::Ground, 466U, 1234U,
                           first_snapshot()),
               "fixture failure could not be latched");

  R19RuntimeFailDiagnosticPublisher publisher{};
  report.check(publisher.stage(latch.evidence(), 0x2AU),
               "valid failure evidence could not be staged");
  report.check(publisher.pending() && publisher.remaining() == 63U,
               "STATUSTEXT did not have the expected 63-byte wire size");

  const auto view = publisher.pending_write();
  MavlinkFrame decoded{};
  report.check(view.bytes != nullptr && view.size == 63U,
               "staged write view is invalid");
  report.check(vc_lora::validate_mavlink_frame(view.bytes, view.size, decoded) ==
                   MavlinkParseStatus::FrameReady,
               "generated STATUSTEXT failed MAVLink CRC validation");
  report.check(decoded.version == vc_lora::MavlinkVersion::V2 &&
                   decoded.message_id == 253U &&
                   decoded.payload_length == 51U &&
                   decoded.sequence == 0x2AU && decoded.system_id == 254U &&
                   decoded.component_id == 190U,
               "generated frame identity is not the diagnostic contract");
  report.check(decoded.payload()[0U] == 2U,
               "STATUSTEXT severity is not MAV_SEVERITY_CRITICAL");

  const std::string text(
      reinterpret_cast<const char*>(decoded.payload() + 1U), 50U);
  report.check(
      text == "R19F:G:01D2:00000000000004D2:010203040586:00000007",
      "STATUSTEXT did not encode the fixed role/line/time/status format");
  report.check(!publisher.stage(latch.evidence(), 0x2BU),
               "an active one-shot publisher accepted a second frame");
}

void test_zero_short_and_full_write_continuation(TestReport& report) {
  R19RuntimeFailLatch latch{};
  report.check(latch.latch(R19RuntimeFailRole::Vehicle, 0xABCDU,
                           0x123456789ABCDEF0ULL, later_snapshot()),
               "vehicle fixture failure could not be latched");
  R19RuntimeFailDiagnosticPublisher publisher{};
  report.check(publisher.stage(latch.evidence(), 7U),
               "vehicle diagnostic could not be staged");

  const auto initial = publisher.pending_write();
  report.check(publisher.complete_write(0U) ==
                   R19RuntimeFailWriteStatus::WouldBlock,
               "a zero write was not retained for retry");
  const auto after_zero = publisher.pending_write();
  report.check(after_zero.bytes == initial.bytes &&
                   after_zero.size == initial.size,
               "zero write changed the pending frame");

  constexpr std::size_t kShortWrite = 11U;
  report.check(publisher.complete_write(kShortWrite) ==
                   R19RuntimeFailWriteStatus::Progress,
               "a short write did not report bounded progress");
  const auto suffix = publisher.pending_write();
  report.check(suffix.bytes == initial.bytes + kShortWrite &&
                   suffix.size == initial.size - kShortWrite,
               "short write did not retain the exact unaccepted suffix");
  report.check(publisher.complete_write(suffix.size) ==
                   R19RuntimeFailWriteStatus::Complete,
               "the exact remaining suffix did not complete the frame");
  report.check(!publisher.pending() && publisher.remaining() == 0U,
               "completed frame remained pending");
  report.check(publisher.complete_write(0U) ==
                   R19RuntimeFailWriteStatus::Invalid,
               "completion without a pending frame was accepted");
}

void test_full_write_and_over_acceptance(TestReport& report) {
  R19RuntimeFailLatch latch{};
  report.check(latch.latch(R19RuntimeFailRole::Ground, 42U, 0U,
                           first_snapshot()),
               "full-write fixture could not be latched");

  R19RuntimeFailDiagnosticPublisher full{};
  report.check(full.stage(latch.evidence(), 1U),
               "full-write fixture could not be staged");
  report.check(full.complete_write(full.remaining()) ==
                   R19RuntimeFailWriteStatus::Complete &&
                   full.complete(),
               "one full write did not complete the publisher");
  report.check(full.restart_complete_write() && full.pending() &&
                   full.remaining() == 63U,
               "completed fail frame could not rewind after session reset");
  const auto restarted_full = full.pending_write();
  MavlinkFrame restarted_decoded{};
  report.check(vc_lora::validate_mavlink_frame(
                   restarted_full.bytes, restarted_full.size,
                   restarted_decoded) == MavlinkParseStatus::FrameReady &&
                   restarted_decoded.sequence == 1U,
               "fail-frame rewind changed its exact MAVLink sequence/image");
  report.check(full.complete_write(full.remaining()) ==
                   R19RuntimeFailWriteStatus::Complete,
               "rewound fail frame did not complete again");

  R19RuntimeFailDiagnosticPublisher invalid{};
  report.check(invalid.stage(latch.evidence(), 2U),
               "over-acceptance fixture could not be staged");
  report.check(invalid.complete_write(invalid.remaining() + 1U) ==
                   R19RuntimeFailWriteStatus::Invalid &&
                   invalid.fail_closed(),
               "over-acceptance did not fail closed");
}

void test_alive_crc_format_and_reuse(TestReport& report) {
  const R19RuntimeAliveEvidence armed{
      R19RuntimeFailRole::Ground, R19RuntimeAliveState::Armed, 0x1234U,
      1234U, first_snapshot()};
  R19RuntimeAliveDiagnosticPublisher publisher{};
  report.check(publisher.stage(armed, 0x31U),
               "valid ARMED evidence could not be staged");
  report.check(publisher.pending() && publisher.remaining() == 63U,
               "ARMED STATUSTEXT was not exactly 63 wire bytes");
  report.check(!publisher.reset(),
               "an incomplete ARMED frame was reset and discarded");

  MavlinkFrame decoded{};
  const auto view = publisher.pending_write();
  report.check(
      vc_lora::validate_mavlink_frame(view.bytes, view.size, decoded) ==
          MavlinkParseStatus::FrameReady,
               "generated ARMED STATUSTEXT failed MAVLink CRC validation");
  report.check(decoded.message_id == 253U && decoded.payload_length == 51U &&
                   decoded.sequence == 0x31U && decoded.system_id == 254U &&
                   decoded.component_id == 190U && decoded.payload()[0U] == 6U,
               "ARMED frame identity or INFO severity is incorrect");
  const std::string armed_text(
      reinterpret_cast<const char*>(decoded.payload() + 1U), 50U);
  report.check(
      armed_text.substr(0U, 47U) ==
          "R19A:G:A:00001234:00000000000004D2:010203040586" &&
          armed_text[47U] == '\0' && armed_text[48U] == '\0' &&
          armed_text[49U] == '\0',
      "ARMED text was not the fixed 47-byte contract plus three NULs");

  report.check(publisher.complete_write(publisher.remaining()) ==
                   R19RuntimeFailWriteStatus::Complete,
               "ARMED frame did not complete");
  report.check(publisher.restart_complete_write() &&
                   publisher.pending() && publisher.remaining() == 63U,
               "completed ARMED frame could not rewind after session reset");
  const auto restarted_armed = publisher.pending_write();
  report.check(vc_lora::validate_mavlink_frame(
                   restarted_armed.bytes, restarted_armed.size, decoded) ==
                       MavlinkParseStatus::FrameReady &&
                   decoded.sequence == 0x31U,
               "ARMED rewind changed its exact MAVLink sequence/image");
  report.check(publisher.complete_write(publisher.remaining()) ==
                   R19RuntimeFailWriteStatus::Complete,
               "rewound ARMED frame did not complete again");
  report.check(publisher.reset(),
               "a completed ARMED publisher could not be reset explicitly");
  const R19RuntimeAliveEvidence alive{
      R19RuntimeFailRole::Vehicle, R19RuntimeAliveState::Alive, 0x89ABCDEFU,
      0x0123456789ABCDEFULL, later_snapshot()};
  report.check(publisher.stage(alive, 0x32U),
               "reset publisher could not stage an ALIVE frame");
  const auto alive_view = publisher.pending_write();
  report.check(vc_lora::validate_mavlink_frame(
                   alive_view.bytes, alive_view.size, decoded) ==
                   MavlinkParseStatus::FrameReady,
               "generated ALIVE STATUSTEXT failed MAVLink CRC validation");
  const std::string alive_text(
      reinterpret_cast<const char*>(decoded.payload() + 1U), 50U);
  report.check(
      alive_text.substr(0U, 47U) ==
          "R19A:V:L:89ABCDEF:0123456789ABCDEF:111213141516",
      "ALIVE text did not preserve role, kind, ordinal, time, and status");

  R19RuntimeAliveDiagnosticPublisher invalid{};
  auto invalid_evidence = armed;
  invalid_evidence.state = R19RuntimeAliveState::Invalid;
  report.check(!invalid.stage(invalid_evidence, 0U),
               "invalid alive-state evidence was accepted");
  invalid_evidence = armed;
  invalid_evidence.status.tdd_state = 0x80U;
  report.check(!invalid.stage(invalid_evidence, 0U),
               "an unrepresentable alive TDD state was accepted");
}

void test_fail_repeat_preserves_first_snapshot(TestReport& report) {
  R19RuntimeFailLatch latch{};
  report.check(latch.latch(R19RuntimeFailRole::Vehicle, 0xBEEFU,
                           0x1122334455667788ULL, first_snapshot()),
               "repeat fixture could not latch its first failure");
  R19RuntimeFailDiagnosticPublisher publisher{};
  report.check(publisher.stage(latch.evidence(), 0x40U),
               "first fail frame could not be staged");
  MavlinkFrame first{};
  auto view = publisher.pending_write();
  report.check(vc_lora::validate_mavlink_frame(view.bytes, view.size, first) ==
                   MavlinkParseStatus::FrameReady,
               "first fail frame was invalid");
  std::array<std::uint8_t, 51U> first_payload{};
  for (std::size_t index = 0U; index < first_payload.size(); ++index) {
    first_payload[index] = first.payload()[index];
  }
  report.check(!publisher.stage_repeat(0x41U),
               "a pending fail frame was replaced by a repeat");
  report.check(publisher.complete_write(publisher.remaining()) ==
                   R19RuntimeFailWriteStatus::Complete,
               "first fail frame did not complete");
  report.check(publisher.stage_repeat(0x41U),
               "completed fail frame could not be explicitly repeated");
  MavlinkFrame repeated{};
  view = publisher.pending_write();
  report.check(vc_lora::validate_mavlink_frame(
                   view.bytes, view.size, repeated) ==
                   MavlinkParseStatus::FrameReady,
               "repeated fail frame was invalid");
  bool identical_payload = repeated.sequence == 0x41U;
  for (std::size_t index = 0U; index < first_payload.size(); ++index) {
    identical_payload = identical_payload &&
                        repeated.payload()[index] == first_payload[index];
  }
  report.check(identical_payload,
               "fail repeat changed the immutable first-failure snapshot");
  report.check(publisher.bound_evidence().role == R19RuntimeFailRole::Vehicle &&
                   publisher.bound_evidence().source_line == 0xBEEFU &&
                   publisher.bound_evidence().status == first_snapshot(),
               "publisher did not retain the exact first-failure evidence");
}

void test_bounded_diagnostic_cadence(TestReport& report) {
  R19RuntimeDiagnosticCadence cadence{};
  report.check(cadence.due(100U, false) == R19RuntimeDiagnosticAction::None,
               "an unstarted cadence emitted work");
  report.check(cadence.start(100U), "cadence did not start");
  report.check(!cadence.start(101U), "cadence restarted unexpectedly");
  report.check(cadence.due(100U, false) ==
                   R19RuntimeDiagnosticAction::Armed &&
                   cadence.diagnostic_sequence() == 0U,
               "first cadence action was not ARMED sequence zero");
  report.check(cadence.due(10000U, false) ==
                   R19RuntimeDiagnosticAction::Armed,
               "uncommitted ARMED action was consumed by elapsed time");
  report.check(!cadence.commit(R19RuntimeDiagnosticAction::Alive, 10000U),
               "a mismatched action committed");
  report.check(cadence.commit(R19RuntimeDiagnosticAction::Armed, 10000U) &&
                   cadence.diagnostic_sequence() == 1U &&
                   cadence.next_due_ms() == 11000U,
               "ARMED commit did not start the bounded ALIVE period");
  report.check(cadence.due(10999U, false) ==
                   R19RuntimeDiagnosticAction::None &&
                   cadence.due(11000U, false) ==
                       R19RuntimeDiagnosticAction::Alive,
               "ALIVE was not due at exactly one bounded period");
  report.check(cadence.due(15000U, false) ==
                   R19RuntimeDiagnosticAction::Alive &&
                   cadence.commit(R19RuntimeDiagnosticAction::Alive, 15000U),
               "pending ALIVE was not held until commit");
  report.check(cadence.diagnostic_sequence() == 2U &&
                   cadence.next_due_ms() == 16000U,
               "ALIVE commit did not advance its ordinal and deadline");

  report.check(cadence.due(15500U, true) ==
                   R19RuntimeDiagnosticAction::FailRepeat,
               "first-failure reporting did not preempt the ALIVE deadline");
  report.check(cadence.due(17000U, true) ==
                   R19RuntimeDiagnosticAction::FailRepeat &&
                   cadence.fail_transmissions() == 0U,
               "uncommitted first-failure action was consumed");
  report.check(cadence.commit(R19RuntimeDiagnosticAction::FailRepeat, 17000U) &&
                   cadence.fail_transmissions() == 1U &&
                   cadence.next_due_ms() == 18000U,
               "first-failure commit did not start bounded repeats");
  report.check(cadence.due(17999U, true) ==
                   R19RuntimeDiagnosticAction::None,
               "fail repeat ran faster than the bounded period");

  std::uint64_t now_ms = 18000U;
  while (cadence.fail_transmissions() <
         R19RuntimeDiagnosticCadence::maximum_fail_transmissions) {
    report.check(cadence.due(now_ms, true) ==
                     R19RuntimeDiagnosticAction::FailRepeat &&
                     cadence.commit(R19RuntimeDiagnosticAction::FailRepeat,
                                    now_ms),
                 "a bounded fail repeat could not be committed");
    now_ms += R19RuntimeDiagnosticCadence::period_ms;
  }
  report.check(cadence.fail_repeat_exhausted() &&
                   cadence.due(now_ms, true) ==
                       R19RuntimeDiagnosticAction::None,
               "fail repeats exceeded the fixed transmission bound");

  R19RuntimeDiagnosticCadence regression{};
  report.check(regression.start(500U) &&
                   regression.due(499U, false) ==
                       R19RuntimeDiagnosticAction::None &&
                   regression.fail_closed(),
               "cadence did not fail closed on clock regression");

  R19RuntimeDiagnosticCadence pending_armed{};
  report.check(pending_armed.start(200U) &&
                   pending_armed.due(200U, false) ==
                       R19RuntimeDiagnosticAction::Armed &&
                   pending_armed.due(201U, true) ==
                       R19RuntimeDiagnosticAction::FailRepeat,
               "first failure did not preempt an unstaged pending ARMED");

  R19RuntimeDiagnosticCadence pending_alive{};
  report.check(pending_alive.start(300U) &&
                   pending_alive.due(300U, false) ==
                       R19RuntimeDiagnosticAction::Armed &&
                   pending_alive.commit(R19RuntimeDiagnosticAction::Armed,
                                        300U) &&
                   pending_alive.due(1300U, false) ==
                       R19RuntimeDiagnosticAction::Alive &&
                   pending_alive.due(1301U, true) ==
                       R19RuntimeDiagnosticAction::FailRepeat,
               "first failure did not preempt an unstaged pending ALIVE");
}

void test_transport_trace_is_first_wins(TestReport& report) {
  R19RuntimeDiagnosticTransportTrace trace{};
  trace.observe_host_gate(false, false, 0, 10U);
  report.check(trace.host_sample_seen && trace.first_host_gate_mask == 0U &&
                   trace.last_host_gate_mask == 0U && !trace.full_gate_seen,
               "initial absent-host gate observation was not retained");

  trace.observe_host_gate(true, true, 0, 20U);
  report.check(trace.first_host_gate_mask == 0U &&
                   trace.last_host_gate_mask == 0x03U &&
                   !trace.full_gate_seen,
               "non-writable host gate was classified incorrectly");

  trace.observe_host_gate(true, true, 32, 30U);
  report.check(trace.last_host_gate_mask == 0x07U &&
                   trace.full_gate_seen && trace.first_full_gate_ms == 30U,
               "first full host gate was not timestamped");
  trace.observe_host_gate(true, true, 64, 40U);
  report.check(trace.first_full_gate_ms == 30U,
               "later full host gate overwrote the first timestamp");

  trace.observe_write_attempt(R19RuntimeDiagnosticAction::Armed, 31U, 32,
                              32U, 11U, 7U, 8U);
  trace.observe_write_attempt(R19RuntimeDiagnosticAction::Alive, 41U, 64,
                              31U, 31U, 9U, 9U);
  report.check(trace.first_write_attempt_seen &&
                   trace.first_write_attempt_ms == 31U &&
                   trace.first_write_action ==
                       R19RuntimeDiagnosticAction::Armed &&
                   trace.first_write_available == 32 &&
                   trace.first_write_requested == 32U &&
                   trace.first_write_accepted == 11U &&
                   trace.first_write_expected_epoch == 7U &&
                   trace.first_write_observed_epoch == 8U,
               "first write-attempt evidence was overwritten or incomplete");

  trace.latch_failure(
      R19RuntimeDiagnosticTransportFailureReason::FrameDeadlineExpired, 50U);
  trace.latch_failure(
      R19RuntimeDiagnosticTransportFailureReason::StageRejected, 60U);
  report.check(trace.first_failure_reason ==
                       R19RuntimeDiagnosticTransportFailureReason::
                           FrameDeadlineExpired &&
                   trace.first_failure_ms == 50U,
               "later transport failure overwrote the first reason");
}

}  // namespace

int main() {
  TestReport report{};
  test_first_failure_wins(report);
  test_invalid_role_is_rejected(report);
  test_crc_valid_statustext(report);
  test_zero_short_and_full_write_continuation(report);
  test_full_write_and_over_acceptance(report);
  test_alive_crc_format_and_reuse(report);
  test_fail_repeat_preserves_first_snapshot(report);
  test_bounded_diagnostic_cadence(report);
  test_transport_trace_is_first_wins(report);

  std::cout << "UT-R19-RUNTIME-FAIL-DIAGNOSTIC-001 checks=" << report.checks
            << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
