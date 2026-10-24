#include "rf_medium_sim.hpp"

#include <algorithm>
#include <limits>

#include "vc_lora/tdd_control_codec.hpp"

namespace vc_lora::test {

RfMediumSim::RfMediumSim(const RfMediumConfig& config, std::uint32_t seed,
                         LinkDiagnostics& diagnostics)
    : config_(config),
      diagnostics_(&diagnostics),
      random_state_(seed == 0U ? 0x6D2B79F5U : seed) {}

std::size_t RfMediumSim::node_index(NodeId node) noexcept {
  return node == NodeId::Vehicle ? 0U : 1U;
}

NodeId RfMediumSim::other(NodeId node) noexcept {
  return node == NodeId::Vehicle ? NodeId::Ground : NodeId::Vehicle;
}

bool RfMediumSim::is_control_payload(const std::uint8_t* bytes,
                                     std::size_t size) noexcept {
  return bytes != nullptr && size == kTddControlFrameSize &&
         bytes[0] == static_cast<std::uint8_t>('V') &&
         bytes[1] == static_cast<std::uint8_t>('C') &&
         bytes[2] == static_cast<std::uint8_t>('T') &&
         bytes[3] == static_cast<std::uint8_t>('D');
}

bool RfMediumSim::receiver_transmitted_during(
    NodeId receiver, std::uint64_t start_ms,
    std::uint64_t end_ms) const noexcept {
  return std::any_of(
      transmissions_.begin(), transmissions_.end(),
      [receiver, start_ms, end_ms](const Transmission& transmission) {
        return transmission.sender == receiver &&
               transmission.start_ms < end_ms &&
               start_ms < transmission.end_ms;
      });
}

std::uint64_t RfMediumSim::duration_ms(std::size_t size) const noexcept {
  if (config_.buffered_air_subpacket_service_ms > 0U &&
      config_.sub_packet_bytes > 0U) {
    const std::uint64_t chunks =
        (size + config_.sub_packet_bytes - 1U) / config_.sub_packet_bytes;
    return std::max<std::uint64_t>(
        1U, chunks * config_.buffered_air_subpacket_service_ms);
  }
  if (size == 0U || config_.air_rate_bps == 0U ||
      config_.sub_packet_bytes == 0U) {
    return 1U;
  }
  const std::uint64_t bits_times_ms =
      static_cast<std::uint64_t>(size) * 8U * 1000U;
  const std::uint64_t air_ms =
      (bits_times_ms + config_.air_rate_bps - 1U) / config_.air_rate_bps;
  const std::uint64_t uart_bits_times_ms =
      static_cast<std::uint64_t>(size) * 10U * 1000U;
  const std::uint64_t uart_ms =
      config_.uart_rate_bps == 0U
          ? 0U
          : (uart_bits_times_ms + config_.uart_rate_bps - 1U) /
                config_.uart_rate_bps;
  const std::uint64_t chunks =
      (size + config_.sub_packet_bytes - 1U) / config_.sub_packet_bytes;
  const std::uint64_t gaps = chunks > 0U ? chunks - 1U : 0U;
  return std::max<std::uint64_t>(1U,
                                 uart_ms + air_ms +
                                     gaps * config_.min_tx_gap_ms);
}

std::uint64_t RfMediumSim::uart_duration_ms(
    std::size_t size) const noexcept {
  if (size == 0U || config_.uart_rate_bps == 0U) {
    return 1U;
  }
  const std::uint64_t bits_times_ms =
      static_cast<std::uint64_t>(size) * 10U * 1000U;
  return std::max<std::uint64_t>(
      1U, (bits_times_ms + config_.uart_rate_bps - 1U) /
              config_.uart_rate_bps);
}

bool RfMediumSim::random_hit(std::uint16_t permyriad) {
  if (permyriad == 0U) {
    return false;
  }
  if (permyriad >= 10'000U) {
    return true;
  }
  // xorshift32: deterministic on every supported C++17 compiler.
  random_state_ ^= random_state_ << 13U;
  random_state_ ^= random_state_ >> 17U;
  random_state_ ^= random_state_ << 5U;
  return random_state_ % 10'000U < permyriad;
}

TxOutcome RfMediumSim::transmit(NodeId sender, std::uint64_t now_ms,
                                const std::uint8_t* bytes, std::size_t size) {
  TxOutcome outcome{};
  if (bytes == nullptr || size == 0U) {
    return outcome;
  }
  if (size > kMaxSimFrameBytes || size > config_.uart_buffer_bytes) {
    ++diagnostics_->uart_buffer_drop_count;
    return outcome;
  }
  const std::size_t sender_index = node_index(sender);
  if (now_ms < busy_until_[sender_index]) {
    return outcome;
  }
  const bool buffered_air =
      config_.buffered_air_subpacket_service_ms > 0U;
  if (buffered_air &&
      buffered_bytes_[sender_index] + size > config_.uart_buffer_bytes) {
    ++diagnostics_->uart_buffer_drop_count;
    return outcome;
  }

  const bool control = is_control_payload(bytes, size);

  Transmission tx{};
  tx.id = next_tx_id_++;
  tx.sender = sender;
  const std::uint64_t uart_end_ms = now_ms + uart_duration_ms(size);
  tx.start_ms = buffered_air
                    ? std::max(uart_end_ms, air_available_ms_[sender_index])
                    : now_ms;
  tx.end_ms = now_ms + duration_ms(size);
  if (buffered_air) {
    tx.end_ms = tx.start_ms + duration_ms(size);
  }
  tx.payload.size = size;
  std::copy_n(bytes, size, tx.payload.bytes.begin());

  if (have_direction_ && sender != last_sender_ &&
      tx.start_ms < last_direction_end_ms_ + config_.turnaround_ms) {
    tx.turnaround_violation = true;
    ++diagnostics_->turnaround_drop_count;
  }

  for (auto& existing : transmissions_) {
    if (!existing.finalized && existing.start_ms < tx.end_ms &&
        tx.start_ms < existing.end_ms && existing.sender != sender) {
      if (!existing.collided) {
        ++collision_count_;
        ++diagnostics_->collision_count;
      }
      existing.collided = true;
      tx.collided = true;
    }
  }

  busy_until_[sender_index] = buffered_air ? uart_end_ms : tx.end_ms;
  if (buffered_air) {
    air_available_ms_[sender_index] = tx.end_ms;
    buffered_bytes_[sender_index] += size;
    ++uart_admission_count_[sender_index];
  }
  have_direction_ = true;
  last_sender_ = sender;
  last_direction_end_ms_ = tx.end_ms;
  if (control) {
    ++control_tx_count_[node_index(sender)];
  } else {
    ++data_tx_count_[node_index(sender)];
  }
  transmissions_.push_back(tx);
  max_retained_transmission_count_ =
      std::max(max_retained_transmission_count_, transmissions_.size());
  if (!have_pending_finalization_ || tx.end_ms < next_finalize_ms_) {
    have_pending_finalization_ = true;
    next_finalize_ms_ = tx.end_ms;
  }

  outcome.accepted = true;
  outcome.tx_id = tx.id;
  outcome.end_ms = tx.end_ms;
  return outcome;
}

void RfMediumSim::finalize(Transmission& tx) {
  tx.finalized = true;
  if (config_.buffered_air_subpacket_service_ms > 0U) {
    const std::size_t sender_index = node_index(tx.sender);
    buffered_bytes_[sender_index] =
        tx.payload.size <= buffered_bytes_[sender_index]
            ? buffered_bytes_[sender_index] - tx.payload.size
            : 0U;
    ++air_completion_count_[sender_index];
  }
  FaultFlags& faults = faults_[node_index(tx.sender)];
  const bool control =
      is_control_payload(tx.payload.bytes.data(), tx.payload.size);
  const bool targeted_drop = control && faults.drop_control;
  const bool targeted_corrupt = control && faults.corrupt_control;
  const bool targeted_duplicate = control && faults.duplicate_control;
  if (control) {
    faults.drop_control = false;
    faults.corrupt_control = false;
    faults.duplicate_control = false;
  }

  if (tx.collided || tx.turnaround_violation || targeted_drop ||
      random_hit(config_.loss_permyriad)) {
    ++diagnostics_->packet_loss_count;
    return;
  }

  RfDelivery delivery{};
  delivery.sender = tx.sender;
  delivery.receiver = other(tx.sender);
  delivery.start_ms = tx.start_ms + config_.propagation_delay_ms;
  delivery.ready_ms = tx.end_ms + config_.propagation_delay_ms;
  delivery.payload = tx.payload;
  bool random_corrupt = false;
  if (!targeted_corrupt) {
    random_corrupt = random_hit(config_.corruption_permyriad);
  }
  if ((targeted_corrupt || random_corrupt) &&
      delivery.payload.size > 0U) {
    const std::size_t index = delivery.payload.size / 2U;
    delivery.payload.bytes[index] ^= 0x01U;
    if (targeted_corrupt) {
      ++targeted_corruption_injection_count_;
    } else {
      ++random_corruption_injection_count_;
    }
  }
  deliveries_.push_back(delivery);
  ++successful_deliveries_;
  if (targeted_duplicate) {
    delivery.ready_ms += 1U;
    deliveries_.push_back(delivery);
    ++successful_deliveries_;
  }
  max_pending_delivery_count_ =
      std::max(max_pending_delivery_count_, deliveries_.size());
}

bool RfMediumSim::needed_for_pending_delivery(
    const Transmission& transmission) const noexcept {
  return std::any_of(
      deliveries_.begin(), deliveries_.end(),
      [&transmission](const RfDelivery& delivery) {
        return transmission.sender == delivery.receiver &&
               transmission.start_ms < delivery.ready_ms &&
               delivery.start_ms < transmission.end_ms;
      });
}

void RfMediumSim::prune_finalized(std::uint64_t now_ms) {
  transmissions_.erase(
      std::remove_if(
          transmissions_.begin(), transmissions_.end(),
          [this, now_ms](const Transmission& transmission) {
            if (!transmission.finalized) {
              return false;
            }

            // A finalized transmission remains observable while its RF tail
            // is propagating.  It must also remain available when a queued
            // delivery still needs it for receive-while-transmit detection.
            const std::uint64_t receive_end =
                transmission.end_ms + config_.propagation_delay_ms;
            return now_ms >= receive_end &&
                   !needed_for_pending_delivery(transmission);
          }),
      transmissions_.end());
}

void RfMediumSim::advance(std::uint64_t now_ms) {
  if (!have_pending_finalization_ || now_ms < next_finalize_ms_) {
    prune_finalized(now_ms);
    return;
  }

  have_pending_finalization_ = false;
  for (auto& tx : transmissions_) {
    if (!tx.finalized && tx.end_ms <= now_ms) {
      finalize(tx);
    } else if (!tx.finalized &&
               (!have_pending_finalization_ || tx.end_ms < next_finalize_ms_)) {
      have_pending_finalization_ = true;
      next_finalize_ms_ = tx.end_ms;
    }
  }
  prune_finalized(now_ms);
}

bool RfMediumSim::pop_delivery(NodeId receiver, std::uint64_t now_ms,
                               RfDelivery& output) {
  for (auto iterator = deliveries_.begin(); iterator != deliveries_.end();) {
    if (iterator->receiver != receiver || iterator->ready_ms > now_ms) {
      ++iterator;
      continue;
    }
    if (receiver_transmitted_during(receiver, iterator->start_ms,
                                    iterator->ready_ms)) {
      ++diagnostics_->half_duplex_drop_count;
      ++diagnostics_->packet_loss_count;
      iterator = deliveries_.erase(iterator);
      prune_finalized(now_ms);
      continue;
    }
    output = *iterator;
    deliveries_.erase(iterator);
    prune_finalized(now_ms);
    return true;
  }
  prune_finalized(now_ms);
  return false;
}

bool RfMediumSim::tx_empty(NodeId node,
                           std::uint64_t now_ms) const noexcept {
  return now_ms >= busy_until_[node_index(node)];
}

bool RfMediumSim::uart_ready(NodeId node,
                             std::uint64_t now_ms) const noexcept {
  const std::size_t index = node_index(node);
  if (now_ms < busy_until_[index]) {
    return false;
  }
  if (config_.buffered_air_subpacket_service_ms == 0U) {
    return true;
  }
  const std::uint64_t admission_bytes =
      std::max<std::uint16_t>(1U, config_.sub_packet_bytes);
  return buffered_bytes_[index] + admission_bytes <=
         config_.uart_buffer_bytes;
}

bool RfMediumSim::rx_active(NodeId node,
                            std::uint64_t now_ms) const noexcept {
  return std::any_of(
      transmissions_.begin(), transmissions_.end(),
      [this, node, now_ms](const Transmission& transmission) {
        if (transmission.sender == node) {
          return false;
        }
        const std::uint64_t receive_start =
            transmission.start_ms + config_.propagation_delay_ms;
        const std::uint64_t receive_end =
            transmission.end_ms + config_.propagation_delay_ms;
        return receive_start <= now_ms && now_ms < receive_end;
      });
}

std::uint64_t RfMediumSim::busy_until(NodeId node) const noexcept {
  return busy_until_[node_index(node)];
}

std::uint64_t RfMediumSim::buffered_bytes(NodeId node) const noexcept {
  return buffered_bytes_[node_index(node)];
}

std::uint64_t RfMediumSim::uart_admission_count(
    NodeId node) const noexcept {
  return uart_admission_count_[node_index(node)];
}

std::uint64_t RfMediumSim::air_completion_count(
    NodeId node) const noexcept {
  return air_completion_count_[node_index(node)];
}

std::uint64_t RfMediumSim::data_tx_count(NodeId node) const noexcept {
  return data_tx_count_[node_index(node)];
}

std::uint64_t RfMediumSim::control_tx_count(NodeId node) const noexcept {
  return control_tx_count_[node_index(node)];
}

void RfMediumSim::duplicate_next_control(NodeId sender) noexcept {
  faults_[node_index(sender)].duplicate_control = true;
}

void RfMediumSim::drop_next_control(NodeId sender) noexcept {
  faults_[node_index(sender)].drop_control = true;
}

void RfMediumSim::corrupt_next_control(NodeId sender) noexcept {
  faults_[node_index(sender)].corrupt_control = true;
}

}  // namespace vc_lora::test
