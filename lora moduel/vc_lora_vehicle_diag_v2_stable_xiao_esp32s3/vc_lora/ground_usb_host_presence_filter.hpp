#pragma once

#include <algorithm>
#include <cstdint>

namespace vc_lora {

// Hardware CDC host presence can briefly read false while the host keeps the
// COM handle open. Physical writes must stop on the raw signal immediately,
// but destructive disconnect handling is delayed until absence is continuous.
struct GroundUsbHostPresenceFilterConfig {
  std::uint32_t disconnect_confirm_ms{50U};
};

enum class GroundUsbHostPresenceUpdate : std::uint8_t {
  Stable,
  LossPending,
  GlitchFiltered,
  ConfirmedDisconnected,
  ConfirmedConnected,
};

struct GroundUsbHostPresenceFilterDiagnostics {
  std::uint64_t raw_loss_edges{0U};
  std::uint64_t raw_recovery_edges{0U};
  std::uint64_t filtered_loss_pulses{0U};
  std::uint64_t confirmed_disconnects{0U};
  std::uint64_t confirmed_connects{0U};
  std::uint64_t last_filtered_low_ms{0U};
  std::uint64_t max_filtered_low_ms{0U};
};

class GroundUsbHostPresenceFilter {
 public:
  GroundUsbHostPresenceFilter() noexcept = default;

  explicit GroundUsbHostPresenceFilter(
      const GroundUsbHostPresenceFilterConfig& config) noexcept
      : config_(config) {}

  // Boot-time absence is not granted a grace period: there is no established
  // connection or queued traffic to preserve yet.
  void reset(bool raw_present, std::uint64_t now_ms) noexcept {
    raw_present_ = raw_present;
    confirmed_present_ = raw_present;
    loss_pending_ = false;
    loss_started_ms_ = now_ms;
    initialized_ = true;
    diagnostics_ = {};
  }

  GroundUsbHostPresenceUpdate observe(bool raw_present,
                                      std::uint64_t now_ms) noexcept {
    if (!initialized_) {
      reset(raw_present, now_ms);
      return GroundUsbHostPresenceUpdate::Stable;
    }

    if (raw_present != raw_present_) {
      if (raw_present) {
        ++diagnostics_.raw_recovery_edges;
      } else {
        ++diagnostics_.raw_loss_edges;
      }
      raw_present_ = raw_present;
    }

    if (raw_present) {
      if (loss_pending_) {
        const std::uint64_t low_ms = elapsed_since(loss_started_ms_, now_ms);
        loss_pending_ = false;
        ++diagnostics_.filtered_loss_pulses;
        diagnostics_.last_filtered_low_ms = low_ms;
        diagnostics_.max_filtered_low_ms =
            std::max(diagnostics_.max_filtered_low_ms, low_ms);
        return GroundUsbHostPresenceUpdate::GlitchFiltered;
      }
      if (!confirmed_present_) {
        confirmed_present_ = true;
        ++diagnostics_.confirmed_connects;
        return GroundUsbHostPresenceUpdate::ConfirmedConnected;
      }
      return GroundUsbHostPresenceUpdate::Stable;
    }

    if (!confirmed_present_) {
      loss_pending_ = false;
      return GroundUsbHostPresenceUpdate::Stable;
    }
    if (!loss_pending_) {
      loss_pending_ = true;
      loss_started_ms_ = now_ms;
    }
    if (now_ms < loss_started_ms_) {
      // A reset or anomalous clock regression must never inherit elapsed time
      // from the old epoch. Restart the full confirmation window fail-safe.
      loss_started_ms_ = now_ms;
      return GroundUsbHostPresenceUpdate::LossPending;
    }
    if (elapsed_since(loss_started_ms_, now_ms) <
        config_.disconnect_confirm_ms) {
      return GroundUsbHostPresenceUpdate::LossPending;
    }

    loss_pending_ = false;
    confirmed_present_ = false;
    ++diagnostics_.confirmed_disconnects;
    return GroundUsbHostPresenceUpdate::ConfirmedDisconnected;
  }

  bool raw_present() const noexcept { return raw_present_; }
  bool confirmed_present() const noexcept { return confirmed_present_; }
  bool loss_pending() const noexcept { return loss_pending_; }

  const GroundUsbHostPresenceFilterDiagnostics& diagnostics() const noexcept {
    return diagnostics_;
  }

 private:
  static std::uint64_t elapsed_since(std::uint64_t started_ms,
                                     std::uint64_t now_ms) noexcept {
    return now_ms >= started_ms ? now_ms - started_ms : 0U;
  }

  GroundUsbHostPresenceFilterConfig config_{};
  GroundUsbHostPresenceFilterDiagnostics diagnostics_{};
  std::uint64_t loss_started_ms_{0U};
  bool raw_present_{false};
  bool confirmed_present_{false};
  bool loss_pending_{false};
  bool initialized_{false};
};

}  // namespace vc_lora
