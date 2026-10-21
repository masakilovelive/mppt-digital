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
constexpr std::size_t kReportCapacity = 10240U;
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
  std::uint8_t usb_connected_predicate{0U};
  std::uint8_t usb_host_present{0U};
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
  std::uint8_t proxy_state{0U};
  std::uint8_t proxy_strategy{0U};
  std::uint8_t proxy_active{0U};
  std::uint8_t proxy_request_admitted{0U};
  std::uint8_t proxy_request_dequeued{0U};
  std::uint16_t proxy_expected_index{0U};
  std::uint16_t proxy_param_count{0U};
  std::uint32_t proxy_request_token{0U};
  std::uint64_t proxy_dequeue_goal{0U};
  std::uint64_t proxy_done_goal{0U};
  std::size_t front_frame_bytes{0U};
  std::size_t front_frame_wire_bytes{0U};
  std::uint64_t window_deadline_ms{0U};
  LinkDiagnostics link{};
  GroundParameterDownloadProxyDiagnostics proxy{};
  GroundParameterRecoveryLatch proxy_recovery_latch{};
  GroundIngressStats ingress{};
  MavlinkParserDiagnostics ingress_parser{};
  MavlinkParserDiagnostics radio_parser{};
  GroundUsbOrderedBacklogDiagnostics ordered_backlog{};
  GroundUsbHeartbeatPacerDiagnostics heartbeat_pacer{};
  vc_lora_ground_diag_observer::ObserverStats observer{};
  ValidatedLocalIngressStats downlink_endpoint{};
  LocalEgressStats usb_egress{};
  std::size_t ingress_queued_bytes{0U};
  std::size_t ingress_queued_frames{0U};
  std::size_t usb_parser_buffered{0U};
  std::size_t radio_parser_buffered{0U};
  std::size_t radio_demux_buffered{0U};
  std::size_t downlink_queued_bytes{0U};
  std::size_t ordered_backlog_queued_frames{0U};
  std::size_t ordered_backlog_queued_bytes{0U};
  std::size_t heartbeat_pacer_queued{0U};
  std::uint8_t heartbeat_pacer_pending{0U};
  std::uint8_t heartbeat_pacer_admitted{0U};
  std::uint8_t radio_demux_escaping{0U};
  std::uint8_t proxy_recovery_active{0U};
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
  const bool usb_host_present = Serial.isPlugged();
  snapshot.usb_host_present = usb_host_present ? 1U : 0U;
  snapshot.usb_connected_predicate =
      (usb_host_present && static_cast<bool>(Serial)) ? 1U : 0U;
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
  snapshot.proxy_state =
      static_cast<std::uint8_t>(ground_parameter_proxy.state());
  snapshot.proxy_strategy =
      static_cast<std::uint8_t>(ground_parameter_proxy.list_strategy());
  snapshot.proxy_active = ground_parameter_proxy.active() ? 1U : 0U;
  snapshot.proxy_request_admitted =
      ground_proxy_request_admitted ? 1U : 0U;
  snapshot.proxy_request_dequeued =
      ground_proxy_request_dequeued ? 1U : 0U;
  snapshot.proxy_expected_index = ground_parameter_proxy.expected_index();
  snapshot.proxy_param_count = ground_parameter_proxy.param_count();
  snapshot.proxy_request_token = ground_proxy_request_token;
  snapshot.proxy_dequeue_goal = ground_proxy_request_dequeue_goal;
  snapshot.proxy_done_goal = ground_proxy_request_done_goal;
  snapshot.front_frame_bytes = ground_ingress.front_frame_remaining();
  snapshot.front_frame_wire_bytes =
      ground_ingress.front_frame_wire_bytes();
  snapshot.window_deadline_ms = tdd_controller.window_deadline_ms();
  snapshot.link = link_diagnostics;
  snapshot.proxy = ground_parameter_proxy.diagnostics();
  snapshot.proxy_recovery_latch =
      ground_parameter_proxy.recovery_latch();
  snapshot.ingress = ground_ingress.stats();
  snapshot.ingress_parser = ground_ingress.parser_diagnostics();
  snapshot.radio_parser = ground_radio_application_parser.diagnostics();
  snapshot.ordered_backlog = ground_usb_ordered_backlog.diagnostics();
  snapshot.heartbeat_pacer = ground_usb_heartbeat_pacer.diagnostics();
  snapshot.observer = vc_lora_ground_diag_observer::stats;
  snapshot.downlink_endpoint = radio_application_endpoint.stats();
  snapshot.usb_egress = radio_application_endpoint.egress().stats();
  snapshot.ingress_queued_bytes = ground_ingress.queued_bytes();
  snapshot.ingress_queued_frames = ground_ingress.queued_frames();
  snapshot.usb_parser_buffered =
      vc_lora_ground_diag_observer::usb_parser.buffered_size();
  snapshot.radio_parser_buffered =
      ground_radio_application_parser.buffered_size();
  snapshot.radio_demux_buffered = radio_demux.buffered_size();
  snapshot.radio_demux_escaping =
      radio_demux.link_data_escaping() ? 1U : 0U;
  snapshot.proxy_recovery_active =
      ground_parameter_proxy.native_stream_recovery_active() ? 1U : 0U;
  snapshot.downlink_queued_bytes =
      radio_application_endpoint.egress().queued_bytes();
  snapshot.ordered_backlog_queued_frames =
      ground_usb_ordered_backlog.queued_frames();
  snapshot.ordered_backlog_queued_bytes =
      ground_usb_ordered_backlog.queued_bytes();
  snapshot.heartbeat_pacer_queued = ground_usb_heartbeat_pacer.queued();
  snapshot.heartbeat_pacer_pending =
      ground_usb_heartbeat_pacer.has_pending_emit() ? 1U : 0U;
  snapshot.heartbeat_pacer_admitted =
      ground_usb_heartbeat_pacer.has_admitted_emit() ? 1U : 0U;
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
  const auto& p = s.proxy;
  const auto& prl = s.proxy_recovery_latch;
  const auto& i = s.ingress;
  const auto& rp = s.radio_parser;
  const auto& ob = s.ordered_backlog;
  const auto& hp = s.heartbeat_pacer;
  const auto& o = s.observer;
  const auto& hr = o.rf_primary_heartbeat_gap;
  const auto& hu = o.usb_primary_heartbeat_gap;
  const auto& dl = s.downlink_endpoint;
  const auto& ue = s.usb_egress;
  const int written = std::snprintf(
      report.data(), report.size(),
      "GCSTAT1 q=%lu ms=%llu v=2 boot=%lu ss=%u sf=%u ready=%u fail=%u st=%u sid=%u cy=%u hv=%u gb=%u ab=%u wd=%llu aux=%u rb=%u pa=%u ew=%u ef=%u gr=%llu dup=%llu fut=%llu stcy=%llu stss=%llu schg=%llu raw=%llu ctl=%llu cgr=%llu ca=%llu cd=%llu cf=%llu csc=%llu css=%llu ci=%llu lcst=%u lcsid=%u lccy=%u lcms=%llu cc=%llu cuv=%llu cut=%llu cm=%llu cdcp=%u cdcs=%llu cdct=%llu cdcup=%llu cdcdn=%llu cdcms=%llu usjp=%u usjps=%llu usjpt=%llu usjpup=%llu usjpdn=%llu usjpms=%llu rse=%llu rsr=%u rsms=%llu rsst=%u rscy=%u rsrdy=%u\n"
      "GCSTAT2 q=%lu ms=%llu ubi=%llu uvf=%llu u20=%llu ucr=%llu uiv=%llu uqf=%llu uqfb=%u uqb=%u ubq=%llu ufc=%llu ufdq=%llu ubdq=%llu udf=%llu udb=%llu uoe=%llu urc=%llu uic=%llu ubuf=%u qreq=%llu qmm=%llu qto=%llu dlb=%llu dlf=%llu dli=%llu dlo=%llu dlq=%u usbacc=%llu usbcm=%llu usbz=%llu usbsh=%llu uv20=%llu u21=%llu upcon=%llu upfwd=%llu upinv=%llu rfv=%llu rf20=%llu rf22=%llu rfdc=%llu rfq=%llu rfd=%llu epc=%llu epdis=%llu epwait=%llu epprog=%llu epinv=%llu eplqb=%llu eplqa=%llu eplcb=%llu eplca=%llu rfbq=%llu rfpc=%llu rfinv=%llu obf=%u obb=%u obp22=%u obfq=%llu obfr=%llu obif=%llu obof=%llu obdf=%llu obdb=%llu s1rx=%llu s1ok=%llu s1q=%llu s1bq=%llu s1dc=%llu s1d=%llu s1pc=%llu s1iv=%llu s1ega=%llu s1egc=%llu s1egp=%u s1ego=%llu s1egl=%llu s1val=%08lX s1cnt=%u s1idx=%u s1ty=%u s1seq=%u s1sys=%u s1cmp=%u s1ms=%llu\n"
      "GCSTAT3 q=%lu ms=%llu utx=%llu upb=%llu itx=%llu dtx=%llu ar=%llu ex=%llu ins=%llu tg=%llu ng=%llu adi=%llu aci=%llu aii=%llu lat=%u lacy=%u lams=%llu sc=%llu se0=%llu se1=%llu se2=%llu se3=%llu se4=%llu se5=%llu r0=%llu r1=%llu r2=%llu r3=%llu r4=%llu r5=%llu c0=%llu c1=%llu c2=%llu c3=%llu c4=%llu c5=%llu hd=%llu ubdrop=%llu pst=%u pmode=%u pact=%u pidx=%u pcnt=%u padm=%u pdeq=%u ptok=%lu pdg=%llu pog=%llu front=%u wire=%u deq=%llu data=%llu done=%llu idle=%llu actual=%u pnat=%llu ppois=%llu pnq=%llu ppre=%llu pgen=%llu ptx=%llu pwto=%llu psfail=%llu prej=%llu datai=%llu donei=%llu idlei=%llu dacc=%llu dnak=%llu xacc=%llu xnak=%llu iacc=%llu inak=%llu pwe=%llu pwr=%u pwtok=%lu pwms=%llu\n",
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
      static_cast<unsigned int>(s.usb_connected_predicate),
      static_cast<unsigned long long>(o.usb_predicate_samples),
      static_cast<unsigned long long>(o.usb_predicate_transitions),
      static_cast<unsigned long long>(
          o.usb_predicate_connected_transitions),
      static_cast<unsigned long long>(
          o.usb_predicate_disconnected_transitions),
      static_cast<unsigned long long>(
          o.usb_predicate_last_transition_ms),
      static_cast<unsigned int>(s.usb_host_present),
      static_cast<unsigned long long>(o.usb_host_presence_samples),
      static_cast<unsigned long long>(o.usb_host_presence_transitions),
      static_cast<unsigned long long>(o.usb_host_present_transitions),
      static_cast<unsigned long long>(o.usb_host_absent_transitions),
      static_cast<unsigned long long>(
          o.usb_host_presence_last_transition_ms),
      static_cast<unsigned long long>(o.runtime_stop_events),
      static_cast<unsigned int>(o.runtime_stop_first_reason),
      static_cast<unsigned long long>(o.runtime_stop_first_ms),
      static_cast<unsigned int>(o.runtime_stop_first_state),
      static_cast<unsigned int>(o.runtime_stop_first_cycle),
      static_cast<unsigned int>(o.runtime_stop_first_ready),
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
      static_cast<unsigned long long>(o.usb_msg20),
      static_cast<unsigned long long>(o.usb_msg21),
      static_cast<unsigned long long>(o.usb_proxy_consumed),
      static_cast<unsigned long long>(o.usb_proxy_forwarded),
      static_cast<unsigned long long>(o.usb_proxy_invalid),
      static_cast<unsigned long long>(o.rf_frames_valid),
      static_cast<unsigned long long>(o.rf_msg20),
      static_cast<unsigned long long>(o.rf_msg22),
      static_cast<unsigned long long>(
          o.rf_downlink_disconnected_rejected),
      static_cast<unsigned long long>(o.rf_downlink_queued),
      static_cast<unsigned long long>(o.rf_downlink_dropped),
      static_cast<unsigned long long>(o.usb_pump_calls),
      static_cast<unsigned long long>(o.usb_pump_disconnected),
      static_cast<unsigned long long>(o.usb_pump_writer_unavailable),
      static_cast<unsigned long long>(o.usb_pump_progress),
      static_cast<unsigned long long>(o.usb_pump_invalid),
      static_cast<unsigned long long>(o.usb_egress_last_queued_before),
      static_cast<unsigned long long>(o.usb_egress_last_queued_after),
      static_cast<unsigned long long>(
          o.usb_egress_last_committed_before),
      static_cast<unsigned long long>(
          o.usb_egress_last_committed_after),
      static_cast<unsigned long long>(o.rf_downlink_backlog_queued),
      static_cast<unsigned long long>(o.rf_downlink_proxy_consumed),
      static_cast<unsigned long long>(o.rf_downlink_invalid),
      static_cast<unsigned int>(s.ordered_backlog_queued_frames),
      static_cast<unsigned int>(s.ordered_backlog_queued_bytes),
      static_cast<unsigned int>(
          o.ordered_backlog_param_value_frames),
      static_cast<unsigned long long>(ob.frames_queued),
      static_cast<unsigned long long>(ob.frames_released),
      static_cast<unsigned long long>(ob.invalid_frames),
      static_cast<unsigned long long>(ob.overflow_frames),
      static_cast<unsigned long long>(ob.discarded_frames),
      static_cast<unsigned long long>(ob.discarded_bytes),
      static_cast<unsigned long long>(o.rf_serial1_baud_exact),
      static_cast<unsigned long long>(o.rf_serial1_baud_expected),
      static_cast<unsigned long long>(o.rf_serial1_endpoint_queued),
      static_cast<unsigned long long>(o.rf_serial1_backlog_queued),
      static_cast<unsigned long long>(
          o.rf_serial1_disconnected_rejected),
      static_cast<unsigned long long>(o.rf_serial1_endpoint_dropped),
      static_cast<unsigned long long>(o.rf_serial1_proxy_consumed),
      static_cast<unsigned long long>(o.rf_serial1_invalid),
      static_cast<unsigned long long>(o.rf_serial1_egress_goals_armed),
      static_cast<unsigned long long>(o.rf_serial1_egress_committed),
      static_cast<unsigned int>(o.rf_serial1_egress_pending),
      static_cast<unsigned long long>(o.rf_serial1_egress_goal_overflow),
      static_cast<unsigned long long>(o.rf_serial1_last_commit_goal),
      static_cast<unsigned long>(o.rf_serial1_last_value_bits),
      static_cast<unsigned int>(o.rf_serial1_last_count),
      static_cast<unsigned int>(o.rf_serial1_last_index),
      static_cast<unsigned int>(o.rf_serial1_last_type),
      static_cast<unsigned int>(o.rf_serial1_last_sequence),
      static_cast<unsigned int>(o.rf_serial1_last_system_id),
      static_cast<unsigned int>(o.rf_serial1_last_component_id),
      static_cast<unsigned long long>(o.rf_serial1_last_ms),
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
      static_cast<unsigned long long>(d.uart_buffer_drop_count),
      static_cast<unsigned int>(s.proxy_state),
      static_cast<unsigned int>(s.proxy_strategy),
      static_cast<unsigned int>(s.proxy_active),
      static_cast<unsigned int>(s.proxy_expected_index),
      static_cast<unsigned int>(s.proxy_param_count),
      static_cast<unsigned int>(s.proxy_request_admitted),
      static_cast<unsigned int>(s.proxy_request_dequeued),
      static_cast<unsigned long>(s.proxy_request_token),
      static_cast<unsigned long long>(s.proxy_dequeue_goal),
      static_cast<unsigned long long>(s.proxy_done_goal),
      static_cast<unsigned int>(s.front_frame_bytes),
      static_cast<unsigned int>(s.front_frame_wire_bytes),
      static_cast<unsigned long long>(p.request_dequeues_observed),
      static_cast<unsigned long long>(d.uplink_transactions),
      static_cast<unsigned long long>(d.done_tx),
      static_cast<unsigned long long>(d.idle_tx),
      static_cast<unsigned int>(s.actual_bytes),
      static_cast<unsigned long long>(p.native_list_requests_leased),
      static_cast<unsigned long long>(p.native_stream_poison_events),
      static_cast<unsigned long long>(
          p.native_stream_values_quarantined),
      static_cast<unsigned long long>(
          p.native_stream_precommit_values_quarantined),
      static_cast<unsigned long long>(p.requests_generated),
      static_cast<unsigned long long>(p.request_tx_accepted),
      static_cast<unsigned long long>(p.request_commit_timeouts),
      static_cast<unsigned long long>(p.sessions_failed),
      static_cast<unsigned long long>(p.request_tx_rejected),
      static_cast<unsigned long long>(o.action_data_issued),
      static_cast<unsigned long long>(o.action_done_issued),
      static_cast<unsigned long long>(o.action_idle_issued),
      static_cast<unsigned long long>(o.radio_data_accepted),
      static_cast<unsigned long long>(o.radio_data_rejected),
      static_cast<unsigned long long>(o.radio_done_accepted),
      static_cast<unsigned long long>(o.radio_done_rejected),
      static_cast<unsigned long long>(o.radio_idle_accepted),
      static_cast<unsigned long long>(o.radio_idle_rejected),
      static_cast<unsigned long long>(o.proxy_watchdog_events),
      static_cast<unsigned int>(o.proxy_watchdog_last_reason),
      static_cast<unsigned long>(o.proxy_watchdog_last_token),
      static_cast<unsigned long long>(o.proxy_watchdog_last_ms));

  if (written <= 0 || static_cast<std::size_t>(written) >= report.size() ||
      report[static_cast<std::size_t>(written) - 1U] != '\n') {
    set_format_error_report();
    return;
  }
  std::size_t offset = static_cast<std::size_t>(written) - 1U;
  const int pacer_written = std::snprintf(
      report.data() + offset, report.size() - offset,
      " hpq=%u hpp=%u hpada=%u hpv=%llu hpe=%llu hpx=%llu hpr=%llu hpinv=%llu hpfor=%llu hpdup=%llu hpadm=%llu hpia=%llu hprej=%llu hpabort=%llu hpiab=%llu hpdc=%llu hpblk=%llu hpdrop=%llu hpshort=%llu hpback=%llu hpwu=%llu hpcon=%llu hpdis=%llu hpmaxb=%u hphold=%llu hpusbg=%llu hpmaxq=%u",
      static_cast<unsigned int>(s.heartbeat_pacer_queued),
      static_cast<unsigned int>(s.heartbeat_pacer_pending),
      static_cast<unsigned int>(s.heartbeat_pacer_admitted),
      static_cast<unsigned long long>(hp.valid_real_heartbeats),
      static_cast<unsigned long long>(hp.emitted_heartbeats),
      static_cast<unsigned long long>(hp.expired_heartbeats),
      static_cast<unsigned long long>(hp.fifo_replacements),
      static_cast<unsigned long long>(hp.invalid_heartbeats),
      static_cast<unsigned long long>(hp.foreign_heartbeats_passthrough),
      static_cast<unsigned long long>(hp.duplicate_ingests),
      static_cast<unsigned long long>(hp.admitted_emits),
      static_cast<unsigned long long>(hp.invalid_admissions),
      static_cast<unsigned long long>(hp.rejected_emits),
      static_cast<unsigned long long>(hp.aborted_pending_emits),
      static_cast<unsigned long long>(hp.invalid_pending_aborts),
      static_cast<unsigned long long>(hp.duplicate_completions),
      static_cast<unsigned long long>(hp.order_barrier_blocks),
      static_cast<unsigned long long>(hp.order_preservation_drops),
      static_cast<unsigned long long>(hp.supply_shortage_events),
      static_cast<unsigned long long>(
          hp.usb_backlog_non_guaranteed_events),
      static_cast<unsigned long long>(hp.usb_writer_unavailable_events),
      static_cast<unsigned long long>(hp.usb_connect_events),
      static_cast<unsigned long long>(hp.usb_disconnect_events),
      static_cast<unsigned int>(hp.max_observed_usb_backlog_bytes),
      static_cast<unsigned long long>(hp.max_hold_age_ms),
      static_cast<unsigned long long>(hp.max_usb_gap_ms),
      static_cast<unsigned int>(hp.max_fifo_depth));
  if (pacer_written <= 0 ||
      static_cast<std::size_t>(pacer_written) >= report.size() - offset) {
    set_format_error_report();
    return;
  }
  offset += static_cast<std::size_t>(pacer_written);

  const int rf_gap_written = std::snprintf(
      report.data() + offset, report.size() - offset,
      " hre=%llu hro=%llu hrv=%llu hrls=%u hrlm=%llu hrlg=%llu hrlms=%llu hrlp=%u hrlc=%u hrmg=%llu hrmms=%llu hrmp=%u hrmc=%u hrmst=%u hrmcy=%u hrmaux=%u hrmrb=%u hrmpa=%u hrmpq=%u hrmpp=%u hrmpad=%u hrmobf=%u hrmob=%lu hrmuq=%lu hrmuwp=%u hrmuw=%u hrvg=%llu hrvms=%llu hrvp=%u hrvc=%u hrvst=%u hrvcy=%u hrvaux=%u hrvrb=%u hrvpa=%u hrvpq=%u hrvpp=%u hrvpad=%u hrvobf=%u hrvob=%lu hrvuq=%lu hrvuwp=%u hrvuw=%u",
      static_cast<unsigned long long>(hr.events),
      static_cast<unsigned long long>(hr.gap_observations),
      static_cast<unsigned long long>(hr.gap_violation_count),
      static_cast<unsigned int>(hr.last_sequence),
      static_cast<unsigned long long>(hr.last_ms),
      static_cast<unsigned long long>(hr.latest.gap_ms),
      static_cast<unsigned long long>(hr.latest.event_ms),
      static_cast<unsigned int>(hr.latest.previous_sequence),
      static_cast<unsigned int>(hr.latest.sequence),
      static_cast<unsigned long long>(hr.maximum.gap_ms),
      static_cast<unsigned long long>(hr.maximum.event_ms),
      static_cast<unsigned int>(hr.maximum.previous_sequence),
      static_cast<unsigned int>(hr.maximum.sequence),
      static_cast<unsigned int>(hr.maximum.context.state),
      static_cast<unsigned int>(hr.maximum.context.cycle),
      static_cast<unsigned int>(hr.maximum.context.aux),
      static_cast<unsigned int>(hr.maximum.context.radio_busy),
      static_cast<unsigned int>(hr.maximum.context.pending_action),
      static_cast<unsigned int>(hr.maximum.context.pacer_queued),
      static_cast<unsigned int>(hr.maximum.context.pacer_pending),
      static_cast<unsigned int>(hr.maximum.context.pacer_admitted),
      static_cast<unsigned int>(hr.maximum.context.ordered_backlog_frames),
      static_cast<unsigned long>(hr.maximum.context.ordered_backlog_bytes),
      static_cast<unsigned long>(hr.maximum.context.usb_queued_bytes),
      static_cast<unsigned int>(hr.maximum.context.usb_write_pending),
      static_cast<unsigned int>(hr.maximum.context.usb_writer_available),
      static_cast<unsigned long long>(hr.latest_violation.gap_ms),
      static_cast<unsigned long long>(hr.latest_violation.event_ms),
      static_cast<unsigned int>(hr.latest_violation.previous_sequence),
      static_cast<unsigned int>(hr.latest_violation.sequence),
      static_cast<unsigned int>(hr.latest_violation.context.state),
      static_cast<unsigned int>(hr.latest_violation.context.cycle),
      static_cast<unsigned int>(hr.latest_violation.context.aux),
      static_cast<unsigned int>(hr.latest_violation.context.radio_busy),
      static_cast<unsigned int>(hr.latest_violation.context.pending_action),
      static_cast<unsigned int>(hr.latest_violation.context.pacer_queued),
      static_cast<unsigned int>(hr.latest_violation.context.pacer_pending),
      static_cast<unsigned int>(hr.latest_violation.context.pacer_admitted),
      static_cast<unsigned int>(
          hr.latest_violation.context.ordered_backlog_frames),
      static_cast<unsigned long>(
          hr.latest_violation.context.ordered_backlog_bytes),
      static_cast<unsigned long>(
          hr.latest_violation.context.usb_queued_bytes),
      static_cast<unsigned int>(
          hr.latest_violation.context.usb_write_pending),
      static_cast<unsigned int>(
          hr.latest_violation.context.usb_writer_available));
  if (rf_gap_written <= 0 ||
      static_cast<std::size_t>(rf_gap_written) >= report.size() - offset) {
    set_format_error_report();
    return;
  }
  offset += static_cast<std::size_t>(rf_gap_written);

  const int usb_gap_written = std::snprintf(
      report.data() + offset, report.size() - offset,
      " hue=%llu huo=%llu huv=%llu huls=%u hulm=%llu hulg=%llu hulms=%llu hulp=%u hulc=%u humg=%llu humms=%llu hump=%u humc=%u humst=%u humcy=%u humaux=%u humrb=%u humpa=%u humpq=%u humpp=%u humpad=%u humobf=%u humob=%lu humuq=%lu humuwp=%u humuw=%u huvg=%llu huvms=%llu huvp=%u huvc=%u huvst=%u huvcy=%u huvaux=%u huvrb=%u huvpa=%u huvpq=%u huvpp=%u huvpad=%u huvobf=%u huvob=%lu huvuq=%lu huvuwp=%u huvuw=%u mcr=%llu rfpbs=%llu rfpfa=%llu rfpno=%llu rfpbl=%llu rfpcr=%llu rfpum=%llu rfpuf=%llu rfprs=%llu rfpbuf=%u rfdmbuf=%u rfdmesc=%u pvto=%llu punm=%llu pract=%u prold=%llu prfut=%llu prgap=%llu prto=%llu prq=%llu prtx=%llu prv=%llu prusb=%llu prlv=%u prlr=%u prlex=%u prlrx=%u prlcnt=%u prlseq=%u prlms=%llu\n",
      static_cast<unsigned long long>(hu.events),
      static_cast<unsigned long long>(hu.gap_observations),
      static_cast<unsigned long long>(hu.gap_violation_count),
      static_cast<unsigned int>(hu.last_sequence),
      static_cast<unsigned long long>(hu.last_ms),
      static_cast<unsigned long long>(hu.latest.gap_ms),
      static_cast<unsigned long long>(hu.latest.event_ms),
      static_cast<unsigned int>(hu.latest.previous_sequence),
      static_cast<unsigned int>(hu.latest.sequence),
      static_cast<unsigned long long>(hu.maximum.gap_ms),
      static_cast<unsigned long long>(hu.maximum.event_ms),
      static_cast<unsigned int>(hu.maximum.previous_sequence),
      static_cast<unsigned int>(hu.maximum.sequence),
      static_cast<unsigned int>(hu.maximum.context.state),
      static_cast<unsigned int>(hu.maximum.context.cycle),
      static_cast<unsigned int>(hu.maximum.context.aux),
      static_cast<unsigned int>(hu.maximum.context.radio_busy),
      static_cast<unsigned int>(hu.maximum.context.pending_action),
      static_cast<unsigned int>(hu.maximum.context.pacer_queued),
      static_cast<unsigned int>(hu.maximum.context.pacer_pending),
      static_cast<unsigned int>(hu.maximum.context.pacer_admitted),
      static_cast<unsigned int>(hu.maximum.context.ordered_backlog_frames),
      static_cast<unsigned long>(hu.maximum.context.ordered_backlog_bytes),
      static_cast<unsigned long>(hu.maximum.context.usb_queued_bytes),
      static_cast<unsigned int>(hu.maximum.context.usb_write_pending),
      static_cast<unsigned int>(hu.maximum.context.usb_writer_available),
      static_cast<unsigned long long>(hu.latest_violation.gap_ms),
      static_cast<unsigned long long>(hu.latest_violation.event_ms),
      static_cast<unsigned int>(hu.latest_violation.previous_sequence),
      static_cast<unsigned int>(hu.latest_violation.sequence),
      static_cast<unsigned int>(hu.latest_violation.context.state),
      static_cast<unsigned int>(hu.latest_violation.context.cycle),
      static_cast<unsigned int>(hu.latest_violation.context.aux),
      static_cast<unsigned int>(hu.latest_violation.context.radio_busy),
      static_cast<unsigned int>(hu.latest_violation.context.pending_action),
      static_cast<unsigned int>(hu.latest_violation.context.pacer_queued),
      static_cast<unsigned int>(hu.latest_violation.context.pacer_pending),
      static_cast<unsigned int>(hu.latest_violation.context.pacer_admitted),
      static_cast<unsigned int>(
          hu.latest_violation.context.ordered_backlog_frames),
      static_cast<unsigned long>(
          hu.latest_violation.context.ordered_backlog_bytes),
      static_cast<unsigned long>(
          hu.latest_violation.context.usb_queued_bytes),
      static_cast<unsigned int>(
          hu.latest_violation.context.usb_write_pending),
      static_cast<unsigned int>(
          hu.latest_violation.context.usb_writer_available),
      static_cast<unsigned long long>(d.mavlink_crc_errors),
      static_cast<unsigned long long>(rp.bytes_seen),
      static_cast<unsigned long long>(rp.frames_accepted),
      static_cast<unsigned long long>(rp.noise_bytes),
      static_cast<unsigned long long>(rp.bad_lengths),
      static_cast<unsigned long long>(rp.crc_errors),
      static_cast<unsigned long long>(rp.unsupported_messages),
      static_cast<unsigned long long>(rp.unsupported_flags),
      static_cast<unsigned long long>(rp.explicit_resets),
      static_cast<unsigned int>(s.radio_parser_buffered),
      static_cast<unsigned int>(s.radio_demux_buffered),
      static_cast<unsigned int>(s.radio_demux_escaping),
      static_cast<unsigned long long>(p.value_timeouts),
      static_cast<unsigned long long>(p.unmatched_values_forwarded),
      static_cast<unsigned int>(s.proxy_recovery_active),
      static_cast<unsigned long long>(
          p.native_stream_old_duplicates_consumed),
      static_cast<unsigned long long>(
          p.native_stream_future_values_quarantined),
      static_cast<unsigned long long>(p.native_stream_gap_recoveries),
      static_cast<unsigned long long>(p.native_stream_timeout_recoveries),
      static_cast<unsigned long long>(
          p.native_stream_recovery_requests_generated),
      static_cast<unsigned long long>(
          p.native_stream_recovery_request_tx_accepted),
      static_cast<unsigned long long>(
          p.native_stream_recovery_values_seen),
      static_cast<unsigned long long>(
          p.native_stream_recovery_values_usb_queued),
      static_cast<unsigned int>(prl.valid ? 1U : 0U),
      static_cast<unsigned int>(prl.reason),
      static_cast<unsigned int>(prl.expected_index),
      static_cast<unsigned int>(prl.received_index),
      static_cast<unsigned int>(prl.received_count),
      static_cast<unsigned int>(prl.received_sequence),
      static_cast<unsigned long long>(prl.observed_at_ms));
  if (usb_gap_written <= 0 ||
      static_cast<std::size_t>(usb_gap_written) >= report.size() - offset) {
    set_format_error_report();
    return;
  }
  offset += static_cast<std::size_t>(usb_gap_written);
  report_size = offset;
  report_offset = 0U;
}

inline bool safe_to_format() noexcept {
  const auto& egress = radio_application_endpoint.egress();
  return vc_lora_ground_diag_observer::ground_report_can_start(
      !bridge_ready || runtime_fail_closed, tdd_controller.state(),
      radio_busy, pending_radio_action.active, egress.empty(),
      egress.write_pending());
}

inline void service() noexcept {
  if (!snapshot_pending && report_offset == report_size &&
      vc_lora_ground_diag_observer::query_request_pending &&
      vc_lora_ground_diag_observer::take_query_request()) {
    pending_snapshot = capture_snapshot();
    snapshot_pending = true;
  }

  if (snapshot_pending && safe_to_format()) {
    vc_lora_ground_diag_observer::begin_usb_report();
    format_report(pending_snapshot);
    snapshot_pending = false;
  }

  if (report_offset >= report_size) {
    if (!snapshot_pending) {
      vc_lora_ground_diag_observer::finish_usb_report();
    }
    return;
  }
  const bool endpoint_ready =
      Serial.isPlugged() && static_cast<bool>(Serial);
  if (!endpoint_ready) {
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
