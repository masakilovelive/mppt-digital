#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "vc_lora/bulk_negotiation_codec.hpp"
#include "vc_lora/mavlink_frame.hpp"

namespace vc_lora {

using BulkTranscriptDigest = std::array<std::uint8_t, 32U>;

enum class Sha256Status : std::uint8_t {
  Accepted = 0U,
  DigestReady,
  InvalidArgument,
  LengthOverflow,
  AlreadyFinalized,
  Latched,
};

// Fixed-storage incremental SHA-256. This primitive deliberately owns no
// allocator, clock, Arduino type, or platform resource.
class Sha256Accumulator final {
 public:
  Sha256Accumulator() noexcept { reset(); }
  Sha256Accumulator(const Sha256Accumulator&) = delete;
  Sha256Accumulator& operator=(const Sha256Accumulator&) = delete;
  Sha256Accumulator(Sha256Accumulator&&) = delete;
  Sha256Accumulator& operator=(Sha256Accumulator&&) = delete;

  void reset() noexcept;
  [[nodiscard]] Sha256Status update(const std::uint8_t* bytes,
                                    std::size_t size) noexcept;
  [[nodiscard]] Sha256Status finish(BulkTranscriptDigest& output) noexcept;

  [[nodiscard]] bool finalized() const noexcept { return finalized_; }
  [[nodiscard]] bool latched() const noexcept { return latched_; }

 private:
  void transform(const std::uint8_t* block) noexcept;
  [[nodiscard]] Sha256Status latch(Sha256Status status) noexcept;

  std::array<std::uint32_t, 8U> state_{};
  std::array<std::uint8_t, 64U> block_{};
  std::size_t block_size_{0U};
  std::uint64_t total_bytes_{0U};
  bool finalized_{false};
  bool latched_{false};
};

enum class BulkTranscriptStatus : std::uint8_t {
  Ready = 0U,
  EntryAccepted,
  Sealed,
  Rearmed,
  Aborted,
  InvalidConfiguration,
  InvalidMavlink,
  UnsupportedFrame,
  WrongParameterCount,
  WrongParameterIndex,
  ParameterOverflow,
  HeartbeatOverflow,
  IncompleteCorpus,
  PostSealData,
  SessionNotSealed,
  IdentityReuse,
  TransferTagReuse,
  DigestFailure,
  AlreadySealed,
  NoActiveSession,
  Latched,
};

// A trivially-copyable, read-only snapshot suitable for mapping into
// TerminalAckExpectedEvidence and TerminalAckRecord without sharing owner
// state. owner_sealed is the authority bit: a digest is terminal evidence only
// after a successful seal_session().
struct BulkTranscriptEvidence final {
  BulkNegotiationIdentity identity{};
  std::uint32_t transfer_tag{0U};
  std::uint32_t parameter_count{0U};
  std::uint32_t raw_parameter_bytes{0U};
  std::uint32_t heartbeat_count{0U};
  std::uint32_t last_heartbeat_request_id{0U};
  BulkTranscriptDigest digest{};
  bool owner_sealed{false};
};

// Long-lived explicit owner for one negotiated transcript epoch at a time.
// There is no implicit destructor abort: the embedding global/static owner
// must explicitly seal or abort, then rearm with a fresh identity and tag.
class BulkTranscriptLedger final {
 public:
  static constexpr std::uint16_t required_parameter_count() noexcept {
    return 932U;
  }
  static constexpr std::uint32_t required_raw_parameter_bytes() noexcept {
    return 34484U;
  }

  BulkTranscriptLedger() noexcept = default;
  BulkTranscriptLedger(const BulkNegotiationIdentity& identity,
                       std::uint32_t transfer_tag) noexcept;
  BulkTranscriptLedger(const BulkTranscriptLedger&) = delete;
  BulkTranscriptLedger& operator=(const BulkTranscriptLedger&) = delete;
  BulkTranscriptLedger(BulkTranscriptLedger&&) = delete;
  BulkTranscriptLedger& operator=(BulkTranscriptLedger&&) = delete;

  [[nodiscard]] BulkTranscriptStatus append(
      const MavlinkFrame& frame) noexcept;
  [[nodiscard]] BulkTranscriptStatus seal_session() noexcept;
  [[nodiscard]] BulkTranscriptStatus abort() noexcept;
  [[nodiscard]] BulkTranscriptStatus rearm(
      const BulkNegotiationIdentity& identity,
      std::uint32_t transfer_tag) noexcept;

  [[nodiscard]] BulkTranscriptEvidence evidence() const noexcept {
    return evidence_;
  }
  [[nodiscard]] bool active() const noexcept { return active_; }
  [[nodiscard]] bool sealed() const noexcept { return sealed_; }
  [[nodiscard]] bool latched() const noexcept { return latched_; }
  [[nodiscard]] BulkTranscriptStatus last_error() const noexcept {
    return last_error_;
  }

 private:
  [[nodiscard]] static bool identity_valid(
      const BulkNegotiationIdentity& identity) noexcept;
  [[nodiscard]] static bool identity_equal(
      const BulkNegotiationIdentity& left,
      const BulkNegotiationIdentity& right) noexcept;
  [[nodiscard]] BulkTranscriptStatus initialize(
      const BulkNegotiationIdentity& identity,
      std::uint32_t transfer_tag) noexcept;
  [[nodiscard]] BulkTranscriptStatus append_parameter(
      const MavlinkFrame& frame) noexcept;
  [[nodiscard]] BulkTranscriptStatus append_heartbeat(
      const MavlinkFrame& frame) noexcept;
  [[nodiscard]] bool hash_entry(std::uint8_t kind, std::uint32_t ordinal,
                                const MavlinkFrame& frame) noexcept;
  [[nodiscard]] BulkTranscriptStatus fail(
      BulkTranscriptStatus status) noexcept;
  void clear_completion_evidence() noexcept;

  Sha256Accumulator sha_{};
  BulkTranscriptEvidence evidence_{};
  bool active_{false};
  bool sealed_{false};
  bool latched_{false};
  BulkTranscriptStatus last_error_{BulkTranscriptStatus::Ready};
};

}  // namespace vc_lora
