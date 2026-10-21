#include <cstddef>
#include <cstdint>
#include <iostream>

#include "../../../firmware/high_speed/e220_high_speed_transport_model.hpp"

namespace {

using vc_lora::experimental::AdmissionResult;
using vc_lora::experimental::Direction;
using vc_lora::experimental::DrainProof;
using vc_lora::experimental::E220UartAdmissionGate;
using vc_lora::experimental::TransferToken;
using vc_lora::experimental::WriteCommitResult;

struct TestReport {
  std::size_t checks = 0U;
  std::size_t failures = 0U;

  void check(bool condition, const char* message) noexcept {
    ++checks;
    if (!condition) {
      ++failures;
      std::cerr << "FAIL: " << message << '\n';
    }
  }
};

void make_aux_ready(E220UartAdmissionGate& gate) noexcept {
  gate.observe_aux(0U, true);
}

TransferToken commit_one(E220UartAdmissionGate& gate, std::uint32_t now,
                         Direction direction, TestReport& report) noexcept {
  report.check(gate.assess(now, direction, 32U) == AdmissionResult::Ready,
               "test setup write was not admitted");
  const auto write = gate.commit_write(now, direction, 32U, 32U);
  report.check(write.result == WriteCommitResult::Committed,
               "test setup write did not commit");
  return write.token;
}

TransferToken token_from_other_gate(std::uint64_t session_id,
                                    std::uint32_t initial_generation,
                                    Direction direction,
                                    TestReport& report) noexcept {
  E220UartAdmissionGate gate(session_id, 0U, initial_generation);
  make_aux_ready(gate);
  return commit_one(gate, 15U, direction, report);
}

void test_continuous_high_unblocks_chunk_thirteen(TestReport& report) {
  E220UartAdmissionGate gate(0xC01171A0ULL);
  make_aux_ready(gate);

  std::uint32_t now_ms = E220UartAdmissionGate::aux_stable_ms;
  TransferToken latest{};
  TransferToken first{};
  std::size_t committed = 0U;
  for (std::size_t chunk = 0U; chunk < 12U; ++chunk) {
    // This is a newly sampled HIGH level every 3 ms, not a cached level.
    gate.observe_aux(now_ms, true);
    const AdmissionResult admission =
        gate.assess(now_ms, Direction::Downlink, 32U);
    report.check(admission == AdmissionResult::Ready,
                 "one of the first twelve writes was not admitted");
    if (admission != AdmissionResult::Ready) {
      break;
    }
    const auto write =
        gate.commit_write(now_ms, Direction::Downlink, 32U, 32U);
    report.check(write.result == WriteCommitResult::Committed,
                 "one of the first twelve writes did not commit");
    if (write.result != WriteCommitResult::Committed) {
      break;
    }
    if (chunk == 0U) {
      first = write.token;
    }
    latest = write.token;
    ++committed;
    now_ms += E220UartAdmissionGate::minimum_gap_ms;
  }

  report.check(committed == 12U && gate.accepted_wire_bytes() == 384U &&
                   gate.buffered_bytes() == 384U,
               "baseline did not reach exactly 384 accepted bytes");
  report.check(gate.assess(now_ms, Direction::Downlink, 32U) ==
                   AdmissionResult::Backpressure,
               "chunk 13 did not reproduce the 400-byte backpressure bound");
  report.check(!gate.release_buffer_credit_from_local_aux(now_ms, latest),
               "cached AUX HIGH was incorrectly accepted as fresh evidence");

  gate.observe_aux(now_ms, true);
  const bool continuous_high_credit =
      gate.release_buffer_credit_from_local_aux(now_ms, latest);
  report.check(continuous_high_credit,
               "fresh post-write continuous AUX HIGH gave no buffer credit");
  report.check(gate.buffered_bytes() == 0U,
               "continuous AUX HIGH did not release local buffer credit");
  report.check(gate.assess(now_ms, Direction::Downlink, 32U) ==
                   AdmissionResult::Ready,
               "chunk 13 stalled despite a fresh continuous HIGH sample");
  report.check(gate.direction_locked(),
               "buffer credit incorrectly unlocked RF direction");
  report.check(!gate.unlock_direction(DrainProof{}),
               "buffer credit created or accepted an implicit drain proof");
  report.check(!gate.release_buffer_credit_from_local_aux(now_ms, first),
               "stale token was accepted after cumulative credit");

  std::cout << "committed=" << committed
            << " buffered_after_credit=" << gate.buffered_bytes()
            << " thirteenth_admission=Ready direction_locked=true\n";
}

void test_high_must_be_fresh_and_after_minimum_gap(TestReport& report) {
  E220UartAdmissionGate gate(0xC01171A1ULL);
  make_aux_ready(gate);
  const TransferToken token =
      commit_one(gate, E220UartAdmissionGate::aux_stable_ms,
                 Direction::Downlink, report);

  gate.observe_aux(16U, true);
  report.check(!gate.release_buffer_credit_from_local_aux(16U, token),
               "continuous HIGH before the 3-ms gap returned credit");
  report.check(!gate.release_buffer_credit_from_local_aux(18U, token),
               "an earlier HIGH sample was reused after the gap");
  gate.observe_aux(18U, true);
  report.check(gate.release_buffer_credit_from_local_aux(18U, token),
               "fresh HIGH at the 3-ms boundary did not return credit");
  report.check(gate.direction_locked(),
               "fresh HIGH credit changed direction ownership");
}

void test_any_low_retains_stable_low_high_path(TestReport& report) {
  E220UartAdmissionGate gate(0xC01171A2ULL);
  make_aux_ready(gate);
  const TransferToken token = commit_one(gate, 15U, Direction::Downlink,
                                         report);

  gate.observe_aux(16U, false);
  gate.observe_aux(18U, true);
  gate.observe_aux(21U, true);
  report.check(!gate.release_buffer_credit_from_local_aux(21U, token),
               "LOW was bypassed by the continuous-HIGH credit path");
  report.check(!gate.release_buffer_credit_from_local_aux(32U, token),
               "LOW/HIGH edge returned credit before 15-ms stability");
  report.check(gate.release_buffer_credit_from_local_aux(33U, token),
               "stable LOW/HIGH edge no longer returns buffer credit");
  report.check(gate.direction_locked(),
               "LOW/HIGH buffer credit unlocked direction");
}

void test_exact_latest_identity_and_one_shot(TestReport& report) {
  constexpr std::uint64_t session = 0xC01171A3ULL;
  E220UartAdmissionGate gate(session);
  make_aux_ready(gate);
  const TransferToken first =
      commit_one(gate, 15U, Direction::Downlink, report);
  const TransferToken latest =
      commit_one(gate, 18U, Direction::Downlink, report);

  const TransferToken wrong_session =
      token_from_other_gate(session + 1U, 0U, Direction::Downlink, report);
  const TransferToken wrong_generation =
      token_from_other_gate(session, 1U, Direction::Downlink, report);
  const TransferToken wrong_direction =
      token_from_other_gate(session, 0U, Direction::Uplink, report);

  gate.observe_aux(21U, true);
  report.check(!gate.release_buffer_credit_from_local_aux(21U, first),
               "non-latest tail returned cumulative buffer credit");
  report.check(!gate.release_buffer_credit_from_local_aux(21U, wrong_session),
               "wrong session returned buffer credit");
  report.check(
      !gate.release_buffer_credit_from_local_aux(21U, wrong_generation),
      "wrong generation returned buffer credit");
  report.check(!gate.release_buffer_credit_from_local_aux(21U, wrong_direction),
               "wrong direction returned buffer credit");
  report.check(gate.release_buffer_credit_from_local_aux(21U, latest),
               "exact latest token did not return cumulative credit");

  gate.observe_aux(24U, true);
  report.check(!gate.release_buffer_credit_from_local_aux(24U, latest),
               "duplicate latest token returned buffer credit twice");
  report.check(gate.buffered_bytes() == 0U && gate.direction_locked(),
               "one-shot credit changed more than the local buffer ledger");
}

}  // namespace

int main() {
  TestReport report{};
  test_continuous_high_unblocks_chunk_thirteen(report);
  test_high_must_be_fresh_and_after_minimum_gap(report);
  test_any_low_retains_stable_low_high_path(report);
  test_exact_latest_identity_and_one_shot(report);

  std::cout << "UT-E220-CONTINUOUS-AUX-CREDIT-001 checks=" << report.checks
            << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
