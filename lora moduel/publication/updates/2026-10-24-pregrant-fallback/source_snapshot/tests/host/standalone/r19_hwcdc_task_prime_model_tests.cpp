#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#ifndef VC_LORA_SOURCE_ROOT
#define VC_LORA_SOURCE_ROOT "."
#endif

namespace {

constexpr std::size_t kProductChunkLimit = 32U;

struct TestReport final {
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

enum class ResetInjection : std::uint8_t {
  None,
  BeforeFifoWrite,
  AfterFifoWrite,
};

// Deterministic contract model for the checked writer's clean-idle fast path.
// It starts at the exact state observed on Ground after the 63-byte R19 frame:
// the previous frame was picked up, FIFO is writable, IN_EMPTY is disabled,
// and no new level/edge is guaranteed when a 21-byte heartbeat is enqueued.
class CheckedWriterTaskPrimeModel final {
 public:
  void set_stale_isr_snapshot() noexcept { stale_isr_snapshot_ = true; }

  std::size_t write_checked(const std::vector<std::uint8_t>& bytes,
                            std::uint32_t expected_loss_epoch,
                            std::size_t fifo_accept_limit,
                            ResetInjection reset = ResetInjection::None) {
    if (bytes.empty() || bytes.size() > kProductChunkLimit || quarantined_ ||
        expected_loss_epoch != loss_epoch_ || !fifo_writable_ ||
        payload_in_flight_ || !ring_.empty() || !stash_.empty()) {
      return 0U;
    }

    // The task owns the same TX mux as the ISR. Mask and clear any old empty
    // indication before making the new software item visible.
    interrupt_enabled_ = false;
    live_in_empty_ = false;
    ring_ = bytes;

    if (reset == ResetInjection::BeforeFifoWrite) {
      discard_for_reset(false);
      return 0U;
    }

    ++fifo_write_attempts_;
    const std::size_t requested =
        std::min(kProductChunkLimit, ring_.size());
    const std::size_t sent = std::min(requested, fifo_accept_limit);
    raw_fifo_write_bytes_ += sent;

    if (reset == ResetInjection::AfterFifoWrite) {
      discard_for_reset(sent > 0U);
      return 0U;
    }
    if (sent == 0U) {
      // Nothing was published. The API rejects this enqueue so its caller
      // remains the sole owner of the immutable input and may retry it.
      ring_.clear();
      return 0U;
    }

    current_fifo_packet_.assign(ring_.begin(), ring_.begin() +
                                                   static_cast<std::ptrdiff_t>(sent));
    if (sent < requested) {
      stash_.assign(ring_.begin() + static_cast<std::ptrdiff_t>(sent),
                    ring_.begin() + static_cast<std::ptrdiff_t>(requested));
    }
    ring_.erase(ring_.begin(), ring_.begin() +
                                   static_cast<std::ptrdiff_t>(requested));
    publish_current_fifo_packet();
    interrupt_enabled_ = true;
    return bytes.size();
  }

  bool service_stale_isr_snapshot() noexcept {
    if (!stale_isr_snapshot_) {
      return false;
    }
    stale_isr_snapshot_ = false;
    // Production must re-sample the live status while holding the TX mux.
    // The task-side clear makes this old entry snapshot observational only.
    return live_in_empty_ ? service_live_in_empty(kProductChunkLimit) : false;
  }

  void service_bus_reset_isr() noexcept {
    const bool fifo_written_after_pending_reset =
        fifo_written_after_pending_reset_;
    fifo_written_after_pending_reset_ = false;
    quarantined_ = fifo_written_after_pending_reset;
    ++loss_epoch_;
  }

  bool host_pickup() {
    if (!payload_in_flight_ || current_fifo_packet_.empty()) {
      return false;
    }
    picked_up_.insert(picked_up_.end(), current_fifo_packet_.begin(),
                      current_fifo_packet_.end());
    current_fifo_packet_.clear();
    payload_in_flight_ = false;
    pickup_generation_ = publish_generation_;
    fifo_writable_ = true;
    live_in_empty_ = interrupt_enabled_;
    return true;
  }

  bool service_live_in_empty(std::size_t fifo_accept_limit) {
    if (!interrupt_enabled_ || !live_in_empty_) {
      return false;
    }
    live_in_empty_ = false;
    if (payload_in_flight_ || !fifo_writable_) {
      return false;
    }
    if (stash_.empty() && ring_.empty()) {
      interrupt_enabled_ = false;
      return false;
    }

    std::vector<std::uint8_t>* source =
        stash_.empty() ? &ring_ : &stash_;
    ++fifo_write_attempts_;
    const std::size_t requested =
        std::min(kProductChunkLimit, source->size());
    const std::size_t sent = std::min(requested, fifo_accept_limit);
    raw_fifo_write_bytes_ += sent;
    if (sent == 0U) {
      interrupt_enabled_ = true;
      return false;
    }
    current_fifo_packet_.assign(
        source->begin(),
        source->begin() + static_cast<std::ptrdiff_t>(sent));
    source->erase(source->begin(),
                  source->begin() + static_cast<std::ptrdiff_t>(sent));
    publish_current_fifo_packet();
    interrupt_enabled_ = true;
    return true;
  }

  bool maybe_issue_terminal_zlp() noexcept {
    // No maintenance/terminal ZLP may replace a pending data packet or be
    // injected while software bytes remain. Product chunks are short packets,
    // so this focused model never needs a terminal ZLP.
    if (!ring_.empty() || !stash_.empty() || payload_in_flight_) {
      return false;
    }
    return false;
  }

  bool complete() const noexcept {
    return ring_.empty() && stash_.empty() && !payload_in_flight_ &&
           pickup_generation_ == publish_generation_ && !quarantined_;
  }

  const std::vector<std::uint8_t>& picked_up() const noexcept {
    return picked_up_;
  }
  std::size_t ring_size() const noexcept { return ring_.size(); }
  std::size_t stash_size() const noexcept { return stash_.size(); }
  std::size_t current_fifo_size() const noexcept {
    return current_fifo_packet_.size();
  }
  std::size_t raw_fifo_write_bytes() const noexcept {
    return raw_fifo_write_bytes_;
  }
  std::uint32_t loss_epoch() const noexcept { return loss_epoch_; }
  std::uint32_t publish_generation() const noexcept {
    return publish_generation_;
  }
  std::uint32_t pickup_generation() const noexcept {
    return pickup_generation_;
  }
  std::size_t wr_done_count() const noexcept { return wr_done_count_; }
  std::size_t zlp_count() const noexcept { return zlp_count_; }
  bool quarantined() const noexcept { return quarantined_; }

 private:
  void publish_current_fifo_packet() noexcept {
    ++publish_generation_;
    ++wr_done_count_;
    payload_in_flight_ = true;
    fifo_writable_ = false;
  }

  void discard_for_reset(bool fifo_was_written) noexcept {
    quarantined_ = fifo_was_written;
    fifo_written_after_pending_reset_ = fifo_was_written;
    ring_.clear();
    stash_.clear();
    current_fifo_packet_.clear();
    payload_in_flight_ = false;
    interrupt_enabled_ = false;
    live_in_empty_ = false;
    ++loss_epoch_;
  }

  std::vector<std::uint8_t> ring_{};
  std::vector<std::uint8_t> stash_{};
  std::vector<std::uint8_t> current_fifo_packet_{};
  std::vector<std::uint8_t> picked_up_{};
  std::uint32_t loss_epoch_{1U};
  std::uint32_t publish_generation_{0U};
  std::uint32_t pickup_generation_{0U};
  std::size_t fifo_write_attempts_{0U};
  std::size_t raw_fifo_write_bytes_{0U};
  std::size_t wr_done_count_{0U};
  std::size_t zlp_count_{0U};
  bool fifo_writable_{true};
  bool payload_in_flight_{false};
  bool interrupt_enabled_{false};
  bool live_in_empty_{false};
  bool stale_isr_snapshot_{false};
  bool quarantined_{false};
  bool fifo_written_after_pending_reset_{false};
};

std::vector<std::uint8_t> sequence(std::size_t size,
                                   std::uint8_t first) {
  std::vector<std::uint8_t> bytes(size);
  for (std::size_t i = 0U; i < size; ++i) {
    bytes[i] = static_cast<std::uint8_t>(first + i);
  }
  return bytes;
}

std::string read_file(const std::string& relative_path) {
  std::ifstream input(std::string{VC_LORA_SOURCE_ROOT} + relative_path,
                      std::ios::binary);
  std::ostringstream content;
  content << input.rdbuf();
  return content.str();
}

std::string extract_function(const std::string& source,
                             const std::string& signature) {
  const std::size_t signature_offset = source.find(signature);
  if (signature_offset == std::string::npos) {
    return {};
  }
  const std::size_t body_offset = source.find('{', signature_offset);
  if (body_offset == std::string::npos) {
    return {};
  }

  std::size_t depth = 0U;
  for (std::size_t offset = body_offset; offset < source.size(); ++offset) {
    if (source[offset] == '{') {
      ++depth;
    } else if (source[offset] == '}') {
      if (--depth == 0U) {
        return source.substr(signature_offset,
                             offset - signature_offset + 1U);
      }
    }
  }
  return {};
}

bool ordered(const std::string& text, const std::string& first,
             const std::string& second) {
  const std::size_t first_offset = text.find(first);
  const std::size_t second_offset =
      first_offset == std::string::npos
          ? std::string::npos
          : text.find(second, first_offset + first.size());
  return first_offset != std::string::npos &&
         second_offset != std::string::npos && first_offset < second_offset;
}

enum class BusyPickupInjection : std::uint8_t {
  BeforeEnqueue,
  AfterEnqueue,
  AfterPostEnqueueCheck,
};

enum class BusyRestartFault : std::uint8_t {
  None,
  EpochMismatch,
  ResetPending,
  Quarantined,
  StashPending,
  OlderRingPending,
  FifoNotWritable,
  PayloadStillInFlight,
  BootstrapFence,
  BootstrapAborted,
  DebugWriterActive,
};

// Unlike the historical clean-idle model, this model accepts a software
// enqueue while the prior FIFO packet is in flight, exactly as the checked
// writer does. Host pickup raises an IRQ; only its ISR retires the generation.
// An empty ISR can clear/mask the last event before the next enqueue becomes
// visible. Re-enabling that IRQ does not synthesize a new hardware event.
class BusyIdleCheckedWriterModel final {
 public:
  explicit BusyIdleCheckedWriterModel(bool post_enqueue_restart) noexcept
      : post_enqueue_restart_{post_enqueue_restart} {}

  void prime_previous(const std::vector<std::uint8_t>& bytes) {
    fifo_ = bytes;
    in_flight_ = true;
    fifo_writable_ = false;
    irq_enabled_ = true;
    ++published_;
    ++fifo_writes_;
  }

  std::size_t enqueue_next(const std::vector<std::uint8_t>& bytes,
                           BusyPickupInjection injection,
                           BusyRestartFault fault = BusyRestartFault::None) {
    const bool reserved_at_entry = !in_flight_ && fifo_writable_ &&
        ring_.empty() && picked_up_generation_ == published_;
    if (injection == BusyPickupInjection::BeforeEnqueue) {
      host_pickup();
      service_isr();
    }
    ring_.insert(ring_.end(), bytes.begin(), bytes.end());
    if (injection == BusyPickupInjection::AfterEnqueue) {
      host_pickup();
      service_isr();
    }
    if (fault == BusyRestartFault::EpochMismatch ||
        fault == BusyRestartFault::ResetPending ||
        fault == BusyRestartFault::Quarantined) {
      // Mirrors the existing post-enqueue epoch/reset rejection, not a new
      // recovery escape. No accepted software bytes may survive this return.
      ring_.clear();
      irq_enabled_ = false;
      raw_in_empty_ = false;
      return 0U;
    }
    if (fault == BusyRestartFault::OlderRingPending) {
      ring_.insert(ring_.begin(), 0x5AU);
    }
    if (fault == BusyRestartFault::FifoNotWritable) {
      fifo_writable_ = false;
    }
    if (fault == BusyRestartFault::PayloadStillInFlight) {
      in_flight_ = true;
    }
    const bool reserve_after_enqueue = post_enqueue_restart_ &&
        !reserved_at_entry && ring_.size() == bytes.size() &&
        !in_flight_ && fifo_writable_ && picked_up_generation_ == published_ &&
        fault != BusyRestartFault::StashPending &&
        fault != BusyRestartFault::BootstrapFence &&
        fault != BusyRestartFault::BootstrapAborted &&
        fault != BusyRestartFault::DebugWriterActive;
    if (reserved_at_entry || reserve_after_enqueue) {
      irq_enabled_ = false;
      raw_in_empty_ = false;
      publish_ring();
    }
    irq_enabled_ = true;
    if (injection == BusyPickupInjection::AfterPostEnqueueCheck) {
      host_pickup();
      service_isr();
    }
    return bytes.size();
  }

  void host_pickup() {
    if (!in_flight_ || fifo_.empty()) {
      return;
    }
    received_.insert(received_.end(), fifo_.begin(), fifo_.end());
    fifo_.clear();
    fifo_writable_ = true;
    raw_in_empty_ = true;
  }

  bool service_isr() {
    if (!irq_enabled_ || !raw_in_empty_) {
      return false;
    }
    raw_in_empty_ = false;
    picked_up_generation_ = published_;
    in_flight_ = false;
    if (ring_.empty()) {
      irq_enabled_ = false;
      return false;
    }
    publish_ring();
    return true;
  }

  void service_stale_second_phase(bool resamples_payload_in_flight) {
    // The old ISR already retired the previous packet in its first TX-mux
    // section, then waited outside the lock while this task published a new
    // packet. Its second section must not disable the fresh packet's IRQ.
    if (resamples_payload_in_flight && in_flight_) {
      return;
    }
    if (ring_.empty()) {
      irq_enabled_ = false;
    } else {
      publish_ring();
    }
  }

  void service_stale_cleanup(bool resamples_payload_in_flight,
                             bool disable_irq) {
    if (resamples_payload_in_flight && in_flight_) {
      return;
    }
    raw_in_empty_ = false;
    if (disable_irq) {
      irq_enabled_ = false;
    }
  }

  bool completed() const noexcept {
    return ring_.empty() && fifo_.empty() && !in_flight_ &&
        published_ == picked_up_generation_;
  }
  bool lost_wake() const noexcept {
    return ring_.size() == 31U && fifo_writable_ && !in_flight_ &&
        published_ == picked_up_generation_ && !raw_in_empty_;
  }
  std::size_t fifo_size() const noexcept { return fifo_.size(); }
  std::size_t fifo_writes() const noexcept { return fifo_writes_; }
  std::size_t ring_size() const noexcept { return ring_.size(); }
  const std::vector<std::uint8_t>& received() const noexcept {
    return received_;
  }

 private:
  void publish_ring() {
    const std::size_t count = std::min(kProductChunkLimit, ring_.size());
    fifo_.assign(ring_.begin(), ring_.begin() +
        static_cast<std::ptrdiff_t>(count));
    ring_.erase(ring_.begin(), ring_.begin() +
        static_cast<std::ptrdiff_t>(count));
    in_flight_ = true;
    fifo_writable_ = false;
    ++published_;
    ++fifo_writes_;
  }

  bool post_enqueue_restart_{false};
  bool in_flight_{false};
  bool fifo_writable_{true};
  bool irq_enabled_{false};
  bool raw_in_empty_{false};
  std::uint32_t published_{0U};
  std::uint32_t picked_up_generation_{0U};
  std::size_t fifo_writes_{0U};
  std::vector<std::uint8_t> ring_{};
  std::vector<std::uint8_t> fifo_{};
  std::vector<std::uint8_t> received_{};
};

bool production_has_post_enqueue_restart() {
  const std::string writer = extract_function(read_file(
      "/third_party/esp32-core-3.3.11-vc-lora/cores/esp32/HWCDC.cpp"),
      "size_t HWCDC::writeTxChecked(");
  const std::size_t send = writer.find("xRingbufferSend(");
  const std::size_t predicate = writer.find(
      "const bool post_enqueue_idle_boundary", send);
  if (send == std::string::npos || predicate == std::string::npos) {
    return false;
  }
  const std::size_t branch = writer.find("if (post_enqueue_idle_boundary)",
                                         predicate);
  const std::size_t prime = writer.find("} else if (task_prime_reserved)",
                                        predicate);
  const std::string recovery = branch == std::string::npos ||
          prime == std::string::npos || branch >= prime
      ? std::string{} : writer.substr(branch, prime - branch);
  return ordered(recovery, "tx_bootstrap_enqueue_fence = true",
                 "usb_serial_jtag_ll_disable_intr_mask(") &&
      ordered(recovery, "usb_serial_jtag_ll_disable_intr_mask(",
              "usb_serial_jtag_ll_clr_intsts_mask(") &&
      ordered(recovery, "usb_serial_jtag_ll_clr_intsts_mask(",
              "task_prime_reserved = true");
}

bool production_rechecks_publication_in_second_isr_phase() {
  const std::string isr = extract_function(read_file(
      "/third_party/esp32-core-3.3.11-vc-lora/cores/esp32/HWCDC.cpp"),
      "static void hw_cdc_isr_handler(");
  const std::size_t first = isr.find("portEXIT_CRITICAL_ISR(&hw_cdc_tx_mux)");
  const std::size_t second = isr.find("portENTER_CRITICAL_ISR(&hw_cdc_tx_mux)", first);
  const std::size_t sample = isr.find("payload_published_since_pickup", second);
  const std::size_t queue = isr.find("xRingbufferReceiveUpToFromISR(", second);
  if (first == std::string::npos || second == std::string::npos ||
      sample == std::string::npos || queue == std::string::npos || sample >= queue) {
    return false;
  }
  std::size_t guards = 0U;
  for (std::size_t pos = sample; (pos = isr.find(
       "!payload_published_since_pickup", pos)) != std::string::npos; ++pos) {
    ++guards;
  }
  return guards >= 3U;
}

bool production_cleanup_rechecks_publication() {
  const std::string isr = extract_function(read_file(
      "/third_party/esp32-core-3.3.11-vc-lora/cores/esp32/HWCDC.cpp"),
      "static void hw_cdc_isr_handler(");
  const std::size_t fallback = isr.find("} else if (in_empty_allowed)");
  if (fallback == std::string::npos) {
    return false;
  }
  const std::string cleanup = isr.substr(fallback);
  std::size_t guards = 0U;
  for (std::size_t pos = 0U; (pos = cleanup.find(
       "if (!tx_payload_in_flight)", pos)) != std::string::npos; ++pos) {
    ++guards;
  }
  std::size_t locks = 0U;
  for (std::size_t pos = 0U; (pos = cleanup.find(
       "portENTER_CRITICAL_ISR(&hw_cdc_tx_mux)", pos)) != std::string::npos; ++pos) {
    ++locks;
  }
  return guards >= 2U && locks >= 2U;
}

void test_isr_second_phase_cannot_disable_new_task_publication(
    TestReport& report) {
  const auto prefix = sequence(32U, 0xA0U);
  const auto suffix = sequence(31U, 0xC0U);
  BusyIdleCheckedWriterModel historical{true};
  historical.prime_previous(prefix);
  historical.enqueue_next(suffix, BusyPickupInjection::BeforeEnqueue);
  historical.service_stale_second_phase(false);
  historical.host_pickup();
  report.check(!historical.service_isr() && !historical.completed(),
               "unprotected second ISR phase did not reproduce lost fresh IRQ");

  BusyIdleCheckedWriterModel production{production_has_post_enqueue_restart()};
  production.prime_previous(prefix);
  production.enqueue_next(suffix, BusyPickupInjection::BeforeEnqueue);
  production.service_stale_second_phase(
      production_rechecks_publication_in_second_isr_phase());
  production.host_pickup();
  production.service_isr();
  auto expected = prefix;
  expected.insert(expected.end(), suffix.begin(), suffix.end());
  report.check(production.completed() && production.received() == expected &&
                   production.fifo_writes() == 2U,
               "stale second ISR phase cleared the new task publication IRQ");
  report.check(production_rechecks_publication_in_second_isr_phase(),
               "ISR second TX-mux phase does not recheck publication before "
               "queue removal, FIFO write and empty-queue IRQ disable");
}

void test_stale_isr_cleanup_cannot_erase_fresh_pickup_event(
    TestReport& report) {
  const auto prefix = sequence(32U, 0xD0U);
  const auto suffix = sequence(31U, 0xE0U);
  for (const bool disable_irq : {false, true}) {
    BusyIdleCheckedWriterModel historical{true};
    historical.prime_previous(prefix);
    historical.enqueue_next(suffix, BusyPickupInjection::BeforeEnqueue);
    historical.host_pickup();
    historical.service_stale_cleanup(false, disable_irq);
    report.check(!historical.service_isr() && !historical.completed(),
                 "unprotected stale cleanup did not erase a fresh pickup IRQ");

    BusyIdleCheckedWriterModel production{production_has_post_enqueue_restart()};
    production.prime_previous(prefix);
    production.enqueue_next(suffix, BusyPickupInjection::BeforeEnqueue);
    production.host_pickup();
    production.service_stale_cleanup(production_cleanup_rechecks_publication(),
                                     disable_irq);
    production.service_isr();
    auto expected = prefix;
    expected.insert(expected.end(), suffix.begin(), suffix.end());
    report.check(production.completed() && production.received() == expected &&
                     production.fifo_writes() == 2U,
                 "stale ISR fallback cleanup erased a new packet pickup IRQ");
  }
  report.check(production_cleanup_rechecks_publication(),
               "both ISR fallback cleanup branches must recheck new payload "
               "ownership under TX mux before clearing or masking IN_EMPTY");
}

void test_busy_entry_pickup_before_enqueue_reproduces_lost_wake(
    TestReport& report) {
  const auto prefix = sequence(32U, 0x30U);
  const auto suffix = sequence(31U, 0x50U);
  BusyIdleCheckedWriterModel historical{false};
  historical.prime_previous(prefix);
  report.check(historical.enqueue_next(suffix,
                   BusyPickupInjection::BeforeEnqueue) == suffix.size() &&
                   historical.lost_wake() &&
                   !historical.service_isr() &&
                   historical.received() == prefix,
               "historical busy-entry model did not reproduce ring31 with "
               "FIFO writable, generations equal and no fresh IRQ");

  BusyIdleCheckedWriterModel production{production_has_post_enqueue_restart()};
  production.prime_previous(prefix);
  report.check(production.enqueue_next(suffix,
                   BusyPickupInjection::BeforeEnqueue) == suffix.size() &&
                   production.fifo_size() == suffix.size() &&
                   production.fifo_writes() == 2U,
               "production busy-to-idle enqueue left 31 bytes stranded "
               "after the last empty ISR");
  production.host_pickup();
  production.service_isr();
  auto expected = prefix;
  expected.insert(expected.end(), suffix.begin(), suffix.end());
  report.check(production.completed() && production.received() == expected &&
                   production.fifo_writes() == 2U,
               "busy-to-idle restart lost or duplicated the 32+31 frame");
}

void test_busy_entry_pickup_after_enqueue_uses_existing_isr_once(
    TestReport& report) {
  const auto prefix = sequence(32U, 0x70U);
  const auto suffix = sequence(31U, 0x90U);
  for (const auto injection : {BusyPickupInjection::AfterEnqueue,
                               BusyPickupInjection::AfterPostEnqueueCheck}) {
    BusyIdleCheckedWriterModel model{production_has_post_enqueue_restart()};
    model.prime_previous(prefix);
    report.check(model.enqueue_next(suffix, injection) == suffix.size() &&
                     model.fifo_size() == suffix.size() &&
                     model.fifo_writes() == 2U,
                 "normal busy enqueue did not leave exactly one suffix "
                 "publication owned by the ISR");
    model.host_pickup();
    model.service_isr();
    auto expected = prefix;
    expected.insert(expected.end(), suffix.begin(), suffix.end());
    report.check(model.completed() && model.received() == expected &&
                     model.fifo_writes() == 2U,
                 "post-enqueue pickup duplicated or lost an ISR-owned packet");
  }
}

void test_busy_to_idle_restart_rejects_unsafe_or_nonexclusive_boundaries(
    TestReport& report) {
  const auto prefix = sequence(32U, 0x10U);
  const auto suffix = sequence(31U, 0x30U);
  for (const auto fault : {BusyRestartFault::EpochMismatch,
                           BusyRestartFault::ResetPending,
                           BusyRestartFault::Quarantined,
                           BusyRestartFault::StashPending,
                           BusyRestartFault::OlderRingPending,
                           BusyRestartFault::FifoNotWritable,
                           BusyRestartFault::PayloadStillInFlight,
                           BusyRestartFault::BootstrapFence,
                           BusyRestartFault::BootstrapAborted,
                           BusyRestartFault::DebugWriterActive}) {
    BusyIdleCheckedWriterModel model{production_has_post_enqueue_restart()};
    model.prime_previous(prefix);
    const std::size_t accepted = model.enqueue_next(
        suffix, BusyPickupInjection::BeforeEnqueue, fault);
    const bool must_reject = fault == BusyRestartFault::EpochMismatch ||
        fault == BusyRestartFault::ResetPending ||
        fault == BusyRestartFault::Quarantined;
    const std::size_t expected_pending = must_reject ? 0U :
        (fault == BusyRestartFault::OlderRingPending ? 32U : 31U);
    report.check(model.fifo_writes() == 1U && model.fifo_size() == 0U &&
                     model.received() == prefix &&
                     accepted == (must_reject ? 0U : suffix.size()) &&
                     model.ring_size() == expected_pending,
                 "busy-to-idle task prime crossed an epoch/reset/ownership "
                 "or FIFO-availability guard");
  }
}

void test_production_source_requires_post_enqueue_boundary_guards(
    TestReport& report) {
  const std::string writer = extract_function(read_file(
      "/third_party/esp32-core-3.3.11-vc-lora/cores/esp32/HWCDC.cpp"),
      "size_t HWCDC::writeTxChecked(");
  const std::size_t begin = writer.find("const bool post_enqueue_idle_boundary",
                                       writer.find("xRingbufferSend("));
  const std::size_t end = writer.find("if (post_enqueue_idle_boundary)", begin);
  const std::string predicate = begin == std::string::npos ||
          end == std::string::npos ? std::string{} : writer.substr(begin, end - begin);
  report.check(production_has_post_enqueue_restart(),
               "checked writer lacks a fenced post-enqueue idle transition "
               "reservation before the existing task-prime branch");
  for (const auto* guard : {"!task_prime_reserved", "epoch_matches",
                            "!tx_bootstrap_enqueue_fence",
                            "!tx_bootstrap_enqueue_aborted", "!tx_debug_writer_active",
                            "bytes_waiting == size", "tx_stash_len == 0U",
                            "!tx_payload_in_flight",
                            "tx_payload_pickup_generation == tx_payload_publish_generation",
                            "usb_serial_jtag_ll_txfifo_writable() == 1"}) {
    report.check(predicate.find(guard) != std::string::npos,
                 "post-enqueue task prime omitted an ownership/epoch/idle guard");
  }
  const std::size_t epoch = writer.rfind("epoch_matches =", begin);
  const std::string epoch_predicate = epoch == std::string::npos ||
          begin == std::string::npos ? std::string{} : writer.substr(epoch, begin - epoch);
  report.check(epoch_predicate.find("tx_loss_epoch == expected_loss_epoch") !=
                       std::string::npos &&
                   epoch_predicate.find("!reset_pending_after") != std::string::npos &&
                   epoch_predicate.find("!tx_fifo_quarantined") != std::string::npos,
               "post-enqueue epoch_matches does not exclude reset/quarantine");
}

void test_post_bootstrap_lost_wake_primes_21_bytes(TestReport& report) {
  CheckedWriterTaskPrimeModel model{};
  const auto heartbeat = sequence(21U, 0xFDU);
  model.set_stale_isr_snapshot();

  report.check(model.write_checked(heartbeat, 1U, kProductChunkLimit) ==
                   heartbeat.size(),
               "clean-idle checked write did not accept the 21-byte frame");
  report.check(model.current_fifo_size() == heartbeat.size() &&
                   model.ring_size() == 0U && model.stash_size() == 0U &&
                   model.wr_done_count() == 1U,
               "21-byte frame waited for a lost IN_EMPTY wake instead of "
               "being task-primed");
  report.check(!model.service_stale_isr_snapshot() &&
                   model.current_fifo_size() == heartbeat.size() &&
                   model.publish_generation() == 1U,
               "stale ISR snapshot consumed or duplicated task-primed data");
  report.check(model.host_pickup() && model.complete() &&
                   model.picked_up() == heartbeat &&
                   model.pickup_generation() == model.publish_generation(),
               "host did not receive the exact 21-byte frame once");
  report.check(!model.service_live_in_empty(kProductChunkLimit) &&
                   model.picked_up() == heartbeat &&
                   model.wr_done_count() == 1U,
               "empty follow-up ISR duplicated an already committed frame");
}

void test_zero_fifo_write_never_publishes(TestReport& report) {
  CheckedWriterTaskPrimeModel model{};
  const auto frame = sequence(21U, 0x10U);
  report.check(model.write_checked(frame, 1U, 0U) == 0U,
               "zero-byte LL write was accepted by checked writer");
  report.check(model.raw_fifo_write_bytes() == 0U &&
                   model.current_fifo_size() == 0U &&
                   model.publish_generation() == 0U &&
                   model.wr_done_count() == 0U && model.zlp_count() == 0U,
               "zero-byte LL write published progress or a ZLP");
}

void test_partial_fifo_write_stashes_suffix_without_duplication(
    TestReport& report) {
  CheckedWriterTaskPrimeModel model{};
  const auto frame = sequence(21U, 0x30U);
  report.check(model.write_checked(frame, 1U, 7U) == frame.size() &&
                   model.current_fifo_size() == 7U &&
                   model.stash_size() == 14U,
               "partial task prime did not retain the unwritten suffix");
  report.check(!model.maybe_issue_terminal_zlp() &&
                   model.zlp_count() == 0U,
               "software-pending suffix emitted a maintenance/terminal ZLP");
  report.check(model.host_pickup() &&
                   model.service_live_in_empty(kProductChunkLimit) &&
                   model.current_fifo_size() == 14U &&
                   model.stash_size() == 0U,
               "fresh pickup did not drain the exact stashed suffix");
  report.check(model.host_pickup() && model.complete() &&
                   model.picked_up() == frame && model.wr_done_count() == 2U,
               "partial task prime lost or duplicated payload bytes");
}

void test_reset_before_fifo_write_is_fail_closed(TestReport& report) {
  CheckedWriterTaskPrimeModel model{};
  const auto frame = sequence(21U, 0x50U);
  report.check(model.write_checked(frame, 1U, kProductChunkLimit,
                                   ResetInjection::BeforeFifoWrite) == 0U,
               "pre-write BUS_RESET did not reject the checked write");
  report.check(model.loss_epoch() == 2U &&
                   model.raw_fifo_write_bytes() == 0U &&
                   model.publish_generation() == 0U &&
                   model.wr_done_count() == 0U && !model.quarantined(),
               "pre-write BUS_RESET exposed bytes or retained false quarantine");
}

void test_reset_after_fifo_write_quarantines_unpublished_bytes(
    TestReport& report) {
  CheckedWriterTaskPrimeModel model{};
  const auto frame = sequence(21U, 0x70U);
  report.check(model.write_checked(frame, 1U, kProductChunkLimit,
                                   ResetInjection::AfterFifoWrite) == 0U,
               "post-write BUS_RESET did not reject the ambiguous write");
  report.check(model.loss_epoch() == 2U && model.quarantined() &&
                   model.raw_fifo_write_bytes() == frame.size() &&
                   model.current_fifo_size() == 0U &&
                   model.publish_generation() == 0U &&
                   model.wr_done_count() == 0U && model.zlp_count() == 0U,
               "post-write BUS_RESET published quarantined FIFO bytes");
  model.service_bus_reset_isr();
  report.check(model.loss_epoch() == 3U && model.quarantined(),
               "the pending reset ISR erased task-side late-write quarantine");
  model.service_bus_reset_isr();
  report.check(model.loss_epoch() == 4U && !model.quarantined(),
               "a later clean reset did not release the sticky quarantine");
}

void test_production_source_requires_checked_writer_task_prime(
    TestReport& report) {
  const std::string source = read_file(
      "/third_party/esp32-core-3.3.11-vc-lora/cores/esp32/HWCDC.cpp");
  const std::string checked_writer = extract_function(
      source, "size_t HWCDC::writeTxChecked(");

  // The implementation may inline the transaction or use this named helper.
  // A named helper keeps the ISR and task paths auditable without changing the
  // public HWCDC API.
  const std::string helper_name =
      "hw_cdc_try_task_prime_payload_locked(";
  const std::size_t helper_offset = source.find(helper_name);
  const bool inline_prime =
      checked_writer.find("usb_serial_jtag_ll_write_txfifo(") !=
      std::string::npos;
  const bool helper_prime =
      helper_offset != std::string::npos &&
      checked_writer.find(helper_name) != std::string::npos;
  const std::string prime_scope =
      inline_prime
          ? checked_writer
          : (helper_offset == std::string::npos
                 ? std::string{}
                 : source.substr(helper_offset,
                                 std::min<std::size_t>(7000U,
                                      source.size() - helper_offset)));

  report.check(!source.empty() && !checked_writer.empty(),
               "patched HWCDC source or writeTxChecked is unreadable");
  report.check(inline_prime || helper_prime,
               "writeTxChecked still relies only on IN_EMPTY and has no "
               "clean-idle task-side payload prime");
  report.check(
      prime_scope.find("usb_serial_jtag_ll_disable_intr_mask(") !=
              std::string::npos &&
          prime_scope.find("usb_serial_jtag_ll_clr_intsts_mask(") !=
              std::string::npos &&
          prime_scope.find("xRingbufferReceiveUpTo(") != std::string::npos &&
          ordered(prime_scope, "reset_pending_before_fifo_write",
                  "usb_serial_jtag_ll_write_txfifo(") &&
          ordered(prime_scope, "usb_serial_jtag_ll_write_txfifo(",
                  "reset_pending_after_fifo_write"),
      "task prime lacks stale-IN_EMPTY fencing or adjacent BUS_RESET checks");
  report.check(
      prime_scope.find("sent_size == 0U") != std::string::npos &&
          prime_scope.find("sent_size < queued_size") != std::string::npos &&
          prime_scope.find("tx_stash_len = queued_size - sent_size") !=
              std::string::npos &&
          ordered(prime_scope, "tx_payload_publish_generation",
                  "usb_serial_jtag_ll_txfifo_flush()") &&
          ordered(prime_scope, "usb_serial_jtag_ll_txfifo_flush()",
                  "USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY"),
      "task prime does not cover zero/partial writes or publish-before-rearm");
  report.check(
      prime_scope.find("hw_cdc_r19_invalidate_terminal_zlp_locked()") !=
              std::string::npos &&
          prime_scope.find("hw_cdc_r19_issue_terminal_zlp_locked(") ==
              std::string::npos,
      "task prime can reuse/emit a terminal ZLP at a new software boundary");
  report.check(
      checked_writer.find(
          "tx_task_fifo_written_after_pending_reset = true") !=
              std::string::npos &&
          source.find(
              "fifo_written_after_reset ||\n      "
              "tx_task_fifo_written_after_pending_reset") !=
              std::string::npos,
      "task-side late-reset quarantine is not handed to the reset ISR");
}

}  // namespace

int main() {
  TestReport report{};
  test_post_bootstrap_lost_wake_primes_21_bytes(report);
  test_zero_fifo_write_never_publishes(report);
  test_partial_fifo_write_stashes_suffix_without_duplication(report);
  test_reset_before_fifo_write_is_fail_closed(report);
  test_reset_after_fifo_write_quarantines_unpublished_bytes(report);
  test_production_source_requires_checked_writer_task_prime(report);
  test_busy_entry_pickup_before_enqueue_reproduces_lost_wake(report);
  test_busy_entry_pickup_after_enqueue_uses_existing_isr_once(report);
  test_busy_to_idle_restart_rejects_unsafe_or_nonexclusive_boundaries(report);
  test_production_source_requires_post_enqueue_boundary_guards(report);
  test_isr_second_phase_cannot_disable_new_task_publication(report);
  test_stale_isr_cleanup_cannot_erase_fresh_pickup_event(report);

  std::cout << "UT-R19-HWCDC-TASK-PRIME-001 checks=" << report.checks
            << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
