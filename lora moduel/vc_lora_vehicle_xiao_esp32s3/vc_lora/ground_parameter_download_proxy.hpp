#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/tdd_types.hpp"

namespace vc_lora {

// Disposition returned for an already CRC-validated MAVLink frame. Forward
// preserves the ordinary transparent bridge path. Consumed means the proxy
// intentionally coalesced the frame. Invalid is fail-safe evidence and must
// not be forwarded as a proxy transaction.
enum class GroundParameterProxyDisposition : std::uint8_t {
  Forward,
  Consumed,
  Invalid,
};

enum class GroundParameterProxyState : std::uint8_t {
  Idle,
  Ready,
  AwaitingValue,
  Backoff,
  Complete,
  Failed,
};

// IndexedRead is the conservative legacy policy which replaces #21 with one
// generated index-addressed #20 at a time. NativeStream leases the original
// #21 exactly once and observes the resulting ordered #22 stream. The latter
// removes the one-uplink-per-parameter dependency while preserving fixed
// storage, duplicate #21 coalescing, and USB-commit-gated progress.
enum class GroundParameterListStrategy : std::uint8_t {
  IndexedRead = 0U,
  NativeStream = 1U,
};

// First observed reason why a native #22 stream either changed to bounded
// indexed reads or failed closed. Numeric values are part of the diagnostic
// contract and therefore remain explicit.
enum class GroundParameterRecoveryReason : std::uint8_t {
  None = 0U,
  FutureIndex = 1U,
  InterValueTimeout = 2U,
  InvalidFrame = 3U,
  SourceMismatch = 4U,
  CountMismatch = 5U,
  UsbRejected = 6U,
};

struct GroundParameterRecoveryLatch {
  bool valid{false};
  GroundParameterRecoveryReason reason{GroundParameterRecoveryReason::None};
  std::uint16_t expected_index{0U};
  // 0xFFFF is the no-frame sentinel used by InterValueTimeout.
  std::uint16_t received_index{0xFFFFU};
  std::uint16_t received_count{0U};
  std::uint8_t received_sequence{0U};
  std::uint64_t observed_at_ms{0U};
};

struct GroundParameterDownloadProxyConfig {
  // Conservative per-stage bound. It applies independently to Ground FIFO
  // admission through descriptor dequeue, dequeue through explicit UL_DONE,
  // and the Pixhawk response plus following RF downlink opportunity.
  std::uint32_t value_timeout_ms{30000U};
  std::uint32_t retry_backoff_ms{1000U};
  std::uint32_t request_pacing_ms{500U};
  // Same-target Mission Planner retries are consumed during this fixed hold.
  // It is at least the production response timeout by default, so a stale
  // admitted #20/#22 cannot race an immediately following user operation.
  std::uint32_t terminal_hold_ms{30000U};
  std::uint32_t periodic_forward_interval_ms{30000U};
  std::uint8_t max_value_attempts{3U};
  GroundParameterListStrategy list_strategy{
      GroundParameterListStrategy::IndexedRead};
};

struct GroundParameterDownloadProxyDiagnostics {
  std::uint64_t sessions_started{0U};
  std::uint64_t sessions_completed{0U};
  std::uint64_t sessions_failed{0U};
  std::uint64_t sessions_cancelled{0U};
  std::uint64_t list_requests_coalesced{0U};
  std::uint64_t read_requests_coalesced{0U};
  std::uint64_t conflicting_requests_forwarded{0U};
  std::uint64_t terminal_requests_suppressed{0U};
  std::uint64_t parameter_sets_cancelled_session{0U};
  std::uint64_t parameter_sets_rejected{0U};
  // A rejection can quarantine future #22 frames, but bytes which entered
  // the USB FIFO before #23 arrived are physically unretractable. This count
  // makes each such conservative residual race window externally visible.
  std::uint64_t parameter_set_preexisting_usb_race_windows{0U};
  std::uint64_t parameter_set_quarantine_escalations{0U};
  std::uint64_t parameter_values_quarantined{0U};
  std::uint64_t stale_request_dequeues_observed{0U};
  std::uint64_t periodic_frames_coalesced{0U};
  std::uint64_t periodic_frames_forwarded{0U};
  std::uint64_t request_message_frames_forwarded{0U};
  std::uint64_t request_message_frames_coalesced{0U};
  std::uint64_t background_cache_full_frames{0U};
  std::uint64_t native_list_requests_leased{0U};
  std::uint64_t native_stream_poison_events{0U};
  std::uint64_t native_stream_values_quarantined{0U};
  // Same-target #22 traffic observed before the current request has a
  // physical commit cannot be causally attributed to that request. This
  // subset remains separately auditable from post-commit stream anomalies.
  std::uint64_t native_stream_precommit_values_quarantined{0U};
  std::uint64_t native_stream_old_duplicates_consumed{0U};
  std::uint64_t native_stream_future_values_quarantined{0U};
  std::uint64_t native_stream_gap_recoveries{0U};
  std::uint64_t native_stream_timeout_recoveries{0U};
  std::uint64_t native_stream_recovery_requests_generated{0U};
  std::uint64_t native_stream_recovery_request_tx_accepted{0U};
  std::uint64_t native_stream_recovery_values_seen{0U};
  std::uint64_t native_stream_recovery_values_usb_queued{0U};
  std::uint64_t requests_generated{0U};
  std::uint64_t request_retries{0U};
  std::uint64_t request_tx_accepted{0U};
  std::uint64_t request_tx_rejected{0U};
  std::uint64_t request_commit_timeouts{0U};
  std::uint64_t request_queue_progress_observed{0U};
  std::uint64_t request_dequeues_observed{0U};
  std::uint64_t value_timeouts{0U};
  std::uint64_t matching_values_seen{0U};
  std::uint64_t matching_values_usb_queued{0U};
  std::uint64_t matching_values_usb_rejected{0U};
  std::uint64_t unmatched_values_forwarded{0U};
  std::uint64_t count_mismatch_failures{0U};
  std::uint64_t invalid_frames{0U};
  std::uint64_t stale_completions{0U};
};

// Ground-owned PARAM_REQUEST_LIST proxy for the low-rate half-duplex link.
// It either converts #21 into index-based #20 requests or leases the original
// #21 once and observes its ordered native #22 stream. No dynamic storage is
// used; one byte-exact uplink lease is retained across rejected admissions.
class GroundParameterDownloadProxy {
 public:
  explicit GroundParameterDownloadProxy(
      GroundParameterDownloadProxyConfig config = {}) noexcept;

  static constexpr std::size_t request_capacity() noexcept { return 1U; }
  static constexpr std::size_t outstanding_capacity() noexcept {
    return request_capacity();
  }
  // Generated requests use an identity separate from Mission Planner (190)
  // and the Vehicle-local replacement heartbeat, giving the proxy its own
  // monotonic MAVLink sequence stream.
  static constexpr std::uint8_t generated_component_id() noexcept {
    return 191U;
  }

  GroundParameterProxyDisposition on_gcs_frame(
      const MavlinkFrame& frame, std::uint64_t now_ms) noexcept;

  // Must be called before Ground USB admission. It quarantines a late #22
  // which could otherwise falsely acknowledge an intentionally rejected
  // PARAM_SET. Only Forward may proceed to the USB FIFO.
  GroundParameterProxyDisposition preclassify_vehicle_frame(
      const MavlinkFrame& frame, std::uint64_t now_ms) noexcept;

  // Post-publication commit. usb_queued must be true only after this exact
  // validated frame crossed the Ground adapter's configured durable boundary
  // (the Phase 6 product uses its result-bearing HWCDC host-pickup fence).
  // A matching #22 never advances the index when that boundary failed.
  GroundParameterProxyDisposition on_vehicle_frame(
      const MavlinkFrame& frame, bool usb_queued,
      std::uint64_t now_ms) noexcept;

  void tick(std::uint64_t now_ms) noexcept;

  // A peek is a stable one-frame lease. Rejected completion deliberately
  // retains the same bytes and token for retry; Accepted completion starts
  // the bounded PARAM_VALUE timeout.
  bool peek_next_request(MavlinkFrame& frame,
                         std::uint32_t& token) const noexcept;
  // Records that this exact lease entered the Ground RF descriptor FIFO.
  // It lets a later fail-safe cancellation recognize the one frame which
  // cannot be removed and re-arm quarantine from its physical dequeue time.
  bool mark_request_admitted(std::uint32_t token,
                             std::uint64_t now_ms) noexcept;
  // While this lease waits behind an immutable FIFO prefix, each physically
  // committed prefix byte refreshes only the bounded no-progress watchdog.
  // Repeated GCS requests never call this API and therefore cannot keep a
  // stalled queue alive. Progress at the exact deadline is valid because the
  // firmware observes physical commits before tick().
  bool mark_request_queue_progress(std::uint32_t token,
                                   std::uint64_t now_ms) noexcept;
  // Full descriptor dequeue is a separate commit stage. This starts one
  // bounded wait for the matching explicit UL_DONE, but a lease which already
  // expired is never re-armed and can never be admitted a second time.
  bool mark_request_dequeued(std::uint32_t token,
                             std::uint64_t now_ms) noexcept;
  bool complete_request_tx(std::uint32_t token, TxResult result,
                           std::uint64_t now_ms) noexcept;
  bool request_admission_abandoned(std::uint32_t token) const noexcept {
    return token != 0U && token == abandoned_admitted_request_token_;
  }

  // cancel() is a soft session boundary and retains diagnostics. reset() is
  // the reboot/test boundary and also clears diagnostics and the sequence.
  void cancel() noexcept;
  void reset() noexcept;

  GroundParameterProxyState state() const noexcept { return state_; }
  GroundParameterListStrategy list_strategy() const noexcept {
    return config_.list_strategy;
  }
  bool active() const noexcept;
  bool native_stream_poisoned() const noexcept {
    return native_stream_poisoned_;
  }
  bool native_stream_recovery_active() const noexcept {
    return native_stream_recovery_active_;
  }
  const GroundParameterRecoveryLatch& recovery_latch() const noexcept {
    return recovery_latch_;
  }
  std::uint16_t expected_index() const noexcept { return expected_index_; }
  std::uint16_t param_count() const noexcept { return param_count_; }
  const GroundParameterDownloadProxyDiagnostics& diagnostics()
      const noexcept {
    return diagnostics_;
  }

 private:
  struct DataStreamCacheEntry {
    std::uint16_t message_rate{0U};
    std::uint8_t target_system{0U};
    std::uint8_t target_component{0U};
    std::uint8_t stream_id{0U};
    std::uint8_t start_stop{0U};
    bool used{false};
  };

  struct PeriodicCommandCacheEntry {
    std::array<std::uint8_t, 32U> semantic_payload{};
    bool used{false};
  };

  static constexpr std::size_t kBackgroundCacheCapacity = 8U;

  bool frame_is_valid(const MavlinkFrame& frame) const noexcept;
  bool start_session(const MavlinkFrame& frame,
                     std::uint64_t now_ms) noexcept;
  bool prepare_request(std::uint64_t now_ms) noexcept;
  void begin_parameter_set_quarantine(
      const MavlinkFrame& frame, std::uint64_t now_ms) noexcept;
  bool stale_response_quarantine_active(
      std::uint64_t now_ms) const noexcept;
  void clear_expired_parameter_set_quarantine(
      std::uint64_t now_ms) noexcept;
  bool response_expected() const noexcept;
  void latch_recovery_event(GroundParameterRecoveryReason reason,
                            const MavlinkFrame* frame,
                            std::uint64_t now_ms) noexcept;
  bool begin_native_stream_recovery(
      GroundParameterRecoveryReason reason, const MavlinkFrame* frame,
      std::uint64_t now_ms) noexcept;
  void fail_native_stream(GroundParameterRecoveryReason reason,
                          const MavlinkFrame* frame,
                          std::uint64_t now_ms) noexcept;
  void poison_native_stream(std::uint64_t now_ms) noexcept;
  std::uint32_t allocate_token() noexcept;
  void clear_session(GroundParameterProxyState terminal_state,
                     std::uint64_t now_ms) noexcept;
  void fail_session(std::uint64_t now_ms) noexcept;
  void reset_background_coalescing() noexcept;
  bool claim_background_forward(std::uint64_t now_ms,
                                bool immediate) noexcept;
  static std::uint64_t deadline_after(std::uint64_t now_ms,
                                      std::uint32_t delay_ms) noexcept;

  GroundParameterDownloadProxyConfig config_{};
  GroundParameterDownloadProxyDiagnostics diagnostics_{};
  GroundParameterRecoveryLatch recovery_latch_{};
  GroundParameterProxyState state_{GroundParameterProxyState::Idle};
  MavlinkFrame request_{};
  std::uint64_t deadline_ms_{0U};
  std::uint64_t admitted_request_deadline_ms_{0U};
  std::uint64_t stale_response_quarantine_deadline_ms_{0U};
  std::uint32_t request_token_{0U};
  std::uint32_t next_token_{1U};
  std::uint32_t admitted_request_token_{0U};
  std::uint32_t cancelled_admitted_request_token_{0U};
  std::uint32_t abandoned_admitted_request_token_{0U};
  std::uint16_t expected_index_{0U};
  std::uint16_t param_count_{0U};
  std::uint8_t target_system_{0U};
  std::uint8_t target_component_{0U};
  std::uint8_t sender_system_{0U};
  std::uint8_t sender_component_{0U};
  std::uint8_t quarantine_target_system_{0U};
  std::uint8_t quarantine_target_component_{0U};
  std::uint8_t next_sequence_{0U};
  std::uint8_t value_attempts_{0U};
  MavlinkVersion request_version_{MavlinkVersion::V2};
  std::array<std::uint8_t, 16U> quarantined_param_id_{};
  std::array<DataStreamCacheEntry, kBackgroundCacheCapacity>
      data_stream_cache_{};
  std::array<PeriodicCommandCacheEntry, kBackgroundCacheCapacity>
      periodic_command_cache_{};
  std::uint64_t background_retry_not_before_ms_{0U};
  std::uint64_t next_ping_forward_ms_{0U};
  std::uint64_t next_timesync_forward_ms_{0U};
  bool request_ready_{false};
  bool count_known_{false};
  bool backoff_is_retry_{false};
  bool autopilot_version_request_seen_{false};
  bool background_retry_armed_{false};
  bool ping_forwarded_{false};
  bool timesync_forwarded_{false};
  bool sequence_initialized_{false};
  bool parameter_set_quarantine_active_{false};
  bool quarantine_all_parameter_values_{false};
  bool admitted_request_dequeued_{false};
  bool native_stream_poisoned_{false};
  bool native_stream_recovery_active_{false};
};

}  // namespace vc_lora
