#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace vc_lora {

// The negotiation codec is an inert, clock-free wire primitive. Nothing in
// the production TDD path selects bulk mode merely because a VCBN record was
// decoded; an adapter must explicitly correlate an Accept to its one pending
// Request before using the derived identity and tag.
//
// Wire v1, exact 32 bytes, little-endian integers:
//   0..3   ASCII "VCBN"
//   4      version (1)
//   5      kind (1=Request, 2=Response)
//   6      profile (1=VCB1 exact-32 data)
//   7      Request flags (0) or Response status
//   8..29  kind-specific body
//   30..31 CRC-16/CCITT-FALSE over bytes 0..29
using BulkNegotiationFrame = std::array<std::uint8_t, 32U>;

enum class BulkNegotiationResponseStatus : std::uint8_t {
  Accept = 0U,
  UnsupportedProfile = 1U,
  Busy = 2U,
  WrongTarget = 3U,
  IdentityExhausted = 4U,
  EntropyUnavailable = 5U,
  TagDerivationFailure = 6U,
};

enum class BulkNegotiationWireStatus : std::uint8_t {
  FrameReady = 0U,
  RequestTagReady,
  TransferTagReady,
  CorrelatedResponse,
  TransferReady,
  InvalidArgument,
  UnknownMagic,
  BadCrc,
  UnknownVersion,
  UnknownKind,
  WrongKind,
  UnsupportedProfile,
  InvalidFlags,
  UnknownResponseStatus,
  InvalidRequest,
  InvalidResponse,
  RequestTagMismatch,
  GrantIdentityMismatch,
  PeerRejected,
  InvalidIdentity,
  DerivedTagZero,
};

struct BulkNegotiationRequest final {
  std::uint32_t ground_boot_id{0U};
  std::uint16_t ground_session_id{0U};
  std::uint16_t request_sequence{0U};
  std::uint64_t ground_nonce{0U};
  std::uint8_t target_system{0U};
  std::uint8_t target_component{0U};
  std::uint16_t captured_vehicle_grant_session{0U};
  std::uint16_t captured_vehicle_grant_cycle{0U};
};

struct BulkNegotiationResponse final {
  BulkNegotiationResponseStatus status{
      BulkNegotiationResponseStatus::Accept};
  std::uint32_t vehicle_boot_id{0U};
  std::uint16_t vehicle_session_id{0U};
  std::uint16_t lease_sequence{0U};
  std::uint64_t vehicle_challenge_nonce{0U};
  std::uint32_t request_tag{0U};
  std::uint16_t echoed_vehicle_grant_cycle{0U};
};

// These values bind the later VCB1 stream and terminal evidence to exactly
// one negotiated request/lease. CRC32C tags detect accidental mixing and are
// correlation values, not cryptographic authentication.
struct BulkNegotiationIdentity final {
  std::uint64_t session_id{0U};
  std::uint64_t stream_id{0U};
  std::uint64_t lease_id{0U};
  std::uint64_t ground_request_nonce{0U};
  std::uint64_t vehicle_challenge_nonce{0U};
};

class BulkNegotiationWireCodec final {
 public:
  static constexpr std::size_t frame_bytes = 32U;
  static constexpr std::size_t integrity_offset = 30U;
  static constexpr std::uint8_t version = 1U;
  static constexpr std::uint8_t request_kind = 1U;
  static constexpr std::uint8_t response_kind = 2U;
  static constexpr std::uint8_t vcb1_profile = 1U;

  [[nodiscard]] static std::uint16_t crc16_ccitt_false(
      const std::uint8_t* bytes, std::size_t size) noexcept;
  [[nodiscard]] static std::uint32_t crc32c(
      const std::uint8_t* bytes, std::size_t size) noexcept;

  [[nodiscard]] static BulkNegotiationWireStatus encode_request(
      const BulkNegotiationRequest& request,
      BulkNegotiationFrame& output) noexcept;
  [[nodiscard]] static BulkNegotiationWireStatus decode_request(
      const BulkNegotiationFrame& frame,
      BulkNegotiationRequest& output) noexcept;

  [[nodiscard]] static BulkNegotiationWireStatus encode_response(
      const BulkNegotiationResponse& response,
      BulkNegotiationFrame& output) noexcept;
  [[nodiscard]] static BulkNegotiationWireStatus decode_response(
      const BulkNegotiationFrame& frame,
      BulkNegotiationResponse& output) noexcept;

  // request_tag = CRC32C("VC-BULK-REQUEST" || 00 || "v1" ||
  //                      request bytes[0..29]).
  [[nodiscard]] static BulkNegotiationWireStatus derive_request_tag(
      const BulkNegotiationFrame& request_frame,
      std::uint32_t& output) noexcept;

  // transfer_tag = CRC32C("VC-BULK-TAG" || 00 || "v1" ||
  //                       LE64(session) || LE64(stream) || LE64(lease) ||
  //                       LE64(ground_nonce) || LE64(vehicle_challenge)).
  [[nodiscard]] static BulkNegotiationWireStatus derive_transfer_tag(
      const BulkNegotiationIdentity& identity,
      std::uint32_t& output) noexcept;

  // Accept and Reject both need the request tag and captured Vehicle
  // grant session/cycle to match the pending Request. No identity is emitted.
  [[nodiscard]] static BulkNegotiationWireStatus
  validate_response_correlation(
      const BulkNegotiationFrame& request_frame,
      const BulkNegotiationFrame& response_frame) noexcept;

  // Emits identity/tag atomically only for a canonical, correlated Accept.
  [[nodiscard]] static BulkNegotiationWireStatus derive_accepted_transfer(
      const BulkNegotiationFrame& request_frame,
      const BulkNegotiationFrame& response_frame,
      BulkNegotiationIdentity& identity_output,
      std::uint32_t& transfer_tag_output) noexcept;
};

static_assert(sizeof(BulkNegotiationFrame) ==
              BulkNegotiationWireCodec::frame_bytes);

}  // namespace vc_lora
