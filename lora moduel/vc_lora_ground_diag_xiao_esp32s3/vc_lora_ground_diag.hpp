#pragma once

#if !defined(VC_LORA_PHASE6_GROUND)
#error "Ground diagnostics require VC_LORA_PHASE6_GROUND"
#endif

#if !defined(VC_LORA_PHASE6_GROUND_DIAGNOSTICS)
#error "Ground diagnostics require VC_LORA_PHASE6_GROUND_DIAGNOSTICS"
#endif

#include <Arduino.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <type_traits>

#include "vc_lora_ground_diag_observer.hpp"

namespace vc_lora_ground_diag {

using namespace vc_lora;
using namespace vc_lora_phase6_firmware;

constexpr char kQuery[] = "VCGSTAT?\n";
constexpr std::size_t kReportCapacity = 4096U;
constexpr std::size_t kUsbWriteChunk = 64U;

static_assert(sizeof(kQuery) ==
                  sizeof(vc_lora_ground_diag_observer::kQuery),
              "Ground diagnostic query contract differs from router");

struct Snapshot {
  std::uint32_t query_id{0U};
  std::uint64_t now_ms{0U};
  std::uint32_t boot_id{0U};
  std::uint8_t startup_status{0U};
  std::uint8_t startup_fault{0U};
  std::uint8_t ready{0U};
  std::uint8_t fail_closed{0U};
  std::uint8_t state{0U};
  std::uint8_t has_valid_grant{0U};
  std::uint8_t aux{0U};
  std::uint8_t radio_busy_value{0U};
  std::uint8_t pending_action{0U};
  std::uint8_t e220_state{0U};
  std::uint8_t e220_fault{0U};
  std::uint16_t session_id{0U};
  std::uint16_t cycle_id{0U};
  std::uint16_t granted_bytes{0U};
  std::uint16_t actual_bytes{0U};
  std::uint64_t window_deadline_ms{0U};
  LinkDiagnostics link{};
  GroundIngressStats ingress{};
  MavlinkParserDiagnostics ingress_parser{};
  vc_lora_ground_diag_observer::ObserverStats observer{};
  ValidatedLocalIngressStats downlink_endpoint{};
  LocalEgressStats usb_egress{};
  std::size_t ingress_queued_bytes{0U};
  std::size_t ingress_queued_frames{0U};
  std::size_t usb_parser_buffered{0U};
  std::size_t downlink_queued_bytes{0U};
};

static_assert(std::is_trivially_copyable<Snapshot>::value,
              "Ground diagnostic snapshot must remain POD");

inline std::array<char, kReportCapacity> report{};
inline std::size_t report_size{0U};
inline std::size_t report_offset{0U};
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
  snapshot.startup_status =
      static_cast<std::uint8_t>(startup_contract.status());
  snapshot.startup_fault =
      static_cast<std::uint8_t>(startup_contract.fault());
  snapshot.ready = bridge_ready ? 1U : 0U;
  snapshot.fail_closed = runtime_fail_closed ? 1U : 0U;
  snapshot.state = static_cast<std::uint8_t>(tdd_controller.state());
  snapshot.has_valid_grant =
      tdd_controller.has_valid_grant() ? 1U : 0U;
  snapshot.aux = aux_high() ? 1U : 0U;
  snapshot.radio_busy_value = radio_busy ? 1U : 0U;
  snapshot.pending_action = pending_radio_action.active ? 1U : 0U;
  snapshot.e220_state =
      static_cast<std::uint8_t>(e220_write_contract.state());
  snapshot.e220_fault =
      static_cast<std::uint8_t>(e220_write_contract.fault());
  snapshot.session_id = tdd_controller.session_id();
  snapshot.cycle_id = tdd_controller.cycle_id();
  snapshot.granted_bytes = tdd_controller.granted_bytes();
  snapshot.actual_bytes = tdd_controller.actual_bytes();
  snapshot.window_deadline_ms = tdd_controller.window_deadline_ms();
  snapshot.link = link_diagnostics;
  snapshot.ingress = ground_ingress.stats();
  snapshot.ingress_parser = ground_ingress.parser_diagnostics();
  snapshot.observer = vc_lora_ground_diag_observer::stats;
  snapshot.downlink_endpoint = radio_application_endpoint.stats();
  snapshot.usb_egress = radio_application_endpoint.egress().stats();
  snapshot.ingress_queued_bytes = ground_ingress.queued_bytes();
  snapshot.ingress_queued_frames = ground_ingress.queued_frames();
  snapshot.usb_parser_buffered =
      vc_lora_ground_diag_observer::usb_parser.buffered_size();
  snapshot.downlink_queued_bytes =
      radio_application_endpoint.egress().queued_bytes();
  return snapshot;
}

inline void set_format_error_report() noexcept {
  constexpr char kError[] =
      "GCSTAT1 q=0 ms=0 error=format\n"
      "GCSTAT2 q=0 ms=0 error=format\n"
      "GCSTAT3 q=0 ms=0 error=format\n";
  std::copy_n(kError, sizeof(kError), report.data());
  report_size = sizeof(kError) - 1U;
  report_offset = 0U;
}

inline void format_report(const Snapshot& s) noexcept {
  const auto& d = s.link;
  const auto& i = s.ingress;
  const auto& o = s.observer;
  const auto& dl = s.downlink_endpoint;
  const auto& ue = s.usb_egress;
  const int written = std::snprintf(
      report.data(), report.size(),
      "GCSTAT1 q=%lu ms=%llu v=1 boot=%lu ss=%u sf=%u ready=%u fail=%u st=%u sid=%u cy=%u hv=%u gb=%u ab=%u wd=%llu aux=%u rb=%u pa=%u ew=%u ef=%u gr=%llu dup=%llu fut=%llu stcy=%llu stss=%llu schg=%llu raw=%llu ctl=%llu cgr=%llu ca=%llu cd=%llu cf=%llu csc=%llu css=%llu ci=%llu lcst=%u lcsid=%u lccy=%u lcms=%llu cc=%llu cuv=%llu cut=%llu cm=%llu\n"
      "GCSTAT2 q=%lu ms=%llu ubi=%llu uvf=%llu u20=%llu ucr=%llu uiv=%llu uqf=%llu uqfb=%u uqb=%u ubq=%llu ufc=%llu ufdq=%llu ubdq=%llu udf=%llu udb=%llu uoe=%llu urc=%llu uic=%llu ubuf=%u qreq=%llu qmm=%llu qto=%llu dlb=%llu dlf=%llu dli=%llu dlo=%llu dlq=%u usbacc=%llu usbcm=%llu usbz=%llu usbsh=%llu\n"
      "GCSTAT3 q=%lu ms=%llu utx=%llu upb=%llu itx=%llu dtx=%llu ar=%llu ex=%llu ins=%llu tg=%llu ng=%llu adi=%llu aci=%llu aii=%llu lat=%u lacy=%u lams=%llu sc=%llu se0=%llu se1=%llu se2=%llu se3=%llu se4=%llu se5=%llu r0=%llu r1=%llu r2=%llu r3=%llu r4=%llu r5=%llu c0=%llu c1=%llu c2=%llu c3=%llu c4=%llu c5=%llu hd=%llu ubdrop=%llu\n",
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
      static_cast<unsigned int>(s.has_valid_grant),
      static_cast<unsigned int>(s.granted_bytes),
      static_cast<unsigned int>(s.actual_bytes),
      static_cast<unsigned long long>(s.window_deadline_ms),
      static_cast<unsigned int>(s.aux),
      static_cast<unsigned int>(s.radio_busy_value),
      static_cast<unsigned int>(s.pending_action),
      static_cast<unsigned int>(s.e220_state),
      static_cast<unsigned int>(s.e220_fault),
      static_cast<unsigned long long>(d.grant_rx),
      static_cast<unsigned long long>(d.duplicate_grants),
      static_cast<unsigned long long>(d.future_cycles),
      static_cast<unsigned long long>(d.stale_cycles),
      static_cast<unsigned long long>(d.stale_sessions),
      static_cast<unsigned long long>(d.session_changes),
      static_cast<unsigned long long>(o.e220_raw_bytes),
      static_cast<unsigned long long>(o.control_messages),
      static_cast<unsigned long long>(o.control_grants),
      static_cast<unsigned long long>(o.control_accepted),
      static_cast<unsigned long long>(o.control_duplicate),
      static_cast<unsigned long long>(o.control_future),
      static_cast<unsigned long long>(o.control_stale_cycle),
      static_cast<unsigned long long>(o.control_stale_session),
      static_cast<unsigned long long>(o.control_invalid),
      static_cast<unsigned int>(o.last_control_state),
      static_cast<unsigned int>(o.last_control_session),
      static_cast<unsigned int>(o.last_control_cycle),
      static_cast<unsigned long long>(o.last_control_ms),
      static_cast<unsigned long long>(d.control_crc_errors),
      static_cast<unsigned long long>(d.control_unknown_version),
      static_cast<unsigned long long>(d.control_unknown_type),
      static_cast<unsigned long long>(d.control_malformed),
      static_cast<unsigned long>(s.query_id),
      static_cast<unsigned long long>(s.now_ms),
      static_cast<unsigned long long>(o.usb_normal_bytes),
      static_cast<unsigned long long>(o.usb_frames_valid),
      static_cast<unsigned long long>(o.usb_msg20),
      static_cast<unsigned long long>(o.usb_bad_crc),
      static_cast<unsigned long long>(o.usb_invalid),
      static_cast<unsigned long long>(i.frames_queued),
      static_cast<unsigned int>(s.ingress_queued_frames),
      static_cast<unsigned int>(s.ingress_queued_bytes),
      static_cast<unsigned long long>(i.bytes_queued),
      static_cast<unsigned long long>(i.frames_completed),
      static_cast<unsigned long long>(i.frames_dequeued),
      static_cast<unsigned long long>(i.bytes_committed),
      static_cast<unsigned long long>(i.frames_dropped),
      static_cast<unsigned long long>(i.bytes_dropped),
      static_cast<unsigned long long>(i.overflow_events),
      static_cast<unsigned long long>(i.rejected_commits),
      static_cast<unsigned long long>(i.invalid_commits),
      static_cast<unsigned int>(s.usb_parser_buffered),
      static_cast<unsigned long long>(o.query_completed),
      static_cast<unsigned long long>(o.query_prefix_mismatch),
      static_cast<unsigned long long>(o.query_prefix_timeout),
      static_cast<unsigned long long>(dl.bytes_ingested),
      static_cast<unsigned long long>(dl.frames_validated),
      static_cast<unsigned long long>(dl.invalid_events),
      static_cast<unsigned long long>(dl.overflow_events),
      static_cast<unsigned int>(s.downlink_queued_bytes),
      static_cast<unsigned long long>(ue.bytes_physically_accepted),
      static_cast<unsigned long long>(ue.bytes_committed),
      static_cast<unsigned long long>(ue.zero_write_events),
      static_cast<unsigned long long>(ue.short_write_events),
      static_cast<unsigned long>(s.query_id),
      static_cast<unsigned long long>(s.now_ms),
      static_cast<unsigned long long>(d.uplink_transactions),
      static_cast<unsigned long long>(d.uplink_payload_bytes),
      static_cast<unsigned long long>(d.idle_tx),
      static_cast<unsigned long long>(d.done_tx),
      static_cast<unsigned long long>(d.action_retries),
      static_cast<unsigned long long>(d.expired_windows),
      static_cast<unsigned long long>(d.insufficient_window_count),
      static_cast<unsigned long long>(d.tx_gate_violation),
      static_cast<unsigned long long>(d.ground_tx_without_valid_grant),
      static_cast<unsigned long long>(o.action_data_issued),
      static_cast<unsigned long long>(o.action_done_issued),
      static_cast<unsigned long long>(o.action_idle_issued),
      static_cast<unsigned int>(o.last_action_type),
      static_cast<unsigned int>(o.last_action_cycle),
      static_cast<unsigned long long>(o.last_action_ms),
      static_cast<unsigned long long>(o.state_changes),
      static_cast<unsigned long long>(o.state_entries[0U]),
      static_cast<unsigned long long>(o.state_entries[1U]),
      static_cast<unsigned long long>(o.state_entries[2U]),
      static_cast<unsigned long long>(o.state_entries[3U]),
      static_cast<unsigned long long>(o.state_entries[4U]),
      static_cast<unsigned long long>(o.state_entries[5U]),
      static_cast<unsigned long long>(o.raw_by_state[0U]),
      static_cast<unsigned long long>(o.raw_by_state[1U]),
      static_cast<unsigned long long>(o.raw_by_state[2U]),
      static_cast<unsigned long long>(o.raw_by_state[3U]),
      static_cast<unsigned long long>(o.raw_by_state[4U]),
      static_cast<unsigned long long>(o.raw_by_state[5U]),
      static_cast<unsigned long long>(o.control_by_state[0U]),
      static_cast<unsigned long long>(o.control_by_state[1U]),
      static_cast<unsigned long long>(o.control_by_state[2U]),
      static_cast<unsigned long long>(o.control_by_state[3U]),
      static_cast<unsigned long long>(o.control_by_state[4U]),
      static_cast<unsigned long long>(o.control_by_state[5U]),
      static_cast<unsigned long long>(d.half_duplex_drop_count),
      static_cast<unsigned long long>(d.uart_buffer_drop_count));

  if (written <= 0 || static_cast<std::size_t>(written) >= report.size()) {
    set_format_error_report();
    return;
  }
  report_size = static_cast<std::size_t>(written);
  report_offset = 0U;
}

inline bool safe_to_format() noexcept {
  return tdd_controller.state() == GroundTddState::WaitGrant &&
         !radio_busy && !pending_radio_action.active;
}

inline void service() noexcept {
  if (!snapshot_pending && report_offset == report_size &&
      vc_lora_ground_diag_observer::query_request_pending &&
      vc_lora_ground_diag_observer::take_query_request()) {
    pending_snapshot = capture_snapshot();
    snapshot_pending = true;
  }

  if (snapshot_pending && safe_to_format()) {
    format_report(pending_snapshot);
    snapshot_pending = false;
  }

  if (report_offset >= report_size) {
    if (!snapshot_pending) {
      vc_lora_ground_diag_observer::finish_usb_report();
    }
    return;
  }
  const int writable = Serial.availableForWrite();
  if (writable <= 0) {
    return;
  }
  const std::size_t count = std::min<std::size_t>(
      {report_size - report_offset, kUsbWriteChunk,
       static_cast<std::size_t>(writable)});
  const std::size_t accepted = Serial.write(
      reinterpret_cast<const std::uint8_t*>(report.data() + report_offset),
      count);
  report_offset += std::min(accepted, count);
  if (report_offset == report_size) {
    vc_lora_ground_diag_observer::finish_usb_report();
  }
}

inline void begin() noexcept {
  report_size = 0U;
  report_offset = 0U;
  snapshot_pending = false;
}

}  // namespace vc_lora_ground_diag
