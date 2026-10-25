#include "test_support.hpp"

#include <cstdint>
#include <string>
#include <type_traits>

#include "vc_lora/bulk_heartbeat_sla.hpp"

namespace vc_lora::test {
namespace {

constexpr std::uint32_t kFirstTag = 0xA1B2C3D4U;
constexpr std::uint32_t kSecondTag = 0x10293847U;

static_assert(!std::is_copy_constructible_v<BulkHeartbeatSlaLedger>);
static_assert(!std::is_copy_assignable_v<BulkHeartbeatSlaLedger>);
static_assert(!std::is_move_constructible_v<BulkHeartbeatSlaLedger>);
static_assert(!std::is_move_assignable_v<BulkHeartbeatSlaLedger>);

void test_exact_happy_path_and_evidence(TestReport& report) {
  BulkHeartbeatSlaLedger ledger{kFirstTag};
  report.check(
      ledger.capture_baseline(1'000U) ==
              BulkHeartbeatSlaStatus::BaselineCaptured &&
          ledger.capture_baseline(2'000U) ==
              BulkHeartbeatSlaStatus::BaselineCaptured &&
          ledger.start_request(2'100U) ==
              BulkHeartbeatSlaStatus::RequestStarted,
      "latest real pre-request heartbeat did not establish the SLA epoch");

  report.check(
      ledger.accept_heartbeat(3'000U) ==
              BulkHeartbeatSlaStatus::HeartbeatAccepted &&
          ledger.accept_heartbeat(5'500U) ==
              BulkHeartbeatSlaStatus::HeartbeatAccepted &&
          ledger.accept_heartbeat(8'000U) ==
              BulkHeartbeatSlaStatus::HeartbeatAccepted &&
          ledger.complete_final_parameter(10'500U) ==
              BulkHeartbeatSlaStatus::EvidenceReady,
      "inclusive 2500-ms heartbeat boundaries did not complete");

  const BulkHeartbeatSlaEvidence evidence = ledger.evidence();
  report.check(
      evidence.transfer_tag == kFirstTag && evidence.heartbeat_count == 3U &&
          evidence.last_heartbeat_request_id == 3U &&
          evidence.request_started_ms == 2'100U &&
          evidence.final_parameter_committed_ms == 10'500U &&
          evidence.request_to_last_parameter_ms == 8'400U &&
          evidence.first_heartbeat_gap_ms == 1'000U &&
          evidence.max_heartbeat_gap_ms == 2'500U &&
          evidence.post_heartbeat_gap_ms == 2'500U && evidence.complete,
      "terminal heartbeat evidence did not match the observed timeline");
}

void test_each_deadline_fails_at_plus_one(TestReport& report) {
  {
    BulkHeartbeatSlaLedger ledger{kFirstTag};
    report.check(
        ledger.capture_baseline(0U) ==
                BulkHeartbeatSlaStatus::BaselineCaptured &&
            ledger.start_request(2'500U) ==
                BulkHeartbeatSlaStatus::RequestStarted,
        "request-start heartbeat age inclusive boundary was rejected");
  }
  {
    BulkHeartbeatSlaLedger ledger{kFirstTag};
    report.check(
        ledger.capture_baseline(0U) ==
                BulkHeartbeatSlaStatus::BaselineCaptured &&
            ledger.start_request(2'501U) ==
                BulkHeartbeatSlaStatus::HeartbeatDeadlineExceeded &&
            ledger.fail_closed(),
        "request-start heartbeat age +1 ms did not fail closed");
  }
  {
    BulkHeartbeatSlaLedger ledger{kFirstTag};
    report.check(
        ledger.capture_baseline(100U) ==
                BulkHeartbeatSlaStatus::BaselineCaptured &&
            ledger.start_request(101U) ==
                BulkHeartbeatSlaStatus::RequestStarted &&
            ledger.accept_heartbeat(2'600U) ==
                BulkHeartbeatSlaStatus::HeartbeatAccepted,
        "first heartbeat inclusive boundary was rejected");
  }
  {
    BulkHeartbeatSlaLedger ledger{kFirstTag};
    report.check(
        ledger.capture_baseline(100U) ==
                BulkHeartbeatSlaStatus::BaselineCaptured &&
            ledger.start_request(101U) ==
                BulkHeartbeatSlaStatus::RequestStarted &&
            ledger.accept_heartbeat(2'601U) ==
                BulkHeartbeatSlaStatus::HeartbeatDeadlineExceeded &&
            ledger.fail_closed(),
        "first heartbeat gap +1 ms did not fail closed");
  }
  {
    BulkHeartbeatSlaLedger ledger{kFirstTag};
    report.check(
        ledger.capture_baseline(100U) ==
                BulkHeartbeatSlaStatus::BaselineCaptured &&
            ledger.start_request(101U) ==
                BulkHeartbeatSlaStatus::RequestStarted &&
            ledger.accept_heartbeat(1'000U) ==
                BulkHeartbeatSlaStatus::HeartbeatAccepted &&
            ledger.accept_heartbeat(3'501U) ==
                BulkHeartbeatSlaStatus::HeartbeatDeadlineExceeded &&
            ledger.fail_closed(),
        "consecutive heartbeat gap +1 ms did not fail closed");
  }
  {
    BulkHeartbeatSlaLedger ledger{kFirstTag};
    report.check(
        ledger.capture_baseline(100U) ==
                BulkHeartbeatSlaStatus::BaselineCaptured &&
            ledger.start_request(101U) ==
                BulkHeartbeatSlaStatus::RequestStarted &&
            ledger.accept_heartbeat(1'000U) ==
                BulkHeartbeatSlaStatus::HeartbeatAccepted &&
            ledger.complete_final_parameter(3'501U) ==
                BulkHeartbeatSlaStatus::HeartbeatDeadlineExceeded &&
            ledger.fail_closed(),
        "post-heartbeat gap +1 ms did not fail closed");
  }
  {
    BulkHeartbeatSlaLedger ledger{kFirstTag};
    report.check(
        ledger.capture_baseline(100U) ==
                BulkHeartbeatSlaStatus::BaselineCaptured &&
            ledger.start_request(101U) ==
                BulkHeartbeatSlaStatus::RequestStarted &&
            ledger.accept_heartbeat(29'000U) ==
                BulkHeartbeatSlaStatus::HeartbeatDeadlineExceeded,
        "an already-invalid long first gap was not rejected");
  }
  {
    BulkHeartbeatSlaLedger ledger{kFirstTag};
    report.check(
        ledger.capture_baseline(0U) ==
                BulkHeartbeatSlaStatus::BaselineCaptured &&
            ledger.start_request(1U) ==
                BulkHeartbeatSlaStatus::RequestStarted &&
            ledger.accept_heartbeat(2'000U) ==
                BulkHeartbeatSlaStatus::HeartbeatAccepted &&
            ledger.accept_heartbeat(29'000U) ==
                BulkHeartbeatSlaStatus::HeartbeatDeadlineExceeded,
        "long in-stream gap did not fail before the completion deadline");
  }
  {
    BulkHeartbeatSlaLedger ledger{kFirstTag};
    bool exact_boundary =
        ledger.capture_baseline(0U) ==
            BulkHeartbeatSlaStatus::BaselineCaptured &&
        ledger.start_request(1U) ==
            BulkHeartbeatSlaStatus::RequestStarted;
    for (std::uint64_t now_ms = 2'500U; now_ms <= 30'000U;
         now_ms += 2'500U) {
      exact_boundary =
          exact_boundary &&
          ledger.accept_heartbeat(now_ms) ==
              BulkHeartbeatSlaStatus::HeartbeatAccepted;
    }
    exact_boundary =
        exact_boundary &&
        ledger.complete_final_parameter(30'001U) ==
            BulkHeartbeatSlaStatus::EvidenceReady;
    report.check(exact_boundary,
                 "30-second completion inclusive boundary was rejected");
  }
  {
    BulkHeartbeatSlaLedger ledger{kFirstTag};
    bool plus_one =
        ledger.capture_baseline(0U) ==
            BulkHeartbeatSlaStatus::BaselineCaptured &&
        ledger.start_request(1U) ==
            BulkHeartbeatSlaStatus::RequestStarted;
    for (std::uint64_t now_ms = 2'500U; now_ms <= 30'000U;
         now_ms += 2'500U) {
      plus_one =
          plus_one &&
          ledger.accept_heartbeat(now_ms) ==
              BulkHeartbeatSlaStatus::HeartbeatAccepted;
    }
    plus_one =
        plus_one &&
        ledger.complete_final_parameter(30'002U) ==
            BulkHeartbeatSlaStatus::CompletionDeadlineExceeded &&
        ledger.fail_closed();
    report.check(plus_one,
        "30-second completion boundary +1 ms did not fail closed");
  }
}

void test_missing_or_invalid_events_fail_closed(TestReport& report) {
  {
    BulkHeartbeatSlaLedger ledger{kFirstTag};
    report.check(ledger.start_request(10U) ==
                         BulkHeartbeatSlaStatus::MissingBaseline &&
                     ledger.fail_closed(),
                 "request without a real baseline heartbeat did not latch");
  }
  {
    BulkHeartbeatSlaLedger ledger{kFirstTag};
    report.check(
        ledger.capture_baseline(10U) ==
                BulkHeartbeatSlaStatus::BaselineCaptured &&
            ledger.start_request(11U) ==
                BulkHeartbeatSlaStatus::RequestStarted &&
            ledger.complete_final_parameter(12U) ==
                BulkHeartbeatSlaStatus::MissingHeartbeat &&
            ledger.fail_closed(),
        "completion without an in-stream real heartbeat did not latch");
  }
  {
    BulkHeartbeatSlaLedger ledger{kFirstTag};
    report.check(
        ledger.capture_baseline(10U) ==
                BulkHeartbeatSlaStatus::BaselineCaptured &&
            ledger.accept_heartbeat(11U) ==
                BulkHeartbeatSlaStatus::InvalidState &&
            ledger.fail_closed(),
        "heartbeat before request start did not fail closed");
  }
  {
    BulkHeartbeatSlaLedger ledger{0U};
    report.check(ledger.fail_closed() &&
                     ledger.last_error() ==
                         BulkHeartbeatSlaStatus::InvalidConfiguration &&
                     ledger.capture_baseline(1U) ==
                         BulkHeartbeatSlaStatus::Latched &&
                     ledger.seal_session() ==
                         BulkHeartbeatSlaStatus::Sealed &&
                     ledger.rearm(kFirstTag, 2U) ==
                         BulkHeartbeatSlaStatus::Rearmed &&
                     !ledger.fail_closed() && !ledger.sealed(),
                 "zero-tag owner was not inert or explicitly recoverable");
  }
}

void test_clock_regression_and_post_complete_data(TestReport& report) {
  {
    BulkHeartbeatSlaLedger ledger{kFirstTag};
    report.check(
        ledger.capture_baseline(100U) ==
                BulkHeartbeatSlaStatus::BaselineCaptured &&
            ledger.start_request(99U) ==
                BulkHeartbeatSlaStatus::ClockRegression &&
            ledger.fail_closed(),
        "clock regression at request start did not fail closed");
  }
  {
    BulkHeartbeatSlaLedger ledger{kFirstTag};
    report.check(
        ledger.capture_baseline(100U) ==
                BulkHeartbeatSlaStatus::BaselineCaptured &&
            ledger.start_request(101U) ==
                BulkHeartbeatSlaStatus::RequestStarted &&
            ledger.accept_heartbeat(1'000U) ==
                BulkHeartbeatSlaStatus::HeartbeatAccepted &&
            ledger.complete_final_parameter(2'000U) ==
                BulkHeartbeatSlaStatus::EvidenceReady &&
            ledger.accept_heartbeat(2'001U) ==
                BulkHeartbeatSlaStatus::PostCompleteData &&
            ledger.fail_closed(),
        "post-completion heartbeat did not invalidate the evidence owner");
  }
}

void test_explicit_seal_and_fresh_rearm(TestReport& report) {
  BulkHeartbeatSlaLedger ledger{kFirstTag};
  report.check(
      ledger.capture_baseline(100U) ==
              BulkHeartbeatSlaStatus::BaselineCaptured &&
          ledger.start_request(101U) ==
              BulkHeartbeatSlaStatus::RequestStarted &&
          ledger.accept_heartbeat(1'000U) ==
              BulkHeartbeatSlaStatus::HeartbeatAccepted &&
          ledger.complete_final_parameter(2'000U) ==
              BulkHeartbeatSlaStatus::EvidenceReady,
      "rearm fixture did not produce evidence");
  const BulkHeartbeatSlaEvidence previous = ledger.evidence();
  report.check(
      ledger.rearm(kSecondTag, 2'001U) ==
              BulkHeartbeatSlaStatus::SessionNotSealed &&
          ledger.evidence().complete &&
          ledger.seal_session() == BulkHeartbeatSlaStatus::Sealed &&
          ledger.rearm(kFirstTag, 2'002U) ==
              BulkHeartbeatSlaStatus::TransferTagReuse &&
          ledger.evidence().heartbeat_count == previous.heartbeat_count &&
          ledger.rearm(0U, 2'003U) ==
              BulkHeartbeatSlaStatus::InvalidConfiguration &&
          ledger.rearm(kSecondTag, 2'004U) ==
              BulkHeartbeatSlaStatus::Rearmed,
      "seal/rearm did not preserve then rotate the evidence epoch");
  const BulkHeartbeatSlaEvidence reset = ledger.evidence();
  report.check(reset.transfer_tag == kSecondTag &&
                   reset.heartbeat_count == 0U &&
                   reset.last_heartbeat_request_id == 0U &&
                   reset.request_started_ms == 0U &&
                   reset.final_parameter_committed_ms == 0U &&
                   !reset.complete && !ledger.fail_closed() &&
                   !ledger.sealed(),
               "fresh rearm retained stale heartbeat evidence");

  BulkHeartbeatSlaLedger sealed_owner{kFirstTag};
  report.check(
      sealed_owner.capture_baseline(10U) ==
              BulkHeartbeatSlaStatus::BaselineCaptured &&
          sealed_owner.start_request(11U) ==
              BulkHeartbeatSlaStatus::RequestStarted &&
          sealed_owner.accept_heartbeat(20U) ==
              BulkHeartbeatSlaStatus::HeartbeatAccepted &&
          sealed_owner.complete_final_parameter(30U) ==
              BulkHeartbeatSlaStatus::EvidenceReady &&
          sealed_owner.seal_session() == BulkHeartbeatSlaStatus::Sealed &&
          sealed_owner.accept_heartbeat(31U) ==
              BulkHeartbeatSlaStatus::PostCompleteData &&
          sealed_owner.fail_closed() &&
          !sealed_owner.evidence().complete,
      "post-seal heartbeat did not revoke terminal SLA evidence");
}

}  // namespace

TestReport run_bulk_heartbeat_sla_test(const std::string& test_id,
                                       std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-BULK-HB-SLA-001") {
    test_exact_happy_path_and_evidence(report);
  } else if (test_id == "UT-BULK-HB-SLA-002") {
    test_each_deadline_fails_at_plus_one(report);
  } else if (test_id == "UT-BULK-HB-SLA-003") {
    test_missing_or_invalid_events_fail_closed(report);
  } else if (test_id == "UT-BULK-HB-SLA-004") {
    test_clock_regression_and_post_complete_data(report);
  } else if (test_id == "UT-BULK-HB-SLA-005") {
    test_explicit_seal_and_fresh_rearm(report);
  } else {
    report.check(false, "unknown bulk heartbeat SLA test ID");
  }

  report.trace.record({0U, "host", "BULK_HB_SLA", 0U,
                       report.passed ? "PASS" : "FAIL", true, 0U, 0U, 0U});
  return report;
}

}  // namespace vc_lora::test
