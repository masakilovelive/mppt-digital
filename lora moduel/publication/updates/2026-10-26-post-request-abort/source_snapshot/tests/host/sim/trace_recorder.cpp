#include "trace_recorder.hpp"

#include <algorithm>
#include <cstdio>
#include <utility>

namespace vc_lora::test {
namespace {

std::string csv_escape(const std::string& value) {
  bool quote = false;
  std::string escaped;
  escaped.reserve(value.size() + 2U);
  for (const char character : value) {
    if (character == ',' || character == '"' || character == '\n' ||
        character == '\r') {
      quote = true;
    }
    if (character == '"') {
      escaped += "\"\"";
    } else {
      escaped += character;
    }
  }
  return quote ? '"' + escaped + '"' : escaped;
}

}  // namespace

void TraceRecorder::record(TraceEvent event) {
  ++total_event_count_;
  if (events_.size() == kMaxRetainedEvents) {
    events_.pop_front();
  }
  events_.push_back(std::move(event));
  max_retained_event_count_ =
      std::max(max_retained_event_count_, events_.size());
}

bool TraceRecorder::write_csv(const std::filesystem::path& path) const {
  std::error_code error;
  std::filesystem::create_directories(path.parent_path(), error);
  std::FILE* stream = std::fopen(path.string().c_str(), "wb");
  if (stream == nullptr) {
    return false;
  }
  const std::string header =
      "time_ms,node,state,cycle_id,event,aux,queue_bytes,"
      "radio_tx_bytes,radio_rx_bytes,session_id\n";
  std::fwrite(header.data(), 1U, header.size(), stream);
  for (const auto& event : events_) {
    const std::string line =
        std::to_string(event.time_ms) + ',' + csv_escape(event.node) + ',' +
        csv_escape(event.state) + ',' + std::to_string(event.cycle_id) + ',' +
        csv_escape(event.event) + ',' +
        (event.aux_high ? "HIGH" : "LOW") + ',' +
        std::to_string(event.queue_bytes) + ',' +
        std::to_string(event.radio_tx_bytes) + ',' +
        std::to_string(event.radio_rx_bytes) + ',' +
        std::to_string(event.session_id) + '\n';
    std::fwrite(line.data(), 1U, line.size(), stream);
  }
  return std::fclose(stream) == 0;
}

}  // namespace vc_lora::test
