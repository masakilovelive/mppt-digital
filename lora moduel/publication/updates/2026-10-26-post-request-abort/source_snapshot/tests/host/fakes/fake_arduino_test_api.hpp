#pragma once
#include "../../../third_party/esp32-core-3.3.11-vc-lora/cores/esp32/HWCDCR19Diagnostic.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <deque>
#include <limits>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

inline constexpr int LOW = 0;
inline constexpr int HIGH = 1;
inline constexpr int INPUT_PULLUP = 2;
inline constexpr int OUTPUT = 3;
inline constexpr std::uint32_t SERIAL_8N1 = 0x800001cU;

inline constexpr int D0 = 0;
inline constexpr int D1 = 1;
inline constexpr int D2 = 2;
inline constexpr int D3 = 3;
inline constexpr int D4 = 4;
inline constexpr int D5 = 5;
inline constexpr int D6 = 6;
inline constexpr int D7 = 7;
inline constexpr int D8 = 8;
inline constexpr int D9 = 9;
inline constexpr int D10 = 10;

namespace fake_arduino {

inline std::uint64_t now_us{0U};
inline std::array<int, 64U> pin_levels{};
inline std::array<int, 64U> pin_modes{};
inline std::uint32_t random_state{0x13579BDFU};
inline std::unordered_map<std::string, std::vector<std::uint8_t>>
    preferences_store{};

void reset_serial_state() noexcept;

inline void reset_platform() noexcept {
  now_us = 0U;
  pin_levels.fill(LOW);
  pin_modes.fill(0);
  random_state = 0x13579BDFU;
  preferences_store.clear();
  reset_serial_state();
}

inline void advance_time_ms(std::uint64_t milliseconds) noexcept {
  now_us += milliseconds * 1000U;
}

inline void set_pin_input_level(int pin, int level) noexcept {
  if (pin >= 0 && static_cast<std::size_t>(pin) < pin_levels.size()) {
    pin_levels[static_cast<std::size_t>(pin)] = level;
  }
}

}  // namespace fake_arduino

inline void pinMode(int pin, int mode) noexcept {
  if (pin >= 0 &&
      static_cast<std::size_t>(pin) < fake_arduino::pin_modes.size()) {
    fake_arduino::pin_modes[static_cast<std::size_t>(pin)] = mode;
  }
}

inline void digitalWrite(int pin, int level) noexcept {
  fake_arduino::set_pin_input_level(pin, level);
}

inline int digitalRead(int pin) noexcept {
  if (pin < 0 ||
      static_cast<std::size_t>(pin) >= fake_arduino::pin_levels.size()) {
    return LOW;
  }
  return fake_arduino::pin_levels[static_cast<std::size_t>(pin)];
}

inline void delay(std::uint32_t milliseconds) noexcept {
  fake_arduino::advance_time_ms(milliseconds);
}

inline std::uint32_t millis() noexcept {
  return static_cast<std::uint32_t>(fake_arduino::now_us / 1000U);
}

inline std::uint32_t micros() noexcept {
  return static_cast<std::uint32_t>(fake_arduino::now_us);
}

class HardwareSerial final {
 public:
  explicit HardwareSerial(int port) noexcept : port_(port) {}

  std::size_t setRxBufferSize(std::size_t bytes) noexcept {
    rx_buffer_bytes_ = bytes;
    return bytes;
  }

  void begin(std::uint32_t baud, std::uint32_t config, int rx_pin,
             int tx_pin) noexcept {
    baud_ = baud;
    config_ = config;
    rx_pin_ = rx_pin;
    tx_pin_ = tx_pin;
    begun_ = true;
  }

  void end() noexcept {
    begun_ = false;
    baud_ = 0U;
  }

  explicit operator bool() const noexcept { return begun_; }

  int available() const noexcept {
    return static_cast<int>(rx_bytes_.size());
  }

  int read() noexcept {
    if (rx_bytes_.empty()) {
      return -1;
    }
    const std::uint8_t value = rx_bytes_.front();
    rx_bytes_.pop_front();
    return static_cast<int>(value);
  }

  int availableForWrite() const noexcept {
    return begun_ ? 4096 : 0;
  }

  std::size_t write(const std::uint8_t* bytes,
                    std::size_t size) noexcept {
    if (!begun_ || bytes == nullptr || size == 0U) {
      return 0U;
    }
    if (baud_ == 9600U) {
      config_tx_bytes_.insert(config_tx_bytes_.end(), bytes, bytes + size);
      if (size == 3U && bytes[0] == 0xC1U && bytes[1] == 0x00U &&
          bytes[2] == 0x08U) {
        ++config_read_count_;
        if (config_responses_enabled_) {
          rx_bytes_.push_back(0xC1U);
          rx_bytes_.push_back(0x00U);
          rx_bytes_.push_back(0x08U);
          for (const std::uint8_t value : e220_profile_) {
            rx_bytes_.push_back(value);
          }
        }
      } else if (size == 11U && bytes[0] == 0xC0U &&
                  bytes[1] == 0x00U && bytes[2] == 0x08U) {
        std::copy_n(bytes + 3U, e220_profile_.size(),
                    e220_profile_.begin());
        if (config_responses_enabled_) {
          rx_bytes_.push_back(0xC1U);
          for (std::size_t index = 1U; index < size; ++index) {
            rx_bytes_.push_back(bytes[index]);
          }
        }
      }
    } else {
      normal_tx_bytes_.insert(normal_tx_bytes_.end(), bytes, bytes + size);
    }
    return size;
  }

  std::size_t write(std::uint8_t byte) noexcept {
    return write(&byte, 1U);
  }

  void inject_rx(const std::uint8_t* bytes, std::size_t size) {
    if (bytes == nullptr) {
      return;
    }
    rx_bytes_.insert(rx_bytes_.end(), bytes, bytes + size);
  }

  void reset_test_state() noexcept {
    begun_ = false;
    baud_ = 0U;
    config_ = 0U;
    rx_pin_ = -1;
    tx_pin_ = -1;
    rx_buffer_bytes_ = 0U;
    rx_bytes_.clear();
    config_tx_bytes_.clear();
    normal_tx_bytes_.clear();
    config_read_count_ = 0U;
    config_responses_enabled_ = true;
    e220_profile_ = {0x00U, 0x00U, 0xE5U, 0xC3U,
                     0x46U, 0x00U, 0x00U, 0x00U};
  }

  std::uint32_t baud_rate() const noexcept { return baud_; }
  std::size_t config_read_count() const noexcept {
    return config_read_count_;
  }
  void set_config_responses_enabled(bool enabled) noexcept {
    config_responses_enabled_ = enabled;
  }
  const std::vector<std::uint8_t>& normal_tx_bytes() const noexcept {
    return normal_tx_bytes_;
  }

 private:
  [[maybe_unused]] int port_{0};
  bool begun_{false};
  std::uint32_t baud_{0U};
  std::uint32_t config_{0U};
  int rx_pin_{-1};
  int tx_pin_{-1};
  std::size_t rx_buffer_bytes_{0U};
  std::deque<std::uint8_t> rx_bytes_{};
  std::vector<std::uint8_t> config_tx_bytes_{};
  std::vector<std::uint8_t> normal_tx_bytes_{};
  std::size_t config_read_count_{0U};
  bool config_responses_enabled_{true};
  std::array<std::uint8_t, 8U> e220_profile_{
      {0x00U, 0x00U, 0xE5U, 0xC3U, 0x46U, 0x00U, 0x00U, 0x00U}};
};

class FakeUsbSerial final {
 public:
  void begin(std::uint32_t baud) noexcept {
    baud_ = baud;
    begun_ = true;
  }

  bool isPlugged() const noexcept { return plugged_; }
  explicit operator bool() const noexcept {
    return begun_ && endpoint_ready_;
  }

  int available() const noexcept {
    return static_cast<int>(rx_bytes_.size());
  }

  int read() noexcept {
    if (rx_bytes_.empty()) {
      return -1;
    }
    const std::uint8_t value = rx_bytes_.front();
    rx_bytes_.pop_front();
    return static_cast<int>(value);
  }

  int availableForWrite() const noexcept {
    // ESP32 HWCDC reports TX-ring capacity independently of its cached
    // host-connected state.  In particular, a read-only host may have the
    // device physically plugged in while operator bool() is still false and
    // availableForWrite() is positive.
    if (!begun_) {
      return 0;
    }
    if (!available_for_write_script_.empty()) {
      const int scripted = available_for_write_script_.front();
      available_for_write_script_.pop_front();
      return scripted;
    }
    return available_for_write_;
  }

  std::size_t writeTxChecked(const std::uint8_t* bytes,
                             std::size_t size,
                             std::uint32_t expected_loss_epoch) noexcept {
    if (!begun_ || !endpoint_ready_ || bytes == nullptr ||
        expected_loss_epoch != loss_epoch_) {
      return 0U;
    }
    const std::size_t accepted = std::min(size, tx_checked_accept_limit_);
    if (accepted > 0U) {
      tx_bytes_.insert(tx_bytes_.end(), bytes, bytes + accepted);
      tx_write_sizes_.push_back(accepted);
    }
    return accepted;
  }

  // Host-only model of the macro-gated HWCDC diagnostic escape.  Acceptance
  // means the complete frame is retained in the device-side TX ring; it does
  // not claim host visibility until flushTxComplete observes the endpoint.
  std::size_t writeTxBootstrapFrameChecked(
      const std::uint8_t* bytes, std::size_t size,
      std::uint32_t expected_loss_epoch) noexcept {
    // The real diagnostic bootstrap must be able to retain its first complete
    // frame even when the IDF SOF watchdog reports a false-negative.  Host
    // visibility is still proved later by flushTxComplete(); enqueue itself
    // is guarded by the clean ring/epoch contract, not by plugged_.
    if (!begun_ || endpoint_ready_ || bytes == nullptr ||
        size != 63U ||
        expected_loss_epoch != loss_epoch_ ||
        !bootstrap_pending_bytes_.empty() ||
        available_for_write_ < static_cast<int>(size)) {
      return 0U;
    }
    bootstrap_pending_bytes_.insert(bootstrap_pending_bytes_.end(), bytes,
                                    bytes + size);
    tx_write_sizes_.push_back(size);
    return size;
  }

  std::size_t write(const std::uint8_t* bytes, std::size_t size) noexcept {
    if (!begun_ || !endpoint_ready_ || bytes == nullptr || size == 0U) {
      return 0U;
    }
    tx_bytes_.insert(tx_bytes_.end(), bytes, bytes + size);
    tx_write_sizes_.push_back(size);
    return size;
  }

  bool flushTxComplete(std::uint32_t timeout_ms,
                       std::uint32_t expected_loss_epoch) noexcept {
    ++flush_count_;
    last_flush_timeout_ms_ = timeout_ms;
    if (flush_consumes_timeout_) {
      fake_arduino::advance_time_ms(timeout_ms);
    }
    bool complete =
        timeout_ms > 0U && begun_ && endpoint_ready_ &&
        expected_loss_epoch == loss_epoch_;
    if (complete && flush_failures_remaining_ > 0U) {
      --flush_failures_remaining_;
      complete = false;
    }
    if (complete && !bootstrap_pending_bytes_.empty()) {
      tx_bytes_.insert(tx_bytes_.end(), bootstrap_pending_bytes_.begin(),
                       bootstrap_pending_bytes_.end());
      bootstrap_pending_bytes_.clear();
    }
    return complete;
  }

  std::uint32_t txLossEpoch() const noexcept {
    const std::uint32_t sampled = loss_epoch_;
    // Opt-in host-test race: return a valid sample, then model an ISR reset
    // before the caller's next operation. Default/reset leaves this disabled.
    if (epoch_samples_until_loss_ != 0U && --epoch_samples_until_loss_ == 0U) {
      const_cast<FakeUsbSerial*>(this)->simulate_tx_loss();
      epoch_sample_loss_triggered_ = true;
    }
    return sampled;
  }

  void simulate_tx_loss_after_epoch_sample(std::size_t samples) noexcept {
    epoch_samples_until_loss_ = samples;
    epoch_sample_loss_triggered_ = false;
  }
  bool epoch_sample_loss_triggered() const noexcept {
    return epoch_sample_loss_triggered_;
  }

  bool flushTxCompleteDiagnostic(std::uint32_t timeout_ms,
      std::uint32_t expected_epoch,
      vc_lora::experimental::R19HwcdcFlushCallEvidence& evidence) noexcept {
    const auto token = evidence.transaction_token;
    const auto attempt = evidence.attempt_id;
    evidence = {};
    evidence.schema = 1U; evidence.transaction_token = token; evidence.attempt_id = attempt;
    evidence.validity_flags = 0x1FU | (endpoint_ready_ ? 0x20U : 0U);
    evidence.timeout_ms = timeout_ms; evidence.expected_loss_epoch = expected_epoch;
    evidence.started_ms = static_cast<std::uint32_t>(fake_arduino::now_us / 1000U);
    const bool result = flushTxComplete(timeout_ms, expected_epoch);
    evidence.finished_ms = static_cast<std::uint32_t>(fake_arduino::now_us / 1000U);
    evidence.elapsed_ms = evidence.finished_ms - evidence.started_ms;
    evidence.terminal_reason = result ? 1U : (expected_epoch != loss_epoch_ ? 6U : 5U);
    evidence.raw_return = result ? 1U : 0U;
    evidence.observed_loss_epoch = loss_epoch_;
    evidence.snapshot_started_ms = evidence.finished_ms;
    evidence.snapshot_finished_ms = evidence.finished_ms;
    evidence.state_flags = result ? 0xFU : 0x17U;
    evidence.flush_blocker_mask = result ? 0U : 0x18U;
    return result;
  }

  void simulate_tx_loss() noexcept {
    ++loss_epoch_;
    bootstrap_pending_bytes_.clear();
  }

  void set_plugged(bool plugged) noexcept { plugged_ = plugged; }
  void set_endpoint_ready(bool ready) noexcept { endpoint_ready_ = ready; }
  void set_tx_checked_accept_limit(std::size_t limit) noexcept {
    tx_checked_accept_limit_ = limit;
  }
  void set_available_for_write(int bytes) noexcept {
    available_for_write_script_.clear();
    available_for_write_ = std::max(0, bytes);
  }
  void set_available_for_write_sequence(int first, int second) noexcept {
    available_for_write_script_.clear();
    available_for_write_script_.push_back(std::max(0, first));
    available_for_write_script_.push_back(std::max(0, second));
  }
  void set_flush_consumes_timeout(bool enabled) noexcept {
    flush_consumes_timeout_ = enabled;
  }
  void set_flush_failures(std::size_t count) noexcept {
    flush_failures_remaining_ = count;
  }

  void inject_rx(const std::uint8_t* bytes, std::size_t size) {
    if (bytes != nullptr) {
      rx_bytes_.insert(rx_bytes_.end(), bytes, bytes + size);
    }
  }

  const std::vector<std::uint8_t>& tx_bytes() const noexcept {
    return tx_bytes_;
  }
  const std::vector<std::size_t>& tx_write_sizes() const noexcept {
    return tx_write_sizes_;
  }
  std::size_t flush_count() const noexcept { return flush_count_; }
  std::uint32_t last_flush_timeout_ms() const noexcept {
    return last_flush_timeout_ms_;
  }
  std::uint32_t baud_rate() const noexcept { return baud_; }

  void reset_test_state() noexcept {
    begun_ = false;
    plugged_ = false;
    endpoint_ready_ = false;
    baud_ = 0U;
    loss_epoch_ = 0U;
    epoch_samples_until_loss_ = 0U;
    epoch_sample_loss_triggered_ = false;
    rx_bytes_.clear();
    tx_bytes_.clear();
    bootstrap_pending_bytes_.clear();
    tx_write_sizes_.clear();
    flush_count_ = 0U;
    tx_checked_accept_limit_ = std::numeric_limits<std::size_t>::max();
    available_for_write_ = 256;
    available_for_write_script_.clear();
    flush_consumes_timeout_ = false;
    flush_failures_remaining_ = 0U;
    last_flush_timeout_ms_ = 0U;
  }

 private:
  bool begun_{false};
  bool plugged_{false};
  bool endpoint_ready_{false};
  std::uint32_t baud_{0U};
  std::uint32_t loss_epoch_{0U};
  mutable std::size_t epoch_samples_until_loss_{0U};
  mutable bool epoch_sample_loss_triggered_{false};
  std::deque<std::uint8_t> rx_bytes_{};
  std::vector<std::uint8_t> tx_bytes_{};
  std::vector<std::uint8_t> bootstrap_pending_bytes_{};
  std::vector<std::size_t> tx_write_sizes_{};
  std::size_t flush_count_{0U};
  std::uint32_t last_flush_timeout_ms_{0U};
  std::size_t tx_checked_accept_limit_{
      std::numeric_limits<std::size_t>::max()};
  int available_for_write_{256};
  mutable std::deque<int> available_for_write_script_{};
  bool flush_consumes_timeout_{false};
  std::size_t flush_failures_remaining_{0U};
};

inline FakeUsbSerial Serial{};

namespace fake_arduino {

inline void reset_serial_state() noexcept { Serial.reset_test_state(); }

}  // namespace fake_arduino
