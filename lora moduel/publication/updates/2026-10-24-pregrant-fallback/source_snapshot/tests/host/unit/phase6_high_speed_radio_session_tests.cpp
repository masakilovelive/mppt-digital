#include <cstddef>
#include <cstdint>
#include <string>

#include "../../../firmware/high_speed/phase6_high_speed_radio_session.hpp"
#include "test_support.hpp"

namespace vc_lora::test {
namespace {

using experimental::AdmissionResult;
using experimental::Direction;
using experimental::HighSpeedPhase6Output;
using experimental::HighSpeedPhase6OutputType;
using experimental::Phase6HighSpeedRadioSession;
using experimental::Phase6HighSpeedRadioSessionStatus;
using experimental::Phase6HighSpeedRadioWrite;
using experimental::Phase6HighSpeedStreamLimits;
using experimental::Phase6RadioWriterArbiter;
using experimental::TransferToken;

constexpr Phase6HighSpeedStreamLimits kLimits{64U, 2048U, 32U};

HighSpeedPhase6Output radio_action(std::uint32_t token,
                                   std::uint32_t writer_generation,
                                   std::size_t size,
                                   std::uint8_t seed) noexcept {
  HighSpeedPhase6Output output{};
  output.type = HighSpeedPhase6OutputType::RadioWrite;
  output.semantic = HighSpeedActionType::SendBulkFragment;
  output.token = token;
  output.writer_generation = writer_generation;
  output.size = size;
  for (std::size_t index = 0U; index < size && index < 32U; ++index) {
    output.bytes[index] =
        static_cast<std::uint8_t>(seed + static_cast<std::uint8_t>(index));
  }
  return output;
}

bool same_write(const Phase6HighSpeedRadioWrite& left,
                const Phase6HighSpeedRadioWrite& right) noexcept {
  if (left.action_token != right.action_token ||
      left.writer_generation != right.writer_generation ||
      left.wire_ordinal != right.wire_ordinal || left.size != right.size) {
    return false;
  }
  for (std::size_t index = 0U; index < left.size; ++index) {
    if (left.bytes[index] != right.bytes[index]) {
      return false;
    }
  }
  return true;
}

bool begin_downlink(Phase6HighSpeedRadioSession& session,
                    std::uint32_t stream_token = 0x7000U) noexcept {
  return session.begin(stream_token, Direction::Downlink, kLimits, 0U) ==
             Phase6HighSpeedRadioSessionStatus::StreamStarted &&
         session.observe_aux(0U, true) ==
             Phase6HighSpeedRadioSessionStatus::StreamActive;
}

bool accept_action(Phase6HighSpeedRadioSession& session,
                   const HighSpeedPhase6Output& action, bool final_action,
                   std::uint32_t now_ms,
                   TransferToken& token_output) noexcept {
  Phase6HighSpeedRadioWrite write{};
  if (session.retain_adapter_action(action, final_action, now_ms) !=
          Phase6HighSpeedRadioSessionStatus::ActionRetained ||
      session.assess_write(now_ms, write) !=
          Phase6HighSpeedRadioSessionStatus::WriteReady ||
      session.complete_uart(write.action_token, write.writer_generation,
                            write.wire_ordinal, write.size, now_ms) !=
          Phase6HighSpeedRadioSessionStatus::WriteCommitted) {
    return false;
  }
  token_output = session.last_transfer_token();
  return token_output.valid();
}

bool release_latest_aux_credit(Phase6HighSpeedRadioSession& session,
                               const TransferToken& token,
                               std::uint32_t low_ms) noexcept {
  return session.observe_aux(low_ms, false) ==
             Phase6HighSpeedRadioSessionStatus::StreamActive &&
         session.observe_aux(low_ms + 1U, true) ==
             Phase6HighSpeedRadioSessionStatus::StreamActive &&
         session.release_buffer_credit_from_local_aux(low_ms + 16U, token) ==
             Phase6HighSpeedRadioSessionStatus::BufferCreditReleased;
}

void test_zero_retry_remote_tail_and_explicit_restore(TestReport& report) {
  Phase6RadioWriterArbiter arbiter{};
  Phase6HighSpeedRadioSession session(arbiter, 0x1122334455667788ULL);
  report.check(begin_downlink(session),
               "valid high-speed stream did not start");

  const HighSpeedPhase6Output action = radio_action(1U, 11U, 32U, 0x20U);
  Phase6HighSpeedRadioWrite first{};
  Phase6HighSpeedRadioWrite retry{};
  report.check(session.retain_adapter_action(action, true, 1U) ==
                       Phase6HighSpeedRadioSessionStatus::ActionRetained &&
                   session.assess_write(15U, first) ==
                       Phase6HighSpeedRadioSessionStatus::WriteReady,
               "first adapter action was not retained/admitted");
  report.check(session.complete_uart(first.action_token,
                                     first.writer_generation,
                                     first.wire_ordinal, 0U, 15U) ==
                       Phase6HighSpeedRadioSessionStatus::RetryRetained &&
                   session.pending_action() &&
                   arbiter.high_speed_stream_uart_records() == 0U,
               "zero-byte write did not retain an uncommitted retry");
  report.check(session.assess_write(15U, retry) ==
                       Phase6HighSpeedRadioSessionStatus::WriteReady &&
                   same_write(first, retry),
               "zero-byte retry was not byte-identical");
  report.check(session.complete_uart(retry.action_token,
                                     retry.writer_generation,
                                     retry.wire_ordinal, retry.size, 15U) ==
                       Phase6HighSpeedRadioSessionStatus::WriteCommitted &&
                   arbiter.high_speed_stream_uart_records() == 1U &&
                   arbiter.high_speed_stream_accepted_bytes() == 32U,
               "full retry was not recorded exactly once");

  const TransferToken final_token = session.last_transfer_token();
  report.check(final_token.valid() && final_token.tail() == 31U &&
                   !arbiter.explicit_restore_required(),
               "UART acceptance incorrectly completed the physical tail");
  report.check(session.observe_aux(16U, true) ==
                       Phase6HighSpeedRadioSessionStatus::StreamActive &&
                   !arbiter.explicit_restore_required(),
               "inherited AUX HIGH incorrectly completed the stream");
  report.check(release_latest_aux_credit(session, final_token, 17U) &&
                   !arbiter.explicit_restore_required() &&
                   arbiter.high_speed_stream_active(),
               "fresh AUX release was not credit-only evidence");
  report.check(session.complete_stream_from_remote_arrival(final_token, 34U) ==
                       Phase6HighSpeedRadioSessionStatus::
                           ExplicitRestoreRequired &&
                   arbiter.explicit_restore_required() &&
                   !arbiter.can_poll_standard(),
               "exact remote final tail did not enter explicit restore");
  report.check(session.restore_standard(false, 35U) ==
                       Phase6HighSpeedRadioSessionStatus::
                           ExplicitRestoreRequired &&
                   !arbiter.can_poll_standard() &&
                   session.restore_standard(true, 36U) ==
                       Phase6HighSpeedRadioSessionStatus::StandardRestored &&
                   arbiter.can_poll_standard(),
               "standard TDD resumed without explicit clean restore");
}

void test_gap_and_400_byte_admission(TestReport& report) {
  Phase6RadioWriterArbiter arbiter{};
  Phase6HighSpeedRadioSession session(arbiter, 0x2222333344445555ULL);
  report.check(begin_downlink(session, 0x7001U),
               "buffer-bound stream did not start");

  TransferToken last{};
  std::uint32_t now_ms = 15U;
  for (std::uint32_t index = 0U; index < 12U; ++index) {
    report.check(accept_action(session,
                               radio_action(100U + index, 200U + index,
                                            32U,
                                            static_cast<std::uint8_t>(index)),
                               false, now_ms, last),
                 "one of twelve buffered writes was not committed");
    now_ms += 3U;
  }
  report.check(session.buffered_bytes() == 384U &&
                   session.accepted_bytes() == 384U,
               "twelve chunks did not consume 384 bytes of credit");

  const HighSpeedPhase6Output thirteenth =
      radio_action(112U, 212U, 32U, 0x80U);
  Phase6HighSpeedRadioWrite blocked{};
  report.check(session.retain_adapter_action(thirteenth, true, now_ms) ==
                       Phase6HighSpeedRadioSessionStatus::ActionRetained &&
                   session.assess_write(now_ms, blocked) ==
                       Phase6HighSpeedRadioSessionStatus::AwaitAdmission &&
                   session.last_admission_result() ==
                       AdmissionResult::Backpressure,
               "400-byte E220 buffer bound did not backpressure chunk 13");
  report.check(release_latest_aux_credit(session, last, now_ms + 1U),
               "fresh local AUX edge did not return buffer credit");

  Phase6HighSpeedRadioWrite admitted{};
  report.check(session.assess_write(now_ms + 17U, admitted) ==
                       Phase6HighSpeedRadioSessionStatus::WriteReady &&
                   session.complete_uart(admitted.action_token,
                                         admitted.writer_generation,
                                         admitted.wire_ordinal,
                                         admitted.size,
                                         now_ms + 17U) ==
                       Phase6HighSpeedRadioSessionStatus::WriteCommitted &&
                   session.accepted_bytes() == 416U,
               "chunk 13 was not admitted after credit release");
  const TransferToken final_token = session.last_transfer_token();
  report.check(release_latest_aux_credit(session, final_token,
                                         now_ms + 18U) &&
                   session.complete_stream_from_remote_arrival(
                       final_token, now_ms + 35U) ==
                       Phase6HighSpeedRadioSessionStatus::
                           ExplicitRestoreRequired &&
                   session.restore_standard(true, now_ms + 36U) ==
                       Phase6HighSpeedRadioSessionStatus::StandardRestored,
               "buffer-bound stream did not drain and restore cleanly");
}

void test_aux_stability_and_three_ms_gap(TestReport& report) {
  Phase6RadioWriterArbiter arbiter{};
  Phase6HighSpeedRadioSession session(arbiter, 0x2222333344446666ULL);
  report.check(begin_downlink(session, 0x7002U),
               "timing-bound stream did not start");

  Phase6HighSpeedRadioWrite first{};
  report.check(session.retain_adapter_action(
                   radio_action(1U, 1U, 32U, 0x11U), false, 1U) ==
                   Phase6HighSpeedRadioSessionStatus::ActionRetained &&
                   session.assess_write(14U, first) ==
                       Phase6HighSpeedRadioSessionStatus::AwaitAdmission &&
                   session.last_admission_result() ==
                       AdmissionResult::AuxNotStable &&
                   session.assess_write(15U, first) ==
                       Phase6HighSpeedRadioSessionStatus::WriteReady &&
                   session.complete_uart(first.action_token,
                                         first.writer_generation,
                                         first.wire_ordinal, first.size,
                                         15U) ==
                       Phase6HighSpeedRadioSessionStatus::WriteCommitted,
               "15-ms AUX qualification was not enforced inclusively");

  Phase6HighSpeedRadioWrite second{};
  report.check(session.retain_adapter_action(
                   radio_action(2U, 2U, 32U, 0x22U), true, 16U) ==
                   Phase6HighSpeedRadioSessionStatus::ActionRetained &&
                   session.assess_write(17U, second) ==
                       Phase6HighSpeedRadioSessionStatus::AwaitAdmission &&
                   session.last_admission_result() ==
                       AdmissionResult::GapActive &&
                   session.assess_write(18U, second) ==
                       Phase6HighSpeedRadioSessionStatus::WriteReady &&
                   session.complete_uart(second.action_token,
                                         second.writer_generation,
                                         second.wire_ordinal, second.size,
                                         18U) ==
                       Phase6HighSpeedRadioSessionStatus::WriteCommitted,
               "3-ms physical-UART admission gap was not enforced");

  const TransferToken final_token = session.last_transfer_token();
  report.check(release_latest_aux_credit(session, final_token, 19U) &&
                   !arbiter.explicit_restore_required() &&
                   session.complete_stream_from_remote_arrival(
                       final_token, 36U) ==
                       Phase6HighSpeedRadioSessionStatus::
                           ExplicitRestoreRequired &&
                   session.restore_standard(true, 37U) ==
                       Phase6HighSpeedRadioSessionStatus::StandardRestored,
               "timing-bound stream did not require a distinct final tail");
}

void test_partial_unadmitted_stale_and_time_fail_closed(TestReport& report) {
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 0x3001U);
    Phase6HighSpeedRadioWrite write{};
    report.check(begin_downlink(session, 0x7101U) &&
                     session.retain_adapter_action(
                         radio_action(1U, 1U, 32U, 1U), false, 1U) ==
                         Phase6HighSpeedRadioSessionStatus::ActionRetained &&
                     session.assess_write(15U, write) ==
                         Phase6HighSpeedRadioSessionStatus::WriteReady &&
                     session.complete_uart(1U, 1U, 0U, 17U, 15U) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     session.fail_closed() && arbiter.fail_closed(),
                 "partial physical write did not fail closed");
  }
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 0x3002U);
    report.check(begin_downlink(session, 0x7102U) &&
                     session.retain_adapter_action(
                         radio_action(1U, 1U, 32U, 2U), false, 1U) ==
                         Phase6HighSpeedRadioSessionStatus::ActionRetained &&
                     session.complete_uart(1U, 1U, 0U, 32U, 2U) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     session.fail_closed() && arbiter.fail_closed(),
                 "positive unadmitted write did not fail closed");
  }
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 0x3006U);
    report.check(begin_downlink(session, 0x7106U) &&
                     session.retain_adapter_action(
                         radio_action(1U, 1U, 32U, 6U), false, 1U) ==
                         Phase6HighSpeedRadioSessionStatus::ActionRetained &&
                     session.complete_uart(1U, 1U, 0U, 0U, 2U) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     session.fail_closed() && arbiter.fail_closed(),
                 "zero-byte unadmitted callback did not fail closed");
  }
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 0x3007U);
    report.check(begin_downlink(session, 0x7107U) &&
                     session.retain_adapter_action(
                         radio_action(1U, 1U, 32U, 7U), false, 1U) ==
                         Phase6HighSpeedRadioSessionStatus::ActionRetained &&
                     session.retain_adapter_action(
                         radio_action(2U, 2U, 32U, 8U), false, 2U) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     session.fail_closed() && arbiter.fail_closed(),
                 "a second in-flight adapter action did not fail closed");
  }
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 0x3003U);
    TransferToken accepted{};
    report.check(begin_downlink(session, 0x7103U) &&
                     accept_action(session,
                                   radio_action(10U, 20U, 32U, 3U),
                                   false, 15U, accepted) &&
                     session.retain_adapter_action(
                         radio_action(10U, 20U, 32U, 3U), false, 18U) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     session.fail_closed() && arbiter.fail_closed(),
                 "duplicate adapter identity did not fail closed");
  }
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 0x3004U);
    Phase6HighSpeedRadioWrite write{};
    report.check(begin_downlink(session, 0x7104U) &&
                     session.retain_adapter_action(
                         radio_action(10U, 20U, 32U, 4U), false, 1U) ==
                         Phase6HighSpeedRadioSessionStatus::ActionRetained &&
                     session.assess_write(15U, write) ==
                         Phase6HighSpeedRadioSessionStatus::WriteReady &&
                     session.complete_uart(9U, 20U, 0U, 0U, 15U) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     session.fail_closed() && arbiter.fail_closed(),
                 "stale completion identity did not fail closed");
  }
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 0x3005U);
    report.check(begin_downlink(session, 0x7105U) &&
                     session.observe_aux(20U, true) ==
                         Phase6HighSpeedRadioSessionStatus::StreamActive &&
                     session.observe_aux(19U, false) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     session.fail_closed() && arbiter.fail_closed(),
                 "time regression did not fail closed");
  }
}

void test_stream_limits_fail_before_physical_write(TestReport& report) {
  {
    constexpr Phase6HighSpeedStreamLimits one_record{1U, 64U, 32U};
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 0x3010U);
    TransferToken first{};
    report.check(session.begin(0x7110U, Direction::Downlink, one_record,
                               0U) ==
                         Phase6HighSpeedRadioSessionStatus::StreamStarted &&
                     session.observe_aux(0U, true) ==
                         Phase6HighSpeedRadioSessionStatus::StreamActive &&
                     accept_action(session,
                                   radio_action(1U, 1U, 32U, 0x10U),
                                   false, 15U, first) &&
                     session.retain_adapter_action(
                         radio_action(2U, 2U, 32U, 0x20U), false, 18U) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     session.fail_closed() && arbiter.fail_closed() &&
                     arbiter.high_speed_stream_uart_records() == 1U &&
                     arbiter.high_speed_stream_accepted_bytes() == 32U,
                 "record-limit overrun reached physical-write admission");
  }
  {
    constexpr Phase6HighSpeedStreamLimits forty_eight_bytes{2U, 48U, 32U};
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 0x3011U);
    TransferToken first{};
    report.check(session.begin(0x7111U, Direction::Downlink,
                               forty_eight_bytes, 0U) ==
                         Phase6HighSpeedRadioSessionStatus::StreamStarted &&
                     session.observe_aux(0U, true) ==
                         Phase6HighSpeedRadioSessionStatus::StreamActive &&
                     accept_action(session,
                                   radio_action(1U, 1U, 32U, 0x30U),
                                   false, 15U, first) &&
                     session.retain_adapter_action(
                         radio_action(2U, 2U, 32U, 0x40U), false, 18U) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     session.fail_closed() && arbiter.fail_closed() &&
                     arbiter.high_speed_stream_uart_records() == 1U &&
                     arbiter.high_speed_stream_accepted_bytes() == 32U,
                 "accepted-byte-limit overrun reached physical-write admission");
  }
}

void test_exact_final_tail_and_explicit_tx_complete(TestReport& report) {
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 0x4001U);
    TransferToken first{};
    TransferToken final_token{};
    report.check(begin_downlink(session, 0x7201U) &&
                     accept_action(session,
                                   radio_action(1U, 1U, 16U, 1U),
                                   false, 15U, first) &&
                     accept_action(session,
                                   radio_action(2U, 2U, 16U, 2U),
                                   true, 18U, final_token) &&
                     release_latest_aux_credit(session, final_token, 19U) &&
                     session.complete_stream_from_remote_arrival(first, 36U) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     session.fail_closed() && arbiter.fail_closed(),
                 "non-final remote TransferToken did not fail closed");
  }
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 0x4002U);
    TransferToken final_token{};
    report.check(begin_downlink(session, 0x7202U) &&
                     accept_action(session,
                                   radio_action(1U, 1U, 32U, 3U),
                                   true, 15U, final_token) &&
                     release_latest_aux_credit(session, final_token, 16U) &&
                     session.observe_local_radio_status(33U, true, false,
                                                        true) ==
                         Phase6HighSpeedRadioSessionStatus::StreamActive &&
                     session.observe_local_radio_status(34U, true, true,
                                                        true) ==
                         Phase6HighSpeedRadioSessionStatus::StreamActive &&
                     session.complete_stream_from_explicit_tx_complete(
                         final_token, 35U) ==
                         Phase6HighSpeedRadioSessionStatus::
                             ExplicitRestoreRequired &&
                     arbiter.explicit_restore_required() &&
                     session.restore_standard(true, 36U) ==
                         Phase6HighSpeedRadioSessionStatus::StandardRestored,
                 "fresh explicit TX-complete proof did not close the stream");
  }
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 0x4003U);
    TransferToken final_token{};
    report.check(begin_downlink(session, 0x7203U) &&
                     accept_action(session,
                                   radio_action(1U, 1U, 32U, 4U),
                                   true, 15U, final_token) &&
                     release_latest_aux_credit(session, final_token, 16U) &&
                     session.observe_local_radio_status(33U, true, true,
                                                        true) ==
                         Phase6HighSpeedRadioSessionStatus::StreamActive &&
                     session.complete_stream_from_explicit_tx_complete(
                         final_token, 34U) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     session.fail_closed() && arbiter.fail_closed(),
                 "inherited TX-complete HIGH was accepted without a fresh LOW");
  }
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 0x4004U);
    TransferToken final_token{};
    report.check(begin_downlink(session, 0x7204U) &&
                     accept_action(session,
                                   radio_action(1U, 1U, 32U, 5U),
                                   true, 15U, final_token) &&
                     release_latest_aux_credit(session, final_token, 16U) &&
                     session.complete_stream_from_remote_arrival(
                         final_token, 33U) ==
                         Phase6HighSpeedRadioSessionStatus::
                             ExplicitRestoreRequired &&
                     session.complete_stream_from_remote_arrival(
                         final_token, 34U) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     session.fail_closed() && arbiter.fail_closed(),
                 "duplicate final tail did not fail closed");
  }
}

void test_invalid_begin_fails_closed(TestReport& report) {
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 0U);
    report.check(session.begin(1U, Direction::Downlink, kLimits, 0U) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     arbiter.fail_closed(),
                 "zero session did not fail closed");
  }
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 1U);
    report.check(session.begin(1U, Direction::Mixed, kLimits, 0U) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     arbiter.fail_closed(),
                 "mixed direction did not fail closed");
  }
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 1U);
    const Direction invalid_direction = static_cast<Direction>(0xFFU);
    report.check(session.begin(1U, invalid_direction, kLimits, 0U) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     arbiter.fail_closed(),
                 "out-of-domain direction did not fail closed");
  }
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 1U);
    constexpr Phase6HighSpeedStreamLimits invalid_limits{};
    report.check(session.begin(1U, Direction::Downlink, invalid_limits, 0U) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     arbiter.fail_closed(),
                 "invalid stream limits did not fail closed");
  }
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 1U);
    report.check(begin_downlink(session, 0x7205U) &&
                     session.retain_adapter_action(
                         radio_action(1U, 1U, 0U, 0U), false, 1U) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     arbiter.fail_closed(),
                 "zero-byte adapter action did not fail closed");
  }
  {
    Phase6RadioWriterArbiter arbiter{};
    Phase6HighSpeedRadioSession session(arbiter, 1U);
    report.check(begin_downlink(session, 0x7206U) &&
                     session.retain_adapter_action(
                         radio_action(1U, 1U, 33U, 0U), false, 1U) ==
                         Phase6HighSpeedRadioSessionStatus::FailClosed &&
                     arbiter.fail_closed(),
                 "oversize adapter action did not fail closed");
  }
}

}  // namespace

TestReport run_phase6_high_speed_radio_session_test(
    const std::string& test_id, std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-HS-RADIO-SESSION-001") {
    test_zero_retry_remote_tail_and_explicit_restore(report);
    test_gap_and_400_byte_admission(report);
    test_aux_stability_and_three_ms_gap(report);
  } else if (test_id == "UT-HS-RADIO-SESSION-002") {
    test_partial_unadmitted_stale_and_time_fail_closed(report);
    test_stream_limits_fail_before_physical_write(report);
  } else if (test_id == "UT-HS-RADIO-SESSION-003") {
    test_exact_final_tail_and_explicit_tx_complete(report);
    test_invalid_begin_fails_closed(report);
  } else {
    report.check(false, "unknown Phase6 high-speed radio session test ID");
  }

  report.trace.record({0U, "host", "HS_RADIO_SESSION", 0U,
                       report.passed ? "PASS" : "FAIL", true,
                       0U, 0U, 0U});
  return report;
}

}  // namespace vc_lora::test
