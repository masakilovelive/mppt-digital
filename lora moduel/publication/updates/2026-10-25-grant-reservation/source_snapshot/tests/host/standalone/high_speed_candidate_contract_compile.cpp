#include "../../../firmware/high_speed/vc_lora_high_speed_candidate.hpp"

using vc_lora::experimental::HighSpeedCandidateContract;

static_assert(HighSpeedCandidateContract::expected_parameter_count == 932U);
static_assert(HighSpeedCandidateContract::mavlink2_param_value_bytes == 37U);
static_assert(HighSpeedCandidateContract::radio_chunk_bytes == 32U);
static_assert(HighSpeedCandidateContract::expected_parameter_wire_chunks ==
              1864U);
static_assert(HighSpeedCandidateContract::expected_parameter_wire_bytes ==
              59648U);
static_assert(HighSpeedCandidateContract::parameter_air_lower_bound_ms ==
              24854U);
static_assert(HighSpeedCandidateContract::production_floor_lower_bound_ms ==
              1025200U);
static_assert(HighSpeedCandidateContract::production_gap_lower_bound_ms ==
              335520U);
static_assert(HighSpeedCandidateContract::candidate_uart_feed_ms == 5592U);
static_assert(HighSpeedCandidateContract::parameter_air_lower_bound_ms <
              HighSpeedCandidateContract::target_completion_ms);
static_assert(HighSpeedCandidateContract::parameter_air_lower_bound_ms >
              HighSpeedCandidateContract::stretch_completion_ms);
static_assert(HighSpeedCandidateContract::persistent_profile_writes_allowed ==
              false);
static_assert(HighSpeedCandidateContract::live_flash_authorized == false);
static_assert(HighSpeedCandidateContract::physical_model_label_required);
static_assert(!HighSpeedCandidateContract::inventory_version_is_model_identity);
static_assert(HighSpeedCandidateContract::preserve_mavlink_frame_order);
static_assert(HighSpeedCandidateContract::preserve_real_heartbeat_priority);

int main() { return 0; }
