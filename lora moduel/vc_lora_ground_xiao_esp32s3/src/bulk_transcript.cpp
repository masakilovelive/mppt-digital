#include "vc_lora/bulk_transcript.hpp"

#include <algorithm>
#include <array>
#include <limits>

namespace vc_lora {
namespace {

constexpr std::array<std::uint32_t, 64U> kSha256RoundConstants{{
    0x428A2F98U, 0x71374491U, 0xB5C0FBCFU, 0xE9B5DBA5U,
    0x3956C25BU, 0x59F111F1U, 0x923F82A4U, 0xAB1C5ED5U,
    0xD807AA98U, 0x12835B01U, 0x243185BEU, 0x550C7DC3U,
    0x72BE5D74U, 0x80DEB1FEU, 0x9BDC06A7U, 0xC19BF174U,
    0xE49B69C1U, 0xEFBE4786U, 0x0FC19DC6U, 0x240CA1CCU,
    0x2DE92C6FU, 0x4A7484AAU, 0x5CB0A9DCU, 0x76F988DAU,
    0x983E5152U, 0xA831C66DU, 0xB00327C8U, 0xBF597FC7U,
    0xC6E00BF3U, 0xD5A79147U, 0x06CA6351U, 0x14292967U,
    0x27B70A85U, 0x2E1B2138U, 0x4D2C6DFCU, 0x53380D13U,
    0x650A7354U, 0x766A0ABBU, 0x81C2C92EU, 0x92722C85U,
    0xA2BFE8A1U, 0xA81A664BU, 0xC24B8B70U, 0xC76C51A3U,
    0xD192E819U, 0xD6990624U, 0xF40E3585U, 0x106AA070U,
    0x19A4C116U, 0x1E376C08U, 0x2748774CU, 0x34B0BCB5U,
    0x391C0CB3U, 0x4ED8AA4AU, 0x5B9CCA4FU, 0x682E6FF3U,
    0x748F82EEU, 0x78A5636FU, 0x84C87814U, 0x8CC70208U,
    0x90BEFFFAU, 0xA4506CEBU, 0xBEF9A3F7U, 0xC67178F2U,
}};

constexpr std::array<std::uint8_t, 25U> kTranscriptDomain{{
    'V', 'C', '-', 'P', 'A', 'R', 'A', 'M', '-', 'H', 'B', '-', 'T',
    'R', 'A', 'N', 'S', 'C', 'R', 'I', 'P', 'T', 0x00U, 'v', '1',
}};

constexpr std::uint32_t rotate_right(std::uint32_t value,
                                     unsigned int count) noexcept {
  return (value >> count) | (value << (32U - count));
}

template <std::size_t Size>
void put_u16_le(std::array<std::uint8_t, Size>& bytes, std::size_t offset,
                std::uint16_t value) noexcept {
  bytes[offset] = static_cast<std::uint8_t>(value & 0xFFU);
  bytes[offset + 1U] = static_cast<std::uint8_t>((value >> 8U) & 0xFFU);
}

template <std::size_t Size>
void put_u32_le(std::array<std::uint8_t, Size>& bytes, std::size_t offset,
                std::uint32_t value) noexcept {
  for (std::size_t index = 0U; index < 4U; ++index) {
    bytes[offset + index] = static_cast<std::uint8_t>(
        (value >> static_cast<unsigned int>(index * 8U)) & 0xFFU);
  }
}

template <std::size_t Size>
void put_u64_le(std::array<std::uint8_t, Size>& bytes, std::size_t offset,
                std::uint64_t value) noexcept {
  for (std::size_t index = 0U; index < 8U; ++index) {
    bytes[offset + index] = static_cast<std::uint8_t>(
        (value >> static_cast<unsigned int>(index * 8U)) & 0xFFU);
  }
}

std::uint16_t payload_u16(const MavlinkFrame& frame,
                          std::size_t offset) noexcept {
  return static_cast<std::uint16_t>(frame.payload()[offset]) |
         static_cast<std::uint16_t>(
             static_cast<std::uint16_t>(frame.payload()[offset + 1U]) << 8U);
}

}  // namespace

void Sha256Accumulator::reset() noexcept {
  state_ = {{0x6A09E667U, 0xBB67AE85U, 0x3C6EF372U, 0xA54FF53AU,
             0x510E527FU, 0x9B05688CU, 0x1F83D9ABU, 0x5BE0CD19U}};
  block_.fill(0U);
  block_size_ = 0U;
  total_bytes_ = 0U;
  finalized_ = false;
  latched_ = false;
}

Sha256Status Sha256Accumulator::latch(Sha256Status status) noexcept {
  latched_ = true;
  return status;
}

Sha256Status Sha256Accumulator::update(const std::uint8_t* bytes,
                                       std::size_t size) noexcept {
  if (latched_) {
    return Sha256Status::Latched;
  }
  if (finalized_) {
    return Sha256Status::AlreadyFinalized;
  }
  if (bytes == nullptr && size != 0U) {
    return latch(Sha256Status::InvalidArgument);
  }

  constexpr std::uint64_t kMaximumBytes =
      std::numeric_limits<std::uint64_t>::max() / 8U;
  const std::uint64_t remaining = kMaximumBytes - total_bytes_;
  if (static_cast<std::uintmax_t>(size) >
      static_cast<std::uintmax_t>(remaining)) {
    return latch(Sha256Status::LengthOverflow);
  }
  total_bytes_ += static_cast<std::uint64_t>(size);

  while (size != 0U) {
    const std::size_t available = block_.size() - block_size_;
    const std::size_t take = std::min(size, available);
    std::copy_n(bytes, take,
                block_.begin() + static_cast<std::ptrdiff_t>(block_size_));
    bytes += take;
    size -= take;
    block_size_ += take;
    if (block_size_ == block_.size()) {
      transform(block_.data());
      block_.fill(0U);
      block_size_ = 0U;
    }
  }
  return Sha256Status::Accepted;
}

Sha256Status Sha256Accumulator::finish(
    BulkTranscriptDigest& output) noexcept {
  if (latched_) {
    return Sha256Status::Latched;
  }
  if (finalized_) {
    return Sha256Status::AlreadyFinalized;
  }

  const std::uint64_t bit_length = total_bytes_ * 8U;
  block_[block_size_++] = 0x80U;
  if (block_size_ > 56U) {
    std::fill(block_.begin() + static_cast<std::ptrdiff_t>(block_size_),
              block_.end(), 0U);
    transform(block_.data());
    block_.fill(0U);
    block_size_ = 0U;
  }
  std::fill(block_.begin() + static_cast<std::ptrdiff_t>(block_size_),
            block_.begin() + 56, 0U);
  for (std::size_t index = 0U; index < 8U; ++index) {
    block_[56U + index] = static_cast<std::uint8_t>(
        (bit_length >> static_cast<unsigned int>((7U - index) * 8U)) &
        0xFFU);
  }
  transform(block_.data());
  for (std::size_t word = 0U; word < state_.size(); ++word) {
    for (std::size_t byte = 0U; byte < 4U; ++byte) {
      output[word * 4U + byte] = static_cast<std::uint8_t>(
          (state_[word] >>
           static_cast<unsigned int>((3U - byte) * 8U)) &
          0xFFU);
    }
  }
  block_.fill(0U);
  block_size_ = 0U;
  finalized_ = true;
  return Sha256Status::DigestReady;
}

void Sha256Accumulator::transform(const std::uint8_t* block) noexcept {
  std::array<std::uint32_t, 64U> schedule{};
  for (std::size_t index = 0U; index < 16U; ++index) {
    const std::size_t offset = index * 4U;
    schedule[index] =
        (static_cast<std::uint32_t>(block[offset]) << 24U) |
        (static_cast<std::uint32_t>(block[offset + 1U]) << 16U) |
        (static_cast<std::uint32_t>(block[offset + 2U]) << 8U) |
        static_cast<std::uint32_t>(block[offset + 3U]);
  }
  for (std::size_t index = 16U; index < schedule.size(); ++index) {
    const std::uint32_t before_two = schedule[index - 2U];
    const std::uint32_t before_fifteen = schedule[index - 15U];
    const std::uint32_t sigma_one =
        rotate_right(before_two, 17U) ^ rotate_right(before_two, 19U) ^
        (before_two >> 10U);
    const std::uint32_t sigma_zero =
        rotate_right(before_fifteen, 7U) ^
        rotate_right(before_fifteen, 18U) ^ (before_fifteen >> 3U);
    schedule[index] = schedule[index - 16U] + sigma_zero +
                      schedule[index - 7U] + sigma_one;
  }

  std::uint32_t a = state_[0];
  std::uint32_t b = state_[1];
  std::uint32_t c = state_[2];
  std::uint32_t d = state_[3];
  std::uint32_t e = state_[4];
  std::uint32_t f = state_[5];
  std::uint32_t g = state_[6];
  std::uint32_t h = state_[7];
  for (std::size_t index = 0U; index < schedule.size(); ++index) {
    const std::uint32_t big_sigma_one =
        rotate_right(e, 6U) ^ rotate_right(e, 11U) ^ rotate_right(e, 25U);
    const std::uint32_t choose = (e & f) ^ ((~e) & g);
    const std::uint32_t temporary_one =
        h + big_sigma_one + choose + kSha256RoundConstants[index] +
        schedule[index];
    const std::uint32_t big_sigma_zero =
        rotate_right(a, 2U) ^ rotate_right(a, 13U) ^ rotate_right(a, 22U);
    const std::uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
    const std::uint32_t temporary_two = big_sigma_zero + majority;

    h = g;
    g = f;
    f = e;
    e = d + temporary_one;
    d = c;
    c = b;
    b = a;
    a = temporary_one + temporary_two;
  }

  state_[0] += a;
  state_[1] += b;
  state_[2] += c;
  state_[3] += d;
  state_[4] += e;
  state_[5] += f;
  state_[6] += g;
  state_[7] += h;
}

BulkTranscriptLedger::BulkTranscriptLedger(
    const BulkNegotiationIdentity& identity,
    std::uint32_t transfer_tag) noexcept {
  (void)initialize(identity, transfer_tag);
}

bool BulkTranscriptLedger::identity_valid(
    const BulkNegotiationIdentity& identity) noexcept {
  return identity.session_id != 0U && identity.stream_id != 0U &&
         identity.lease_id != 0U && identity.ground_request_nonce != 0U &&
         identity.vehicle_challenge_nonce != 0U;
}

bool BulkTranscriptLedger::identity_equal(
    const BulkNegotiationIdentity& left,
    const BulkNegotiationIdentity& right) noexcept {
  return left.session_id == right.session_id &&
         left.stream_id == right.stream_id &&
         left.lease_id == right.lease_id &&
         left.ground_request_nonce == right.ground_request_nonce &&
         left.vehicle_challenge_nonce == right.vehicle_challenge_nonce;
}

BulkTranscriptStatus BulkTranscriptLedger::initialize(
    const BulkNegotiationIdentity& identity,
    std::uint32_t transfer_tag) noexcept {
  sha_.reset();
  evidence_ = {};
  evidence_.identity = identity;
  evidence_.transfer_tag = transfer_tag;
  active_ = false;
  sealed_ = false;
  latched_ = false;
  last_error_ = BulkTranscriptStatus::Ready;

  if (!identity_valid(identity) || transfer_tag == 0U) {
    return fail(BulkTranscriptStatus::InvalidConfiguration);
  }

  std::array<std::uint8_t, 65U> prefix{};
  std::copy(kTranscriptDomain.begin(), kTranscriptDomain.end(),
            prefix.begin());
  put_u64_le(prefix, 25U, identity.session_id);
  put_u64_le(prefix, 33U, identity.stream_id);
  put_u64_le(prefix, 41U, identity.lease_id);
  put_u64_le(prefix, 49U, identity.ground_request_nonce);
  put_u64_le(prefix, 57U, identity.vehicle_challenge_nonce);
  if (sha_.update(prefix.data(), prefix.size()) != Sha256Status::Accepted) {
    return fail(BulkTranscriptStatus::DigestFailure);
  }
  active_ = true;
  return BulkTranscriptStatus::Ready;
}

BulkTranscriptStatus BulkTranscriptLedger::append(
    const MavlinkFrame& frame) noexcept {
  if (sealed_) {
    return fail(BulkTranscriptStatus::PostSealData);
  }
  if (latched_) {
    return BulkTranscriptStatus::Latched;
  }
  if (!active_) {
    return fail(BulkTranscriptStatus::InvalidConfiguration);
  }

  MavlinkFrame validated{};
  if (validate_mavlink_frame(frame.bytes.data(), frame.size, validated) !=
      MavlinkParseStatus::FrameReady) {
    return fail(BulkTranscriptStatus::InvalidMavlink);
  }
  if (validated.version != MavlinkVersion::V2 || validated.signed_frame) {
    return fail(BulkTranscriptStatus::UnsupportedFrame);
  }
  if (validated.message_id == 22U) {
    if (validated.size != 37U || validated.payload_length != 25U) {
      return fail(BulkTranscriptStatus::UnsupportedFrame);
    }
    return append_parameter(validated);
  }
  if (validated.message_id == 0U) {
    if (validated.size != 21U || validated.payload_length != 9U) {
      return fail(BulkTranscriptStatus::UnsupportedFrame);
    }
    return append_heartbeat(validated);
  }
  return fail(BulkTranscriptStatus::UnsupportedFrame);
}

BulkTranscriptStatus BulkTranscriptLedger::append_parameter(
    const MavlinkFrame& frame) noexcept {
  if (evidence_.parameter_count >= required_parameter_count()) {
    return fail(BulkTranscriptStatus::ParameterOverflow);
  }
  if (payload_u16(frame, 4U) != required_parameter_count()) {
    return fail(BulkTranscriptStatus::WrongParameterCount);
  }
  if (payload_u16(frame, 6U) != evidence_.parameter_count) {
    return fail(BulkTranscriptStatus::WrongParameterIndex);
  }
  if (evidence_.raw_parameter_bytes >
      std::numeric_limits<std::uint32_t>::max() - 37U) {
    return fail(BulkTranscriptStatus::ParameterOverflow);
  }
  if (!hash_entry(static_cast<std::uint8_t>('P'),
                  evidence_.parameter_count, frame)) {
    return fail(BulkTranscriptStatus::DigestFailure);
  }
  ++evidence_.parameter_count;
  evidence_.raw_parameter_bytes += 37U;
  last_error_ = BulkTranscriptStatus::Ready;
  return BulkTranscriptStatus::EntryAccepted;
}

BulkTranscriptStatus BulkTranscriptLedger::append_heartbeat(
    const MavlinkFrame& frame) noexcept {
  if (evidence_.heartbeat_count ==
      std::numeric_limits<std::uint32_t>::max()) {
    return fail(BulkTranscriptStatus::HeartbeatOverflow);
  }
  const std::uint32_t request_id = evidence_.heartbeat_count + 1U;
  if (!hash_entry(static_cast<std::uint8_t>('H'), request_id, frame)) {
    return fail(BulkTranscriptStatus::DigestFailure);
  }
  evidence_.heartbeat_count = request_id;
  evidence_.last_heartbeat_request_id = request_id;
  last_error_ = BulkTranscriptStatus::Ready;
  return BulkTranscriptStatus::EntryAccepted;
}

bool BulkTranscriptLedger::hash_entry(std::uint8_t kind,
                                      std::uint32_t ordinal,
                                      const MavlinkFrame& frame) noexcept {
  std::array<std::uint8_t, 7U> prefix{};
  prefix[0] = kind;
  put_u32_le(prefix, 1U, ordinal);
  put_u16_le(prefix, 5U, static_cast<std::uint16_t>(frame.size));
  return sha_.update(prefix.data(), prefix.size()) == Sha256Status::Accepted &&
         sha_.update(frame.bytes.data(), frame.size) == Sha256Status::Accepted;
}

BulkTranscriptStatus BulkTranscriptLedger::seal_session() noexcept {
  if (sealed_) {
    return BulkTranscriptStatus::AlreadySealed;
  }
  if (latched_) {
    return BulkTranscriptStatus::Latched;
  }
  if (!active_) {
    return fail(BulkTranscriptStatus::NoActiveSession);
  }
  if (evidence_.parameter_count != required_parameter_count() ||
      evidence_.raw_parameter_bytes != required_raw_parameter_bytes() ||
      evidence_.heartbeat_count == 0U ||
      evidence_.last_heartbeat_request_id != evidence_.heartbeat_count) {
    return fail(BulkTranscriptStatus::IncompleteCorpus);
  }
  if (sha_.finish(evidence_.digest) != Sha256Status::DigestReady) {
    return fail(BulkTranscriptStatus::DigestFailure);
  }
  evidence_.owner_sealed = true;
  active_ = false;
  sealed_ = true;
  latched_ = false;
  last_error_ = BulkTranscriptStatus::Ready;
  return BulkTranscriptStatus::Sealed;
}

BulkTranscriptStatus BulkTranscriptLedger::abort() noexcept {
  if (!active_) {
    last_error_ = BulkTranscriptStatus::NoActiveSession;
    return BulkTranscriptStatus::NoActiveSession;
  }
  sha_.reset();
  clear_completion_evidence();
  active_ = false;
  sealed_ = false;
  latched_ = true;
  last_error_ = BulkTranscriptStatus::Aborted;
  return BulkTranscriptStatus::Aborted;
}

BulkTranscriptStatus BulkTranscriptLedger::rearm(
    const BulkNegotiationIdentity& identity,
    std::uint32_t transfer_tag) noexcept {
  if (active_) {
    last_error_ = BulkTranscriptStatus::SessionNotSealed;
    return BulkTranscriptStatus::SessionNotSealed;
  }
  if (!identity_valid(identity) || transfer_tag == 0U) {
    return fail(BulkTranscriptStatus::InvalidConfiguration);
  }
  if (identity_valid(evidence_.identity) &&
      identity_equal(identity, evidence_.identity)) {
    last_error_ = BulkTranscriptStatus::IdentityReuse;
    return BulkTranscriptStatus::IdentityReuse;
  }
  if (evidence_.transfer_tag != 0U &&
      transfer_tag == evidence_.transfer_tag) {
    last_error_ = BulkTranscriptStatus::TransferTagReuse;
    return BulkTranscriptStatus::TransferTagReuse;
  }
  const BulkTranscriptStatus initialized = initialize(identity, transfer_tag);
  return initialized == BulkTranscriptStatus::Ready
             ? BulkTranscriptStatus::Rearmed
             : initialized;
}

BulkTranscriptStatus BulkTranscriptLedger::fail(
    BulkTranscriptStatus status) noexcept {
  evidence_.digest.fill(0U);
  evidence_.owner_sealed = false;
  active_ = false;
  sealed_ = false;
  latched_ = true;
  last_error_ = status;
  return status;
}

void BulkTranscriptLedger::clear_completion_evidence() noexcept {
  evidence_.parameter_count = 0U;
  evidence_.raw_parameter_bytes = 0U;
  evidence_.heartbeat_count = 0U;
  evidence_.last_heartbeat_request_id = 0U;
  evidence_.digest.fill(0U);
  evidence_.owner_sealed = false;
}

}  // namespace vc_lora
