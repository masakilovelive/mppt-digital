#include "tdd_simulation.hpp"

#include <algorithm>
#include <array>
#include <limits>

#include "vc_lora/tx_gate.hpp"

namespace vc_lora::test {

TddSimulation::TddSimulation(const TddConfig& tdd_config,
                             const RfMediumConfig& rf_config,
                             std::uint32_t seed, LocalClock vehicle_clock,
                             LocalClock ground_clock)
    : config_(tdd_config),
      medium_(rf_config, seed, diagnostics_),
      vehicle_radio_(NodeId::Vehicle, medium_),
      ground_radio_(NodeId::Ground, medium_),
      vehicle_(config_, diagnostics_),
      ground_(config_, diagnostics_),
      vehicle_clock_(vehicle_clock),
      ground_clock_(ground_clock) {}

std::size_t TddSimulation::ingest_ground_usb(
    const std::uint8_t* bytes, std::size_t size) noexcept {
  if (bytes == nullptr || size == 0U) {
    return 0U;
  }

  diagnostics_.ground_usb_rx_bytes += size;
  const std::size_t accepted = ground_usb_buffer_.write(bytes, size);
  diagnostics_.ground_usb_accepted_bytes += accepted;
  diagnostics_.ground_usb_dropped_bytes += size - accepted;
  if (accepted < size) {
    ++diagnostics_.ground_buffer_overflow_count;
  }

  const std::size_t expected =
      expected_vehicle_uplink_.write(bytes, accepted);
  if (expected != accepted) {
    diagnostics_.ground_payload_order_errors += accepted - expected;
  }
  diagnostics_.max_ground_queue =
      std::max<std::uint64_t>(diagnostics_.max_ground_queue,
                              ground_usb_buffer_.size());
  return accepted;
}

void TddSimulation::queue_ground_bytes(std::uint32_t bytes) noexcept {
  std::array<std::uint8_t, 256> generated{};
  std::uint32_t remaining = bytes;
  while (remaining > 0U) {
    const std::size_t count =
        std::min<std::size_t>(remaining, generated.size());
    for (std::size_t index = 0; index < count; ++index) {
      generated[index] = next_ground_generated_byte_;
      next_ground_generated_byte_ =
          static_cast<std::uint8_t>(next_ground_generated_byte_ + 37U);
    }
    ingest_ground_usb(generated.data(), count);
    remaining -= static_cast<std::uint32_t>(count);
  }
}

void TddSimulation::clear_ground_queue() noexcept {
  ground_usb_buffer_.clear();
  expected_vehicle_uplink_.clear();
}

void TddSimulation::start(std::uint16_t session_id,
                          std::uint16_t initial_cycle) {
  diagnostics_.clear();
  stats_ = {};
  clock_.set_ms(0);
  ground_usb_buffer_.reset();
  expected_vehicle_uplink_.reset();
  next_ground_generated_byte_ = 0xA0U;
  vehicle_queue_bytes_ = vehicle_downlink_per_cycle_;
  vehicle_demux_.reset();
  ground_demux_.reset();
  vehicle_local_leak_detector_.reset();
  ground_local_leak_detector_.reset();
  vehicle_.reset(session_id, initial_cycle, vehicle_clock_.now_ms(0));
  ground_.reset(ground_clock_.now_ms(0));
  last_vehicle_cycle_ = initial_cycle;
  last_vehicle_state_ = vehicle_.state();
  last_ground_state_ = ground_.state();
  started_ = true;
  record("vehicle", vehicle_state_name(vehicle_.state()),
         vehicle_.cycle_id(), "RESET", vehicle_radio_.aux_high(0), 0, 0, 0);
  record("ground", ground_state_name(ground_.state()), ground_.cycle_id(),
         "RESET", ground_radio_.aux_high(0), 0, 0, 0);
}

void TddSimulation::record(const char* node, const char* state,
                           std::uint16_t cycle, const std::string& event,
                           bool aux_high, std::uint64_t queue_bytes,
                           std::uint64_t tx_bytes,
                           std::uint64_t rx_bytes) {
  trace_.record({clock_.now_ms(), node, state, cycle, event, aux_high,
                 queue_bytes, tx_bytes, rx_bytes,
                 node[0] == 'v' ? vehicle_.session_id()
                                : ground_.session_id()});
}

void TddSimulation::deliver_one(const RfDelivery& delivery) {
  TddLinkDemux* demux = delivery.receiver == NodeId::Vehicle
                            ? &vehicle_demux_
                            : &ground_demux_;
  TddControlStreamDecoder* leak_detector =
      delivery.receiver == NodeId::Vehicle
          ? &vehicle_local_leak_detector_
          : &ground_local_leak_detector_;

  const auto deliver_local = [&](const std::uint8_t* bytes,
                                 std::size_t size) {
    for (std::size_t index = 0; index < size; ++index) {
      if (leak_detector->push(bytes[index]).status != DecodeStatus::NeedMore) {
        ++diagnostics_.control_bytes_leaked_to_local_uart;
      }
    }
    if (delivery.receiver == NodeId::Vehicle) {
      if (!vehicle_.radio_receive_window()) {
        ++diagnostics_.uplink_data_outside_receive_window;
        record("vehicle", vehicle_state_name(vehicle_.state()),
               vehicle_.cycle_id(), "DROP_UPLINK_OUTSIDE_WINDOW",
               vehicle_radio_.aux_high(clock_.now_ms()), 0, 0,
               size);
        return;
      }
      for (std::size_t index = 0; index < size; ++index) {
        std::uint8_t expected = 0U;
        if (!expected_vehicle_uplink_.pop(expected) ||
            expected != bytes[index]) {
          ++diagnostics_.ground_payload_order_errors;
        }
      }
      stats_.vehicle_payload_rx += size;
      record("vehicle", vehicle_state_name(vehicle_.state()),
             vehicle_.cycle_id(), "RX_UPLINK_DATA",
             vehicle_radio_.aux_high(clock_.now_ms()), 0, 0,
             size);
    } else {
      stats_.ground_payload_rx += size;
      record("ground", ground_state_name(ground_.state()),
             ground_.cycle_id(), "RX_DOWNLINK_DATA",
             ground_radio_.aux_high(clock_.now_ms()), ground_queue_bytes(), 0,
             size);
    }
  };

  const auto deliver_control = [&](const DecodeEvent& decoded) {
    const VehicleTddState vehicle_state_before = vehicle_.state();
    const GroundTddState ground_state_before = ground_.state();
    const std::uint16_t vehicle_session_before = vehicle_.session_id();
    const std::uint16_t ground_session_before = ground_.session_id();
    const std::uint16_t vehicle_cycle_before = vehicle_.cycle_id();
    const std::uint16_t ground_cycle_before = ground_.cycle_id();
    diagnostics_.note_decode_status(decoded.status);
    if (decoded.status != DecodeStatus::Message) {
      if (decoded.status == DecodeStatus::BadCrc &&
          (vehicle_.state() != vehicle_state_before ||
           ground_.state() != ground_state_before ||
           vehicle_.session_id() != vehicle_session_before ||
           ground_.session_id() != ground_session_before ||
           vehicle_.cycle_id() != vehicle_cycle_before ||
           ground_.cycle_id() != ground_cycle_before)) {
        ++diagnostics_.invalid_crc_state_transition;
      }
      record(delivery.receiver == NodeId::Vehicle ? "vehicle" : "ground",
             delivery.receiver == NodeId::Vehicle
                 ? vehicle_state_name(vehicle_.state())
                 : ground_state_name(ground_.state()),
             delivery.receiver == NodeId::Vehicle ? vehicle_.cycle_id()
                                                  : ground_.cycle_id(),
             decoded.status == DecodeStatus::BadCrc ? "CONTROL_BAD_CRC"
                                                    : "CONTROL_REJECTED",
             delivery.receiver == NodeId::Vehicle
                 ? vehicle_radio_.aux_high(clock_.now_ms())
                 : ground_radio_.aux_high(clock_.now_ms()),
             ground_queue_bytes(), 0, kTddControlFrameSize);
      return;
    }

    if (delivery.receiver == NodeId::Ground) {
      ++stats_.ground_control_rx;
      if (faults_.busy_ground_on_grant_cycle ==
          static_cast<int>(decoded.message.cycle_id)) {
        ground_radio_.force_aux_low_until(clock_.now_ms() +
                                           faults_.ground_aux_busy_ms);
      }
      const ControlDisposition disposition = ground_.on_control(
          decoded.message, ground_clock_.now_ms(clock_.now_ms()));
      if (disposition == ControlDisposition::Accepted &&
          stats_.first_grant_rx_ms == 0U) {
        stats_.first_grant_rx_ms = clock_.now_ms();
      }
      record("ground", ground_state_name(ground_.state()), ground_.cycle_id(),
             disposition == ControlDisposition::Accepted ? "RX_UL_GRANT"
                                                         : "REJECT_UL_GRANT",
             ground_radio_.aux_high(clock_.now_ms()), ground_queue_bytes(), 0,
             kTddControlFrameSize);
      if (faults_.reset_ground_on_grant_cycle ==
              static_cast<int>(decoded.message.cycle_id) &&
          disposition == ControlDisposition::Accepted) {
        restart_ground();
        faults_.reset_ground_on_grant_cycle = -1;
      }
    } else {
      ++stats_.vehicle_control_rx;
      const ControlDisposition disposition = vehicle_.on_control(
          decoded.message, vehicle_clock_.now_ms(clock_.now_ms()));
      record("vehicle", vehicle_state_name(vehicle_.state()),
             vehicle_.cycle_id(),
             disposition == ControlDisposition::Accepted ? "RX_UL_DONE"
                                                         : "REJECT_UL_DONE",
             vehicle_radio_.aux_high(clock_.now_ms()), 0, 0,
             kTddControlFrameSize);
    }
  };

  std::array<std::uint8_t, kMaxSimFrameBytes +
                               kTddDemuxMaxLocalBytes> local{};
  std::size_t local_size = 0;
  const auto flush_local = [&]() {
    if (local_size > 0U) {
      deliver_local(local.data(), local_size);
      local_size = 0;
    }
  };

  for (std::size_t index = 0; index < delivery.payload.size; ++index) {
    const TddDemuxEvent event = demux->push(delivery.payload.bytes[index]);
    for (std::size_t local_index = 0; local_index < event.local_size;
         ++local_index) {
      local[local_size++] = event.local_bytes[local_index];
    }
    if (event.has_control) {
      flush_local();
      deliver_control(event.control);
    }
  }
  flush_local();
}

void TddSimulation::deliver_radio() {
  RfDelivery delivery{};
  while (medium_.pop_delivery(NodeId::Ground, clock_.now_ms(), delivery)) {
    deliver_one(delivery);
  }
  while (medium_.pop_delivery(NodeId::Vehicle, clock_.now_ms(), delivery)) {
    deliver_one(delivery);
  }
}

void TddSimulation::process_vehicle_action(const LinkAction& action,
                                           std::uint64_t vehicle_now) {
  if (action.type == LinkActionType::SendRadioData) {
    if (!TxGate::authorize_vehicle(vehicle_.state(), TxClass::DownlinkData,
                                   diagnostics_)) {
      vehicle_.complete_action(action.token, TxResult::Rejected, vehicle_now);
      return;
    }
    std::array<std::uint8_t, kMaxSimFrameBytes> payload{};
    const std::size_t count = std::min<std::size_t>(action.byte_budget,
                                                    payload.size());
    for (std::size_t index = 0; index < count; ++index) {
      payload[index] = static_cast<std::uint8_t>(0x50U + (index & 0x0FU));
    }
    const TxOutcome outcome = vehicle_radio_.write(
        clock_.now_ms(), payload.data(), count);
    vehicle_.complete_action(action.token,
                             outcome.accepted ? TxResult::Accepted
                                              : TxResult::Rejected,
                             vehicle_now);
    if (outcome.accepted) {
      vehicle_queue_bytes_ -= static_cast<std::uint32_t>(count);
      ++stats_.vehicle_payload_tx;
    }
    record("vehicle", vehicle_state_name(vehicle_.state()),
           vehicle_.cycle_id(),
           outcome.accepted ? "TX_DOWNLINK_DATA" : "TX_DATA_REJECTED",
           vehicle_radio_.aux_high(clock_.now_ms()), vehicle_queue_bytes_,
           outcome.accepted ? count : 0, 0);
    return;
  }

  if (action.type != LinkActionType::SendGrant) {
    return;
  }
  if (!TxGate::authorize_vehicle(vehicle_.state(), TxClass::GrantControl,
                                 diagnostics_)) {
    vehicle_.complete_action(action.token, TxResult::Rejected, vehicle_now);
    return;
  }

  if (faults_.drop_grant_cycle == static_cast<int>(action.control.cycle_id)) {
    medium_.drop_next_control(NodeId::Vehicle);
    faults_.drop_grant_cycle = -1;
  }
  if (faults_.duplicate_grant_cycle ==
      static_cast<int>(action.control.cycle_id)) {
    medium_.duplicate_next_control(NodeId::Vehicle);
    faults_.duplicate_grant_cycle = -1;
  }
  if (faults_.corrupt_grant_cycle ==
      static_cast<int>(action.control.cycle_id)) {
    medium_.corrupt_next_control(NodeId::Vehicle);
    faults_.corrupt_grant_cycle = -1;
  }

  std::array<std::uint8_t, kTddControlFrameSize> frame{};
  std::size_t encoded_size = 0;
  const bool encoded = encode_control(action.control, frame.data(),
                                      frame.size(), encoded_size);
  const TxOutcome outcome =
      encoded ? vehicle_radio_.write(clock_.now_ms(), frame.data(),
                                     encoded_size)
              : TxOutcome{};
  vehicle_.complete_action(action.token,
                           outcome.accepted ? TxResult::Accepted
                                            : TxResult::Rejected,
                           vehicle_now);
  record("vehicle", vehicle_state_name(vehicle_.state()),
         vehicle_.cycle_id(), outcome.accepted ? "TX_UL_GRANT" :
                                                "TX_GRANT_REJECTED",
         vehicle_radio_.aux_high(clock_.now_ms()), 0,
         outcome.accepted ? encoded_size : 0, 0);
}

void TddSimulation::process_ground_action(const LinkAction& action,
                                          std::uint64_t ground_now) {
  if (action.type == LinkActionType::SendRadioData) {
    const bool continuing_started_transaction =
        ground_.transaction_target_bytes() > 0U &&
        ground_.actual_bytes() > 0U &&
        ground_.actual_bytes() < ground_.transaction_target_bytes();
    if (!TxGate::authorize_ground(
            ground_.state(), TxClass::UplinkData, ground_.has_valid_grant(),
            ground_now, ground_.window_deadline_ms(), diagnostics_,
            continuing_started_transaction)) {
      ground_.complete_action(action.token, TxResult::Rejected, ground_now);
      return;
    }
    std::array<std::uint8_t, kMaxSimFrameBytes> payload{};
    const std::size_t count = std::min<std::size_t>(action.byte_budget,
                                                    payload.size());
    const std::size_t copied =
        ground_usb_buffer_.copy_front(payload.data(), count);
    if (copied != count) {
      ++diagnostics_.ground_queue_underflow_count;
      ground_.complete_action(action.token, TxResult::Rejected, ground_now);
      record("ground", ground_state_name(ground_.state()), ground_.cycle_id(),
             "TX_QUEUE_UNDERFLOW", ground_radio_.aux_high(clock_.now_ms()),
             ground_queue_bytes(), 0, 0);
      return;
    }

    const bool force_rejection =
        faults_.reject_ground_data_cycle == static_cast<int>(ground_.cycle_id());
    if (force_rejection) {
      faults_.reject_ground_data_cycle = -1;
    }
    const TxOutcome outcome =
        force_rejection
            ? TxOutcome{}
            : ground_radio_.write(clock_.now_ms(), payload.data(), count);
    ground_.complete_action(action.token,
                            outcome.accepted ? TxResult::Accepted
                                             : TxResult::Rejected,
                            ground_now);
    if (outcome.accepted) {
      const std::size_t discarded = ground_usb_buffer_.discard(count);
      diagnostics_.ground_usb_dequeued_bytes += discarded;
      if (discarded != count) {
        ++diagnostics_.ground_queue_underflow_count;
      }
      ++stats_.ground_payload_tx;
      stats_.max_ground_data_write_bytes =
          std::max<std::uint64_t>(stats_.max_ground_data_write_bytes, count);
      if (stats_.first_ground_payload_tx_ms == 0U) {
        stats_.first_ground_payload_tx_ms = clock_.now_ms();
      }
      stats_.last_ground_payload_tx_ms = clock_.now_ms();
    } else {
      ++stats_.ground_payload_rejected;
      stats_.queue_bytes_after_rejected_tx = ground_usb_buffer_.size();
    }
    record("ground", ground_state_name(ground_.state()), ground_.cycle_id(),
           outcome.accepted ? "TX_UPLINK_DATA" : "TX_DATA_REJECTED",
           ground_radio_.aux_high(clock_.now_ms()), ground_queue_bytes(),
           outcome.accepted ? count : 0, 0);
    return;
  }

  if (action.type != LinkActionType::SendDone) {
    return;
  }
  if (!TxGate::authorize_ground(
          ground_.state(), TxClass::DoneControl, ground_.has_valid_grant(),
          ground_now, ground_.window_deadline_ms(), diagnostics_)) {
    ground_.complete_action(action.token, TxResult::Rejected, ground_now);
    return;
  }
  if (faults_.drop_done_cycle == static_cast<int>(action.control.cycle_id)) {
    medium_.drop_next_control(NodeId::Ground);
    faults_.drop_done_cycle = -1;
  }
  std::array<std::uint8_t, kTddControlFrameSize> frame{};
  std::size_t encoded_size = 0;
  const bool encoded = encode_control(action.control, frame.data(),
                                      frame.size(), encoded_size);
  const TxOutcome outcome =
      encoded ? ground_radio_.write(clock_.now_ms(), frame.data(), encoded_size)
              : TxOutcome{};
  ground_.complete_action(action.token,
                          outcome.accepted ? TxResult::Accepted
                                           : TxResult::Rejected,
                          ground_now);
  record("ground", ground_state_name(ground_.state()), ground_.cycle_id(),
         outcome.accepted ? "TX_UL_DONE" : "TX_DONE_REJECTED",
         ground_radio_.aux_high(clock_.now_ms()), ground_queue_bytes(),
         outcome.accepted ? encoded_size : 0, 0);
}

void TddSimulation::step() {
  if (!started_) {
    start();
  }
  const std::uint64_t physical_now = clock_.now_ms();
  medium_.advance(physical_now);
  deliver_radio();

  const std::uint64_t vehicle_now = vehicle_clock_.now_ms(physical_now);
  const std::uint64_t ground_now = ground_clock_.now_ms(physical_now);
  const TddInput vehicle_input{vehicle_now,
                               vehicle_radio_.aux_high(physical_now),
                               vehicle_radio_.tx_empty(physical_now), true,
                               vehicle_queue_bytes_};
  const TddInput ground_input{ground_now,
                              ground_radio_.aux_high(physical_now),
                              ground_radio_.tx_empty(physical_now), true,
                              ground_queue_bytes()};
  process_vehicle_action(vehicle_.tick(vehicle_input), vehicle_now);
  process_ground_action(ground_.tick(ground_input), ground_now);

  if (physical_now % 50U == 0U) {
    record("vehicle", vehicle_state_name(vehicle_.state()),
           vehicle_.cycle_id(), "STATE_SAMPLE",
           vehicle_radio_.aux_high(physical_now), vehicle_queue_bytes_, 0, 0);
    record("ground", ground_state_name(ground_.state()), ground_.cycle_id(),
           "STATE_SAMPLE", ground_radio_.aux_high(physical_now),
           ground_queue_bytes(), 0, 0);
  }

  if (vehicle_.state() != last_vehicle_state_) {
    last_vehicle_state_ = vehicle_.state();
    record("vehicle", vehicle_state_name(vehicle_.state()),
           vehicle_.cycle_id(), "STATE", vehicle_input.aux_high, 0, 0, 0);
  }
  if (ground_.state() != last_ground_state_) {
    last_ground_state_ = ground_.state();
    record("ground", ground_state_name(ground_.state()), ground_.cycle_id(),
           "STATE", ground_input.aux_high, ground_queue_bytes(), 0, 0);
  }
  if (vehicle_.cycle_id() != last_vehicle_cycle_) {
    last_vehicle_cycle_ = vehicle_.cycle_id();
    ++stats_.cycles_completed;
    vehicle_queue_bytes_ += vehicle_downlink_per_cycle_;
  }
  clock_.advance_ms(1);
}

void TddSimulation::run_for(std::uint64_t duration_ms) {
  const std::uint64_t deadline = clock_.now_ms() + duration_ms;
  while (clock_.now_ms() < deadline) {
    step();
  }
}

bool TddSimulation::run_until_cycles(std::uint64_t cycles,
                                     std::uint64_t timeout_ms) {
  const std::uint64_t deadline = clock_.now_ms() + timeout_ms;
  while (stats_.cycles_completed < cycles && clock_.now_ms() < deadline) {
    step();
  }
  return stats_.cycles_completed >= cycles;
}

bool TddSimulation::run_until_cycles_event_driven(
    std::uint64_t target_cycles, std::uint64_t timeout_ms) {
  constexpr std::uint64_t kEventQuantumMs = 5U;
  const std::uint64_t now = clock_.now_ms();
  const std::uint64_t deadline =
      timeout_ms > std::numeric_limits<std::uint64_t>::max() - now
          ? std::numeric_limits<std::uint64_t>::max()
          : now + timeout_ms;

  while (stats_.cycles_completed < target_cycles &&
         clock_.now_ms() < deadline) {
    const std::uint64_t remaining = deadline - clock_.now_ms();
    const std::uint64_t quantum =
        std::min<std::uint64_t>(kEventQuantumMs, remaining);
    step();
    if (stats_.cycles_completed >= target_cycles) {
      break;
    }
    if (quantum > 1U) {
      clock_.advance_ms(quantum - 1U);
    }
  }
  return stats_.cycles_completed >= target_cycles;
}

bool TddSimulation::run_until_grants(std::uint64_t grants,
                                     std::uint64_t timeout_ms) {
  const std::uint64_t deadline = clock_.now_ms() + timeout_ms;
  while (diagnostics_.grant_tx < grants && clock_.now_ms() < deadline) {
    step();
  }
  return diagnostics_.grant_tx >= grants;
}

void TddSimulation::restart_ground() {
  ground_.reset(ground_clock_.now_ms(clock_.now_ms()));
  ground_demux_.reset();
  ground_local_leak_detector_.reset();
  last_ground_state_ = ground_.state();
  record("ground", ground_state_name(ground_.state()), ground_.cycle_id(),
         "RESET", ground_radio_.aux_high(clock_.now_ms()),
         ground_queue_bytes(), 0, 0);
}

void TddSimulation::restart_vehicle(std::uint16_t new_session,
                                    std::uint16_t initial_cycle) {
  vehicle_.reset(new_session, initial_cycle,
                 vehicle_clock_.now_ms(clock_.now_ms()));
  vehicle_demux_.reset();
  vehicle_local_leak_detector_.reset();
  last_vehicle_cycle_ = initial_cycle;
  last_vehicle_state_ = vehicle_.state();
  record("vehicle", vehicle_state_name(vehicle_.state()),
         vehicle_.cycle_id(), "RESET", vehicle_radio_.aux_high(clock_.now_ms()),
         0, 0, 0);
}

ControlDisposition TddSimulation::inject_ground_control(
    const TddControlMessage& message) {
  return ground_.on_control(message,
                            ground_clock_.now_ms(clock_.now_ms()));
}

}  // namespace vc_lora::test
