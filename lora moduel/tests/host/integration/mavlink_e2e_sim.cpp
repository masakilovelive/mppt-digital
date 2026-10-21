#include "mavlink_e2e_sim.hpp"

#include <algorithm>
#include <array>
#include <limits>
#include <utility>

#include "vc_lora/link_data_codec.hpp"
#include "vc_lora/runtime_contract.hpp"
#include "vc_lora/tdd_control_codec.hpp"
#include "vc_lora/tx_gate.hpp"

namespace vc_lora::test {
namespace {

constexpr std::uint64_t kFnv1a64Offset = 14'695'981'039'346'656'037ULL;
constexpr std::uint64_t kFnv1a64Prime = 1'099'511'628'211ULL;

std::uint32_t narrow_queue(std::size_t size) noexcept {
  return static_cast<std::uint32_t>(std::min<std::size_t>(
      size, std::numeric_limits<std::uint32_t>::max()));
}

std::uint64_t append_stream_hash(std::uint64_t hash,
                                 const MavlinkFrame& frame) noexcept {
  for (std::size_t index = 0U; index < frame.size; ++index) {
    hash ^= frame.bytes[index];
    hash *= kFnv1a64Prime;
  }
  return hash;
}

}  // namespace

MavlinkE2eSimulation::MavlinkE2eSimulation(
    const TddConfig& tdd_config, const RfMediumConfig& rf_config,
    std::uint32_t seed, MavlinkE2eCaptureConfig capture_config)
    : config_(tdd_config),
      medium_(rf_config, seed, diagnostics_),
      vehicle_radio_(NodeId::Vehicle, medium_),
      ground_radio_(NodeId::Ground, medium_),
      vehicle_(config_, diagnostics_),
      ground_(config_, diagnostics_),
      capture_config_(capture_config) {}

void MavlinkE2eSimulation::start(std::uint16_t session_id,
                                 std::uint16_t initial_cycle) {
  diagnostics_.clear();
  stats_ = {};
  stats_.vehicle_stream_hash = kFnv1a64Offset;
  stats_.ground_stream_hash = kFnv1a64Offset;
  now_ms_ = 0U;
  ground_ingested_valid_frames_ = 0U;
  ground_ingested_valid_bytes_ = 0U;
  ground_queue_drop_frames_ = 0U;
  ground_queue_drop_bytes_ = 0U;
  max_ground_queued_frames_ = 0U;
  last_heartbeat_ms_ = 0U;
  last_heartbeat_point_ = {};
  last_vehicle_data_tx_start_ms_ = 0U;
  last_vehicle_data_tx_end_ms_ = 0U;
  last_terminal_rx_ms_ = 0U;
  have_heartbeat_ = false;
  vehicle_scheduler_.reset();
  ground_ingress_parser_ = {};
  vehicle_endpoint_parser_ = {};
  ground_endpoint_parser_ = {};
  ground_usb_buffer_.reset();
  vehicle_frames_.clear();
  ground_frames_.clear();
  wire_writes_.clear();
  failure_context_pre_events_.clear();
  failure_context_trace_ = {};
  previous_write_start_ms_ = {{0U, 0U}};
  have_previous_write_ = {{false, false}};
  failure_context_post_remaining_ = 0U;
  failure_context_triggered_ = false;
  ground_frame_lengths_.clear();
  vehicle_demux_.set_link_data_escaping(true);
  ground_demux_.set_link_data_escaping(true);
  vehicle_.reset(session_id, initial_cycle, 0U);
  ground_.reset(0U);
  last_vehicle_cycle_ = initial_cycle;
  last_ground_cycle_ = ground_.cycle_id();
  last_vehicle_state_ = vehicle_.state();
  last_ground_state_ = ground_.state();
  started_ = true;
  record_context_event(NodeId::Vehicle, "RESET", 0U);
  record_context_event(NodeId::Ground, "RESET", 0U);
  sync_scheduler_diagnostics();
}

void MavlinkE2eSimulation::record_context_event(
    NodeId node, const char* event, std::uint64_t event_ms,
    std::uint64_t radio_tx_bytes, std::uint64_t radio_rx_bytes) {
  if ((capture_config_.failure_context_pre_events == 0U &&
       capture_config_.failure_context_post_events == 0U) ||
      (failure_context_triggered_ &&
       failure_context_post_remaining_ == 0U)) {
    return;
  }
  const bool vehicle_node = node == NodeId::Vehicle;
  TraceEvent trace{
      event_ms,
      vehicle_node ? "vehicle" : "ground",
      vehicle_node ? vehicle_state_name(vehicle_.state())
                   : ground_state_name(ground_.state()),
      vehicle_node ? vehicle_.cycle_id() : ground_.cycle_id(),
      event == nullptr ? "EVENT" : event,
      vehicle_node ? vehicle_radio_.aux_high(event_ms)
                   : ground_radio_.aux_high(event_ms),
      vehicle_node ? vehicle_scheduler_.queued_bytes()
                   : ground_usb_buffer_.size(),
      radio_tx_bytes,
      radio_rx_bytes,
      vehicle_node ? vehicle_.session_id() : ground_.session_id()};
  if (!failure_context_triggered_) {
    const std::size_t limit = capture_config_.failure_context_pre_events;
    if (limit == 0U) {
      return;
    }
    if (failure_context_pre_events_.size() == limit) {
      failure_context_pre_events_.pop_front();
    }
    failure_context_pre_events_.push_back(std::move(trace));
    stats_.max_failure_context_pre_events = std::max(
        stats_.max_failure_context_pre_events,
        failure_context_pre_events_.size());
    return;
  }
  failure_context_trace_.record(std::move(trace));
  --failure_context_post_remaining_;
  ++stats_.failure_context_post_events;
  stats_.max_failure_context_trace_events = std::max(
      stats_.max_failure_context_trace_events,
      failure_context_trace_.size());
}

void MavlinkE2eSimulation::trigger_failure_context(
    std::uint64_t gap_ms) {
  if (failure_context_triggered_ ||
      capture_config_.failure_heartbeat_gap_ms == 0U ||
      gap_ms <= capture_config_.failure_heartbeat_gap_ms) {
    return;
  }
  stats_.failure_context_pre_events = failure_context_pre_events_.size();
  for (const TraceEvent& event : failure_context_pre_events_) {
    failure_context_trace_.record(event);
  }
  std::string marker = "HEARTBEAT_GAP_VIOLATION gap_ms=";
  marker += std::to_string(gap_ms);
  marker += " limit_ms=";
  marker += std::to_string(capture_config_.failure_heartbeat_gap_ms);
  marker += " vehicle_state=";
  marker += vehicle_state_name(vehicle_.state());
  marker += " vehicle_cycle=";
  marker += std::to_string(vehicle_.cycle_id());
  marker += " before_rx=";
  marker += std::to_string(stats_.heartbeat_gap_before.received_ms);
  marker += " before_tx=";
  marker += std::to_string(stats_.heartbeat_gap_before.tx_start_ms);
  marker += "..";
  marker += std::to_string(stats_.heartbeat_gap_before.tx_end_ms);
  marker += " before_done=";
  marker +=
      std::to_string(stats_.heartbeat_gap_before.last_terminal_rx_ms);
  marker += " before_wire_count=";
  marker += std::to_string(stats_.heartbeat_gap_before.wire_write_count);
  marker += " after_rx=";
  marker += std::to_string(stats_.heartbeat_gap_after.received_ms);
  marker += " after_tx=";
  marker += std::to_string(stats_.heartbeat_gap_after.tx_start_ms);
  marker += "..";
  marker += std::to_string(stats_.heartbeat_gap_after.tx_end_ms);
  marker += " after_done=";
  marker += std::to_string(stats_.heartbeat_gap_after.last_terminal_rx_ms);
  marker += " after_wire_count=";
  marker += std::to_string(stats_.heartbeat_gap_after.wire_write_count);
  failure_context_trace_.record(
      {now_ms_, "ground", ground_state_name(ground_.state()),
       ground_.cycle_id(), marker, ground_radio_.aux_high(now_ms_),
       ground_usb_buffer_.size(), 0U, 0U, ground_.session_id()});
  failure_context_pre_events_.clear();
  failure_context_triggered_ = true;
  failure_context_post_remaining_ =
      capture_config_.failure_context_post_events;
  stats_.max_failure_context_trace_events = std::max(
      stats_.max_failure_context_trace_events,
      failure_context_trace_.size());
}

void MavlinkE2eSimulation::record_state_cycle_changes() {
  if (vehicle_.state() != last_vehicle_state_) {
    record_context_event(NodeId::Vehicle, "STATE_CYCLE_CHANGE", now_ms_);
    last_vehicle_state_ = vehicle_.state();
  }
  if (ground_.state() != last_ground_state_ ||
      ground_.cycle_id() != last_ground_cycle_) {
    record_context_event(NodeId::Ground, "STATE_CYCLE_CHANGE", now_ms_);
    last_ground_state_ = ground_.state();
    last_ground_cycle_ = ground_.cycle_id();
  }
}

void MavlinkE2eSimulation::note_parser_status(
    MavlinkParseStatus status) noexcept {
  if (status == MavlinkParseStatus::BadCrc) {
    ++diagnostics_.mavlink_crc_errors;
  } else if (status == MavlinkParseStatus::BadLength ||
             status == MavlinkParseStatus::UnsupportedMessage ||
             status == MavlinkParseStatus::UnsupportedFlags) {
    ++diagnostics_.mavlink_parser_resets;
  }
}

std::size_t MavlinkE2eSimulation::ingest_gcs_stream(
    const std::uint8_t* bytes, std::size_t size) noexcept {
  if (bytes == nullptr || size == 0U) {
    return 0U;
  }
  diagnostics_.ground_usb_rx_bytes += size;
  for (std::size_t index = 0U; index < size; ++index) {
    MavlinkFrame frame{};
    const MavlinkParseStatus status =
        ground_ingress_parser_.push(bytes[index], frame);
    if (status == MavlinkParseStatus::FrameReady) {
      ++ground_ingested_valid_frames_;
      ground_ingested_valid_bytes_ += frame.size;
      if (ground_usb_buffer_.free_space() >= frame.size) {
        const std::size_t accepted =
            ground_usb_buffer_.write(frame.bytes.data(), frame.size);
        diagnostics_.ground_usb_accepted_bytes += accepted;
        ground_frame_lengths_.push_back(frame.size);
        max_ground_queued_frames_ = std::max(
            max_ground_queued_frames_, ground_frame_lengths_.size());
      } else {
        ++ground_queue_drop_frames_;
        ground_queue_drop_bytes_ += frame.size;
        diagnostics_.ground_usb_dropped_bytes += frame.size;
        ++diagnostics_.ground_buffer_overflow_count;
      }
      diagnostics_.max_ground_queue = std::max<std::uint64_t>(
          diagnostics_.max_ground_queue, ground_usb_buffer_.size());
    } else {
      note_parser_status(status);
    }
  }
  sync_scheduler_diagnostics();
  return size;
}

bool MavlinkE2eSimulation::ingest_gcs_frame(
    const MavlinkFrame& frame) noexcept {
  MavlinkFrame validated{};
  if (validate_mavlink_frame(frame.bytes.data(), frame.size, validated) !=
      MavlinkParseStatus::FrameReady) {
    return false;
  }
  const std::uint64_t accepted_before =
      diagnostics_.ground_usb_accepted_bytes;
  (void)ingest_gcs_stream(frame.bytes.data(), frame.size);
  return diagnostics_.ground_usb_accepted_bytes - accepted_before ==
         frame.size;
}

bool MavlinkE2eSimulation::ingest_pixhawk_frame(
    const MavlinkFrame& frame) noexcept {
  const MavlinkEnqueueStatus status =
      vehicle_scheduler_.enqueue(frame, now_ms_);
  sync_scheduler_diagnostics();
  return status == MavlinkEnqueueStatus::Queued ||
         status == MavlinkEnqueueStatus::Filtered;
}

std::size_t MavlinkE2eSimulation::ingest_pixhawk_stream(
    const std::uint8_t* bytes, std::size_t size) noexcept {
  if (bytes == nullptr || size == 0U) {
    return 0U;
  }
  const MavlinkParserDiagnostics before =
      vehicle_scheduler_.parser_diagnostics();
  for (std::size_t index = 0U; index < size; ++index) {
    (void)vehicle_scheduler_.ingest_byte(bytes[index], now_ms_);
  }
  const MavlinkParserDiagnostics after =
      vehicle_scheduler_.parser_diagnostics();
  diagnostics_.mavlink_crc_errors += after.crc_errors - before.crc_errors;
  diagnostics_.mavlink_parser_resets +=
      after.bad_lengths - before.bad_lengths +
      after.unsupported_messages - before.unsupported_messages +
      after.unsupported_flags - before.unsupported_flags;
  sync_scheduler_diagnostics();
  return size;
}

void MavlinkE2eSimulation::sync_scheduler_diagnostics() noexcept {
  const auto& scheduler = vehicle_scheduler_.diagnostics();
  diagnostics_.mavlink_frames_ingested =
      ground_ingested_valid_frames_ + scheduler.frames_ingested;
  diagnostics_.mavlink_frames_filtered =
      scheduler.policy_filtered_frames + scheduler.rate_limited_frames;
  diagnostics_.mavlink_msg194_filtered_frames =
      scheduler.msg194_frames_filtered;
  diagnostics_.mavlink_msg194_filtered_bytes =
      scheduler.msg194_bytes_filtered;
  diagnostics_.mavlink_queue_drop_frames =
      ground_queue_drop_frames_ + scheduler.queue_drop_frames;
  diagnostics_.mavlink_queue_drop_bytes =
      ground_queue_drop_bytes_ + scheduler.queue_drop_bytes;
  diagnostics_.max_mavlink_queue_frames = std::max<std::uint64_t>(
      diagnostics_.max_mavlink_queue_frames,
      std::max<std::size_t>(scheduler.max_queue_frames,
                            max_ground_queued_frames_));
  diagnostics_.max_mavlink_queue_bytes = std::max<std::uint64_t>(
      diagnostics_.max_mavlink_queue_bytes,
      std::max<std::size_t>(scheduler.max_queue_bytes,
                            ground_usb_buffer_.stats().high_watermark));
  diagnostics_.max_vehicle_queue = std::max<std::uint64_t>(
      diagnostics_.max_vehicle_queue, vehicle_scheduler_.queued_bytes());
  diagnostics_.max_ground_queue = std::max<std::uint64_t>(
      diagnostics_.max_ground_queue, ground_usb_buffer_.size());
}

void MavlinkE2eSimulation::note_complete_frame(
    NodeId receiver, const MavlinkFrame& frame) {
  MavlinkFrame validated{};
  if (validate_mavlink_frame(frame.bytes.data(), frame.size, validated) !=
      MavlinkParseStatus::FrameReady) {
    ++diagnostics_.partial_mavlink_delivered;
    return;
  }
  record_context_event(receiver, "MAV_FRAME_RX", now_ms_, 0U,
                       validated.size);
  TimedMavlinkFrame timed{validated, now_ms_};
  if (receiver == NodeId::Vehicle) {
    ++stats_.vehicle_frames_received;
    stats_.vehicle_frame_bytes_received += validated.size;
    stats_.vehicle_stream_hash =
        append_stream_hash(stats_.vehicle_stream_hash, validated);
    if (capture_config_.frames) {
      vehicle_frames_.push_back(timed);
      stats_.max_captured_vehicle_frames = std::max(
          stats_.max_captured_vehicle_frames, vehicle_frames_.size());
    }
    if (frame.message_id == 20U) {
      ++diagnostics_.param_requests_rx;
    } else if (frame.message_id == 23U) {
      ++diagnostics_.param_sets_rx;
      ++diagnostics_.param_updates;
    } else if (frame.message_id == 76U) {
      ++diagnostics_.command_long_rx;
    }
  } else {
    ++stats_.ground_frames_received;
    stats_.ground_frame_bytes_received += validated.size;
    stats_.ground_stream_hash =
        append_stream_hash(stats_.ground_stream_hash, validated);
    if (capture_config_.frames) {
      ground_frames_.push_back(timed);
      stats_.max_captured_ground_frames = std::max(
          stats_.max_captured_ground_frames, ground_frames_.size());
    }
    if (frame.message_id == 0U && frame.system_id == 1U &&
        frame.component_id == 1U) {
      ++diagnostics_.heartbeat_valid;
      const MavlinkHeartbeatGapPoint current{
          now_ms_, last_vehicle_data_tx_start_ms_,
          last_vehicle_data_tx_end_ms_, last_terminal_rx_ms_,
          stats_.wire_write_count, vehicle_.cycle_id(),
          static_cast<std::uint8_t>(vehicle_.state())};
      if (have_heartbeat_) {
        const std::uint64_t gap = now_ms_ - last_heartbeat_ms_;
        if (gap > diagnostics_.heartbeat_max_gap_ms) {
          diagnostics_.heartbeat_max_gap_ms = gap;
          stats_.heartbeat_gap_before = last_heartbeat_point_;
          stats_.heartbeat_gap_after = current;
        }
        trigger_failure_context(gap);
      }
      last_heartbeat_ms_ = now_ms_;
      last_heartbeat_point_ = current;
      have_heartbeat_ = true;
    } else if (frame.message_id == 22U) {
      ++diagnostics_.param_values_rx;
    } else if (frame.message_id == 77U) {
      ++diagnostics_.command_ack_rx;
    }
  }
  ++diagnostics_.mavlink_frames_forwarded;
}

void MavlinkE2eSimulation::record_wire_write(
    const WireWriteRecord& record) {
  ++stats_.wire_write_count;
  if (record.wire_bytes > kLinkDataMaxWireBytes) {
    ++stats_.physical_write_oversize_count;
  }
  const std::size_t node =
      record.sender == NodeId::Vehicle ? 0U : 1U;
  if (have_previous_write_[node] &&
      record.start_ms - previous_write_start_ms_[node] <
          config_.min_tx_gap_ms) {
    ++stats_.physical_write_gap_violations;
  }
  have_previous_write_[node] = true;
  previous_write_start_ms_[node] = record.start_ms;
  if (record.sender == NodeId::Ground && !record.control &&
      record.end_ms > record.window_deadline_ms &&
      !record.continuing_started_transaction) {
    ++stats_.ground_window_overrun_count;
  }
  if (record.sender == NodeId::Vehicle && !record.control) {
    last_vehicle_data_tx_start_ms_ = record.start_ms;
    last_vehicle_data_tx_end_ms_ = record.end_ms;
  }
  record_context_event(
      record.sender,
      record.control ? "WIRE_TX_CONTROL" : "WIRE_TX_DATA",
      record.start_ms, record.wire_bytes, 0U);
  if (capture_config_.wire_writes) {
    wire_writes_.push_back(record);
    stats_.max_captured_wire_writes =
        std::max(stats_.max_captured_wire_writes, wire_writes_.size());
  }
}

void MavlinkE2eSimulation::deliver_application_byte(NodeId receiver,
                                                     std::uint8_t byte) {
  if (receiver == NodeId::Vehicle && !vehicle_.radio_receive_window()) {
    ++diagnostics_.uplink_data_outside_receive_window;
    return;
  }
  MavlinkFrame frame{};
  const MavlinkParseStatus status =
      receiver == NodeId::Vehicle
          ? vehicle_endpoint_parser_.push(byte, frame)
          : ground_endpoint_parser_.push(byte, frame);
  if (status == MavlinkParseStatus::FrameReady) {
    note_complete_frame(receiver, frame);
  } else {
    note_parser_status(status);
  }
}

void MavlinkE2eSimulation::deliver_control(NodeId receiver,
                                           const DecodeEvent& event) {
  record_context_event(receiver, "CONTROL_RX_DECODE", now_ms_, 0U,
                       kTddControlFrameSize);
  diagnostics_.note_decode_status(event.status);
  if (event.status != DecodeStatus::Message) {
    return;
  }
  if (receiver == NodeId::Vehicle) {
    const ControlDisposition disposition =
        vehicle_.on_control(event.message, now_ms_);
    if (disposition == ControlDisposition::Accepted &&
        (event.message.type == ControlType::UlDone ||
         event.message.type == ControlType::UlIdle)) {
      last_terminal_rx_ms_ = now_ms_;
    }
  } else {
    (void)ground_.on_control(event.message, now_ms_);
  }
}

void MavlinkE2eSimulation::deliver_one(const RfDelivery& delivery) {
  TddLinkDemux& demux = delivery.receiver == NodeId::Vehicle
                            ? vehicle_demux_
                            : ground_demux_;
  const bool control_wire_candidate =
      delivery.payload.size == kTddControlFrameSize &&
      delivery.payload.bytes[0] == static_cast<std::uint8_t>('V');
  for (std::size_t index = 0U; index < delivery.payload.size; ++index) {
    record_context_event(
        delivery.receiver,
        control_wire_candidate ? "WIRE_RX_CONTROL_BYTE"
                               : "WIRE_RX_DATA_BYTE",
        now_ms_, 0U, 1U);
    const TddDemuxEvent event = demux.push(delivery.payload.bytes[index]);
    if (control_wire_candidate && event.local_size > 0U) {
      diagnostics_.control_bytes_leaked_to_local_uart += event.local_size;
    }
    for (std::size_t local = 0U; local < event.local_size; ++local) {
      deliver_application_byte(delivery.receiver, event.local_bytes[local]);
    }
    if (event.has_control) {
      deliver_control(delivery.receiver, event.control);
    }
  }
}

void MavlinkE2eSimulation::deliver_radio() {
  RfDelivery delivery{};
  while (medium_.pop_delivery(NodeId::Ground, now_ms_, delivery)) {
    deliver_one(delivery);
  }
  while (medium_.pop_delivery(NodeId::Vehicle, now_ms_, delivery)) {
    deliver_one(delivery);
  }
}

void MavlinkE2eSimulation::process_vehicle_action(
    const LinkAction& action, std::uint64_t local_now_ms) {
  if (action.type == LinkActionType::SendRadioData) {
    if (!TxGate::authorize_vehicle(vehicle_.state(), TxClass::DownlinkData,
                                   diagnostics_)) {
      vehicle_.complete_action(action.token, TxResult::Rejected,
                               local_now_ms);
      return;
    }
    std::array<std::uint8_t, kLinkDataMaxWireBytes> application{};
    const std::size_t available = vehicle_scheduler_.peek(
        application.data(),
        std::min<std::size_t>(action.byte_budget, application.size()));
    const EncodedLinkDataChunk encoded =
        encode_link_data(application.data(), available);
    if (encoded.input_consumed == 0U || encoded.wire_size == 0U) {
      vehicle_.complete_action(action.token, TxResult::Rejected,
                               local_now_ms);
      return;
    }
    const TxOutcome outcome = vehicle_radio_.write(
        now_ms_, encoded.wire_bytes.data(), encoded.wire_size);
    (void)vehicle_scheduler_.complete_send(
        outcome.accepted ? TxResult::Accepted : TxResult::Rejected,
        encoded.input_consumed);
    vehicle_.complete_action(
        action.token,
        outcome.accepted ? TxResult::Accepted : TxResult::Rejected,
        local_now_ms,
        static_cast<std::uint16_t>(encoded.input_consumed));
    if (outcome.accepted) {
      ++stats_.vehicle_data_writes;
      stats_.vehicle_application_bytes_tx += encoded.input_consumed;
      stats_.max_vehicle_wire_write = std::max<std::uint64_t>(
          stats_.max_vehicle_wire_write, encoded.wire_size);
      record_wire_write({NodeId::Vehicle, false, now_ms_, outcome.end_ms,
                         0U, encoded.input_consumed, encoded.wire_size});
    }
    sync_scheduler_diagnostics();
    return;
  }

  if (action.type != LinkActionType::SendGrant) {
    return;
  }
  if (!TxGate::authorize_vehicle(vehicle_.state(), TxClass::GrantControl,
                                 diagnostics_)) {
    vehicle_.complete_action(action.token, TxResult::Rejected,
                             local_now_ms);
    return;
  }
  std::array<std::uint8_t, kTddControlFrameSize> frame{};
  std::size_t encoded_size = 0U;
  const bool encoded = encode_control(action.control, frame.data(),
                                      frame.size(), encoded_size);
  const TxOutcome outcome =
      encoded ? vehicle_radio_.write(now_ms_, frame.data(), encoded_size)
              : TxOutcome{};
  vehicle_.complete_action(action.token,
                           outcome.accepted ? TxResult::Accepted
                                            : TxResult::Rejected,
                           local_now_ms);
  if (outcome.accepted) {
    record_wire_write({NodeId::Vehicle, true, now_ms_, outcome.end_ms,
                       0U, 0U, encoded_size});
  }
}

void MavlinkE2eSimulation::process_ground_action(
    const LinkAction& action, std::uint64_t local_now_ms) {
  if (action.type == LinkActionType::SendRadioData) {
    const bool continuing_started_transaction =
        ground_.transaction_target_bytes() > 0U &&
        ground_.actual_bytes() > 0U &&
        ground_.actual_bytes() < ground_.transaction_target_bytes();
    if (!TxGate::authorize_ground(
            ground_.state(), TxClass::UplinkData, ground_.has_valid_grant(),
            local_now_ms, ground_.window_deadline_ms(), diagnostics_,
            continuing_started_transaction)) {
      ground_.complete_action(action.token, TxResult::Rejected, local_now_ms);
      return;
    }
    std::array<std::uint8_t, kLinkDataMaxWireBytes> application{};
    const std::size_t copied = ground_usb_buffer_.copy_front(
        application.data(),
        std::min<std::size_t>(action.byte_budget, application.size()));
    const EncodedLinkDataChunk encoded =
        encode_link_data(application.data(), copied);
    if (encoded.input_consumed == 0U || encoded.wire_size == 0U) {
      ++diagnostics_.ground_queue_underflow_count;
      ground_.complete_action(action.token, TxResult::Rejected, local_now_ms);
      return;
    }
    const TxOutcome outcome = ground_radio_.write(
        now_ms_, encoded.wire_bytes.data(), encoded.wire_size);
    ground_.complete_action(
        action.token,
        outcome.accepted ? TxResult::Accepted : TxResult::Rejected,
        local_now_ms,
        static_cast<std::uint16_t>(encoded.input_consumed));
    if (outcome.accepted) {
      const std::size_t discarded =
          ground_usb_buffer_.discard(encoded.input_consumed);
      diagnostics_.ground_usb_dequeued_bytes += discarded;
      if (discarded != encoded.input_consumed) {
        ++diagnostics_.ground_queue_underflow_count;
      }
      std::size_t descriptor_bytes = discarded;
      while (descriptor_bytes > 0U && !ground_frame_lengths_.empty()) {
        if (descriptor_bytes >= ground_frame_lengths_.front()) {
          descriptor_bytes -= ground_frame_lengths_.front();
          ground_frame_lengths_.pop_front();
        } else {
          ground_frame_lengths_.front() -= descriptor_bytes;
          descriptor_bytes = 0U;
        }
      }
      if (descriptor_bytes != 0U) {
        ++diagnostics_.ground_queue_underflow_count;
      }
      ++stats_.ground_data_writes;
      stats_.ground_application_bytes_tx += encoded.input_consumed;
      stats_.max_ground_wire_write = std::max<std::uint64_t>(
          stats_.max_ground_wire_write, encoded.wire_size);
      record_wire_write({NodeId::Ground, false, now_ms_, outcome.end_ms,
                         ground_.window_deadline_ms(),
                         encoded.input_consumed, encoded.wire_size,
                         continuing_started_transaction});
    }
    sync_scheduler_diagnostics();
    return;
  }

  if (action.type != LinkActionType::SendDone) {
    return;
  }
  if (!TxGate::authorize_ground(
          ground_.state(), TxClass::DoneControl, ground_.has_valid_grant(),
          local_now_ms, ground_.window_deadline_ms(), diagnostics_)) {
    ground_.complete_action(action.token, TxResult::Rejected, local_now_ms);
    return;
  }
  std::array<std::uint8_t, kTddControlFrameSize> frame{};
  std::size_t encoded_size = 0U;
  const bool encoded = encode_control(action.control, frame.data(),
                                      frame.size(), encoded_size);
  const TxOutcome outcome =
      encoded ? ground_radio_.write(now_ms_, frame.data(), encoded_size)
              : TxOutcome{};
  ground_.complete_action(action.token,
                          outcome.accepted ? TxResult::Accepted
                                           : TxResult::Rejected,
                          local_now_ms);
  if (outcome.accepted) {
    record_wire_write({NodeId::Ground, true, now_ms_, outcome.end_ms,
                       ground_.window_deadline_ms(), 0U, encoded_size});
  }
}

void MavlinkE2eSimulation::step() {
  if (!started_) {
    start();
  }
  medium_.advance(now_ms_);
  deliver_radio();

  TddInput vehicle_input{
      now_ms_, vehicle_radio_.aux_high(now_ms_),
      vehicle_radio_.tx_empty(now_ms_), !vehicle_scheduler_.has_active_frame(),
      narrow_queue(vehicle_scheduler_.queued_bytes())};
  const MavlinkHeartbeatCandidate heartbeat =
      vehicle_scheduler_.heartbeat_candidate();
  vehicle_input.heartbeat_tail_enabled =
      vehicle_scheduler_.has_seen_heartbeat();
  vehicle_input.heartbeat_tail_available = heartbeat.tail_available;
  vehicle_input.heartbeat_tail_active = heartbeat.active;
  vehicle_input.heartbeat_tail_active_started =
      heartbeat.active_started;
  if (heartbeat.present && heartbeat.tail_available) {
    vehicle_input.heartbeat_deadline_valid = true;
    vehicle_input.heartbeat_order = heartbeat.order;
    vehicle_input.heartbeat_enqueued_ms = heartbeat.enqueued_ms;
    const std::uint64_t maximum =
        std::numeric_limits<std::uint64_t>::max();
    constexpr std::uint64_t kDeadlineMs =
        FixedFirmwareContract::heartbeat_hard_deadline_ms;
    vehicle_input.heartbeat_deadline_ms =
        heartbeat.enqueued_ms > maximum - kDeadlineMs
            ? maximum
            : heartbeat.enqueued_ms + kDeadlineMs;
  }
  std::array<std::uint8_t, kLinkDataMaxWireBytes> ground_preview_bytes{};
  std::size_t preview_limit = std::min<std::size_t>(
      ground_usb_buffer_.size(), config_.radio_chunk_bytes);
  if (ground_.has_valid_grant()) {
    const std::size_t remaining =
        ground_.actual_bytes() < ground_.granted_bytes()
            ? static_cast<std::size_t>(ground_.granted_bytes() -
                                       ground_.actual_bytes())
            : 0U;
    preview_limit = std::min(preview_limit, remaining);
  }
  const std::size_t preview_copied = ground_usb_buffer_.copy_front(
      ground_preview_bytes.data(), preview_limit);
  const EncodedLinkDataChunk ground_preview =
      encode_link_data(ground_preview_bytes.data(), preview_copied);
  TddInput ground_input{
      now_ms_, ground_radio_.aux_high(now_ms_),
      ground_radio_.tx_empty(now_ms_), true,
      narrow_queue(ground_usb_buffer_.size())};
  ground_input.next_tx_application_bytes =
      static_cast<std::uint16_t>(ground_preview.input_consumed);
  ground_input.next_tx_wire_bytes =
      static_cast<std::uint16_t>(ground_preview.wire_size);
  process_vehicle_action(vehicle_.tick(vehicle_input), now_ms_);
  process_ground_action(ground_.tick(ground_input), now_ms_);
  record_state_cycle_changes();

  if (vehicle_.cycle_id() != last_vehicle_cycle_) {
    last_vehicle_cycle_ = vehicle_.cycle_id();
    ++stats_.cycles_completed;
  }
  sync_scheduler_diagnostics();
  ++now_ms_;
}

void MavlinkE2eSimulation::step_event_driven(std::uint64_t quantum_ms) {
  if (quantum_ms == 0U) {
    return;
  }
  step();
  if (quantum_ms > 1U) {
    now_ms_ += quantum_ms - 1U;
  }
}

void MavlinkE2eSimulation::run_for(std::uint64_t duration_ms) {
  const std::uint64_t deadline = now_ms_ + duration_ms;
  while (now_ms_ < deadline) {
    step();
  }
}

bool MavlinkE2eSimulation::run_until_vehicle_frames(
    std::size_t count, std::uint64_t timeout_ms) {
  const std::uint64_t deadline = now_ms_ + timeout_ms;
  while (vehicle_frames_.size() < count && now_ms_ < deadline) {
    step();
  }
  return vehicle_frames_.size() >= count;
}

bool MavlinkE2eSimulation::run_until_ground_frames(
    std::size_t count, std::uint64_t timeout_ms) {
  const std::uint64_t deadline = now_ms_ + timeout_ms;
  while (ground_frames_.size() < count && now_ms_ < deadline) {
    step();
  }
  return ground_frames_.size() >= count;
}

bool MavlinkE2eSimulation::run_until_vehicle_parser_buffered(
    std::size_t minimum, std::uint64_t timeout_ms) {
  const std::uint64_t deadline = now_ms_ + timeout_ms;
  while (vehicle_endpoint_parser_.buffered_size() < minimum &&
         vehicle_frames_.empty() && now_ms_ < deadline) {
    step();
  }
  return vehicle_endpoint_parser_.buffered_size() >= minimum;
}

bool MavlinkE2eSimulation::run_until_ground_parser_buffered(
    std::size_t minimum, std::uint64_t timeout_ms) {
  const std::uint64_t deadline = now_ms_ + timeout_ms;
  while (ground_endpoint_parser_.buffered_size() < minimum &&
         ground_frames_.empty() && now_ms_ < deadline) {
    step();
  }
  return ground_endpoint_parser_.buffered_size() >= minimum;
}

}  // namespace vc_lora::test
