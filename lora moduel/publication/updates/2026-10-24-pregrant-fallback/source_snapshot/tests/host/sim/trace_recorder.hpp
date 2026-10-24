#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <string>

namespace vc_lora::test {

struct TraceEvent {
  std::uint64_t time_ms{0};
  std::string node{};
  std::string state{};
  std::uint16_t cycle_id{0};
  std::string event{};
  bool aux_high{true};
  std::uint64_t queue_bytes{0};
  std::uint64_t radio_tx_bytes{0};
  std::uint64_t radio_rx_bytes{0};
  std::uint16_t session_id{0};
};

class TraceRecorder {
 public:
  static constexpr std::size_t kMaxRetainedEvents = 2'048U;

  void record(TraceEvent event);
  bool write_csv(const std::filesystem::path& path) const;
  std::size_t size() const noexcept { return events_.size(); }
  std::size_t retained_event_count() const noexcept { return events_.size(); }
  std::uint64_t total_event_count() const noexcept {
    return total_event_count_;
  }
  std::size_t max_retained_event_count() const noexcept {
    return max_retained_event_count_;
  }
  std::uint64_t last_time_ms() const noexcept {
    return events_.empty() ? 0U : events_.back().time_ms;
  }
  const TraceEvent* event_at(std::size_t index) const noexcept {
    return index < events_.size() ? &events_[index] : nullptr;
  }

 private:
  std::deque<TraceEvent> events_{};
  std::uint64_t total_event_count_{0};
  std::size_t max_retained_event_count_{0};
};

}  // namespace vc_lora::test
