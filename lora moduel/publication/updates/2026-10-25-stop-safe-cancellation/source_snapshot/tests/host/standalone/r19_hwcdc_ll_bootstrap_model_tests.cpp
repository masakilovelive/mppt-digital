#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <iostream>

namespace {

constexpr std::size_t kEndpointCapacity = 64U;
constexpr std::size_t kBootstrapSize = 63U;
constexpr std::size_t kPayloadChunk = 32U;
static_assert(kPayloadChunk < kEndpointCapacity,
              "payload chunks must remain below auto-flush");

using BootstrapFrame = std::array<std::uint8_t, kBootstrapSize>;

struct TestReport {
  std::size_t checks{0U};
  std::size_t failures{0U};

  void check(bool condition, const char* message) noexcept {
    ++checks;
    if (!condition) {
      ++failures;
      std::cerr << "FAIL: " << message << '\n';
    }
  }
};

enum class BootstrapScheme : std::uint8_t {
  EmptyZlpKick,
  DirectPrime,
};

enum class FlushTailPolicy : std::uint8_t {
  UnconditionalReflush,
  DiagnosticPredicateOwnedOnly,
};

enum class CandidateFeatureMode : std::uint8_t {
  R18MacroOff,
  R19MacroOn,
};

enum class FinalPacketClass : std::uint8_t {
  ShortPacket,
  FullEndpointPacket,
  Unknown,
};

enum class TerminalZlpOwnership : std::uint8_t {
  None,
  InFlight,
  PickedUp,
};

enum class PayloadLoadResult : std::uint8_t {
  Empty,
  Retry,
  Published,
};

// Deterministic model of the flushTxComplete() final-ZLP race.  The host can
// pick up a pending ZLP after the loop's FIFO sample but before its tail kick.
// Reissuing at that point makes the next iteration observe a non-writable FIFO
// again and can repeat until the absolute timeout.  Once the final ZLP has
// been issued, the tail may re-arm IN_EMPTY but must not publish another ZLP.
class FlushCompletionLoopModel final {
 public:
  explicit FlushCompletionLoopModel(
      FlushTailPolicy policy,
      CandidateFeatureMode feature_mode = CandidateFeatureMode::R19MacroOn,
      FinalPacketClass final_packet_class =
          FinalPacketClass::FullEndpointPacket) noexcept
      : policy_(policy),
        feature_mode_(feature_mode),
        final_packet_class_(final_packet_class) {}

  void service_iteration(bool host_pickup_before_tail) noexcept {
    if (complete_) {
      return;
    }

    const bool completion_evidence_valid =
        publish_generation_ != 0U &&
        pickup_generation_ == publish_generation_ &&
        flush_loss_epoch_ == current_loss_epoch_ && !bus_reset_observed_;
    const bool completion_boundary_ready =
        fifo_writable_ && !software_pending_ && completion_evidence_valid;
    if (policy_ == FlushTailPolicy::DiagnosticPredicateOwnedOnly) {
      if (completion_boundary_ready &&
          feature_mode_ == CandidateFeatureMode::R19MacroOn &&
          final_packet_class_ == FinalPacketClass::ShortPacket) {
        complete_ = true;
        return;
      }
      if (completion_boundary_ready &&
          terminal_zlp_ownership_ == TerminalZlpOwnership::None) {
        issue_terminal_zlp();
      }
      if (completion_boundary_ready &&
          terminal_zlp_ownership_ == TerminalZlpOwnership::PickedUp) {
        complete_ = true;
        return;
      }
    } else {
      if (completion_boundary_ready && !final_flush_issued_) {
        issue_terminal_zlp();
      }
      if (completion_boundary_ready && final_flush_issued_ && fifo_writable_) {
        complete_ = true;
        return;
      }
    }

    if (host_pickup_before_tail && !fifo_writable_) {
      fifo_writable_ = true;
      if (terminal_zlp_ownership_ == TerminalZlpOwnership::InFlight) {
        terminal_zlp_ownership_ = TerminalZlpOwnership::PickedUp;
      }
    }

    const bool tail_flush_allowed =
        policy_ == FlushTailPolicy::UnconditionalReflush;
    if (tail_flush_allowed && fifo_writable_) {
      issue_terminal_zlp();
    }
    ++interrupt_rearm_count_;
  }

  [[nodiscard]] bool complete() const noexcept { return complete_; }
  [[nodiscard]] bool fifo_writable() const noexcept {
    return fifo_writable_;
  }
  [[nodiscard]] std::uint32_t terminal_zlp_count() const noexcept {
    return terminal_zlp_count_;
  }
  [[nodiscard]] std::uint32_t interrupt_rearm_count() const noexcept {
    return interrupt_rearm_count_;
  }
  void set_software_pending(bool pending) noexcept {
    software_pending_ = pending;
  }
  void set_generations(std::uint32_t published,
                       std::uint32_t picked_up) noexcept {
    publish_generation_ = published;
    pickup_generation_ = picked_up;
  }
  void set_loss_epochs(std::uint32_t flush_epoch,
                       std::uint32_t current_epoch) noexcept {
    flush_loss_epoch_ = flush_epoch;
    current_loss_epoch_ = current_epoch;
  }
  void observe_bus_reset() noexcept { bus_reset_observed_ = true; }
  void host_pickup_between_calls() noexcept {
    fifo_writable_ = true;
    if (terminal_zlp_ownership_ == TerminalZlpOwnership::InFlight) {
      terminal_zlp_ownership_ = TerminalZlpOwnership::PickedUp;
    }
  }
  void service_stale_entry_snapshot_without_live_event() noexcept {
    // Production re-samples live IN_EMPTY after taking the TX mux. An entry
    // snapshot which the publisher already cleared owns no current event.
  }
  void invalidate_terminal_for_new_payload() noexcept {
    terminal_zlp_ownership_ = TerminalZlpOwnership::None;
  }
  void restart_flush_call() noexcept {
    // A new C++ call loses only its local convenience flag. The diagnostic
    // terminal-ZLP transaction remains bound to the same logical boundary.
    final_flush_issued_ = false;
    complete_ = false;
  }

 private:
  void issue_terminal_zlp() noexcept {
    final_flush_issued_ = true;
    if (policy_ == FlushTailPolicy::DiagnosticPredicateOwnedOnly) {
      terminal_zlp_ownership_ = TerminalZlpOwnership::InFlight;
    }
    fifo_writable_ = false;
    ++terminal_zlp_count_;
  }

  FlushTailPolicy policy_;
  CandidateFeatureMode feature_mode_;
  FinalPacketClass final_packet_class_;
  std::uint32_t terminal_zlp_count_{0U};
  std::uint32_t interrupt_rearm_count_{0U};
  std::uint32_t publish_generation_{1U};
  std::uint32_t pickup_generation_{1U};
  std::uint32_t flush_loss_epoch_{0U};
  std::uint32_t current_loss_epoch_{0U};
  bool fifo_writable_{true};
  bool final_flush_issued_{false};
  TerminalZlpOwnership terminal_zlp_ownership_{
      TerminalZlpOwnership::None};
  bool complete_{false};
  bool software_pending_{false};
  bool bus_reset_observed_{false};
};

// Deterministic model of the ESP32-S3 USB Serial/JTAG IN boundary used by the
// R19 63-byte bootstrap. FIFO writes, wr_done publication, host pickup and
// IN_EMPTY interrupt service are separate events. The direct path mirrors
// production: the first 32-byte packet is task-primed and the final 31 bytes
// are published by the IN_EMPTY ISR only after pickup of the first packet.
class HwcdcLlSimulator {
 public:
  explicit HwcdcLlSimulator(BootstrapScheme scheme) noexcept
      : scheme_(scheme) {}

  bool stage_legacy(const BootstrapFrame& frame) noexcept {
    if (scheme_ != BootstrapScheme::EmptyZlpKick || quarantined_ ||
        ring_size_ != 0U || in_transaction_pending_) {
      return false;
    }
    std::copy(frame.begin(), frame.end(), ring_.begin());
    ring_size_ = frame.size();
    interrupt_enabled_ = true;
    issue_wr_done();  // Empty/ZLP kick: no payload has been published.
    return true;
  }

  bool begin_direct_prime(const BootstrapFrame& frame,
                          std::size_t fifo_accept_limit) noexcept {
    if (scheme_ != BootstrapScheme::DirectPrime || quarantined_ ||
        direct_prime_uncommitted_ || ring_size_ != 0U || stash_size_ != 0U ||
        fifo_size_ != 0U || in_transaction_pending_) {
      return false;
    }

    const std::size_t first_chunk = std::min(frame.size(), kPayloadChunk);
    const std::size_t accepted = std::min(first_chunk, fifo_accept_limit);
    if (accepted == 0U) {
      quarantine_and_advance_loss();
      return false;
    }

    std::copy_n(frame.begin(), accepted, fifo_.begin());
    fifo_size_ = accepted;
    if (accepted < first_chunk) {
      std::copy(frame.begin() + static_cast<std::ptrdiff_t>(accepted),
                frame.begin() + static_cast<std::ptrdiff_t>(first_chunk),
                stash_.begin());
      stash_size_ = first_chunk - accepted;
    }
    std::copy(frame.begin() + static_cast<std::ptrdiff_t>(first_chunk),
              frame.end(), ring_.begin());
    ring_size_ = frame.size() - first_chunk;
    direct_prime_uncommitted_ = true;
    return true;
  }

  bool commit_direct_prime(bool pickup_before_irq_enable = false) noexcept {
    if (scheme_ != BootstrapScheme::DirectPrime || quarantined_ ||
        !direct_prime_uncommitted_ || fifo_size_ == 0U) {
      return false;
    }

    // Required production order: mask, clear stale event, arm this packet's
    // generation, wr_done publication, then enable IN_EMPTY. A pickup in the
    // wr_done->enable window remains latched and is serviced afterwards.
    interrupt_enabled_ = false;
    in_empty_interrupt_pending_ = false;
    ++publish_generation_;
    payload_in_flight_ = true;
    direct_prime_uncommitted_ = false;
    issue_wr_done();
    if (pickup_before_irq_enable && !host_poll()) {
      quarantine_and_advance_loss();
      return false;
    }
    interrupt_enabled_ = true;
    return true;
  }

  bool stage_direct(const BootstrapFrame& frame,
                    std::size_t fifo_accept_limit = kEndpointCapacity,
                    bool pickup_before_irq_enable = false) noexcept {
    return begin_direct_prime(frame, fifo_accept_limit) &&
           commit_direct_prime(pickup_before_irq_enable);
  }

  void seed_stale_in_empty() noexcept { in_empty_interrupt_pending_ = true; }

  void bus_reset() noexcept { quarantine_and_advance_loss(); }

  bool host_poll() noexcept {
    if (!in_transaction_pending_) {
      return false;
    }
    if (host_size_ + pending_packet_size_ > host_bytes_.size()) {
      quarantine_and_advance_loss();
      return false;
    }
    std::copy_n(pending_packet_.begin(), pending_packet_size_,
                host_bytes_.begin() + static_cast<std::ptrdiff_t>(host_size_));
    host_size_ += pending_packet_size_;
    in_transaction_pending_ = false;
    pending_packet_size_ = 0U;
    in_empty_interrupt_pending_ = true;
    return true;
  }

  void service_isr(
      std::size_t fifo_accept_limit = kPayloadChunk) noexcept {
    if (!interrupt_enabled_ || !in_empty_interrupt_pending_ || quarantined_) {
      return;
    }
    in_empty_interrupt_pending_ = false;

    if (scheme_ == BootstrapScheme::EmptyZlpKick) {
      service_legacy_isr();
      return;
    }

    if (!payload_in_flight_ && ring_size_ == 0U && stash_size_ == 0U) {
      // A stale empty event is not a transaction-specific pickup witness.
      interrupt_enabled_ = false;
      return;
    }

    if (payload_in_flight_) {
      pickup_generation_ = publish_generation_;
      payload_in_flight_ = false;
    }

    const PayloadLoadResult load_result =
        load_next_payload_chunk(fifo_accept_limit);
    if (load_result == PayloadLoadResult::Retry) {
      // Enabling the level-triggered IN_EMPTY source schedules another pass;
      // no generation, WR_DONE, or TX event belongs to a zero-byte LL write.
      interrupt_enabled_ = true;
      in_empty_interrupt_pending_ = true;
      ++interrupt_rearm_count_;
      return;
    }
    if (load_result == PayloadLoadResult::Published) {
      ++publish_generation_;
      payload_in_flight_ = true;
      issue_wr_done();
      interrupt_enabled_ = true;
      ++isr_tx_event_count_;
      ++interrupt_rearm_count_;
      return;
    }

    interrupt_enabled_ = false;
    if (pickup_generation_ == publish_generation_) {
      ++completion_events_;
    }
  }

  [[nodiscard]] bool flush_complete() const noexcept {
    return scheme_ == BootstrapScheme::DirectPrime && !quarantined_ &&
           ring_size_ == 0U && stash_size_ == 0U &&
           !in_transaction_pending_ && !payload_in_flight_ &&
           publish_generation_ != 0U &&
           pickup_generation_ == publish_generation_;
  }
  [[nodiscard]] bool in_transaction_pending() const noexcept {
    return in_transaction_pending_;
  }
  [[nodiscard]] std::size_t pending_packet_size() const noexcept {
    return pending_packet_size_;
  }
  [[nodiscard]] std::size_t last_published_packet_size() const noexcept {
    return last_published_packet_size_;
  }
  [[nodiscard]] std::size_t ring_size() const noexcept { return ring_size_; }
  [[nodiscard]] std::size_t stash_size() const noexcept { return stash_size_; }
  [[nodiscard]] std::size_t queued_size() const noexcept {
    return ring_size_ + stash_size_;
  }
  [[nodiscard]] std::size_t ring_return_count() const noexcept {
    return ring_return_count_;
  }
  [[nodiscard]] std::size_t isr_tx_event_count() const noexcept {
    return isr_tx_event_count_;
  }
  [[nodiscard]] std::size_t interrupt_rearm_count() const noexcept {
    return interrupt_rearm_count_;
  }
  [[nodiscard]] std::size_t host_size() const noexcept { return host_size_; }
  [[nodiscard]] const std::array<std::uint8_t, kEndpointCapacity>& host_bytes()
      const noexcept {
    return host_bytes_;
  }
  [[nodiscard]] std::size_t completion_events() const noexcept {
    return completion_events_;
  }
  [[nodiscard]] std::uint32_t publish_generation() const noexcept {
    return publish_generation_;
  }
  [[nodiscard]] std::uint32_t pickup_generation() const noexcept {
    return pickup_generation_;
  }
  [[nodiscard]] bool payload_in_flight() const noexcept {
    return payload_in_flight_;
  }
  [[nodiscard]] bool quarantined() const noexcept { return quarantined_; }
  [[nodiscard]] std::uint32_t loss_epoch() const noexcept {
    return loss_epoch_;
  }

 private:
  PayloadLoadResult load_next_payload_chunk(
      std::size_t fifo_accept_limit) noexcept {
    fifo_size_ = 0U;
    if (stash_size_ != 0U) {
      const std::size_t chunk = std::min(stash_size_, kPayloadChunk);
      const std::size_t accepted = std::min(chunk, fifo_accept_limit);
      if (accepted == 0U) {
        return PayloadLoadResult::Retry;
      }
      std::copy_n(stash_.begin(), accepted, fifo_.begin());
      std::move(stash_.begin() + static_cast<std::ptrdiff_t>(accepted),
                stash_.begin() + static_cast<std::ptrdiff_t>(stash_size_),
                stash_.begin());
      stash_size_ -= accepted;
      fifo_size_ = accepted;
      return PayloadLoadResult::Published;
    }
    if (ring_size_ == 0U) {
      return PayloadLoadResult::Empty;
    }
    const std::size_t chunk = std::min(ring_size_, kPayloadChunk);
    const std::size_t accepted = std::min(chunk, fifo_accept_limit);
    if (accepted != 0U) {
      std::copy_n(ring_.begin(), accepted, fifo_.begin());
    }
    if (accepted < chunk) {
      std::copy(ring_.begin() + static_cast<std::ptrdiff_t>(accepted),
                ring_.begin() + static_cast<std::ptrdiff_t>(chunk),
                stash_.begin());
      stash_size_ = chunk - accepted;
    }
    std::move(ring_.begin() + static_cast<std::ptrdiff_t>(chunk),
              ring_.begin() + static_cast<std::ptrdiff_t>(ring_size_),
              ring_.begin());
    ring_size_ -= chunk;
    ++ring_return_count_;
    if (accepted == 0U) {
      return PayloadLoadResult::Retry;
    }
    fifo_size_ = accepted;
    return PayloadLoadResult::Published;
  }

  void service_legacy_isr() noexcept {
    if (ring_size_ != 0U) {
      const std::size_t chunk = std::min(ring_size_, kPayloadChunk);
      std::copy_n(ring_.begin(), chunk, fifo_.begin());
      fifo_size_ = chunk;
      std::move(ring_.begin() + static_cast<std::ptrdiff_t>(chunk),
                ring_.begin() + static_cast<std::ptrdiff_t>(ring_size_),
                ring_.begin());
      ring_size_ -= chunk;
      issue_wr_done();
      ++completion_events_;
      return;
    }
    issue_wr_done();
    interrupt_enabled_ = false;
  }

  void issue_wr_done() noexcept {
    last_published_packet_size_ = fifo_size_;
    std::copy_n(fifo_.begin(), fifo_size_, pending_packet_.begin());
    pending_packet_size_ = fifo_size_;
    fifo_size_ = 0U;
    in_transaction_pending_ = true;
  }

  void quarantine_and_advance_loss() noexcept {
    ring_size_ = 0U;
    stash_size_ = 0U;
    fifo_size_ = 0U;
    pending_packet_size_ = 0U;
    in_transaction_pending_ = false;
    in_empty_interrupt_pending_ = false;
    interrupt_enabled_ = false;
    direct_prime_uncommitted_ = false;
    payload_in_flight_ = false;
    quarantined_ = true;
    ++loss_epoch_;
  }

  BootstrapScheme scheme_;
  std::array<std::uint8_t, kBootstrapSize> ring_{};
  std::array<std::uint8_t, kPayloadChunk> stash_{};
  std::array<std::uint8_t, kEndpointCapacity> fifo_{};
  std::array<std::uint8_t, kEndpointCapacity> pending_packet_{};
  std::array<std::uint8_t, kEndpointCapacity> host_bytes_{};
  std::size_t ring_size_{0U};
  std::size_t stash_size_{0U};
  std::size_t fifo_size_{0U};
  std::size_t pending_packet_size_{0U};
  std::size_t last_published_packet_size_{0U};
  std::size_t host_size_{0U};
  std::size_t completion_events_{0U};
  std::size_t ring_return_count_{0U};
  std::size_t isr_tx_event_count_{0U};
  std::size_t interrupt_rearm_count_{0U};
  std::uint32_t loss_epoch_{0U};
  std::uint32_t publish_generation_{0U};
  std::uint32_t pickup_generation_{0U};
  bool in_transaction_pending_{false};
  bool in_empty_interrupt_pending_{false};
  bool interrupt_enabled_{false};
  bool direct_prime_uncommitted_{false};
  bool payload_in_flight_{false};
  bool quarantined_{false};
};

// Focused model for reset races at the ISR's IN_EMPTY and post-write
// linearization boundaries. It intentionally models only the facts which
// decide whether a payload pickup is committed and whether reset quarantine
// must remain sticky after the software queue is discarded.
class IsrResetRaceModel final {
 public:
  void stage_payload(std::size_t bytes) noexcept {
    queued_bytes_ = bytes;
    payload_in_flight_ = true;
    publish_generation_ = 1U;
  }

  void service_in_empty(std::size_t fifo_accept_limit,
                        bool reset_before_pickup,
                        bool reset_after_fifo_write) noexcept {
    if (!payload_in_flight_) {
      return;
    }

    ++raw_in_empty_count_;
    if (reset_before_pickup) {
      ++bus_reset_count_;
      discard_for_reset(false);
      return;
    }

    ++payload_in_empty_count_;
    pickup_generation_ = publish_generation_;
    payload_in_flight_ = false;

    const std::size_t selected = std::min(queued_bytes_, kPayloadChunk);
    const std::size_t sent = std::min(selected, fifo_accept_limit);
    if (selected != 0U) {
      ++ring_return_count_;
    }

    if (reset_after_fifo_write) {
      const bool fifo_written_after_reset = sent > 0U;
      if (fifo_written_after_reset) {
        ++fifo_written_after_reset_count_;
      }
      ++bus_reset_count_;
      discard_for_reset(fifo_written_after_reset);
      return;
    }

    queued_bytes_ -= sent;
  }

  [[nodiscard]] std::uint32_t loss_epoch() const noexcept {
    return loss_epoch_;
  }
  [[nodiscard]] std::size_t discarded_bytes() const noexcept {
    return discarded_bytes_;
  }
  [[nodiscard]] std::size_t ring_return_count() const noexcept {
    return ring_return_count_;
  }
  [[nodiscard]] std::size_t fifo_written_after_reset_count() const noexcept {
    return fifo_written_after_reset_count_;
  }
  [[nodiscard]] std::size_t raw_in_empty_count() const noexcept {
    return raw_in_empty_count_;
  }
  [[nodiscard]] std::size_t payload_in_empty_count() const noexcept {
    return payload_in_empty_count_;
  }
  [[nodiscard]] std::size_t bus_reset_count() const noexcept {
    return bus_reset_count_;
  }
  [[nodiscard]] std::uint32_t pickup_generation() const noexcept {
    return pickup_generation_;
  }
  [[nodiscard]] bool quarantined() const noexcept { return quarantined_; }

 private:
  void discard_for_reset(bool fifo_written_after_reset) noexcept {
    discarded_bytes_ += queued_bytes_;
    queued_bytes_ = 0U;
    payload_in_flight_ = false;
    quarantined_ = fifo_written_after_reset;
    ++loss_epoch_;
  }

  std::size_t queued_bytes_{0U};
  std::size_t discarded_bytes_{0U};
  std::size_t ring_return_count_{0U};
  std::size_t fifo_written_after_reset_count_{0U};
  std::size_t raw_in_empty_count_{0U};
  std::size_t payload_in_empty_count_{0U};
  std::size_t bus_reset_count_{0U};
  std::uint32_t loss_epoch_{0U};
  std::uint32_t publish_generation_{0U};
  std::uint32_t pickup_generation_{0U};
  bool payload_in_flight_{false};
  bool quarantined_{false};
};

BootstrapFrame make_frame() noexcept {
  BootstrapFrame frame{};
  for (std::size_t i = 0U; i < frame.size(); ++i) {
    frame[i] = static_cast<std::uint8_t>(0x40U + i);
  }
  return frame;
}

bool host_matches(const HwcdcLlSimulator& sim,
                  const BootstrapFrame& expected) noexcept {
  return sim.host_size() == expected.size() &&
         std::equal(expected.begin(), expected.end(), sim.host_bytes().begin());
}

void test_legacy_empty_zlp_requires_host_kick(TestReport& report) {
  const BootstrapFrame frame = make_frame();
  HwcdcLlSimulator sim(BootstrapScheme::EmptyZlpKick);
  report.check(sim.stage_legacy(frame), "legacy frame could not be staged");
  report.check(sim.ring_size() == frame.size(),
               "legacy stage did not retain all 63 bytes in the ring");
  report.check(sim.in_transaction_pending() &&
                   sim.pending_packet_size() == 0U,
               "legacy cold start did not expose the empty-ZLP kick");
  sim.service_isr();
  report.check(sim.ring_size() == frame.size() && sim.host_size() == 0U,
               "legacy payload advanced without the first host poll");
  report.check(sim.host_poll() && sim.host_size() == 0U,
               "legacy first host poll was not the empty kick");
  sim.service_isr();
  report.check(sim.in_transaction_pending() &&
                   sim.pending_packet_size() == kPayloadChunk,
               "legacy ISR did not split payload after the empty kick");
}

void test_direct_payload_publishes_only_at_wr_done(TestReport& report) {
  const BootstrapFrame frame = make_frame();
  HwcdcLlSimulator sim(BootstrapScheme::DirectPrime);
  report.check(sim.begin_direct_prime(frame, kEndpointCapacity),
               "direct prime rejected the first 32-byte FIFO write");
  report.check(!sim.in_transaction_pending() && !sim.payload_in_flight(),
               "FIFO bytes became host-visible before wr_done");
  report.check(!sim.host_poll() && sim.host_size() == 0U,
               "host consumed uncommitted FIFO bytes");
  report.check(sim.commit_direct_prime(),
               "wr_done rejected a complete direct-prime frame");
  report.check(sim.in_transaction_pending() &&
                   sim.pending_packet_size() == kPayloadChunk &&
                   sim.ring_size() == kBootstrapSize - kPayloadChunk,
               "wr_done did not publish only the first 32-byte packet");
  report.check(sim.publish_generation() == 1U &&
                   sim.pickup_generation() == 0U &&
                   sim.payload_in_flight() && !sim.flush_complete(),
               "publication was reported complete before host pickup");
}

void test_zero_direct_write_never_publishes(TestReport& report) {
  const BootstrapFrame frame = make_frame();
  HwcdcLlSimulator sim(BootstrapScheme::DirectPrime);
  report.check(!sim.stage_direct(frame, 0U),
               "zero FIFO write was accepted as a bootstrap");
  report.check(!sim.in_transaction_pending() && !sim.host_poll() &&
                   sim.host_size() == 0U,
               "zero FIFO write published a prefix");
  report.check(sim.quarantined() && sim.loss_epoch() == 1U,
               "zero FIFO write did not quarantine and advance loss");
}

void test_zero_isr_fifo_write_retries_without_publication(TestReport& report) {
  const BootstrapFrame frame = make_frame();
  HwcdcLlSimulator sim(BootstrapScheme::DirectPrime);
  report.check(sim.stage_direct(frame),
               "zero-ISR-write fixture could not publish first packet");
  report.check(sim.host_poll(),
               "zero-ISR-write fixture did not pick up first packet");

  sim.service_isr(0U);
  report.check(sim.ring_size() == 0U &&
                   sim.stash_size() == kBootstrapSize - kPayloadChunk &&
                   sim.queued_size() == kBootstrapSize - kPayloadChunk &&
                   sim.ring_return_count() == 1U,
               "zero ISR FIFO write did not retain and return the full ring item");
  report.check(sim.publish_generation() == 1U &&
                   sim.pickup_generation() == 1U &&
                   !sim.payload_in_flight() &&
                   !sim.in_transaction_pending(),
               "zero ISR FIFO write published a payload generation or WR_DONE");
  report.check(sim.isr_tx_event_count() == 0U &&
                   sim.interrupt_rearm_count() == 1U,
               "zero ISR FIFO write claimed TX progress or failed to re-arm retry");

  sim.service_isr(kPayloadChunk);
  report.check(sim.queued_size() == 0U &&
                   sim.publish_generation() == 2U &&
                   sim.payload_in_flight() &&
                   sim.in_transaction_pending() &&
                   sim.pending_packet_size() ==
                       kBootstrapSize - kPayloadChunk,
               "positive retry did not publish the retained payload exactly once");
  report.check(sim.isr_tx_event_count() == 1U &&
                   sim.interrupt_rearm_count() == 2U,
               "positive retry did not report exactly one ISR TX event/re-arm");
  report.check(sim.host_poll(),
               "host did not pick up the payload retained across zero write");
  sim.service_isr();
  report.check(host_matches(sim, frame) && sim.flush_complete() &&
                   sim.completion_events() == 1U,
               "zero-write retry did not preserve the exact 63-byte frame");
}

void test_postwrite_reset_quarantines_only_positive_fifo_write(
    TestReport& report) {
  IsrResetRaceModel zero_write;
  zero_write.stage_payload(kPayloadChunk);
  zero_write.service_in_empty(/*fifo_accept_limit=*/0U,
                              /*reset_before_pickup=*/false,
                              /*reset_after_fifo_write=*/true);
  report.check(zero_write.loss_epoch() == 1U &&
                   zero_write.discarded_bytes() == kPayloadChunk &&
                   zero_write.ring_return_count() == 1U,
               "zero-write reset did not purge/release/advance the epoch");
  report.check(!zero_write.quarantined() &&
                   zero_write.fifo_written_after_reset_count() == 0U,
               "zero-write reset incorrectly retained sticky FIFO quarantine");

  IsrResetRaceModel positive_write;
  positive_write.stage_payload(kPayloadChunk);
  positive_write.service_in_empty(/*fifo_accept_limit=*/7U,
                                  /*reset_before_pickup=*/false,
                                  /*reset_after_fifo_write=*/true);
  report.check(positive_write.loss_epoch() == 1U &&
                   positive_write.discarded_bytes() == kPayloadChunk &&
                   positive_write.ring_return_count() == 1U,
               "positive-write reset did not purge/release/advance the epoch");
  report.check(positive_write.quarantined() &&
                   positive_write.fifo_written_after_reset_count() == 1U,
               "positive FIFO write followed by reset lost sticky quarantine");
}

void test_reset_at_pickup_boundary_is_raw_only(TestReport& report) {
  IsrResetRaceModel sim;
  sim.stage_payload(kPayloadChunk);
  sim.service_in_empty(/*fifo_accept_limit=*/kPayloadChunk,
                       /*reset_before_pickup=*/true,
                       /*reset_after_fifo_write=*/false);
  report.check(sim.raw_in_empty_count() == 1U &&
                   sim.payload_in_empty_count() == 0U &&
                   sim.pickup_generation() == 0U,
               "pickup-boundary reset committed a payload IN_EMPTY witness");
  report.check(sim.bus_reset_count() == 1U && sim.loss_epoch() == 1U &&
                   sim.discarded_bytes() == kPayloadChunk &&
                   !sim.quarantined(),
               "pickup-boundary reset did not take clean raw-only discard");
}

void test_reset_before_wr_done_never_publishes(TestReport& report) {
  const BootstrapFrame frame = make_frame();
  HwcdcLlSimulator sim(BootstrapScheme::DirectPrime);
  report.check(sim.begin_direct_prime(frame, kEndpointCapacity),
               "reset fixture could not prime the first packet");
  sim.bus_reset();
  report.check(!sim.commit_direct_prime(),
               "wr_done succeeded after a pre-publication reset");
  report.check(!sim.in_transaction_pending() && !sim.host_poll() &&
                   sim.host_size() == 0U,
               "pre-wr_done reset exposed stale payload");
  report.check(sim.quarantined() && sim.loss_epoch() == 1U,
               "pre-wr_done reset did not quarantine and advance loss");
}

void test_stale_in_empty_cannot_consume_generation(TestReport& report) {
  const BootstrapFrame frame = make_frame();
  HwcdcLlSimulator sim(BootstrapScheme::DirectPrime);
  sim.seed_stale_in_empty();
  report.check(sim.stage_direct(frame),
               "stale-event fixture could not publish first packet");
  sim.service_isr();
  report.check(sim.in_transaction_pending() &&
                   sim.pending_packet_size() == kPayloadChunk &&
                   sim.ring_size() == kBootstrapSize - kPayloadChunk,
               "stale IN_EMPTY drained the ring suffix before host pickup");
  report.check(sim.publish_generation() == 1U &&
                   sim.pickup_generation() == 0U &&
                   sim.payload_in_flight() && !sim.flush_complete(),
               "stale IN_EMPTY consumed the first payload generation");
}

void test_no_host_poll_remains_pending(TestReport& report) {
  const BootstrapFrame frame = make_frame();
  HwcdcLlSimulator sim(BootstrapScheme::DirectPrime);
  report.check(sim.stage_direct(frame),
               "no-host fixture could not publish the first packet");
  sim.service_isr();
  report.check(sim.in_transaction_pending() && sim.host_size() == 0U,
               "no-host transaction did not remain pending");
  report.check(sim.completion_events() == 0U && !sim.flush_complete(),
               "completion was reported without a host poll");
}

void test_two_pickups_yield_exact_frame_and_final_generation(
    TestReport& report) {
  const BootstrapFrame frame = make_frame();
  HwcdcLlSimulator sim(BootstrapScheme::DirectPrime);
  report.check(sim.stage_direct(frame),
               "two-pickup fixture could not publish first packet");
  report.check(sim.host_poll(), "host did not pick up first 32-byte packet");
  sim.service_isr();
  report.check(sim.host_size() == kPayloadChunk &&
                   sim.in_transaction_pending() &&
                   sim.pending_packet_size() == kBootstrapSize - kPayloadChunk,
               "first pickup did not publish the final 31-byte packet");
  report.check(sim.publish_generation() == 2U &&
                   sim.pickup_generation() == 1U &&
                   sim.payload_in_flight() && !sim.flush_complete(),
               "first pickup incorrectly completed the whole frame");

  report.check(sim.host_poll(), "host did not pick up final 31-byte packet");
  sim.service_isr();
  report.check(host_matches(sim, frame),
               "host did not receive exact 32+31 byte frame");
  report.check(sim.publish_generation() == 2U &&
                   sim.pickup_generation() == 2U &&
                   !sim.payload_in_flight() && sim.flush_complete(),
               "final pickup did not close the matching generation");
  report.check(sim.completion_events() == 1U,
               "exact frame did not produce one completion event");
  report.check(!sim.in_transaction_pending() && !sim.host_poll(),
               "short final packet generated an unnecessary ZLP");
}

void test_r19_32_plus_31_short_packet_completes_without_terminal_zlp(
    TestReport& report) {
  const BootstrapFrame frame = make_frame();
  HwcdcLlSimulator sim(BootstrapScheme::DirectPrime);
  report.check(sim.stage_direct(frame),
               "R19 short-packet fixture could not publish the first chunk");
  report.check(sim.host_poll(),
               "R19 short-packet fixture did not pick up the 32-byte chunk");
  sim.service_isr();
  report.check(sim.last_published_packet_size() == 31U,
               "R19 32+31 fixture did not end with a short USB packet");
  report.check(sim.host_poll(),
               "R19 short-packet fixture did not pick up the 31-byte tail");
  sim.service_isr();
  report.check(sim.flush_complete() && host_matches(sim, frame),
               "R19 32+31 fixture did not reach an exact payload boundary");

  FlushCompletionLoopModel completion(
      FlushTailPolicy::DiagnosticPredicateOwnedOnly,
      CandidateFeatureMode::R19MacroOn, FinalPacketClass::ShortPacket);
  completion.service_iteration(false);
  report.check(completion.complete(),
               "R19 short packet did not complete at matching payload pickup");
  report.check(completion.terminal_zlp_count() == 0U,
               "R19 short packet emitted a forbidden terminal ZLP");
}

void test_r19_full_and_unknown_packets_cannot_short_circuit(
    TestReport& report) {
  const std::array<FinalPacketClass, 2U> non_short_classes{
      FinalPacketClass::FullEndpointPacket, FinalPacketClass::Unknown};
  for (const FinalPacketClass packet_class : non_short_classes) {
    FlushCompletionLoopModel completion(
        FlushTailPolicy::DiagnosticPredicateOwnedOnly,
        CandidateFeatureMode::R19MacroOn, packet_class);
    completion.service_iteration(false);
    report.check(!completion.complete() &&
                     completion.terminal_zlp_count() == 1U &&
                     !completion.fifo_writable(),
                 "R19 full/unknown packet bypassed terminal-ZLP pickup");
    completion.host_pickup_between_calls();
    completion.service_iteration(false);
    report.check(completion.complete() &&
                     completion.terminal_zlp_count() == 1U,
                 "R19 full/unknown packet did not complete after one ZLP pickup");
  }
}

void test_r19_short_packet_rejects_invalid_completion_evidence(
    TestReport& report) {
  FlushCompletionLoopModel generation_mismatch(
      FlushTailPolicy::DiagnosticPredicateOwnedOnly,
      CandidateFeatureMode::R19MacroOn, FinalPacketClass::ShortPacket);
  generation_mismatch.set_generations(2U, 1U);
  generation_mismatch.service_iteration(false);
  report.check(!generation_mismatch.complete() &&
                   generation_mismatch.terminal_zlp_count() == 0U,
               "generation mismatch completed or emitted a terminal ZLP");

  FlushCompletionLoopModel epoch_mismatch(
      FlushTailPolicy::DiagnosticPredicateOwnedOnly,
      CandidateFeatureMode::R19MacroOn, FinalPacketClass::ShortPacket);
  epoch_mismatch.set_loss_epochs(7U, 8U);
  epoch_mismatch.service_iteration(false);
  report.check(!epoch_mismatch.complete() &&
                   epoch_mismatch.terminal_zlp_count() == 0U,
               "loss-epoch mismatch completed or emitted a terminal ZLP");

  FlushCompletionLoopModel reset_observed(
      FlushTailPolicy::DiagnosticPredicateOwnedOnly,
      CandidateFeatureMode::R19MacroOn, FinalPacketClass::ShortPacket);
  reset_observed.observe_bus_reset();
  reset_observed.service_iteration(false);
  report.check(!reset_observed.complete() &&
                   reset_observed.terminal_zlp_count() == 0U,
               "BUS_RESET evidence completed or emitted a terminal ZLP");
}

void test_macro_off_short_packet_preserves_r18_terminal_zlp_contract(
    TestReport& report) {
  FlushCompletionLoopModel r18(
      FlushTailPolicy::DiagnosticPredicateOwnedOnly,
      CandidateFeatureMode::R18MacroOff, FinalPacketClass::ShortPacket);
  r18.service_iteration(false);
  report.check(!r18.complete() && r18.terminal_zlp_count() == 1U &&
                   !r18.fifo_writable(),
               "macro-off/R18 path adopted R19 short-packet completion");
  r18.host_pickup_between_calls();
  r18.service_iteration(false);
  report.check(r18.complete() && r18.terminal_zlp_count() == 1U,
               "macro-off/R18 terminal-ZLP behavior changed");
}

void test_pickup_between_wr_done_and_irq_enable_is_latched(
    TestReport& report) {
  const BootstrapFrame frame = make_frame();
  HwcdcLlSimulator sim(BootstrapScheme::DirectPrime);
  report.check(sim.stage_direct(frame, kEndpointCapacity, true),
               "wr_done-to-enable pickup fixture failed");
  report.check(sim.host_size() == kPayloadChunk &&
                   sim.pickup_generation() == 0U,
               "masked pickup was consumed before ISR enable");
  sim.service_isr();
  report.check(sim.in_transaction_pending() &&
                   sim.pending_packet_size() == kBootstrapSize - kPayloadChunk,
               "latched pickup did not publish the final packet");
  report.check(sim.host_poll(), "host did not pick up latched-path suffix");
  sim.service_isr();
  report.check(host_matches(sim, frame) && sim.flush_complete(),
               "wr_done-to-enable pickup lost or duplicated payload");
}

void test_final_zlp_is_not_reissued_before_next_completion_sample(
    TestReport& report) {
  FlushCompletionLoopModel unguarded(
      FlushTailPolicy::UnconditionalReflush);
  unguarded.service_iteration(false);
  unguarded.service_iteration(true);
  report.check(!unguarded.complete() &&
                   unguarded.terminal_zlp_count() == 2U,
               "fixture no longer reproduces final-ZLP tail reissue");

  FlushCompletionLoopModel guarded(
      FlushTailPolicy::DiagnosticPredicateOwnedOnly);
  guarded.service_iteration(false);
  guarded.service_iteration(true);
  report.check(!guarded.complete() && guarded.fifo_writable() &&
                   guarded.terminal_zlp_count() == 1U,
               "final ZLP was reissued after pickup at the loop tail");
  report.check(guarded.interrupt_rearm_count() == 2U,
               "suppressing the repeated ZLP also suppressed TX interrupt rearm");

  guarded.service_iteration(false);
  report.check(guarded.complete(),
               "next iteration did not complete after final-ZLP pickup");
  report.check(guarded.terminal_zlp_count() <= 1U,
               "one flush attempt emitted more than one terminal ZLP");
}

void test_software_pending_cannot_trigger_diagnostic_maintenance_zlp(
    TestReport& report) {
  FlushCompletionLoopModel guarded(
      FlushTailPolicy::DiagnosticPredicateOwnedOnly);
  guarded.set_software_pending(true);
  guarded.service_iteration(false);
  report.check(guarded.terminal_zlp_count() == 0U &&
                   guarded.fifo_writable() &&
                   guarded.interrupt_rearm_count() == 1U,
               "software-pending iteration emitted a premature task ZLP");

  guarded.set_software_pending(false);
  guarded.service_iteration(false);
  report.check(guarded.terminal_zlp_count() == 1U &&
                   !guarded.fifo_writable(),
               "terminal predicate did not own the one required ZLP");
  guarded.service_iteration(true);
  guarded.service_iteration(false);
  report.check(guarded.complete() &&
                   guarded.terminal_zlp_count() == 1U,
               "predicate-owned ZLP did not converge exactly once");
}

void test_terminal_zlp_ownership_survives_flush_reentry(
    TestReport& report) {
  FlushCompletionLoopModel guarded(
      FlushTailPolicy::DiagnosticPredicateOwnedOnly);
  guarded.service_iteration(false);
  report.check(!guarded.complete() &&
                   guarded.terminal_zlp_count() == 1U,
               "first bounded flush did not issue exactly one terminal ZLP");

  // The first call times out while that ZLP is pending. The host picks it up
  // between calls, then the same logical flush is retried.
  guarded.host_pickup_between_calls();
  guarded.restart_flush_call();
  guarded.service_iteration(false);
  report.check(guarded.complete() &&
                   guarded.terminal_zlp_count() == 1U,
               "flush re-entry reissued the same generation's terminal ZLP");
}

void test_stale_snapshot_cannot_ack_new_terminal_zlp(TestReport& report) {
  FlushCompletionLoopModel guarded(
      FlushTailPolicy::DiagnosticPredicateOwnedOnly);
  guarded.service_iteration(false);
  guarded.service_stale_entry_snapshot_without_live_event();
  guarded.restart_flush_call();
  guarded.service_iteration(false);
  report.check(!guarded.complete() && !guarded.fifo_writable() &&
                   guarded.terminal_zlp_count() == 1U,
               "stale ISR snapshot acknowledged or republished terminal ZLP");

  guarded.host_pickup_between_calls();
  guarded.restart_flush_call();
  guarded.service_iteration(false);
  report.check(guarded.complete() &&
                   guarded.terminal_zlp_count() == 1U,
               "fresh terminal pickup did not complete after stale snapshot");
}

void test_new_payload_invalidates_terminal_zlp_ownership(
    TestReport& report) {
  FlushCompletionLoopModel guarded(
      FlushTailPolicy::DiagnosticPredicateOwnedOnly);
  guarded.service_iteration(false);
  guarded.host_pickup_between_calls();
  guarded.invalidate_terminal_for_new_payload();
  guarded.restart_flush_call();
  guarded.service_iteration(false);
  report.check(!guarded.complete() &&
                   guarded.terminal_zlp_count() == 2U,
               "new payload boundary reused the prior terminal-ZLP pickup");
}

}  // namespace

int main() {
  TestReport report{};
  test_legacy_empty_zlp_requires_host_kick(report);
  test_direct_payload_publishes_only_at_wr_done(report);
  test_zero_direct_write_never_publishes(report);
  test_zero_isr_fifo_write_retries_without_publication(report);
  test_postwrite_reset_quarantines_only_positive_fifo_write(report);
  test_reset_at_pickup_boundary_is_raw_only(report);
  test_reset_before_wr_done_never_publishes(report);
  test_stale_in_empty_cannot_consume_generation(report);
  test_no_host_poll_remains_pending(report);
  test_two_pickups_yield_exact_frame_and_final_generation(report);
  test_r19_32_plus_31_short_packet_completes_without_terminal_zlp(report);
  test_r19_full_and_unknown_packets_cannot_short_circuit(report);
  test_r19_short_packet_rejects_invalid_completion_evidence(report);
  test_macro_off_short_packet_preserves_r18_terminal_zlp_contract(report);
  test_pickup_between_wr_done_and_irq_enable_is_latched(report);
  test_final_zlp_is_not_reissued_before_next_completion_sample(report);
  test_software_pending_cannot_trigger_diagnostic_maintenance_zlp(report);
  test_terminal_zlp_ownership_survives_flush_reentry(report);
  test_stale_snapshot_cannot_ack_new_terminal_zlp(report);
  test_new_payload_invalidates_terminal_zlp_ownership(report);

  std::cout << "UT-R19-HWCDC-LL-BOOTSTRAP-001 checks=" << report.checks
            << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
