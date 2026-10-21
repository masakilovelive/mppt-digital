#pragma once

// Offline-only transport model for the high-speed experiment. This header has
// no device I/O and is not included by either accepted R18 sketch. It models
// evidence-carrying admission/drain and bulk termination before any live
// implementation is authorized.

#include "vc_lora_high_speed_candidate.hpp"

#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>

namespace vc_lora::experimental {

static_assert(!HighSpeedCandidateContract::live_flash_authorized,
              "The offline transport model must not open the live gate");
inline constexpr bool transport_model_live_flash_authorized =
    HighSpeedCandidateContract::live_flash_authorized;

constexpr std::uint32_t elapsed_ms(std::uint32_t now,
                                   std::uint32_t since) noexcept {
  return now - since;
}

enum class Direction : std::uint8_t {
  Downlink = 0U,
  Uplink = 1U,
  Mixed = 2U
};

class E220UartAdmissionGate;
class NativeBulkDownlink;
class RemoteDeliveryLedger;
class RemoteHeartbeatSlaLedger;

class TransferToken {
 public:
  constexpr TransferToken() noexcept = default;

  // session_id is a boot/session epoch supplied by the eventual integration.
  // It prevents generation=1 from a reboot matching generation=1 before it.
  [[nodiscard]] constexpr std::uint64_t session_id() const noexcept {
    return session_id_;
  }
  [[nodiscard]] constexpr std::uint32_t generation() const noexcept {
    return generation_;
  }
  [[nodiscard]] constexpr Direction direction() const noexcept {
    return direction_;
  }
  [[nodiscard]] constexpr std::uint64_t tail() const noexcept { return tail_; }
  [[nodiscard]] constexpr bool tail_known() const noexcept {
    return tail_known_;
  }
  [[nodiscard]] constexpr bool valid() const noexcept { return valid_; }

 private:
  friend class E220UartAdmissionGate;
  constexpr TransferToken(std::uint64_t session_value,
                          std::uint32_t generation_value,
                          Direction direction_value,
                          std::uint64_t tail_value,
                          bool tail_is_known) noexcept
      : session_id_(session_value),
        generation_(generation_value),
        direction_(direction_value),
        tail_(tail_value),
        tail_known_(tail_is_known),
        valid_(session_value != 0U && generation_value != 0U &&
               (tail_is_known ? direction_value != Direction::Mixed : true)) {}

  std::uint64_t session_id_ = 0U;
  std::uint32_t generation_ = 0U;
  Direction direction_ = Direction::Downlink;
  std::uint64_t tail_ = 0U;
  bool tail_known_ = false;
  bool valid_ = false;
};

constexpr bool operator==(const TransferToken& lhs,
                          const TransferToken& rhs) noexcept {
  return lhs.session_id() == rhs.session_id() &&
         lhs.generation() == rhs.generation() &&
         lhs.direction() == rhs.direction() && lhs.tail() == rhs.tail() &&
         lhs.tail_known() == rhs.tail_known() && lhs.valid() == rhs.valid();
}

constexpr bool operator!=(const TransferToken& lhs,
                          const TransferToken& rhs) noexcept {
  return !(lhs == rhs);
}

enum class EvidenceSource : std::uint8_t {
  RemoteArrival,
  ExplicitTxComplete,
  ExplicitQuarantineDrain
};

class E220DirectionDrainFence;

class HeartbeatTailPermit {
 public:
  constexpr HeartbeatTailPermit() noexcept = default;
  [[nodiscard]] constexpr bool valid() const noexcept { return valid_; }
  [[nodiscard]] constexpr std::uint64_t session_id() const noexcept {
    return session_id_;
  }
  [[nodiscard]] constexpr std::uint64_t stream_id() const noexcept {
    return stream_id_;
  }
  [[nodiscard]] constexpr std::uint64_t lease_id() const noexcept {
    return lease_id_;
  }
  [[nodiscard]] constexpr std::uint32_t request_id() const noexcept {
    return request_id_;
  }

 private:
  friend class NativeBulkDownlink;
  constexpr HeartbeatTailPermit(std::uint64_t session_id,
                                std::uint64_t stream_id,
                                std::uint64_t lease_id,
                                std::uint32_t request_id) noexcept
      : session_id_(session_id),
        stream_id_(stream_id),
        lease_id_(lease_id),
        request_id_(request_id),
        valid_(session_id != 0U && stream_id != 0U && lease_id != 0U &&
               request_id != 0U) {}

  std::uint64_t session_id_ = 0U;
  std::uint64_t stream_id_ = 0U;
  std::uint64_t lease_id_ = 0U;
  std::uint32_t request_id_ = 0U;
  bool valid_ = false;
};

class ParameterFramePermit {
 public:
  constexpr ParameterFramePermit() noexcept = default;
  [[nodiscard]] constexpr bool valid() const noexcept { return valid_; }
  [[nodiscard]] constexpr std::uint64_t session_id() const noexcept {
    return session_id_;
  }
  [[nodiscard]] constexpr std::uint64_t stream_id() const noexcept {
    return stream_id_;
  }
  [[nodiscard]] constexpr std::uint64_t lease_id() const noexcept {
    return lease_id_;
  }
  [[nodiscard]] constexpr std::uint16_t parameter_index() const noexcept {
    return parameter_index_;
  }

 private:
  friend class NativeBulkDownlink;
  constexpr ParameterFramePermit(std::uint64_t session_id,
                                 std::uint64_t stream_id,
                                 std::uint64_t lease_id,
                                 std::uint16_t parameter_index) noexcept
      : session_id_(session_id),
        stream_id_(stream_id),
        lease_id_(lease_id),
        parameter_index_(parameter_index),
        valid_(session_id != 0U && stream_id != 0U && lease_id != 0U &&
               parameter_index < 932U) {}

  std::uint64_t session_id_ = 0U;
  std::uint64_t stream_id_ = 0U;
  std::uint64_t lease_id_ = 0U;
  std::uint16_t parameter_index_ = 0U;
  bool valid_ = false;
};

class ParameterFrameTailWatermark {
 public:
  constexpr ParameterFrameTailWatermark() noexcept = default;
  [[nodiscard]] constexpr bool valid() const noexcept { return valid_; }
  [[nodiscard]] constexpr const TransferToken& token() const noexcept {
    return token_;
  }
  [[nodiscard]] constexpr std::uint64_t stream_id() const noexcept {
    return stream_id_;
  }
  [[nodiscard]] constexpr std::uint64_t lease_id() const noexcept {
    return lease_id_;
  }
  [[nodiscard]] constexpr std::uint16_t parameter_index() const noexcept {
    return parameter_index_;
  }

 private:
  friend class E220UartAdmissionGate;
  constexpr ParameterFrameTailWatermark(
      TransferToken token, std::uint64_t stream_id, std::uint64_t lease_id,
      std::uint16_t parameter_index) noexcept
      : token_(token),
        stream_id_(stream_id),
        lease_id_(lease_id),
        parameter_index_(parameter_index),
        valid_(token.valid() && token.direction() == Direction::Downlink &&
               stream_id != 0U && lease_id != 0U &&
               parameter_index < 932U) {}

  TransferToken token_{};
  std::uint64_t stream_id_ = 0U;
  std::uint64_t lease_id_ = 0U;
  std::uint16_t parameter_index_ = 0U;
  bool valid_ = false;
};

// Issued for every admitted 32-byte PARAM_VALUE wire chunk. Unlike a frame
// tail, this carries the parameter-ledger ordinal needed by the receiver to
// prove that no earlier PARAM chunk was skipped merely because a later tail
// arrived. It is deliberately distinct from VCB1's interleaved
// transfer-global fragment ordinal.
class ParameterChunkWatermark {
 public:
  constexpr ParameterChunkWatermark() noexcept = default;
  [[nodiscard]] constexpr bool valid() const noexcept { return valid_; }
  [[nodiscard]] constexpr const TransferToken& token() const noexcept {
    return token_;
  }
  [[nodiscard]] constexpr std::uint64_t stream_id() const noexcept {
    return stream_id_;
  }
  [[nodiscard]] constexpr std::uint64_t lease_id() const noexcept {
    return lease_id_;
  }
  [[nodiscard]] constexpr std::uint16_t parameter_index() const noexcept {
    return parameter_index_;
  }
  [[nodiscard]] constexpr std::uint8_t chunk_ordinal() const noexcept {
    return chunk_ordinal_;
  }
  [[nodiscard]] constexpr std::uint64_t global_chunk_ordinal() const noexcept {
    return global_chunk_ordinal_;
  }

 private:
  friend class E220UartAdmissionGate;
  constexpr ParameterChunkWatermark(
      TransferToken token, std::uint64_t stream_id, std::uint64_t lease_id,
      std::uint16_t parameter_index, std::uint8_t chunk_ordinal,
      std::uint64_t global_chunk_ordinal) noexcept
      : token_(token),
        stream_id_(stream_id),
        lease_id_(lease_id),
        parameter_index_(parameter_index),
        chunk_ordinal_(chunk_ordinal),
        global_chunk_ordinal_(global_chunk_ordinal),
        valid_(token.valid() && token.direction() == Direction::Downlink &&
               stream_id != 0U && lease_id != 0U &&
               parameter_index < 932U && chunk_ordinal < 2U &&
               global_chunk_ordinal < 1864U) {}

  TransferToken token_{};
  std::uint64_t stream_id_ = 0U;
  std::uint64_t lease_id_ = 0U;
  std::uint16_t parameter_index_ = 0U;
  std::uint8_t chunk_ordinal_ = 0U;
  std::uint64_t global_chunk_ordinal_ = 0U;
  bool valid_ = false;
};

class HeartbeatTailWatermark {
 public:
  constexpr HeartbeatTailWatermark() noexcept = default;
  [[nodiscard]] constexpr bool valid() const noexcept { return valid_; }
  [[nodiscard]] constexpr const TransferToken& token() const noexcept {
    return token_;
  }
  [[nodiscard]] constexpr std::uint64_t stream_id() const noexcept {
    return stream_id_;
  }
  [[nodiscard]] constexpr std::uint64_t lease_id() const noexcept {
    return lease_id_;
  }
  [[nodiscard]] constexpr std::uint32_t request_id() const noexcept {
    return request_id_;
  }

 private:
  friend class E220UartAdmissionGate;
  constexpr HeartbeatTailWatermark(TransferToken token,
                                   std::uint64_t stream_id,
                                   std::uint64_t lease_id,
                                   std::uint32_t request_id) noexcept
      : token_(token),
        stream_id_(stream_id),
        lease_id_(lease_id),
        request_id_(request_id),
        valid_(token.valid() && token.direction() == Direction::Downlink &&
               stream_id != 0U && lease_id != 0U && request_id != 0U) {}

  TransferToken token_{};
  std::uint64_t stream_id_ = 0U;
  std::uint64_t lease_id_ = 0U;
  std::uint32_t request_id_ = 0U;
  bool valid_ = false;
};

class FinalParameterTailWatermark {
 public:
  constexpr FinalParameterTailWatermark() noexcept = default;
  [[nodiscard]] constexpr bool valid() const noexcept { return valid_; }
  [[nodiscard]] constexpr const TransferToken& token() const noexcept {
    return token_;
  }
  [[nodiscard]] constexpr std::uint64_t stream_id() const noexcept {
    return stream_id_;
  }
  [[nodiscard]] constexpr std::uint64_t lease_id() const noexcept {
    return lease_id_;
  }
  [[nodiscard]] constexpr std::uint16_t parameter_index() const noexcept {
    return parameter_index_;
  }

 private:
  friend class E220UartAdmissionGate;
  constexpr FinalParameterTailWatermark(
      TransferToken token, std::uint64_t stream_id, std::uint64_t lease_id,
      std::uint16_t parameter_index) noexcept
      : token_(token),
        stream_id_(stream_id),
        lease_id_(lease_id),
        parameter_index_(parameter_index),
        valid_(token.valid() && token.direction() == Direction::Downlink &&
               stream_id != 0U && lease_id != 0U &&
               parameter_index == 931U) {}

  TransferToken token_{};
  std::uint64_t stream_id_ = 0U;
  std::uint64_t lease_id_ = 0U;
  std::uint16_t parameter_index_ = 0U;
  bool valid_ = false;
};

// These are receiver-purpose capabilities, not generic UART-drain evidence.
// Their timestamps are captured by RemoteDeliveryLedger and cannot be
// supplied later by the scheduler.
class HeartbeatDeliveryProof {
 public:
  constexpr HeartbeatDeliveryProof() noexcept = default;
  [[nodiscard]] constexpr bool valid() const noexcept { return valid_; }
  [[nodiscard]] constexpr const TransferToken& token() const noexcept {
    return token_;
  }
  [[nodiscard]] constexpr std::uint64_t stream_id() const noexcept {
    return stream_id_;
  }
  [[nodiscard]] constexpr std::uint64_t lease_id() const noexcept {
    return lease_id_;
  }
  [[nodiscard]] constexpr std::uint32_t request_id() const noexcept {
    return request_id_;
  }
  [[nodiscard]] constexpr std::uint32_t
  remote_observed_at_ms() const noexcept {
    return remote_observed_at_ms_;
  }
 private:
  friend class RemoteDeliveryLedger;
  constexpr HeartbeatDeliveryProof(TransferToken token,
                                   std::uint64_t stream_id,
                                   std::uint64_t lease_id,
                                   std::uint32_t request_id,
                                   std::uint32_t remote_observed_at_ms) noexcept
      : token_(token),
        stream_id_(stream_id),
        lease_id_(lease_id),
        request_id_(request_id),
        remote_observed_at_ms_(remote_observed_at_ms),
        valid_(token.valid() && token.direction() == Direction::Downlink &&
               stream_id != 0U && lease_id != 0U && request_id != 0U) {}

  TransferToken token_{};
  std::uint64_t stream_id_ = 0U;
  std::uint64_t lease_id_ = 0U;
  std::uint32_t request_id_ = 0U;
  std::uint32_t remote_observed_at_ms_ = 0U;
  bool valid_ = false;
};

class ParameterStreamDeliveryProof {
 public:
  constexpr ParameterStreamDeliveryProof() noexcept = default;
  [[nodiscard]] constexpr bool valid() const noexcept { return valid_; }
  [[nodiscard]] constexpr const TransferToken& final_token() const noexcept {
    return final_token_;
  }
  [[nodiscard]] constexpr std::uint64_t stream_id() const noexcept {
    return stream_id_;
  }
  [[nodiscard]] constexpr std::uint64_t lease_id() const noexcept {
    return lease_id_;
  }
  [[nodiscard]] constexpr std::uint64_t parameter_count() const noexcept {
    return parameter_count_;
  }
  [[nodiscard]] constexpr std::uint64_t chunk_count() const noexcept {
    return chunk_count_;
  }
  [[nodiscard]] constexpr std::uint64_t wire_bytes() const noexcept {
    return wire_bytes_;
  }
  [[nodiscard]] constexpr std::uint32_t
  remote_observed_at_ms() const noexcept {
    return remote_observed_at_ms_;
  }
  [[nodiscard]] constexpr std::uint32_t
  remote_first_parameter_ms() const noexcept {
    return remote_first_parameter_ms_;
  }
  [[nodiscard]] constexpr std::uint32_t
  remote_request_started_ms() const noexcept {
    return remote_request_started_ms_;
  }
  [[nodiscard]] constexpr std::uint32_t
  remote_transfer_elapsed_ms() const noexcept {
    return remote_transfer_elapsed_ms_;
  }
  [[nodiscard]] constexpr std::uint64_t receiver_revision() const noexcept {
    return receiver_revision_;
  }

 private:
  friend class RemoteDeliveryLedger;
  friend class RemoteHeartbeatSlaLedger;
  friend class NativeBulkDownlink;
  constexpr ParameterStreamDeliveryProof(
      TransferToken final_token, std::uint64_t stream_id,
      std::uint64_t lease_id, std::uint64_t parameter_count,
      std::uint64_t chunk_count, std::uint64_t wire_bytes,
      std::uint32_t remote_request_started_ms,
      std::uint32_t remote_first_parameter_ms,
      std::uint32_t remote_observed_at_ms,
      std::uint64_t receiver_revision,
      const RemoteDeliveryLedger* issuer) noexcept
      : final_token_(final_token),
        stream_id_(stream_id),
        lease_id_(lease_id),
        parameter_count_(parameter_count),
        chunk_count_(chunk_count),
        wire_bytes_(wire_bytes),
        remote_request_started_ms_(remote_request_started_ms),
        remote_first_parameter_ms_(remote_first_parameter_ms),
        remote_observed_at_ms_(remote_observed_at_ms),
        remote_transfer_elapsed_ms_(
            elapsed_ms(remote_observed_at_ms, remote_request_started_ms)),
        receiver_revision_(receiver_revision),
        issuer_(issuer),
        valid_(final_token.valid() &&
               final_token.direction() == Direction::Downlink &&
               stream_id != 0U && lease_id != 0U &&
               parameter_count == 932U && chunk_count == 1864U &&
               wire_bytes == 59648U && receiver_revision != 0U &&
               issuer != nullptr) {}

  TransferToken final_token_{};
  std::uint64_t stream_id_ = 0U;
  std::uint64_t lease_id_ = 0U;
  std::uint64_t parameter_count_ = 0U;
  std::uint64_t chunk_count_ = 0U;
  std::uint64_t wire_bytes_ = 0U;
  std::uint32_t remote_request_started_ms_ = 0U;
  std::uint32_t remote_first_parameter_ms_ = 0U;
  std::uint32_t remote_observed_at_ms_ = 0U;
  std::uint32_t remote_transfer_elapsed_ms_ = 0U;
  std::uint64_t receiver_revision_ = 0U;
  const RemoteDeliveryLedger* issuer_ = nullptr;
  bool valid_ = false;
};

// Opaque terminal summary produced exclusively from the Ground receiver's
// monotonic clock.  It proves the first/gap/post heartbeat SLA for one
// session/stream/lease without requiring any midstream reverse-direction ACK.
class RemoteHeartbeatSlaProof {
 public:
  constexpr RemoteHeartbeatSlaProof() noexcept = default;
  [[nodiscard]] constexpr bool valid() const noexcept { return valid_; }
  [[nodiscard]] constexpr std::uint64_t session_id() const noexcept {
    return session_id_;
  }
  [[nodiscard]] constexpr std::uint64_t stream_id() const noexcept {
    return stream_id_;
  }
  [[nodiscard]] constexpr std::uint64_t lease_id() const noexcept {
    return lease_id_;
  }
  [[nodiscard]] constexpr std::uint32_t heartbeat_count() const noexcept {
    return heartbeat_count_;
  }
  [[nodiscard]] constexpr std::uint32_t last_request_id() const noexcept {
    return last_request_id_;
  }
  [[nodiscard]] constexpr std::uint32_t max_gap_ms() const noexcept {
    return max_gap_ms_;
  }
  [[nodiscard]] constexpr std::uint32_t first_gap_ms() const noexcept {
    return first_gap_ms_;
  }
  [[nodiscard]] constexpr std::uint32_t post_gap_ms() const noexcept {
    return post_gap_ms_;
  }

 private:
  friend class RemoteHeartbeatSlaLedger;
  friend class NativeBulkDownlink;
  constexpr RemoteHeartbeatSlaProof(
      std::uint64_t session_id, std::uint64_t stream_id,
      std::uint64_t lease_id, std::uint32_t heartbeat_count,
      std::uint32_t last_request_id, std::uint32_t first_gap_ms,
      std::uint32_t max_gap_ms, std::uint32_t post_gap_ms,
      const RemoteDeliveryLedger* parameter_issuer,
      std::uint64_t parameter_receiver_revision,
      TransferToken final_parameter_token,
      std::uint32_t final_parameter_observed_at_ms,
      std::uint64_t receiver_revision,
      const RemoteHeartbeatSlaLedger* issuer) noexcept
      : session_id_(session_id),
        stream_id_(stream_id),
        lease_id_(lease_id),
        heartbeat_count_(heartbeat_count),
        last_request_id_(last_request_id),
        first_gap_ms_(first_gap_ms),
        max_gap_ms_(max_gap_ms),
        post_gap_ms_(post_gap_ms),
        parameter_issuer_(parameter_issuer),
        parameter_receiver_revision_(parameter_receiver_revision),
        final_parameter_token_(final_parameter_token),
        final_parameter_observed_at_ms_(final_parameter_observed_at_ms),
        receiver_revision_(receiver_revision),
        issuer_(issuer),
        valid_(session_id != 0U && stream_id != 0U && lease_id != 0U &&
               heartbeat_count != 0U && last_request_id == heartbeat_count &&
               parameter_issuer != nullptr &&
               parameter_receiver_revision != 0U &&
               final_parameter_token.valid() &&
               receiver_revision != 0U && issuer != nullptr) {}

  std::uint64_t session_id_ = 0U;
  std::uint64_t stream_id_ = 0U;
  std::uint64_t lease_id_ = 0U;
  std::uint32_t heartbeat_count_ = 0U;
  std::uint32_t last_request_id_ = 0U;
  std::uint32_t first_gap_ms_ = 0U;
  std::uint32_t max_gap_ms_ = 0U;
  std::uint32_t post_gap_ms_ = 0U;
  const RemoteDeliveryLedger* parameter_issuer_ = nullptr;
  std::uint64_t parameter_receiver_revision_ = 0U;
  TransferToken final_parameter_token_{};
  std::uint32_t final_parameter_observed_at_ms_ = 0U;
  std::uint64_t receiver_revision_ = 0U;
  const RemoteHeartbeatSlaLedger* issuer_ = nullptr;
  bool valid_ = false;
};

class ReceiverEvidencePollEpoch {
 public:
  constexpr ReceiverEvidencePollEpoch() noexcept = default;
  [[nodiscard]] constexpr bool valid() const noexcept { return valid_; }
  [[nodiscard]] constexpr std::uint32_t
  receiver_events_drained_through_ms() const noexcept {
    return receiver_events_drained_through_ms_;
  }
  [[nodiscard]] constexpr bool heartbeat_delivery_applied() const noexcept {
    return heartbeat_delivery_applied_;
  }
  [[nodiscard]] constexpr bool
  final_parameter_delivery_applied() const noexcept {
    return final_parameter_delivery_applied_;
  }
  [[nodiscard]] constexpr bool heartbeat_sla_applied() const noexcept {
    return heartbeat_sla_applied_;
  }

 private:
  friend class NativeBulkDownlink;
  constexpr ReceiverEvidencePollEpoch(
      std::uint64_t session_id, std::uint64_t stream_id,
      std::uint64_t lease_id,
      std::uint32_t sequence, std::uint32_t drained_through_ms,
      bool heartbeat_delivery_applied,
      bool final_parameter_delivery_applied,
      bool heartbeat_sla_applied) noexcept
      : session_id_(session_id),
        stream_id_(stream_id),
        lease_id_(lease_id),
        sequence_(sequence),
        receiver_events_drained_through_ms_(drained_through_ms),
        heartbeat_delivery_applied_(heartbeat_delivery_applied),
        final_parameter_delivery_applied_(final_parameter_delivery_applied),
        heartbeat_sla_applied_(heartbeat_sla_applied),
        valid_(session_id != 0U && stream_id != 0U && lease_id != 0U &&
               sequence != 0U) {}

  std::uint64_t session_id_ = 0U;
  std::uint64_t stream_id_ = 0U;
  std::uint64_t lease_id_ = 0U;
  std::uint32_t sequence_ = 0U;
  std::uint32_t receiver_events_drained_through_ms_ = 0U;
  bool heartbeat_delivery_applied_ = false;
  bool final_parameter_delivery_applied_ = false;
  bool heartbeat_sla_applied_ = false;
  bool valid_ = false;
};

class ProgressProof {
 public:
  constexpr ProgressProof() noexcept = default;
  [[nodiscard]] constexpr const TransferToken& token() const noexcept {
    return token_;
  }
  [[nodiscard]] constexpr EvidenceSource source() const noexcept {
    return source_;
  }
  [[nodiscard]] constexpr bool valid() const noexcept { return valid_; }

 private:
  friend class E220DirectionDrainFence;
  constexpr ProgressProof(TransferToken token, EvidenceSource source) noexcept
      : token_(token), source_(source), valid_(true) {}

  TransferToken token_{};
  EvidenceSource source_ = EvidenceSource::RemoteArrival;
  bool valid_ = false;
};

class DrainProof {
 public:
  constexpr DrainProof() noexcept = default;
  [[nodiscard]] constexpr const TransferToken& token() const noexcept {
    return token_;
  }
  [[nodiscard]] constexpr EvidenceSource source() const noexcept {
    return source_;
  }
  [[nodiscard]] constexpr std::uint32_t observed_at_ms() const noexcept {
    return observed_at_ms_;
  }
  [[nodiscard]] constexpr bool valid() const noexcept { return valid_; }

 private:
  friend class E220DirectionDrainFence;
  constexpr DrainProof(TransferToken token, EvidenceSource source,
                       std::uint32_t observed_at_ms) noexcept
      : token_(token),
        source_(source),
        observed_at_ms_(observed_at_ms),
        valid_(true) {}

  TransferToken token_{};
  EvidenceSource source_ = EvidenceSource::RemoteArrival;
  std::uint32_t observed_at_ms_ = 0U;
  bool valid_ = false;
};

enum class AdmissionResult : std::uint8_t {
  Ready,
  InvalidLength,
  Oversize,
  InvalidDirection,
  DirectionMismatch,
  AuxLow,
  AuxNotStable,
  GapActive,
  Backpressure,
  Quarantined,
  WriteFaultLatched,
  InvalidSession,
  CounterOverflow
};

enum class WriteCommitResult : std::uint8_t {
  Committed,
  NoProgress,
  PartialWriteFault,
  UnadmittedWriteFault,
  CounterOverflowFault
};

struct WriteCommitOutcome {
  WriteCommitResult result = WriteCommitResult::NoProgress;
  TransferToken token{};
};

struct HeartbeatWriteCommitOutcome {
  WriteCommitOutcome write{};
  HeartbeatTailWatermark watermark{};
};

struct ParameterFrameWriteCommitOutcome {
  WriteCommitOutcome write{};
  ParameterChunkWatermark chunk_watermark{};
  ParameterFrameTailWatermark frame_watermark{};
  FinalParameterTailWatermark final_watermark{};
};

class E220UartAdmissionGate {
 public:
  static inline constexpr std::size_t max_chunk_bytes =
      HighSpeedCandidateContract::radio_chunk_bytes;
  static inline constexpr std::size_t max_buffered_bytes =
      HighSpeedCandidateContract::documented_internal_buffer_bytes;
  static inline constexpr std::uint32_t minimum_gap_ms =
      HighSpeedCandidateContract::candidate_uart_write_gap_ms;
  static inline constexpr std::uint32_t aux_stable_ms =
      HighSpeedCandidateContract::aux_high_stable_ms;

  explicit constexpr E220UartAdmissionGate(
      std::uint64_t session_id,
      std::uint64_t initial_accepted_wire_bytes = 0U,
      std::uint32_t initial_generation = 0U) noexcept
      : accepted_wire_bytes_(initial_accepted_wire_bytes),
        generation_(initial_generation),
        session_id_(session_id),
        session_fault_latched_(session_id == 0U) {}

  void observe_aux(std::uint32_t now, bool high) noexcept {
    if (high) {
      if (!aux_high_) {
        aux_high_ = true;
        aux_high_since_ms_ = now;
        if (local_release_low_seen_since_accept_) {
          local_release_high_after_low_ = true;
          local_release_edge_tail_ =
              next_generation_byte_ == 0U ? 0U : next_generation_byte_ - 1U;
        }
      }
      // A newly sampled HIGH after an accepted write is independent evidence
      // that the E220's documented 400-byte UART buffer has accepted its
      // contents into the wireless side.  Keep this observation separate from
      // LOW -> HIGH evidence: once LOW has been seen, only the stable edge path
      // below may return credit for that accepted tail.
      if (direction_locked_ && has_committed_write_ && buffered_bytes_ != 0U &&
          !local_release_low_seen_since_accept_) {
        local_release_continuous_high_observed_since_accept_ = true;
        local_release_continuous_high_observed_at_ms_ = now;
      }
      return;
    }
    aux_high_ = false;
    pending_ = false;
    if (direction_locked_ && buffered_bytes_ != 0U) {
      local_release_low_seen_since_accept_ = true;
      local_release_high_after_low_ = false;
      local_release_continuous_high_observed_since_accept_ = false;
    }
  }

  AdmissionResult assess(std::uint32_t now, Direction direction,
                         std::size_t bytes) noexcept {
    pending_ = false;
    if (session_fault_latched_) {
      return AdmissionResult::InvalidSession;
    }
    if (counter_fault_latched_) {
      return AdmissionResult::CounterOverflow;
    }
    if (quarantined_) {
      return AdmissionResult::Quarantined;
    }
    if (write_fault_latched_) {
      return AdmissionResult::WriteFaultLatched;
    }
    if (bytes == 0U) {
      return AdmissionResult::InvalidLength;
    }
    if (bytes > max_chunk_bytes) {
      return AdmissionResult::Oversize;
    }
    if (direction == Direction::Mixed) {
      return AdmissionResult::InvalidDirection;
    }
    if (!direction_locked_ &&
        generation_ == std::numeric_limits<std::uint32_t>::max()) {
      counter_fault_latched_ = true;
      return AdmissionResult::CounterOverflow;
    }
    if (direction_locked_ && direction != locked_direction_) {
      return AdmissionResult::DirectionMismatch;
    }
    if (!aux_high_) {
      return AdmissionResult::AuxLow;
    }
    if (elapsed_ms(now, aux_high_since_ms_) < aux_stable_ms) {
      return AdmissionResult::AuxNotStable;
    }
    if (has_committed_write_ &&
        elapsed_ms(now, last_commit_ms_) < minimum_gap_ms) {
      return AdmissionResult::GapActive;
    }
    if (buffered_bytes_ > max_buffered_bytes - bytes) {
      return AdmissionResult::Backpressure;
    }

    pending_ = true;
    pending_direction_ = direction;
    pending_bytes_ = bytes;
    return AdmissionResult::Ready;
  }

  WriteCommitOutcome commit_write(std::uint32_t now, Direction direction,
                                  std::size_t requested,
                                  std::size_t written) noexcept {
    if ((parameter_stream_active_ ||
         heartbeat_transaction_active_) &&
        !semantic_commit_in_progress_) {
      return reject_semantic_write(direction, written);
    }
    if (written == 0U) {
      pending_ = false;
      return WriteCommitOutcome{WriteCommitResult::NoProgress, {}};
    }

    if (!pending_ || direction != pending_direction_ ||
        requested != pending_bytes_) {
      pending_ = false;
      return WriteCommitOutcome{WriteCommitResult::UnadmittedWriteFault,
                                enter_quarantine(direction, false)};
    }
    pending_ = false;

    if (written != requested) {
      return WriteCommitOutcome{WriteCommitResult::PartialWriteFault,
                                enter_quarantine(direction, false)};
    }

    const std::uint64_t requested_u64 =
        static_cast<std::uint64_t>(requested);
    if (accepted_wire_bytes_ >
            std::numeric_limits<std::uint64_t>::max() - requested_u64 ||
        (direction_locked_ &&
         next_generation_byte_ >
             std::numeric_limits<std::uint64_t>::max() - requested_u64)) {
      counter_fault_latched_ = true;
      return WriteCommitOutcome{WriteCommitResult::CounterOverflowFault,
                                enter_quarantine(direction, true)};
    }

    if (!direction_locked_) {
      ++generation_;
      locked_direction_ = direction;
      direction_locked_ = true;
      next_generation_byte_ = 0U;
      has_credited_tail_ = false;
    }
    const std::uint64_t tail = next_generation_byte_ + requested_u64 - 1U;
    next_generation_byte_ += requested_u64;
    buffered_bytes_ += requested;
    accepted_wire_bytes_ += requested_u64;
    has_committed_write_ = true;
    last_commit_ms_ = now;
    // Local E220 buffer-release evidence must be newer than this accepted
    // tail.  A LOW/HIGH edge or continuously sampled HIGH cached from an
    // earlier write is never reusable.
    local_release_low_seen_since_accept_ = false;
    local_release_high_after_low_ = false;
    local_release_continuous_high_observed_since_accept_ = false;
    return WriteCommitOutcome{
        WriteCommitResult::Committed,
        TransferToken(session_id_, generation_, locked_direction_, tail,
                      true)};
  }

  HeartbeatWriteCommitOutcome commit_heartbeat_chunk(
      std::uint32_t now, Direction direction, std::size_t requested,
      std::size_t written, std::size_t chunk_ordinal,
      const HeartbeatTailPermit& permit) noexcept {
    if (!permit.valid() || permit.session_id() != session_id_ ||
        direction != Direction::Downlink ||
        requested != HighSpeedCandidateContract::radio_chunk_bytes ||
        parameter_next_chunk_ordinal_ != 0U ||
        (parameter_stream_active_ &&
         (permit.stream_id() != parameter_stream_id_ ||
          permit.lease_id() != parameter_lease_id_)) ||
        !heartbeat_transaction_matches_or_starts(permit, chunk_ordinal)) {
      return HeartbeatWriteCommitOutcome{
          reject_semantic_write(direction, written), {}};
    }
    semantic_commit_in_progress_ = true;
    const WriteCommitOutcome write =
        commit_write(now, direction, requested, written);
    semantic_commit_in_progress_ = false;
    if (write.result != WriteCommitResult::Committed) {
      if (write.result != WriteCommitResult::NoProgress) {
        heartbeat_transaction_active_ = false;
      }
      return HeartbeatWriteCommitOutcome{write, {}};
    }
    heartbeat_transaction_bytes_ += requested;
    ++heartbeat_next_chunk_ordinal_;
    if (heartbeat_next_chunk_ordinal_ !=
            HighSpeedCandidateContract::heartbeat_wire_chunks_per_frame ||
        heartbeat_transaction_bytes_ !=
            HighSpeedCandidateContract::heartbeat_wire_bytes_per_frame) {
      return HeartbeatWriteCommitOutcome{write, {}};
    }
    heartbeat_transaction_active_ = false;
    has_last_heartbeat_permit_ = true;
    last_heartbeat_stream_id_ = permit.stream_id();
    last_heartbeat_lease_id_ = permit.lease_id();
    last_heartbeat_request_id_ = permit.request_id();
    return HeartbeatWriteCommitOutcome{
        write, HeartbeatTailWatermark(write.token, permit.stream_id(),
                                      permit.lease_id(),
                                      permit.request_id())};
  }

  ParameterFrameWriteCommitOutcome commit_parameter_chunk(
      std::uint32_t now, Direction direction, std::size_t requested,
      std::size_t written, std::size_t chunk_ordinal,
      const ParameterFramePermit& permit) noexcept {
    if (!permit.valid() || permit.session_id() != session_id_ ||
        direction != Direction::Downlink ||
        requested != HighSpeedCandidateContract::radio_chunk_bytes ||
        heartbeat_transaction_active_ ||
        !parameter_transaction_matches_or_starts(permit, chunk_ordinal)) {
      return ParameterFrameWriteCommitOutcome{
          reject_semantic_write(direction, written), {}, {}, {}};
    }
    semantic_commit_in_progress_ = true;
    const WriteCommitOutcome write =
        commit_write(now, direction, requested, written);
    semantic_commit_in_progress_ = false;
    if (write.result != WriteCommitResult::Committed) {
      if (write.result != WriteCommitResult::NoProgress) {
        parameter_stream_active_ = false;
      }
      return ParameterFrameWriteCommitOutcome{write, {}, {}, {}};
    }
    parameter_stream_bytes_ += requested;
    ++parameter_stream_chunks_;
    ++parameter_next_chunk_ordinal_;
    const ParameterChunkWatermark chunk_watermark(
        write.token, permit.stream_id(), permit.lease_id(),
        permit.parameter_index(), static_cast<std::uint8_t>(chunk_ordinal),
        parameter_stream_chunks_ - 1U);
    if (parameter_next_chunk_ordinal_ !=
            HighSpeedCandidateContract::param_value_wire_chunks_per_frame ||
        parameter_stream_bytes_ !=
            (static_cast<std::uint64_t>(parameter_expected_index_) + 1U) *
                HighSpeedCandidateContract::param_value_wire_bytes_per_frame) {
      return ParameterFrameWriteCommitOutcome{write, chunk_watermark, {}, {}};
    }
    const ParameterFrameTailWatermark frame_watermark(
        write.token, permit.stream_id(), permit.lease_id(),
        permit.parameter_index());
    parameter_next_chunk_ordinal_ = 0U;
    ++parameter_expected_index_;
    if (parameter_expected_index_ !=
        HighSpeedCandidateContract::expected_parameter_count) {
      return ParameterFrameWriteCommitOutcome{
          write, chunk_watermark, frame_watermark, {}};
    }
    if (parameter_stream_chunks_ !=
            HighSpeedCandidateContract::expected_parameter_wire_chunks ||
        parameter_stream_bytes_ !=
            HighSpeedCandidateContract::expected_parameter_wire_bytes) {
      return ParameterFrameWriteCommitOutcome{
          WriteCommitOutcome{WriteCommitResult::CounterOverflowFault,
                             write.token},
          {}, {}, {}};
    }
    parameter_stream_active_ = false;
    has_last_parameter_stream_ = true;
    last_parameter_stream_id_ = permit.stream_id();
    last_parameter_lease_id_ = permit.lease_id();
    return ParameterFrameWriteCommitOutcome{
        write, chunk_watermark, frame_watermark,
        FinalParameterTailWatermark(write.token, permit.stream_id(),
                                    permit.lease_id(),
                                    permit.parameter_index())};
  }

  bool apply_progress(const ProgressProof& proof) noexcept {
    const TransferToken& token = proof.token();
    if (!proof.valid() || !token.valid() || !token.tail_known() ||
        quarantined_ || !direction_locked_ ||
        token.session_id() != session_id_ ||
        token.generation() != generation_ ||
        token.direction() != locked_direction_ ||
        token.tail() >= next_generation_byte_ ||
        proof.source() != EvidenceSource::ExplicitTxComplete) {
      return false;
    }
    if (has_credited_tail_ && token.tail() <= credited_tail_) {
      return false;
    }
    const std::uint64_t released_u64 =
        has_credited_tail_ ? token.tail() - credited_tail_ : token.tail() + 1U;
    if (released_u64 > static_cast<std::uint64_t>(buffered_bytes_)) {
      return false;
    }
    buffered_bytes_ -= static_cast<std::size_t>(released_u64);
    credited_tail_ = token.tail();
    has_credited_tail_ = true;
    return true;
  }

  // ACK-less local buffer credit is intentionally independent from receiver
  // progress.  E220 AUX HIGH documents that the internal 400-byte UART buffer
  // is empty / handed into the wireless side, but explicitly does not prove
  // that the last packet finished RF transmission.  Credit can therefore come
  // from either (a) a fresh continuously sampled HIGH at least one candidate
  // write gap after the accepted tail, provided no LOW was observed since that
  // accept, or (b) the existing fresh LOW -> HIGH transition with HIGH stable
  // for the configured interval.  Both paths are buffer-handoff evidence only:
  // they never make a DrainProof, unlock direction, or prove RF arrival/tail.
  bool release_buffer_credit_from_local_aux(
      std::uint32_t now, const TransferToken& token) noexcept {
    if (!token.valid() || !token.tail_known() || quarantined_ ||
        !direction_locked_ || !aux_high_ || !has_committed_write_ ||
        token.session_id() != session_id_ ||
        token.generation() != generation_ ||
        token.direction() != locked_direction_ ||
        token.tail() >= next_generation_byte_ ||
        (has_credited_tail_ && token.tail() <= credited_tail_)) {
      return false;
    }

    const bool stable_low_high_edge =
        local_release_low_seen_since_accept_ &&
        local_release_high_after_low_ &&
        elapsed_ms(now, aux_high_since_ms_) >= aux_stable_ms &&
        token.tail() == local_release_edge_tail_;
    const bool fresh_continuous_high =
        !local_release_low_seen_since_accept_ &&
        local_release_continuous_high_observed_since_accept_ &&
        local_release_continuous_high_observed_at_ms_ == now &&
        elapsed_ms(now, last_commit_ms_) >= minimum_gap_ms &&
        token.tail() == next_generation_byte_ - 1U;
    if (!stable_low_high_edge && !fresh_continuous_high) {
      return false;
    }

    const std::uint64_t released_u64 =
        has_credited_tail_ ? token.tail() - credited_tail_ : token.tail() + 1U;
    if (released_u64 > static_cast<std::uint64_t>(buffered_bytes_)) {
      return false;
    }
    buffered_bytes_ -= static_cast<std::size_t>(released_u64);
    credited_tail_ = token.tail();
    has_credited_tail_ = true;
    local_release_low_seen_since_accept_ = false;
    local_release_high_after_low_ = false;
    local_release_continuous_high_observed_since_accept_ = false;
    return true;
  }

  bool unlock_direction(const DrainProof& proof) noexcept {
    const TransferToken& token = proof.token();
    if (!direction_locked_ || !proof.valid() || !token.valid() ||
        token.session_id() != session_id_ ||
        token.generation() != generation_ ||
        token.direction() != locked_direction_) {
      return false;
    }

    if (quarantined_) {
      if (token.tail_known() ||
          proof.source() != EvidenceSource::ExplicitQuarantineDrain) {
        return false;
      }
    } else {
      if (!token.tail_known() || next_generation_byte_ == 0U ||
          token.tail() != next_generation_byte_ - 1U ||
          (proof.source() != EvidenceSource::RemoteArrival &&
           proof.source() != EvidenceSource::ExplicitTxComplete)) {
        return false;
      }
    }

    buffered_bytes_ = 0U;
    direction_locked_ = false;
    quarantined_ = false;
    has_committed_write_ = false;
    has_credited_tail_ = false;
    local_release_low_seen_since_accept_ = false;
    local_release_high_after_low_ = false;
    local_release_continuous_high_observed_since_accept_ = false;
    next_generation_byte_ = 0U;
    pending_ = false;
    return true;
  }

  [[nodiscard]] std::size_t buffered_bytes() const noexcept {
    return buffered_bytes_;
  }
  [[nodiscard]] std::uint64_t accepted_wire_bytes() const noexcept {
    return accepted_wire_bytes_;
  }
  [[nodiscard]] bool direction_locked() const noexcept {
    return direction_locked_;
  }
  [[nodiscard]] bool quarantined() const noexcept { return quarantined_; }
  [[nodiscard]] bool write_fault_latched() const noexcept {
    return write_fault_latched_;
  }
  [[nodiscard]] bool counter_fault_latched() const noexcept {
    return counter_fault_latched_;
  }
  [[nodiscard]] bool session_fault_latched() const noexcept {
    return session_fault_latched_;
  }

 private:
  [[nodiscard]] bool heartbeat_transaction_matches_or_starts(
      const HeartbeatTailPermit& permit,
      std::size_t chunk_ordinal) noexcept {
    if (heartbeat_transaction_active_) {
      return permit.stream_id() == heartbeat_transaction_stream_id_ &&
             permit.lease_id() == heartbeat_transaction_lease_id_ &&
             permit.request_id() == heartbeat_transaction_request_id_ &&
             chunk_ordinal == heartbeat_next_chunk_ordinal_;
    }
    const bool newer_than_consumed =
        !has_last_heartbeat_permit_ ||
        permit.stream_id() > last_heartbeat_stream_id_ ||
        (permit.stream_id() == last_heartbeat_stream_id_ &&
         permit.lease_id() == last_heartbeat_lease_id_ &&
         permit.request_id() > last_heartbeat_request_id_);
    if (!newer_than_consumed || chunk_ordinal != 0U) {
      return false;
    }
    heartbeat_transaction_active_ = true;
    heartbeat_transaction_stream_id_ = permit.stream_id();
    heartbeat_transaction_lease_id_ = permit.lease_id();
    heartbeat_transaction_request_id_ = permit.request_id();
    heartbeat_next_chunk_ordinal_ = 0U;
    heartbeat_transaction_bytes_ = 0U;
    return true;
  }

  [[nodiscard]] bool parameter_transaction_matches_or_starts(
      const ParameterFramePermit& permit,
      std::size_t chunk_ordinal) noexcept {
    if (parameter_stream_active_) {
      return permit.stream_id() == parameter_stream_id_ &&
             permit.lease_id() == parameter_lease_id_ &&
             permit.parameter_index() == parameter_expected_index_ &&
             chunk_ordinal == parameter_next_chunk_ordinal_;
    }
    if ((has_last_parameter_stream_ &&
         permit.stream_id() <= last_parameter_stream_id_) ||
        permit.parameter_index() != 0U || chunk_ordinal != 0U) {
      return false;
    }
    parameter_stream_active_ = true;
    parameter_stream_id_ = permit.stream_id();
    parameter_lease_id_ = permit.lease_id();
    parameter_expected_index_ = 0U;
    parameter_next_chunk_ordinal_ = 0U;
    parameter_stream_chunks_ = 0U;
    parameter_stream_bytes_ = 0U;
    return true;
  }

  WriteCommitOutcome reject_semantic_write(Direction attempted_direction,
                                            std::size_t written) noexcept {
    pending_ = false;
    if (written == 0U) {
      return WriteCommitOutcome{WriteCommitResult::NoProgress, {}};
    }
    return WriteCommitOutcome{WriteCommitResult::UnadmittedWriteFault,
                              enter_quarantine(attempted_direction, false)};
  }

  TransferToken enter_quarantine(Direction attempted_direction,
                                 bool counter_fault) noexcept {
    if (!direction_locked_) {
      if (generation_ != std::numeric_limits<std::uint32_t>::max()) {
        ++generation_;
      } else {
        counter_fault_latched_ = true;
      }
      locked_direction_ = attempted_direction;
      direction_locked_ = true;
      next_generation_byte_ = 0U;
    } else if (locked_direction_ != attempted_direction) {
      locked_direction_ = Direction::Mixed;
    }
    quarantined_ = true;
    write_fault_latched_ = true;
    counter_fault_latched_ = counter_fault_latched_ || counter_fault;
    buffered_bytes_ = max_buffered_bytes;
    has_credited_tail_ = false;
    return TransferToken(session_id_, generation_, locked_direction_, 0U,
                         false);
  }

  bool aux_high_ = false;
  std::uint32_t aux_high_since_ms_ = 0U;
  bool pending_ = false;
  Direction pending_direction_ = Direction::Downlink;
  std::size_t pending_bytes_ = 0U;
  bool direction_locked_ = false;
  Direction locked_direction_ = Direction::Downlink;
  bool has_committed_write_ = false;
  std::uint32_t last_commit_ms_ = 0U;
  std::size_t buffered_bytes_ = 0U;
  std::uint64_t accepted_wire_bytes_ = 0U;
  std::uint32_t generation_ = 0U;
  std::uint64_t session_id_ = 0U;
  std::uint64_t next_generation_byte_ = 0U;
  bool has_credited_tail_ = false;
  std::uint64_t credited_tail_ = 0U;
  bool local_release_low_seen_since_accept_ = false;
  bool local_release_high_after_low_ = false;
  std::uint64_t local_release_edge_tail_ = 0U;
  bool local_release_continuous_high_observed_since_accept_ = false;
  std::uint32_t local_release_continuous_high_observed_at_ms_ = 0U;
  bool quarantined_ = false;
  bool write_fault_latched_ = false;
  bool counter_fault_latched_ = false;
  bool session_fault_latched_ = false;
  bool semantic_commit_in_progress_ = false;
  bool heartbeat_transaction_active_ = false;
  std::uint64_t heartbeat_transaction_stream_id_ = 0U;
  std::uint64_t heartbeat_transaction_lease_id_ = 0U;
  std::uint32_t heartbeat_transaction_request_id_ = 0U;
  std::size_t heartbeat_next_chunk_ordinal_ = 0U;
  std::size_t heartbeat_transaction_bytes_ = 0U;
  bool has_last_heartbeat_permit_ = false;
  std::uint64_t last_heartbeat_stream_id_ = 0U;
  std::uint64_t last_heartbeat_lease_id_ = 0U;
  std::uint32_t last_heartbeat_request_id_ = 0U;
  bool parameter_stream_active_ = false;
  std::uint64_t parameter_stream_id_ = 0U;
  std::uint64_t parameter_lease_id_ = 0U;
  std::uint16_t parameter_expected_index_ = 0U;
  std::size_t parameter_next_chunk_ordinal_ = 0U;
  std::uint64_t parameter_stream_chunks_ = 0U;
  std::uint64_t parameter_stream_bytes_ = 0U;
  bool has_last_parameter_stream_ = false;
  std::uint64_t last_parameter_stream_id_ = 0U;
  std::uint64_t last_parameter_lease_id_ = 0U;
};

class E220DirectionDrainFence {
 public:
  bool record_accepted(const TransferToken& token) noexcept {
    if (!token.valid() || !token.tail_known() || token.session_id() == 0U ||
        token.direction() == Direction::Mixed || token.generation() == 0U ||
        unknown_tail_pending_ ||
        (has_accepted_tail_ &&
         (token.session_id() != session_id_ ||
          token.generation() != generation_ ||
          token.direction() != direction_ ||
          token.tail() <= last_accepted_tail_))) {
      accounting_fault_ = true;
      return false;
    }
    session_id_ = token.session_id();
    generation_ = token.generation();
    direction_ = token.direction();
    has_accepted_tail_ = true;
    last_accepted_tail_ = token.tail();
    clear_completion_for_new_accept();
    return true;
  }

  bool record_unknown_accepted(const TransferToken& token) noexcept {
    if (!token.valid() || token.tail_known() || token.session_id() == 0U ||
        token.generation() == 0U) {
      accounting_fault_ = true;
      return false;
    }
    session_id_ = token.session_id();
    generation_ = token.generation();
    direction_ = token.direction();
    has_accepted_tail_ = false;
    unknown_tail_pending_ = true;
    unknown_token_ = token;
    clear_completion_for_new_accept();
    return true;
  }

  void observe_local_radio_status(bool tx_empty, bool tx_complete,
                                  bool aux_high) noexcept {
    radio_tx_empty_ = tx_empty;
    aux_high_ = aux_high;
    if (!tx_complete) {
      completion_low_seen_since_accept_ = true;
      radio_tx_complete_ = false;
    } else {
      // A HIGH level is fresh only after LOW was observed for this accepted
      // tail. A level inherited from an earlier transfer is not reusable.
      radio_tx_complete_ = completion_low_seen_since_accept_;
    }
  }

  std::optional<ProgressProof> observe_remote_progress(
      const TransferToken& token) noexcept {
    if (!matches_known_transfer(token) ||
        token.tail() > last_accepted_tail_ ||
        (has_progress_tail_ && token.tail() <= progress_tail_)) {
      return std::nullopt;
    }
    progress_tail_ = token.tail();
    has_progress_tail_ = true;
    return ProgressProof(token, EvidenceSource::RemoteArrival);
  }

  std::optional<DrainProof> observe_remote_tail(
      const TransferToken& token, std::uint32_t observed_at_ms) noexcept {
    if (!matches_final_known_tail(token) || drain_proof_issued_) {
      return std::nullopt;
    }
    drain_proof_issued_ = true;
    issued_drain_proof_ =
        DrainProof(token, EvidenceSource::RemoteArrival, observed_at_ms);
    return issued_drain_proof_;
  }

  std::optional<DrainProof> observe_explicit_tail(
      const TransferToken& token, std::uint32_t observed_at_ms) noexcept {
    if (!radio_tx_complete_ || !matches_final_known_tail(token) ||
        drain_proof_issued_) {
      return std::nullopt;
    }
    drain_proof_issued_ = true;
    issued_drain_proof_ =
        DrainProof(token, EvidenceSource::ExplicitTxComplete,
                   observed_at_ms);
    return issued_drain_proof_;
  }

  std::optional<DrainProof> observe_explicit_quarantine_drain(
      const TransferToken& token, std::uint32_t observed_at_ms) noexcept {
    if (!radio_tx_complete_ || !unknown_tail_pending_ ||
        drain_proof_issued_ || token != unknown_token_) {
      return std::nullopt;
    }
    drain_proof_issued_ = true;
    issued_drain_proof_ =
        DrainProof(token, EvidenceSource::ExplicitQuarantineDrain,
                   observed_at_ms);
    return issued_drain_proof_;
  }

  bool commit_direction_change(const DrainProof& proof,
                               Direction next_direction) noexcept {
    if (!direction_drained() || next_direction == Direction::Mixed ||
        next_direction == direction_ || !same_proof(proof, issued_drain_proof_)) {
      return false;
    }
    direction_ = next_direction;
    has_accepted_tail_ = false;
    unknown_tail_pending_ = false;
    unknown_token_ = {};
    has_progress_tail_ = false;
    progress_tail_ = 0U;
    drain_proof_issued_ = false;
    issued_drain_proof_ = {};
    radio_tx_empty_ = false;
    radio_tx_complete_ = false;
    completion_low_seen_since_accept_ = false;
    aux_high_ = false;
    return true;
  }

  [[nodiscard]] bool direction_drained() const noexcept {
    return drain_proof_issued_ && !accounting_fault_ &&
           (has_accepted_tail_ || unknown_tail_pending_);
  }
  [[nodiscard]] bool can_begin(Direction direction) const noexcept {
    if (!has_accepted_tail_ && !unknown_tail_pending_) {
      return !accounting_fault_;
    }
    return direction == direction_ || direction_drained();
  }
  [[nodiscard]] bool radio_tx_empty() const noexcept {
    return radio_tx_empty_;
  }
  [[nodiscard]] bool radio_tx_complete() const noexcept {
    return radio_tx_complete_;
  }
  [[nodiscard]] bool aux_high() const noexcept { return aux_high_; }
  [[nodiscard]] bool accounting_fault() const noexcept {
    return accounting_fault_;
  }

 private:
  void clear_completion_for_new_accept() noexcept {
    radio_tx_empty_ = false;
    radio_tx_complete_ = false;
    completion_low_seen_since_accept_ = false;
    drain_proof_issued_ = false;
    issued_drain_proof_ = {};
  }

  [[nodiscard]] static bool same_proof(const DrainProof& lhs,
                                       const DrainProof& rhs) noexcept {
    return lhs.valid() && rhs.valid() && lhs.token() == rhs.token() &&
           lhs.source() == rhs.source() &&
           lhs.observed_at_ms() == rhs.observed_at_ms();
  }

  [[nodiscard]] bool matches_known_transfer(
      const TransferToken& token) const noexcept {
    return token.valid() && token.tail_known() && has_accepted_tail_ &&
           !unknown_tail_pending_ && !accounting_fault_ &&
           token.session_id() == session_id_ &&
           token.generation() == generation_ &&
           token.direction() == direction_;
  }

  [[nodiscard]] bool matches_final_known_tail(
      const TransferToken& token) const noexcept {
    return matches_known_transfer(token) &&
           token.tail() == last_accepted_tail_;
  }

  std::uint64_t session_id_ = 0U;
  std::uint32_t generation_ = 0U;
  Direction direction_ = Direction::Downlink;
  bool has_accepted_tail_ = false;
  std::uint64_t last_accepted_tail_ = 0U;
  bool unknown_tail_pending_ = false;
  TransferToken unknown_token_{};
  bool has_progress_tail_ = false;
  std::uint64_t progress_tail_ = 0U;
  bool drain_proof_issued_ = false;
  DrainProof issued_drain_proof_{};
  bool radio_tx_empty_ = false;
  bool radio_tx_complete_ = false;
  bool completion_low_seen_since_accept_ = false;
  bool aux_high_ = false;
  bool accounting_fault_ = false;
};

// Receiver-side ledger for the native bulk stream.  The strict Ground
// checker expects PARAM_VALUE index 0..931 exactly once and in order; this
// ledger supplies the physical counterpart by accepting both 32-byte chunks
// of each frame, in parameter-only ordinal order 0..1863. Seeing only the
// final RF tail can therefore never prove delivery of missing earlier chunks.
class RemoteDeliveryLedger {
 public:
  explicit constexpr RemoteDeliveryLedger(std::uint64_t session_id,
                                          std::uint64_t stream_id,
                                          std::uint64_t lease_id,
                                          std::uint32_t
                                              ground_request_started_ms) noexcept
      : session_id_(session_id),
        stream_id_(stream_id),
        lease_id_(lease_id),
        ground_request_started_ms_(ground_request_started_ms),
        accounting_fault_(session_id == 0U || stream_id == 0U ||
                          lease_id == 0U) {}

  RemoteDeliveryLedger(const RemoteDeliveryLedger&) = delete;
  RemoteDeliveryLedger& operator=(const RemoteDeliveryLedger&) = delete;
  RemoteDeliveryLedger(RemoteDeliveryLedger&&) = delete;
  RemoteDeliveryLedger& operator=(RemoteDeliveryLedger&&) = delete;

  bool observe_parameter_chunk(
      const ParameterChunkWatermark& watermark,
      std::uint32_t observed_at_ms) noexcept {
    if (!record_observation_attempt() || accounting_fault_ ||
        parameter_proof_issued_ || !watermark.valid() ||
        watermark.token().session_id() != session_id_ ||
        watermark.stream_id() != stream_id_ ||
        watermark.lease_id() != lease_id_ ||
        watermark.parameter_index() != received_parameter_count_ ||
        watermark.chunk_ordinal() != next_parameter_chunk_ordinal_ ||
        watermark.global_chunk_ordinal() != received_parameter_chunks_ ||
        !token_is_next(watermark.token()) ||
        (received_parameter_chunks_ == 0U &&
         elapsed_ms(observed_at_ms, ground_request_started_ms_) >
             static_cast<std::uint32_t>(
                 std::numeric_limits<std::int32_t>::max())) ||
        !observation_time_is_forward(observed_at_ms)) {
      accounting_fault_ = true;
      return false;
    }

    if (received_parameter_chunks_ == 0U) {
      first_parameter_observed_at_ms_ = observed_at_ms;
    }
    accept_token(watermark.token(), observed_at_ms);
    ++received_parameter_chunks_;
    received_parameter_bytes_ +=
        HighSpeedCandidateContract::radio_chunk_bytes;
    if (next_parameter_chunk_ordinal_ == 0U) {
      next_parameter_chunk_ordinal_ = 1U;
      return true;
    }

    next_parameter_chunk_ordinal_ = 0U;
    ++received_parameter_count_;
    if (received_parameter_count_ !=
        HighSpeedCandidateContract::expected_parameter_count) {
      return true;
    }
    if (received_parameter_chunks_ !=
            HighSpeedCandidateContract::expected_parameter_wire_chunks ||
        received_parameter_bytes_ !=
            HighSpeedCandidateContract::expected_parameter_wire_bytes) {
      accounting_fault_ = true;
      return false;
    }
    parameter_stream_complete_ = true;
    final_parameter_token_ = watermark.token();
    final_parameter_observed_at_ms_ = observed_at_ms;
    return true;
  }

  // Called only after the receiver event batch has been drained.  Delaying
  // proof issuance until this explicit seal means a duplicate/out-of-order
  // event seen in the same batch invalidates the ledger before any terminal
  // capability exists.
  std::optional<ParameterStreamDeliveryProof>
  seal_parameter_stream_delivery() noexcept {
    if (accounting_fault_ || parameter_terminal_consumed_ ||
        !parameter_stream_complete_ || next_parameter_chunk_ordinal_ != 0U ||
        received_parameter_count_ !=
            HighSpeedCandidateContract::expected_parameter_count ||
        received_parameter_chunks_ !=
            HighSpeedCandidateContract::expected_parameter_wire_chunks ||
        received_parameter_bytes_ !=
            HighSpeedCandidateContract::expected_parameter_wire_bytes ||
        !has_observation_time_) {
      return std::nullopt;
    }
    parameter_proof_issued_ = true;
    parameter_proof_revision_ = receiver_revision_;
    issued_parameter_proof_ = ParameterStreamDeliveryProof(
        final_parameter_token_, stream_id_, lease_id_,
        received_parameter_count_, received_parameter_chunks_,
        received_parameter_bytes_, ground_request_started_ms_,
        first_parameter_observed_at_ms_,
        final_parameter_observed_at_ms_,
        receiver_revision_, this);
    return issued_parameter_proof_;
  }

  std::optional<HeartbeatDeliveryProof> observe_heartbeat(
      const HeartbeatTailWatermark& watermark,
      std::uint32_t observed_at_ms) noexcept {
    // Heartbeats may be interleaved only at PARAM_VALUE frame boundaries.
    // A VCB1 heartbeat spans two physical chunks, so its tail advances RF
    // contiguity by the complete 64-byte transaction. It never advances the
    // parameter-only chunk ledger.
    if (!record_observation_attempt() || accounting_fault_ ||
        next_parameter_chunk_ordinal_ != 0U ||
        !watermark.valid() ||
        watermark.token().session_id() != session_id_ ||
        watermark.stream_id() != stream_id_ ||
        watermark.lease_id() != lease_id_ ||
        (has_heartbeat_request_ &&
         watermark.request_id() <= last_heartbeat_request_id_) ||
        !token_is_next_after_bytes(
            watermark.token(),
            HighSpeedCandidateContract::heartbeat_wire_bytes_per_frame) ||
        !observation_time_is_forward(observed_at_ms)) {
      accounting_fault_ = true;
      return std::nullopt;
    }

    accept_token(watermark.token(), observed_at_ms);
    has_heartbeat_request_ = true;
    last_heartbeat_request_id_ = watermark.request_id();
    return HeartbeatDeliveryProof(
        watermark.token(), stream_id_, lease_id_, watermark.request_id(),
        observed_at_ms);
  }

  [[nodiscard]] constexpr bool accounting_fault() const noexcept {
    return accounting_fault_;
  }
  [[nodiscard]] constexpr std::uint64_t
  received_parameter_count() const noexcept {
    return received_parameter_count_;
  }
  [[nodiscard]] constexpr std::uint64_t
  received_parameter_chunks() const noexcept {
    return received_parameter_chunks_;
  }
  [[nodiscard]] constexpr std::uint64_t
  received_parameter_bytes() const noexcept {
    return received_parameter_bytes_;
  }
  [[nodiscard]] constexpr std::uint64_t receiver_revision() const noexcept {
    return receiver_revision_;
  }
  [[nodiscard]] constexpr bool parameter_terminal_consumed() const noexcept {
    return parameter_terminal_consumed_;
  }

 private:
  friend class NativeBulkDownlink;

  [[nodiscard]] std::optional<ParameterStreamDeliveryProof>
  consume_current_parameter_delivery(
      const ParameterStreamDeliveryProof& proof) noexcept {
    if (!current_parameter_delivery_matches(proof)) {
      return std::nullopt;
    }
    parameter_terminal_consumed_ = true;
    return issued_parameter_proof_;
  }

  [[nodiscard]] bool current_parameter_delivery_matches(
      const ParameterStreamDeliveryProof& proof) const noexcept {
    return !accounting_fault_ && !parameter_terminal_consumed_ &&
           parameter_proof_issued_ &&
           parameter_proof_revision_ == receiver_revision_ && proof.valid() &&
           proof.issuer_ == this &&
           proof.receiver_revision_ == receiver_revision_ &&
           proof.final_token_ == issued_parameter_proof_.final_token_ &&
           proof.stream_id_ == issued_parameter_proof_.stream_id_ &&
           proof.lease_id_ == issued_parameter_proof_.lease_id_;
  }

  [[nodiscard]] bool terminal_state_is_current(
      std::uint64_t expected_revision) const noexcept {
    return !accounting_fault_ && parameter_terminal_consumed_ &&
           parameter_proof_issued_ && receiver_revision_ == expected_revision &&
           parameter_proof_revision_ == expected_revision;
  }

  bool record_observation_attempt() noexcept {
    if (receiver_revision_ == std::numeric_limits<std::uint64_t>::max()) {
      accounting_fault_ = true;
      return false;
    }
    ++receiver_revision_;
    return true;
  }

  [[nodiscard]] bool token_is_next(const TransferToken& token) const noexcept {
    return token_is_next_after_bytes(
        token, HighSpeedCandidateContract::radio_chunk_bytes);
  }

  [[nodiscard]] bool token_is_next_after_bytes(
      const TransferToken& token,
      std::uint64_t expected_wire_bytes) const noexcept {
    if (!token.valid() || !token.tail_known() ||
        token.direction() != Direction::Downlink ||
        token.session_id() != session_id_ || token.generation() == 0U ||
        expected_wire_bytes == 0U) {
      return false;
    }
    if (!has_wire_token_) {
      return token.tail() == expected_wire_bytes - 1U;
    }
    return token.generation() == generation_ &&
           last_wire_tail_ <=
               std::numeric_limits<std::uint64_t>::max() -
                   expected_wire_bytes &&
           token.tail() == last_wire_tail_ + expected_wire_bytes;
  }

  [[nodiscard]] bool observation_time_is_forward(
      std::uint32_t observed_at_ms) const noexcept {
    return !has_observation_time_ ||
           elapsed_ms(observed_at_ms, last_observed_at_ms_) <=
               static_cast<std::uint32_t>(
                   std::numeric_limits<std::int32_t>::max());
  }

  void accept_token(const TransferToken& token,
                    std::uint32_t observed_at_ms) noexcept {
    if (!has_wire_token_) {
      generation_ = token.generation();
    }
    has_wire_token_ = true;
    last_wire_tail_ = token.tail();
    has_observation_time_ = true;
    last_observed_at_ms_ = observed_at_ms;
  }

  std::uint64_t session_id_ = 0U;
  std::uint64_t stream_id_ = 0U;
  std::uint64_t lease_id_ = 0U;
  std::uint32_t ground_request_started_ms_ = 0U;
  bool has_wire_token_ = false;
  std::uint32_t generation_ = 0U;
  std::uint64_t last_wire_tail_ = 0U;
  bool has_observation_time_ = false;
  std::uint32_t last_observed_at_ms_ = 0U;
  std::uint64_t received_parameter_count_ = 0U;
  std::uint64_t received_parameter_chunks_ = 0U;
  std::uint64_t received_parameter_bytes_ = 0U;
  std::uint8_t next_parameter_chunk_ordinal_ = 0U;
  bool has_heartbeat_request_ = false;
  std::uint32_t last_heartbeat_request_id_ = 0U;
  bool parameter_proof_issued_ = false;
  bool parameter_terminal_consumed_ = false;
  std::uint64_t receiver_revision_ = 0U;
  std::uint64_t parameter_proof_revision_ = 0U;
  ParameterStreamDeliveryProof issued_parameter_proof_{};
  bool parameter_stream_complete_ = false;
  TransferToken final_parameter_token_{};
  std::uint32_t final_parameter_observed_at_ms_ = 0U;
  std::uint32_t first_parameter_observed_at_ms_ = 0U;
  bool accounting_fault_ = false;
};

// Ground-side cumulative heartbeat SLA ledger.  This ledger never feeds
// admission credit and never sends a midstream ACK.  It uses only Ground
// millis() samples and is sealed once, together with the contiguous PARAM
// delivery proof, for the terminal ACK.
class RemoteHeartbeatSlaLedger {
 public:
  static inline constexpr std::uint32_t heartbeat_deadline_ms =
      HighSpeedCandidateContract::heartbeat_hard_deadline_ms;

  explicit constexpr RemoteHeartbeatSlaLedger(
      std::uint64_t session_id, std::uint64_t stream_id,
      std::uint64_t lease_id, std::uint32_t ground_request_started_ms,
      std::uint32_t baseline_heartbeat_ms,
      std::uint32_t baseline_heartbeat_sequence) noexcept
      : session_id_(session_id),
        stream_id_(stream_id),
        lease_id_(lease_id),
        ground_request_started_ms_(ground_request_started_ms),
        baseline_heartbeat_ms_(baseline_heartbeat_ms),
        last_heartbeat_sequence_(baseline_heartbeat_sequence),
        accounting_fault_(session_id == 0U || stream_id == 0U ||
                          lease_id == 0U ||
                          elapsed_ms(ground_request_started_ms,
                                     baseline_heartbeat_ms) >
                              static_cast<std::uint32_t>(
                                  std::numeric_limits<std::int32_t>::max())) {}

  RemoteHeartbeatSlaLedger(const RemoteHeartbeatSlaLedger&) = delete;
  RemoteHeartbeatSlaLedger& operator=(const RemoteHeartbeatSlaLedger&) =
      delete;
  RemoteHeartbeatSlaLedger(RemoteHeartbeatSlaLedger&&) = delete;
  RemoteHeartbeatSlaLedger& operator=(RemoteHeartbeatSlaLedger&&) = delete;

  bool observe_heartbeat(const HeartbeatTailWatermark& watermark,
                         std::uint32_t ground_observed_at_ms,
                         std::uint32_t heartbeat_sequence) noexcept {
    if (!record_observation_attempt() || accounting_fault_ || proof_issued_ ||
        !watermark.valid() ||
        watermark.token().session_id() != session_id_ ||
        watermark.token().direction() != Direction::Downlink ||
        watermark.stream_id() != stream_id_ ||
        watermark.lease_id() != lease_id_ ||
        watermark.request_id() != heartbeat_count_ + 1U ||
        heartbeat_sequence != last_heartbeat_sequence_ + 1U ||
        (has_heartbeat_time_ &&
         elapsed_ms(ground_observed_at_ms, last_heartbeat_ms_) >
             static_cast<std::uint32_t>(
                 std::numeric_limits<std::int32_t>::max()))) {
      accounting_fault_ = true;
      return false;
    }
    if (heartbeat_count_ == std::numeric_limits<std::uint32_t>::max()) {
      accounting_fault_ = true;
      counter_fault_latched_ = true;
      return false;
    }
    if (!has_heartbeat_time_) {
      first_heartbeat_ms_ = ground_observed_at_ms;
      const std::uint32_t baseline_gap =
          elapsed_ms(ground_observed_at_ms, baseline_heartbeat_ms_);
      if (baseline_gap > heartbeat_deadline_ms ||
          baseline_gap > static_cast<std::uint32_t>(
                             std::numeric_limits<std::int32_t>::max())) {
        accounting_fault_ = true;
        return false;
      }
    } else {
      const std::uint32_t gap =
          elapsed_ms(ground_observed_at_ms, last_heartbeat_ms_);
      if (gap > max_gap_ms_) {
        max_gap_ms_ = gap;
      }
      if (gap > heartbeat_deadline_ms) {
        accounting_fault_ = true;
        return false;
      }
    }
    has_heartbeat_time_ = true;
    last_heartbeat_ms_ = ground_observed_at_ms;
    ++heartbeat_count_;
    last_request_id_ = watermark.request_id();
    last_heartbeat_sequence_ = heartbeat_sequence;
    return true;
  }

  std::optional<RemoteHeartbeatSlaProof> seal_terminal_sla(
      const ParameterStreamDeliveryProof& parameter_delivery) noexcept {
    if (accounting_fault_ || terminal_consumed_ || proof_issued_ ||
        !has_heartbeat_time_ || !parameter_delivery.valid() ||
        parameter_delivery.final_token().session_id() != session_id_ ||
        parameter_delivery.stream_id() != stream_id_ ||
        parameter_delivery.lease_id() != lease_id_) {
      return std::nullopt;
    }
    if (parameter_delivery.remote_request_started_ms() !=
        ground_request_started_ms_) {
      accounting_fault_ = true;
      return std::nullopt;
    }
    const std::uint32_t final_parameter_ms =
        parameter_delivery.remote_observed_at_ms();
    const std::uint32_t first_gap =
        elapsed_ms(first_heartbeat_ms_, baseline_heartbeat_ms_);
    const std::uint32_t post_gap =
        elapsed_ms(final_parameter_ms, last_heartbeat_ms_);
    if (first_gap > heartbeat_deadline_ms ||
        first_gap > static_cast<std::uint32_t>(
                        std::numeric_limits<std::int32_t>::max()) ||
        post_gap > heartbeat_deadline_ms ||
        post_gap > static_cast<std::uint32_t>(
                       std::numeric_limits<std::int32_t>::max()) ||
        max_gap_ms_ > heartbeat_deadline_ms) {
      accounting_fault_ = true;
      return std::nullopt;
    }
    proof_issued_ = true;
    proof_revision_ = receiver_revision_;
    issued_proof_ = RemoteHeartbeatSlaProof(
        session_id_, stream_id_, lease_id_, heartbeat_count_,
        last_request_id_, first_gap, max_gap_ms_, post_gap,
        parameter_delivery.issuer_, parameter_delivery.receiver_revision_,
        parameter_delivery.final_token_,
        parameter_delivery.remote_observed_at_ms_,
        receiver_revision_, this);
    return issued_proof_;
  }

  [[nodiscard]] constexpr bool accounting_fault() const noexcept {
    return accounting_fault_;
  }
  [[nodiscard]] constexpr bool counter_fault_latched() const noexcept {
    return counter_fault_latched_;
  }
  [[nodiscard]] constexpr std::uint32_t heartbeat_count() const noexcept {
    return heartbeat_count_;
  }
  [[nodiscard]] constexpr bool terminal_consumed() const noexcept {
    return terminal_consumed_;
  }

 private:
  friend class NativeBulkDownlink;

  [[nodiscard]] std::optional<RemoteHeartbeatSlaProof>
  consume_current_sla(const RemoteHeartbeatSlaProof& proof) noexcept {
    if (!current_sla_matches(proof)) {
      return std::nullopt;
    }
    terminal_consumed_ = true;
    return issued_proof_;
  }

  [[nodiscard]] bool current_sla_matches(
      const RemoteHeartbeatSlaProof& proof) const noexcept {
    return !accounting_fault_ && !terminal_consumed_ && proof_issued_ &&
           proof_revision_ == receiver_revision_ && proof.valid() &&
           proof.issuer_ == this &&
           proof.receiver_revision_ == receiver_revision_ &&
           proof.session_id_ == session_id_ && proof.stream_id_ == stream_id_ &&
           proof.lease_id_ == lease_id_ &&
           proof.heartbeat_count_ == heartbeat_count_ &&
           proof.last_request_id_ == last_request_id_;
  }

  [[nodiscard]] bool terminal_state_is_current(
      std::uint64_t expected_revision) const noexcept {
    return !accounting_fault_ && terminal_consumed_ && proof_issued_ &&
           receiver_revision_ == expected_revision &&
           proof_revision_ == expected_revision;
  }

  bool record_observation_attempt() noexcept {
    if (receiver_revision_ == std::numeric_limits<std::uint64_t>::max()) {
      accounting_fault_ = true;
      counter_fault_latched_ = true;
      return false;
    }
    ++receiver_revision_;
    return true;
  }

  std::uint64_t session_id_ = 0U;
  std::uint64_t stream_id_ = 0U;
  std::uint64_t lease_id_ = 0U;
  std::uint32_t ground_request_started_ms_ = 0U;
  std::uint32_t baseline_heartbeat_ms_ = 0U;
  bool has_heartbeat_time_ = false;
  std::uint32_t first_heartbeat_ms_ = 0U;
  std::uint32_t last_heartbeat_ms_ = 0U;
  std::uint32_t max_gap_ms_ = 0U;
  std::uint32_t heartbeat_count_ = 0U;
  std::uint32_t last_request_id_ = 0U;
  std::uint32_t last_heartbeat_sequence_ = 0U;
  std::uint64_t receiver_revision_ = 0U;
  std::uint64_t proof_revision_ = 0U;
  RemoteHeartbeatSlaProof issued_proof_{};
  bool proof_issued_ = false;
  bool terminal_consumed_ = false;
  bool accounting_fault_ = false;
  bool counter_fault_latched_ = false;
};

struct NativeBulkInput {
  bool fifo_has_complete_frame = false;
  bool upstream_stream_complete = false;
  bool parser_partial = false;
  std::size_t queued_backlog = 0U;
  std::uint32_t estimated_worst_case_frame_service_ms = 0U;
};

enum class BulkAction : std::uint8_t {
  WaitForFirstParam,
  WaitForData,
  StartNextParamFrame,
  ContinueActiveFrame,
  SendHeartbeat,
  WaitForHeartbeatDelivery,
  WaitForFinalParamDelivery,
  EndSuccess,
  EndIncomplete,
  EndAbort,
  Complete
};

enum class BulkDisposition : std::uint8_t {
  Running,
  SuccessPending,
  IncompletePending,
  AbortPending,
  Success,
  Incomplete,
  Aborted
};

enum class BulkEndReason : std::uint8_t {
  None,
  InvalidSession,
  InvalidStream,
  InvalidLease,
  UpstreamComplete,
  UpstreamCompleteCountMismatch,
  InactivityIncomplete,
  AbsoluteMaxIncomplete,
  FinalLocalHandoffAfterAbsoluteMax,
  FinalTailAfterAbsoluteMax,
  TerminalAckTimeout,
  HeartbeatDeadlineMiss,
  ParamOrderViolation,
  ParamCountExceeded,
  CounterOverflow,
  EvidencePollOrderViolation,
  LateParamAfterExit,
  ReceiverEvidenceRevoked
};

class NativeBulkDownlink {
 public:
  static inline constexpr std::uint64_t expected_param_count =
      HighSpeedCandidateContract::expected_parameter_count;
  static inline constexpr std::uint32_t inactivity_ms =
      HighSpeedCandidateContract::late_terminal_wait_ms;
  static inline constexpr std::uint32_t absolute_max_ms =
      HighSpeedCandidateContract::native_stream_downlink_ms;
  static inline constexpr std::uint32_t ground_arrival_target_ms =
      static_cast<std::uint32_t>(
          HighSpeedCandidateContract::target_completion_ms);
  static inline constexpr std::uint32_t terminal_ack_wait_ms =
      HighSpeedCandidateContract::late_terminal_wait_ms;
  static inline constexpr std::uint32_t terminal_session_limit_ms =
      ground_arrival_target_ms +
      HighSpeedCandidateContract::direction_guard_ms +
      terminal_ack_wait_ms + 20U;
  static inline constexpr std::uint32_t heartbeat_deadline_ms =
      HighSpeedCandidateContract::heartbeat_hard_deadline_ms;
  static inline constexpr std::uint32_t radio_buffer_payload_floor_ms =
      static_cast<std::uint32_t>(
          (HighSpeedCandidateContract::documented_internal_buffer_bytes * 8U *
               1000U +
           HighSpeedCandidateContract::radio_air_bps - 1U) /
          HighSpeedCandidateContract::radio_air_bps);
  // The tail model is deliberately more conservative than the 167-ms
  // payload-only floor: it includes the existing late-tail observation bound.
  static inline constexpr std::uint32_t conservative_tail_service_ms =
      HighSpeedCandidateContract::late_terminal_wait_ms;
  static inline constexpr std::uint32_t heartbeat_reserve_floor_ms =
      conservative_tail_service_ms > radio_buffer_payload_floor_ms
          ? conservative_tail_service_ms
          : radio_buffer_payload_floor_ms;

  [[nodiscard]] static constexpr std::uint32_t
  required_heartbeat_reserve_ms(
      std::uint32_t modeled_frame_service_ms) noexcept {
    return modeled_frame_service_ms >
                   std::numeric_limits<std::uint32_t>::max() -
                       heartbeat_reserve_floor_ms
               ? std::numeric_limits<std::uint32_t>::max()
               : modeled_frame_service_ms + heartbeat_reserve_floor_ms;
  }

  explicit constexpr NativeBulkDownlink(
      std::uint64_t expected_session_id, std::uint64_t stream_id,
      std::uint64_t lease_id,
      std::uint64_t initial_param_count = 0U) noexcept
      : session_id_(expected_session_id),
        stream_id_(stream_id),
        lease_id_(lease_id),
        param_value_count_(initial_param_count),
        hard_fault_latched_(expected_session_id == 0U || stream_id == 0U ||
                            lease_id == 0U),
        disposition_(expected_session_id == 0U || stream_id == 0U ||
                             lease_id == 0U
                         ? BulkDisposition::AbortPending
                         : BulkDisposition::Running),
        end_reason_(expected_session_id == 0U
                        ? BulkEndReason::InvalidSession
                        : (stream_id == 0U ? BulkEndReason::InvalidStream
                                           : (lease_id == 0U
                                                  ? BulkEndReason::InvalidLease
                                                  : BulkEndReason::None))) {}

  bool observe_param_value(std::uint32_t now, bool mavlink_valid,
                           std::uint16_t parameter_index) noexcept {
    if (!mavlink_valid) {
      return false;
    }
    if (complete_ || disposition_ != BulkDisposition::Running) {
      record_late_parameter_loss();
      return false;
    }
    if (param_value_count_ == std::numeric_limits<std::uint64_t>::max()) {
      counter_fault_latched_ = true;
      latch_abort(BulkEndReason::CounterOverflow);
      return false;
    }
    if (param_value_count_ >= expected_param_count) {
      latch_abort(BulkEndReason::ParamCountExceeded);
      return false;
    }
    if (static_cast<std::uint64_t>(parameter_index) != param_value_count_) {
      latch_abort(BulkEndReason::ParamOrderViolation);
      return false;
    }
    if (!started_) {
      started_ = true;
      first_param_ms_ = now;
    }
    last_valid_param_ms_ = now;
    ++param_value_count_;
    return true;
  }

  bool begin_active_frame(std::uint32_t now,
                          std::uint32_t worst_case_service_ms) noexcept {
    if (!started_ || complete_ || active_frame_ ||
        disposition_ != BulkDisposition::Running ||
        heartbeat_requires_service_before_frame(now,
                                                worst_case_service_ms)) {
      return false;
    }
    active_frame_ = true;
    return true;
  }

  bool finish_active_frame() noexcept {
    if (!active_frame_) {
      return false;
    }
    active_frame_ = false;
    return true;
  }

  bool queue_heartbeat(std::uint32_t now) noexcept {
    if (complete_ || heartbeat_pending_) {
      return false;
    }
    if (heartbeat_request_id_ ==
        std::numeric_limits<std::uint32_t>::max()) {
      counter_fault_latched_ = true;
      latch_abort(BulkEndReason::CounterOverflow);
      return false;
    }
    ++heartbeat_request_id_;
    heartbeat_pending_ = true;
    heartbeat_pending_since_ms_ = now;
    heartbeat_tail_bound_ = false;
    return true;
  }

  [[nodiscard]] std::optional<HeartbeatTailPermit>
  heartbeat_tail_permit() const noexcept {
    if (!heartbeat_pending_ || heartbeat_tail_bound_ ||
        heartbeat_request_id_ == 0U) {
      return std::nullopt;
    }
    return HeartbeatTailPermit(session_id_, stream_id_, lease_id_,
                               heartbeat_request_id_);
  }

  [[nodiscard]] std::optional<ParameterFramePermit>
  parameter_frame_permit() const noexcept {
    if (complete_ || disposition_ != BulkDisposition::Running ||
        physically_committed_param_count_ >= param_value_count_ ||
        physically_committed_param_count_ >= expected_param_count) {
      return std::nullopt;
    }
    return ParameterFramePermit(
        session_id_, stream_id_, lease_id_,
        static_cast<std::uint16_t>(physically_committed_param_count_));
  }

  bool consume_parameter_frame_tail(
      const ParameterFrameTailWatermark& watermark,
      std::uint32_t local_handoff_ms) noexcept {
    const TransferToken& token = watermark.token();
    if (!watermark.valid() || !token.valid() || !token.tail_known() ||
        token.session_id() != session_id_ ||
        token.direction() != Direction::Downlink ||
        watermark.stream_id() != stream_id_ ||
        watermark.lease_id() != lease_id_ ||
        watermark.parameter_index() != physically_committed_param_count_ ||
        physically_committed_param_count_ >= param_value_count_ ||
        physically_committed_param_count_ >= expected_param_count ||
        elapsed_ms(local_handoff_ms, first_param_ms_) >
            static_cast<std::uint32_t>(
                std::numeric_limits<std::int32_t>::max()) ||
        (has_physical_param_handoff_ms_ &&
         elapsed_ms(local_handoff_ms, last_physical_param_handoff_ms_) >
             static_cast<std::uint32_t>(
                 std::numeric_limits<std::int32_t>::max())) ||
        (has_physical_param_tail_ &&
         (token.generation() != physical_param_generation_ ||
          token.tail() <= physical_param_tail_))) {
      return false;
    }
    if (physically_committed_param_chunks_ >
            std::numeric_limits<std::uint64_t>::max() -
                HighSpeedCandidateContract::param_value_wire_chunks_per_frame ||
        physically_committed_param_bytes_ >
            std::numeric_limits<std::uint64_t>::max() -
                HighSpeedCandidateContract::param_value_wire_bytes_per_frame) {
      counter_fault_latched_ = true;
      latch_abort(BulkEndReason::CounterOverflow);
      return false;
    }
    if (!has_physical_param_tail_) {
      physical_param_generation_ = token.generation();
    }
    has_physical_param_tail_ = true;
    physical_param_tail_ = token.tail();
    last_physical_param_token_ = token;
    has_physical_param_handoff_ms_ = true;
    last_physical_param_handoff_ms_ = local_handoff_ms;
    ++physically_committed_param_count_;
    physically_committed_param_chunks_ +=
        HighSpeedCandidateContract::param_value_wire_chunks_per_frame;
    physically_committed_param_bytes_ +=
        HighSpeedCandidateContract::param_value_wire_bytes_per_frame;
    if (physically_committed_param_count_ == expected_param_count) {
      final_param_local_handoff_ms_ = local_handoff_ms;
      final_param_local_handoff_recorded_ = true;
      if (elapsed_ms(final_param_local_handoff_ms_, first_param_ms_) >
          absolute_max_ms) {
        latch_incomplete(BulkEndReason::FinalLocalHandoffAfterAbsoluteMax);
      }
    }
    return true;
  }

  bool bind_heartbeat_tail(
      const HeartbeatTailWatermark& watermark) noexcept {
    const TransferToken& token = watermark.token();
    if (!heartbeat_pending_ || heartbeat_tail_bound_ || !watermark.valid() ||
        !token.valid() || !token.tail_known() ||
        token.session_id() != session_id_ ||
        token.direction() != Direction::Downlink ||
        watermark.stream_id() != stream_id_ ||
        watermark.lease_id() != lease_id_ ||
        watermark.request_id() != heartbeat_request_id_) {
      return false;
    }
    heartbeat_tail_ = token;
    heartbeat_tail_bound_ = true;
    return true;
  }

  // Full semantic UART admission is the sender-side E220 buffer handoff.  It
  // releases the scheduler to queue the next ~1-Hz heartbeat without opening
  // a reverse-direction ACK window.  End-to-end arrival is judged later by
  // RemoteHeartbeatSlaLedger on Ground and returned only in the terminal ACK.
  bool note_heartbeat_uart_sent() const noexcept {
    return heartbeat_pending_ && heartbeat_tail_bound_;
  }

  bool confirm_heartbeat_local_buffer_handoff(
      const HeartbeatTailWatermark& watermark,
      std::uint32_t local_handoff_ms) noexcept {
    if (!heartbeat_pending_ || !heartbeat_tail_bound_ || !watermark.valid() ||
        watermark.token() != heartbeat_tail_ ||
        watermark.stream_id() != stream_id_ ||
        watermark.lease_id() != lease_id_ ||
        watermark.request_id() != heartbeat_request_id_ ||
        heartbeat_local_handoff_count_ ==
            std::numeric_limits<std::uint32_t>::max() ||
        watermark.request_id() != heartbeat_local_handoff_count_ + 1U) {
      if (heartbeat_local_handoff_count_ ==
          std::numeric_limits<std::uint32_t>::max()) {
        counter_fault_latched_ = true;
        latch_abort(BulkEndReason::CounterOverflow);
      }
      return false;
    }
    if (heartbeat_deadline_missed(local_handoff_ms)) {
      latch_abort(BulkEndReason::HeartbeatDeadlineMiss);
      return false;
    }
    ++heartbeat_local_handoff_count_;
    heartbeat_pending_ = false;
    heartbeat_tail_bound_ = false;
    return true;
  }

 public:
  bool bind_final_parameter_tail(
      const FinalParameterTailWatermark& watermark) noexcept {
    const TransferToken& token = watermark.token();
    if (!started_ || complete_ ||
        disposition_ != BulkDisposition::Running ||
        param_value_count_ != expected_param_count ||
        physically_committed_param_count_ != expected_param_count ||
        physically_committed_param_chunks_ !=
            HighSpeedCandidateContract::expected_parameter_wire_chunks ||
        physically_committed_param_bytes_ !=
            HighSpeedCandidateContract::expected_parameter_wire_bytes ||
        !final_param_local_handoff_recorded_ ||
        final_param_tail_bound_ ||
        !watermark.valid() || !token.valid() || !token.tail_known() ||
        token.session_id() != session_id_ ||
        token.direction() != Direction::Downlink ||
        watermark.stream_id() != stream_id_ ||
        watermark.lease_id() != lease_id_ ||
        !has_physical_param_tail_ || token != last_physical_param_token_ ||
        watermark.parameter_index() != expected_param_count - 1U) {
      return false;
    }
    final_param_tail_ = token;
    final_param_tail_bound_ = true;
    return true;
  }

  // Integration may open this finite terminal-ACK window only after the
  // final downlink tail has drained and the direction guard has completed.
  // It is deliberately separate from the Ground request->last-PARAM metric.
  bool open_terminal_ack_window(std::uint32_t local_now) noexcept {
    if (!final_param_tail_bound_ || terminal_ack_window_open_ ||
        heartbeat_pending_ || disposition_ != BulkDisposition::Running) {
      return false;
    }
    terminal_ack_window_open_ = true;
    terminal_ack_window_started_ms_ = local_now;
    return true;
  }

 private:
  bool confirm_final_parameter_delivery(
      const ParameterStreamDeliveryProof& proof,
      std::uint32_t local_ack_received_ms) noexcept {
    if (!terminal_ack_window_open_ ||
        elapsed_ms(local_ack_received_ms, terminal_ack_window_started_ms_) >
            terminal_ack_wait_ms ||
        !final_param_tail_bound_ || final_param_remote_arrived_ ||
        disposition_ != BulkDisposition::Running || !proof.valid() ||
        proof.stream_id() != stream_id_ || proof.lease_id() != lease_id_ ||
        proof.parameter_count() != expected_param_count ||
        proof.chunk_count() !=
            HighSpeedCandidateContract::expected_parameter_wire_chunks ||
        proof.wire_bytes() !=
            HighSpeedCandidateContract::expected_parameter_wire_bytes ||
        proof.final_token() != final_param_tail_) {
      if (terminal_ack_window_open_ &&
          elapsed_ms(local_ack_received_ms,
                     terminal_ack_window_started_ms_) >
              terminal_ack_wait_ms) {
        latch_incomplete(BulkEndReason::TerminalAckTimeout);
      }
      return false;
    }
    final_param_remote_arrived_ = true;
    terminal_ack_received_ms_ = local_ack_received_ms;
    ground_param_arrival_elapsed_ms_ = proof.remote_transfer_elapsed_ms();
    if (ground_param_arrival_elapsed_ms_ > ground_arrival_target_ms) {
      latch_incomplete(BulkEndReason::FinalTailAfterAbsoluteMax);
      return false;
    }
    final_param_delivery_on_time_ = true;
    final_param_receiver_ = proof.issuer_;
    final_param_receiver_revision_ = proof.receiver_revision_;
    return true;
  }

  bool confirm_remote_heartbeat_sla(
      const RemoteHeartbeatSlaProof& proof) noexcept {
    if (remote_heartbeat_sla_accepted_ || !proof.valid() ||
        proof.session_id() != session_id_ || proof.stream_id() != stream_id_ ||
        proof.lease_id() != lease_id_ ||
        proof.heartbeat_count() != heartbeat_local_handoff_count_ ||
        proof.last_request_id() != heartbeat_request_id_ ||
        proof.first_gap_ms() > heartbeat_deadline_ms ||
        proof.max_gap_ms() > heartbeat_deadline_ms ||
        proof.post_gap_ms() > heartbeat_deadline_ms) {
      return false;
    }
    remote_heartbeat_sla_accepted_ = true;
    heartbeat_sla_receiver_ = proof.issuer_;
    heartbeat_sla_receiver_revision_ = proof.receiver_revision_;
    return true;
  }

 public:
  // drained_through_ms is the sender-side monotonic time at which the ACK was
  // received and the local event queue was drained.  Remote proof timestamps
  // are used only for receiver ordering; they are intentionally never mixed
  // with first_param_ms_/heartbeat_pending_since_ms_ deadline arithmetic.
  // poll() requires the same local clock sample, preventing cached epochs.
  ReceiverEvidencePollEpoch seal_receiver_events_drained(
      std::uint32_t drained_through_ms) noexcept {
    return issue_poll_epoch(drained_through_ms, nullptr, nullptr);
  }

  ReceiverEvidencePollEpoch seal_terminal_receiver_evidence(
      std::uint32_t terminal_ack_received_ms,
      const ParameterStreamDeliveryProof& parameter_delivery,
      RemoteDeliveryLedger& parameter_receiver,
      const RemoteHeartbeatSlaProof& heartbeat_sla,
      RemoteHeartbeatSlaLedger& heartbeat_receiver) noexcept {
    // WIRE INTEGRATION BLOCKER: no terminal ACK codec is implemented here.
    // A live design must encode session/stream/lease, final global ordinal,
    // exact PARAM accounting, HB count/first/max/post gaps, receiver batch
    // identity, and CRC.  Production v2 uses exact fixed 32-byte control/data
    // frames, so this requires either a checked multi-frame vNext ACK or a
    // reviewed digest.  Return guard and ACK airtime are separate from Ground
    // request->last-PARAM 30-second metric.  Until that codec is tested, the
    // live gate remains false.
    const bool pair_matches =
        parameter_receiver.current_parameter_delivery_matches(
            parameter_delivery) &&
        heartbeat_receiver.current_sla_matches(heartbeat_sla) &&
        heartbeat_sla.parameter_issuer_ == &parameter_receiver &&
        heartbeat_sla.parameter_receiver_revision_ ==
            parameter_delivery.receiver_revision_ &&
        heartbeat_sla.final_parameter_token_ ==
            parameter_delivery.final_token_ &&
        heartbeat_sla.final_parameter_observed_at_ms_ ==
            parameter_delivery.remote_observed_at_ms_;
    if (!pair_matches) {
      latch_abort(BulkEndReason::ReceiverEvidenceRevoked);
      return issue_poll_epoch(terminal_ack_received_ms, nullptr, nullptr);
    }
    const auto current_parameter =
        parameter_receiver.consume_current_parameter_delivery(
            parameter_delivery);
    const auto current_heartbeat =
        heartbeat_receiver.consume_current_sla(heartbeat_sla);
    if (!current_parameter.has_value() || !current_heartbeat.has_value()) {
      latch_abort(BulkEndReason::ReceiverEvidenceRevoked);
      return issue_poll_epoch(terminal_ack_received_ms, nullptr, nullptr);
    }
    return issue_poll_epoch(
        terminal_ack_received_ms,
        current_parameter.has_value() ? &*current_parameter : nullptr,
        current_heartbeat.has_value() ? &*current_heartbeat : nullptr);
  }

  BulkAction poll(std::uint32_t actual_now,
                  const ReceiverEvidencePollEpoch& epoch,
                  const NativeBulkInput& transport) noexcept {
    if (complete_) {
      return BulkAction::Complete;
    }

    if (!epoch.valid_ || epoch.session_id_ != session_id_ ||
        epoch.stream_id_ != stream_id_ || epoch.lease_id_ != lease_id_ ||
        poll_epoch_consumed_ ||
        epoch.sequence_ != poll_epoch_sequence_ ||
        epoch.receiver_events_drained_through_ms_ != actual_now ||
        !poll_time_is_forward(actual_now)) {
      latch_abort(BulkEndReason::EvidencePollOrderViolation);
    } else {
      poll_epoch_consumed_ = true;
      has_last_poll_ms_ = true;
      last_poll_ms_ = actual_now;
    }
    const std::uint32_t now = actual_now;

    if (heartbeat_deadline_missed(now)) {
      latch_abort(BulkEndReason::HeartbeatDeadlineMiss);
    }
    if (started_ && disposition_ == BulkDisposition::Running) {
      latch_stream_end(now, transport);
    } else if (!started_ &&
               disposition_ == BulkDisposition::Running &&
               clean_upstream_end(transport)) {
      latch_incomplete(BulkEndReason::UpstreamCompleteCountMismatch);
    }

    if (active_frame_) {
      return BulkAction::ContinueActiveFrame;
    }
    if (disposition_ == BulkDisposition::AbortPending) {
      return BulkAction::EndAbort;
    }
    if (heartbeat_pending_) {
      if (heartbeat_tail_bound_) {
        return BulkAction::WaitForHeartbeatDelivery;
      }
      if (!started_ || disposition_ != BulkDisposition::Running ||
          heartbeat_requires_service_before_frame(
              now, transport.estimated_worst_case_frame_service_ms)) {
        return BulkAction::SendHeartbeat;
      }
    }
    if (disposition_ == BulkDisposition::SuccessPending) {
      return BulkAction::EndSuccess;
    }
    if (disposition_ == BulkDisposition::IncompletePending) {
      return BulkAction::EndIncomplete;
    }
    if (!started_) {
      return BulkAction::WaitForFirstParam;
    }
    if (clean_upstream_end(transport) &&
        param_value_count_ == expected_param_count &&
        !final_param_delivery_on_time_) {
      return BulkAction::WaitForFinalParamDelivery;
    }
    if (transport.fifo_has_complete_frame) {
      return BulkAction::StartNextParamFrame;
    }
    return BulkAction::WaitForData;
  }

  bool commit_end() noexcept {
    if (complete_ || active_frame_ ||
        disposition_ == BulkDisposition::Running ||
        disposition_ == BulkDisposition::SuccessPending ||
        (disposition_ == BulkDisposition::IncompletePending &&
         heartbeat_pending_)) {
      return false;
    }
    if (disposition_ == BulkDisposition::IncompletePending) {
      disposition_ = BulkDisposition::Incomplete;
    } else {
      disposition_ = BulkDisposition::Aborted;
    }
    complete_ = true;
    return true;
  }

  bool commit_end(RemoteDeliveryLedger& receiver) noexcept {
    (void)receiver;
    return false;
  }

  bool commit_end(RemoteDeliveryLedger& receiver,
                  RemoteHeartbeatSlaLedger& heartbeat_receiver) noexcept {
    if (complete_ || active_frame_ || heartbeat_pending_ ||
        disposition_ != BulkDisposition::SuccessPending) {
      return false;
    }
    if (final_param_receiver_ != &receiver ||
        !receiver.terminal_state_is_current(
            final_param_receiver_revision_)) {
      latch_abort(BulkEndReason::ReceiverEvidenceRevoked);
      return false;
    }
    if (heartbeat_sla_receiver_ != &heartbeat_receiver ||
        !heartbeat_receiver.terminal_state_is_current(
            heartbeat_sla_receiver_revision_)) {
      latch_abort(BulkEndReason::ReceiverEvidenceRevoked);
      return false;
    }
    disposition_ = BulkDisposition::Success;
    complete_ = true;
    return true;
  }

  [[nodiscard]] bool heartbeat_deadline_missed(
      std::uint32_t now) const noexcept {
    return heartbeat_pending_ &&
           elapsed_ms(now, heartbeat_pending_since_ms_) >
               heartbeat_deadline_ms;
  }
  [[nodiscard]] bool active() const noexcept {
    return started_ && !complete_;
  }
  [[nodiscard]] bool heartbeat_pending() const noexcept {
    return heartbeat_pending_;
  }
  [[nodiscard]] std::uint64_t param_value_count() const noexcept {
    return param_value_count_;
  }
  [[nodiscard]] std::uint64_t session_id() const noexcept {
    return session_id_;
  }
  [[nodiscard]] std::uint64_t stream_id() const noexcept {
    return stream_id_;
  }
  [[nodiscard]] std::uint64_t lease_id() const noexcept {
    return lease_id_;
  }
  [[nodiscard]] std::uint64_t
  physically_committed_parameter_count() const noexcept {
    return physically_committed_param_count_;
  }
  [[nodiscard]] std::uint64_t
  physically_committed_parameter_chunks() const noexcept {
    return physically_committed_param_chunks_;
  }
  [[nodiscard]] std::uint64_t
  physically_committed_parameter_bytes() const noexcept {
    return physically_committed_param_bytes_;
  }
  [[nodiscard]] std::uint64_t late_param_loss_count() const noexcept {
    return late_param_loss_count_;
  }
  [[nodiscard]] bool hard_fault_latched() const noexcept {
    return hard_fault_latched_;
  }
  [[nodiscard]] bool counter_fault_latched() const noexcept {
    return counter_fault_latched_;
  }
  [[nodiscard]] BulkDisposition disposition() const noexcept {
    return disposition_;
  }
  [[nodiscard]] BulkEndReason end_reason() const noexcept {
    return end_reason_;
  }

 private:
  ReceiverEvidencePollEpoch issue_poll_epoch(
      std::uint32_t drained_through_ms,
      const ParameterStreamDeliveryProof* parameter_delivery,
      const RemoteHeartbeatSlaProof* heartbeat_sla) noexcept {
    if (poll_epoch_sequence_ ==
        std::numeric_limits<std::uint32_t>::max()) {
      counter_fault_latched_ = true;
      latch_abort(BulkEndReason::CounterOverflow);
      return {};
    }
    if (!epoch_time_is_forward(drained_through_ms)) {
      latch_abort(BulkEndReason::EvidencePollOrderViolation);
      return {};
    }
    bool final_applied = false;
    bool heartbeat_sla_applied = false;
    if (parameter_delivery != nullptr && parameter_delivery->valid()) {
      final_applied = confirm_final_parameter_delivery(
          *parameter_delivery, drained_through_ms);
    }
    if (heartbeat_sla != nullptr && heartbeat_sla->valid()) {
      heartbeat_sla_applied = confirm_remote_heartbeat_sla(*heartbeat_sla);
    }
    ++poll_epoch_sequence_;
    poll_epoch_consumed_ = false;
    has_last_epoch_ms_ = true;
    last_epoch_ms_ = drained_through_ms;
    return ReceiverEvidencePollEpoch(
        session_id_, stream_id_, lease_id_, poll_epoch_sequence_,
        drained_through_ms,
        false, final_applied, heartbeat_sla_applied);
  }

  [[nodiscard]] bool epoch_time_is_forward(std::uint32_t now) const noexcept {
    const bool after_last_epoch =
        !has_last_epoch_ms_ ||
        elapsed_ms(now, last_epoch_ms_) <=
            static_cast<std::uint32_t>(
                std::numeric_limits<std::int32_t>::max());
    const bool after_last_poll =
        !has_last_poll_ms_ ||
        elapsed_ms(now, last_poll_ms_) <=
            static_cast<std::uint32_t>(
                std::numeric_limits<std::int32_t>::max());
    return after_last_epoch && after_last_poll;
  }

  [[nodiscard]] bool poll_time_is_forward(std::uint32_t now) const noexcept {
    return !has_last_poll_ms_ ||
           elapsed_ms(now, last_poll_ms_) <=
               static_cast<std::uint32_t>(
                   std::numeric_limits<std::int32_t>::max());
  }

  [[nodiscard]] bool heartbeat_requires_service_before_frame(
      std::uint32_t now, std::uint32_t modeled_frame_service_ms) const
      noexcept {
    if (!heartbeat_pending_) {
      return false;
    }
    const std::uint32_t age =
        elapsed_ms(now, heartbeat_pending_since_ms_);
    const std::uint32_t reserve =
        required_heartbeat_reserve_ms(modeled_frame_service_ms);
    return reserve >= heartbeat_deadline_ms ||
           age >= heartbeat_deadline_ms - reserve;
  }

  [[nodiscard]] static bool clean_upstream_end(
      const NativeBulkInput& transport) noexcept {
    return transport.upstream_stream_complete &&
           !transport.fifo_has_complete_frame && !transport.parser_partial &&
           transport.queued_backlog == 0U;
  }

  [[nodiscard]] static bool transport_idle(
      const NativeBulkInput& transport) noexcept {
    return !transport.fifo_has_complete_frame && !transport.parser_partial &&
           transport.queued_backlog == 0U;
  }

  void latch_stream_end(std::uint32_t now,
                        const NativeBulkInput& transport) noexcept {
    const bool local_stream_fully_handed_off =
        param_value_count_ == expected_param_count &&
        physically_committed_param_count_ == expected_param_count &&
        physically_committed_param_chunks_ ==
            HighSpeedCandidateContract::expected_parameter_wire_chunks &&
        physically_committed_param_bytes_ ==
            HighSpeedCandidateContract::expected_parameter_wire_bytes;
    if (local_stream_fully_handed_off &&
        (!final_param_local_handoff_recorded_ ||
         elapsed_ms(final_param_local_handoff_ms_, first_param_ms_) >
             absolute_max_ms)) {
      latch_incomplete(BulkEndReason::FinalLocalHandoffAfterAbsoluteMax);
      return;
    }
    if (clean_upstream_end(transport)) {
      if (param_value_count_ != expected_param_count) {
        latch_incomplete(BulkEndReason::UpstreamCompleteCountMismatch);
        return;
      }
      // Upstream completion only closes ingress.  The admitted physical
      // stream may still be draining, so a clean 932-frame ingress must not
      // be reclassified as an incomplete transfer while its ordered permits
      // are still being consumed.
      if (physically_committed_param_count_ == expected_param_count &&
          physically_committed_param_chunks_ ==
              HighSpeedCandidateContract::expected_parameter_wire_chunks &&
          physically_committed_param_bytes_ ==
              HighSpeedCandidateContract::expected_parameter_wire_bytes &&
          final_param_delivery_on_time_ &&
          remote_heartbeat_sla_accepted_) {
        if (!active_frame_) {
          disposition_ = BulkDisposition::SuccessPending;
          end_reason_ = BulkEndReason::UpstreamComplete;
        }
        return;
      }
    }
    if (!local_stream_fully_handed_off &&
        elapsed_ms(now, first_param_ms_) > absolute_max_ms) {
      latch_incomplete(BulkEndReason::AbsoluteMaxIncomplete);
      return;
    }
    if (local_stream_fully_handed_off && !final_param_delivery_on_time_ &&
        ((terminal_ack_window_open_ &&
          elapsed_ms(now, terminal_ack_window_started_ms_) >
              terminal_ack_wait_ms) ||
         elapsed_ms(now, first_param_ms_) > terminal_session_limit_ms)) {
      latch_incomplete(BulkEndReason::TerminalAckTimeout);
      return;
    }
    if (param_value_count_ < expected_param_count &&
        transport_idle(transport) &&
        elapsed_ms(now, last_valid_param_ms_) >= inactivity_ms) {
      latch_incomplete(BulkEndReason::InactivityIncomplete);
    }
  }

  void latch_incomplete(BulkEndReason reason) noexcept {
    if (disposition_ == BulkDisposition::Running) {
      disposition_ = BulkDisposition::IncompletePending;
      end_reason_ = reason;
    }
  }

  void latch_abort(BulkEndReason reason) noexcept {
    hard_fault_latched_ = true;
    disposition_ = BulkDisposition::AbortPending;
    end_reason_ = reason;
  }

  void record_late_parameter_loss() noexcept {
    if (late_param_loss_count_ ==
        std::numeric_limits<std::uint64_t>::max()) {
      counter_fault_latched_ = true;
      hard_fault_latched_ = true;
      disposition_ = complete_ ? BulkDisposition::Aborted
                               : BulkDisposition::AbortPending;
      end_reason_ = BulkEndReason::CounterOverflow;
      return;
    }
    ++late_param_loss_count_;
    hard_fault_latched_ = true;
    disposition_ = complete_ ? BulkDisposition::Aborted
                             : BulkDisposition::AbortPending;
    end_reason_ = BulkEndReason::LateParamAfterExit;
  }

  bool started_ = false;
  bool complete_ = false;
  bool active_frame_ = false;
  std::uint64_t session_id_ = 0U;
  std::uint64_t stream_id_ = 0U;
  std::uint64_t lease_id_ = 0U;
  bool heartbeat_pending_ = false;
  bool heartbeat_tail_bound_ = false;
  std::uint32_t heartbeat_request_id_ = 0U;
  std::uint32_t heartbeat_local_handoff_count_ = 0U;
  std::uint32_t poll_epoch_sequence_ = 0U;
  bool poll_epoch_consumed_ = true;
  bool has_last_epoch_ms_ = false;
  std::uint32_t last_epoch_ms_ = 0U;
  bool has_last_poll_ms_ = false;
  std::uint32_t last_poll_ms_ = 0U;
  TransferToken heartbeat_tail_{};
  std::uint64_t physically_committed_param_count_ = 0U;
  std::uint64_t physically_committed_param_chunks_ = 0U;
  std::uint64_t physically_committed_param_bytes_ = 0U;
  bool has_physical_param_tail_ = false;
  std::uint32_t physical_param_generation_ = 0U;
  std::uint64_t physical_param_tail_ = 0U;
  TransferToken last_physical_param_token_{};
  bool has_physical_param_handoff_ms_ = false;
  std::uint32_t last_physical_param_handoff_ms_ = 0U;
  bool final_param_local_handoff_recorded_ = false;
  std::uint32_t final_param_local_handoff_ms_ = 0U;
  bool final_param_tail_bound_ = false;
  bool terminal_ack_window_open_ = false;
  std::uint32_t terminal_ack_window_started_ms_ = 0U;
  bool final_param_remote_arrived_ = false;
  bool final_param_delivery_on_time_ = false;
  TransferToken final_param_tail_{};
  std::uint32_t terminal_ack_received_ms_ = 0U;
  std::uint32_t ground_param_arrival_elapsed_ms_ = 0U;
  const RemoteDeliveryLedger* final_param_receiver_ = nullptr;
  std::uint64_t final_param_receiver_revision_ = 0U;
  bool remote_heartbeat_sla_accepted_ = false;
  const RemoteHeartbeatSlaLedger* heartbeat_sla_receiver_ = nullptr;
  std::uint64_t heartbeat_sla_receiver_revision_ = 0U;
  std::uint32_t first_param_ms_ = 0U;
  std::uint32_t last_valid_param_ms_ = 0U;
  std::uint32_t heartbeat_pending_since_ms_ = 0U;
  std::uint64_t param_value_count_ = 0U;
  std::uint64_t late_param_loss_count_ = 0U;
  bool hard_fault_latched_ = false;
  bool counter_fault_latched_ = false;
  BulkDisposition disposition_ = BulkDisposition::Running;
  BulkEndReason end_reason_ = BulkEndReason::None;
};

static_assert(E220UartAdmissionGate::max_chunk_bytes == 32U);
static_assert(E220UartAdmissionGate::max_buffered_bytes == 400U);
static_assert(NativeBulkDownlink::radio_buffer_payload_floor_ms == 167U);
static_assert(NativeBulkDownlink::heartbeat_reserve_floor_ms >=
              NativeBulkDownlink::radio_buffer_payload_floor_ms);
static_assert(NativeBulkDownlink::heartbeat_reserve_floor_ms <
              NativeBulkDownlink::heartbeat_deadline_ms);
static_assert(!transport_model_live_flash_authorized);

}  // namespace vc_lora::experimental
