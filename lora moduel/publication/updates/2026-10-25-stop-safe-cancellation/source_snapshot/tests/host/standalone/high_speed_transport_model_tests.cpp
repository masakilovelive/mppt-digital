#include "../../../firmware/high_speed/e220_high_speed_transport_model.hpp"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <memory>
#include <optional>
#include <type_traits>
#include <utility>

namespace {

std::uint32_t measured_nominal_pipelined_ms = 0U;
std::uint32_t measured_nonoverlap_ms = 0U;

using vc_lora::experimental::AdmissionResult;
using vc_lora::experimental::BulkAction;
using vc_lora::experimental::BulkDisposition;
using vc_lora::experimental::BulkEndReason;
using vc_lora::experimental::Direction;
using vc_lora::experimental::DrainProof;
using vc_lora::experimental::E220DirectionDrainFence;
using vc_lora::experimental::E220UartAdmissionGate;
using vc_lora::experimental::EvidenceSource;
using vc_lora::experimental::FinalParameterTailWatermark;
using vc_lora::experimental::HeartbeatDeliveryProof;
using vc_lora::experimental::HeartbeatTailWatermark;
using vc_lora::experimental::HeartbeatWriteCommitOutcome;
using vc_lora::experimental::HighSpeedCandidateContract;
using vc_lora::experimental::NativeBulkDownlink;
using vc_lora::experimental::NativeBulkInput;
using vc_lora::experimental::ParameterChunkWatermark;
using vc_lora::experimental::ParameterFramePermit;
using vc_lora::experimental::ParameterFrameTailWatermark;
using vc_lora::experimental::ParameterStreamDeliveryProof;
using vc_lora::experimental::ProgressProof;
using vc_lora::experimental::ReceiverEvidencePollEpoch;
using vc_lora::experimental::RemoteDeliveryLedger;
using vc_lora::experimental::RemoteHeartbeatSlaLedger;
using vc_lora::experimental::RemoteHeartbeatSlaProof;
using vc_lora::experimental::TransferToken;
using vc_lora::experimental::WriteCommitResult;
using vc_lora::experimental::WriteCommitOutcome;

static_assert(!std::is_aggregate_v<DrainProof>);
static_assert(!std::is_constructible_v<DrainProof, TransferToken,
                                       EvidenceSource, bool>);
static_assert(!std::is_aggregate_v<ProgressProof>);
static_assert(!std::is_constructible_v<ProgressProof, TransferToken,
                                       EvidenceSource, bool>);
static_assert(!std::is_default_constructible_v<E220UartAdmissionGate>);
static_assert(!std::is_aggregate_v<TransferToken>);
static_assert(!std::is_aggregate_v<ParameterFramePermit>);
static_assert(!std::is_aggregate_v<ParameterFrameTailWatermark>);
static_assert(!std::is_aggregate_v<ParameterChunkWatermark>);
static_assert(!std::is_aggregate_v<HeartbeatDeliveryProof>);
static_assert(!std::is_aggregate_v<ParameterStreamDeliveryProof>);

template <typename Proof, typename = void>
struct CanSealReceiverProof : std::false_type {};

template <typename Proof>
struct CanSealReceiverProof<
    Proof,
    std::void_t<decltype(std::declval<NativeBulkDownlink&>()
                             .seal_receiver_events_drained(
                                 std::declval<std::uint32_t>(),
                                 std::declval<const Proof&>()))>>
    : std::true_type {};

static_assert(!CanSealReceiverProof<HeartbeatDeliveryProof>::value);
static_assert(!CanSealReceiverProof<ParameterStreamDeliveryProof>::value);
static_assert(!CanSealReceiverProof<DrainProof>::value);
static_assert(!std::is_copy_constructible_v<RemoteDeliveryLedger>);
static_assert(!std::is_move_constructible_v<RemoteDeliveryLedger>);

template <typename Proof, typename = void>
struct CanSealReceiverProofWithLedger : std::false_type {};

template <typename Proof>
struct CanSealReceiverProofWithLedger<
    Proof,
    std::void_t<decltype(std::declval<NativeBulkDownlink&>()
                             .seal_receiver_events_drained(
                                 std::declval<std::uint32_t>(),
                                 std::declval<const Proof&>(),
                                 std::declval<RemoteDeliveryLedger&>()))>>
    : std::true_type {};

static_assert(
    !CanSealReceiverProofWithLedger<ParameterStreamDeliveryProof>::value);
static_assert(!CanSealReceiverProofWithLedger<HeartbeatDeliveryProof>::value);
static_assert(!CanSealReceiverProofWithLedger<DrainProof>::value);
static_assert(!std::is_constructible_v<TransferToken, std::uint64_t,
                                       std::uint32_t, Direction,
                                       std::uint64_t, bool, bool>);
static_assert(!std::is_default_constructible_v<NativeBulkDownlink>);
static_assert(!std::is_aggregate_v<ReceiverEvidencePollEpoch>);
static_assert(vc_lora::experimental::HighSpeedCandidateContract::
                  param_value_wire_chunks_per_frame == 2U);
static_assert(vc_lora::experimental::HighSpeedCandidateContract::
                  param_value_wire_bytes_per_frame == 64U);
static_assert(vc_lora::experimental::HighSpeedCandidateContract::
                  bulk_fragment_payload_bytes == 19U);
static_assert(vc_lora::experimental::HighSpeedCandidateContract::
                  heartbeat_wire_chunks_per_frame == 2U);
static_assert(vc_lora::experimental::HighSpeedCandidateContract::
                  heartbeat_wire_bytes_per_frame == 64U);

using PollSignature = BulkAction (NativeBulkDownlink::*)(
    std::uint32_t, const ReceiverEvidencePollEpoch&,
    const NativeBulkInput&) noexcept;
static_assert(std::is_same_v<decltype(&NativeBulkDownlink::poll),
                             PollSignature>);

int failures = 0;

void check(bool condition, const char* expression, int line) {
  if (!condition) {
    std::cerr << "FAIL line " << line << ": " << expression << '\n';
    ++failures;
  }
}

#define CHECK(expression) check((expression), #expression, __LINE__)

NativeBulkInput input(bool fifo_has_complete_frame,
                      bool upstream_stream_complete,
                      bool parser_partial, std::size_t queued_backlog,
                      std::uint32_t worst_case_service_ms = 100U) {
  return NativeBulkInput{fifo_has_complete_frame, upstream_stream_complete,
                         parser_partial, queued_backlog,
                         worst_case_service_ms};
}

BulkAction poll_bulk(NativeBulkDownlink& bulk, std::uint32_t now,
                     const NativeBulkInput& transport) {
  const auto epoch = bulk.seal_receiver_events_drained(now);
  return bulk.poll(now, epoch, transport);
}

void make_aux_ready(E220UartAdmissionGate& gate, std::uint32_t start) {
  gate.observe_aux(start, true);
}

TransferToken issue_short_token(std::uint64_t session_id,
                                std::uint32_t generation,
                                Direction direction,
                                std::uint64_t tail) {
  E220UartAdmissionGate gate(session_id, 0U, generation - 1U);
  make_aux_ready(gate, 0U);
  std::uint32_t now = 15U;
  TransferToken token{};
  std::uint64_t remaining = tail + 1U;
  while (remaining != 0U) {
    const std::size_t bytes = static_cast<std::size_t>(
        remaining > 32U ? 32U : remaining);
    CHECK(gate.assess(now, direction, bytes) == AdmissionResult::Ready);
    const auto committed = gate.commit_write(now, direction, bytes, bytes);
    CHECK(committed.result == WriteCommitResult::Committed);
    token = committed.token;
    remaining -= static_cast<std::uint64_t>(bytes);
    now += 3U;
  }
  return token;
}

struct FullParameterStreamOutcome {
  TransferToken final_token{};
  ParameterChunkWatermark final_chunk_watermark{};
  FinalParameterTailWatermark final_watermark{};
  ParameterStreamDeliveryProof delivery_proof{};
  RemoteHeartbeatSlaProof heartbeat_sla_proof{};
  HeartbeatDeliveryProof trailing_heartbeat_proof{};
  std::unique_ptr<RemoteDeliveryLedger> receiver{};
  std::unique_ptr<RemoteHeartbeatSlaLedger> heartbeat_receiver{};
  std::uint32_t completion_ms = 0U;
  std::uint32_t ground_last_parameter_ms = 0U;
  std::uint32_t ground_transfer_elapsed_ms = 0U;
  std::uint32_t heartbeat_count = 0U;
  HeartbeatTailWatermark last_heartbeat_watermark{};
  bool receiver_fault = false;
  bool cached_parameter_permit_reaccepted = false;
  bool aux_tail_airtime_overlap_assumed = true;
  std::uint32_t local_aux_credit_releases = 0U;
};

FullParameterStreamOutcome issue_full_parameter_stream(
    NativeBulkDownlink& bulk, std::uint64_t session_id,
    std::optional<std::uint32_t> ground_clock_offset_ms = std::nullopt,
    bool replay_final_before_seal = false,
    bool trailing_heartbeat_before_seal = false,
    bool replay_final_after_seal = false,
    bool probe_cached_permit_after_complete = false,
    std::uint32_t final_parameter_remote_delay_ms = 0U,
    std::uint32_t ground_request_lead_ms = 0U,
    bool assume_aux_tail_airtime_overlap = true,
    std::uint32_t final_local_handoff_pause_ms = 0U,
    std::uint32_t ground_timeline_scale_per_mille = 1000U) {
  E220UartAdmissionGate gate(session_id);
  E220DirectionDrainFence fence;
  FullParameterStreamOutcome result{};
  const std::uint32_t ground_offset = ground_clock_offset_ms.value_or(0U);
  const std::uint32_t ground_request_ms =
      ground_offset - ground_request_lead_ms;
  const auto ground_observed_at = [&](std::uint32_t local_ms) {
    return ground_offset + static_cast<std::uint32_t>(
                               static_cast<std::uint64_t>(local_ms) *
                               ground_timeline_scale_per_mille / 1000U);
  };
  result.receiver = std::make_unique<RemoteDeliveryLedger>(
      bulk.session_id(), bulk.stream_id(), bulk.lease_id(), ground_request_ms);
  result.heartbeat_receiver = std::make_unique<RemoteHeartbeatSlaLedger>(
      bulk.session_id(), bulk.stream_id(), bulk.lease_id(), ground_request_ms,
      ground_request_ms, 0U);
  RemoteDeliveryLedger& receiver = *result.receiver;
  RemoteHeartbeatSlaLedger& heartbeat_receiver =
      *result.heartbeat_receiver;
  make_aux_ready(gate, 0U);
  std::uint32_t now = 15U;
  std::uint64_t parameter_chunks = 0U;
  std::uint64_t all_wire_chunks = 0U;
  std::uint32_t next_heartbeat_due_ms = now + 1000U;
  ParameterFramePermit cached_first_permit{};
  result.aux_tail_airtime_overlap_assumed =
      assume_aux_tail_airtime_overlap;

  const auto release_local_credit_if_needed =
      [&](const TransferToken& token, std::uint32_t accepted_at_ms) {
        ++all_wire_chunks;
        if ((all_wire_chunks % 12U) != 0U) {
          return;
        }
        ++result.local_aux_credit_releases;
        if (assume_aux_tail_airtime_overlap) {
          // NOMINAL TIMING HYPOTHESIS ONLY: AUX rises 1 ms after admission,
          // then at most 13 ms of its required 15-ms stable-HIGH interval
          // overlaps the preceding tail's modeled airtime.  Therefore 2 ms
          // remains outside that tail service.  This AUX behavior is not yet
          // measured or guaranteed on the physical E220; live remains false.
          gate.observe_aux(accepted_at_ms, false);
          gate.observe_aux(accepted_at_ms + 1U, true);
          CHECK(!gate.release_buffer_credit_from_local_aux(
              accepted_at_ms + 15U, token));
          CHECK(gate.release_buffer_credit_from_local_aux(
              accepted_at_ms + 16U, token));
          CHECK(now == accepted_at_ms + 14U);
          now = accepted_at_ms + 16U;
        } else {
          // Conservative non-overlap case: the AUX LOW -> HIGH -> stable
          // observation starts only after the preceding 14-ms tail service.
          const std::uint32_t aux_low_at_ms = now;
          gate.observe_aux(aux_low_at_ms, false);
          gate.observe_aux(aux_low_at_ms + 1U, true);
          CHECK(!gate.release_buffer_credit_from_local_aux(
              aux_low_at_ms + 15U, token));
          CHECK(gate.release_buffer_credit_from_local_aux(
              aux_low_at_ms + 16U, token));
          now = aux_low_at_ms + 16U;
        }
      };

  const auto send_heartbeat_if_due = [&]() {
    if (now < next_heartbeat_due_ms) {
      return;
    }
    CHECK(bulk.queue_heartbeat(now));
    const auto heartbeat_permit = bulk.heartbeat_tail_permit();
    CHECK(heartbeat_permit.has_value());
    HeartbeatWriteCommitOutcome heartbeat{};
    std::uint32_t heartbeat_tail_accepted_at_ms = 0U;
    for (std::size_t ordinal = 0U;
         ordinal < HighSpeedCandidateContract::
                       heartbeat_wire_chunks_per_frame;
         ++ordinal) {
      CHECK(gate.assess(now, Direction::Downlink, 32U) ==
            AdmissionResult::Ready);
      heartbeat = gate.commit_heartbeat_chunk(
          now, Direction::Downlink, 32U, 32U, ordinal,
          *heartbeat_permit);
      CHECK(heartbeat.write.result == WriteCommitResult::Committed);
      CHECK(heartbeat.watermark.valid() ==
            (ordinal + 1U == HighSpeedCandidateContract::
                                heartbeat_wire_chunks_per_frame));
      CHECK(fence.record_accepted(heartbeat.write.token));
      const std::uint32_t accepted_at_ms = now;
      heartbeat_tail_accepted_at_ms = accepted_at_ms;
      now += 14U;
      release_local_credit_if_needed(heartbeat.write.token,
                                     accepted_at_ms);
    }
    CHECK(heartbeat.watermark.valid());
    CHECK(bulk.bind_heartbeat_tail(heartbeat.watermark));
    CHECK(bulk.confirm_heartbeat_local_buffer_handoff(
        heartbeat.watermark, heartbeat_tail_accepted_at_ms));
    const auto legacy_delivery = receiver.observe_heartbeat(
        heartbeat.watermark, ground_observed_at(heartbeat_tail_accepted_at_ms));
    CHECK(legacy_delivery.has_value());
    const bool heartbeat_sla_observed =
        heartbeat_receiver.observe_heartbeat(
            heartbeat.watermark,
            ground_observed_at(heartbeat_tail_accepted_at_ms),
            heartbeat.watermark.request_id());
    if (ground_request_lead_ms == 0U) {
      CHECK(heartbeat_sla_observed);
    }
    result.trailing_heartbeat_proof = *legacy_delivery;
    result.last_heartbeat_watermark = heartbeat.watermark;
    ++result.heartbeat_count;
    next_heartbeat_due_ms += 1000U;
  };

  for (std::uint16_t index = 0U; index < 932U; ++index) {
    send_heartbeat_if_due();
    const auto permit = bulk.parameter_frame_permit();
    CHECK(permit.has_value());
    CHECK(permit->parameter_index() == index);
    if (index == 0U) {
      cached_first_permit = *permit;
    }
    for (std::size_t ordinal = 0U; ordinal < 2U; ++ordinal) {
      if (index == 931U && ordinal == 1U) {
        now += final_local_handoff_pause_ms;
      }
      CHECK(gate.assess(now, Direction::Downlink, 32U) ==
            AdmissionResult::Ready);
      const auto outcome = gate.commit_parameter_chunk(
          now, Direction::Downlink, 32U, 32U, ordinal, *permit);
      CHECK(outcome.write.result == WriteCommitResult::Committed);
      CHECK(outcome.chunk_watermark.valid());
      CHECK(outcome.chunk_watermark.parameter_index() == index);
      CHECK(outcome.chunk_watermark.chunk_ordinal() == ordinal);
      CHECK(outcome.chunk_watermark.global_chunk_ordinal() ==
            parameter_chunks);
      CHECK(fence.record_accepted(outcome.write.token));
      ++parameter_chunks;
      if (ordinal == 0U) {
        CHECK(!outcome.frame_watermark.valid());
        CHECK(!outcome.final_watermark.valid());
      } else {
        CHECK(outcome.frame_watermark.valid());
        CHECK(bulk.consume_parameter_frame_tail(
            outcome.frame_watermark, now));
        if (index == 931U) {
          CHECK(outcome.final_watermark.valid());
          result.final_token = outcome.write.token;
          result.final_chunk_watermark = outcome.chunk_watermark;
          result.final_watermark = outcome.final_watermark;
        } else {
          CHECK(!outcome.final_watermark.valid());
        }
      }
      const std::uint32_t observed_at =
          ground_observed_at(now) +
          ((index == 931U && ordinal == 1U)
               ? final_parameter_remote_delay_ms
               : 0U);
      CHECK(receiver.observe_parameter_chunk(outcome.chunk_watermark,
                                              observed_at));
      if (index == 931U && ordinal == 1U) {
        result.ground_last_parameter_ms = observed_at;
      }
      const std::uint32_t accepted_at_ms = now;
      now += 14U;
      release_local_credit_if_needed(outcome.write.token,
                                     accepted_at_ms);
    }
  }
  CHECK(parameter_chunks == 1864U);
  CHECK(gate.accepted_wire_bytes() ==
        59648U + static_cast<std::uint64_t>(result.heartbeat_count) *
                     HighSpeedCandidateContract::
                         heartbeat_wire_bytes_per_frame);
  CHECK(bulk.physically_committed_parameter_count() == 932U);
  CHECK(bulk.physically_committed_parameter_chunks() == 1864U);
  CHECK(bulk.physically_committed_parameter_bytes() == 59648U);
  CHECK(receiver.received_parameter_count() == 932U);
  CHECK(receiver.received_parameter_chunks() == 1864U);
  CHECK(receiver.received_parameter_bytes() == 59648U);
  CHECK(!receiver.accounting_fault());
  (void)trailing_heartbeat_before_seal;
  if (replay_final_before_seal) {
    CHECK(!receiver.observe_parameter_chunk(
        result.final_chunk_watermark, now));
    CHECK(receiver.accounting_fault());
  }
  const auto delivery = receiver.seal_parameter_stream_delivery();
  if (replay_final_before_seal) {
    CHECK(!delivery.has_value());
  } else {
    CHECK(delivery.has_value());
    result.delivery_proof = *delivery;
    CHECK(result.delivery_proof.valid());
    result.ground_transfer_elapsed_ms =
        result.delivery_proof.remote_transfer_elapsed_ms();
    const auto heartbeat_sla =
        heartbeat_receiver.seal_terminal_sla(result.delivery_proof);
    if (heartbeat_sla.has_value()) {
      result.heartbeat_sla_proof = *heartbeat_sla;
      CHECK(result.heartbeat_sla_proof.valid());
    }
  }
  if (replay_final_after_seal) {
    CHECK(!receiver.observe_parameter_chunk(
        result.final_chunk_watermark, now));
    CHECK(receiver.accounting_fault());
  }
  if (probe_cached_permit_after_complete) {
    CHECK(gate.assess(now, Direction::Downlink, 32U) ==
          AdmissionResult::Ready);
    const auto cached = gate.commit_parameter_chunk(
        now, Direction::Downlink, 32U, 32U, 0U, cached_first_permit);
    result.cached_parameter_permit_reaccepted =
        cached.write.result == WriteCommitResult::Committed;
  }
  result.receiver_fault = receiver.accounting_fault();
  result.completion_ms = now;
  return result;
}

ReceiverEvidencePollEpoch seal_terminal_outcome(
    NativeBulkDownlink& bulk, const FullParameterStreamOutcome& outcome,
    std::uint32_t terminal_ack_received_ms) {
  CHECK(outcome.receiver != nullptr);
  CHECK(outcome.heartbeat_receiver != nullptr);
  CHECK(bulk.open_terminal_ack_window(terminal_ack_received_ms - 100U));
  return bulk.seal_terminal_receiver_evidence(
      terminal_ack_received_ms, outcome.delivery_proof, *outcome.receiver,
      outcome.heartbeat_sla_proof, *outcome.heartbeat_receiver);
}

bool commit_terminal_outcome(
    NativeBulkDownlink& bulk, const FullParameterStreamOutcome& outcome) {
  CHECK(outcome.receiver != nullptr);
  CHECK(outcome.heartbeat_receiver != nullptr);
  return bulk.commit_end(*outcome.receiver, *outcome.heartbeat_receiver);
}

HeartbeatWriteCommitOutcome issue_heartbeat_tail(
    NativeBulkDownlink& bulk, std::uint64_t session_id,
    std::uint32_t now) {
  const auto permit = bulk.heartbeat_tail_permit();
  CHECK(permit.has_value());
  E220UartAdmissionGate gate(session_id);
  make_aux_ready(gate, now - 15U);
  CHECK(gate.assess(now, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto head = gate.commit_heartbeat_chunk(
      now, Direction::Downlink, 32U, 32U, 0U, *permit);
  CHECK(head.write.result == WriteCommitResult::Committed);
  CHECK(!head.watermark.valid());
  CHECK(gate.assess(now + 3U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto tail = gate.commit_heartbeat_chunk(
      now + 3U, Direction::Downlink, 32U, 32U, 1U, *permit);
  CHECK(tail.write.result == WriteCommitResult::Committed);
  CHECK(tail.watermark.valid());
  return tail;
}

void observe_all_parameters(NativeBulkDownlink& bulk,
                            std::uint32_t first_ms = 0U) {
  for (std::uint16_t index = 0U; index < 932U; ++index) {
    CHECK(bulk.observe_param_value(first_ms + index, true, index));
  }
}

void test_admission_full_write_aux_gap_and_direction() {
  E220UartAdmissionGate gate(1U);
  make_aux_ready(gate, 100U);
  CHECK(gate.assess(114U, Direction::Downlink, 32U) ==
        AdmissionResult::AuxNotStable);
  CHECK(gate.assess(115U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto first =
      gate.commit_write(115U, Direction::Downlink, 32U, 32U);
  CHECK(first.result == WriteCommitResult::Committed);
  CHECK(first.token.valid() && first.token.tail_known());
  CHECK(first.token.generation() == 1U);
  CHECK(first.token.direction() == Direction::Downlink);
  CHECK(first.token.tail() == 31U);
  CHECK(gate.assess(117U, Direction::Downlink, 32U) ==
        AdmissionResult::GapActive);
  CHECK(gate.assess(118U, Direction::Uplink, 32U) ==
        AdmissionResult::DirectionMismatch);
  CHECK(gate.assess(118U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto second =
      gate.commit_write(118U, Direction::Downlink, 32U, 32U);
  CHECK(second.result == WriteCommitResult::Committed);
  CHECK(second.token.generation() == first.token.generation());
  CHECK(second.token.tail() == 63U);
  CHECK(gate.buffered_bytes() == 64U);
}

void test_generation_tail_credit_rejects_stale_duplicate_and_wrong() {
  E220UartAdmissionGate gate(2U);
  E220DirectionDrainFence fence;
  make_aux_ready(gate, 0U);
  std::uint32_t now = 15U;
  TransferToken first{};
  TransferToken last{};
  for (std::uint32_t index = 0U; index < 12U; ++index) {
    CHECK(gate.assess(now, Direction::Downlink, 32U) ==
          AdmissionResult::Ready);
    const auto committed =
        gate.commit_write(now, Direction::Downlink, 32U, 32U);
    CHECK(committed.result == WriteCommitResult::Committed);
    CHECK(fence.record_accepted(committed.token));
    if (index == 0U) {
      first = committed.token;
    }
    last = committed.token;
    now += 3U;
  }
  CHECK(gate.buffered_bytes() == 384U);
  CHECK(gate.assess(now, Direction::Downlink, 32U) ==
        AdmissionResult::Backpressure);

  const auto first_progress = fence.observe_remote_progress(first);
  CHECK(first_progress.has_value());
  CHECK(!gate.apply_progress(*first_progress));
  CHECK(gate.buffered_bytes() == 384U);
  CHECK(!fence.observe_remote_progress(first).has_value());
  CHECK(!gate.apply_progress(*first_progress));

  E220DirectionDrainFence wrong_direction_fence;
  const auto wrong_direction_token =
      issue_short_token(2U, 1U, Direction::Uplink, 31U);
  CHECK(wrong_direction_fence.record_accepted(wrong_direction_token));
  const auto wrong_direction =
      wrong_direction_fence.observe_remote_progress(wrong_direction_token);
  CHECK(wrong_direction.has_value());
  CHECK(!gate.apply_progress(*wrong_direction));
  E220DirectionDrainFence wrong_generation_fence;
  const auto wrong_generation_token =
      issue_short_token(2U, 9U, Direction::Downlink, 31U);
  CHECK(wrong_generation_fence.record_accepted(wrong_generation_token));
  const auto wrong_generation =
      wrong_generation_fence.observe_remote_progress(wrong_generation_token);
  CHECK(wrong_generation.has_value());
  CHECK(!gate.apply_progress(*wrong_generation));
  CHECK(gate.buffered_bytes() == 384U);

  gate.observe_aux(now, false);
  gate.observe_aux(now + 1U, true);
  CHECK(!gate.release_buffer_credit_from_local_aux(now + 15U, last));
  CHECK(gate.release_buffer_credit_from_local_aux(now + 16U, last));
  CHECK(gate.buffered_bytes() == 0U);

  const auto drain = fence.observe_remote_tail(last, now);
  CHECK(drain.has_value());
  CHECK(drain->source() == EvidenceSource::RemoteArrival);
  CHECK(gate.unlock_direction(*drain));
  CHECK(gate.buffered_bytes() == 0U);
  CHECK(!gate.direction_locked());
  CHECK(!gate.unlock_direction(*drain));
  CHECK(fence.commit_direction_change(*drain, Direction::Uplink));
  CHECK(!fence.commit_direction_change(*drain, Direction::Downlink));

  CHECK(gate.assess(now, Direction::Uplink, 32U) ==
        AdmissionResult::Ready);
  const auto next_generation =
      gate.commit_write(now, Direction::Uplink, 32U, 32U);
  CHECK(next_generation.result == WriteCommitResult::Committed);
  CHECK(next_generation.token.generation() == 2U);
  CHECK(next_generation.token.tail() == 31U);
  CHECK(fence.record_accepted(next_generation.token));
  CHECK(!gate.apply_progress(*first_progress));
}

void test_partial_and_unadmitted_positive_write_enter_quarantine() {
  E220UartAdmissionGate partial(3U);
  E220DirectionDrainFence partial_fence;
  make_aux_ready(partial, 10U);
  CHECK(partial.assess(25U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto partial_result =
      partial.commit_write(25U, Direction::Downlink, 32U, 17U);
  CHECK(partial_result.result == WriteCommitResult::PartialWriteFault);
  CHECK(partial_result.token.valid() && !partial_result.token.tail_known());
  CHECK(partial.quarantined());
  CHECK(partial.direction_locked());
  CHECK(partial.write_fault_latched());
  CHECK(partial_fence.record_unknown_accepted(partial_result.token));
  partial_fence.observe_local_radio_status(true, false, true);
  CHECK(!partial_fence.observe_explicit_quarantine_drain(
              partial_result.token, 26U)
              .has_value());
  CHECK(!partial_fence.direction_drained());
  partial_fence.observe_local_radio_status(true, true, true);
  const auto quarantine_proof =
      partial_fence.observe_explicit_quarantine_drain(partial_result.token,
                                                       27U);
  CHECK(quarantine_proof.has_value());
  CHECK(partial.unlock_direction(*quarantine_proof));
  CHECK(!partial.direction_locked());
  CHECK(partial.write_fault_latched());
  CHECK(partial.assess(30U, Direction::Uplink, 32U) ==
        AdmissionResult::WriteFaultLatched);

  E220UartAdmissionGate unadmitted(4U);
  const auto unadmitted_result =
      unadmitted.commit_write(5U, Direction::Uplink, 32U, 5U);
  CHECK(unadmitted_result.result ==
        WriteCommitResult::UnadmittedWriteFault);
  CHECK(unadmitted_result.token.valid() &&
        !unadmitted_result.token.tail_known());
  CHECK(unadmitted.quarantined());
  CHECK(unadmitted.direction_locked());

  E220UartAdmissionGate mixed(5U);
  E220DirectionDrainFence mixed_fence;
  make_aux_ready(mixed, 0U);
  CHECK(mixed.assess(15U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto known =
      mixed.commit_write(15U, Direction::Downlink, 32U, 32U);
  CHECK(known.result == WriteCommitResult::Committed);
  CHECK(mixed_fence.record_accepted(known.token));
  const auto wrong_direction_write =
      mixed.commit_write(18U, Direction::Uplink, 32U, 4U);
  CHECK(wrong_direction_write.result ==
        WriteCommitResult::UnadmittedWriteFault);
  CHECK(wrong_direction_write.token.direction() == Direction::Mixed);
  CHECK(mixed.quarantined() && mixed.direction_locked());
  CHECK(mixed_fence.record_unknown_accepted(wrong_direction_write.token));
  mixed_fence.observe_local_radio_status(true, false, true);
  CHECK(!mixed_fence.observe_explicit_quarantine_drain(
              wrong_direction_write.token, 19U)
              .has_value());
  mixed_fence.observe_local_radio_status(true, true, true);
  const auto mixed_drain = mixed_fence.observe_explicit_quarantine_drain(
      wrong_direction_write.token, 20U);
  CHECK(mixed_drain.has_value());
  CHECK(mixed.unlock_direction(*mixed_drain));

  E220UartAdmissionGate zero(6U);
  const auto zero_result =
      zero.commit_write(5U, Direction::Uplink, 32U, 0U);
  CHECK(zero_result.result == WriteCommitResult::NoProgress);
  CHECK(!zero_result.token.valid());
  CHECK(!zero.quarantined());
  CHECK(!zero.direction_locked());
  CHECK(!zero.write_fault_latched());
}

void test_admission_overflow_is_fail_latched_before_or_after_write() {
  E220UartAdmissionGate generation_overflow(
      7U, 0U, std::numeric_limits<std::uint32_t>::max());
  make_aux_ready(generation_overflow, 0U);
  CHECK(generation_overflow.assess(15U, Direction::Downlink, 32U) ==
        AdmissionResult::CounterOverflow);
  CHECK(generation_overflow.counter_fault_latched());

  E220UartAdmissionGate byte_overflow(
      8U, std::numeric_limits<std::uint64_t>::max() - 16U, 0U);
  make_aux_ready(byte_overflow, 0U);
  CHECK(byte_overflow.assess(15U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto overflow =
      byte_overflow.commit_write(15U, Direction::Downlink, 32U, 32U);
  CHECK(overflow.result == WriteCommitResult::CounterOverflowFault);
  CHECK(overflow.token.valid() && !overflow.token.tail_known());
  CHECK(byte_overflow.counter_fault_latched());
  CHECK(byte_overflow.quarantined());
  CHECK(byte_overflow.direction_locked());
}

void test_session_identity_rejects_proof_replay_after_reboot() {
  E220UartAdmissionGate before_reboot(1001U);
  make_aux_ready(before_reboot, 0U);
  CHECK(before_reboot.assess(15U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto old_commit =
      before_reboot.commit_write(15U, Direction::Downlink, 32U, 32U);
  CHECK(old_commit.result == WriteCommitResult::Committed);
  CHECK(old_commit.token.session_id() == 1001U);
  CHECK(old_commit.token.generation() == 1U);
  E220DirectionDrainFence old_fence;
  CHECK(old_fence.record_accepted(old_commit.token));
  const auto old_progress = old_fence.observe_remote_progress(old_commit.token);
  const auto old_drain =
      old_fence.observe_remote_tail(old_commit.token, 16U);
  CHECK(old_progress.has_value());
  CHECK(old_drain.has_value());

  E220UartAdmissionGate after_reboot(2002U);
  make_aux_ready(after_reboot, 0U);
  CHECK(after_reboot.assess(15U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto new_commit =
      after_reboot.commit_write(15U, Direction::Downlink, 32U, 32U);
  CHECK(new_commit.result == WriteCommitResult::Committed);
  CHECK(new_commit.token.session_id() == 2002U);
  CHECK(new_commit.token.generation() == 1U);
  CHECK(new_commit.token.direction() == old_commit.token.direction());
  CHECK(new_commit.token.tail() == old_commit.token.tail());
  CHECK(!after_reboot.apply_progress(*old_progress));
  CHECK(!after_reboot.unlock_direction(*old_drain));

  E220DirectionDrainFence new_fence;
  CHECK(new_fence.record_accepted(new_commit.token));
  const auto new_drain =
      new_fence.observe_remote_tail(new_commit.token, 16U);
  CHECK(new_drain.has_value());
  CHECK(after_reboot.unlock_direction(*new_drain));

  E220UartAdmissionGate invalid_session(0U);
  make_aux_ready(invalid_session, 0U);
  CHECK(invalid_session.assess(15U, Direction::Downlink, 32U) ==
        AdmissionResult::InvalidSession);
  CHECK(invalid_session.session_fault_latched());
}

void test_direction_fence_never_reuses_old_complete_or_evidence() {
  E220DirectionDrainFence fence;
  E220UartAdmissionGate token_gate(42U, 0U, 6U);
  make_aux_ready(token_gate, 0U);
  CHECK(token_gate.assess(15U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto first_write =
      token_gate.commit_write(15U, Direction::Downlink, 32U, 32U);
  CHECK(token_gate.assess(18U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto second_write =
      token_gate.commit_write(18U, Direction::Downlink, 32U, 32U);
  const auto first = first_write.token;
  const auto second = second_write.token;
  CHECK(fence.record_accepted(first));
  // A level that was already true is not a fresh completion event.
  fence.observe_local_radio_status(true, true, true);
  CHECK(!fence.radio_tx_complete());
  CHECK(!fence.observe_explicit_tail(first, 10U).has_value());
  fence.observe_local_radio_status(true, false, true);
  CHECK(!fence.radio_tx_complete());
  fence.observe_local_radio_status(true, true, true);
  const auto first_proof = fence.observe_explicit_tail(first, 11U);
  CHECK(first_proof.has_value());
  CHECK(fence.direction_drained());

  CHECK(fence.record_accepted(second));
  CHECK(!fence.radio_tx_complete());
  CHECK(!fence.direction_drained());
  CHECK(!fence.observe_explicit_tail(second, 12U).has_value());
  fence.observe_local_radio_status(true, false, true);
  CHECK(!fence.direction_drained());
  fence.observe_local_radio_status(true, true, true);
  const auto second_proof = fence.observe_explicit_tail(second, 13U);
  CHECK(second_proof.has_value());
  CHECK(fence.direction_drained());
}

void test_direction_fence_rejects_stale_duplicate_wrong_direction_tail() {
  E220DirectionDrainFence fence;
  const auto first = issue_short_token(42U, 4U, Direction::Uplink, 31U);
  const auto last = issue_short_token(42U, 4U, Direction::Uplink, 63U);
  CHECK(fence.record_accepted(first));
  CHECK(fence.record_accepted(last));
  fence.observe_local_radio_status(true, false, true);
  CHECK(!fence.direction_drained());
  CHECK(!fence.observe_remote_tail(first, 10U).has_value());
  CHECK(!fence.observe_remote_tail(
              issue_short_token(42U, 3U, Direction::Uplink, 63U), 12U)
              .has_value());
  CHECK(!fence.observe_remote_tail(
              issue_short_token(42U, 4U, Direction::Downlink, 63U), 13U)
              .has_value());
  const auto proof = fence.observe_remote_tail(last, 14U);
  CHECK(proof.has_value());
  CHECK(!fence.observe_remote_tail(last, 15U).has_value());
  CHECK(fence.direction_drained());
}

void test_transient_fifo_empty_is_not_terminal() {
  NativeBulkDownlink bulk(10U, 1U, 1001U);
  CHECK(bulk.observe_param_value(100U, true, 0U));
  CHECK(poll_bulk(bulk, 101U, input(false, false, false, 0U)) ==
        BulkAction::WaitForData);
  CHECK(bulk.disposition() == BulkDisposition::Running);
  CHECK(bulk.end_reason() == BulkEndReason::None);
  CHECK(poll_bulk(bulk, 102U, input(false, false, true, 7U)) ==
        BulkAction::WaitForData);
  CHECK(bulk.disposition() == BulkDisposition::Running);
  CHECK(poll_bulk(bulk, 103U, input(true, false, false, 37U)) ==
        BulkAction::StartNextParamFrame);
}

void test_inactivity_never_discards_backlog_or_parser_partial() {
  NativeBulkDownlink queued(11U, 1U, 1101U);
  CHECK(queued.observe_param_value(0U, true, 0U));
  CHECK(poll_bulk(queued, 350U, input(true, false, false, 37U)) ==
        BulkAction::StartNextParamFrame);
  CHECK(queued.disposition() == BulkDisposition::Running);
  CHECK(poll_bulk(queued, 351U, input(false, false, true, 7U)) ==
        BulkAction::WaitForData);
  CHECK(queued.disposition() == BulkDisposition::Running);
  CHECK(poll_bulk(queued, 700U, input(false, false, false, 0U)) ==
        BulkAction::EndIncomplete);

  NativeBulkDownlink upstream_done_with_queue(12U, 1U, 1201U);
  CHECK(upstream_done_with_queue.observe_param_value(0U, true, 0U));
  CHECK(poll_bulk(upstream_done_with_queue, 350U,
                  input(true, true, false, 37U)) ==
        BulkAction::StartNextParamFrame);
  CHECK(upstream_done_with_queue.disposition() == BulkDisposition::Running);
}

void test_actual_932_success_requires_clean_upstream_completion() {
  NativeBulkDownlink bulk(70U, 1U, 7001U);
  for (std::uint16_t index = 0U; index < 932U; ++index) {
    CHECK(bulk.observe_param_value(static_cast<std::uint32_t>(index), true,
                                   index));
  }
  CHECK(bulk.param_value_count() == 932U);
  CHECK(poll_bulk(bulk, 932U, input(false, false, false, 0U)) ==
        BulkAction::WaitForData);
  CHECK(poll_bulk(bulk, 933U, input(false, true, true, 0U)) ==
        BulkAction::WaitForData);
  CHECK(poll_bulk(bulk, 934U, input(false, true, false, 1U)) ==
        BulkAction::WaitForData);
  CHECK(poll_bulk(bulk, 935U, input(false, true, false, 0U)) ==
        BulkAction::WaitForFinalParamDelivery);
  const auto final_write = issue_full_parameter_stream(bulk, 70U);
  CHECK(bulk.bind_final_parameter_tail(final_write.final_watermark));
  const auto final_epoch = seal_terminal_outcome(
      bulk, final_write, final_write.completion_ms + 700U);
  CHECK(final_epoch.final_parameter_delivery_applied());
  CHECK(bulk.poll(final_write.completion_ms + 700U, final_epoch,
                  input(false, true, false, 0U)) ==
        BulkAction::EndSuccess);
  CHECK(bulk.disposition() == BulkDisposition::SuccessPending);
  CHECK(commit_terminal_outcome(bulk, final_write));
  CHECK(bulk.disposition() == BulkDisposition::Success);
  CHECK(poll_bulk(bulk, final_write.completion_ms + 701U,
                  input(false, true, false, 0U)) ==
        BulkAction::Complete);
}

void test_clean_completion_waits_for_active_frame() {
  NativeBulkDownlink bulk(71U, 1U, 7101U);
  for (std::uint16_t index = 0U; index < 932U; ++index) {
    CHECK(bulk.observe_param_value(static_cast<std::uint32_t>(index), true,
                                   index));
  }
  const auto final_write = issue_full_parameter_stream(bulk, 71U);
  CHECK(bulk.bind_final_parameter_tail(final_write.final_watermark));
  const auto final_epoch = seal_terminal_outcome(
      bulk, final_write, final_write.completion_ms + 700U);
  CHECK(final_epoch.final_parameter_delivery_applied());
  CHECK(bulk.poll(final_write.completion_ms + 700U, final_epoch,
                  input(true, false, false, 37U)) ==
        BulkAction::StartNextParamFrame);
  CHECK(bulk.begin_active_frame(final_write.completion_ms + 700U, 100U));
  CHECK(poll_bulk(bulk, final_write.completion_ms + 701U,
                  input(false, true, false, 0U)) ==
        BulkAction::ContinueActiveFrame);
  CHECK(bulk.disposition() == BulkDisposition::Running);
  CHECK(bulk.finish_active_frame());
  CHECK(poll_bulk(bulk, final_write.completion_ms + 702U,
                  input(false, true, false, 0U)) ==
        BulkAction::EndSuccess);
  CHECK(commit_terminal_outcome(bulk, final_write));
  CHECK(bulk.disposition() == BulkDisposition::Success);
}

void test_frozen_932_accounted_transport_success_path() {
  NativeBulkDownlink bulk(90U, 1U, 9001U);
  observe_all_parameters(bulk, 15U);
  const auto outcome = issue_full_parameter_stream(bulk, 90U);
  CHECK(bulk.physically_committed_parameter_count() == 932U);
  CHECK(bulk.physically_committed_parameter_chunks() == 1864U);
  CHECK(bulk.physically_committed_parameter_bytes() == 59648U);
  CHECK(outcome.delivery_proof.parameter_count() == 932U);
  CHECK(outcome.delivery_proof.chunk_count() == 1864U);
  CHECK(outcome.delivery_proof.wire_bytes() == 59648U);
  CHECK(outcome.ground_transfer_elapsed_ms < 30000U);
  CHECK(outcome.heartbeat_count >= 20U);
  CHECK(outcome.heartbeat_sla_proof.max_gap_ms() <= 2500U);
  CHECK(bulk.bind_final_parameter_tail(outcome.final_watermark));
  const std::uint32_t terminal_ack_ms = outcome.completion_ms + 700U;
  const auto final_epoch =
      seal_terminal_outcome(bulk, outcome, terminal_ack_ms);
  CHECK(final_epoch.final_parameter_delivery_applied());
  CHECK(final_epoch.heartbeat_sla_applied());
  CHECK(bulk.poll(terminal_ack_ms, final_epoch,
                  input(false, true, false, 0U)) ==
        BulkAction::EndSuccess);
  CHECK(commit_terminal_outcome(bulk, outcome));
  CHECK(bulk.disposition() == BulkDisposition::Success);
}

void test_inactivity_and_absolute_max_are_incomplete_not_success() {
  NativeBulkDownlink inactivity(20U, 1U, 2001U);
  CHECK(inactivity.observe_param_value(1000U, true, 0U));
  CHECK(poll_bulk(inactivity, 1349U, input(false, false, false, 0U)) ==
        BulkAction::WaitForData);
  CHECK(poll_bulk(inactivity, 1350U, input(false, false, false, 0U)) ==
        BulkAction::EndIncomplete);
  CHECK(inactivity.end_reason() == BulkEndReason::InactivityIncomplete);
  CHECK(inactivity.disposition() == BulkDisposition::IncompletePending);
  CHECK(inactivity.commit_end());
  CHECK(inactivity.disposition() == BulkDisposition::Incomplete);

  NativeBulkDownlink absolute(21U, 1U, 2101U);
  constexpr std::uint32_t start = 5000U;
  CHECK(absolute.observe_param_value(start, true, 0U));
  CHECK(absolute.observe_param_value(start + 27999U, true, 1U));
  CHECK(poll_bulk(absolute, start + 28001U,
                  input(false, false, true, 12U)) ==
        BulkAction::EndIncomplete);
  CHECK(absolute.end_reason() == BulkEndReason::AbsoluteMaxIncomplete);
  CHECK(absolute.disposition() == BulkDisposition::IncompletePending);
}

void test_clean_upstream_with_missing_parameter_is_incomplete() {
  NativeBulkDownlink bulk(22U, 1U, 2201U);
  CHECK(bulk.observe_param_value(0U, true, 0U));
  CHECK(poll_bulk(bulk, 1U, input(false, true, false, 0U)) ==
        BulkAction::EndIncomplete);
  CHECK(bulk.end_reason() == BulkEndReason::UpstreamCompleteCountMismatch);
  CHECK(bulk.disposition() == BulkDisposition::IncompletePending);
}

void test_local_ack_timestamp_controls_absolute_deadline() {
  NativeBulkDownlink on_time(80U, 1U, 8001U);
  NativeBulkDownlink late(81U, 1U, 8101U);
  for (std::uint16_t index = 0U; index < 932U; ++index) {
    const auto now = static_cast<std::uint32_t>(index);
    CHECK(on_time.observe_param_value(now, true, index));
    CHECK(late.observe_param_value(now, true, index));
  }
  const auto on_time_write = issue_full_parameter_stream(on_time, 80U);
  CHECK(on_time.bind_final_parameter_tail(on_time_write.final_watermark));
  CHECK(on_time_write.ground_transfer_elapsed_ms < 30000U);
  const std::uint32_t delayed_terminal_ack =
      on_time_write.completion_ms + 5000U;
  const auto on_time_epoch =
      seal_terminal_outcome(on_time, on_time_write, delayed_terminal_ack);
  CHECK(on_time_epoch.final_parameter_delivery_applied());
  CHECK(on_time_epoch.heartbeat_sla_applied());
  CHECK(on_time.poll(delayed_terminal_ack, on_time_epoch,
                     input(false, true, false, 0U)) ==
        BulkAction::EndSuccess);

  const auto late_write = issue_full_parameter_stream(
      late, 81U, std::nullopt, false, false, false, false, 0U, 0U,
      true, 0U, 1130U);
  CHECK(late_write.ground_transfer_elapsed_ms > 30000U);
  CHECK(late.bind_final_parameter_tail(late_write.final_watermark));
  const auto late_epoch = seal_terminal_outcome(
      late, late_write, late_write.completion_ms + 100U);
  CHECK(!late_epoch.final_parameter_delivery_applied());
  CHECK(late.poll(late_write.completion_ms + 100U, late_epoch,
                  input(false, true, false, 0U)) ==
        BulkAction::EndIncomplete);
  CHECK(late.end_reason() == BulkEndReason::FinalTailAfterAbsoluteMax);
}

void test_bulk_rejects_old_session_stream_and_uplink_capabilities() {
  NativeBulkDownlink old_bulk(300U, 1U, 30001U);
  observe_all_parameters(old_bulk);
  const auto old_write = issue_full_parameter_stream(old_bulk, 300U);

  NativeBulkDownlink rebooted(301U, 1U, 30101U);
  observe_all_parameters(rebooted);
  CHECK(!rebooted.bind_final_parameter_tail(old_write.final_watermark));

  NativeBulkDownlink next_stream(300U, 2U, 30002U);
  observe_all_parameters(next_stream);
  CHECK(!next_stream.bind_final_parameter_tail(old_write.final_watermark));

  const auto next_permit = next_stream.parameter_frame_permit();
  CHECK(next_permit.has_value());
  E220UartAdmissionGate uplink_gate(300U);
  make_aux_ready(uplink_gate, 0U);
  CHECK(uplink_gate.assess(15U, Direction::Uplink, 32U) ==
        AdmissionResult::Ready);
  const auto uplink_attempt = uplink_gate.commit_parameter_chunk(
      15U, Direction::Uplink, 32U, 32U, 0U, *next_permit);
  CHECK(uplink_attempt.write.result ==
        WriteCommitResult::UnadmittedWriteFault);
  CHECK(!uplink_attempt.frame_watermark.valid());
  CHECK(uplink_gate.quarantined());

  E220UartAdmissionGate wrong_session_gate(302U);
  make_aux_ready(wrong_session_gate, 0U);
  CHECK(wrong_session_gate.assess(15U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto wrong_session_attempt =
      wrong_session_gate.commit_parameter_chunk(
          15U, Direction::Downlink, 32U, 32U, 0U, *next_permit);
  CHECK(wrong_session_attempt.write.result ==
        WriteCommitResult::UnadmittedWriteFault);
  CHECK(!wrong_session_attempt.frame_watermark.valid());
}

void test_heartbeat_capability_is_bound_to_current_request() {
  NativeBulkDownlink bulk(310U, 9U, 31009U);
  CHECK(bulk.queue_heartbeat(0U));
  const auto first_permit = bulk.heartbeat_tail_permit();
  CHECK(first_permit.has_value());
  E220UartAdmissionGate first_gate(310U);
  make_aux_ready(first_gate, 0U);
  CHECK(first_gate.assess(15U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto first_head = first_gate.commit_heartbeat_chunk(
      15U, Direction::Downlink, 32U, 32U, 0U, *first_permit);
  CHECK(first_head.write.result == WriteCommitResult::Committed);
  CHECK(!first_head.watermark.valid());
  CHECK(first_gate.assess(18U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto first_write = first_gate.commit_heartbeat_chunk(
      18U, Direction::Downlink, 32U, 32U, 1U, *first_permit);
  CHECK(first_write.write.result == WriteCommitResult::Committed);
  CHECK(first_write.watermark.valid());
  CHECK(bulk.bind_heartbeat_tail(first_write.watermark));
  CHECK(bulk.confirm_heartbeat_local_buffer_handoff(
      first_write.watermark, 18U));
  const auto first_epoch = bulk.seal_receiver_events_drained(100U);
  CHECK(!first_epoch.heartbeat_delivery_applied());
  CHECK(bulk.poll(100U, first_epoch, input(false, false, false, 0U)) ==
        BulkAction::WaitForFirstParam);

  CHECK(bulk.queue_heartbeat(200U));
  CHECK(!bulk.bind_heartbeat_tail(first_write.watermark));
  const auto second_permit = bulk.heartbeat_tail_permit();
  CHECK(second_permit.has_value());
  E220UartAdmissionGate wrong_direction_gate(310U);
  make_aux_ready(wrong_direction_gate, 200U);
  CHECK(wrong_direction_gate.assess(215U, Direction::Uplink, 32U) ==
        AdmissionResult::Ready);
  const auto wrong_direction = wrong_direction_gate.commit_heartbeat_chunk(
      215U, Direction::Uplink, 32U, 32U, 0U, *second_permit);
  CHECK(!wrong_direction.watermark.valid());
  CHECK(wrong_direction_gate.quarantined());

  NativeBulkDownlink next_stream(310U, 10U, 31010U);
  CHECK(next_stream.queue_heartbeat(200U));
  CHECK(!next_stream.bind_heartbeat_tail(first_write.watermark));
}

void test_bulk_session_and_stream_zero_fail_closed() {
  NativeBulkDownlink zero_session(0U, 1U, 1U);
  CHECK(zero_session.hard_fault_latched());
  CHECK(zero_session.end_reason() == BulkEndReason::InvalidSession);
  CHECK(poll_bulk(zero_session, 0U, input(false, false, false, 0U)) ==
        BulkAction::EndAbort);

  NativeBulkDownlink zero_stream(1U, 0U, 1U);
  CHECK(zero_stream.hard_fault_latched());
  CHECK(zero_stream.end_reason() == BulkEndReason::InvalidStream);
  CHECK(poll_bulk(zero_stream, 0U, input(false, false, false, 0U)) ==
        BulkAction::EndAbort);
}

void test_final_parameter_transaction_requires_both_chunks_once_in_order() {
  NativeBulkDownlink bulk(320U, 5U, 32005U);
  observe_all_parameters(bulk);
  const auto permit = bulk.parameter_frame_permit();
  CHECK(permit.has_value());
  CHECK(permit->parameter_index() == 0U);

  E220UartAdmissionGate gate(320U);
  make_aux_ready(gate, 0U);
  CHECK(gate.assess(15U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto first = gate.commit_parameter_chunk(
      15U, Direction::Downlink, 32U, 32U, 0U, *permit);
  CHECK(first.write.result == WriteCommitResult::Committed);
  CHECK(!first.frame_watermark.valid());
  CHECK(!first.final_watermark.valid());

  CHECK(gate.assess(18U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto second = gate.commit_parameter_chunk(
      18U, Direction::Downlink, 32U, 32U, 1U, *permit);
  CHECK(second.write.result == WriteCommitResult::Committed);
  CHECK(second.frame_watermark.valid());
  CHECK(!second.final_watermark.valid());
  CHECK(bulk.consume_parameter_frame_tail(second.frame_watermark, 18U));

  CHECK(gate.assess(21U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto reused = gate.commit_parameter_chunk(
      21U, Direction::Downlink, 32U, 32U, 0U, *permit);
  CHECK(reused.write.result == WriteCommitResult::UnadmittedWriteFault);
  CHECK(!reused.frame_watermark.valid());
  CHECK(gate.quarantined());

  NativeBulkDownlink skipped_bulk(321U, 6U, 32106U);
  observe_all_parameters(skipped_bulk);
  const auto skipped_permit = skipped_bulk.parameter_frame_permit();
  CHECK(skipped_permit.has_value());
  E220UartAdmissionGate skipped_gate(321U);
  make_aux_ready(skipped_gate, 0U);
  CHECK(skipped_gate.assess(15U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto skipped = skipped_gate.commit_parameter_chunk(
      15U, Direction::Downlink, 32U, 32U, 1U, *skipped_permit);
  CHECK(skipped.write.result == WriteCommitResult::UnadmittedWriteFault);
  CHECK(!skipped.frame_watermark.valid());
  CHECK(skipped_gate.quarantined());

  E220UartAdmissionGate short_gate(321U);
  make_aux_ready(short_gate, 0U);
  CHECK(short_gate.assess(15U, Direction::Downlink, 31U) ==
        AdmissionResult::Ready);
  const auto short_chunk = short_gate.commit_parameter_chunk(
      15U, Direction::Downlink, 31U, 31U, 0U, *skipped_permit);
  CHECK(short_chunk.write.result == WriteCommitResult::UnadmittedWriteFault);
  CHECK(!short_chunk.frame_watermark.valid());
  CHECK(short_gate.quarantined());
}

void test_heartbeat_transaction_requires_two_chunks_and_is_one_shot() {
  NativeBulkDownlink bulk(330U, 7U, 33007U);
  CHECK(bulk.queue_heartbeat(0U));
  const auto permit = bulk.heartbeat_tail_permit();
  CHECK(permit.has_value());
  E220UartAdmissionGate gate(330U);
  make_aux_ready(gate, 0U);
  CHECK(gate.assess(15U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto head = gate.commit_heartbeat_chunk(
      15U, Direction::Downlink, 32U, 32U, 0U, *permit);
  CHECK(head.write.result == WriteCommitResult::Committed);
  CHECK(!head.watermark.valid());

  CHECK(gate.assess(18U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto sent = gate.commit_heartbeat_chunk(
      18U, Direction::Downlink, 32U, 32U, 1U, *permit);
  CHECK(sent.write.result == WriteCommitResult::Committed);
  CHECK(sent.watermark.valid());
  CHECK(bulk.bind_heartbeat_tail(sent.watermark));

  CHECK(gate.assess(21U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto reused = gate.commit_heartbeat_chunk(
      21U, Direction::Downlink, 32U, 32U, 0U, *permit);
  CHECK(reused.write.result == WriteCommitResult::UnadmittedWriteFault);
  CHECK(!reused.watermark.valid());
  CHECK(gate.quarantined());

  E220UartAdmissionGate short_gate(330U);
  make_aux_ready(short_gate, 0U);
  CHECK(short_gate.assess(15U, Direction::Downlink, 21U) ==
        AdmissionResult::Ready);
  const auto short_chunk = short_gate.commit_heartbeat_chunk(
      15U, Direction::Downlink, 21U, 21U, 0U, *permit);
  CHECK(short_chunk.write.result == WriteCommitResult::UnadmittedWriteFault);
  CHECK(!short_chunk.watermark.valid());

  E220UartAdmissionGate oversized_gate(330U);
  make_aux_ready(oversized_gate, 0U);
  CHECK(oversized_gate.assess(15U, Direction::Downlink, 33U) ==
        AdmissionResult::Oversize);
  const auto oversized_chunk = oversized_gate.commit_heartbeat_chunk(
      15U, Direction::Downlink, 33U, 33U, 0U, *permit);
  CHECK(oversized_chunk.write.result ==
        WriteCommitResult::UnadmittedWriteFault);
  CHECK(!oversized_chunk.watermark.valid());
}

void test_local_ack_time_is_applied_before_deadline_poll() {
  NativeBulkDownlink on_time(340U, 1U, 34001U);
  CHECK(on_time.queue_heartbeat(0U));
  const auto sent = issue_heartbeat_tail(on_time, 340U, 15U);
  CHECK(on_time.bind_heartbeat_tail(sent.watermark));
  CHECK(on_time.confirm_heartbeat_local_buffer_handoff(sent.watermark,
                                                       2500U));
  const auto on_time_epoch = on_time.seal_receiver_events_drained(2500U);
  CHECK(!on_time_epoch.heartbeat_delivery_applied());
  CHECK(on_time.poll(2500U, on_time_epoch,
                     input(false, false, false, 0U)) ==
        BulkAction::WaitForFirstParam);
  CHECK(!on_time.hard_fault_latched());

  NativeBulkDownlink late(341U, 1U, 34101U);
  CHECK(late.queue_heartbeat(0U));
  const auto late_sent = issue_heartbeat_tail(late, 341U, 15U);
  CHECK(late.bind_heartbeat_tail(late_sent.watermark));
  CHECK(!late.confirm_heartbeat_local_buffer_handoff(late_sent.watermark,
                                                     2501U));
  const auto late_epoch = late.seal_receiver_events_drained(2501U);
  CHECK(!late_epoch.heartbeat_delivery_applied());
  CHECK(late.poll(2501U, late_epoch,
                  input(false, false, false, 0U)) == BulkAction::EndAbort);
  CHECK(late.end_reason() == BulkEndReason::HeartbeatDeadlineMiss);
}

void test_poll_epoch_rejects_cached_future_replay_and_time_regression() {
  NativeBulkDownlink cached(350U, 1U, 35001U);
  const auto cached_epoch = cached.seal_receiver_events_drained(1000U);
  CHECK(cached_epoch.valid());
  CHECK(cached.poll(1001U, cached_epoch,
                    input(false, false, false, 0U)) == BulkAction::EndAbort);
  CHECK(cached.end_reason() == BulkEndReason::EvidencePollOrderViolation);

  NativeBulkDownlink future(351U, 1U, 35101U);
  const auto future_epoch = future.seal_receiver_events_drained(1000U);
  CHECK(future.poll(999U, future_epoch,
                    input(false, false, false, 0U)) == BulkAction::EndAbort);
  CHECK(future.end_reason() == BulkEndReason::EvidencePollOrderViolation);

  NativeBulkDownlink replay(352U, 1U, 35201U);
  const auto replay_epoch = replay.seal_receiver_events_drained(1000U);
  CHECK(replay.poll(1000U, replay_epoch,
                    input(false, false, false, 0U)) ==
        BulkAction::WaitForFirstParam);
  CHECK(replay.poll(1000U, replay_epoch,
                    input(false, false, false, 0U)) == BulkAction::EndAbort);
  CHECK(replay.end_reason() == BulkEndReason::EvidencePollOrderViolation);

  NativeBulkDownlink regressing(353U, 1U, 35301U);
  const auto first = regressing.seal_receiver_events_drained(1000U);
  CHECK(regressing.poll(1000U, first,
                        input(false, false, false, 0U)) ==
        BulkAction::WaitForFirstParam);
  const auto backwards = regressing.seal_receiver_events_drained(500U);
  CHECK(!backwards.valid());
  CHECK(regressing.hard_fault_latched());
  CHECK(regressing.end_reason() ==
        BulkEndReason::EvidencePollOrderViolation);

  NativeBulkDownlink wrapping(354U, 1U, 35401U);
  const auto before_wrap =
      wrapping.seal_receiver_events_drained(0xFFFFFFFEU);
  CHECK(wrapping.poll(0xFFFFFFFEU, before_wrap,
                      input(false, false, false, 0U)) ==
        BulkAction::WaitForFirstParam);
  const auto after_wrap = wrapping.seal_receiver_events_drained(1U);
  CHECK(after_wrap.valid());
  CHECK(wrapping.poll(1U, after_wrap,
                      input(false, false, false, 0U)) ==
        BulkAction::WaitForFirstParam);
}

void test_physical_parameter_ledger_starts_at_zero_and_rejects_fresh_gate() {
  NativeBulkDownlink bulk(360U, 1U, 9001U);
  observe_all_parameters(bulk);
  const auto first_permit = bulk.parameter_frame_permit();
  CHECK(first_permit.has_value());
  CHECK(first_permit->parameter_index() == 0U);

  E220UartAdmissionGate gate(360U);
  make_aux_ready(gate, 0U);
  CHECK(gate.assess(15U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto first_chunk = gate.commit_parameter_chunk(
      15U, Direction::Downlink, 32U, 32U, 0U, *first_permit);
  CHECK(!first_chunk.frame_watermark.valid());
  CHECK(!first_chunk.final_watermark.valid());
  CHECK(gate.assess(18U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto first_frame = gate.commit_parameter_chunk(
      18U, Direction::Downlink, 32U, 32U, 1U, *first_permit);
  CHECK(first_frame.frame_watermark.valid());
  CHECK(!first_frame.final_watermark.valid());
  CHECK(bulk.consume_parameter_frame_tail(first_frame.frame_watermark, 18U));
  CHECK(bulk.physically_committed_parameter_count() == 1U);
  CHECK(bulk.physically_committed_parameter_chunks() == 2U);
  CHECK(bulk.physically_committed_parameter_bytes() == 64U);

  const auto second_permit = bulk.parameter_frame_permit();
  CHECK(second_permit.has_value());
  CHECK(second_permit->parameter_index() == 1U);
  E220UartAdmissionGate fresh_gate(360U);
  make_aux_ready(fresh_gate, 0U);
  CHECK(fresh_gate.assess(15U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto skipped_history = fresh_gate.commit_parameter_chunk(
      15U, Direction::Downlink, 32U, 32U, 0U, *second_permit);
  CHECK(skipped_history.write.result ==
        WriteCommitResult::UnadmittedWriteFault);
  CHECK(!skipped_history.frame_watermark.valid());
  CHECK(fresh_gate.quarantined());
}

void test_late_parameter_after_exit_is_recorded_as_loss_and_abort() {
  NativeBulkDownlink bulk(72U, 1U, 7201U);
  for (std::uint16_t index = 0U; index < 932U; ++index) {
    CHECK(bulk.observe_param_value(static_cast<std::uint32_t>(index), true,
                                   index));
  }
  const auto bulk_write = issue_full_parameter_stream(bulk, 72U);
  CHECK(bulk.bind_final_parameter_tail(bulk_write.final_watermark));
  const auto bulk_epoch = seal_terminal_outcome(
      bulk, bulk_write, bulk_write.completion_ms + 100U);
  CHECK(bulk_epoch.final_parameter_delivery_applied());
  CHECK(bulk.poll(bulk_write.completion_ms + 100U, bulk_epoch,
                  input(false, true, false, 0U)) ==
        BulkAction::EndSuccess);
  CHECK(commit_terminal_outcome(bulk, bulk_write));
  CHECK(!bulk.observe_param_value(bulk_write.completion_ms + 101U, true,
                                  932U));
  CHECK(bulk.late_param_loss_count() == 1U);
  CHECK(bulk.hard_fault_latched());
  CHECK(bulk.disposition() == BulkDisposition::Aborted);
  CHECK(bulk.end_reason() == BulkEndReason::LateParamAfterExit);

  NativeBulkDownlink pending(73U, 1U, 7301U);
  for (std::uint16_t index = 0U; index < 932U; ++index) {
    CHECK(pending.observe_param_value(static_cast<std::uint32_t>(index), true,
                                      index));
  }
  const auto pending_write = issue_full_parameter_stream(pending, 73U);
  CHECK(pending.bind_final_parameter_tail(pending_write.final_watermark));
  const auto pending_epoch = seal_terminal_outcome(
      pending, pending_write, pending_write.completion_ms + 100U);
  CHECK(pending_epoch.final_parameter_delivery_applied());
  CHECK(pending.poll(pending_write.completion_ms + 100U, pending_epoch,
                     input(false, true, false, 0U)) ==
        BulkAction::EndSuccess);
  CHECK(!pending.observe_param_value(pending_write.completion_ms + 101U,
                                     true, 932U));
  CHECK(pending.late_param_loss_count() == 1U);
  CHECK(pending.disposition() == BulkDisposition::AbortPending);
  CHECK(poll_bulk(pending, pending_write.completion_ms + 101U,
                  input(false, true, false, 0U)) ==
        BulkAction::EndAbort);
  CHECK(pending.commit_end());
  CHECK(pending.disposition() == BulkDisposition::Aborted);
}

void test_heartbeat_before_bulk_is_schedulable_and_needs_drain_proof() {
  NativeBulkDownlink bulk(55U, 1U, 5501U);
  E220DirectionDrainFence local_fence;
  CHECK(bulk.queue_heartbeat(100U));
  CHECK(poll_bulk(bulk, 100U, input(false, false, false, 0U)) ==
        BulkAction::SendHeartbeat);
  const auto heartbeat_permit = bulk.heartbeat_tail_permit();
  CHECK(heartbeat_permit.has_value());
  E220UartAdmissionGate heartbeat_gate(55U, 0U, 8U);
  make_aux_ready(heartbeat_gate, 100U);
  CHECK(heartbeat_gate.assess(115U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const HeartbeatWriteCommitOutcome heartbeat_head =
      heartbeat_gate.commit_heartbeat_chunk(
          115U, Direction::Downlink, 32U, 32U, 0U, *heartbeat_permit);
  CHECK(heartbeat_head.write.result == WriteCommitResult::Committed);
  CHECK(!heartbeat_head.watermark.valid());
  CHECK(local_fence.record_accepted(heartbeat_head.write.token));
  CHECK(heartbeat_gate.assess(118U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const HeartbeatWriteCommitOutcome heartbeat_write =
      heartbeat_gate.commit_heartbeat_chunk(
          118U, Direction::Downlink, 32U, 32U, 1U, *heartbeat_permit);
  CHECK(heartbeat_write.write.result == WriteCommitResult::Committed);
  CHECK(heartbeat_write.watermark.valid());
  const auto heartbeat_tail = heartbeat_write.write.token;
  CHECK(bulk.bind_heartbeat_tail(heartbeat_write.watermark));
  CHECK(bulk.note_heartbeat_uart_sent());
  CHECK(bulk.heartbeat_pending());
  CHECK(local_fence.record_accepted(heartbeat_tail));
  local_fence.observe_local_radio_status(true, false, true);
  local_fence.observe_local_radio_status(true, true, true);
  const auto local_only =
      local_fence.observe_explicit_tail(heartbeat_tail, 200U);
  CHECK(local_only.has_value());
  CHECK(bulk.confirm_heartbeat_local_buffer_handoff(
      heartbeat_write.watermark, 200U));
  const auto local_epoch = bulk.seal_receiver_events_drained(200U);
  CHECK(!local_epoch.heartbeat_delivery_applied());
  CHECK(bulk.poll(200U, local_epoch, input(false, false, false, 0U)) ==
        BulkAction::WaitForFirstParam);
  CHECK(!bulk.heartbeat_pending());
}

void test_heartbeat_reserve_accounts_for_worst_case_frame_and_tail() {
  static_assert(NativeBulkDownlink::radio_buffer_payload_floor_ms == 167U);
  static_assert(NativeBulkDownlink::conservative_tail_service_ms >= 167U);
  static_assert(NativeBulkDownlink::heartbeat_reserve_floor_ms >=
                NativeBulkDownlink::conservative_tail_service_ms);
  static_assert(NativeBulkDownlink::required_heartbeat_reserve_ms(350U) ==
                700U);

  NativeBulkDownlink bulk(30U, 1U, 3001U);
  CHECK(bulk.observe_param_value(0U, true, 0U));
  CHECK(bulk.queue_heartbeat(0U));
  CHECK(bulk.observe_param_value(1750U, true, 1U));
  CHECK(poll_bulk(bulk, 1799U,
                  input(true, false, false, 37U, 350U)) ==
        BulkAction::StartNextParamFrame);
  CHECK(bulk.begin_active_frame(1799U, 350U));
  CHECK(poll_bulk(bulk, 1800U,
                  input(true, false, false, 37U, 350U)) ==
        BulkAction::ContinueActiveFrame);
  CHECK(bulk.finish_active_frame());
  CHECK(poll_bulk(bulk, 1800U,
                  input(true, false, false, 37U, 350U)) ==
        BulkAction::SendHeartbeat);
  CHECK(!bulk.begin_active_frame(1800U, 350U));
}

void test_active_frame_is_not_split_but_deadline_miss_is_hard_abort() {
  NativeBulkDownlink bulk(31U, 1U, 3101U);
  CHECK(bulk.observe_param_value(0U, true, 0U));
  CHECK(bulk.queue_heartbeat(0U));
  CHECK(bulk.observe_param_value(1750U, true, 1U));
  CHECK(poll_bulk(bulk, 1799U,
                  input(true, false, false, 37U, 350U)) ==
        BulkAction::StartNextParamFrame);
  CHECK(bulk.begin_active_frame(1799U, 350U));
  CHECK(poll_bulk(bulk, 2501U,
                  input(false, false, false, 0U, 350U)) ==
        BulkAction::ContinueActiveFrame);
  CHECK(bulk.hard_fault_latched());
  CHECK(bulk.end_reason() == BulkEndReason::HeartbeatDeadlineMiss);
  CHECK(!bulk.commit_end());
  CHECK(bulk.finish_active_frame());
  CHECK(poll_bulk(bulk, 2502U,
                  input(false, false, false, 0U, 350U)) ==
        BulkAction::EndAbort);
  CHECK(bulk.commit_end());
  CHECK(bulk.disposition() == BulkDisposition::Aborted);
}

void test_param_order_and_counter_overflow_are_hard_faults() {
  NativeBulkDownlink order(32U, 1U, 3201U);
  CHECK(order.observe_param_value(10U, true, 0U));
  CHECK(!order.observe_param_value(11U, true, 2U));
  CHECK(order.hard_fault_latched());
  CHECK(order.end_reason() == BulkEndReason::ParamOrderViolation);
  CHECK(poll_bulk(order, 11U, input(false, false, false, 0U)) ==
        BulkAction::EndAbort);

  NativeBulkDownlink overflow(33U, 1U, 3301U,
                              std::numeric_limits<std::uint64_t>::max());
  CHECK(!overflow.observe_param_value(0U, true, 0U));
  CHECK(overflow.counter_fault_latched());
  CHECK(overflow.hard_fault_latched());
  CHECK(overflow.end_reason() == BulkEndReason::CounterOverflow);
  CHECK(poll_bulk(overflow, 0U, input(false, false, false, 0U)) ==
        BulkAction::EndAbort);
}

void test_all_timers_are_wrap_safe() {
  E220UartAdmissionGate gate(91U);
  constexpr std::uint32_t aux_start = 0xFFFFFFEFU;
  gate.observe_aux(aux_start, true);
  CHECK(gate.assess(0xFFFFFFFDU, Direction::Downlink, 32U) ==
        AdmissionResult::AuxNotStable);
  CHECK(gate.assess(0xFFFFFFFEU, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  CHECK(gate.commit_write(0xFFFFFFFEU, Direction::Downlink, 32U, 32U)
            .result == WriteCommitResult::Committed);
  CHECK(gate.assess(0U, Direction::Downlink, 32U) ==
        AdmissionResult::GapActive);
  CHECK(gate.assess(1U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);

  constexpr std::uint32_t start = 0xFFFFFF00U;
  NativeBulkDownlink inactivity(34U, 1U, 3401U);
  CHECK(inactivity.observe_param_value(start, true, 0U));
  CHECK(poll_bulk(inactivity, start + 349U,
                  input(false, false, false, 0U)) ==
        BulkAction::WaitForData);
  CHECK(poll_bulk(inactivity, start + 350U,
                  input(false, false, false, 0U)) ==
        BulkAction::EndIncomplete);

  NativeBulkDownlink heartbeat(35U, 1U, 3501U);
  CHECK(heartbeat.observe_param_value(start, true, 0U));
  CHECK(heartbeat.queue_heartbeat(start));
  CHECK(heartbeat.observe_param_value(start + 1750U, true, 1U));
  CHECK(poll_bulk(heartbeat, start + 1799U,
                  input(true, false, false, 37U, 350U)) ==
        BulkAction::StartNextParamFrame);
  CHECK(poll_bulk(heartbeat, start + 1800U,
                  input(true, false, false, 37U, 350U)) ==
        BulkAction::SendHeartbeat);
  CHECK(!heartbeat.heartbeat_deadline_missed(start + 2500U));
  CHECK(heartbeat.heartbeat_deadline_missed(start + 2501U));
}

void test_remote_delivery_ledger_rejects_noncontiguous_or_wrong_stream() {
  NativeBulkDownlink source(370U, 1U, 37001U);
  CHECK(source.observe_param_value(0U, true, 0U));
  CHECK(source.observe_param_value(1U, true, 1U));
  E220UartAdmissionGate gate(370U);
  make_aux_ready(gate, 0U);

  const auto first_permit = source.parameter_frame_permit();
  CHECK(first_permit.has_value());
  CHECK(gate.assess(15U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto chunk0 = gate.commit_parameter_chunk(
      15U, Direction::Downlink, 32U, 32U, 0U, *first_permit);
  CHECK(chunk0.chunk_watermark.valid());
  CHECK(gate.assess(18U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto chunk1 = gate.commit_parameter_chunk(
      18U, Direction::Downlink, 32U, 32U, 1U, *first_permit);
  CHECK(chunk1.chunk_watermark.valid());
  CHECK(source.consume_parameter_frame_tail(chunk1.frame_watermark, 18U));

  const auto second_permit = source.parameter_frame_permit();
  CHECK(second_permit.has_value());
  CHECK(gate.assess(21U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto chunk2 = gate.commit_parameter_chunk(
      21U, Direction::Downlink, 32U, 32U, 0U, *second_permit);
  CHECK(chunk2.chunk_watermark.valid());

  RemoteDeliveryLedger missing(370U, 1U, 37001U, 0U);
  CHECK(missing.observe_parameter_chunk(chunk0.chunk_watermark, 15U));
  CHECK(!missing.observe_parameter_chunk(chunk2.chunk_watermark, 21U));
  CHECK(!missing.seal_parameter_stream_delivery().has_value());
  CHECK(missing.accounting_fault());

  RemoteDeliveryLedger duplicate(370U, 1U, 37001U, 0U);
  CHECK(duplicate.observe_parameter_chunk(chunk0.chunk_watermark, 15U));
  CHECK(!duplicate.observe_parameter_chunk(chunk0.chunk_watermark, 16U));
  CHECK(!duplicate.seal_parameter_stream_delivery().has_value());
  CHECK(duplicate.accounting_fault());

  RemoteDeliveryLedger out_of_order(370U, 1U, 37001U, 0U);
  CHECK(!out_of_order.observe_parameter_chunk(chunk1.chunk_watermark, 18U));
  CHECK(!out_of_order.seal_parameter_stream_delivery().has_value());
  CHECK(out_of_order.accounting_fault());

  RemoteDeliveryLedger wrong_session(371U, 1U, 37001U, 0U);
  CHECK(!wrong_session.observe_parameter_chunk(chunk0.chunk_watermark, 15U));
  CHECK(!wrong_session.seal_parameter_stream_delivery().has_value());
  CHECK(wrong_session.accounting_fault());
  RemoteDeliveryLedger wrong_stream(370U, 2U, 37001U, 0U);
  CHECK(!wrong_stream.observe_parameter_chunk(chunk0.chunk_watermark, 15U));
  CHECK(!wrong_stream.seal_parameter_stream_delivery().has_value());
  CHECK(wrong_stream.accounting_fault());
  RemoteDeliveryLedger wrong_lease(370U, 1U, 37002U, 0U);
  CHECK(!wrong_lease.observe_parameter_chunk(chunk0.chunk_watermark, 15U));
  CHECK(!wrong_lease.seal_parameter_stream_delivery().has_value());
  CHECK(wrong_lease.accounting_fault());

  NativeBulkDownlink full(372U, 1U, 37201U);
  observe_all_parameters(full);
  const auto full_write = issue_full_parameter_stream(full, 372U);
  RemoteDeliveryLedger final_only(372U, 1U, 37201U, 0U);
  CHECK(!final_only.observe_parameter_chunk(
      full_write.final_chunk_watermark, full_write.completion_ms));
  CHECK(!final_only.seal_parameter_stream_delivery().has_value());
  CHECK(final_only.received_parameter_count() == 0U);
  CHECK(final_only.accounting_fault());

  NativeBulkDownlink terminal_duplicate(373U, 1U, 37301U);
  observe_all_parameters(terminal_duplicate);
  const auto duplicate_write = issue_full_parameter_stream(
      terminal_duplicate, 373U, std::nullopt, true);
  CHECK(duplicate_write.receiver_fault);
  CHECK(!duplicate_write.delivery_proof.valid());

  NativeBulkDownlink timestamped(374U, 1U, 37401U);
  observe_all_parameters(timestamped);
  const auto timestamped_write = issue_full_parameter_stream(
      timestamped, 374U, std::nullopt, false, true);
  CHECK(timestamped_write.delivery_proof.valid());
  CHECK(timestamped_write.trailing_heartbeat_proof.valid());
  CHECK(timestamped_write.delivery_proof.remote_observed_at_ms() -
            timestamped_write.trailing_heartbeat_proof.remote_observed_at_ms() <=
        2500U);

  // A proof from the same session/token shape but a different lease cannot
  // terminalize a locally complete stream.
  NativeBulkDownlink other_lease(372U, 1U, 37202U);
  observe_all_parameters(other_lease);
  const auto other_write = issue_full_parameter_stream(other_lease, 372U);
  CHECK(other_lease.bind_final_parameter_tail(other_write.final_watermark));
  CHECK(other_lease.open_terminal_ack_window(other_write.completion_ms));
  const auto foreign_epoch = other_lease.seal_terminal_receiver_evidence(
      other_write.completion_ms + 100U, full_write.delivery_proof,
      *other_write.receiver, other_write.heartbeat_sla_proof,
      *other_write.heartbeat_receiver);
  CHECK(!foreign_epoch.final_parameter_delivery_applied());
  CHECK(other_lease.poll(other_write.completion_ms + 100U, foreign_epoch,
                         input(false, true, false, 0U)) ==
        BulkAction::EndAbort);
}

void test_heartbeat_delivery_is_purpose_specific_and_frame_boundary_only() {
  NativeBulkDownlink bulk(380U, 2U, 38002U);
  CHECK(bulk.observe_param_value(0U, true, 0U));
  CHECK(bulk.observe_param_value(1U, true, 1U));
  E220UartAdmissionGate gate(380U);
  RemoteDeliveryLedger receiver(380U, 2U, 38002U, 0U);
  make_aux_ready(gate, 0U);

  const auto first_permit = bulk.parameter_frame_permit();
  CHECK(first_permit.has_value());
  CHECK(gate.assess(15U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto p0c0 = gate.commit_parameter_chunk(
      15U, Direction::Downlink, 32U, 32U, 0U, *first_permit);
  CHECK(receiver.observe_parameter_chunk(p0c0.chunk_watermark, 15U));
  CHECK(gate.assess(18U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto p0c1 = gate.commit_parameter_chunk(
      18U, Direction::Downlink, 32U, 32U, 1U, *first_permit);
  CHECK(receiver.observe_parameter_chunk(p0c1.chunk_watermark, 18U));
  CHECK(bulk.consume_parameter_frame_tail(p0c1.frame_watermark, 18U));

  CHECK(bulk.queue_heartbeat(19U));
  const auto heartbeat_permit = bulk.heartbeat_tail_permit();
  CHECK(heartbeat_permit.has_value());
  CHECK(gate.assess(21U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto heartbeat_head = gate.commit_heartbeat_chunk(
      21U, Direction::Downlink, 32U, 32U, 0U, *heartbeat_permit);
  CHECK(heartbeat_head.write.result == WriteCommitResult::Committed);
  CHECK(!heartbeat_head.watermark.valid());
  CHECK(gate.assess(24U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto heartbeat = gate.commit_heartbeat_chunk(
      24U, Direction::Downlink, 32U, 32U, 1U, *heartbeat_permit);
  CHECK(heartbeat.write.result == WriteCommitResult::Committed);
  CHECK(heartbeat.watermark.valid());
  CHECK(bulk.bind_heartbeat_tail(heartbeat.watermark));
  const auto heartbeat_delivery =
      receiver.observe_heartbeat(heartbeat.watermark, 24U);
  CHECK(heartbeat_delivery.has_value());
  CHECK(bulk.confirm_heartbeat_local_buffer_handoff(heartbeat.watermark,
                                                    24U));
  CHECK(receiver.received_parameter_count() == 1U);
  CHECK(receiver.received_parameter_chunks() == 2U);
  const auto heartbeat_epoch = bulk.seal_receiver_events_drained(24U);
  CHECK(!heartbeat_epoch.heartbeat_delivery_applied());
  CHECK(bulk.poll(24U, heartbeat_epoch,
                  input(false, false, false, 0U)) ==
        BulkAction::WaitForData);

  const auto second_permit = bulk.parameter_frame_permit();
  CHECK(second_permit.has_value());
  CHECK(second_permit->parameter_index() == 1U);
  CHECK(gate.assess(27U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto p1c0 = gate.commit_parameter_chunk(
      27U, Direction::Downlink, 32U, 32U, 0U, *second_permit);
  CHECK(receiver.observe_parameter_chunk(p1c0.chunk_watermark, 27U));
  CHECK(!receiver.accounting_fault());

  NativeBulkDownlink midframe(381U, 3U, 38103U);
  CHECK(midframe.observe_param_value(0U, true, 0U));
  const auto mid_param = midframe.parameter_frame_permit();
  CHECK(mid_param.has_value());
  E220UartAdmissionGate mid_gate(381U);
  make_aux_ready(mid_gate, 0U);
  CHECK(mid_gate.assess(15U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto mid_first = mid_gate.commit_parameter_chunk(
      15U, Direction::Downlink, 32U, 32U, 0U, *mid_param);
  CHECK(mid_first.chunk_watermark.valid());
  RemoteDeliveryLedger mid_receiver(381U, 3U, 38103U, 0U);
  CHECK(mid_receiver.observe_parameter_chunk(mid_first.chunk_watermark,
                                              15U));
  CHECK(midframe.queue_heartbeat(16U));
  const auto mid_heartbeat = midframe.heartbeat_tail_permit();
  CHECK(mid_heartbeat.has_value());

  // Build an otherwise valid next-tail HB watermark on an alias gate so the
  // receiver (not only the sender gate) proves the mid-frame rejection.
  E220UartAdmissionGate alias_gate(381U);
  make_aux_ready(alias_gate, 0U);
  CHECK(alias_gate.assess(15U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  CHECK(alias_gate.commit_write(15U, Direction::Downlink, 32U, 32U).result ==
        WriteCommitResult::Committed);
  CHECK(alias_gate.assess(18U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto alias_heartbeat_head = alias_gate.commit_heartbeat_chunk(
      18U, Direction::Downlink, 32U, 32U, 0U, *mid_heartbeat);
  CHECK(alias_heartbeat_head.write.result == WriteCommitResult::Committed);
  CHECK(!alias_heartbeat_head.watermark.valid());
  CHECK(alias_gate.assess(21U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto alias_heartbeat = alias_gate.commit_heartbeat_chunk(
      21U, Direction::Downlink, 32U, 32U, 1U, *mid_heartbeat);
  CHECK(alias_heartbeat.watermark.valid());
  CHECK(!mid_receiver.observe_heartbeat(alias_heartbeat.watermark, 21U)
             .has_value());
  CHECK(mid_receiver.accounting_fault());

  CHECK(mid_gate.assess(18U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto rejected = mid_gate.commit_heartbeat_chunk(
      18U, Direction::Downlink, 32U, 32U, 0U, *mid_heartbeat);
  CHECK(rejected.write.result == WriteCommitResult::UnadmittedWriteFault);
  CHECK(!rejected.watermark.valid());
  CHECK(mid_gate.quarantined());
}

void test_parameter_proof_is_revoked_by_post_seal_duplicate_before_terminal_commit() {
  NativeBulkDownlink bulk(390U, 1U, 39001U);
  observe_all_parameters(bulk);
  const auto write = issue_full_parameter_stream(
      bulk, 390U, std::nullopt, false, false, true, false);
  CHECK(write.delivery_proof.valid());
  CHECK(write.receiver_fault);
  CHECK(bulk.bind_final_parameter_tail(write.final_watermark));
  CHECK(bulk.open_terminal_ack_window(write.completion_ms));
  const auto epoch = bulk.seal_terminal_receiver_evidence(
      write.completion_ms + 100U, write.delivery_proof, *write.receiver,
      write.heartbeat_sla_proof, *write.heartbeat_receiver);
  CHECK(!epoch.final_parameter_delivery_applied());
  CHECK(bulk.poll(write.completion_ms + 100U, epoch,
                  input(false, true, false, 0U)) ==
        BulkAction::EndAbort);

  NativeBulkDownlink after_bulk_seal(391U, 1U, 39101U);
  observe_all_parameters(after_bulk_seal);
  const auto sealed_write =
      issue_full_parameter_stream(after_bulk_seal, 391U);
  CHECK(after_bulk_seal.bind_final_parameter_tail(
      sealed_write.final_watermark));
  const auto sealed_epoch = seal_terminal_outcome(
      after_bulk_seal, sealed_write, sealed_write.completion_ms + 100U);
  CHECK(sealed_epoch.final_parameter_delivery_applied());
  CHECK(sealed_epoch.heartbeat_sla_applied());
  CHECK(after_bulk_seal.poll(
            sealed_write.completion_ms + 100U, sealed_epoch,
            input(false, true, false, 0U)) == BulkAction::EndSuccess);
  CHECK(!sealed_write.receiver->observe_parameter_chunk(
      sealed_write.final_chunk_watermark,
      sealed_write.completion_ms + 1U));
  CHECK(sealed_write.receiver->accounting_fault());
  CHECK(!after_bulk_seal.commit_end(*sealed_write.receiver,
                                    *sealed_write.heartbeat_receiver));
  CHECK(after_bulk_seal.hard_fault_latched());
  CHECK(after_bulk_seal.end_reason() ==
        BulkEndReason::ReceiverEvidenceRevoked);
}

void test_remote_clock_offset_cannot_change_hb_or_final_deadline_result() {
  NativeBulkDownlink zero_offset(402U, 1U, 40201U);
  NativeBulkDownlink large_offset(403U, 1U, 40301U);
  observe_all_parameters(zero_offset);
  observe_all_parameters(large_offset);
  const auto zero = issue_full_parameter_stream(zero_offset, 402U, 0U);
  const auto shifted =
      issue_full_parameter_stream(large_offset, 403U, 100000U);
  CHECK(zero.ground_transfer_elapsed_ms ==
        shifted.ground_transfer_elapsed_ms);
  CHECK(zero.heartbeat_sla_proof.first_gap_ms() ==
        shifted.heartbeat_sla_proof.first_gap_ms());
  CHECK(zero.heartbeat_sla_proof.max_gap_ms() ==
        shifted.heartbeat_sla_proof.max_gap_ms());
  CHECK(zero.heartbeat_sla_proof.post_gap_ms() ==
        shifted.heartbeat_sla_proof.post_gap_ms());
  CHECK(zero_offset.bind_final_parameter_tail(zero.final_watermark));
  CHECK(large_offset.bind_final_parameter_tail(shifted.final_watermark));
  const auto zero_epoch = seal_terminal_outcome(
      zero_offset, zero, zero.completion_ms + 100U);
  const auto shifted_epoch = seal_terminal_outcome(
      large_offset, shifted, shifted.completion_ms + 100U);
  CHECK(zero_epoch.final_parameter_delivery_applied());
  CHECK(shifted_epoch.final_parameter_delivery_applied());
  CHECK(zero_epoch.heartbeat_sla_applied());
  CHECK(shifted_epoch.heartbeat_sla_applied());
}

void test_completed_parameter_stream_rejects_cached_index_zero_permit() {
  NativeBulkDownlink bulk(410U, 1U, 41001U);
  observe_all_parameters(bulk);
  const auto write = issue_full_parameter_stream(
      bulk, 410U, std::nullopt, false, false, false, true);
  CHECK(!write.cached_parameter_permit_reaccepted);
}

void test_half_duplex_bulk_can_prove_heartbeat_sla_without_midstream_reverse_ack() {
  NativeBulkDownlink bulk(420U, 1U, 42001U);
  observe_all_parameters(bulk);
  const auto outcome = issue_full_parameter_stream(bulk, 420U);
  CHECK(outcome.heartbeat_count >= 20U);
  CHECK(outcome.heartbeat_sla_proof.valid());
  CHECK(outcome.heartbeat_sla_proof.first_gap_ms() <= 2500U);
  CHECK(outcome.heartbeat_sla_proof.max_gap_ms() <= 2500U);
  CHECK(outcome.heartbeat_sla_proof.post_gap_ms() <= 2500U);
  CHECK(outcome.ground_transfer_elapsed_ms < 30000U);
  CHECK(!bulk.heartbeat_pending());
  CHECK(bulk.bind_final_parameter_tail(outcome.final_watermark));
  const auto terminal = seal_terminal_outcome(
      bulk, outcome, outcome.completion_ms + 100U);
  CHECK(terminal.final_parameter_delivery_applied());
  CHECK(terminal.heartbeat_sla_applied());
  CHECK(bulk.poll(outcome.completion_ms + 100U, terminal,
                  input(false, true, false, 0U)) ==
        BulkAction::EndSuccess);
  CHECK(commit_terminal_outcome(bulk, outcome));
}

void test_aux_tail_airtime_overlap_is_nominal_only_and_nonoverlap_misses_28s() {
  NativeBulkDownlink nominal(422U, 1U, 42201U);
  observe_all_parameters(nominal);
  const auto nominal_outcome = issue_full_parameter_stream(nominal, 422U);
  CHECK(nominal_outcome.aux_tail_airtime_overlap_assumed);
  CHECK(nominal_outcome.local_aux_credit_releases > 0U);
  CHECK(nominal_outcome.ground_transfer_elapsed_ms <=
        NativeBulkDownlink::absolute_max_ms);
  CHECK(nominal_outcome.ground_transfer_elapsed_ms < 30000U);
  CHECK(nominal_outcome.heartbeat_sla_proof.valid());

  NativeBulkDownlink conservative(423U, 1U, 42301U);
  observe_all_parameters(conservative);
  const auto conservative_outcome = issue_full_parameter_stream(
      conservative, 423U, std::nullopt, false, false, false, false, 0U,
      0U, false);
  CHECK(!conservative_outcome.aux_tail_airtime_overlap_assumed);
  CHECK(conservative_outcome.local_aux_credit_releases > 0U);
  CHECK(conservative_outcome.ground_transfer_elapsed_ms >
        NativeBulkDownlink::absolute_max_ms);
  CHECK(conservative_outcome.ground_transfer_elapsed_ms < 30000U);
  CHECK(conservative_outcome.heartbeat_sla_proof.valid());

  measured_nominal_pipelined_ms =
      nominal_outcome.ground_transfer_elapsed_ms;
  measured_nonoverlap_ms =
      conservative_outcome.ground_transfer_elapsed_ms;
}

void test_sender_local_full_handoff_hard_deadline_boundary() {
  NativeBulkDownlink on_boundary(424U, 1U, 42401U);
  observe_all_parameters(on_boundary);
  const auto on_boundary_outcome = issue_full_parameter_stream(
      on_boundary, 424U, std::nullopt, false, false, false, false, 0U,
      0U, true, 829U);
  CHECK(on_boundary_outcome.ground_transfer_elapsed_ms == 28000U);
  CHECK(on_boundary.bind_final_parameter_tail(
      on_boundary_outcome.final_watermark));
  const auto on_boundary_epoch = seal_terminal_outcome(
      on_boundary, on_boundary_outcome,
      on_boundary_outcome.completion_ms + 100U);
  CHECK(on_boundary.poll(on_boundary_outcome.completion_ms + 100U,
                         on_boundary_epoch,
                         input(false, true, false, 0U)) ==
        BulkAction::EndSuccess);
  CHECK(commit_terminal_outcome(on_boundary, on_boundary_outcome));

  NativeBulkDownlink one_ms_late(425U, 1U, 42501U);
  observe_all_parameters(one_ms_late);
  const auto one_ms_late_outcome = issue_full_parameter_stream(
      one_ms_late, 425U, std::nullopt, false, false, false, false, 0U,
      0U, true, 830U);
  CHECK(one_ms_late_outcome.ground_transfer_elapsed_ms == 28001U);
  CHECK(poll_bulk(one_ms_late, one_ms_late_outcome.completion_ms,
                  input(false, true, false, 0U)) ==
        BulkAction::EndIncomplete);
  CHECK(one_ms_late.end_reason() ==
        BulkEndReason::FinalLocalHandoffAfterAbsoluteMax);

  NativeBulkDownlink nonoverlap(426U, 1U, 42601U);
  observe_all_parameters(nonoverlap);
  const auto nonoverlap_outcome = issue_full_parameter_stream(
      nonoverlap, 426U, std::nullopt, false, false, false, false, 0U,
      0U, true, 1830U);
  CHECK(nonoverlap_outcome.ground_transfer_elapsed_ms == 29001U);
  CHECK(poll_bulk(nonoverlap, nonoverlap_outcome.completion_ms,
                  input(false, true, false, 0U)) ==
        BulkAction::EndIncomplete);
  CHECK(nonoverlap.end_reason() ==
        BulkEndReason::FinalLocalHandoffAfterAbsoluteMax);
}

void test_ackless_downlink_replenishes_400_byte_credit_from_local_e220_evidence() {
  E220UartAdmissionGate gate(421U);
  make_aux_ready(gate, 0U);
  std::uint32_t now = 15U;
  TransferToken latest{};
  for (std::size_t chunk = 0U; chunk < 12U; ++chunk) {
    CHECK(gate.assess(now, Direction::Downlink, 32U) ==
          AdmissionResult::Ready);
    const auto write = gate.commit_write(now, Direction::Downlink, 32U, 32U);
    CHECK(write.result == WriteCommitResult::Committed);
    latest = write.token;
    now += 3U;
  }
  CHECK(gate.buffered_bytes() == 384U);
  CHECK(gate.assess(now, Direction::Downlink, 32U) ==
        AdmissionResult::Backpressure);
  CHECK(!gate.release_buffer_credit_from_local_aux(now, latest));
  gate.observe_aux(now, false);
  gate.observe_aux(now + 1U, true);
  CHECK(!gate.release_buffer_credit_from_local_aux(now + 15U, latest));
  CHECK(gate.release_buffer_credit_from_local_aux(now + 16U, latest));
  CHECK(gate.buffered_bytes() == 0U);
  CHECK(gate.assess(now + 16U, Direction::Downlink, 32U) ==
        AdmissionResult::Ready);
  const auto next = gate.commit_write(now + 16U, Direction::Downlink,
                                      32U, 32U);
  CHECK(next.result == WriteCommitResult::Committed);
  CHECK(!gate.release_buffer_credit_from_local_aux(now + 32U, latest));
  CHECK(!gate.release_buffer_credit_from_local_aux(now + 32U,
                                                   next.token));
  gate.observe_aux(now + 32U, false);
  gate.observe_aux(now + 33U, true);
  CHECK(!gate.release_buffer_credit_from_local_aux(now + 47U,
                                                   next.token));
  CHECK(gate.release_buffer_credit_from_local_aux(now + 48U,
                                                  next.token));
  CHECK(gate.direction_locked());

  E220DirectionDrainFence remote_progress;
  CHECK(remote_progress.record_accepted(next.token));
  const auto remote = remote_progress.observe_remote_progress(next.token);
  CHECK(remote.has_value());
  CHECK(!gate.apply_progress(*remote));
}

void test_remote_heartbeat_sla_rejects_missing_gap_duplicate_wrong_lease_and_bad_baseline() {
  NativeBulkDownlink source(430U, 1U, 43001U);
  CHECK(source.queue_heartbeat(0U));
  const auto first = issue_heartbeat_tail(source, 430U, 15U);
  CHECK(source.bind_heartbeat_tail(first.watermark));
  CHECK(source.confirm_heartbeat_local_buffer_handoff(first.watermark, 15U));
  CHECK(source.queue_heartbeat(1000U));
  const auto second = issue_heartbeat_tail(source, 430U, 1015U);
  CHECK(source.bind_heartbeat_tail(second.watermark));
  CHECK(source.confirm_heartbeat_local_buffer_handoff(second.watermark,
                                                      1015U));

  RemoteHeartbeatSlaLedger gap(430U, 1U, 43001U, 0U, 0U, 0U);
  CHECK(gap.observe_heartbeat(first.watermark, 1000U, 1U));
  CHECK(!gap.observe_heartbeat(second.watermark, 3501U, 2U));
  CHECK(gap.accounting_fault());

  RemoteHeartbeatSlaLedger duplicate(430U, 1U, 43001U, 0U, 0U, 0U);
  CHECK(duplicate.observe_heartbeat(first.watermark, 1000U, 1U));
  CHECK(!duplicate.observe_heartbeat(first.watermark, 1001U, 1U));
  CHECK(duplicate.accounting_fault());

  NativeBulkDownlink foreign_source(430U, 1U, 43002U);
  CHECK(foreign_source.queue_heartbeat(0U));
  const auto foreign = issue_heartbeat_tail(foreign_source, 430U, 15U);
  RemoteHeartbeatSlaLedger wrong_lease(430U, 1U, 43001U, 0U, 0U, 0U);
  CHECK(!wrong_lease.observe_heartbeat(foreign.watermark, 1000U, 1U));
  CHECK(wrong_lease.accounting_fault());

  RemoteHeartbeatSlaLedger bad_baseline(430U, 1U, 43001U, 2000U, 0U,
                                        0U);
  CHECK(!bad_baseline.observe_heartbeat(first.watermark, 4000U, 1U));
  CHECK(bad_baseline.accounting_fault());

  NativeBulkDownlink full(431U, 1U, 43101U);
  observe_all_parameters(full);
  const auto full_outcome = issue_full_parameter_stream(full, 431U);
  RemoteHeartbeatSlaLedger missing(431U, 1U, 43101U, 0U, 0U, 0U);
  CHECK(!missing.seal_terminal_sla(full_outcome.delivery_proof).has_value());

  NativeBulkDownlink post_source(431U, 1U, 43101U);
  CHECK(post_source.queue_heartbeat(0U));
  const auto post_first = issue_heartbeat_tail(post_source, 431U, 15U);
  RemoteHeartbeatSlaLedger post_gap(431U, 1U, 43101U, 0U, 0U, 0U);
  CHECK(post_gap.observe_heartbeat(post_first.watermark, 1000U, 1U));
  CHECK(!post_gap.seal_terminal_sla(full_outcome.delivery_proof).has_value());
  CHECK(post_gap.accounting_fault());
}

void test_terminal_pair_is_atomic_cross_bound_and_revocable() {
  NativeBulkDownlink first_bulk(440U, 1U, 44001U);
  NativeBulkDownlink second_bulk(440U, 1U, 44001U);
  observe_all_parameters(first_bulk);
  observe_all_parameters(second_bulk);
  const auto first = issue_full_parameter_stream(first_bulk, 440U);
  const auto second = issue_full_parameter_stream(second_bulk, 440U);
  CHECK(first_bulk.bind_final_parameter_tail(first.final_watermark));
  CHECK(first_bulk.open_terminal_ack_window(first.completion_ms));
  const auto rejected = first_bulk.seal_terminal_receiver_evidence(
      first.completion_ms + 100U, first.delivery_proof, *first.receiver,
      second.heartbeat_sla_proof, *second.heartbeat_receiver);
  CHECK(!rejected.final_parameter_delivery_applied());
  CHECK(!rejected.heartbeat_sla_applied());
  CHECK(first_bulk.hard_fault_latched());
  CHECK(first_bulk.end_reason() == BulkEndReason::ReceiverEvidenceRevoked);
  CHECK(!first.receiver->parameter_terminal_consumed());
  CHECK(!second.heartbeat_receiver->terminal_consumed());

  NativeBulkDownlink revoked(441U, 1U, 44101U);
  observe_all_parameters(revoked);
  const auto revoked_outcome = issue_full_parameter_stream(revoked, 441U);
  CHECK(!revoked_outcome.heartbeat_receiver->observe_heartbeat(
      revoked_outcome.last_heartbeat_watermark,
      revoked_outcome.ground_last_parameter_ms + 1U,
      revoked_outcome.heartbeat_count));
  CHECK(revoked_outcome.heartbeat_receiver->accounting_fault());
  CHECK(revoked.bind_final_parameter_tail(revoked_outcome.final_watermark));
  CHECK(revoked.open_terminal_ack_window(revoked_outcome.completion_ms));
  const auto revoked_epoch = revoked.seal_terminal_receiver_evidence(
      revoked_outcome.completion_ms + 100U,
      revoked_outcome.delivery_proof, *revoked_outcome.receiver,
      revoked_outcome.heartbeat_sla_proof,
      *revoked_outcome.heartbeat_receiver);
  CHECK(!revoked_epoch.heartbeat_sla_applied());
  CHECK(revoked.hard_fault_latched());
}

void test_terminal_ack_wait_is_finite_and_separate_from_ground_30s_metric() {
  NativeBulkDownlink timeout(450U, 1U, 45001U);
  observe_all_parameters(timeout);
  const auto outcome = issue_full_parameter_stream(timeout, 450U);
  CHECK(outcome.ground_transfer_elapsed_ms < 30000U);
  CHECK(timeout.bind_final_parameter_tail(outcome.final_watermark));
  CHECK(timeout.open_terminal_ack_window(outcome.completion_ms));
  CHECK(poll_bulk(timeout,
                  outcome.completion_ms +
                      NativeBulkDownlink::terminal_ack_wait_ms + 1U,
                  input(false, true, false, 0U)) ==
        BulkAction::EndIncomplete);
  CHECK(timeout.end_reason() == BulkEndReason::TerminalAckTimeout);

  NativeBulkDownlink request_delay(451U, 1U, 45101U);
  observe_all_parameters(request_delay);
  const auto delayed = issue_full_parameter_stream(
      request_delay, 451U, std::nullopt, false, false, false, false, 0U,
      4000U, true);
  CHECK(delayed.delivery_proof.remote_observed_at_ms() -
            delayed.delivery_proof.remote_first_parameter_ms() <
        30000U);
  CHECK(delayed.ground_transfer_elapsed_ms > 30000U);
  CHECK(!delayed.heartbeat_sla_proof.valid());
}

void test_rejects_first_in_stream_heartbeat_when_pre_stream_baseline_gap_exceeds_sla() {
  NativeBulkDownlink source(460U, 1U, 46001U);
  CHECK(source.queue_heartbeat(2000U));
  const auto first = issue_heartbeat_tail(source, 460U, 2015U);
  RemoteHeartbeatSlaLedger ledger(460U, 1U, 46001U, 2000U, 0U, 0U);
  CHECK(!ledger.observe_heartbeat(first.watermark, 4000U, 1U));
  CHECK(ledger.accounting_fault());
}

}  // namespace

int main() {
  test_admission_full_write_aux_gap_and_direction();
  test_generation_tail_credit_rejects_stale_duplicate_and_wrong();
  test_partial_and_unadmitted_positive_write_enter_quarantine();
  test_admission_overflow_is_fail_latched_before_or_after_write();
  test_session_identity_rejects_proof_replay_after_reboot();
  test_direction_fence_never_reuses_old_complete_or_evidence();
  test_direction_fence_rejects_stale_duplicate_wrong_direction_tail();
  test_transient_fifo_empty_is_not_terminal();
  test_inactivity_never_discards_backlog_or_parser_partial();
  test_actual_932_success_requires_clean_upstream_completion();
  test_clean_completion_waits_for_active_frame();
  test_frozen_932_accounted_transport_success_path();
  test_inactivity_and_absolute_max_are_incomplete_not_success();
  test_clean_upstream_with_missing_parameter_is_incomplete();
  test_local_ack_timestamp_controls_absolute_deadline();
  test_bulk_rejects_old_session_stream_and_uplink_capabilities();
  test_heartbeat_capability_is_bound_to_current_request();
  test_bulk_session_and_stream_zero_fail_closed();
  test_final_parameter_transaction_requires_both_chunks_once_in_order();
  test_heartbeat_transaction_requires_two_chunks_and_is_one_shot();
  test_local_ack_time_is_applied_before_deadline_poll();
  test_poll_epoch_rejects_cached_future_replay_and_time_regression();
  test_physical_parameter_ledger_starts_at_zero_and_rejects_fresh_gate();
  test_late_parameter_after_exit_is_recorded_as_loss_and_abort();
  test_heartbeat_before_bulk_is_schedulable_and_needs_drain_proof();
  test_heartbeat_reserve_accounts_for_worst_case_frame_and_tail();
  test_active_frame_is_not_split_but_deadline_miss_is_hard_abort();
  test_param_order_and_counter_overflow_are_hard_faults();
  test_all_timers_are_wrap_safe();
  test_remote_delivery_ledger_rejects_noncontiguous_or_wrong_stream();
  test_heartbeat_delivery_is_purpose_specific_and_frame_boundary_only();
  test_parameter_proof_is_revoked_by_post_seal_duplicate_before_terminal_commit();
  test_remote_clock_offset_cannot_change_hb_or_final_deadline_result();
  test_completed_parameter_stream_rejects_cached_index_zero_permit();
  test_half_duplex_bulk_can_prove_heartbeat_sla_without_midstream_reverse_ack();
  test_aux_tail_airtime_overlap_is_nominal_only_and_nonoverlap_misses_28s();
  test_sender_local_full_handoff_hard_deadline_boundary();
  test_ackless_downlink_replenishes_400_byte_credit_from_local_e220_evidence();
  test_remote_heartbeat_sla_rejects_missing_gap_duplicate_wrong_lease_and_bad_baseline();
  test_terminal_pair_is_atomic_cross_bound_and_revocable();
  test_terminal_ack_wait_is_finite_and_separate_from_ground_30s_metric();
  test_rejects_first_in_stream_heartbeat_when_pre_stream_baseline_gap_exceeds_sla();

  if (failures != 0) {
    std::cerr << "HIGH_SPEED_TRANSPORT_MODEL FAIL count=" << failures << '\n';
    return EXIT_FAILURE;
  }
  std::cout << "HIGH_SPEED_TRANSPORT_MODEL PASS tests=42"
            << " expected_params=932 buffer_limit=400 chunk_limit=32"
            << " nominal_pipelined_ms=" << measured_nominal_pipelined_ms
            << " nonoverlap_ms=" << measured_nonoverlap_ms
            << " live_gate=false\n";
  return EXIT_SUCCESS;
}
