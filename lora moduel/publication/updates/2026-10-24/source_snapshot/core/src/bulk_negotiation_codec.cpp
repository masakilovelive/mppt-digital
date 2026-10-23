#include "vc_lora/bulk_negotiation_codec.hpp"

#include <algorithm>

namespace vc_lora {
namespace {

constexpr std::array<std::uint8_t, 4U> kMagic{{'V', 'C', 'B', 'N'}};
constexpr std::array<std::uint8_t, 18U> kRequestTagDomain{{
    'V', 'C', '-', 'B', 'U', 'L', 'K', '-', 'R', 'E', 'Q', 'U', 'E', 'S',
    'T', 0U,  'v', '1'}};
constexpr std::array<std::uint8_t, 14U> kTransferTagDomain{{
    'V', 'C', '-', 'B', 'U', 'L', 'K', '-', 'T', 'A', 'G', 0U, 'v', '1'}};
constexpr std::uint32_t kCrc32cInitial = 0xFFFFFFFFU;
constexpr std::uint32_t kCrc32cPolynomial = 0x82F63B78U;

void put_u16(BulkNegotiationFrame& bytes, std::size_t offset,
             std::uint16_t value) noexcept {
  bytes[offset] = static_cast<std::uint8_t>(value & 0xFFU);
  bytes[offset + 1U] = static_cast<std::uint8_t>(value >> 8U);
}

void put_u32(BulkNegotiationFrame& bytes, std::size_t offset,
             std::uint32_t value) noexcept {
  for (std::size_t index = 0U; index < 4U; ++index) {
    bytes[offset + index] = static_cast<std::uint8_t>(
        (value >> static_cast<unsigned int>(index * 8U)) & 0xFFU);
  }
}

void put_u64(BulkNegotiationFrame& bytes, std::size_t offset,
             std::uint64_t value) noexcept {
  for (std::size_t index = 0U; index < 8U; ++index) {
    bytes[offset + index] = static_cast<std::uint8_t>(
        (value >> static_cast<unsigned int>(index * 8U)) & 0xFFU);
  }
}

void put_u64(std::array<std::uint8_t, 40U>& bytes, std::size_t offset,
             std::uint64_t value) noexcept {
  for (std::size_t index = 0U; index < 8U; ++index) {
    bytes[offset + index] = static_cast<std::uint8_t>(
        (value >> static_cast<unsigned int>(index * 8U)) & 0xFFU);
  }
}

std::uint16_t get_u16(const BulkNegotiationFrame& bytes,
                      std::size_t offset) noexcept {
  return static_cast<std::uint16_t>(bytes[offset]) |
         static_cast<std::uint16_t>(
             static_cast<std::uint16_t>(bytes[offset + 1U]) << 8U);
}

std::uint32_t get_u32(const BulkNegotiationFrame& bytes,
                      std::size_t offset) noexcept {
  std::uint32_t value = 0U;
  for (std::size_t index = 0U; index < 4U; ++index) {
    value |= static_cast<std::uint32_t>(bytes[offset + index])
             << static_cast<unsigned int>(index * 8U);
  }
  return value;
}

std::uint64_t get_u64(const BulkNegotiationFrame& bytes,
                      std::size_t offset) noexcept {
  std::uint64_t value = 0U;
  for (std::size_t index = 0U; index < 8U; ++index) {
    value |= static_cast<std::uint64_t>(bytes[offset + index])
             << static_cast<unsigned int>(index * 8U);
  }
  return value;
}

bool request_is_valid(const BulkNegotiationRequest& request) noexcept {
  return request.ground_boot_id != 0U && request.ground_session_id != 0U &&
         request.request_sequence != 0U && request.ground_nonce != 0U &&
         request.captured_vehicle_grant_session != 0U;
}

bool response_status_is_known(
    BulkNegotiationResponseStatus status) noexcept {
  return static_cast<std::uint8_t>(status) <=
         static_cast<std::uint8_t>(
             BulkNegotiationResponseStatus::TagDerivationFailure);
}

bool response_is_valid(const BulkNegotiationResponse& response) noexcept {
  if (!response_status_is_known(response.status) ||
      response.vehicle_boot_id == 0U ||
      response.vehicle_session_id == 0U || response.request_tag == 0U) {
    return false;
  }
  if (response.status == BulkNegotiationResponseStatus::Accept) {
    return response.lease_sequence != 0U &&
           response.vehicle_challenge_nonce != 0U;
  }
  return response.lease_sequence == 0U &&
         response.vehicle_challenge_nonce == 0U;
}

bool identity_is_valid(const BulkNegotiationIdentity& identity) noexcept {
  return identity.session_id != 0U && identity.stream_id != 0U &&
         identity.lease_id != 0U && identity.ground_request_nonce != 0U &&
         identity.vehicle_challenge_nonce != 0U;
}

std::uint32_t update_crc32c(std::uint32_t crc, const std::uint8_t* bytes,
                            std::size_t size) noexcept {
  for (std::size_t index = 0U; index < size; ++index) {
    crc ^= static_cast<std::uint32_t>(bytes[index]);
    for (std::uint8_t bit = 0U; bit < 8U; ++bit) {
      const std::uint32_t mask =
          0U - static_cast<std::uint32_t>(crc & 1U);
      crc = (crc >> 1U) ^ (kCrc32cPolynomial & mask);
    }
  }
  return crc;
}

std::uint32_t request_tag_unchecked(
    const BulkNegotiationFrame& request_frame) noexcept {
  std::uint32_t crc = update_crc32c(
      kCrc32cInitial, kRequestTagDomain.data(), kRequestTagDomain.size());
  crc = update_crc32c(crc, request_frame.data(),
                      BulkNegotiationWireCodec::integrity_offset);
  return ~crc;
}

BulkNegotiationWireStatus validate_common(
    const BulkNegotiationFrame& frame, std::uint8_t expected_kind) noexcept {
  if (!std::equal(kMagic.begin(), kMagic.end(), frame.begin())) {
    return BulkNegotiationWireStatus::UnknownMagic;
  }
  if (get_u16(frame, BulkNegotiationWireCodec::integrity_offset) !=
      BulkNegotiationWireCodec::crc16_ccitt_false(
          frame.data(), BulkNegotiationWireCodec::integrity_offset)) {
    return BulkNegotiationWireStatus::BadCrc;
  }
  if (frame[4] != BulkNegotiationWireCodec::version) {
    return BulkNegotiationWireStatus::UnknownVersion;
  }
  if (frame[5] != BulkNegotiationWireCodec::request_kind &&
      frame[5] != BulkNegotiationWireCodec::response_kind) {
    return BulkNegotiationWireStatus::UnknownKind;
  }
  if (frame[5] != expected_kind) {
    return BulkNegotiationWireStatus::WrongKind;
  }
  if (frame[6] != BulkNegotiationWireCodec::vcb1_profile) {
    return BulkNegotiationWireStatus::UnsupportedProfile;
  }
  return BulkNegotiationWireStatus::FrameReady;
}

BulkNegotiationWireStatus correlate(
    const BulkNegotiationFrame& request_frame,
    const BulkNegotiationFrame& response_frame,
    BulkNegotiationRequest& request,
    BulkNegotiationResponse& response) noexcept {
  const BulkNegotiationWireStatus request_status =
      BulkNegotiationWireCodec::decode_request(request_frame, request);
  if (request_status != BulkNegotiationWireStatus::FrameReady) {
    return request_status;
  }
  const BulkNegotiationWireStatus response_status =
      BulkNegotiationWireCodec::decode_response(response_frame, response);
  if (response_status != BulkNegotiationWireStatus::FrameReady) {
    return response_status;
  }
  const std::uint32_t expected_tag = request_tag_unchecked(request_frame);
  if (expected_tag == 0U) {
    return BulkNegotiationWireStatus::DerivedTagZero;
  }
  if (response.request_tag != expected_tag) {
    return BulkNegotiationWireStatus::RequestTagMismatch;
  }
  if (response.vehicle_session_id !=
          request.captured_vehicle_grant_session ||
      response.echoed_vehicle_grant_cycle !=
          request.captured_vehicle_grant_cycle) {
    return BulkNegotiationWireStatus::GrantIdentityMismatch;
  }
  return BulkNegotiationWireStatus::CorrelatedResponse;
}

}  // namespace

std::uint16_t BulkNegotiationWireCodec::crc16_ccitt_false(
    const std::uint8_t* bytes, std::size_t size) noexcept {
  if (bytes == nullptr && size != 0U) {
    return 0U;
  }
  std::uint16_t crc = 0xFFFFU;
  for (std::size_t index = 0U; index < size; ++index) {
    crc ^= static_cast<std::uint16_t>(
        static_cast<std::uint16_t>(bytes[index]) << 8U);
    for (std::uint8_t bit = 0U; bit < 8U; ++bit) {
      crc = (crc & 0x8000U) != 0U
                ? static_cast<std::uint16_t>(
                      (static_cast<std::uint32_t>(crc) << 1U) ^ 0x1021U)
                : static_cast<std::uint16_t>(
                      static_cast<std::uint32_t>(crc) << 1U);
    }
  }
  return crc;
}

std::uint32_t BulkNegotiationWireCodec::crc32c(
    const std::uint8_t* bytes, std::size_t size) noexcept {
  if (bytes == nullptr && size != 0U) {
    return 0U;
  }
  return ~update_crc32c(kCrc32cInitial, bytes, size);
}

BulkNegotiationWireStatus BulkNegotiationWireCodec::encode_request(
    const BulkNegotiationRequest& request,
    BulkNegotiationFrame& output) noexcept {
  if (!request_is_valid(request)) {
    return BulkNegotiationWireStatus::InvalidRequest;
  }

  BulkNegotiationFrame candidate{};
  std::copy(kMagic.begin(), kMagic.end(), candidate.begin());
  candidate[4] = version;
  candidate[5] = request_kind;
  candidate[6] = vcb1_profile;
  candidate[7] = 0U;
  put_u32(candidate, 8U, request.ground_boot_id);
  put_u16(candidate, 12U, request.ground_session_id);
  put_u16(candidate, 14U, request.request_sequence);
  put_u64(candidate, 16U, request.ground_nonce);
  candidate[24] = request.target_system;
  candidate[25] = request.target_component;
  put_u16(candidate, 26U, request.captured_vehicle_grant_session);
  put_u16(candidate, 28U, request.captured_vehicle_grant_cycle);
  if (request_tag_unchecked(candidate) == 0U) {
    return BulkNegotiationWireStatus::DerivedTagZero;
  }
  put_u16(candidate, integrity_offset,
          crc16_ccitt_false(candidate.data(), integrity_offset));
  output = candidate;
  return BulkNegotiationWireStatus::FrameReady;
}

BulkNegotiationWireStatus BulkNegotiationWireCodec::decode_request(
    const BulkNegotiationFrame& frame,
    BulkNegotiationRequest& output) noexcept {
  const BulkNegotiationWireStatus common =
      validate_common(frame, request_kind);
  if (common != BulkNegotiationWireStatus::FrameReady) {
    return common;
  }
  if (frame[7] != 0U) {
    return BulkNegotiationWireStatus::InvalidFlags;
  }

  BulkNegotiationRequest candidate{};
  candidate.ground_boot_id = get_u32(frame, 8U);
  candidate.ground_session_id = get_u16(frame, 12U);
  candidate.request_sequence = get_u16(frame, 14U);
  candidate.ground_nonce = get_u64(frame, 16U);
  candidate.target_system = frame[24];
  candidate.target_component = frame[25];
  candidate.captured_vehicle_grant_session = get_u16(frame, 26U);
  candidate.captured_vehicle_grant_cycle = get_u16(frame, 28U);
  if (!request_is_valid(candidate)) {
    return BulkNegotiationWireStatus::InvalidRequest;
  }
  if (request_tag_unchecked(frame) == 0U) {
    return BulkNegotiationWireStatus::DerivedTagZero;
  }
  output = candidate;
  return BulkNegotiationWireStatus::FrameReady;
}

BulkNegotiationWireStatus BulkNegotiationWireCodec::encode_response(
    const BulkNegotiationResponse& response,
    BulkNegotiationFrame& output) noexcept {
  if (!response_status_is_known(response.status)) {
    return BulkNegotiationWireStatus::UnknownResponseStatus;
  }
  if (!response_is_valid(response)) {
    return BulkNegotiationWireStatus::InvalidResponse;
  }

  BulkNegotiationFrame candidate{};
  std::copy(kMagic.begin(), kMagic.end(), candidate.begin());
  candidate[4] = version;
  candidate[5] = response_kind;
  candidate[6] = vcb1_profile;
  candidate[7] = static_cast<std::uint8_t>(response.status);
  put_u32(candidate, 8U, response.vehicle_boot_id);
  put_u16(candidate, 12U, response.vehicle_session_id);
  put_u16(candidate, 14U, response.lease_sequence);
  put_u64(candidate, 16U, response.vehicle_challenge_nonce);
  put_u32(candidate, 24U, response.request_tag);
  put_u16(candidate, 28U, response.echoed_vehicle_grant_cycle);
  put_u16(candidate, integrity_offset,
          crc16_ccitt_false(candidate.data(), integrity_offset));
  output = candidate;
  return BulkNegotiationWireStatus::FrameReady;
}

BulkNegotiationWireStatus BulkNegotiationWireCodec::decode_response(
    const BulkNegotiationFrame& frame,
    BulkNegotiationResponse& output) noexcept {
  const BulkNegotiationWireStatus common =
      validate_common(frame, response_kind);
  if (common != BulkNegotiationWireStatus::FrameReady) {
    return common;
  }
  const auto status =
      static_cast<BulkNegotiationResponseStatus>(frame[7]);
  if (!response_status_is_known(status)) {
    return BulkNegotiationWireStatus::UnknownResponseStatus;
  }

  BulkNegotiationResponse candidate{};
  candidate.status = status;
  candidate.vehicle_boot_id = get_u32(frame, 8U);
  candidate.vehicle_session_id = get_u16(frame, 12U);
  candidate.lease_sequence = get_u16(frame, 14U);
  candidate.vehicle_challenge_nonce = get_u64(frame, 16U);
  candidate.request_tag = get_u32(frame, 24U);
  candidate.echoed_vehicle_grant_cycle = get_u16(frame, 28U);
  if (!response_is_valid(candidate)) {
    return BulkNegotiationWireStatus::InvalidResponse;
  }
  output = candidate;
  return BulkNegotiationWireStatus::FrameReady;
}

BulkNegotiationWireStatus BulkNegotiationWireCodec::derive_request_tag(
    const BulkNegotiationFrame& request_frame,
    std::uint32_t& output) noexcept {
  BulkNegotiationRequest decoded{};
  const BulkNegotiationWireStatus status =
      decode_request(request_frame, decoded);
  if (status != BulkNegotiationWireStatus::FrameReady) {
    return status;
  }
  const std::uint32_t candidate = request_tag_unchecked(request_frame);
  if (candidate == 0U) {
    return BulkNegotiationWireStatus::DerivedTagZero;
  }
  output = candidate;
  return BulkNegotiationWireStatus::RequestTagReady;
}

BulkNegotiationWireStatus BulkNegotiationWireCodec::derive_transfer_tag(
    const BulkNegotiationIdentity& identity,
    std::uint32_t& output) noexcept {
  if (!identity_is_valid(identity)) {
    return BulkNegotiationWireStatus::InvalidIdentity;
  }
  std::array<std::uint8_t, 40U> identity_bytes{};
  put_u64(identity_bytes, 0U, identity.session_id);
  put_u64(identity_bytes, 8U, identity.stream_id);
  put_u64(identity_bytes, 16U, identity.lease_id);
  put_u64(identity_bytes, 24U, identity.ground_request_nonce);
  put_u64(identity_bytes, 32U, identity.vehicle_challenge_nonce);

  std::uint32_t crc = update_crc32c(
      kCrc32cInitial, kTransferTagDomain.data(), kTransferTagDomain.size());
  crc = update_crc32c(crc, identity_bytes.data(), identity_bytes.size());
  const std::uint32_t candidate = ~crc;
  if (candidate == 0U) {
    return BulkNegotiationWireStatus::DerivedTagZero;
  }
  output = candidate;
  return BulkNegotiationWireStatus::TransferTagReady;
}

BulkNegotiationWireStatus
BulkNegotiationWireCodec::validate_response_correlation(
    const BulkNegotiationFrame& request_frame,
    const BulkNegotiationFrame& response_frame) noexcept {
  BulkNegotiationRequest request{};
  BulkNegotiationResponse response{};
  return correlate(request_frame, response_frame, request, response);
}

BulkNegotiationWireStatus
BulkNegotiationWireCodec::derive_accepted_transfer(
    const BulkNegotiationFrame& request_frame,
    const BulkNegotiationFrame& response_frame,
    BulkNegotiationIdentity& identity_output,
    std::uint32_t& transfer_tag_output) noexcept {
  BulkNegotiationRequest request{};
  BulkNegotiationResponse response{};
  const BulkNegotiationWireStatus correlation =
      correlate(request_frame, response_frame, request, response);
  if (correlation != BulkNegotiationWireStatus::CorrelatedResponse) {
    return correlation;
  }
  if (response.status != BulkNegotiationResponseStatus::Accept) {
    return BulkNegotiationWireStatus::PeerRejected;
  }

  BulkNegotiationIdentity candidate{};
  candidate.session_id =
      (static_cast<std::uint64_t>(response.vehicle_boot_id) << 16U) |
      static_cast<std::uint64_t>(response.vehicle_session_id);
  candidate.stream_id =
      (static_cast<std::uint64_t>(request.ground_boot_id) << 32U) |
      (static_cast<std::uint64_t>(request.ground_session_id) << 16U) |
      static_cast<std::uint64_t>(request.request_sequence);
  candidate.lease_id =
      (static_cast<std::uint64_t>(response.vehicle_boot_id) << 32U) |
      (static_cast<std::uint64_t>(response.vehicle_session_id) << 16U) |
      static_cast<std::uint64_t>(response.lease_sequence);
  candidate.ground_request_nonce = request.ground_nonce;
  candidate.vehicle_challenge_nonce = response.vehicle_challenge_nonce;
  if (!identity_is_valid(candidate)) {
    return BulkNegotiationWireStatus::InvalidIdentity;
  }

  std::uint32_t tag_candidate = 0U;
  const BulkNegotiationWireStatus tag_status =
      derive_transfer_tag(candidate, tag_candidate);
  if (tag_status != BulkNegotiationWireStatus::TransferTagReady) {
    return tag_status;
  }
  identity_output = candidate;
  transfer_tag_output = tag_candidate;
  return BulkNegotiationWireStatus::TransferReady;
}

}  // namespace vc_lora
