#pragma once

// R19 high-speed design contract. This file is deliberately not selected by
// either accepted R18 sketch and contains no device-I/O implementation. Its
// timing values are hypotheses for staged AUX/air-service characterization,
// not authorization to flash hardware.

#include <array>
#include <cstddef>
#include <cstdint>

namespace vc_lora::experimental {

struct HighSpeedCandidateContract {
  // Read-only inventory result measured on both attached radios. Version 0x20
  // is firmware metadata, not a unique T22S/T30D physical-model identifier.
  static inline constexpr std::uint8_t expected_inventory_version = 0x20U;
  static inline constexpr std::array<std::uint8_t, 8U> expected_profile{{
      0x00U, 0x00U, 0xE5U, 0xC3U,
      0x46U, 0x00U, 0x00U, 0x00U}};
  static inline constexpr bool inventory_version_is_model_identity = false;
  static inline constexpr bool physical_model_label_required = true;

  // The first candidate leaves the stored profile unchanged: UART 115200,
  // air 19.2 kbps, 32-byte subpackets. Profile mutation is a later, separately
  // authorized experiment only after model/power/BOM verification.
  static inline constexpr std::uint32_t radio_uart_bps = 115200U;
  static inline constexpr std::uint32_t radio_air_bps = 19200U;
  static inline constexpr std::size_t radio_chunk_bytes = 32U;
  // VCB1 reserves 13 bytes in every physical chunk for magic, kind/length,
  // transfer tag, transfer-global fragment ordinal, and CRC16.
  static inline constexpr std::size_t bulk_fragment_payload_bytes = 19U;
  static inline constexpr std::size_t documented_internal_buffer_bytes = 400U;
  static inline constexpr bool persistent_profile_writes_allowed = false;

  // Proposed staged values. A 3-ms start gap matches the ceiling of one
  // 32-byte 8N1 UART write at 115200 bps; AUX must still gate admission.
  // The 100-ms direction guard is intentionally separate from same-direction
  // buffering because AUX HIGH does not prove the final packet left the air.
  static inline constexpr std::uint32_t candidate_uart_write_gap_ms = 3U;
  static inline constexpr std::uint32_t aux_high_stable_ms = 15U;
  static inline constexpr std::uint32_t initial_downlink_ms = 100U;
  static inline constexpr std::uint32_t native_stream_downlink_ms = 28000U;
  static inline constexpr std::uint32_t direction_guard_ms = 100U;
  static inline constexpr std::uint32_t uplink_window_ms = 150U;
  static inline constexpr std::uint32_t vehicle_receive_timeout_ms = 350U;
  static inline constexpr std::uint32_t late_terminal_wait_ms = 350U;

  // Existing semantic guarantees are requirements, not tunable speed knobs.
  static inline constexpr std::uint32_t heartbeat_hard_deadline_ms = 2500U;
  static inline constexpr bool preserve_mavlink_frame_order = true;
  static inline constexpr bool preserve_real_heartbeat_priority = true;
  static inline constexpr bool one_initial_uplink_then_native_stream = true;

  // Exact parameter-only accounting from the preserved accepted 932-value
  // corpus. Each 37-byte MAVLink2 PARAM_VALUE occupies two independently
  // padded VCB1 physical chunks. Heartbeat chunks are accounted separately
  // and do not change the parameter terminal-evidence constants below.
  static inline constexpr std::uint64_t expected_parameter_count = 932U;
  static inline constexpr std::uint64_t mavlink2_param_value_bytes = 37U;
  static inline constexpr std::size_t param_value_wire_chunks_per_frame =
      (mavlink2_param_value_bytes + bulk_fragment_payload_bytes - 1U) /
      bulk_fragment_payload_bytes;
  static inline constexpr std::size_t param_value_wire_bytes_per_frame =
      param_value_wire_chunks_per_frame * radio_chunk_bytes;
  // Unsigned MAVLink2 HEARTBEAT is 10-byte header + 9-byte payload + CRC.
  // Its 21 bytes exceed VCB1's 19-byte payload, so a complete heartbeat is
  // two physical chunks (HEAD then TAIL), not one raw 32-byte calculation.
  static inline constexpr std::uint64_t mavlink2_heartbeat_bytes = 21U;
  static inline constexpr std::size_t heartbeat_wire_chunks_per_frame =
      (mavlink2_heartbeat_bytes + bulk_fragment_payload_bytes - 1U) /
      bulk_fragment_payload_bytes;
  static inline constexpr std::size_t heartbeat_wire_bytes_per_frame =
      heartbeat_wire_chunks_per_frame * radio_chunk_bytes;
  static inline constexpr std::uint64_t expected_parameter_wire_chunks =
      1864U;
  static inline constexpr std::uint64_t expected_parameter_wire_bytes =
      59648U;
  static inline constexpr std::uint64_t target_completion_ms = 30000U;
  static inline constexpr std::uint64_t stretch_completion_ms = 10000U;

  static inline constexpr std::uint64_t parameter_air_lower_bound_ms =
      (expected_parameter_wire_bytes * 8U * 1000U + radio_air_bps - 1U) /
      radio_air_bps;
  static inline constexpr std::uint64_t production_floor_lower_bound_ms =
      expected_parameter_wire_chunks * 550U;
  static inline constexpr std::uint64_t production_gap_lower_bound_ms =
      expected_parameter_wire_chunks * 180U;
  static inline constexpr std::uint64_t candidate_uart_feed_ms =
      expected_parameter_wire_chunks * candidate_uart_write_gap_ms;

  // Ground-visible 30-second SLA boundary. t0 is acceptance of a complete
  // MAVLink PARAM_REQUEST_LIST (#21) at Ground USB. t1 is the host-visible
  // USB commit of the final PARAM_VALUE (#22), index 931. Terminal VCTA
  // evidence follows t1 and therefore must not be mixed into this interval.
  static inline constexpr std::uint32_t sla_start_message_id = 21U;
  static inline constexpr std::uint32_t sla_terminal_message_id = 22U;
  static inline constexpr std::uint16_t sla_terminal_parameter_index = 931U;
  static inline constexpr bool sla_ends_at_ground_usb_commit = true;

  // Until a bulk-mode heartbeat policy has been implemented and proven, use
  // the conservative inclusive allowance of 31 complete HEARTBEAT frames.
  // The critical interval also includes one mandatory Grant, the two VCBN
  // negotiation messages, and the one VCRC receipt proving that Vehicle's
  // VCBN response was consumed before bulk downlink starts. All frame classes
  // use exact 32-byte chunks.
  static inline constexpr std::uint64_t sla_grant_wire_chunks = 1U;
  static inline constexpr std::uint64_t sla_negotiation_wire_chunks = 2U;
  static inline constexpr std::uint64_t
      sla_negotiation_receipt_wire_chunks = 1U;
  static inline constexpr std::uint64_t sla_parameter_wire_chunks =
      expected_parameter_wire_chunks;
  static inline constexpr std::uint64_t sla_conservative_heartbeat_frames =
      31U;
  static inline constexpr std::uint64_t sla_heartbeat_wire_chunks =
      sla_conservative_heartbeat_frames * heartbeat_wire_chunks_per_frame;
  static inline constexpr std::uint64_t sla_critical_wire_chunks =
      sla_grant_wire_chunks + sla_negotiation_wire_chunks +
      sla_negotiation_receipt_wire_chunks + sla_parameter_wire_chunks +
      sla_heartbeat_wire_chunks;
  static inline constexpr std::uint64_t sla_critical_wire_bytes =
      sla_critical_wire_chunks * radio_chunk_bytes;
  static inline constexpr std::uint64_t sla_air_payload_lower_bound_ms =
      (sla_critical_wire_bytes * 8U * 1000U + radio_air_bps - 1U) /
      radio_air_bps;
  static inline constexpr std::uint64_t sla_uart_feed_ms =
      sla_critical_wire_chunks * candidate_uart_write_gap_ms;

  // Schedule terms are added to the payload-air lower bound. They do not
  // include LoRa packet overhead, AUX/drain uncertainty, retry cost, or host
  // scheduling jitter, so neither sum is a physical completion upper bound.
  static inline constexpr std::uint64_t current_grant_wait_ms = 4600U;
  static inline constexpr std::uint64_t candidate_grant_wait_budget_ms = 500U;
  // Grant down -> request up -> response down -> response receipt up -> bulk
  // down is four physical direction reversals before t1.
  static inline constexpr std::uint64_t sla_direction_guard_count = 4U;
  static inline constexpr std::uint64_t sla_direction_guard_budget_ms =
      sla_direction_guard_count * direction_guard_ms;
  static inline constexpr std::uint64_t ground_usb_commit_budget_ms = 100U;
  static inline constexpr std::uint64_t current_schedule_lower_bound_ms =
      sla_air_payload_lower_bound_ms + current_grant_wait_ms +
      sla_direction_guard_budget_ms + ground_usb_commit_budget_ms;
  static inline constexpr std::uint64_t integration_candidate_lower_bound_ms =
      sla_air_payload_lower_bound_ms + candidate_grant_wait_budget_ms +
      sla_direction_guard_budget_ms + ground_usb_commit_budget_ms;
  static inline constexpr std::uint64_t
      integration_candidate_unproven_margin_ms =
          target_completion_ms - integration_candidate_lower_bound_ms;

  // Eight VCTA terminal-evidence chunks and the one VCRC receipt proving that
  // Ground consumed the terminal record are post-SLA. The bulk-down -> VCTA-up
  // and VCTA-up -> receipt-down reversals are likewise full-session-only.
  static inline constexpr std::uint64_t post_sla_vcta_wire_chunks = 8U;
  static inline constexpr std::uint64_t
      post_sla_terminal_receipt_wire_chunks = 1U;
  static inline constexpr std::uint64_t post_sla_direction_guard_count = 2U;
  static inline constexpr std::uint64_t
      post_sla_direction_guard_budget_ms =
          post_sla_direction_guard_count * direction_guard_ms;
  static inline constexpr std::uint64_t
      full_session_direction_guard_budget_ms =
          sla_direction_guard_budget_ms +
          post_sla_direction_guard_budget_ms;
  static inline constexpr std::uint64_t full_session_wire_chunks =
      sla_critical_wire_chunks + post_sla_vcta_wire_chunks +
      post_sla_terminal_receipt_wire_chunks;
  static inline constexpr std::uint64_t full_session_wire_bytes =
      full_session_wire_chunks * radio_chunk_bytes;
  static inline constexpr std::uint64_t
      full_session_air_payload_lower_bound_ms =
          (full_session_wire_bytes * 8U * 1000U + radio_air_bps - 1U) /
          radio_air_bps;
  static inline constexpr std::uint64_t
      integration_full_session_lower_bound_ms =
          full_session_air_payload_lower_bound_ms +
          candidate_grant_wait_budget_ms +
          full_session_direction_guard_budget_ms +
          ground_usb_commit_budget_ms;
  static inline constexpr bool vcta_is_post_sla = true;

  // These booleans state only what the lower-bound arithmetic establishes.
  // The present 4.6-second Grant schedule cannot meet 30 seconds even before
  // unmodelled cost. A 500-ms Grant budget is arithmetically feasible, but it
  // still has 3.266 seconds of unproven physical margin and is not a proof.
  static inline constexpr bool current_schedule_30s_impossible =
      current_schedule_lower_bound_ms > target_completion_ms;
  static inline constexpr bool integration_candidate_feasible =
      integration_candidate_lower_bound_ms < target_completion_ms;
  static inline constexpr bool physical_30s_proven = false;
  static inline constexpr bool bulk_heartbeat_policy_required = true;
  static inline constexpr bool bulk_heartbeat_policy_proven = false;
  static inline constexpr bool uart_feed_must_overlap_air =
      integration_candidate_lower_bound_ms + sla_uart_feed_ms >
      target_completion_ms;
  static inline constexpr bool ten_seconds_impossible_at_current_profile =
      sla_air_payload_lower_bound_ms > stretch_completion_ms;

  // Closed until the printed model is captured and progressive 550 -> 180 ->
  // 50 -> 20 -> 3 ms AUX/remote-delivery trials prove loss-free admission and
  // a safe direction-change bound on both physical radios.
  static inline constexpr bool live_flash_authorized = false;
};

static_assert(HighSpeedCandidateContract::expected_profile[2] == 0xE5U);
static_assert(HighSpeedCandidateContract::expected_profile[3] == 0xC3U);
static_assert(HighSpeedCandidateContract::radio_chunk_bytes == 32U);
static_assert(HighSpeedCandidateContract::bulk_fragment_payload_bytes == 19U);
static_assert(
    HighSpeedCandidateContract::param_value_wire_chunks_per_frame == 2U);
static_assert(
    HighSpeedCandidateContract::param_value_wire_bytes_per_frame == 64U);
static_assert(HighSpeedCandidateContract::heartbeat_wire_chunks_per_frame ==
              2U);
static_assert(HighSpeedCandidateContract::heartbeat_wire_bytes_per_frame ==
              64U);
static_assert(HighSpeedCandidateContract::documented_internal_buffer_bytes >=
              HighSpeedCandidateContract::radio_chunk_bytes);
static_assert(HighSpeedCandidateContract::sla_critical_wire_chunks == 1930U);
static_assert(HighSpeedCandidateContract::sla_critical_wire_bytes == 61760U);
static_assert(
    HighSpeedCandidateContract::sla_air_payload_lower_bound_ms == 25734U);
static_assert(
    HighSpeedCandidateContract::current_schedule_30s_impossible);
static_assert(HighSpeedCandidateContract::integration_candidate_feasible);
static_assert(!HighSpeedCandidateContract::physical_30s_proven);
static_assert(HighSpeedCandidateContract::bulk_heartbeat_policy_required);
static_assert(!HighSpeedCandidateContract::bulk_heartbeat_policy_proven);
static_assert(HighSpeedCandidateContract::uart_feed_must_overlap_air);
static_assert(
    HighSpeedCandidateContract::ten_seconds_impossible_at_current_profile);
static_assert(!HighSpeedCandidateContract::persistent_profile_writes_allowed);
static_assert(!HighSpeedCandidateContract::live_flash_authorized);

}  // namespace vc_lora::experimental
