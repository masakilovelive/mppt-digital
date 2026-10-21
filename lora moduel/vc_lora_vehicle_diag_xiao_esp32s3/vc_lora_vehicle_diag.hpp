#pragma once

#if !defined(VC_LORA_PHASE6_VEHICLE)
#error "Vehicle diagnostics require VC_LORA_PHASE6_VEHICLE"
#endif

#if !defined(VC_LORA_PHASE6_VEHICLE_DIAGNOSTICS)
#error "Vehicle diagnostics require VC_LORA_PHASE6_VEHICLE_DIAGNOSTICS"
#endif

#include <Arduino.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "vc_lora_vehicle_diag_observer.hpp"

namespace vc_lora_vehicle_diag {

using namespace vc_lora_phase6_firmware;

constexpr std::uint32_t kUsbDiagnosticBaud = 115200U;
constexpr char kQuery[] = "VCSTAT?\n";
constexpr std::size_t kQuerySize = sizeof(kQuery) - 1U;
constexpr std::size_t kReportCapacity = 6144U;
constexpr std::size_t kUsbChunkCapacity = 64U;
constexpr std::size_t kEventTextCapacity = 2048U;

struct Snapshot {
  std::uint32_t query_id{0U};
  std::uint64_t now_ms{0U};
  std::uint32_t boot_id{0U};
  std::uint16_t session_id{0U};
  std::uint16_t cycle_id{0U};
  std::uint8_t ready{0U};
  std::uint8_t fail_closed{0U};
  std::uint8_t state{0U};
  std::uint8_t startup_status{0U};
  std::uint8_t startup_fault{0U};
  std::uint8_t aux{0U};
  std::uint8_t radio_busy_value{0U};
  std::uint8_t e220_state{0U};
  std::uint8_t e220_fault{0U};

  std::uint64_t grant_tx{0U};
  std::uint64_t done_rx{0U};
  std::uint64_t idle_rx{0U};
  std::uint64_t uplink_timeouts{0U};
  std::uint64_t control_crc_errors{0U};
  std::uint64_t outside_window_bytes{0U};

  std::uint64_t radio_bytes_ingested{0U};
  std::uint64_t radio_frames_validated{0U};
  std::uint64_t radio_frames_queued{0U};
  std::uint64_t radio_invalid_events{0U};
  std::uint64_t radio_crc_errors{0U};
  std::uint64_t radio_overflow_events{0U};
  std::size_t radio_parser_buffered{0U};

  std::size_t pixhawk_queue_bytes{0U};
  std::uint64_t pixhawk_bytes_accepted{0U};
  std::uint64_t pixhawk_bytes_committed{0U};
  std::uint64_t pixhawk_writes_completed{0U};
  std::uint64_t pixhawk_zero_writes{0U};
  std::uint64_t pixhawk_short_writes{0U};
  std::uint64_t pixhawk_overflow_events{0U};

  std::uint64_t pixhawk_frames_ingested{0U};
  std::uint64_t pixhawk_frames_forwarded{0U};
  std::uint64_t pixhawk_parser_crc_errors{0U};

  vc_lora_vehicle_diag_observer::ObserverStats observer{};
};

inline std::array<char, kReportCapacity> report{};
inline std::size_t report_size{0U};
inline std::size_t report_offset{0U};
inline std::size_t query_offset{0U};
inline std::uint32_t query_sequence{0U};
inline Snapshot pending_snapshot{};
inline bool snapshot_pending{false};

inline Snapshot capture_snapshot() noexcept {
  Snapshot snapshot{};
  ++query_sequence;
  if (query_sequence == 0U) {
    ++query_sequence;
  }
  snapshot.query_id = query_sequence;
  snapshot.now_ms = monotonic_now_ms();
  snapshot.boot_id = boot_identity.boot_id;
  snapshot.session_id = tdd_controller.session_id();
  snapshot.cycle_id = tdd_controller.cycle_id();
  snapshot.ready = bridge_ready ? 1U : 0U;
  snapshot.fail_closed = runtime_fail_closed ? 1U : 0U;
  snapshot.state = static_cast<std::uint8_t>(tdd_controller.state());
  snapshot.startup_status =
      static_cast<std::uint8_t>(startup_contract.status());
  snapshot.startup_fault =
      static_cast<std::uint8_t>(startup_contract.fault());
  snapshot.aux = aux_high() ? 1U : 0U;
  snapshot.radio_busy_value = radio_busy ? 1U : 0U;
  snapshot.e220_state =
      static_cast<std::uint8_t>(e220_write_contract.state());
  snapshot.e220_fault =
      static_cast<std::uint8_t>(e220_write_contract.fault());

  snapshot.grant_tx = link_diagnostics.grant_tx;
  snapshot.done_rx = link_diagnostics.done_rx;
  snapshot.idle_rx = link_diagnostics.idle_rx;
  snapshot.uplink_timeouts = link_diagnostics.uplink_timeouts;
  snapshot.control_crc_errors = link_diagnostics.control_crc_errors;
  snapshot.outside_window_bytes =
      link_diagnostics.uplink_data_outside_receive_window;

  const auto& endpoint_stats = radio_application_endpoint.stats();
  const auto& endpoint_parser =
      radio_application_endpoint.parser_diagnostics();
  snapshot.radio_bytes_ingested = endpoint_stats.bytes_ingested;
  snapshot.radio_frames_validated = endpoint_stats.frames_validated;
  snapshot.radio_frames_queued = endpoint_stats.frames_queued;
  snapshot.radio_invalid_events = endpoint_stats.invalid_events;
  snapshot.radio_crc_errors = endpoint_parser.crc_errors;
  snapshot.radio_overflow_events = endpoint_stats.overflow_events;
  snapshot.radio_parser_buffered =
      radio_application_endpoint.parser_buffered_size();

  const auto& local_egress = radio_application_endpoint.egress();
  const auto& local_stats = local_egress.stats();
  snapshot.pixhawk_queue_bytes = local_egress.queued_bytes();
  snapshot.pixhawk_bytes_accepted = local_stats.bytes_physically_accepted;
  snapshot.pixhawk_bytes_committed = local_stats.bytes_committed;
  snapshot.pixhawk_writes_completed = local_stats.writes_completed;
  snapshot.pixhawk_zero_writes = local_stats.zero_write_events;
  snapshot.pixhawk_short_writes = local_stats.short_write_events;
  snapshot.pixhawk_overflow_events = local_stats.overflow_events;

  const auto& scheduler_stats = vehicle_scheduler.diagnostics();
  const auto& scheduler_parser = vehicle_scheduler.parser_diagnostics();
  snapshot.pixhawk_frames_ingested = scheduler_stats.frames_ingested;
  snapshot.pixhawk_frames_forwarded = scheduler_stats.frames_forwarded;
  snapshot.pixhawk_parser_crc_errors = scheduler_parser.crc_errors;
  snapshot.observer = vc_lora_vehicle_diag_observer::stats;
  return snapshot;
}

inline void set_format_error_report() noexcept {
  constexpr char kError[] =
      "VCSTAT1 error=format\n"
      "VCSTAT2 error=format\n"
      "VCSTAT3 error=format\n";
  static_assert(sizeof(kError) <= kReportCapacity,
                "diagnostic error report too large");
  std::copy_n(kError, sizeof(kError), report.data());
  report_size = sizeof(kError) - 1U;
  report_offset = 0U;
}

inline bool format_target_events(
    const vc_lora_vehicle_diag_observer::TargetUplinkSnapshot& target,
    std::array<char, kEventTextCapacity>& output) noexcept {
  std::size_t offset = 0U;
  if (target.event_count == 0U) {
    output[0] = '-';
    output[1] = '\0';
    return true;
  }
  for (std::size_t logical = 0U; logical < target.event_count; ++logical) {
    const std::size_t index =
        (static_cast<std::size_t>(target.event_head) + logical) %
        vc_lora_vehicle_diag_observer::kTargetEventCapacity;
    const auto& event = target.events[index];
    const int written = std::snprintf(
        output.data() + offset, output.size() - offset,
        "%s%u,%u,%u,%llu,%u,%u", logical == 0U ? "" : ";",
        static_cast<unsigned int>(event.code),
        static_cast<unsigned int>(event.state),
        static_cast<unsigned int>(event.cycle),
        static_cast<unsigned long long>(event.ms),
        static_cast<unsigned int>(event.a),
        static_cast<unsigned int>(event.b));
    if (written <= 0 ||
        static_cast<std::size_t>(written) >= output.size() - offset) {
      return false;
    }
    offset += static_cast<std::size_t>(written);
  }
  return true;
}

inline void format_report(const Snapshot& s) noexcept {
  std::array<char, kEventTextCapacity> event_text{};
  if (!format_target_events(s.observer.target, event_text)) {
    set_format_error_report();
    return;
  }
  const auto& target = s.observer.target;
  const int written = std::snprintf(
      report.data(), report.size(),
      "VCSTAT1 q=%lu ms=%llu v=5 boot=%lu ss=%u sf=%u r=%u f=%u st=%u sid=%u cy=%u aux=%u rb=%u ew=%u ef=%u gr=%llu done=%llu idle=%llu ut=%llu cc=%llu raw=%llu rwi=%llu rwo=%llu uclt=%u ucls=%u uclcy=%u uclms=%llu rgseen=%u rgems=%llu owftv=%u owfel=%llu owfrem=%llu tl=%u tsid=%u tcy=%u tbms=%llu tbs=%u tfms=%llu tfs=%u tlms=%llu tls=%u trb=%u tbb=%u tfc=%u tis=%u\n"
      "VCSTAT2 q=%lu ms=%llu rib=%llu rif=%llu r20=%llu r23=%llu r76=%llu rcr=%llu riv=%llu rob=%llu rof=%llu o20=%llu o23=%llu o76=%llu ocr=%llu oiv=%llu owbds=%llu owbdd=%llu owbsg=%llu owbgd=%llu owbug=%llu owbur=%llu owbrg=%llu owfds=%llu owfdd=%llu owfsg=%llu owfgd=%llu owfug=%llu owfur=%llu owfrg=%llu owls=%u owlcy=%u owlms=%llu ebi=%llu evf=%llu eiv=%llu eov=%llu pb=%u out=%llu tdms=%llu tdst=%u tdcc=%u tdcy=%u tdsid=%u tdv=%u tdty=%u tdgd=%u tdwn=%u tdmx=%u tdac=%u tdgp=%llu tts=%u\n"
      "VCSTAT3 q=%lu ms=%llu d6b=%llu d6f=%llu d620=%llu d623=%llu d676=%llu d6cr=%llu d7b=%llu d7f=%llu d722=%llu d777=%llu d7cr=%llu udds=%llu uddd=%llu udsg=%llu udgd=%llu udug=%llu udur=%llu udrg=%llu uids=%llu uidd=%llu uisg=%llu uigd=%llu uiug=%llu uiur=%llu uirg=%llu qb=%u pa=%llu cm=%llu wc=%llu z=%llu sh=%llu eo=%llu si=%llu sf=%llu sc=%llu tpf=%u ttk=%u tei=%u tfr=%u tcb=%u tcf=%u td620=%u td6ms=%llu td722=%u td7ms=%llu tto=%llu tca=%u tcams=%llu tar=%u evn=%u evo=%u ev=%s\n",
      static_cast<unsigned long>(s.query_id),
      static_cast<unsigned long long>(s.now_ms),
      static_cast<unsigned long>(s.boot_id),
      static_cast<unsigned int>(s.startup_status),
      static_cast<unsigned int>(s.startup_fault),
      static_cast<unsigned int>(s.ready),
      static_cast<unsigned int>(s.fail_closed),
      static_cast<unsigned int>(s.state),
      static_cast<unsigned int>(s.session_id),
      static_cast<unsigned int>(s.cycle_id),
      static_cast<unsigned int>(s.aux),
      static_cast<unsigned int>(s.radio_busy_value),
      static_cast<unsigned int>(s.e220_state),
      static_cast<unsigned int>(s.e220_fault),
      static_cast<unsigned long long>(s.grant_tx),
      static_cast<unsigned long long>(s.done_rx),
      static_cast<unsigned long long>(s.idle_rx),
      static_cast<unsigned long long>(s.uplink_timeouts),
      static_cast<unsigned long long>(s.control_crc_errors),
      static_cast<unsigned long long>(s.observer.e220_raw_bytes),
      static_cast<unsigned long long>(s.observer.e220_raw_in_window),
      static_cast<unsigned long long>(
          s.observer.e220_raw_outside_window),
      static_cast<unsigned int>(s.observer.control_by_state.last_type),
      static_cast<unsigned int>(s.observer.control_by_state.last_state),
      static_cast<unsigned int>(s.observer.control_by_state.last_cycle),
      static_cast<unsigned long long>(s.observer.control_by_state.last_ms),
      static_cast<unsigned int>(s.observer.state_timing.return_guard_seen),
      static_cast<unsigned long long>(
          s.observer.state_timing.last_return_guard_entry_ms),
      static_cast<unsigned int>(
          s.observer.radio_outside_by_state.last_frame_timing_valid),
      static_cast<unsigned long long>(
          s.observer.radio_outside_by_state.last_frame_state_elapsed_ms),
      static_cast<unsigned long long>(
          s.observer.radio_outside_by_state.last_frame_state_remaining_ms),
      static_cast<unsigned int>(target.latched),
      static_cast<unsigned int>(target.session_id),
      static_cast<unsigned int>(target.cycle_id),
      static_cast<unsigned long long>(target.quarantine_begin_ms),
      static_cast<unsigned int>(target.quarantine_begin_state),
      static_cast<unsigned long long>(target.first_application_ms),
      static_cast<unsigned int>(target.first_application_state),
      static_cast<unsigned long long>(target.last_application_ms),
      static_cast<unsigned int>(target.last_application_state),
      static_cast<unsigned int>(target.received_bytes),
      static_cast<unsigned int>(target.buffered_bytes),
      static_cast<unsigned int>(target.frame_count),
      static_cast<unsigned int>(target.ingest_status),
      static_cast<unsigned long>(s.query_id),
      static_cast<unsigned long long>(s.now_ms),
      static_cast<unsigned long long>(
          s.observer.radio_in_window.bytes),
      static_cast<unsigned long long>(
          s.observer.radio_in_window.frames),
      static_cast<unsigned long long>(
          s.observer.radio_in_window.msg20),
      static_cast<unsigned long long>(
          s.observer.radio_in_window.msg23),
      static_cast<unsigned long long>(
          s.observer.radio_in_window.msg76),
      static_cast<unsigned long long>(
          s.observer.radio_in_window.crc_errors),
      static_cast<unsigned long long>(
          s.observer.radio_in_window.invalid),
      static_cast<unsigned long long>(s.observer.radio_outside_window.bytes),
      static_cast<unsigned long long>(
          s.observer.radio_outside_window.frames),
      static_cast<unsigned long long>(
          s.observer.radio_outside_window.msg20),
      static_cast<unsigned long long>(
          s.observer.radio_outside_window.msg23),
      static_cast<unsigned long long>(
          s.observer.radio_outside_window.msg76),
      static_cast<unsigned long long>(
          s.observer.radio_outside_window.crc_errors),
      static_cast<unsigned long long>(
          s.observer.radio_outside_window.invalid),
      static_cast<unsigned long long>(
          s.observer.radio_outside_by_state.bytes[0U]),
      static_cast<unsigned long long>(
          s.observer.radio_outside_by_state.bytes[1U]),
      static_cast<unsigned long long>(
          s.observer.radio_outside_by_state.bytes[2U]),
      static_cast<unsigned long long>(
          s.observer.radio_outside_by_state.bytes[3U]),
      static_cast<unsigned long long>(
          s.observer.radio_outside_by_state.bytes[4U]),
      static_cast<unsigned long long>(
          s.observer.radio_outside_by_state.bytes[5U]),
      static_cast<unsigned long long>(
          s.observer.radio_outside_by_state.bytes[6U]),
      static_cast<unsigned long long>(
          s.observer.radio_outside_by_state.frames[0U]),
      static_cast<unsigned long long>(
          s.observer.radio_outside_by_state.frames[1U]),
      static_cast<unsigned long long>(
          s.observer.radio_outside_by_state.frames[2U]),
      static_cast<unsigned long long>(
          s.observer.radio_outside_by_state.frames[3U]),
      static_cast<unsigned long long>(
          s.observer.radio_outside_by_state.frames[4U]),
      static_cast<unsigned long long>(
          s.observer.radio_outside_by_state.frames[5U]),
      static_cast<unsigned long long>(
          s.observer.radio_outside_by_state.frames[6U]),
      static_cast<unsigned int>(
          s.observer.radio_outside_by_state.last_state),
      static_cast<unsigned int>(
          s.observer.radio_outside_by_state.last_cycle),
      static_cast<unsigned long long>(
          s.observer.radio_outside_by_state.last_ms),
      static_cast<unsigned long long>(s.radio_bytes_ingested),
      static_cast<unsigned long long>(s.radio_frames_validated),
      static_cast<unsigned long long>(s.radio_invalid_events),
      static_cast<unsigned long long>(s.radio_overflow_events),
      static_cast<unsigned int>(s.radio_parser_buffered),
      static_cast<unsigned long long>(s.outside_window_bytes),
      static_cast<unsigned long long>(target.done_ms),
      static_cast<unsigned int>(target.done_state),
      static_cast<unsigned int>(target.done_seen),
      static_cast<unsigned int>(target.done_cycle_id),
      static_cast<unsigned int>(target.done_session_id),
      static_cast<unsigned int>(target.done_version),
      static_cast<unsigned int>(target.done_type),
      static_cast<unsigned int>(target.done_guard_ms),
      static_cast<unsigned int>(target.done_window_ms),
      static_cast<unsigned int>(target.done_max_bytes),
      static_cast<unsigned int>(target.done_actual_bytes),
      static_cast<unsigned long long>(target.done_gap_ms),
      static_cast<unsigned int>(target.terminal_status),
      static_cast<unsigned long>(s.query_id),
      static_cast<unsigned long long>(s.now_ms),
      static_cast<unsigned long long>(
          s.observer.pixhawk_d6_accepted.bytes),
      static_cast<unsigned long long>(
          s.observer.pixhawk_d6_accepted.frames),
      static_cast<unsigned long long>(
          s.observer.pixhawk_d6_accepted.msg20),
      static_cast<unsigned long long>(
          s.observer.pixhawk_d6_accepted.msg23),
      static_cast<unsigned long long>(
          s.observer.pixhawk_d6_accepted.msg76),
      static_cast<unsigned long long>(
          s.observer.pixhawk_d6_accepted.crc_errors),
      static_cast<unsigned long long>(
          s.observer.pixhawk_d7_received.bytes),
      static_cast<unsigned long long>(
          s.observer.pixhawk_d7_received.frames),
      static_cast<unsigned long long>(
          s.observer.pixhawk_d7_received.msg22),
      static_cast<unsigned long long>(
          s.observer.pixhawk_d7_received.msg77),
      static_cast<unsigned long long>(
          s.observer.pixhawk_d7_received.crc_errors),
      static_cast<unsigned long long>(s.observer.control_by_state.done[0U]),
      static_cast<unsigned long long>(s.observer.control_by_state.done[1U]),
      static_cast<unsigned long long>(s.observer.control_by_state.done[2U]),
      static_cast<unsigned long long>(s.observer.control_by_state.done[3U]),
      static_cast<unsigned long long>(s.observer.control_by_state.done[4U]),
      static_cast<unsigned long long>(s.observer.control_by_state.done[5U]),
      static_cast<unsigned long long>(s.observer.control_by_state.done[6U]),
      static_cast<unsigned long long>(s.observer.control_by_state.idle[0U]),
      static_cast<unsigned long long>(s.observer.control_by_state.idle[1U]),
      static_cast<unsigned long long>(s.observer.control_by_state.idle[2U]),
      static_cast<unsigned long long>(s.observer.control_by_state.idle[3U]),
      static_cast<unsigned long long>(s.observer.control_by_state.idle[4U]),
      static_cast<unsigned long long>(s.observer.control_by_state.idle[5U]),
      static_cast<unsigned long long>(s.observer.control_by_state.idle[6U]),
      static_cast<unsigned int>(s.pixhawk_queue_bytes),
      static_cast<unsigned long long>(s.pixhawk_bytes_accepted),
      static_cast<unsigned long long>(s.pixhawk_bytes_committed),
      static_cast<unsigned long long>(s.pixhawk_writes_completed),
      static_cast<unsigned long long>(s.pixhawk_zero_writes),
      static_cast<unsigned long long>(s.pixhawk_short_writes),
      static_cast<unsigned long long>(s.pixhawk_overflow_events),
      static_cast<unsigned long long>(s.pixhawk_frames_ingested),
      static_cast<unsigned long long>(s.pixhawk_frames_forwarded),
      static_cast<unsigned long long>(s.pixhawk_parser_crc_errors),
      static_cast<unsigned int>(
          target.commit_preflight_seen == 0U
              ? 0U
              : (target.commit_preflight_ok != 0U ? 2U : 1U)),
      static_cast<unsigned int>(
          target.commit_take_seen == 0U
              ? 0U
              : (target.commit_take_ok != 0U ? 2U : 1U)),
      static_cast<unsigned int>(
          target.commit_egress_seen == 0U
              ? 0U
              : (target.commit_egress_ok != 0U ? 2U : 1U)),
      static_cast<unsigned int>(target.commit_free_bytes),
      static_cast<unsigned int>(target.commit_bytes),
      static_cast<unsigned int>(target.commit_frames),
      static_cast<unsigned int>(target.d6_msg20),
      static_cast<unsigned long long>(target.d6_msg20_ms),
      static_cast<unsigned int>(target.d7_msg22),
      static_cast<unsigned long long>(target.d7_msg22_ms),
      static_cast<unsigned long long>(target.timeout_delta),
      static_cast<unsigned int>(target.timeout_cancelled),
      static_cast<unsigned long long>(target.cycle_advance_ms),
      static_cast<unsigned int>(target.abort_reason),
      static_cast<unsigned int>(target.event_count),
      static_cast<unsigned int>(target.event_overflow),
      event_text.data());

  if (written <= 0 || static_cast<std::size_t>(written) >= report.size()) {
    set_format_error_report();
    return;
  }
  report_size = static_cast<std::size_t>(written);
  report_offset = 0U;
}

inline void accept_query_byte(char byte) noexcept {
  if (byte == '\r') {
    return;
  }
  if (byte == kQuery[query_offset]) {
    ++query_offset;
    if (query_offset == kQuerySize) {
      query_offset = 0U;
      if (report_offset == report_size && !snapshot_pending) {
        pending_snapshot = capture_snapshot();
        snapshot_pending = true;
      }
    }
    return;
  }
  query_offset = byte == kQuery[0] ? 1U : 0U;
}

inline void collect_query() noexcept {
  constexpr std::size_t kReadBudget = 64U;
  std::size_t read_count = 0U;
  while (read_count < kReadBudget && Serial.available() > 0) {
    const int value = Serial.read();
    if (value < 0) {
      break;
    }
    accept_query_byte(static_cast<char>(value));
    ++read_count;
  }
}

inline void pump_report() noexcept {
  if (report_offset >= report_size) {
    return;
  }
  const int available = Serial.availableForWrite();
  if (available <= 0) {
    return;
  }
  const std::size_t remaining = report_size - report_offset;
  const std::size_t chunk_size = std::min(
      {remaining, static_cast<std::size_t>(available), kUsbChunkCapacity});
  if (chunk_size == 0U) {
    return;
  }

  std::array<char, kUsbChunkCapacity + 1U> chunk{};
  std::copy_n(report.data() + report_offset, chunk_size, chunk.data());
  chunk[chunk_size] = '\0';
  const std::size_t accepted = Serial.print(chunk.data());
  report_offset += std::min(accepted, chunk_size);
}

inline bool safe_to_report() noexcept {
  if (!bridge_ready || runtime_fail_closed) {
    return true;
  }
  return tdd_controller.state() == vc_lora::VehicleTddState::DownlinkSend &&
         !radio_busy && !pending_radio_action.active;
}

inline void begin() noexcept {
  Serial.begin(kUsbDiagnosticBaud);
}

inline void service() noexcept {
  collect_query();
  if (!safe_to_report()) {
    return;
  }
  if (snapshot_pending) {
    format_report(pending_snapshot);
    snapshot_pending = false;
  }
  pump_report();
}

}  // namespace vc_lora_vehicle_diag
