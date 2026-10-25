#pragma once

#include <cstdint>
#include <limits>

namespace vc_lora::experimental {

enum class Phase6RadioWriterOwner : std::uint8_t {
  None = 0U,
  StandardTdd,
  HighSpeed,
};

enum class Phase6RadioWriterUartResult : std::uint8_t {
  Rejected = 0U,
  Accepted,
};

enum class Phase6RadioWriterStatus : std::uint8_t {
  Idle = 0U,
  LeaseGranted,
  AcceptedAwaitingTail,
  RejectedReleased,
  TailReleased,
  HighSpeedActivated,
  ExplicitRestoreRequired,
  StandardRestored,
  FailClosed,
  HighSpeedStreamLeaseGranted,
  HighSpeedStreamUartRecorded,
};

struct Phase6RadioWriterLease final {
  Phase6RadioWriterOwner owner{Phase6RadioWriterOwner::None};
  std::uint32_t action_token{0U};
  std::uint32_t writer_generation{0U};

  [[nodiscard]] constexpr bool valid() const noexcept {
    return owner != Phase6RadioWriterOwner::None && action_token != 0U &&
           writer_generation != 0U;
  }
};

struct Phase6RadioTailEvidence final {
  Phase6RadioWriterLease lease{};
  bool physical_tail_complete{false};
  std::uint64_t completed_ms{0U};
};

struct Phase6HighSpeedStreamLimits final {
  std::uint32_t maximum_uart_records{0U};
  std::uint64_t maximum_accepted_bytes{0U};
  std::uint32_t maximum_record_bytes{0U};

  [[nodiscard]] constexpr bool valid() const noexcept {
    return maximum_uart_records != 0U && maximum_accepted_bytes != 0U &&
           maximum_record_bytes != 0U;
  }
};

struct Phase6HighSpeedStreamTailEvidence final {
  Phase6RadioWriterLease lease{};
  std::uint32_t final_action_token{0U};
  std::uint32_t final_action_writer_generation{0U};
  std::uint32_t final_wire_ordinal{0U};
  std::uint32_t uart_record_count{0U};
  std::uint64_t accepted_bytes{0U};
  bool local_aux_release_observed{false};
  bool physical_tail_complete{false};
  std::uint64_t completed_ms{0U};
};

// One physical E220 UART has one writer owner.  The standard TDD and R19
// candidate paths may select work independently, but only this arbiter may
// grant a physical write.  UART acceptance never releases the lease: the same
// owner/token/generation remains active through the correlated physical tail.
// A high-speed session also requires an explicit clean restore before standard
// TDD can poll again; an overlap, stale tail, or clock regression is fail-stop.
class Phase6RadioWriterArbiter final {
public:
  [[nodiscard]] Phase6RadioWriterStatus
  request(Phase6RadioWriterOwner owner, std::uint32_t action_token,
          Phase6RadioWriterLease &output) noexcept {
    output = {};
    if (failed_) {
      return Phase6RadioWriterStatus::FailClosed;
    }
    if (active_ || action_token == 0U || !owner_allowed(owner) ||
        next_generation_ == std::numeric_limits<std::uint32_t>::max()) {
      return fail();
    }
    ++next_generation_;
    active_lease_ = {owner, action_token, next_generation_};
    active_ = true;
    uart_accepted_ = false;
    accepted_ms_ = 0U;
    output = active_lease_;
    return set_status(Phase6RadioWriterStatus::LeaseGranted);
  }

  [[nodiscard]] Phase6RadioWriterStatus
  complete_uart(const Phase6RadioWriterLease &lease,
                Phase6RadioWriterUartResult result,
                std::uint64_t completed_ms) noexcept {
    if (failed_) {
      return Phase6RadioWriterStatus::FailClosed;
    }
    if (!accept_time(completed_ms) || !active_ || stream_active_ ||
        uart_accepted_ || !same_lease(lease, active_lease_)) {
      return fail();
    }
    if (result == Phase6RadioWriterUartResult::Rejected) {
      clear_active();
      return set_status(Phase6RadioWriterStatus::RejectedReleased);
    }
    uart_accepted_ = true;
    accepted_ms_ = completed_ms;
    return set_status(Phase6RadioWriterStatus::AcceptedAwaitingTail);
  }

  [[nodiscard]] Phase6RadioWriterStatus
  observe_physical_tail(const Phase6RadioTailEvidence &evidence,
                        std::uint64_t now_ms) noexcept {
    if (failed_) {
      return Phase6RadioWriterStatus::FailClosed;
    }
    if (!accept_time(now_ms) || !active_ || stream_active_ || !uart_accepted_ ||
        !evidence.physical_tail_complete ||
        !same_lease(evidence.lease, active_lease_) ||
        evidence.completed_ms < accepted_ms_ ||
        evidence.completed_ms > now_ms) {
      return fail();
    }
    last_released_lease_ = active_lease_;
    last_tail_ms_ = evidence.completed_ms;
    have_released_tail_ = true;
    clear_active();
    return set_status(Phase6RadioWriterStatus::TailReleased);
  }

  // Atomically selects HighSpeed mode and retains one writer lease for the
  // whole buffered stream. Individual UART accepts are accounting events;
  // they neither release this lease nor claim a physical RF tail.
  [[nodiscard]] Phase6RadioWriterStatus
  begin_high_speed_stream(std::uint32_t stream_token,
                          const Phase6HighSpeedStreamLimits &limits,
                          Phase6RadioWriterLease &output) noexcept {
    output = {};
    if (failed_) {
      return Phase6RadioWriterStatus::FailClosed;
    }
    if (mode_ != Mode::Standard || active_ || stream_token == 0U ||
        !limits.valid() ||
        next_generation_ == std::numeric_limits<std::uint32_t>::max()) {
      return fail();
    }
    ++next_generation_;
    mode_ = Mode::HighSpeed;
    active_lease_ = {Phase6RadioWriterOwner::HighSpeed, stream_token,
                     next_generation_};
    active_ = true;
    stream_active_ = true;
    stream_limits_ = limits;
    stream_uart_records_ = 0U;
    stream_accepted_bytes_ = 0U;
    stream_last_ordinal_ = 0U;
    stream_last_action_token_ = 0U;
    stream_last_action_writer_generation_ = 0U;
    stream_last_uart_ms_ = 0U;
    uart_accepted_ = false;
    accepted_ms_ = 0U;
    output = active_lease_;
    return set_status(Phase6RadioWriterStatus::HighSpeedStreamLeaseGranted);
  }

  [[nodiscard]] Phase6RadioWriterStatus record_high_speed_uart(
      const Phase6RadioWriterLease &lease, std::uint32_t action_token,
      std::uint32_t action_writer_generation, std::uint32_t wire_ordinal,
      std::uint32_t accepted_bytes, std::uint64_t completed_ms) noexcept {
    if (failed_) {
      return Phase6RadioWriterStatus::FailClosed;
    }
    const std::uint64_t accepted_u64 =
        static_cast<std::uint64_t>(accepted_bytes);
    if (!accept_time(completed_ms) || mode_ != Mode::HighSpeed || !active_ ||
        !stream_active_ || !same_lease(lease, active_lease_) ||
        action_token == 0U || action_writer_generation == 0U ||
        (stream_uart_records_ != 0U &&
         (action_token <= stream_last_action_token_ ||
          action_writer_generation <= stream_last_action_writer_generation_)) ||
        accepted_bytes == 0U ||
        accepted_bytes > stream_limits_.maximum_record_bytes ||
        stream_uart_records_ >= stream_limits_.maximum_uart_records ||
        wire_ordinal != stream_uart_records_ ||
        accepted_u64 > stream_limits_.maximum_accepted_bytes ||
        stream_accepted_bytes_ >
            stream_limits_.maximum_accepted_bytes - accepted_u64) {
      return fail();
    }
    stream_accepted_bytes_ += accepted_u64;
    stream_last_ordinal_ = wire_ordinal;
    stream_last_action_token_ = action_token;
    stream_last_action_writer_generation_ = action_writer_generation;
    ++stream_uart_records_;
    stream_last_uart_ms_ = completed_ms;
    return set_status(Phase6RadioWriterStatus::HighSpeedStreamUartRecorded);
  }

  [[nodiscard]] Phase6RadioWriterStatus observe_high_speed_stream_tail(
      const Phase6HighSpeedStreamTailEvidence &evidence,
      std::uint64_t now_ms) noexcept {
    if (failed_) {
      return Phase6RadioWriterStatus::FailClosed;
    }
    if (!accept_time(now_ms) || mode_ != Mode::HighSpeed || !active_ ||
        !stream_active_ || stream_uart_records_ == 0U ||
        !same_lease(evidence.lease, active_lease_) ||
        !evidence.local_aux_release_observed ||
        !evidence.physical_tail_complete ||
        evidence.final_action_token != stream_last_action_token_ ||
        evidence.final_action_writer_generation !=
            stream_last_action_writer_generation_ ||
        evidence.final_wire_ordinal != stream_last_ordinal_ ||
        evidence.uart_record_count != stream_uart_records_ ||
        evidence.accepted_bytes != stream_accepted_bytes_ ||
        evidence.completed_ms < stream_last_uart_ms_ ||
        evidence.completed_ms > now_ms) {
      return fail();
    }
    last_released_lease_ = active_lease_;
    last_tail_ms_ = evidence.completed_ms;
    have_released_tail_ = true;
    clear_active();
    mode_ = Mode::AwaitExplicitRestore;
    return set_status(Phase6RadioWriterStatus::ExplicitRestoreRequired);
  }

  [[nodiscard]] Phase6RadioWriterStatus activate_high_speed() noexcept {
    if (failed_) {
      return Phase6RadioWriterStatus::FailClosed;
    }
    if (mode_ != Mode::Standard || active_) {
      return fail();
    }
    mode_ = Mode::HighSpeed;
    return set_status(Phase6RadioWriterStatus::HighSpeedActivated);
  }

  [[nodiscard]] Phase6RadioWriterStatus complete_high_speed() noexcept {
    if (failed_) {
      return Phase6RadioWriterStatus::FailClosed;
    }
    if (mode_ != Mode::HighSpeed || active_) {
      return fail();
    }
    mode_ = Mode::AwaitExplicitRestore;
    return set_status(Phase6RadioWriterStatus::ExplicitRestoreRequired);
  }

  [[nodiscard]] Phase6RadioWriterStatus
  restore_standard(bool clean_session_confirmed) noexcept {
    if (failed_) {
      return Phase6RadioWriterStatus::FailClosed;
    }
    if (mode_ != Mode::AwaitExplicitRestore || active_) {
      return fail();
    }
    if (!clean_session_confirmed) {
      return set_status(Phase6RadioWriterStatus::ExplicitRestoreRequired);
    }
    mode_ = Mode::Standard;
    return set_status(Phase6RadioWriterStatus::StandardRestored);
  }

  [[nodiscard]] Phase6RadioWriterStatus abort_high_speed() noexcept {
    return fail();
  }

  [[nodiscard]] constexpr bool can_poll_standard() const noexcept {
    return !failed_ && mode_ == Mode::Standard && !active_;
  }
  [[nodiscard]] constexpr bool can_poll_high_speed() const noexcept {
    return !failed_ && mode_ == Mode::HighSpeed && !active_;
  }
  [[nodiscard]] constexpr bool write_active() const noexcept { return active_; }
  [[nodiscard]] constexpr bool awaiting_physical_tail() const noexcept {
    return active_ &&
           (uart_accepted_ || (stream_active_ && stream_uart_records_ != 0U));
  }
  [[nodiscard]] constexpr bool high_speed_active() const noexcept {
    return !failed_ && mode_ == Mode::HighSpeed;
  }
  [[nodiscard]] constexpr bool explicit_restore_required() const noexcept {
    return !failed_ && mode_ == Mode::AwaitExplicitRestore;
  }
  [[nodiscard]] constexpr bool fail_closed() const noexcept { return failed_; }
  [[nodiscard]] constexpr bool high_speed_stream_active() const noexcept {
    return !failed_ && mode_ == Mode::HighSpeed && active_ && stream_active_;
  }
  [[nodiscard]] constexpr std::uint32_t
  high_speed_stream_uart_records() const noexcept {
    return stream_uart_records_;
  }
  [[nodiscard]] constexpr std::uint64_t
  high_speed_stream_accepted_bytes() const noexcept {
    return stream_accepted_bytes_;
  }
  [[nodiscard]] constexpr std::uint32_t
  high_speed_stream_last_ordinal() const noexcept {
    return stream_last_ordinal_;
  }
  [[nodiscard]] constexpr std::uint32_t
  high_speed_stream_last_action_token() const noexcept {
    return stream_last_action_token_;
  }
  [[nodiscard]] constexpr std::uint32_t
  high_speed_stream_last_action_writer_generation() const noexcept {
    return stream_last_action_writer_generation_;
  }
  [[nodiscard]] constexpr Phase6RadioWriterStatus last_status() const noexcept {
    return last_status_;
  }
  [[nodiscard]] constexpr const Phase6RadioWriterLease &
  active_lease() const noexcept {
    return active_lease_;
  }
  [[nodiscard]] constexpr bool have_released_tail() const noexcept {
    return have_released_tail_;
  }
  [[nodiscard]] constexpr const Phase6RadioWriterLease &
  last_released_lease() const noexcept {
    return last_released_lease_;
  }
  [[nodiscard]] constexpr std::uint64_t last_tail_ms() const noexcept {
    return last_tail_ms_;
  }

private:
  enum class Mode : std::uint8_t {
    Standard = 0U,
    HighSpeed,
    AwaitExplicitRestore,
  };

  [[nodiscard]] constexpr bool
  owner_allowed(Phase6RadioWriterOwner owner) const noexcept {
    return (mode_ == Mode::Standard &&
            owner == Phase6RadioWriterOwner::StandardTdd) ||
           (mode_ == Mode::HighSpeed &&
            owner == Phase6RadioWriterOwner::HighSpeed);
  }

  [[nodiscard]] static constexpr bool
  same_lease(const Phase6RadioWriterLease &left,
             const Phase6RadioWriterLease &right) noexcept {
    return left.valid() && right.valid() && left.owner == right.owner &&
           left.action_token == right.action_token &&
           left.writer_generation == right.writer_generation;
  }

  [[nodiscard]] bool accept_time(std::uint64_t now_ms) noexcept {
    if (have_last_time_ && now_ms < last_time_ms_) {
      return false;
    }
    have_last_time_ = true;
    last_time_ms_ = now_ms;
    return true;
  }

  void clear_active() noexcept {
    active_lease_ = {};
    active_ = false;
    uart_accepted_ = false;
    accepted_ms_ = 0U;
    stream_active_ = false;
    stream_limits_ = {};
    stream_uart_records_ = 0U;
    stream_accepted_bytes_ = 0U;
    stream_last_ordinal_ = 0U;
    stream_last_action_token_ = 0U;
    stream_last_action_writer_generation_ = 0U;
    stream_last_uart_ms_ = 0U;
  }

  [[nodiscard]] Phase6RadioWriterStatus
  set_status(Phase6RadioWriterStatus status) noexcept {
    last_status_ = status;
    return status;
  }

  [[nodiscard]] Phase6RadioWriterStatus fail() noexcept {
    failed_ = true;
    last_status_ = Phase6RadioWriterStatus::FailClosed;
    return last_status_;
  }

  Mode mode_{Mode::Standard};
  Phase6RadioWriterLease active_lease_{};
  Phase6RadioWriterLease last_released_lease_{};
  Phase6HighSpeedStreamLimits stream_limits_{};
  std::uint32_t next_generation_{0U};
  std::uint32_t stream_uart_records_{0U};
  std::uint32_t stream_last_ordinal_{0U};
  std::uint32_t stream_last_action_token_{0U};
  std::uint32_t stream_last_action_writer_generation_{0U};
  std::uint64_t stream_accepted_bytes_{0U};
  std::uint64_t stream_last_uart_ms_{0U};
  std::uint64_t accepted_ms_{0U};
  std::uint64_t last_tail_ms_{0U};
  std::uint64_t last_time_ms_{0U};
  bool active_{false};
  bool stream_active_{false};
  bool uart_accepted_{false};
  bool have_released_tail_{false};
  bool have_last_time_{false};
  bool failed_{false};
  Phase6RadioWriterStatus last_status_{Phase6RadioWriterStatus::Idle};
};

} // namespace vc_lora::experimental
