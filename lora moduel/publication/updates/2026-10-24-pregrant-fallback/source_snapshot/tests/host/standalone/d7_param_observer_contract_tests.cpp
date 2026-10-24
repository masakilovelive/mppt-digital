#define VC_LORA_PHASE6_VEHICLE_DIAGNOSTICS 1

#include "vc_lora_vehicle_diag_observer.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

namespace {

using vc_lora_vehicle_diag_observer::D7ParamValueStats;

bool check(bool condition, const char* message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", message);
  }
  return condition;
}

void store_u16_le(std::uint16_t value, std::uint8_t* output) {
  output[0U] = static_cast<std::uint8_t>(value & 0xFFU);
  output[1U] = static_cast<std::uint8_t>((value >> 8U) & 0xFFU);
}

std::array<std::uint8_t, 25U> make_param_value_payload(
    float value, std::uint16_t count, std::uint16_t index,
    const char* id, std::uint8_t type) {
  std::array<std::uint8_t, 25U> payload{};
  std::uint32_t value_bits = 0U;
  static_assert(sizeof(value_bits) == sizeof(value),
                "host contract requires a 32-bit float");
  std::memcpy(&value_bits, &value, sizeof(value_bits));
  payload[0U] = static_cast<std::uint8_t>(value_bits & 0xFFU);
  payload[1U] = static_cast<std::uint8_t>((value_bits >> 8U) & 0xFFU);
  payload[2U] = static_cast<std::uint8_t>((value_bits >> 16U) & 0xFFU);
  payload[3U] = static_cast<std::uint8_t>((value_bits >> 24U) & 0xFFU);
  store_u16_le(count, payload.data() + 4U);
  store_u16_le(index, payload.data() + 6U);
  if (id != nullptr) {
    const std::size_t length = std::min<std::size_t>(std::strlen(id), 16U);
    std::copy_n(reinterpret_cast<const std::uint8_t*>(id), length,
                payload.begin() + 8U);
  }
  payload[24U] = type;
  return payload;
}

vc_lora::MavlinkFrame make_param_value_v1(
    std::uint8_t sequence, std::uint8_t system_id,
    std::uint8_t component_id, const std::array<std::uint8_t, 25U>& payload) {
  vc_lora::MavlinkFrame frame{};
  if (!vc_lora::encode_mavlink_v1(sequence, system_id, component_id, 22U,
                                  payload.data(), payload.size(), frame)) {
    std::fprintf(stderr, "FAIL: could not encode MAVLink1 PARAM_VALUE\n");
  }
  return frame;
}

vc_lora::MavlinkFrame make_param_value_v2(
    std::uint8_t sequence, std::uint8_t system_id,
    std::uint8_t component_id, const std::array<std::uint8_t, 25U>& payload) {
  vc_lora::MavlinkFrame frame{};
  if (!vc_lora::encode_mavlink_v2(sequence, system_id, component_id, 22U,
                                  payload.data(), payload.size(), frame)) {
    std::fprintf(stderr, "FAIL: could not encode MAVLink2 PARAM_VALUE\n");
  }
  return frame;
}

vc_lora::MavlinkFrame make_heartbeat(std::uint8_t sequence,
                                     std::uint8_t system_id = 1U,
                                     std::uint8_t component_id = 1U) {
  constexpr std::array<std::uint8_t, 9U> payload{};
  vc_lora::MavlinkFrame frame{};
  if (!vc_lora::encode_mavlink_v2(sequence, system_id, component_id, 0U,
                                  payload.data(), payload.size(), frame)) {
    std::fprintf(stderr, "FAIL: could not encode heartbeat\n");
  }
  return frame;
}

void reset_observer() {
  using namespace vc_lora_vehicle_diag_observer;
  stats = {};
  pixhawk_d7_parser = {};
}

void feed(const vc_lora::MavlinkFrame& frame, std::size_t count,
          std::uint64_t now_ms) {
  const std::size_t bounded_count = std::min(count, frame.size);
  for (std::size_t index = 0U; index < bounded_count; ++index) {
    vc_lora_vehicle_diag_observer::observe_pixhawk_read(frame.bytes[index],
                                                        now_ms);
  }
}

void feed(const vc_lora::MavlinkFrame& frame, std::size_t count,
          std::uint64_t now_ms,
          const vc_lora_vehicle_diag_observer::VehicleHeartbeatRuntimeContext&
              context) {
  const std::size_t bounded_count = std::min(count, frame.size);
  for (std::size_t index = 0U; index < bounded_count; ++index) {
    vc_lora_vehicle_diag_observer::observe_pixhawk_read(
        frame.bytes[index], now_ms, context);
  }
}

bool id_is(const D7ParamValueStats& stats, const char* expected) {
  return std::strncmp(stats.last_param_id.data(), expected, 17U) == 0;
}

std::uint32_t float_bits(float value) {
  std::uint32_t bits = 0U;
  static_assert(sizeof(bits) == sizeof(value),
                "host contract requires a 32-bit float");
  std::memcpy(&bits, &value, sizeof(bits));
  return bits;
}

bool same_param_evidence(const D7ParamValueStats& left,
                         const D7ParamValueStats& right) {
  return left.last_param_id == right.last_param_id &&
         left.decoded == right.decoded &&
         left.serial1_baud_exact == right.serial1_baud_exact &&
         left.decode_errors == right.decode_errors &&
         left.counter_overflows == right.counter_overflows &&
         left.last_ms == right.last_ms &&
         left.last_value_bits == right.last_value_bits &&
         left.last_count == right.last_count &&
         left.last_index == right.last_index &&
         left.last_type == right.last_type &&
         left.last_sequence == right.last_sequence &&
         left.last_system_id == right.last_system_id &&
         left.last_component_id == right.last_component_id &&
         left.serial1_last_ms == right.serial1_last_ms &&
         left.serial1_last_value_bits == right.serial1_last_value_bits &&
         left.serial1_last_count == right.serial1_last_count &&
         left.serial1_last_index == right.serial1_last_index &&
         left.serial1_last_type == right.serial1_last_type &&
         left.serial1_last_sequence == right.serial1_last_sequence &&
         left.serial1_last_system_id == right.serial1_last_system_id &&
         left.serial1_last_component_id == right.serial1_last_component_id;
}

bool check_serial1_v1() {
  reset_observer();
  vc_lora_vehicle_diag_observer::stats.target.latched = 1U;
  vc_lora_vehicle_diag_observer::stats.target.d6_msg20 = 1U;
  vc_lora_vehicle_diag_observer::stats.target.d6_exact = 1U;
  vc_lora_vehicle_diag_observer::stats.target.request_param_index = -1;
  vc_lora_vehicle_diag_observer::stats.target.cycle_id = 7U;
  const auto payload = make_param_value_payload(
      57.0F, 932U, 0xFFFFU, "SERIAL1_BAUD", 6U);
  const auto frame = make_param_value_v1(41U, 1U, 1U, payload);
  feed(frame, frame.size, 1234U);

  const auto& observed =
      vc_lora_vehicle_diag_observer::stats.pixhawk_d7_param_value;
  bool passed = true;
  passed &= check(observed.decoded == 1U,
                  "valid MAVLink1 PARAM_VALUE must increment pvok");
  passed &= check(observed.serial1_baud_exact == 1U,
                  "exact padded SERIAL1_BAUD must increment pvs1");
  passed &= check(id_is(observed, "SERIAL1_BAUD"),
                  "MAVLink1 param_id extraction failed");
  passed &= check(observed.last_value_bits == 0x42640000U &&
                      observed.last_value_bits == float_bits(57.0F),
                  "SERIAL1_BAUD value bits must be 42640000 (57.0)");
  passed &= check(observed.last_count == 932U,
                  "SERIAL1_BAUD param_count must decode as 932");
  passed &= check(observed.last_index == 0xFFFFU,
                  "SERIAL1_BAUD param_index must decode as 65535");
  passed &= check(observed.last_type == 6U,
                  "SERIAL1_BAUD param_type must decode as 6");
  passed &= check(observed.last_sequence == 41U,
                  "MAVLink1 sequence metadata mismatch");
  passed &= check(observed.last_system_id == 1U,
                  "MAVLink1 system id metadata mismatch");
  passed &= check(observed.last_component_id == 1U,
                  "MAVLink1 component id metadata mismatch");
  passed &= check(observed.last_ms == 1234U,
                  "MAVLink1 final-byte time metadata mismatch");
  passed &= check(observed.serial1_last_value_bits == 0x42640000U &&
                      observed.serial1_last_count == 932U &&
                      observed.serial1_last_index == 0xFFFFU &&
                      observed.serial1_last_type == 6U &&
                      observed.serial1_last_sequence == 41U &&
                      observed.serial1_last_system_id == 1U &&
                      observed.serial1_last_component_id == 1U &&
                      observed.serial1_last_ms == 1234U,
                  "target-specific SERIAL1_BAUD tuple was not retained");
  passed &= check(
      vc_lora_vehicle_diag_observer::stats.target.d7_msg22 == 1U &&
          vc_lora_vehicle_diag_observer::stats.target.d7_matching_index == 1U &&
          vc_lora_vehicle_diag_observer::stats.target.d7_msg22_ms == 1234U,
      "strict SERIAL1_BAUD did not advance the correlated D7 target stage");
  return passed;
}

bool check_invalid_input_is_non_counting() {
  using namespace vc_lora_vehicle_diag_observer;
  const D7ParamValueStats baseline = stats.pixhawk_d7_param_value;
  bool passed = true;

  const auto partial_payload = make_param_value_payload(
      18.5F, 933U, 17U, "STAT_RUNTIME", 9U);
  const auto partial = make_param_value_v2(50U, 2U, 3U, partial_payload);
  feed(partial, partial.size - 1U, 2000U);
  passed &= check(same_param_evidence(stats.pixhawk_d7_param_value, baseline),
                  "partial PARAM_VALUE must not change PARAM_VALUE evidence");
  pixhawk_d7_parser.reset();

  auto bad_crc = make_param_value_v2(51U, 2U, 3U, partial_payload);
  bad_crc.bytes[bad_crc.size - 1U] ^= 0x80U;
  feed(bad_crc, bad_crc.size, 2001U);
  passed &= check(same_param_evidence(stats.pixhawk_d7_param_value, baseline),
                  "CRC-bad PARAM_VALUE must not change PARAM_VALUE evidence");

  vc_lora::MavlinkFrame unsupported{};
  unsupported.size = 8U;
  unsupported.bytes[0U] = vc_lora::kMavlinkV1Magic;
  unsupported.bytes[1U] = 0U;
  unsupported.bytes[2U] = 52U;
  unsupported.bytes[3U] = 2U;
  unsupported.bytes[4U] = 3U;
  unsupported.bytes[5U] = 250U;
  unsupported.bytes[6U] = 0U;
  unsupported.bytes[7U] = 0U;
  feed(unsupported, unsupported.size, 2002U);
  passed &= check(same_param_evidence(stats.pixhawk_d7_param_value, baseline),
                  "unsupported MAVLink message must not change evidence");
  return passed;
}

bool check_v2_distinction_and_exact_match() {
  using namespace vc_lora_vehicle_diag_observer;
  bool passed = true;

  const auto wrong_source_payload = make_param_value_payload(
      57.0F, 933U, 0xFFFFU, "SERIAL1_BAUD", 6U);
  const auto wrong_source =
      make_param_value_v2(69U, 2U, 1U, wrong_source_payload);
  feed(wrong_source, wrong_source.size, 2900U);
  const auto wrong_value_payload = make_param_value_payload(
      58.0F, 933U, 0xFFFFU, "SERIAL1_BAUD", 6U);
  const auto wrong_value =
      make_param_value_v2(70U, 1U, 1U, wrong_value_payload);
  feed(wrong_value, wrong_value.size, 2950U);
  passed &= check(stats.pixhawk_d7_param_value.serial1_baud_exact == 1U &&
                      stats.target.d7_msg22 == 1U &&
                      stats.target.d7_matching_index == 1U &&
                      stats.target.d7_msg22_ms == 1234U,
                  "wrong-source/value SERIAL1_BAUD advanced target evidence");

  const auto prefix_payload = make_param_value_payload(
      57.0F, 934U, 0xFFFFU, "SERIAL1_BAUDX", 6U);
  const auto prefix = make_param_value_v2(71U, 1U, 1U, prefix_payload);
  feed(prefix, prefix.size, 3000U);
  passed &= check(stats.pixhawk_d7_param_value.decoded == 4U,
                  "valid non-target MAVLink2 PARAM_VALUE must increment pvok");
  passed &= check(stats.pixhawk_d7_param_value.serial1_baud_exact == 1U,
                  "SERIAL1_BAUD prefix must not increment exact pvs1");
  passed &= check(id_is(stats.pixhawk_d7_param_value, "SERIAL1_BAUDX"),
                  "full 16-byte param_id comparison is required");

  const auto stat_payload = make_param_value_payload(
      57.0F, 935U, 0xFFFFU, "STAT_RUNTIME", 6U);
  const auto stat_frame = make_param_value_v2(99U, 1U, 1U, stat_payload);
  feed(stat_frame, stat_frame.size, 4321U);
  const auto& observed = stats.pixhawk_d7_param_value;
  passed &= check(observed.decoded == 5U,
                  "valid MAVLink2 STAT_RUNTIME must increment pvok");
  passed &= check(observed.serial1_baud_exact == 1U,
                  "later STAT_RUNTIME must preserve cumulative pvs1");
  passed &= check(id_is(observed, "STAT_RUNTIME"),
                  "STAT_RUNTIME must remain distinguishable in pvid");
  passed &= check(observed.last_value_bits == float_bits(57.0F) &&
                      observed.last_count == 935U &&
                      observed.last_index == 0xFFFFU &&
                      observed.last_type == 6U,
                  "MAVLink2 PARAM_VALUE payload metadata mismatch");
  passed &= check(observed.last_sequence == 99U &&
                      observed.last_system_id == 1U &&
                      observed.last_component_id == 1U &&
                      observed.last_ms == 4321U,
                  "MAVLink2 frame/time metadata mismatch");
  passed &= check(observed.serial1_last_value_bits == 0x42640000U &&
                      observed.serial1_last_count == 932U &&
                      observed.serial1_last_index == 0xFFFFU &&
                      observed.serial1_last_type == 6U &&
                      observed.serial1_last_sequence == 41U &&
                      observed.serial1_last_system_id == 1U &&
                      observed.serial1_last_component_id == 1U &&
                      observed.serial1_last_ms == 1234U,
                  "later STAT_RUNTIME overwrote target SERIAL1_BAUD tuple");
  passed &= check(
      stats.target.d7_msg22 == 1U &&
          stats.target.d7_matching_index == 1U &&
          stats.target.d7_msg22_ms == 1234U,
      "STAT_RUNTIME advanced the strict correlated D7 target stage");
  return passed;
}

bool check_primary_heartbeat_gap_latch() {
  using namespace vc_lora_vehicle_diag_observer;
  reset_observer();
  VehicleHeartbeatRuntimeContext context{};
  context.state = static_cast<std::uint8_t>(
      vc_lora::VehicleTddState::DownlinkSend);
  context.cycle = 7U;
  context.aux = 1U;
  context.radio_busy = 0U;
  context.pending_action = 0U;
  context.scheduler_queued_frames = 3U;
  context.scheduler_queued_bytes = 96U;
  context.generic_parameter_frames = 2U;
  context.generic_parameter_active = 1U;
  context.pending_parameter_requests = 1U;
  context.prioritized_parameter_values = 1U;
  context.heartbeat_pending = 0U;
  context.heartbeat_tail_available = 0U;
  context.heartbeat_active = 0U;
  context.heartbeat_active_progress = 0U;
  feed(make_heartbeat(250U), make_heartbeat(250U).size, 1000U, context);

  context.state = static_cast<std::uint8_t>(
      vc_lora::VehicleTddState::ReturnGuard);
  context.cycle = 8U;
  context.aux = 0U;
  context.radio_busy = 1U;
  context.pending_action = 1U;
  context.scheduler_queued_frames = 1025U;
  context.scheduler_queued_bytes = 65535U;
  context.generic_parameter_frames = 1024U;
  context.generic_parameter_active = 1U;
  context.pending_parameter_requests = 2U;
  context.prioritized_parameter_values = 1U;
  context.heartbeat_pending = 1U;
  context.heartbeat_tail_available = 1U;
  context.heartbeat_active = 1U;
  context.heartbeat_active_progress = 1U;
  const auto second = make_heartbeat(251U);
  feed(second, second.size, 3500U, context);

  context.cycle = 9U;
  const auto third = make_heartbeat(252U);
  feed(third, third.size, 5000U, context);
  context.cycle = 10U;
  context.scheduler_queued_frames = 777U;
  context.scheduler_queued_bytes = 32000U;
  context.generic_parameter_frames = 700U;
  const auto fourth = make_heartbeat(253U);
  feed(fourth, fourth.size, 8001U, context);
  context.cycle = 11U;
  context.scheduler_queued_frames = 0U;
  context.scheduler_queued_bytes = 0U;
  context.generic_parameter_frames = 0U;
  const auto fifth = make_heartbeat(254U);
  feed(fifth, fifth.size, 9000U, context);
  const auto foreign = make_heartbeat(9U, 2U, 1U);
  feed(foreign, foreign.size, 12000U, context);

  const auto& gap = stats.pixhawk_d7_primary_heartbeat_gap;
  return check(
      gap.events == 5U && gap.gap_observations == 4U &&
          gap.gap_violation_count == 1U &&
          gap.last_sequence == 254U && gap.last_ms == 9000U &&
          gap.latest.gap_ms == 999U &&
          gap.maximum.gap_ms == 3001U &&
          gap.maximum.event_ms == 8001U &&
          gap.maximum.previous_sequence == 252U &&
          gap.maximum.sequence == 253U &&
          gap.maximum.context.state ==
              static_cast<std::uint8_t>(
                  vc_lora::VehicleTddState::ReturnGuard) &&
          gap.maximum.context.cycle == 10U &&
          gap.maximum.context.aux == 0U &&
          gap.maximum.context.radio_busy == 1U &&
          gap.maximum.context.pending_action == 1U &&
          gap.maximum.context.scheduler_queued_frames == 777U &&
          gap.maximum.context.scheduler_queued_bytes == 32000U &&
          gap.maximum.context.generic_parameter_frames == 700U &&
          gap.maximum.context.generic_parameter_active == 1U &&
          gap.maximum.context.pending_parameter_requests == 2U &&
          gap.maximum.context.prioritized_parameter_values == 1U &&
          gap.maximum.context.heartbeat_pending == 1U &&
          gap.maximum.context.heartbeat_tail_available == 1U &&
          gap.maximum.context.heartbeat_active == 1U &&
          gap.maximum.context.heartbeat_active_progress == 1U &&
          gap.latest_violation.gap_ms == 3001U &&
          gap.latest_violation.event_ms == 8001U &&
          gap.latest_violation.context.scheduler_queued_frames == 777U &&
          gap.latest_violation.context.generic_parameter_frames == 700U,
      "D7 primary-heartbeat maximum-gap context was not retained");
}

}  // namespace

int main() {
  bool passed = check_serial1_v1();
  passed &= check_invalid_input_is_non_counting();
  passed &= check_v2_distinction_and_exact_match();
  passed &= check_primary_heartbeat_gap_latch();
  if (!passed) {
    return 1;
  }
  std::puts("PASS FW-D7-PARAM-OBSERVER-001");
  return 0;
}
