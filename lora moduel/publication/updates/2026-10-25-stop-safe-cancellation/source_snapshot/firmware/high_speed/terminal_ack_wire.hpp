#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace vc_lora::experimental {

// Experimental, host-verified wire format only.  This file is deliberately
// not referenced by R18, core/, phase6/, or either accepted product sketch.
// It performs no UART, radio, profile, COM, or flash I/O.
//
// Each fragment is exactly 32 bytes:
//   0..3   ASCII "VCTA" (a separate magic from production VCTD)
//   4      wire version (1)
//   5      zero-based fragment index
//   6      fragment count (8)
//   7      flags (v1 requires zero)
//   8..11  record tag, little-endian uint32
//   12..29 canonical record bytes (fixed v1 payload length: 18)
//   30..31 CRC-16/CCITT-FALSE over bytes 0..29, little-endian
//
// Eight payloads form one exact 144-byte canonical record.  Its final four
// bytes are CRC-32C over bytes 0..139.  Fragment CRC detects local corruption;
// record CRC binds the reassembled order and all evidence fields.  Neither CRC
// is authentication.  The session/stream/lease plus two unpredictable nonces
// must be established by a separate authenticated-or-physically-trusted
// exchange and are consumed exactly once by the receiver.
//
// IMPORTANT INTEGRATION BLOCKER: production TddLinkDemux separates exact raw VCTD and VCTA
// candidates, but no phase6 consumer feeds VCTA fragments into
// TerminalAckReassembler or latches malformed/incomplete terminal evidence
// fail-closed.  The codec therefore remains disconnected from both accepted
// product entry points.  The 32-bit tag is only a fast assembly hint, defined
// as the XOR-fold of the
// canonical uint64 record ID. It is neither identity nor security; collisions
// are resolved by the canonical ID, full expected tuple, and whole-record CRC.
//
// 256 raw fragment bytes have a payload-only lower bound of 107 ms at
// 19.2 kbps. This is NOT the escaped product-path size: concatenated
// escape/rechunk is at least 288 bytes, while preserving each fragment boundary
// can require 512 bytes. The queue path is not implemented, so UART time,
// escaping policy, packet overhead, AUX/drain, guards, and the ACK window all
// remain unmeasured.

using TerminalAckFragment = std::array<std::uint8_t, 32U>;

struct TerminalAckIdentity final {
  std::uint64_t session_id = 0U;
  std::uint64_t stream_id = 0U;
  std::uint64_t lease_id = 0U;
  std::uint64_t ground_request_nonce = 0U;
  std::uint64_t vehicle_terminal_challenge_nonce = 0U;

  [[nodiscard]] constexpr bool operator==(
      const TerminalAckIdentity& other) const noexcept {
    return session_id == other.session_id && stream_id == other.stream_id &&
           lease_id == other.lease_id &&
           ground_request_nonce == other.ground_request_nonce &&
           vehicle_terminal_challenge_nonce ==
               other.vehicle_terminal_challenge_nonce;
  }

  [[nodiscard]] constexpr bool operator!=(
      const TerminalAckIdentity& other) const noexcept {
    return !(*this == other);
  }
};

struct TerminalAckRecord final {
  std::uint64_t record_id = 0U;
  TerminalAckIdentity identity{};

  // The next five fields are parameter-only terminal evidence. They exclude
  // VCB1 heartbeat fragments and VCTA terminal-ACK fragments. In particular,
  // final_global_chunk_ordinal is the parameter ledger's ordinal, distinct
  // from VCB1's interleaved transfer-global fragment ordinal on the air.
  std::uint32_t final_parameter_count = 0U;
  // Global zero-based ordinal of the final accepted PARAM wire chunk.  The
  // final parameter index is final_parameter_count - 1; it is intentionally
  // not duplicated on the wire.
  std::uint32_t final_global_chunk_ordinal = 0U;
  std::uint32_t raw_mavlink_bytes = 0U;
  std::uint32_t wire_chunk_count = 0U;
  std::uint32_t wire_bytes = 0U;
  // Ground-clock delta, never an absolute millis() value. The receiver
  // measures request arrival through the Ground USB commit of the final
  // complete PARAM frame with wrap-safe arithmetic. RF arrival or decoder
  // acceptance alone cannot terminate this interval.
  std::uint32_t request_to_last_parameter_elapsed_ms = 0U;

  std::uint32_t heartbeat_count = 0U;
  // Receiver-validated, transfer-local request IDs are exactly 1..N.  This is
  // not MAVLink's shared 8-bit sequence field.
  std::uint32_t last_heartbeat_request_id = 0U;
  // Ground RemoteHeartbeatSlaLedger deltas: baseline HB -> first in-stream HB,
  // maximum consecutive in-stream HB gap, and last in-stream HB -> final PARAM.
  std::uint32_t first_heartbeat_gap_ms = 0U;
  std::uint32_t max_heartbeat_gap_ms = 0U;
  std::uint32_t post_heartbeat_gap_ms = 0U;

  std::uint64_t receiver_batch = 0U;
  std::uint64_t receiver_revision = 0U;
  // SHA-256(domain || identity || entries), byte-exact as follows. Domain is
  // ASCII "VC-PARAM-HB-TRANSCRIPT", one 0x00 byte, ASCII "v1", and no trailing
  // NUL. Identity is LE64 session, stream, lease, Ground request nonce, then
  // Vehicle challenge nonce. Entries use the single Ground-observed event
  // order after parser validation. A PARAM entry is byte 'P', LE32 global
  // parameter index, LE16 frame length, then exact CRC-valid complete MAVLink
  // bytes before link escaping/padding. A heartbeat entry is byte 'H', LE32
  // transfer-local request ID, LE16 frame length, then exact heartbeat bytes.
  // Both peers hash the same canonical bytes incrementally. Plain SHA-256 is
  // not active-link authentication; a future keyed MAC must bind the complete
  // canonical terminal record (bytes 0..139), not only this digest.
  std::array<std::uint8_t, 32U> transcript_digest{};
};

// Vehicle-local values that a received record must match before it can become
// terminal evidence. Supplying only an identity is intentionally impossible:
// a CRC-valid but semantically false success record must fail closed. Batch and
// revision must be independently bound by the terminal challenge/ledger before
// reception; copying them from a decoded record is forbidden. The producer and
// the two ledger-revision mapping rules remain an explicit integration blocker.
struct TerminalAckExpectedEvidence final {
  // Independently derived from the complete five-value identity. This makes
  // the record epoch exact rather than accepting any value above replay floor.
  std::uint64_t expected_record_id = 0U;
  TerminalAckIdentity identity{};
  std::uint32_t final_parameter_count = 0U;
  std::uint32_t final_global_chunk_ordinal = 0U;
  std::uint32_t raw_mavlink_bytes = 0U;
  std::uint32_t wire_chunk_count = 0U;
  std::uint32_t wire_bytes = 0U;
  std::uint32_t maximum_request_to_last_parameter_elapsed_ms = 0U;
  std::uint32_t heartbeat_count = 0U;
  std::uint32_t last_heartbeat_request_id = 0U;
  std::uint32_t maximum_heartbeat_gap_ms = 0U;
  std::uint64_t receiver_batch = 0U;
  std::uint64_t receiver_revision = 0U;
  std::array<std::uint8_t, 32U> transcript_digest{};
};

enum class TerminalAckError : std::uint8_t {
  None = 0U,
  InvalidRecord,
  UnknownMagic,
  UnknownVersion,
  InvalidFlags,
  BadFragmentCrc,
  BadFragmentCount,
  BadPayloadLength,
  StaleReplay,
  ReorderedFragment,
  DuplicateFragment,
  MixedRecord,
  Overflow,
  BadWholeRecordCrc,
  WrongSession,
  WrongStream,
  WrongLease,
  WrongRequestNonce,
  WrongChallengeNonce,
  WrongRecordId,
  ParameterEvidenceMismatch,
  ParameterDeadlineExceeded,
  HeartbeatEvidenceMismatch,
  HeartbeatDeadlineExceeded,
  ReceiverBatchMismatch,
  ReceiverRevisionMismatch,
  TranscriptDigestMismatch,
  MissingFragment,
  AlreadyComplete,
  AlreadyConsumed,
  Latched,
};

class TerminalAckWireCodec final {
 public:
  static constexpr std::size_t fragment_bytes = 32U;
  static constexpr std::size_t fragment_payload_bytes = 18U;
  static constexpr std::size_t record_bytes = 144U;
  static constexpr std::size_t record_integrity_offset = 140U;
  static constexpr std::size_t fragment_count =
      record_bytes / fragment_payload_bytes;
  static constexpr std::uint8_t version = 1U;
  static constexpr std::uint8_t required_flags = 0U;
  static constexpr std::uint32_t radio_bits_per_second = 19200U;
  // Parameter-only terminal evidence; heartbeat and VCTA wire traffic is
  // deliberately excluded from these five fixed accepted-corpus values.
  static constexpr std::uint32_t required_parameter_count = 932U;
  static constexpr std::uint32_t required_final_global_chunk_ordinal = 1863U;
  static constexpr std::uint32_t required_raw_mavlink_bytes = 34484U;
  static constexpr std::uint32_t required_wire_chunk_count = 1864U;
  static constexpr std::uint32_t required_wire_bytes = 59648U;
  static constexpr std::uint32_t parameter_deadline_ms = 30000U;
  static constexpr std::uint32_t heartbeat_deadline_ms = 2500U;
  static constexpr std::uint32_t raw_fragment_airtime_lower_bound_ms =
      static_cast<std::uint32_t>(
          (fragment_count * fragment_bytes * 8U * 1000U +
           radio_bits_per_second - 1U) /
          radio_bits_per_second);

  using RecordBytes = std::array<std::uint8_t, record_bytes>;

  [[nodiscard]] static TerminalAckError encode(
      const TerminalAckRecord& record,
      std::array<TerminalAckFragment, fragment_count>& output) noexcept {
    const TerminalAckError validation = validate_record(record);
    if (validation != TerminalAckError::None) {
      return validation;
    }

    RecordBytes canonical{};
    encode_record_without_integrity(record, canonical);
    put_u32(canonical, record_integrity_offset,
            crc32c_record_prefix(canonical));

    std::array<TerminalAckFragment, fragment_count> candidate{};
    for (std::size_t fragment_index = 0U;
         fragment_index < fragment_count; ++fragment_index) {
      TerminalAckFragment fragment{};
      fragment[0] = static_cast<std::uint8_t>('V');
      fragment[1] = static_cast<std::uint8_t>('C');
      fragment[2] = static_cast<std::uint8_t>('T');
      fragment[3] = static_cast<std::uint8_t>('A');
      fragment[4] = version;
      fragment[5] = static_cast<std::uint8_t>(fragment_index);
      fragment[6] = static_cast<std::uint8_t>(fragment_count);
      fragment[7] = required_flags;
      put_u32(fragment, 8U, record_tag(record.record_id));

      const std::size_t record_offset =
          fragment_index * fragment_payload_bytes;
      for (std::size_t payload_index = 0U;
           payload_index < fragment_payload_bytes; ++payload_index) {
        fragment[12U + payload_index] =
            canonical[record_offset + payload_index];
      }
      put_u16(fragment, 30U, crc16_fragment_prefix(fragment));
      candidate[fragment_index] = fragment;
    }
    output = candidate;
    return TerminalAckError::None;
  }

  [[nodiscard]] static constexpr bool identity_is_valid(
      const TerminalAckIdentity& identity) noexcept {
    return identity.session_id != 0U && identity.stream_id != 0U &&
           identity.lease_id != 0U &&
           identity.ground_request_nonce != 0U &&
           identity.vehicle_terminal_challenge_nonce != 0U;
  }

  [[nodiscard]] static constexpr std::uint32_t record_tag(
      std::uint64_t record_id) noexcept {
    return static_cast<std::uint32_t>(record_id & 0xFFFFFFFFULL) ^
           static_cast<std::uint32_t>(record_id >> 32U);
  }

  [[nodiscard]] static bool expected_evidence_is_valid(
      const TerminalAckExpectedEvidence& expected) noexcept {
    return expected.expected_record_id != 0U &&
           identity_is_valid(expected.identity) &&
           expected.final_parameter_count == required_parameter_count &&
           expected.final_global_chunk_ordinal ==
               required_final_global_chunk_ordinal &&
           expected.raw_mavlink_bytes == required_raw_mavlink_bytes &&
           expected.wire_chunk_count == required_wire_chunk_count &&
           expected.wire_bytes == required_wire_bytes &&
           expected.maximum_request_to_last_parameter_elapsed_ms ==
               parameter_deadline_ms &&
           expected.heartbeat_count != 0U &&
           expected.last_heartbeat_request_id == expected.heartbeat_count &&
           expected.maximum_heartbeat_gap_ms == heartbeat_deadline_ms &&
           expected.receiver_batch != 0U &&
           expected.receiver_revision != 0U &&
           digest_is_nonzero(expected.transcript_digest);
  }

  template <std::size_t Size>
  [[nodiscard]] static std::uint16_t crc16_ccitt_false(
      const std::array<std::uint8_t, Size>& bytes,
      std::size_t length) noexcept {
    if (length > Size) {
      return 0U;
    }
    std::uint16_t crc = 0xFFFFU;
    for (std::size_t index = 0U; index < length; ++index) {
      crc ^= static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(bytes[index]) << 8U);
      for (std::uint8_t bit = 0U; bit < 8U; ++bit) {
        crc = (crc & 0x8000U) != 0U
                  ? static_cast<std::uint16_t>(
                        (static_cast<std::uint32_t>(crc) << 1U) ^
                        0x1021U)
                  : static_cast<std::uint16_t>(
                        static_cast<std::uint32_t>(crc) << 1U);
      }
    }
    return crc;
  }

  template <std::size_t Size>
  [[nodiscard]] static std::uint32_t crc32c(
      const std::array<std::uint8_t, Size>& bytes,
      std::size_t length) noexcept {
    if (length > Size) {
      return 0U;
    }
    std::uint32_t crc = 0xFFFFFFFFU;
    for (std::size_t index = 0U; index < length; ++index) {
      crc ^= static_cast<std::uint32_t>(bytes[index]);
      for (std::uint8_t bit = 0U; bit < 8U; ++bit) {
        const std::uint32_t mask =
            0U - static_cast<std::uint32_t>(crc & 1U);
        crc = (crc >> 1U) ^ (0x82F63B78U & mask);
      }
    }
    return ~crc;
  }

 private:
  friend class TerminalAckReassembler;

  template <std::size_t Size>
  static void put_u16(std::array<std::uint8_t, Size>& bytes,
                      std::size_t offset, std::uint16_t value) noexcept {
    bytes[offset] = static_cast<std::uint8_t>(value & 0xFFU);
    bytes[offset + 1U] =
        static_cast<std::uint8_t>((value >> 8U) & 0xFFU);
  }

  template <std::size_t Size>
  static void put_u32(std::array<std::uint8_t, Size>& bytes,
                      std::size_t offset, std::uint32_t value) noexcept {
    bytes[offset] = static_cast<std::uint8_t>(value & 0xFFU);
    bytes[offset + 1U] =
        static_cast<std::uint8_t>((value >> 8U) & 0xFFU);
    bytes[offset + 2U] =
        static_cast<std::uint8_t>((value >> 16U) & 0xFFU);
    bytes[offset + 3U] =
        static_cast<std::uint8_t>((value >> 24U) & 0xFFU);
  }

  template <std::size_t Size>
  static void put_u64(std::array<std::uint8_t, Size>& bytes,
                      std::size_t offset, std::uint64_t value) noexcept {
    for (std::size_t index = 0U; index < 8U; ++index) {
      const std::size_t shift = index * 8U;
      bytes[offset + index] = static_cast<std::uint8_t>(
          (value >> static_cast<unsigned int>(shift)) & 0xFFU);
    }
  }

  template <std::size_t Size>
  [[nodiscard]] static std::uint16_t get_u16(
      const std::array<std::uint8_t, Size>& bytes,
      std::size_t offset) noexcept {
    return static_cast<std::uint16_t>(
        static_cast<std::uint16_t>(bytes[offset]) |
        static_cast<std::uint16_t>(
            static_cast<std::uint16_t>(bytes[offset + 1U]) << 8U));
  }

  template <std::size_t Size>
  [[nodiscard]] static std::uint32_t get_u32(
      const std::array<std::uint8_t, Size>& bytes,
      std::size_t offset) noexcept {
    return static_cast<std::uint32_t>(bytes[offset]) |
           (static_cast<std::uint32_t>(bytes[offset + 1U]) << 8U) |
           (static_cast<std::uint32_t>(bytes[offset + 2U]) << 16U) |
           (static_cast<std::uint32_t>(bytes[offset + 3U]) << 24U);
  }

  template <std::size_t Size>
  [[nodiscard]] static std::uint64_t get_u64(
      const std::array<std::uint8_t, Size>& bytes,
      std::size_t offset) noexcept {
    std::uint64_t value = 0U;
    for (std::size_t index = 0U; index < 8U; ++index) {
      const std::size_t shift = index * 8U;
      value |= static_cast<std::uint64_t>(bytes[offset + index])
               << static_cast<unsigned int>(shift);
    }
    return value;
  }

  [[nodiscard]] static std::uint16_t crc16_fragment_prefix(
      const TerminalAckFragment& fragment) noexcept {
    return crc16_ccitt_false(fragment, 30U);
  }

  [[nodiscard]] static std::uint32_t crc32c_record_prefix(
      const RecordBytes& bytes) noexcept {
    return crc32c(bytes, record_integrity_offset);
  }

  [[nodiscard]] static bool digest_is_nonzero(
      const std::array<std::uint8_t, 32U>& digest) noexcept {
    std::uint8_t aggregate = 0U;
    for (const std::uint8_t byte : digest) {
      aggregate = static_cast<std::uint8_t>(aggregate | byte);
    }
    return aggregate != 0U;
  }

  [[nodiscard]] static TerminalAckError validate_record(
      const TerminalAckRecord& record) noexcept {
    if (record.record_id == 0U || !identity_is_valid(record.identity) ||
        record.final_parameter_count == 0U ||
        record.wire_chunk_count == 0U || record.raw_mavlink_bytes == 0U ||
        record.wire_bytes == 0U || record.heartbeat_count == 0U ||
        record.receiver_batch == 0U || record.receiver_revision == 0U ||
        !digest_is_nonzero(record.transcript_digest)) {
      return TerminalAckError::InvalidRecord;
    }
    constexpr std::uint32_t bytes_per_wire_chunk = 32U;
    if (record.wire_chunk_count >
        std::numeric_limits<std::uint32_t>::max() /
            bytes_per_wire_chunk) {
      return TerminalAckError::Overflow;
    }
    if (record.final_global_chunk_ordinal !=
            record.wire_chunk_count - 1U ||
        record.last_heartbeat_request_id != record.heartbeat_count ||
        record.wire_bytes !=
            record.wire_chunk_count * bytes_per_wire_chunk) {
      return TerminalAckError::InvalidRecord;
    }
    if (record.final_parameter_count != required_parameter_count ||
        record.final_global_chunk_ordinal !=
            required_final_global_chunk_ordinal ||
        record.raw_mavlink_bytes != required_raw_mavlink_bytes ||
        record.wire_chunk_count != required_wire_chunk_count ||
        record.wire_bytes != required_wire_bytes) {
      return TerminalAckError::ParameterEvidenceMismatch;
    }
    if (record.request_to_last_parameter_elapsed_ms >
        parameter_deadline_ms) {
      return TerminalAckError::ParameterDeadlineExceeded;
    }
    if (record.first_heartbeat_gap_ms > heartbeat_deadline_ms ||
        record.max_heartbeat_gap_ms > heartbeat_deadline_ms ||
        record.post_heartbeat_gap_ms > heartbeat_deadline_ms) {
      return TerminalAckError::HeartbeatDeadlineExceeded;
    }
    return TerminalAckError::None;
  }

  static void encode_record_without_integrity(
      const TerminalAckRecord& record, RecordBytes& bytes) noexcept {
    put_u64(bytes, 0U, record.record_id);
    put_u64(bytes, 8U, record.identity.session_id);
    put_u64(bytes, 16U, record.identity.stream_id);
    put_u64(bytes, 24U, record.identity.lease_id);
    put_u64(bytes, 32U, record.identity.ground_request_nonce);
    put_u64(bytes, 40U,
            record.identity.vehicle_terminal_challenge_nonce);
    put_u32(bytes, 48U, record.final_parameter_count);
    put_u32(bytes, 52U, record.final_global_chunk_ordinal);
    put_u32(bytes, 56U, record.raw_mavlink_bytes);
    put_u32(bytes, 60U, record.wire_chunk_count);
    put_u32(bytes, 64U, record.wire_bytes);
    put_u32(bytes, 68U, record.request_to_last_parameter_elapsed_ms);
    put_u32(bytes, 72U, record.heartbeat_count);
    put_u32(bytes, 76U, record.last_heartbeat_request_id);
    put_u32(bytes, 80U, record.first_heartbeat_gap_ms);
    put_u32(bytes, 84U, record.max_heartbeat_gap_ms);
    put_u32(bytes, 88U, record.post_heartbeat_gap_ms);
    put_u64(bytes, 92U, record.receiver_batch);
    put_u64(bytes, 100U, record.receiver_revision);
    for (std::size_t index = 0U; index < record.transcript_digest.size();
         ++index) {
      bytes[108U + index] = record.transcript_digest[index];
    }
  }

  [[nodiscard]] static TerminalAckError decode_record(
      const RecordBytes& bytes, TerminalAckRecord& output) noexcept {
    const std::uint32_t expected_integrity = get_u32(
        bytes, record_integrity_offset);
    if (expected_integrity != crc32c_record_prefix(bytes)) {
      return TerminalAckError::BadWholeRecordCrc;
    }

    TerminalAckRecord candidate{};
    candidate.record_id = get_u64(bytes, 0U);
    candidate.identity.session_id = get_u64(bytes, 8U);
    candidate.identity.stream_id = get_u64(bytes, 16U);
    candidate.identity.lease_id = get_u64(bytes, 24U);
    candidate.identity.ground_request_nonce = get_u64(bytes, 32U);
    candidate.identity.vehicle_terminal_challenge_nonce =
        get_u64(bytes, 40U);
    candidate.final_parameter_count = get_u32(bytes, 48U);
    candidate.final_global_chunk_ordinal = get_u32(bytes, 52U);
    candidate.raw_mavlink_bytes = get_u32(bytes, 56U);
    candidate.wire_chunk_count = get_u32(bytes, 60U);
    candidate.wire_bytes = get_u32(bytes, 64U);
    candidate.request_to_last_parameter_elapsed_ms = get_u32(bytes, 68U);
    candidate.heartbeat_count = get_u32(bytes, 72U);
    candidate.last_heartbeat_request_id = get_u32(bytes, 76U);
    candidate.first_heartbeat_gap_ms = get_u32(bytes, 80U);
    candidate.max_heartbeat_gap_ms = get_u32(bytes, 84U);
    candidate.post_heartbeat_gap_ms = get_u32(bytes, 88U);
    candidate.receiver_batch = get_u64(bytes, 92U);
    candidate.receiver_revision = get_u64(bytes, 100U);
    for (std::size_t index = 0U; index < candidate.transcript_digest.size();
         ++index) {
      candidate.transcript_digest[index] = bytes[108U + index];
    }

    const TerminalAckError validation = validate_record(candidate);
    if (validation != TerminalAckError::None) {
      return validation;
    }
    output = candidate;
    return TerminalAckError::None;
  }
};

using TerminalAckFragments =
    std::array<TerminalAckFragment, TerminalAckWireCodec::fragment_count>;

class TerminalAckReassembler final {
 public:
  // One instance consumes at most one challenge/lease. There is deliberately
  // no reset: a new transfer requires a new independently established identity
  // and a new instance. The caller must invoke finish() at its finite terminal
  // window deadline; this clock-free codec then hard-latches MissingFragment.
  // last_accepted_record_id is a persistent replay floor scoped to the exact
  // expected session/stream/lease/nonces, never a global floor. At UINT64_MAX
  // that identity remains permanently closed; the caller must rotate lease and
  // both nonces rather than wrap or reuse the identity.
  explicit TerminalAckReassembler(
      TerminalAckExpectedEvidence expected,
      std::uint64_t last_accepted_record_id = 0U) noexcept
      : expected_(expected),
        last_accepted_record_id_(last_accepted_record_id) {
    if (!TerminalAckWireCodec::expected_evidence_is_valid(expected_)) {
      error_ = TerminalAckError::InvalidRecord;
      failed_ = true;
    }
  }

  TerminalAckReassembler(const TerminalAckReassembler&) = delete;
  TerminalAckReassembler& operator=(const TerminalAckReassembler&) = delete;
  TerminalAckReassembler(TerminalAckReassembler&&) = delete;
  TerminalAckReassembler& operator=(TerminalAckReassembler&&) = delete;

  [[nodiscard]] TerminalAckError push(
      const TerminalAckFragment& fragment) noexcept {
    if (failed_) {
      return TerminalAckError::Latched;
    }
    if (complete_) {
      return consumed_ ? TerminalAckError::AlreadyConsumed
                       : TerminalAckError::AlreadyComplete;
    }

    if (fragment[0] != static_cast<std::uint8_t>('V') ||
        fragment[1] != static_cast<std::uint8_t>('C') ||
        fragment[2] != static_cast<std::uint8_t>('T') ||
        fragment[3] != static_cast<std::uint8_t>('A')) {
      return fail(TerminalAckError::UnknownMagic);
    }
    // Once the full magic routes the frame to VCTA, CRC covers every remaining
    // header and payload bit before any semantic interpretation.
    if (TerminalAckWireCodec::get_u16(fragment, 30U) !=
        TerminalAckWireCodec::crc16_fragment_prefix(fragment)) {
      return fail(TerminalAckError::BadFragmentCrc);
    }
    if (fragment[4] != TerminalAckWireCodec::version) {
      return fail(TerminalAckError::UnknownVersion);
    }
    if (fragment[7] != TerminalAckWireCodec::required_flags) {
      return fail(TerminalAckError::InvalidFlags);
    }

    const std::size_t supplied_count =
        static_cast<std::size_t>(fragment[6]);
    if (supplied_count > TerminalAckWireCodec::fragment_count) {
      return fail(TerminalAckError::Overflow);
    }
    if (supplied_count != TerminalAckWireCodec::fragment_count) {
      return fail(TerminalAckError::BadFragmentCount);
    }
    const std::size_t fragment_index =
        static_cast<std::size_t>(fragment[5]);
    if (fragment_index >= TerminalAckWireCodec::fragment_count) {
      return fail(TerminalAckError::Overflow);
    }
    const std::uint32_t supplied_record_tag =
        TerminalAckWireCodec::get_u32(fragment, 8U);

    if (next_fragment_index_ == 0U) {
      if (fragment_index != 0U) {
        return fail(TerminalAckError::ReorderedFragment);
      }
      const std::uint64_t supplied_record_id =
          TerminalAckWireCodec::get_u64(fragment, 12U);
      if (supplied_record_id == 0U) {
        return fail(TerminalAckError::InvalidRecord);
      }
      if (supplied_record_tag !=
          TerminalAckWireCodec::record_tag(supplied_record_id)) {
        return fail(TerminalAckError::MixedRecord);
      }
      if (supplied_record_id <= last_accepted_record_id_) {
        return fail(TerminalAckError::StaleReplay);
      }
      active_record_id_ = supplied_record_id;
      active_record_tag_ = supplied_record_tag;
    } else {
      if (supplied_record_tag != active_record_tag_) {
        return fail(TerminalAckError::MixedRecord);
      }
      if (fragment_index < next_fragment_index_) {
        return fail(TerminalAckError::DuplicateFragment);
      }
      if (fragment_index > next_fragment_index_) {
        return fail(TerminalAckError::ReorderedFragment);
      }
    }

    const std::size_t record_offset =
        fragment_index * TerminalAckWireCodec::fragment_payload_bytes;
    if (record_offset > TerminalAckWireCodec::record_bytes ||
        TerminalAckWireCodec::fragment_payload_bytes >
            TerminalAckWireCodec::record_bytes - record_offset) {
      return fail(TerminalAckError::Overflow);
    }
    for (std::size_t payload_index = 0U;
         payload_index < TerminalAckWireCodec::fragment_payload_bytes;
         ++payload_index) {
      assembled_[record_offset + payload_index] =
          fragment[12U + payload_index];
    }
    ++next_fragment_index_;

    if (next_fragment_index_ != TerminalAckWireCodec::fragment_count) {
      return TerminalAckError::None;
    }

    TerminalAckRecord candidate{};
    const TerminalAckError decode_result =
        TerminalAckWireCodec::decode_record(assembled_, candidate);
    if (decode_result != TerminalAckError::None) {
      return fail(decode_result);
    }
    if (candidate.record_id != active_record_id_) {
      return fail(TerminalAckError::MixedRecord);
    }
    if (candidate.record_id != expected_.expected_record_id) {
      return fail(TerminalAckError::WrongRecordId);
    }
    if (candidate.identity.session_id != expected_.identity.session_id) {
      return fail(TerminalAckError::WrongSession);
    }
    if (candidate.identity.stream_id != expected_.identity.stream_id) {
      return fail(TerminalAckError::WrongStream);
    }
    if (candidate.identity.lease_id != expected_.identity.lease_id) {
      return fail(TerminalAckError::WrongLease);
    }
    if (candidate.identity.ground_request_nonce !=
        expected_.identity.ground_request_nonce) {
      return fail(TerminalAckError::WrongRequestNonce);
    }
    if (candidate.identity.vehicle_terminal_challenge_nonce !=
        expected_.identity.vehicle_terminal_challenge_nonce) {
      return fail(TerminalAckError::WrongChallengeNonce);
    }
    if (candidate.final_parameter_count !=
            expected_.final_parameter_count ||
        candidate.final_global_chunk_ordinal !=
            expected_.final_global_chunk_ordinal ||
        candidate.raw_mavlink_bytes != expected_.raw_mavlink_bytes ||
        candidate.wire_chunk_count != expected_.wire_chunk_count ||
        candidate.wire_bytes != expected_.wire_bytes) {
      return fail(TerminalAckError::ParameterEvidenceMismatch);
    }
    if (candidate.request_to_last_parameter_elapsed_ms >
        expected_.maximum_request_to_last_parameter_elapsed_ms) {
      return fail(TerminalAckError::ParameterDeadlineExceeded);
    }
    if (candidate.heartbeat_count != expected_.heartbeat_count ||
        candidate.last_heartbeat_request_id !=
            expected_.last_heartbeat_request_id) {
      return fail(TerminalAckError::HeartbeatEvidenceMismatch);
    }
    if (candidate.first_heartbeat_gap_ms >
            expected_.maximum_heartbeat_gap_ms ||
        candidate.max_heartbeat_gap_ms >
            expected_.maximum_heartbeat_gap_ms ||
        candidate.post_heartbeat_gap_ms >
            expected_.maximum_heartbeat_gap_ms) {
      return fail(TerminalAckError::HeartbeatDeadlineExceeded);
    }
    if (candidate.receiver_batch != expected_.receiver_batch) {
      return fail(TerminalAckError::ReceiverBatchMismatch);
    }
    if (candidate.receiver_revision != expected_.receiver_revision) {
      return fail(TerminalAckError::ReceiverRevisionMismatch);
    }
    if (candidate.transcript_digest != expected_.transcript_digest) {
      return fail(TerminalAckError::TranscriptDigestMismatch);
    }

    record_ = candidate;
    last_accepted_record_id_ = active_record_id_;
    complete_ = true;
    return TerminalAckError::None;
  }

  [[nodiscard]] TerminalAckError finish() noexcept {
    if (failed_) {
      return TerminalAckError::Latched;
    }
    if (!complete_) {
      return fail(TerminalAckError::MissingFragment);
    }
    return consumed_ ? TerminalAckError::AlreadyConsumed
                     : TerminalAckError::None;
  }

  [[nodiscard]] bool take_record(TerminalAckRecord& output) noexcept {
    if (!complete_ || failed_ || consumed_) {
      return false;
    }
    output = record_;
    record_ = TerminalAckRecord{};
    assembled_.fill(0U);
    consumed_ = true;
    return true;
  }

  [[nodiscard]] constexpr bool complete() const noexcept {
    return complete_ && !failed_;
  }

  [[nodiscard]] constexpr bool failed() const noexcept { return failed_; }

  [[nodiscard]] constexpr TerminalAckError error() const noexcept {
    return error_;
  }

  [[nodiscard]] constexpr std::uint64_t last_accepted_record_id()
      const noexcept {
    return last_accepted_record_id_;
  }

 private:
  [[nodiscard]] TerminalAckError fail(TerminalAckError error) noexcept {
    error_ = error;
    failed_ = true;
    complete_ = false;
    return error;
  }

  TerminalAckExpectedEvidence expected_{};
  std::uint64_t last_accepted_record_id_ = 0U;
  std::uint64_t active_record_id_ = 0U;
  std::uint32_t active_record_tag_ = 0U;
  std::size_t next_fragment_index_ = 0U;
  TerminalAckWireCodec::RecordBytes assembled_{};
  TerminalAckRecord record_{};
  TerminalAckError error_ = TerminalAckError::None;
  bool complete_ = false;
  bool failed_ = false;
  bool consumed_ = false;
};

static_assert(TerminalAckWireCodec::record_bytes %
                      TerminalAckWireCodec::fragment_payload_bytes ==
                  0U,
              "The canonical record must fill all fragments exactly.");
static_assert(TerminalAckWireCodec::fragment_count == 8U);
static_assert(TerminalAckWireCodec::raw_fragment_airtime_lower_bound_ms ==
              107U);
static_assert(sizeof(TerminalAckFragment) ==
              TerminalAckWireCodec::fragment_bytes);

}  // namespace vc_lora::experimental
