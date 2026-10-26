#include <cstddef>
#include <cstdint>
#include <fstream>
#include <initializer_list>
#include <sstream>
#include <string>
#include <string_view>

#include "test_support.hpp"

#ifndef VC_LORA_SOURCE_ROOT
#define VC_LORA_SOURCE_ROOT "."
#endif

namespace vc_lora::test {
namespace {

std::string read_file(const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  std::ostringstream content;
  content << input.rdbuf();
  return content.str();
}

bool contains_all(const std::string& text,
                  std::initializer_list<std::string_view> required) noexcept {
  for (const std::string_view item : required) {
    if (text.find(item) == std::string::npos) {
      return false;
    }
  }
  return true;
}

std::size_t count_occurrences(const std::string& text,
                              std::string_view needle) noexcept {
  if (needle.empty()) {
    return 0U;
  }
  std::size_t count = 0U;
  std::size_t offset = 0U;
  while ((offset = text.find(needle, offset)) != std::string::npos) {
    ++count;
    offset += needle.size();
  }
  return count;
}

bool ordered(const std::string& text, std::string_view first,
             std::string_view second) noexcept {
  const std::size_t first_offset = text.find(first);
  const std::size_t second_offset = text.find(second);
  return first_offset != std::string::npos &&
         second_offset != std::string::npos && first_offset < second_offset;
}

class SourceContractAudit final {
 public:
  explicit SourceContractAudit(TestReport& report) noexcept : report_(report) {}

  void require(bool condition, std::string_view requirement,
               std::string_view failure) {
    ++required_;
    if (condition) {
      return;
    }
    ++missing_;
    report_.check(false, std::string{failure});
    detail_ += "MISSING ";
    detail_ += requirement;
    detail_ += ": ";
    detail_ += failure;
    detail_ += '\n';
  }

  void finish() {
    report_.detail = "required=" + std::to_string(required_) +
                     " present=" + std::to_string(required_ - missing_) +
                     " missing=" + std::to_string(missing_) + '\n' + detail_;
  }

 private:
  TestReport& report_;
  std::size_t required_{0U};
  std::size_t missing_{0U};
  std::string detail_{};
};

void test_phase6_high_speed_product_route_source_contract(TestReport& report) {
  const std::string root{VC_LORA_SOURCE_ROOT};
  const std::string bridge =
      read_file(root + "/firmware/phase6/vc_lora_phase6_bridge.hpp");
  const std::string adapter =
      read_file(root + "/firmware/high_speed/high_speed_phase6_adapter.hpp");
  const std::string demux =
      read_file(root + "/core/include/vc_lora/tdd_link_demux.hpp");
  const std::string arbiter =
      read_file(root + "/firmware/high_speed/phase6_radio_writer_arbiter.hpp");
  const std::string candidate =
      read_file(root + "/firmware/high_speed/vc_lora_high_speed_candidate.hpp");
  const std::string admission = read_file(
      root + "/firmware/high_speed/e220_high_speed_transport_model.hpp");
  const std::string radio_session = read_file(
      root + "/firmware/high_speed/phase6_high_speed_radio_session.hpp");
  const std::string peer_receipt = read_file(
      root + "/firmware/high_speed/peer_completion_receipt.hpp");

  report.check(!bridge.empty() && !adapter.empty() && !demux.empty() &&
                   !arbiter.empty() && !candidate.empty() &&
                   !admission.empty() && !radio_session.empty() &&
                   !peer_receipt.empty(),
               "one or more high-speed product-route sources are unreadable");
  report.check(
      contains_all(adapter,
                   {"class GroundHighSpeedPhase6Adapter",
                    "class VehicleHighSpeedPhase6Adapter",
                    "on_ground_usb_frame(", "on_decoded_bulk_frame(",
                    "on_pixhawk_request_tail(", "on_terminal_reassembler("}),
      "the platform-neutral adapter prerequisite is incomplete");
  report.check(
      contains_all(demux, {"has_terminal_ack", "has_bulk_data",
                            "has_bulk_negotiation",
                            "has_peer_completion_receipt",
                            "set_bulk_data_route_mode"}),
      "the product demux prerequisite does not expose all high-speed routes");
  report.check(contains_all(arbiter, {"Phase6RadioWriterOwner::HighSpeed",
                                      "AcceptedAwaitingTail",
                                      "observe_physical_tail"}) &&
                   contains_all(candidate, {"candidate_uart_write_gap_ms = 3U",
                                            "live_flash_authorized = false"}) &&
                   contains_all(admission, {"class E220UartAdmissionGate",
                                            "AdmissionResult"}),
               "the staged writer/admission prerequisites are incomplete");

  SourceContractAudit audit{report};

  audit.require(
      contains_all(
          bridge,
          {"high_speed/high_speed_phase6_adapter.hpp",
           "GroundBulkSessionConfig", "VehicleBulkSessionConfig",
           "GroundHighSpeedPhase6Adapter", "VehicleHighSpeedPhase6Adapter",
           "make_r19_ground_bulk_session_config",
           "make_r19_vehicle_bulk_session_config", "boot_identity.boot_id",
           "boot_identity.session_id"}),
      "P0-ROUTE-01-ROLE-BOOT-CONFIG",
      "Ground/Vehicle high-speed adapters are not created from the persisted "
      "boot identity");

  audit.require(
      contains_all(bridge,
                   {"r19_radio_stream_session_id(",
                    "R19RadioStreamPurpose::GroundNegotiationRequest",
                    "r19_ground_adapter->identity().session_id",
                    "r19_vehicle_adapter->identity().session_id"}),
      "P0-ROUTE-01A-PURPOSE-BOUND-SESSION-IDENTITY",
      "post-negotiation radio streams are not bound to the negotiated "
      "BulkNegotiationIdentity session ID");

  audit.require(
      contains_all(
           bridge,
           {"event.has_bulk_negotiation", "event.bulk_negotiation_record",
            "on_negotiation_request_with_retained_grant(",
            "on_negotiation_response("}),
      "P0-ROUTE-02-VCBN-DEMUX",
      "VCBN records are not routed from TddLinkDemux to both role adapters");

  audit.require(
      contains_all(bridge, {"BulkDataRouteMode::Enabled", "event.has_bulk_data",
                            "event.bulk_data_fragment", "BulkDataStreamDecoder",
                            "on_decoded_bulk_frame("}),
      "P0-ROUTE-03-VCB1-DEMUX",
      "negotiated VCB1 mode, decoder routing, and decoded-frame delivery are "
      "absent");

  audit.require(
      contains_all(bridge,
                   {"event.has_terminal_ack", "event.terminal_ack_fragment",
                    "TerminalAckReassembler", "on_terminal_reassembler("}),
      "P0-ROUTE-04-VCTA-DEMUX",
      "VCTA fragments are not routed to the current-session terminal "
      "reassembler");

  const bool intercepts_before_standard_proxy = ordered(
      bridge, "on_ground_usb_frame(", "ground_parameter_proxy.on_gcs_frame(");
  audit.require(
      intercepts_before_standard_proxy &&
          contains_all(bridge, {"HighSpeedPhase6AdapterStatus::Held",
                                "HighSpeedPhase6AdapterStatus::Busy",
                                "HighSpeedPhase6AdapterStatus::PassThrough"}),
      "P0-ROUTE-05-GROUND-21-INTERCEPT",
      "Ground #21 is not offered to the candidate before the standard proxy");

  audit.require(
      contains_all(bridge, {"case HighSpeedPhase6AdapterStatus::Held:",
                            "case HighSpeedPhase6AdapterStatus::Busy:",
                            "case HighSpeedPhase6AdapterStatus::PassThrough:"}),
      "P0-ROUTE-06-GROUND-HELD-BUSY-NO-FALLTHROUGH",
      "Held/Busy do not have explicit consume-without-fallthrough branches");

  audit.require(
      contains_all(bridge, {"HighSpeedPhase6OutputType::RadioWrite",
                            "route_r19_high_speed_radio_output", "output.token",
                            "output.writer_generation"}),
      "P0-ROUTE-07-RADIO-OUTPUT",
      "adapter RadioWrite output is not routed with its action and writer "
      "identity");

  audit.require(
      contains_all(bridge, {"HighSpeedPhase6OutputType::GroundUsbWrite",
                            "on_ground_usb_host_commit(",
                            "on_final_ground_usb_host_commit("}),
      "P0-ROUTE-08-GROUND-USB-OUTPUT",
      "Ground USB output lacks accepted-byte and final host-visible commit "
      "routing");

  audit.require(
      contains_all(bridge, {"HighSpeedPhase6OutputType::PixhawkWrite",
                            "on_pixhawk_request_tail(", "pixhawk_serial"}),
      "P0-ROUTE-09-PIXHAWK-OUTPUT",
      "Vehicle Pixhawk output lacks its exact D6 physical-tail callback");

  audit.require(
      bridge.find("pixhawk_serial.flush(") == std::string::npos &&
          contains_all(
              bridge,
              {"kR19PixhawkCommitDeadlineMs", "r19_pixhawk_commit_deadline_ms",
               "uart_wait_tx_done(UART_NUM_2, 0)", "ESP_ERR_TIMEOUT",
               "status != ESP_OK", "on_pixhawk_request_tail("}),
      "P0-ROUTE-09A-PIXHAWK-BOUNDED-PHYSICAL-TAIL",
      "Vehicle Pixhawk tail uses an unbounded flush or lacks a zero-tick "
      "UART2 drain poll with an absolute fail-closed deadline");

  audit.require(
      contains_all(bridge, {"HighSpeedPhase6OutputType::OpenTerminalAckWindow",
                            "HighSpeedPhase6AdapterStatus::WindowOpened"}),
      "P0-ROUTE-10-TERMINAL-WINDOW-OUTPUT",
      "the terminal receive-window output is not explicitly completed");

  audit.require(
      contains_all(
          bridge,
          {"HighSpeedTailDrainEvidence", "on_radio_tail(",
           "HighSpeedStreamTailEvidence", "on_bulk_tail(",
           "R19BulkRxTailLedger", "HighSpeedLocalRxRecordIdentity",
           "bind_final_bulk_rx_record(", "final_wire_ordinal",
           "fragment_count", "rx_record_token", "rx_ledger_generation"}) &&
          contains_all(radio_session,
                       {"Phase6HighSpeedStreamTailEvidence",
                        "final_action_token",
                        "final_action_writer_generation",
                        "observe_high_speed_stream_tail("}),
      "P0-ROUTE-11-EXACT-PHYSICAL-TAILS",
      "radio and final VCB1 tails are not correlated to exact local writer/RX "
      "ledger identities");

  const bool arbiter_has_stream_lease = contains_all(
      arbiter, {"begin_high_speed_stream(", "record_high_speed_uart(",
                "observe_high_speed_stream_tail("});
  const bool bridge_uses_stream_lease =
      contains_all(bridge, {"Phase6HighSpeedRadioSession",
                            "retain_adapter_action(", "assess_write(",
                            "complete_uart("}) &&
      contains_all(radio_session,
                   {"begin_high_speed_stream(", "record_high_speed_uart(",
                    "observe_high_speed_stream_tail("});
  audit.require(
      arbiter_has_stream_lease && bridge_uses_stream_lease,
      "P0-ROUTE-12-HIGH-SPEED-STREAM-WRITER-LEASE",
      "the arbiter has no exclusive multi-write HighSpeed stream lease; "
      "per-fragment AcceptedAwaitingTail cannot support a 3-ms buffered burst");

  audit.require(
      contains_all(bridge,
                   {"phase6_high_speed_radio_session.hpp",
                    "Phase6HighSpeedRadioSession",
                    "E220WriteContract e220_write_contract"}) &&
          contains_all(radio_session,
                       {"E220UartAdmissionGate", "AdmissionResult::Ready",
                        "uart_gate_.assess(", "uart_gate_.commit_write("}) &&
          contains_all(admission,
                       {"candidate_uart_write_gap_ms", "minimum_gap_ms"}) &&
          bridge.find("e220_subpacket_service_floor_ms == 550U") !=
              std::string::npos,
      "P0-ROUTE-13-SEPARATE-3MS-ADMISSION",
      "candidate 3-ms admission is not a distinct path from the unchanged "
      "standard 550-ms E220 contract");

  audit.require(
      contains_all(
          bridge,
          {"BulkDataStreamDecoder", "BulkDataTxLease", "BulkTranscriptLedger",
           "BulkHeartbeatSlaLedger", "GroundTerminalAckProducer",
           "VehicleTerminalAckExpectedFactory", "TerminalAckReassembler"}),
      "P0-ROUTE-14-SESSION-EVIDENCE-OWNERS",
      "decoder, TX lease, transcript, SLA, and terminal owners are not bound "
      "to the product route");

  audit.require(
      contains_all(bridge, {"HighSpeedPhase6AdapterStatus::FailClosed",
                            ".fail_closed()", "latch_runtime_fail_closed();"}),
      "P0-ROUTE-15-FAIL-CLOSE",
      "candidate adapter/owner failures do not latch the product bridge "
      "closed");

  audit.require(
      contains_all(
          bridge,
          {"PeerCompletionReceiptLedger", "PeerCompletionReceiptProducer",
           "event.has_peer_completion_receipt",
           "r19_route_peer_completion_receipt(",
           "complete_stream_from_peer_receipt(",
           "Phase6HighSpeedRadioSessionStatus::ExplicitRestoreRequired",
           "r19_peer_receipt_proof_delivered", "restore_standard(true",
           "r19_standard_resume_not_before_ms",
           "BulkDataRouteMode::Disabled"}) &&
          contains_all(peer_receipt,
                       {"NegotiationResponseConsumed",
                        "TerminalRecordConsumed", "Only a ledger",
                        "PeerCompletionReceiptProof"}),
      "P0-ROUTE-16-VCRC-PROVEN-RESTORE",
      "candidate restore is not gated by the exact VCRC proof, explicit "
      "restore state, and the post-receipt direction guard");

  audit.require(
      contains_all(bridge,
                   {"observe_candidate_pixhawk_output_tail(",
                    "observe_candidate_ground_usb_output_commit("}) &&
          count_occurrences(
              bridge, "observe_candidate_ground_usb_output_commit(now_ms);") ==
              2U,
      "P0-ROUTE-17-DEFAULT-OFF-LOOP-WRAPPERS",
      "candidate completion observers are not isolated behind unconditional "
      "default-off no-op wrappers");

  audit.require(
      contains_all(admission,
                   {"fresh_continuous_high", "minimum_gap_ms",
                    "buffer-handoff evidence only",
                    "never make a DrainProof, unlock direction"}) &&
          contains_all(radio_session,
                       {"release_buffer_credit_from_local_aux(",
                        "complete_stream_from_peer_receipt("}),
      "P0-ROUTE-18-CONTINUOUS-HIGH-CREDIT-NOT-TAIL",
      "continuous AUX HIGH does not provide bounded buffer-only progress, or "
      "is incorrectly treated as final RF-tail proof");

  audit.require(
      contains_all(
          bridge,
          {"kR19PeerReceiptReceiveMarginMs = 650U",
           "BulkSessionTiming::direction_guard_ms +",
           "FixedFirmwareContract::e220_subpacket_service_floor_ms +",
           "kR19PeerReceiptDeadlineMs == 1300U",
           "FixedFirmwareContract::heartbeat_hard_deadline_ms"}),
      "P0-ROUTE-19-VCRC-PHYSICAL-FLOOR-DEADLINE",
      "the VCRC proof deadline does not cover its 100-ms reversal guard, "
      "standard 550-ms E220 service floor, and bounded receive margin while "
      "remaining below the heartbeat hard deadline");

  audit.require(
      contains_all(
          bridge,
          {"r19_terminal_receipt_stage_ready()",
           "return r19_radio_session == nullptr;",
           "r19_complete_vehicle_terminal_if_ready(now_ms)"}) &&
          ordered(bridge, "r19_complete_bulk_stream_from_remote_arrival(now_ms)",
                  "r19_complete_vehicle_terminal_if_ready(now_ms)"),
      "P0-ROUTE-20-VCRC-AFTER-BULK-LEASE-CLOSE",
      "Vehicle can stage the terminal VCRC while the bulk HighSpeed writer "
      "lease is still active, which would starve radio-session credit service");

  const std::size_t pending_response_begin =
      bridge.find("bool r19_process_pending_ground_negotiation_response(");
  const std::size_t pending_response_end =
      bridge.find("bool r19_route_bulk_negotiation(", pending_response_begin);
  const std::string pending_response_route =
      pending_response_begin != std::string::npos &&
              pending_response_end != std::string::npos
          ? bridge.substr(pending_response_begin,
                          pending_response_end - pending_response_begin)
          : std::string{};
  audit.require(
      ordered(pending_response_route,
              "prevalidate_negotiation_response(",
              "r19_complete_action_stream_from_remote_arrival(now_ms)"),
      "P0-ROUTE-21-VCBN-CORRELATION-BEFORE-REMOTE-TAIL",
      "Ground treats an uncorrelated/raw VCBN arrival as remote-tail proof "
      "before CRC, session, request-tag, and Grant-cycle correlation");

  const std::size_t terminal_route_begin =
      bridge.find("bool r19_route_terminal_ack(");
  const std::size_t terminal_route_end =
      bridge.find("void r19_observe_ground_grant(", terminal_route_begin);
  const std::string terminal_route =
      terminal_route_begin != std::string::npos &&
              terminal_route_end != std::string::npos
          ? bridge.substr(terminal_route_begin,
                          terminal_route_end - terminal_route_begin)
          : std::string{};
  audit.require(
      terminal_route.find("r19_terminal_fragment_received") ==
              std::string::npos &&
          ordered(terminal_route, "r19_terminal_reassembler->finish()",
                  "r19_terminal_record_reassembled = true;") &&
          ordered(terminal_route, "r19_terminal_record_reassembled = true;",
                  "r19_complete_bulk_stream_from_remote_arrival(now_ms)"),
      "P0-ROUTE-22-FULL-VCTA-BEFORE-BULK-REMOTE-TAIL",
      "Vehicle treats the first VCTA fragment as proof that the full bulk "
      "stream reached Ground; all 8 correlated fragments must validate first");

  const std::size_t ground_intercept_begin =
      bridge.find("bool r19_intercept_ground_usb_frame(");
  const std::size_t ground_intercept_end = bridge.find(
      "bool r19_construct_ground_session_owners(", ground_intercept_begin);
  const std::string ground_intercept =
      ground_intercept_begin != std::string::npos &&
              ground_intercept_end != std::string::npos
          ? bridge.substr(ground_intercept_begin,
                          ground_intercept_end - ground_intercept_begin)
          : std::string{};
  audit.require(
      contains_all(bridge,
                   {"r19_acceleration_consumed{false}",
                    "r19_acceleration_consumed = true;"}) &&
          ordered(ground_intercept, "if (r19_acceleration_consumed)",
                  "r19_ground_adapter->on_ground_usb_frame(") &&
          contains_all(bridge,
                       {"activate_r19_high_speed_candidate()",
                        "if (r19_acceleration_consumed)"}) &&
          count_occurrences(bridge, "if (r19_acceleration_consumed)") >= 3U,
      "P0-ROUTE-23-ONE-ACCELERATED-SESSION-PER-BOOT",
      "the one-shot ledger/producer lifetime is not explicitly bounded; a "
      "second #21 must bypass candidate activation and fall through to R18");

  audit.finish();
}

}  // namespace

TestReport run_phase6_high_speed_product_route_source_contract_test(
    const std::string& test_id, std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;
  if (test_id == "UT-HS-PRODUCT-ROUTE-SOURCE-001") {
    test_phase6_high_speed_product_route_source_contract(report);
  } else {
    report.check(false,
                 "unknown Phase6 high-speed product-route source test ID");
  }
  return report;
}

}  // namespace vc_lora::test
