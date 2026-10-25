#include "test_support.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <type_traits>

#include "fixtures/mavlink_fixtures.hpp"
#include "vc_lora/bulk_tx_lease.hpp"

namespace vc_lora::test {
namespace {

constexpr std::uint32_t kTransferTag = 0xD4C3B2A1U;

static_assert(!std::is_copy_constructible_v<BulkDataTxLease>,
              "a scheduler lease must not be copy-constructed");
static_assert(!std::is_copy_assignable_v<BulkDataTxLease>,
              "a scheduler lease must not be copy-assigned");
static_assert(!std::is_move_constructible_v<BulkDataTxLease>,
              "a scheduler lease must not be move-constructed");
static_assert(!std::is_move_assignable_v<BulkDataTxLease>,
              "a scheduler lease must not be move-assigned");

bool same_frame(const MavlinkFrame& expected, const std::uint8_t* actual,
                std::size_t actual_size) {
  return actual != nullptr && actual_size == expected.size &&
         std::equal(expected.bytes.begin(),
                    expected.bytes.begin() + expected.size, actual);
}

BulkDataDecodedFragment decode_current(const BulkDataTxLease& sender,
                                       TestReport& report) {
  BulkDataDecodedFragment decoded{};
  const BulkDataFragment* fragment = sender.current_fragment();
  report.check(fragment != nullptr, "sender did not expose a cached fragment");
  if (fragment != nullptr) {
    report.check(BulkDataWireCodec::decode_fragment(*fragment, decoded) ==
                     BulkDataWireStatus::FragmentReady,
                 "cached fragment was not a valid VCB1 fragment");
  }
  return decoded;
}

void test_begin_and_physical_rejection(TestReport& report) {
  MavlinkFrameScheduler scheduler{};
  const MavlinkFrame parameter =
      fixtures::param_value_v2(7U, "TX_RETRY", 1.25F, 0U, 932U);
  report.check(parameter.size == 37U &&
                   scheduler.enqueue(parameter) == MavlinkEnqueueStatus::Queued,
               "PARAM_VALUE fixture was not queued");

  BulkDataTxLease sender{scheduler, kTransferTag, 10U};
  report.check(sender.begin() == BulkDataTxLeaseStatus::Ready,
               "begin did not lease one complete PARAM_VALUE");
  report.check(sender.active() && sender.source_frame_size() == 37U &&
                   sender.current_fragment_index() == 0U &&
                   sender.next_wire_ordinal() == 10U,
               "begin changed lease/source/ordinal accounting");
  const BulkDataDecodedFragment head = decode_current(sender, report);
  report.check(head.kind == BulkDataFragmentKind::ParameterHead &&
                   head.wire_ordinal == 10U,
               "begin did not cache the exact PARAM head");

  BulkDataFragment cached{};
  if (sender.current_fragment() != nullptr) {
    cached = *sender.current_fragment();
  }
  report.check(sender.complete_fragment(TxResult::Rejected) ==
                   BulkDataTxLeaseStatus::FragmentRejected,
               "physical rejection was not retained for retry");
  report.check(sender.current_fragment() != nullptr &&
                   *sender.current_fragment() == cached &&
                   sender.current_fragment_index() == 0U &&
                   sender.next_wire_ordinal() == 10U,
               "physical rejection changed the cached fragment or ordinal");
  report.check(scheduler.size() == 1U &&
                   scheduler.queued_bytes() == parameter.size &&
                   scheduler.diagnostics().frames_forwarded == 0U &&
                   scheduler.diagnostics().bytes_forwarded == 0U &&
                   scheduler.diagnostics().rejected_send_attempts == 0U,
               "physical rejection consumed or rejected source scheduler bytes");
  report.check(sender.begin() == BulkDataTxLeaseStatus::Busy,
               "a second begin replaced an active frame lease");
}

void test_tail_is_the_only_source_commit(TestReport& report) {
  MavlinkFrameScheduler scheduler{};
  const MavlinkFrame parameter =
      fixtures::param_value_v2(8U, "TX_COMMIT", 2.5F, 0U, 932U);
  report.check(scheduler.enqueue(parameter) == MavlinkEnqueueStatus::Queued,
               "PARAM_VALUE commit fixture was not queued");

  BulkDataTxLease sender{scheduler, kTransferTag, 20U};
  report.check(sender.begin() == BulkDataTxLeaseStatus::Ready &&
                   sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FragmentAccepted,
               "accepted PARAM head did not advance to its cached tail");
  const BulkDataDecodedFragment tail = decode_current(sender, report);
  report.check(tail.kind == BulkDataFragmentKind::ParameterTail &&
                   tail.wire_ordinal == 21U &&
                   sender.current_fragment_index() == 1U &&
                   sender.next_wire_ordinal() == 21U,
               "accepted PARAM head changed tail/ordinal accounting");
  report.check(scheduler.size() == 1U &&
                   scheduler.queued_bytes() == parameter.size &&
                   scheduler.diagnostics().frames_forwarded == 0U &&
                   scheduler.diagnostics().bytes_forwarded == 0U,
               "accepted PARAM head consumed source bytes");

  BulkDataFragment cached_tail{};
  if (sender.current_fragment() != nullptr) {
    cached_tail = *sender.current_fragment();
  }
  report.check(sender.complete_fragment(TxResult::Rejected) ==
                       BulkDataTxLeaseStatus::FragmentRejected &&
                   sender.current_fragment() != nullptr &&
                   *sender.current_fragment() == cached_tail &&
                   sender.next_wire_ordinal() == 21U,
               "rejected PARAM tail was not byte-identical on retry");
  report.check(sender.complete_fragment(TxResult::Accepted) ==
                   BulkDataTxLeaseStatus::FrameCommitted,
               "accepted PARAM tail did not commit its source frame");
  report.check(!sender.active() && sender.current_fragment() == nullptr &&
                   sender.next_wire_ordinal() == 22U && scheduler.empty() &&
                   scheduler.diagnostics().frames_forwarded == 1U &&
                   scheduler.diagnostics().bytes_forwarded == parameter.size,
               "PARAM tail did not perform exactly one full-frame commit");
  report.check(sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::NoLease &&
                   scheduler.diagnostics().frames_forwarded == 1U &&
                   scheduler.diagnostics().bytes_forwarded == parameter.size,
               "post-release completion committed source bytes twice");

  const MavlinkFrame heartbeat = fixtures::heartbeat_v2(9U);
  report.check(scheduler.enqueue(heartbeat) == MavlinkEnqueueStatus::Queued &&
                   sender.begin() == BulkDataTxLeaseStatus::Ready,
               "HEARTBEAT fixture was not leased");
  const BulkDataDecodedFragment heartbeat_head =
      decode_current(sender, report);
  report.check(heartbeat_head.kind == BulkDataFragmentKind::HeartbeatHead &&
                   heartbeat_head.wire_ordinal == 22U,
               "HEARTBEAT head kind/ordinal changed");
  report.check(sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FragmentAccepted &&
                   decode_current(sender, report).kind ==
                       BulkDataFragmentKind::HeartbeatTail &&
                   sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FrameCommitted,
               "HEARTBEAT did not commit only after its two fragments");
  report.check(scheduler.diagnostics().frames_forwarded == 2U &&
                   scheduler.diagnostics().bytes_forwarded ==
                       parameter.size + heartbeat.size &&
                   sender.next_wire_ordinal() == 24U,
               "HEARTBEAT full-frame commit accounting changed");
}

void test_frame_types_cannot_interleave(TestReport& report) {
  MavlinkFrameScheduler scheduler{};
  const MavlinkFrame parameter =
      fixtures::param_value_v2(10U, "NO_INTERLEAVE", 3.5F, 0U, 932U);
  const MavlinkFrame heartbeat = fixtures::heartbeat_v2(11U);
  report.check(scheduler.enqueue(parameter) == MavlinkEnqueueStatus::Queued,
               "interleave PARAM_VALUE fixture was not queued");

  BulkDataTxLease sender{scheduler, kTransferTag, 30U};
  report.check(sender.begin() == BulkDataTxLeaseStatus::Ready &&
                   decode_current(sender, report).kind ==
                       BulkDataFragmentKind::ParameterHead,
               "PARAM head was not selected before heartbeat arrival");
  report.check(scheduler.enqueue(heartbeat) == MavlinkEnqueueStatus::Queued,
               "heartbeat could not arrive during PARAM lease");
  report.check(sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FragmentAccepted &&
                   decode_current(sender, report).kind ==
                       BulkDataFragmentKind::ParameterTail &&
                   sender.begin() == BulkDataTxLeaseStatus::Busy,
               "heartbeat interleaved between PARAM head and tail");
  report.check(sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FrameCommitted &&
                   sender.begin() == BulkDataTxLeaseStatus::Ready &&
                   decode_current(sender, report).kind ==
                       BulkDataFragmentKind::HeartbeatHead,
               "queued heartbeat did not wait for PARAM lease release");
}

void test_abort_returns_frame_to_standard_mode(TestReport& report) {
  MavlinkFrameScheduler scheduler{};
  const MavlinkFrame parameter =
      fixtures::param_value_v2(12U, "ABORT_FALLBACK", 4.5F, 0U, 932U);
  report.check(scheduler.enqueue(parameter) == MavlinkEnqueueStatus::Queued,
               "abort PARAM_VALUE fixture was not queued");

  BulkDataTxLease sender{scheduler, kTransferTag, 40U};
  report.check(sender.begin() == BulkDataTxLeaseStatus::Ready &&
                   sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FragmentAccepted,
               "abort fixture did not accept its physical head");
  report.check(sender.abort() == BulkDataTxLeaseStatus::Aborted &&
                   !sender.active() && sender.latched() &&
                   sender.last_error() == BulkDataTxLeaseStatus::Aborted &&
                   sender.current_fragment() == nullptr &&
                   sender.next_wire_ordinal() == 41U,
               "abort did not close and release the sender lease");
  report.check(scheduler.size() == 1U &&
                   scheduler.queued_bytes() == parameter.size &&
                   scheduler.diagnostics().rejected_send_attempts == 1U &&
                   scheduler.diagnostics().frames_forwarded == 0U,
               "abort consumed the scheduler source frame");

  std::array<std::uint8_t, kMavlinkMaxFrameBytes> output{};
  const std::size_t size = scheduler.peek(output.data(), output.size());
  report.check(same_frame(parameter, output.data(), size),
               "aborted frame was not byte-exactly available to standard mode");
  report.check(scheduler.complete_send(TxResult::Accepted, size) &&
                   scheduler.empty(),
               "standard mode could not consume the aborted frame");
  report.check(sender.abort() == BulkDataTxLeaseStatus::Latched,
               "aborted transfer resumed without a new tag/session");
}

void test_invalid_and_unsupported_fail_closed(TestReport& report) {
  {
    MavlinkFrameScheduler scheduler{};
    const MavlinkFrame heartbeat = fixtures::heartbeat_v2(13U);
    report.check(scheduler.enqueue(heartbeat) == MavlinkEnqueueStatus::Queued,
                 "invalid-config heartbeat fixture was not queued");
    BulkDataTxLease sender{scheduler, 0U, 0U};
    report.check(sender.begin() ==
                         BulkDataTxLeaseStatus::InvalidConfiguration &&
                     sender.latched() &&
                     sender.last_error() ==
                         BulkDataTxLeaseStatus::InvalidConfiguration &&
                     scheduler.size() == 1U &&
                     scheduler.queued_bytes() == heartbeat.size,
                 "zero transfer tag did not fail closed before scheduler peek");
    report.check(sender.begin() == BulkDataTxLeaseStatus::Latched,
                 "invalid sender resumed after fail-closed latch");
  }

  {
    MavlinkFrameScheduler scheduler{};
    const MavlinkFrame unsupported = fixtures::command_ack_v2(14U);
    report.check(scheduler.enqueue(unsupported) ==
                     MavlinkEnqueueStatus::Queued,
                 "unsupported MAVLink fixture was not queued");
    std::array<std::uint8_t, kMavlinkMaxFrameBytes> output{};
    const std::size_t selected =
        scheduler.peek(output.data(), output.size());
    report.check(same_frame(unsupported, output.data(), selected) &&
                     scheduler.complete_send(TxResult::Rejected, selected),
                 "could not retain an active unsupported standard frame");

    BulkDataTxLease sender{scheduler, kTransferTag, 0U};
    report.check(sender.begin() ==
                         BulkDataTxLeaseStatus::BlockedByActiveFrame &&
                     sender.latched() &&
                     sender.current_fragment() == nullptr &&
                     scheduler.size() == 1U &&
                     scheduler.queued_bytes() == unsupported.size &&
                     scheduler.diagnostics().rejected_send_attempts == 1U,
                 "active unsupported source did not fail closed without loss");

    const std::size_t size = scheduler.peek(output.data(), output.size());
    report.check(same_frame(unsupported, output.data(), size),
                 "unsupported frame was not retained for standard mode");
  }

  {
    MavlinkFrameScheduler scheduler{};
    const MavlinkFrame unsupported_bulk = fixtures::heartbeat_v1(15U);
    report.check(scheduler.enqueue(unsupported_bulk) ==
                     MavlinkEnqueueStatus::Queued,
                 "MAVLink1 heartbeat fixture was not queued");
    BulkDataTxLease sender{scheduler, kTransferTag, 0U};
    report.check(sender.begin() == BulkDataTxLeaseStatus::UnsupportedFrame &&
                     sender.latched() &&
                     sender.last_error() ==
                         BulkDataTxLeaseStatus::UnsupportedFrame &&
                     scheduler.size() == 1U &&
                     scheduler.queued_bytes() == unsupported_bulk.size &&
                     scheduler.diagnostics().rejected_send_attempts == 1U,
                 "eligible but unsupported MAVLink1 frame did not fail closed");

    std::array<std::uint8_t, kMavlinkMaxFrameBytes> output{};
    const std::size_t size = scheduler.peek(output.data(), output.size());
    report.check(same_frame(unsupported_bulk, output.data(), size),
                 "unsupported MAVLink1 frame was lost after bulk rejection");
  }

  {
    MavlinkFrameScheduler scheduler{};
    const MavlinkFrame parameter =
        fixtures::param_value_v2(16U, "PARTIAL_ACTIVE", 5.5F, 0U, 932U);
    report.check(scheduler.enqueue(parameter) == MavlinkEnqueueStatus::Queued,
                 "partial-active PARAM fixture was not queued");
    std::array<std::uint8_t, 10U> prefix{};
    const std::size_t prefix_size = scheduler.peek(prefix.data(), prefix.size());
    report.check(prefix_size == prefix.size() &&
                     scheduler.complete_send(TxResult::Accepted, prefix_size),
                 "could not create a partially active standard frame");
    BulkDataTxLease sender{scheduler, kTransferTag, 0U};
    report.check(sender.begin() ==
                         BulkDataTxLeaseStatus::BlockedByActiveFrame &&
                     sender.latched() && scheduler.size() == 1U &&
                     scheduler.queued_bytes() == parameter.size - prefix.size(),
                 "partial source frame entered the bulk envelope");
  }
}

void test_bulk_selector_skips_urgent_and_preserves_priority(
    TestReport& report) {
  MavlinkFrameScheduler scheduler{};
  const MavlinkFrame urgent = fixtures::command_ack_v2(20U);
  const MavlinkFrame generic =
      fixtures::param_value_v2(21U, "GENERIC", 10.5F, 0U, 932U);
  const MavlinkFrame request =
      fixtures::param_request_read_v2(22U, "TARGET", -1);
  const MavlinkFrame target =
      fixtures::param_value_v2(23U, "TARGET", 11.5F, 7U, 932U);
  const MavlinkFrame heartbeat = fixtures::heartbeat_v2(24U);
  report.check(scheduler.enqueue(urgent) == MavlinkEnqueueStatus::Queued &&
                   scheduler.enqueue(generic) == MavlinkEnqueueStatus::Queued &&
                   scheduler.remember_parameter_request(request) ==
                       MavlinkParameterRequestStatus::Remembered &&
                   scheduler.enqueue(target) == MavlinkEnqueueStatus::Queued &&
                   scheduler.enqueue(heartbeat) == MavlinkEnqueueStatus::Queued,
               "coexistence fixtures were not queued in all scheduler lanes");

  BulkDataTxLease sender{scheduler, kTransferTag, 200U};
  EncodedBulkDataFrame expected_heartbeat{};
  EncodedBulkDataFrame expected_target{};
  EncodedBulkDataFrame expected_generic{};
  report.check(encode_bulk_data_frame(heartbeat, kTransferTag, 200U,
                                      expected_heartbeat) ==
                       BulkDataWireStatus::FrameReady &&
                   encode_bulk_data_frame(target, kTransferTag, 202U,
                                          expected_target) ==
                       BulkDataWireStatus::FrameReady &&
                   encode_bulk_data_frame(generic, kTransferTag, 204U,
                                          expected_generic) ==
                       BulkDataWireStatus::FrameReady,
               "coexistence expected fragments could not be encoded");

  report.check(sender.begin() == BulkDataTxLeaseStatus::Ready &&
                   sender.current_fragment() != nullptr &&
                   *sender.current_fragment() == expected_heartbeat.fragments[0],
               "bulk selector did not prefer retained real heartbeat");
  report.check(sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FragmentAccepted &&
                   sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FrameCommitted,
               "coexistence heartbeat did not commit");

  report.check(sender.begin() == BulkDataTxLeaseStatus::Ready &&
                   sender.current_fragment() != nullptr &&
                   *sender.current_fragment() == expected_target.fragments[0],
               "bulk selector did not prefer target PARAM_VALUE next");
  report.check(sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FragmentAccepted &&
                   sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FrameCommitted,
               "coexistence target PARAM_VALUE did not commit");

  report.check(sender.begin() == BulkDataTxLeaseStatus::Ready &&
                   sender.current_fragment() != nullptr &&
                   *sender.current_fragment() == expected_generic.fragments[0],
               "bulk selector did not select generic PARAM_VALUE last");
  report.check(sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FragmentAccepted &&
                   sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FrameCommitted,
               "coexistence generic PARAM_VALUE did not commit");

  report.check(sender.begin() == BulkDataTxLeaseStatus::NoEligibleFrame &&
                   !sender.latched() && scheduler.size() == 1U &&
                   scheduler.queued_bytes() == urgent.size &&
                   !scheduler.has_active_frame(),
               "unsupported urgent frame blocked or entered bulk selection");
  std::array<std::uint8_t, kMavlinkMaxFrameBytes> output{};
  const std::size_t size = scheduler.peek(output.data(), output.size());
  report.check(same_frame(urgent, output.data(), size),
               "bulk selection consumed or reordered the standard urgent frame");
}

void test_unsupported_only_is_not_activated(TestReport& report) {
  MavlinkFrameScheduler scheduler{};
  const MavlinkFrame urgent = fixtures::command_ack_v2(25U);
  report.check(scheduler.enqueue(urgent) == MavlinkEnqueueStatus::Queued,
               "unsupported-only urgent fixture was not queued");
  BulkDataTxLease sender{scheduler, kTransferTag, 300U};
  report.check(sender.begin() == BulkDataTxLeaseStatus::NoEligibleFrame &&
                   !sender.active() && !sender.latched() &&
                   scheduler.size() == 1U &&
                   scheduler.queued_bytes() == urgent.size &&
                   !scheduler.has_active_frame(),
               "unsupported-only queue was activated or latched by bulk begin");

  std::array<std::uint8_t, kMavlinkMaxFrameBytes> output{};
  const std::size_t size = scheduler.peek(output.data(), output.size());
  report.check(same_frame(urgent, output.data(), size),
               "unsupported-only frame was unavailable to standard mode");
}

void test_active_partial_is_distinct_and_fail_closed(TestReport& report) {
  MavlinkFrameScheduler scheduler{};
  const MavlinkFrame parameter =
      fixtures::param_value_v2(26U, "ACTIVE_PARTIAL", 12.5F, 0U, 932U);
  report.check(scheduler.enqueue(parameter) == MavlinkEnqueueStatus::Queued,
               "active-partial PARAM fixture was not queued");
  std::array<std::uint8_t, 10U> prefix{};
  const std::size_t prefix_size = scheduler.peek(prefix.data(), prefix.size());
  report.check(prefix_size == prefix.size() &&
                   scheduler.complete_send(TxResult::Accepted, prefix_size),
               "could not establish active partial scheduler progress");

  BulkDataTxLease sender{scheduler, kTransferTag, 400U};
  report.check(sender.begin() ==
                       BulkDataTxLeaseStatus::BlockedByActiveFrame &&
                   sender.latched() &&
                   sender.last_error() ==
                       BulkDataTxLeaseStatus::BlockedByActiveFrame &&
                   scheduler.size() == 1U &&
                   scheduler.queued_bytes() == parameter.size - prefix.size(),
               "active partial frame was not distinctly rejected fail-closed");

  std::array<std::uint8_t, kMavlinkMaxFrameBytes> remainder{};
  const std::size_t remainder_size =
      scheduler.peek(remainder.data(), remainder.size());
  report.check(remainder_size == parameter.size - prefix.size() &&
                   std::equal(parameter.bytes.begin() + prefix.size(),
                              parameter.bytes.begin() + parameter.size,
                              remainder.begin()),
               "active partial frame changed after bulk rejection");
}

void test_ordinal_overflow_and_scheduler_failure(TestReport& report) {
  {
    MavlinkFrameScheduler scheduler{};
    const MavlinkFrame parameter =
        fixtures::param_value_v2(16U, "ORDINAL_LIMIT", 6.5F, 0U, 932U);
    report.check(scheduler.enqueue(parameter) == MavlinkEnqueueStatus::Queued,
                 "ordinal-overflow PARAM fixture was not queued");
    BulkDataTxLease sender{scheduler, kTransferTag, 65535U};
    report.check(sender.begin() == BulkDataTxLeaseStatus::OrdinalOverflow &&
                     sender.latched() && scheduler.size() == 1U &&
                     scheduler.queued_bytes() == parameter.size &&
                     !scheduler.has_active_frame(),
                 "ordinal overflow did not fail before source selection");
  }

  {
    MavlinkFrameScheduler scheduler{};
    const MavlinkFrame first =
        fixtures::param_value_v2(17U, "ORDINAL_LAST", 7.5F, 0U, 932U);
    const MavlinkFrame second =
        fixtures::param_value_v2(18U, "ORDINAL_NEXT", 8.5F, 1U, 932U);
    report.check(scheduler.enqueue(first) == MavlinkEnqueueStatus::Queued,
                 "last-valid ordinal fixture was not queued");
    BulkDataTxLease sender{scheduler, kTransferTag, 65534U};
    report.check(sender.begin() == BulkDataTxLeaseStatus::Ready &&
                     sender.complete_fragment(TxResult::Accepted) ==
                         BulkDataTxLeaseStatus::FragmentAccepted &&
                     sender.complete_fragment(TxResult::Accepted) ==
                         BulkDataTxLeaseStatus::FrameCommitted &&
                     sender.next_wire_ordinal() == 65536U,
                 "last legal ordinal pair did not complete exactly once");
    report.check(scheduler.enqueue(second) == MavlinkEnqueueStatus::Queued &&
                     sender.begin() == BulkDataTxLeaseStatus::OrdinalOverflow &&
                     scheduler.size() == 1U &&
                     scheduler.queued_bytes() == second.size,
                 "post-65535 source frame was not preserved fail-closed");
  }

  {
    MavlinkFrameScheduler scheduler{};
    const MavlinkFrame parameter =
        fixtures::param_value_v2(19U, "SCHED_FAIL", 9.5F, 0U, 932U);
    report.check(scheduler.enqueue(parameter) == MavlinkEnqueueStatus::Queued,
                 "scheduler-failure PARAM fixture was not queued");
    BulkDataTxLease sender{scheduler, kTransferTag, 100U};
    report.check(sender.begin() == BulkDataTxLeaseStatus::Ready,
                 "scheduler-failure sender did not begin");
    report.check(scheduler.complete_send(TxResult::Rejected, parameter.size),
                 "could not invalidate the sender's scheduler peek contract");
    report.check(sender.complete_fragment(TxResult::Accepted) ==
                         BulkDataTxLeaseStatus::FragmentAccepted &&
                     sender.complete_fragment(TxResult::Accepted) ==
                         BulkDataTxLeaseStatus::SchedulerFailure &&
                     sender.latched() && scheduler.size() == 1U &&
                     scheduler.queued_bytes() == parameter.size,
                 "scheduler commit failure did not latch without source loss");
  }
}

void test_explicit_session_seal_and_rearm(TestReport& report) {
  constexpr std::uint32_t kNextTransferTag = 0x10293847U;

  {
    MavlinkFrameScheduler boot_scheduler{};
    BulkDataTxLease boot_owner{boot_scheduler, 0U};
    report.check(boot_owner.seal_session() ==
                         BulkDataTxLeaseStatus::Sealed &&
                     boot_owner.rearm(kTransferTag) ==
                         BulkDataTxLeaseStatus::Rearmed &&
                     boot_owner.transfer_tag() == kTransferTag &&
                     boot_owner.next_wire_ordinal() == 0U &&
                     !boot_owner.active() && !boot_owner.latched(),
                 "pre-negotiation global owner could not arm its first tag");
  }

  MavlinkFrameScheduler scheduler{};
  const MavlinkFrame first =
      fixtures::param_value_v2(27U, "SESSION_ONE", 13.5F, 0U, 932U);
  report.check(scheduler.enqueue(first) == MavlinkEnqueueStatus::Queued,
               "first-session PARAM fixture was not queued");

  BulkDataTxLease sender{scheduler, kTransferTag, 500U};
  report.check(sender.begin() == BulkDataTxLeaseStatus::Ready &&
                   sender.seal_session() == BulkDataTxLeaseStatus::Busy &&
                   sender.active() && !sender.latched(),
               "active lease was sealed before its source disposition");
  report.check(sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FragmentAccepted &&
                   sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FrameCommitted,
               "first session frame did not commit");
  report.check(sender.rearm(kNextTransferTag) ==
                       BulkDataTxLeaseStatus::SessionNotSealed &&
                   sender.transfer_tag() == kTransferTag &&
                   sender.next_wire_ordinal() == 502U,
               "unsealed live session changed tag or reset its ordinal");
  report.check(sender.seal_session() == BulkDataTxLeaseStatus::Sealed &&
                   sender.latched() &&
                   sender.last_error() == BulkDataTxLeaseStatus::Sealed &&
                   sender.begin() == BulkDataTxLeaseStatus::Latched,
               "inactive session did not seal terminally");
  report.check(sender.rearm(kTransferTag) ==
                       BulkDataTxLeaseStatus::TransferTagReuse &&
                   sender.rearm(0U) ==
                       BulkDataTxLeaseStatus::InvalidConfiguration &&
                   sender.latched(),
               "rearm accepted a zero or same-session transfer tag");
  report.check(sender.rearm(kNextTransferTag) ==
                       BulkDataTxLeaseStatus::Rearmed &&
                   !sender.latched() && !sender.active() &&
                   sender.transfer_tag() == kNextTransferTag &&
                   sender.next_wire_ordinal() == 0U,
               "new negotiated tag did not rearm at ordinal zero");

  const MavlinkFrame second = fixtures::heartbeat_v2(28U);
  EncodedBulkDataFrame expected{};
  report.check(scheduler.enqueue(second) == MavlinkEnqueueStatus::Queued &&
                   encode_bulk_data_frame(second, kNextTransferTag, 0U,
                                          expected) ==
                       BulkDataWireStatus::FrameReady &&
                   sender.begin() == BulkDataTxLeaseStatus::Ready &&
                   sender.current_fragment() != nullptr &&
                   *sender.current_fragment() == expected.fragments[0],
               "second download session did not use its new tag/ordinal");
}

void test_abort_requires_standard_release_before_rearm(TestReport& report) {
  constexpr std::uint32_t kNextTransferTag = 0x55667788U;
  MavlinkFrameScheduler scheduler{};
  const MavlinkFrame parameter =
      fixtures::param_value_v2(29U, "ABORT_REARM", 14.5F, 0U, 932U);
  report.check(scheduler.enqueue(parameter) == MavlinkEnqueueStatus::Queued,
               "abort/rearm PARAM fixture was not queued");

  BulkDataTxLease sender{scheduler, kTransferTag, 0U};
  report.check(sender.begin() == BulkDataTxLeaseStatus::Ready &&
                   sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FragmentAccepted &&
                   sender.abort() == BulkDataTxLeaseStatus::Aborted,
               "abort/rearm fixture did not enter aborted state");
  report.check(sender.rearm(kNextTransferTag) ==
                       BulkDataTxLeaseStatus::BlockedByActiveFrame &&
                   sender.latched() &&
                   sender.last_error() == BulkDataTxLeaseStatus::Aborted,
               "rearm bypassed the scheduler's retained active source");

  std::array<std::uint8_t, kMavlinkMaxFrameBytes> output{};
  const std::size_t size = scheduler.peek(output.data(), output.size());
  report.check(same_frame(parameter, output.data(), size) &&
                   scheduler.complete_send(TxResult::Accepted, size) &&
                   !scheduler.has_active_frame(),
               "standard mode did not release the aborted source frame");
  report.check(sender.rearm(kNextTransferTag) ==
                       BulkDataTxLeaseStatus::Rearmed &&
                   sender.transfer_tag() == kNextTransferTag &&
                   sender.next_wire_ordinal() == 0U && !sender.latched(),
               "aborted sender did not rearm after standard source release");
}

void test_completion_evidence_commits_only_on_accepted_tail(
    TestReport& report) {
  MavlinkFrameScheduler scheduler{};
  const MavlinkFrame parameter =
      fixtures::param_value_v2(30U, "EVIDENCE_PARAM", 15.5F, 0U, 932U);
  const MavlinkFrame heartbeat = fixtures::heartbeat_v2(31U);
  report.check(scheduler.enqueue(parameter) == MavlinkEnqueueStatus::Queued,
               "completion-evidence PARAM_VALUE fixture was not queued");

  BulkDataTxLease sender{scheduler, kTransferTag, 0U};
  BulkDataTxLeaseEvidence evidence = sender.completion_evidence();
  report.check(evidence.transfer_tag == kTransferTag &&
                   evidence.parameter_count == 0U &&
                   evidence.parameter_fragment_count == 0U &&
                   evidence.raw_parameter_bytes == 0U &&
                   evidence.heartbeat_count == 0U && !evidence.owner_sealed,
               "new sender exposed nonzero or sealed completion evidence");

  report.check(sender.begin() == BulkDataTxLeaseStatus::Ready &&
                   sender.complete_fragment(TxResult::Rejected) ==
                       BulkDataTxLeaseStatus::FragmentRejected,
               "evidence fixture did not retain a rejected PARAM head");
  evidence = sender.completion_evidence();
  report.check(evidence.parameter_count == 0U &&
                   evidence.parameter_fragment_count == 0U &&
                   evidence.raw_parameter_bytes == 0U,
               "rejected PARAM head changed completion evidence");

  report.check(sender.complete_fragment(TxResult::Accepted) ==
                   BulkDataTxLeaseStatus::FragmentAccepted,
               "evidence fixture did not accept PARAM head");
  evidence = sender.completion_evidence();
  report.check(evidence.parameter_count == 0U &&
                   evidence.parameter_fragment_count == 0U &&
                   evidence.raw_parameter_bytes == 0U,
               "accepted PARAM head was counted before source commit");

  report.check(sender.complete_fragment(TxResult::Rejected) ==
                       BulkDataTxLeaseStatus::FragmentRejected &&
                   sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FrameCommitted,
               "evidence fixture did not retry and commit PARAM tail");
  evidence = sender.completion_evidence();
  report.check(evidence.parameter_count == 1U &&
                   evidence.parameter_fragment_count == 2U &&
                   evidence.raw_parameter_bytes == 37U &&
                   evidence.heartbeat_count == 0U && !evidence.owner_sealed,
               "accepted PARAM tail did not commit exact evidence once");
  report.check(sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::NoLease &&
                   sender.completion_evidence().parameter_count == 1U,
               "released PARAM lease double-counted completion evidence");

  report.check(scheduler.enqueue(heartbeat) == MavlinkEnqueueStatus::Queued &&
                   sender.begin() == BulkDataTxLeaseStatus::Ready &&
                   sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FragmentAccepted,
               "completion-evidence HEARTBEAT fixture did not reach tail");
  evidence = sender.completion_evidence();
  report.check(evidence.heartbeat_count == 0U,
               "accepted HEARTBEAT head was counted before source commit");
  report.check(sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FrameCommitted &&
                   sender.completion_evidence().heartbeat_count == 1U,
               "accepted HEARTBEAT tail did not commit exact evidence once");

  report.check(sender.seal_session() == BulkDataTxLeaseStatus::Sealed,
               "complete evidence owner did not seal explicitly");
  evidence = sender.completion_evidence();
  report.check(evidence.transfer_tag == kTransferTag &&
                   evidence.parameter_count == 1U &&
                   evidence.parameter_fragment_count == 2U &&
                   evidence.raw_parameter_bytes == 37U &&
                   evidence.heartbeat_count == 1U && evidence.owner_sealed,
               "sealed evidence snapshot changed committed totals");
}

void test_completion_evidence_abort_and_rearm_reset(TestReport& report) {
  constexpr std::uint32_t kNextTransferTag = 0x31415926U;
  MavlinkFrameScheduler scheduler{};
  const MavlinkFrame committed =
      fixtures::param_value_v2(32U, "EVIDENCE_OLD", 16.5F, 0U, 932U);
  const MavlinkFrame aborted = fixtures::heartbeat_v2(33U);
  report.check(scheduler.enqueue(committed) == MavlinkEnqueueStatus::Queued,
               "abort-reset committed fixture was not queued");

  BulkDataTxLease sender{scheduler, kTransferTag, 0U};
  report.check(sender.begin() == BulkDataTxLeaseStatus::Ready &&
                   sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FragmentAccepted &&
                   sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FrameCommitted &&
                   sender.completion_evidence().parameter_count == 1U,
               "abort-reset fixture did not establish prior evidence");

  report.check(scheduler.enqueue(aborted) == MavlinkEnqueueStatus::Queued &&
                   sender.begin() == BulkDataTxLeaseStatus::Ready &&
                   sender.complete_fragment(TxResult::Accepted) ==
                       BulkDataTxLeaseStatus::FragmentAccepted &&
                   sender.abort() == BulkDataTxLeaseStatus::Aborted,
               "abort-reset fixture did not abort an active heartbeat");
  BulkDataTxLeaseEvidence evidence = sender.completion_evidence();
  report.check(evidence.transfer_tag == kTransferTag &&
                   evidence.parameter_count == 0U &&
                   evidence.parameter_fragment_count == 0U &&
                   evidence.raw_parameter_bytes == 0U &&
                   evidence.heartbeat_count == 0U && !evidence.owner_sealed,
               "abort retained stale completion evidence");

  std::array<std::uint8_t, kMavlinkMaxFrameBytes> output{};
  const std::size_t size = scheduler.peek(output.data(), output.size());
  report.check(same_frame(aborted, output.data(), size) &&
                   scheduler.complete_send(TxResult::Accepted, size),
               "standard fallback did not release aborted evidence source");
  report.check(sender.rearm(kNextTransferTag) ==
                       BulkDataTxLeaseStatus::Rearmed,
               "aborted evidence owner did not rearm with a fresh tag");
  evidence = sender.completion_evidence();
  report.check(evidence.transfer_tag == kNextTransferTag &&
                   evidence.parameter_count == 0U &&
                   evidence.parameter_fragment_count == 0U &&
                   evidence.raw_parameter_bytes == 0U &&
                   evidence.heartbeat_count == 0U && !evidence.owner_sealed,
               "rearm did not expose a clean unsealed evidence epoch");

  report.check(sender.seal_session() == BulkDataTxLeaseStatus::Sealed &&
                   sender.completion_evidence().owner_sealed,
               "empty rearmed evidence epoch did not seal explicitly");
}

}  // namespace

TestReport run_bulk_tx_lease_test(const std::string& test_id,
                                  std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-BULK-TX-LEASE-001") {
    test_begin_and_physical_rejection(report);
  } else if (test_id == "UT-BULK-TX-LEASE-002") {
    test_tail_is_the_only_source_commit(report);
  } else if (test_id == "UT-BULK-TX-LEASE-003") {
    test_frame_types_cannot_interleave(report);
  } else if (test_id == "UT-BULK-TX-LEASE-004") {
    test_abort_returns_frame_to_standard_mode(report);
  } else if (test_id == "UT-BULK-TX-LEASE-005") {
    test_invalid_and_unsupported_fail_closed(report);
  } else if (test_id == "UT-BULK-TX-LEASE-006") {
    test_ordinal_overflow_and_scheduler_failure(report);
  } else if (test_id == "UT-BULK-TX-LEASE-007") {
    test_bulk_selector_skips_urgent_and_preserves_priority(report);
  } else if (test_id == "UT-BULK-TX-LEASE-008") {
    test_unsupported_only_is_not_activated(report);
  } else if (test_id == "UT-BULK-TX-LEASE-009") {
    test_active_partial_is_distinct_and_fail_closed(report);
  } else if (test_id == "UT-BULK-TX-LEASE-010") {
    test_explicit_session_seal_and_rearm(report);
  } else if (test_id == "UT-BULK-TX-LEASE-011") {
    test_abort_requires_standard_release_before_rearm(report);
  } else if (test_id == "UT-BULK-TX-LEASE-012") {
    test_completion_evidence_commits_only_on_accepted_tail(report);
  } else if (test_id == "UT-BULK-TX-LEASE-013") {
    test_completion_evidence_abort_and_rearm_reset(report);
  } else {
    report.check(false, "unknown bulk TX lease test ID");
  }

  report.trace.record({0U, "host", "BULK_TX_LEASE", 0U,
                       report.passed ? "PASS" : "FAIL", true,
                       report.diagnostics.downlink_payload_bytes, 0U, 0U});
  return report;
}

}  // namespace vc_lora::test
