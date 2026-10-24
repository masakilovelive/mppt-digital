#pragma once

#include <cstdint>

#include "vc_lora/bulk_session_controller.hpp"
#include "vc_lora/runtime_contract.hpp"

namespace vc_lora::experimental {

// The platform adapter must supply two independent, nonzero entropy samples.
// This pure factory deliberately does not acquire ESP entropy itself. Equal
// samples are treated as an alias/miswired caller and fail closed.
struct Phase6HighSpeedRoleEntropy final {
  std::uint64_t sequence_entropy{0U};
  std::uint64_t nonce_entropy{0U};
};

namespace role_config_detail {

constexpr std::uint64_t kGroundSequenceDomain =
    0x47524F554E445345ULL;  // "GROUNDSE"
constexpr std::uint64_t kGroundNonceDomain =
    0x47524F554E444E43ULL;  // "GROUNDNC"
constexpr std::uint64_t kVehicleNonceDomain =
    0x56454849434C454EULL;  // "VEHICLEN"
constexpr std::uint64_t kVehicleMavlinkDomain =
    0x5645484D41564C4BULL;  // "VEHMAVLK"

constexpr std::uint64_t mix64(std::uint64_t value) noexcept {
  value ^= value >> 30U;
  value *= 0xBF58476D1CE4E5B9ULL;
  value ^= value >> 27U;
  value *= 0x94D049BB133111EBULL;
  value ^= value >> 31U;
  return value;
}

constexpr std::uint64_t rotate_left_17(std::uint64_t value) noexcept {
  return (value << 17U) | (value >> 47U);
}

constexpr bool identity_valid(BootSessionIdentity identity) noexcept {
  return identity.boot_id != 0U && identity.session_id != 0U;
}

constexpr bool entropy_valid(Phase6HighSpeedRoleEntropy entropy) noexcept {
  return entropy.sequence_entropy != 0U && entropy.nonce_entropy != 0U &&
         entropy.sequence_entropy != entropy.nonce_entropy;
}

constexpr std::uint64_t identity_material(
    BootSessionIdentity identity) noexcept {
  return (static_cast<std::uint64_t>(identity.boot_id) << 16U) |
         static_cast<std::uint64_t>(identity.session_id);
}

constexpr std::uint64_t entropy_material(
    BootSessionIdentity identity,
    Phase6HighSpeedRoleEntropy entropy) noexcept {
  return identity_material(identity) ^ entropy.nonce_entropy ^
         rotate_left_17(entropy.sequence_entropy);
}

constexpr std::uint16_t next_nonzero_not_equal(
    std::uint16_t value, std::uint16_t forbidden) noexcept {
  if (value == 0U) {
    value = 1U;
  }
  if (value == forbidden) {
    value = value == 0xFFFFU
                ? static_cast<std::uint16_t>(1U)
                : static_cast<std::uint16_t>(value + 1U);
  }
  if (value == forbidden) {
    value = value == 0xFFFFU
                ? static_cast<std::uint16_t>(1U)
                : static_cast<std::uint16_t>(value + 1U);
  }
  return value;
}

constexpr std::uint16_t ground_request_sequence(
    BootSessionIdentity identity,
    Phase6HighSpeedRoleEntropy entropy) noexcept {
  const std::uint64_t mixed = mix64(
      identity_material(identity) ^ entropy.sequence_entropy ^
      kGroundSequenceDomain);
  return next_nonzero_not_equal(static_cast<std::uint16_t>(mixed),
                                identity.session_id);
}

constexpr std::uint8_t vehicle_mavlink_sequence(
    BootSessionIdentity identity,
    Phase6HighSpeedRoleEntropy entropy) noexcept {
  const std::uint8_t candidate = static_cast<std::uint8_t>(mix64(
      identity_material(identity) ^ entropy.sequence_entropy ^
      kVehicleMavlinkDomain));
  return candidate == 0U ? static_cast<std::uint8_t>(1U) : candidate;
}

constexpr std::uint64_t ground_nonce(
    BootSessionIdentity identity,
    Phase6HighSpeedRoleEntropy entropy) noexcept {
  // Ground always occupies the low-half nonce domain and sets bit zero.
  // Vehicle always occupies the high-half domain, so equal inputs cannot
  // alias even after the nonzero normalization.
  return (mix64(entropy_material(identity, entropy) ^ kGroundNonceDomain) &
          0x7FFFFFFFFFFFFFFFULL) |
         0x1ULL;
}

constexpr std::uint64_t vehicle_nonce(
    BootSessionIdentity identity,
    Phase6HighSpeedRoleEntropy entropy) noexcept {
  return (mix64(entropy_material(identity, entropy) ^
                kVehicleNonceDomain) &
          0x7FFFFFFFFFFFFFFFULL) |
         0x8000000000000000ULL;
}

}  // namespace role_config_detail

[[nodiscard]] constexpr GroundBulkSessionConfig
make_ground_bulk_session_config(
    BulkSessionFeature feature, BootSessionIdentity identity,
    Phase6HighSpeedRoleEntropy entropy) noexcept {
  if (feature != BulkSessionFeature::Enabled ||
      !role_config_detail::identity_valid(identity) ||
      !role_config_detail::entropy_valid(entropy)) {
    return {};
  }

  GroundBulkSessionConfig config{};
  config.feature = BulkSessionFeature::Enabled;
  config.ground_boot_id = identity.boot_id;
  config.ground_session_id = identity.session_id;
  config.request_sequence =
      role_config_detail::ground_request_sequence(identity, entropy);
  config.ground_nonce = role_config_detail::ground_nonce(identity, entropy);
  return config;
}

[[nodiscard]] constexpr VehicleBulkSessionConfig
make_vehicle_bulk_session_config(
    BulkSessionFeature feature, BootSessionIdentity identity,
    Phase6HighSpeedRoleEntropy entropy) noexcept {
  if (feature != BulkSessionFeature::Enabled ||
      !role_config_detail::identity_valid(identity) ||
      !role_config_detail::entropy_valid(entropy)) {
    return {};
  }

  VehicleBulkSessionConfig config{};
  config.feature = BulkSessionFeature::Enabled;
  config.vehicle_boot_id = identity.boot_id;
  // The persisted BootSessionIdentity session is the Vehicle lease epoch.
  config.lease_sequence = identity.session_id;
  config.vehicle_challenge_nonce =
      role_config_detail::vehicle_nonce(identity, entropy);
  config.mavlink_sequence =
      role_config_detail::vehicle_mavlink_sequence(identity, entropy);
  config.mavlink_system_id = 255U;
  config.mavlink_component_id = 190U;
  return config;
}

// Product-route names are intentionally explicit. They remain thin wrappers
// around the pure role factories so the later bridge integration cannot
// accidentally select an unrelated session-config constructor.
[[nodiscard]] constexpr GroundBulkSessionConfig
make_r19_ground_bulk_session_config(
    BulkSessionFeature feature, BootSessionIdentity identity,
    Phase6HighSpeedRoleEntropy entropy) noexcept {
  return make_ground_bulk_session_config(feature, identity, entropy);
}

[[nodiscard]] constexpr VehicleBulkSessionConfig
make_r19_vehicle_bulk_session_config(
    BulkSessionFeature feature, BootSessionIdentity identity,
    Phase6HighSpeedRoleEntropy entropy) noexcept {
  return make_vehicle_bulk_session_config(feature, identity, entropy);
}

}  // namespace vc_lora::experimental
