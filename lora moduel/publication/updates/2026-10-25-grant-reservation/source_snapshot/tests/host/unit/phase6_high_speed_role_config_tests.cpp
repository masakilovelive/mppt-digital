#include <cstdint>
#include <string>

#include "../../../firmware/high_speed/phase6_high_speed_role_config.hpp"
#include "test_support.hpp"

namespace vc_lora::test {
namespace {

using experimental::Phase6HighSpeedRoleEntropy;
using experimental::make_r19_ground_bulk_session_config;
using experimental::make_r19_vehicle_bulk_session_config;

constexpr BootSessionIdentity kIdentity{0x12345678U, 0x3456U};
constexpr Phase6HighSpeedRoleEntropy kEntropy{
    0x0123456789ABCDEFULL, 0xFEDCBA9876543210ULL};

constexpr bool ground_zeroed(
    const GroundBulkSessionConfig& config) noexcept {
  return config.feature == BulkSessionFeature::Disabled &&
         config.ground_boot_id == 0U && config.ground_session_id == 0U &&
         config.request_sequence == 0U && config.ground_nonce == 0U;
}

constexpr bool vehicle_zeroed(
    const VehicleBulkSessionConfig& config) noexcept {
  return config.feature == BulkSessionFeature::Disabled &&
         config.vehicle_boot_id == 0U && config.lease_sequence == 0U &&
         config.vehicle_challenge_nonce == 0U &&
         config.mavlink_sequence == 0U && config.mavlink_system_id == 0U &&
         config.mavlink_component_id == 0U;
}

constexpr bool same_ground(const GroundBulkSessionConfig& lhs,
                           const GroundBulkSessionConfig& rhs) noexcept {
  return lhs.feature == rhs.feature &&
         lhs.ground_boot_id == rhs.ground_boot_id &&
         lhs.ground_session_id == rhs.ground_session_id &&
         lhs.request_sequence == rhs.request_sequence &&
         lhs.ground_nonce == rhs.ground_nonce;
}

constexpr bool same_vehicle(const VehicleBulkSessionConfig& lhs,
                            const VehicleBulkSessionConfig& rhs) noexcept {
  return lhs.feature == rhs.feature &&
         lhs.vehicle_boot_id == rhs.vehicle_boot_id &&
         lhs.lease_sequence == rhs.lease_sequence &&
         lhs.vehicle_challenge_nonce == rhs.vehicle_challenge_nonce &&
         lhs.mavlink_sequence == rhs.mavlink_sequence &&
         lhs.mavlink_system_id == rhs.mavlink_system_id &&
         lhs.mavlink_component_id == rhs.mavlink_component_id;
}

static_assert(noexcept(make_r19_ground_bulk_session_config(
    BulkSessionFeature::Enabled, kIdentity, kEntropy)));
static_assert(noexcept(make_r19_vehicle_bulk_session_config(
    BulkSessionFeature::Enabled, kIdentity, kEntropy)));

void test_enabled_mapping_and_domain_separation(TestReport& report) {
  constexpr GroundBulkSessionConfig ground =
      make_r19_ground_bulk_session_config(BulkSessionFeature::Enabled,
                                          kIdentity, kEntropy);
  constexpr VehicleBulkSessionConfig vehicle =
      make_r19_vehicle_bulk_session_config(BulkSessionFeature::Enabled,
                                           kIdentity, kEntropy);
  constexpr GroundBulkSessionConfig ground_repeat =
      make_r19_ground_bulk_session_config(BulkSessionFeature::Enabled,
                                          kIdentity, kEntropy);
  constexpr VehicleBulkSessionConfig vehicle_repeat =
      make_r19_vehicle_bulk_session_config(BulkSessionFeature::Enabled,
                                           kIdentity, kEntropy);

  report.check(ground.feature == BulkSessionFeature::Enabled &&
                   ground.ground_boot_id == kIdentity.boot_id &&
                   ground.ground_session_id == kIdentity.session_id,
               "Ground did not exactly inherit boot/session identity");
  report.check(ground.request_sequence != 0U &&
                   ground.request_sequence != ground.ground_session_id &&
                   ground.ground_nonce != 0U,
               "Ground sequence/nonce was zero or aliased its session");
  report.check(vehicle.feature == BulkSessionFeature::Enabled &&
                   vehicle.vehicle_boot_id == kIdentity.boot_id &&
                   vehicle.lease_sequence == kIdentity.session_id,
               "Vehicle did not exactly inherit boot/session identity");
  report.check(vehicle.vehicle_challenge_nonce != 0U &&
                   vehicle.mavlink_sequence != 0U &&
                   vehicle.mavlink_system_id == 255U &&
                   vehicle.mavlink_component_id == 190U,
               "Vehicle nonce/MAVLink identity contract is invalid");
  report.check(same_ground(ground, ground_repeat) &&
                   same_vehicle(vehicle, vehicle_repeat),
               "same identity/entropy input was not deterministic");
  report.check(ground.ground_nonce != vehicle.vehicle_challenge_nonce,
               "Ground and Vehicle nonce domains aliased");
}

void test_disabled_and_invalid_inputs_fail_closed(TestReport& report) {
  constexpr Phase6HighSpeedRoleEntropy zero_sequence{
      0U, kEntropy.nonce_entropy};
  constexpr Phase6HighSpeedRoleEntropy zero_nonce{
      kEntropy.sequence_entropy, 0U};
  constexpr Phase6HighSpeedRoleEntropy aliased{
      0x55AA55AA55AA55AAULL, 0x55AA55AA55AA55AAULL};
  constexpr BulkSessionFeature invalid_feature =
      static_cast<BulkSessionFeature>(0xFFU);

  report.check(
      ground_zeroed(make_r19_ground_bulk_session_config(
          BulkSessionFeature::Disabled, kIdentity, kEntropy)) &&
          vehicle_zeroed(make_r19_vehicle_bulk_session_config(
              BulkSessionFeature::Disabled, kIdentity, kEntropy)),
      "explicit Disabled feature did not return a zero disabled config");
  report.check(
      ground_zeroed(make_r19_ground_bulk_session_config(
          invalid_feature, kIdentity, kEntropy)) &&
          vehicle_zeroed(make_r19_vehicle_bulk_session_config(
              invalid_feature, kIdentity, kEntropy)),
      "invalid feature did not fail closed");

  for (const BootSessionIdentity invalid_identity :
       {BootSessionIdentity{0U, kIdentity.session_id},
        BootSessionIdentity{kIdentity.boot_id, 0U},
        BootSessionIdentity{}}) {
    report.check(
        ground_zeroed(make_r19_ground_bulk_session_config(
            BulkSessionFeature::Enabled, invalid_identity, kEntropy)) &&
            vehicle_zeroed(make_r19_vehicle_bulk_session_config(
                BulkSessionFeature::Enabled, invalid_identity, kEntropy)),
        "zero boot/session identity did not fail closed");
  }

  for (const Phase6HighSpeedRoleEntropy invalid_entropy :
       {zero_sequence, zero_nonce, aliased}) {
    report.check(
        ground_zeroed(make_r19_ground_bulk_session_config(
            BulkSessionFeature::Enabled, kIdentity, invalid_entropy)) &&
            vehicle_zeroed(make_r19_vehicle_bulk_session_config(
                BulkSessionFeature::Enabled, kIdentity, invalid_entropy)),
        "zero or aliased entropy did not fail closed");
  }
}

void test_input_changes_are_bound(TestReport& report) {
  constexpr BootSessionIdentity next_identity{0x12345679U, 0x3457U};
  constexpr Phase6HighSpeedRoleEntropy next_entropy{
      0x0123456789ABCDEEULL, 0xFEDCBA9876543211ULL};
  constexpr GroundBulkSessionConfig baseline_ground =
      make_r19_ground_bulk_session_config(BulkSessionFeature::Enabled,
                                          kIdentity, kEntropy);
  constexpr VehicleBulkSessionConfig baseline_vehicle =
      make_r19_vehicle_bulk_session_config(BulkSessionFeature::Enabled,
                                           kIdentity, kEntropy);
  constexpr GroundBulkSessionConfig next_ground =
      make_r19_ground_bulk_session_config(BulkSessionFeature::Enabled,
                                          next_identity, next_entropy);
  constexpr VehicleBulkSessionConfig next_vehicle =
      make_r19_vehicle_bulk_session_config(BulkSessionFeature::Enabled,
                                           next_identity, next_entropy);

  report.check(next_ground.ground_boot_id == next_identity.boot_id &&
                   next_ground.ground_session_id == next_identity.session_id &&
                   next_vehicle.vehicle_boot_id == next_identity.boot_id &&
                   next_vehicle.lease_sequence == next_identity.session_id,
               "updated identity was not inherited exactly");
  report.check(next_ground.request_sequence !=
                       baseline_ground.request_sequence &&
                   next_ground.ground_nonce != baseline_ground.ground_nonce &&
                   next_vehicle.vehicle_challenge_nonce !=
                       baseline_vehicle.vehicle_challenge_nonce,
               "identity/entropy changes were not bound into role outputs");
  report.check(next_ground.ground_nonce !=
                   next_vehicle.vehicle_challenge_nonce,
               "next Ground/Vehicle nonce domains aliased");
}

void test_valid_input_domain_sweep(TestReport& report) {
  for (std::uint32_t index = 1U; index <= 4096U; ++index) {
    const BootSessionIdentity identity{
        0x01000000U + index,
        static_cast<std::uint16_t>((index % 0xFFFFU) + 1U)};
    const Phase6HighSpeedRoleEntropy entropy{
        0x0102030405060708ULL + index,
        0xA0B0C0D0E0F00000ULL +
            static_cast<std::uint64_t>(index) * 3U};
    const GroundBulkSessionConfig ground =
        make_r19_ground_bulk_session_config(BulkSessionFeature::Enabled,
                                            identity, entropy);
    const VehicleBulkSessionConfig vehicle =
        make_r19_vehicle_bulk_session_config(BulkSessionFeature::Enabled,
                                             identity, entropy);
    report.check(ground.feature == BulkSessionFeature::Enabled &&
                     ground.ground_boot_id == identity.boot_id &&
                     ground.ground_session_id == identity.session_id &&
                     ground.request_sequence != 0U &&
                     ground.request_sequence != identity.session_id &&
                     ground.ground_nonce != 0U &&
                     vehicle.feature == BulkSessionFeature::Enabled &&
                     vehicle.vehicle_boot_id == identity.boot_id &&
                     vehicle.lease_sequence == identity.session_id &&
                     vehicle.vehicle_challenge_nonce != 0U &&
                     vehicle.mavlink_sequence != 0U &&
                     ground.ground_nonce !=
                         vehicle.vehicle_challenge_nonce,
                 "valid-input sweep violated identity, nonzero, or domain separation");
  }
}

}  // namespace

TestReport run_phase6_high_speed_role_config_test(
    const std::string& test_id, std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-HS-ROLE-CONFIG-001") {
    test_enabled_mapping_and_domain_separation(report);
    test_disabled_and_invalid_inputs_fail_closed(report);
    test_input_changes_are_bound(report);
    test_valid_input_domain_sweep(report);
  } else {
    report.check(false, "unknown Phase6 high-speed role config test ID");
  }

  report.trace.record({0U, "host", "HS_ROLE_CONFIG", 0U,
                       report.passed ? "PASS" : "FAIL", true,
                       0U, 0U, 0U});
  return report;
}

}  // namespace vc_lora::test
