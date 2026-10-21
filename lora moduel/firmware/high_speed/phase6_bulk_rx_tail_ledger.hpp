#pragma once

#include <cstddef>
#include <cstdint>
#include <limits>

#include "vc_lora/bulk_data_codec.hpp"
#include "vc_lora/bulk_session_controller.hpp"
#include "vc_lora/high_speed_tdd_coordinator.hpp"

namespace vc_lora::experimental {

enum class R19BulkRxTailLedgerStatus : std::uint8_t {
  Idle = 0U,
  Armed,
  FragmentAccepted,
  FinalIdentityReady,
  IdentityIssued,
  InvalidConfiguration,
  InvalidState,
  InvalidFragment,
  DecoderRejected,
  EvidenceMismatch,
  ClockRegression,
  CounterOverflow,
  FailClosed,
};

struct R19BulkRxTailLedgerCounterSeed final {
  std::uint32_t last_token{0xA1000000U};
  std::uint32_t last_generation{0xB2000000U};
};

// Local receive-ledger owner for the final complete VCB1 record. It owns no
// UART and cannot turn byte arrival, AUX HIGH, or UART admission into physical
// tail evidence. The only accounting entry point accepts one exact 32-byte
// fragment and itself feeds those bytes to the bound BulkDataStreamDecoder.
// An identity can therefore be issued only after that decoder accepted every
// CRC-valid/tag-valid fragment in contiguous transfer-global ordinal order.
// Heartbeat count is intentionally not known at arm time. The terminal record
// is discovered only when the decoder accepts the ordered PARAM_VALUE index
// 931 tail and can successfully finish its complete 932-parameter corpus.
//
// RX token and generation use explicit local domains. They are deliberately
// unrelated to the Vehicle's remote writer token/generation, which VCB1 does
// not carry on wire. The resulting identity still needs a separate correlated
// physical-tail event before GroundHighSpeedPhase6Adapter::on_bulk_tail().
class R19BulkRxTailLedger final {
public:
  static constexpr std::uint32_t local_rx_token_domain = 0xA1000000U;
  static constexpr std::uint32_t local_rx_generation_domain = 0xB2000000U;
  static constexpr std::uint32_t local_domain_mask = 0xFF000000U;
  static constexpr std::uint32_t local_counter_suffix_mask = 0x00FFFFFFU;
  static constexpr std::uint32_t local_rx_token_limit =
      local_rx_token_domain | local_counter_suffix_mask;
  static constexpr std::uint32_t local_rx_generation_limit =
      local_rx_generation_domain | local_counter_suffix_mask;
  static constexpr std::uint32_t maximum_fragment_count =
      static_cast<std::uint32_t>(std::numeric_limits<std::uint16_t>::max()) +
      1U;

  explicit R19BulkRxTailLedger(
      R19BulkRxTailLedgerCounterSeed seed = {}) noexcept
      : next_token_(seed.last_token), next_generation_(seed.last_generation),
        failed_(!is_local_rx_token_seed(seed.last_token) ||
                !is_local_rx_generation_seed(seed.last_generation)),
        last_status_(failed_ ? R19BulkRxTailLedgerStatus::InvalidConfiguration
                             : R19BulkRxTailLedgerStatus::Idle) {}
  R19BulkRxTailLedger(const R19BulkRxTailLedger &) = delete;
  R19BulkRxTailLedger &operator=(const R19BulkRxTailLedger &) = delete;
  R19BulkRxTailLedger(R19BulkRxTailLedger &&) = delete;
  R19BulkRxTailLedger &operator=(R19BulkRxTailLedger &&) = delete;

  [[nodiscard]] R19BulkRxTailLedgerStatus
  arm(std::uint32_t negotiated_transfer_tag, std::uint64_t now_ms) noexcept {
    if (failed_) {
      return R19BulkRxTailLedgerStatus::FailClosed;
    }
    if (!note_time(now_ms)) {
      return fail(R19BulkRxTailLedgerStatus::ClockRegression);
    }
    if ((state_ != State::Idle && state_ != State::IdentityIssued) ||
        negotiated_transfer_tag == 0U ||
        negotiated_transfer_tag == previous_transfer_tag_) {
      return fail(R19BulkRxTailLedgerStatus::InvalidConfiguration);
    }
    if (next_generation_ >= local_rx_generation_limit) {
      return fail(R19BulkRxTailLedgerStatus::CounterOverflow);
    }
    ++next_generation_;
    transfer_tag_ = negotiated_transfer_tag;
    accepted_fragment_count_ = 0U;
    session_generation_ = next_generation_;
    pending_identity_ = {};
    state_ = State::Active;
    return set_status(R19BulkRxTailLedgerStatus::Armed);
  }

  [[nodiscard]] R19BulkRxTailLedgerStatus accept_decoder_fragment(
      BulkDataStreamDecoder &decoder, const BulkDataFragment &fragment,
      MavlinkFrame &frame_output, std::uint64_t completed_ms) noexcept {
    frame_output = {};
    if (failed_) {
      return R19BulkRxTailLedgerStatus::FailClosed;
    }
    if (!note_time(completed_ms)) {
      return fail(R19BulkRxTailLedgerStatus::ClockRegression);
    }
    if (state_ != State::Active) {
      return fail(R19BulkRxTailLedgerStatus::InvalidState);
    }

    BulkDataDecodedFragment decoded_fragment{};
    if (BulkDataWireCodec::decode_fragment(fragment, decoded_fragment) !=
        BulkDataWireStatus::FragmentReady) {
      return fail(R19BulkRxTailLedgerStatus::InvalidFragment);
    }
    if (decoded_fragment.transfer_tag != transfer_tag_ ||
        static_cast<std::uint32_t>(decoded_fragment.wire_ordinal) !=
            accepted_fragment_count_ ||
        accepted_fragment_count_ >= maximum_fragment_count ||
        decoder.expected_transfer_tag() != transfer_tag_ || decoder.latched() ||
        decoder.sealed() ||
        decoder.next_wire_ordinal() != accepted_fragment_count_) {
      return fail(R19BulkRxTailLedgerStatus::EvidenceMismatch);
    }

    BulkDataStreamStatus decoder_status = BulkDataStreamStatus::NeedMore;
    MavlinkFrame candidate{};
    for (std::size_t index = 0U; index < fragment.size(); ++index) {
      decoder_status = decoder.push_byte(fragment[index], candidate);
      if (index + 1U != fragment.size() &&
          decoder_status != BulkDataStreamStatus::NeedMore) {
        return fail(R19BulkRxTailLedgerStatus::DecoderRejected);
      }
    }
    const bool head =
        decoded_fragment.kind == BulkDataFragmentKind::ParameterHead ||
        decoded_fragment.kind == BulkDataFragmentKind::HeartbeatHead;
    const BulkDataStreamStatus expected_status =
        head ? BulkDataStreamStatus::FragmentAccepted
             : BulkDataStreamStatus::FrameReady;
    if (decoder_status != expected_status || decoder.latched() ||
        decoder.next_wire_ordinal() != accepted_fragment_count_ + 1U) {
      return fail(R19BulkRxTailLedgerStatus::DecoderRejected);
    }

    ++accepted_fragment_count_;
    const bool final =
        decoder_status == BulkDataStreamStatus::FrameReady &&
        decoded_fragment.kind == BulkDataFragmentKind::ParameterTail &&
        candidate.message_id == 22U &&
        decoder.parameter_count() == decoder.expected_parameter_count();
    if ((!final && decoder.complete()) || (final && !decoder.finish())) {
      return fail(R19BulkRxTailLedgerStatus::EvidenceMismatch);
    }
    if (!head) {
      frame_output = candidate;
    }
    if (!final) {
      return set_status(R19BulkRxTailLedgerStatus::FragmentAccepted);
    }
    if (next_token_ >= local_rx_token_limit) {
      return fail(R19BulkRxTailLedgerStatus::CounterOverflow);
    }
    ++next_token_;
    pending_identity_.transfer_tag = transfer_tag_;
    pending_identity_.final_wire_ordinal = accepted_fragment_count_ - 1U;
    pending_identity_.fragment_count = accepted_fragment_count_;
    pending_identity_.rx_record_token = next_token_;
    pending_identity_.rx_ledger_generation = session_generation_;
    state_ = State::FinalReady;
    return set_status(R19BulkRxTailLedgerStatus::FinalIdentityReady);
  }

  [[nodiscard]] R19BulkRxTailLedgerStatus
  issue_final_identity(HighSpeedLocalRxRecordIdentity &output,
                       std::uint64_t now_ms) noexcept {
    output = {};
    if (failed_) {
      return R19BulkRxTailLedgerStatus::FailClosed;
    }
    if (!note_time(now_ms)) {
      return fail(R19BulkRxTailLedgerStatus::ClockRegression);
    }
    if (state_ != State::FinalReady || !identity_valid(pending_identity_)) {
      return fail(R19BulkRxTailLedgerStatus::InvalidState);
    }
    output = pending_identity_;
    previous_transfer_tag_ = transfer_tag_;
    pending_identity_ = {};
    state_ = State::IdentityIssued;
    return set_status(R19BulkRxTailLedgerStatus::IdentityIssued);
  }

  [[nodiscard]] static constexpr bool
  is_local_rx_token(std::uint32_t token) noexcept {
    return token != 0U && (token & local_domain_mask) == local_rx_token_domain;
  }

  [[nodiscard]] static constexpr bool
  is_local_rx_generation(std::uint32_t generation) noexcept {
    return generation != 0U &&
           (generation & local_domain_mask) == local_rx_generation_domain;
  }

  [[nodiscard]] static constexpr bool
  is_local_rx_token_seed(std::uint32_t token) noexcept {
    return (token & local_domain_mask) == local_rx_token_domain &&
           token <= local_rx_token_limit;
  }

  [[nodiscard]] static constexpr bool
  is_local_rx_generation_seed(std::uint32_t generation) noexcept {
    return (generation & local_domain_mask) == local_rx_generation_domain &&
           generation <= local_rx_generation_limit;
  }

  [[nodiscard]] constexpr bool fail_closed() const noexcept { return failed_; }
  [[nodiscard]] constexpr bool active() const noexcept {
    return !failed_ && state_ == State::Active;
  }
  [[nodiscard]] constexpr bool final_identity_ready() const noexcept {
    return !failed_ && state_ == State::FinalReady;
  }
  [[nodiscard]] constexpr std::uint32_t
  accepted_fragment_count() const noexcept {
    return accepted_fragment_count_;
  }
  [[nodiscard]] constexpr R19BulkRxTailLedgerStatus
  last_status() const noexcept {
    return last_status_;
  }

private:
  enum class State : std::uint8_t {
    Idle = 0U,
    Active,
    FinalReady,
    IdentityIssued,
    FailClosed,
  };

  [[nodiscard]] static constexpr bool
  identity_valid(const HighSpeedLocalRxRecordIdentity &identity) noexcept {
    return identity.transfer_tag != 0U && identity.fragment_count != 0U &&
           identity.final_wire_ordinal + 1U == identity.fragment_count &&
           is_local_rx_token(identity.rx_record_token) &&
           is_local_rx_generation(identity.rx_ledger_generation);
  }

  [[nodiscard]] bool note_time(std::uint64_t now_ms) noexcept {
    if (have_last_time_ && now_ms < last_time_ms_) {
      return false;
    }
    have_last_time_ = true;
    last_time_ms_ = now_ms;
    return true;
  }

  [[nodiscard]] R19BulkRxTailLedgerStatus
  set_status(R19BulkRxTailLedgerStatus status) noexcept {
    last_status_ = status;
    return status;
  }

  [[nodiscard]] R19BulkRxTailLedgerStatus
  fail(R19BulkRxTailLedgerStatus reason) noexcept {
    failed_ = true;
    state_ = State::FailClosed;
    last_status_ = reason;
    return reason;
  }

  State state_{State::Idle};
  HighSpeedLocalRxRecordIdentity pending_identity_{};
  std::uint32_t transfer_tag_{0U};
  std::uint32_t previous_transfer_tag_{0U};
  std::uint32_t accepted_fragment_count_{0U};
  std::uint32_t session_generation_{0U};
  std::uint32_t next_token_{local_rx_token_domain};
  std::uint32_t next_generation_{local_rx_generation_domain};
  std::uint64_t last_time_ms_{0U};
  bool have_last_time_{false};
  bool failed_{false};
  R19BulkRxTailLedgerStatus last_status_{R19BulkRxTailLedgerStatus::Idle};
};

static_assert(R19BulkRxTailLedger::maximum_fragment_count == 65'536U);
static_assert(R19BulkRxTailLedger::is_local_rx_token(0xA1000001U));
static_assert(R19BulkRxTailLedger::is_local_rx_generation(0xB2000001U));

} // namespace vc_lora::experimental
