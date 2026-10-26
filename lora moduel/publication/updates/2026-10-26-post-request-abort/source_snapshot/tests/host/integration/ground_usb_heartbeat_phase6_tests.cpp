#include "test_support.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

#include "vc_lora/embedded_io_adapter.hpp"
#include "vc_lora/ground_parameter_download_proxy.hpp"
#include "vc_lora/ground_usb_heartbeat_pacer.hpp"
#include "vc_lora/ground_usb_host_presence_filter.hpp"
#include "vc_lora/mavlink_frame.hpp"

#if __has_include("vc_lora/ground_usb_ordered_frame_backlog.hpp")
#include "vc_lora/ground_usb_ordered_frame_backlog.hpp"
#define VC_LORA_HAS_GROUND_USB_ORDERED_FRAME_BACKLOG 1
#else
#define VC_LORA_HAS_GROUND_USB_ORDERED_FRAME_BACKLOG 0
namespace vc_lora {
constexpr std::size_t kGroundUsbOrderedBacklogBytes = 0U;
constexpr std::size_t kGroundUsbOrderedBacklogFrames = 0U;
enum class GroundUsbOrderedBacklogStatus : std::uint8_t {
  Queued,
  Invalid,
  Overflow,
};
struct GroundUsbOrderedBacklogDiagnostics {
  std::uint64_t frames_queued{0U};
  std::uint64_t frames_released{0U};
  std::uint64_t overflow_frames{0U};
  std::uint64_t overflow_bytes{0U};
  std::size_t max_bytes{0U};
  std::size_t max_frames{0U};
};
template <std::size_t ByteCapacity = 1U,
          std::size_t FrameCapacity = 1U>
class GroundUsbOrderedFrameBacklog {
 public:
  GroundUsbOrderedBacklogStatus enqueue(const MavlinkFrame&, bool) noexcept {
    return GroundUsbOrderedBacklogStatus::Invalid;
  }
  bool peek(MavlinkFrame&, bool&) const noexcept { return false; }
  bool pop_front() noexcept { return false; }
  void reset() noexcept {}
  bool empty() const noexcept { return true; }
  std::size_t queued_bytes() const noexcept { return 0U; }
  std::size_t queued_frames() const noexcept { return 0U; }
  static constexpr std::size_t byte_capacity() noexcept {
    return ByteCapacity;
  }
  static constexpr std::size_t frame_capacity() noexcept {
    return FrameCapacity;
  }
  const GroundUsbOrderedBacklogDiagnostics& diagnostics() const noexcept {
    return diagnostics_;
  }

 private:
  GroundUsbOrderedBacklogDiagnostics diagnostics_{};
};
}  // namespace vc_lora
#endif

namespace vc_lora::test {
namespace {

constexpr std::uint64_t kUsbHeartbeatLimitMs = 2500U;
constexpr std::uint64_t kSoftDueMs = 2200U;
constexpr std::uint64_t kLoopJitterMs = 100U;
constexpr std::uint64_t kCurrentFrameBlockMs = 49U;
constexpr std::uint64_t kHeartbeatWriteMs = 6U;
constexpr std::uint64_t kTransportFlushMs = 100U;

template <typename T, typename = void>
struct HasMarkEmitAdmitted : std::false_type {};

template <typename T>
struct HasMarkEmitAdmitted<
    T, std::void_t<decltype(std::declval<T&>().mark_emit_admitted(
           std::declval<std::uint32_t>()))>> : std::true_type {};

template <typename Pacer>
bool mark_emit_admitted_if_present(Pacer& pacer,
                                   std::uint32_t token) noexcept {
  if constexpr (HasMarkEmitAdmitted<Pacer>::value) {
    return pacer.mark_emit_admitted(token);
  }
  (void)pacer;
  (void)token;
  return false;
}

template <typename T, typename = void>
struct HasAbortPendingEmit : std::false_type {};

template <typename T>
struct HasAbortPendingEmit<
    T, std::void_t<decltype(std::declval<T&>().abort_pending_emit(
           std::declval<std::uint32_t>()))>> : std::true_type {};

template <typename Pacer>
bool abort_pending_emit_if_present(Pacer& pacer,
                                   std::uint32_t token) noexcept {
  if constexpr (HasAbortPendingEmit<Pacer>::value) {
    return pacer.abort_pending_emit(token);
  }
  (void)pacer;
  (void)token;
  return false;
}

GroundUsbHeartbeatPacerConfig pacer_config() noexcept {
  GroundUsbHeartbeatPacerConfig config{};
  config.soft_due_ms = static_cast<std::uint32_t>(kSoftDueMs);
  config.hard_max_age_ms = 2400U;
  config.loop_jitter_budget_ms = static_cast<std::uint32_t>(kLoopJitterMs);
  config.physical_write_budget_ms =
      static_cast<std::uint32_t>(kHeartbeatWriteMs);
  config.transport_flush_budget_ms =
      static_cast<std::uint32_t>(kTransportFlushMs);
  config.supply_window_ms = 6200U;
  config.minimum_supply_frames = 3U;
  config.target_system_id = 1U;
  config.target_component_id = 1U;
  return config;
}

MavlinkFrame heartbeat(std::uint8_t sequence,
                       std::uint8_t marker) noexcept;
MavlinkFrame param_value(std::uint8_t sequence,
                         std::uint16_t index,
                         std::uint16_t count) noexcept;

void check_host_presence_filter(TestReport& report) {
  GroundUsbHostPresenceFilterConfig config{};
  config.disconnect_confirm_ms = 50U;
  GroundUsbHostPresenceFilter filter{config};
  filter.reset(true, 100U);
  report.check(filter.raw_present() && filter.confirmed_present() &&
                   !filter.loss_pending(),
               "connected reset did not establish raw/confirmed presence");

  const auto check_short_pulse =
      [&filter, &report](std::uint64_t start_ms,
                         std::uint64_t width_ms) {
        report.check(
            filter.observe(false, start_ms) ==
                    GroundUsbHostPresenceUpdate::LossPending &&
                !filter.raw_present() && filter.confirmed_present() &&
                filter.loss_pending(),
            "raw loss did not immediately pause behind a pending loss");
        report.check(
            filter.observe(true, start_ms + width_ms) ==
                    GroundUsbHostPresenceUpdate::GlitchFiltered &&
                filter.raw_present() && filter.confirmed_present() &&
                !filter.loss_pending(),
            "sub-threshold raw loss was not cancelled without disconnect");
      };

  check_short_pulse(1'000U, 1U);
  check_short_pulse(2'000U, 15U);
  check_short_pulse(3'000U, 49U);
  report.check(filter.diagnostics().filtered_loss_pulses == 3U &&
                   filter.diagnostics().confirmed_disconnects == 0U &&
                   filter.diagnostics().last_filtered_low_ms == 49U &&
                   filter.diagnostics().max_filtered_low_ms == 49U,
               "short-loss diagnostics did not preserve the 49-ms boundary");

  // Separate false pulses must restart, rather than accumulate, the timer.
  report.check(filter.observe(false, 4'000U) ==
                       GroundUsbHostPresenceUpdate::LossPending &&
                   filter.observe(true, 4'030U) ==
                       GroundUsbHostPresenceUpdate::GlitchFiltered &&
                   filter.observe(false, 4'040U) ==
                       GroundUsbHostPresenceUpdate::LossPending &&
                   filter.observe(false, 4'080U) ==
                       GroundUsbHostPresenceUpdate::LossPending &&
                   filter.observe(true, 4'080U) ==
                       GroundUsbHostPresenceUpdate::GlitchFiltered &&
                   filter.confirmed_present(),
               "separate raw-loss pulses accumulated into a disconnect");

  filter.reset(true, 5'000U);
  report.check(filter.observe(false, 6'000U) ==
                       GroundUsbHostPresenceUpdate::LossPending &&
                   filter.observe(false, 6'049U) ==
                       GroundUsbHostPresenceUpdate::LossPending &&
                   filter.confirmed_present() && filter.loss_pending(),
               "49-ms loss crossed the 50-ms confirmation boundary");
  report.check(filter.observe(false, 6'050U) ==
                       GroundUsbHostPresenceUpdate::ConfirmedDisconnected &&
                   !filter.confirmed_present() && !filter.loss_pending() &&
                   filter.diagnostics().confirmed_disconnects == 1U,
               "50-ms continuous loss was not confirmed exactly once");
  report.check(filter.observe(false, 6'500U) ==
                       GroundUsbHostPresenceUpdate::Stable &&
                   filter.diagnostics().confirmed_disconnects == 1U,
               "continued raw absence duplicated the confirmed disconnect");
  report.check(filter.observe(true, 6'501U) ==
                       GroundUsbHostPresenceUpdate::ConfirmedConnected &&
                   filter.confirmed_present() &&
                   filter.diagnostics().confirmed_connects == 1U,
               "raw recovery did not reconnect immediately and exactly once");
  report.check(filter.observe(false, 7'000U) ==
                       GroundUsbHostPresenceUpdate::LossPending &&
                   filter.observe(false, 7'049U) ==
                       GroundUsbHostPresenceUpdate::LossPending &&
                   filter.observe(false, 7'050U) ==
                       GroundUsbHostPresenceUpdate::ConfirmedDisconnected &&
                   filter.diagnostics().confirmed_disconnects == 2U,
               "reconnected host did not require a new full 50-ms loss");

  // Confirmation requires a still-false sample at the boundary. A true
  // sample at or beyond 50 ms cancels the loss because writes were already
  // paused while the raw signal was false and there is nothing left to tear
  // down after recovery.
  GroundUsbHostPresenceFilter recovered_at_boundary{config};
  recovered_at_boundary.reset(true, 0U);
  report.check(recovered_at_boundary.observe(false, 8'000U) ==
                       GroundUsbHostPresenceUpdate::LossPending &&
                   recovered_at_boundary.observe(true, 8'050U) ==
                       GroundUsbHostPresenceUpdate::GlitchFiltered &&
                   recovered_at_boundary.confirmed_present() &&
                   recovered_at_boundary.diagnostics().confirmed_disconnects ==
                       0U &&
                   recovered_at_boundary.diagnostics().last_filtered_low_ms ==
                       50U,
               "recovery at the boundary performed an unobserved disconnect");

  GroundUsbHostPresenceFilter regressed_clock{config};
  regressed_clock.reset(true, 0U);
  report.check(regressed_clock.observe(false, 9'000U) ==
                       GroundUsbHostPresenceUpdate::LossPending &&
                   regressed_clock.observe(false, 8'990U) ==
                       GroundUsbHostPresenceUpdate::LossPending &&
                   regressed_clock.observe(false, 9'039U) ==
                       GroundUsbHostPresenceUpdate::LossPending &&
                   regressed_clock.observe(false, 9'040U) ==
                       GroundUsbHostPresenceUpdate::ConfirmedDisconnected,
               "clock regression did not restart the confirmation window");

  GroundUsbHostPresenceFilter boot_absent{config};
  boot_absent.reset(false, 7'000U);
  report.check(!boot_absent.raw_present() &&
                   !boot_absent.confirmed_present() &&
                   !boot_absent.loss_pending() &&
                   boot_absent.observe(false, 8'000U) ==
                       GroundUsbHostPresenceUpdate::Stable,
               "boot-time raw absence incorrectly received a grace period");
  report.check(boot_absent.observe(true, 8'001U) ==
                       GroundUsbHostPresenceUpdate::ConfirmedConnected &&
                   boot_absent.confirmed_present(),
               "boot-absent filter did not reconnect immediately");

  // Reproduce the seven 2--15 ms false pulses measured in the sealed HIL run.
  GroundUsbHostPresenceFilter measured_pulses{config};
  measured_pulses.reset(true, 0U);
  constexpr std::array<std::uint64_t, 7U> starts{{
      10'355U, 44'142U, 78'343U, 113'125U,
      148'344U, 183'967U, 219'888U}};
  constexpr std::array<std::uint64_t, 7U> widths{{
      2U, 5U, 8U, 3U, 2U, 6U, 15U}};
  for (std::size_t index = 0U; index < starts.size(); ++index) {
    report.check(measured_pulses.observe(false, starts[index]) ==
                         GroundUsbHostPresenceUpdate::LossPending &&
                     measured_pulses.observe(
                         true, starts[index] + widths[index]) ==
                         GroundUsbHostPresenceUpdate::GlitchFiltered,
                 "measured raw-loss pulse was not filtered");
  }
  report.check(measured_pulses.confirmed_present() &&
                   measured_pulses.diagnostics().raw_loss_edges == 7U &&
                   measured_pulses.diagnostics().raw_recovery_edges == 7U &&
                   measured_pulses.diagnostics().filtered_loss_pulses == 7U &&
                   measured_pulses.diagnostics().confirmed_disconnects == 0U,
               "sealed-HIL pulse regression produced a false disconnect");

  // Integration model: raw presence controls the physical writer, confirmed
  // presence controls admission, and only the confirmed-disconnect update is
  // allowed to invoke the destructive pacer/backlog callback.
  GroundUsbHostPresenceFilter integrated_filter{config};
  GroundUsbHeartbeatPacer integrated_pacer{pacer_config()};
  GroundUsbOrderedFrameBacklog<> integrated_backlog{};
  integrated_filter.reset(true, 0U);
  integrated_pacer.set_usb_connected(true, 0U);
  const MavlinkFrame held = heartbeat(0xD1U, 0x51U);
  const MavlinkFrame behind = param_value(0xD2U, 0U, 2U);
  report.check(integrated_pacer.ingest(held, 100U) ==
                       GroundUsbHeartbeatIngestStatus::Held &&
                   integrated_backlog.enqueue(held, true) ==
                       GroundUsbOrderedBacklogStatus::Queued &&
                   integrated_backlog.enqueue(behind, false) ==
                       GroundUsbOrderedBacklogStatus::Queued,
               "host-filter integration fixture was not queued");
  const GroundUsbHostPresenceUpdate short_loss =
      integrated_filter.observe(false, 1'000U);
  const bool writer_enabled_during_loss =
      integrated_filter.raw_present() && true;
  report.check(short_loss == GroundUsbHostPresenceUpdate::LossPending &&
                   !writer_enabled_during_loss &&
                   integrated_filter.confirmed_present() &&
                   integrated_backlog.queued_frames() == 2U &&
                   integrated_pacer.queued() == 1U &&
                   integrated_pacer.diagnostics().usb_disconnect_events == 0U,
               "short raw loss did not stop writes while preserving admission");
  report.check(integrated_filter.observe(true, 1'015U) ==
                       GroundUsbHostPresenceUpdate::GlitchFiltered &&
                   integrated_backlog.diagnostics().discarded_frames == 0U &&
                   integrated_backlog.diagnostics().discarded_bytes == 0U &&
                   integrated_pacer.diagnostics().usb_disconnect_events == 0U,
               "short raw recovery triggered destructive side effects");
  MavlinkFrame retained{};
  bool retained_marker = false;
  const auto same_frame = [](const MavlinkFrame& left,
                             const MavlinkFrame& right) noexcept {
    return left.size == right.size && left.size > 0U &&
           std::equal(left.bytes.begin(), left.bytes.begin() + left.size,
                      right.bytes.begin());
  };
  report.check(integrated_backlog.peek(retained, retained_marker) &&
                   retained_marker && same_frame(held, retained) &&
                   integrated_backlog.pop_front() &&
                   integrated_backlog.peek(retained, retained_marker) &&
                   !retained_marker &&
                   same_frame(behind, retained),
               "short raw loss changed the exact retained frame order");

  // Refill the marker consumed only by the inspection above, then model the
  // production confirmed-disconnect callback exactly once.
  integrated_backlog.reset();
  report.check(integrated_backlog.enqueue(held, true) ==
                       GroundUsbOrderedBacklogStatus::Queued &&
                   integrated_backlog.enqueue(behind, false) ==
                       GroundUsbOrderedBacklogStatus::Queued,
               "confirmed-loss fixture refill failed");
  report.check(integrated_filter.observe(false, 2'000U) ==
                       GroundUsbHostPresenceUpdate::LossPending,
               "sustained integration loss did not enter pending state");
  const GroundUsbHostPresenceUpdate confirmed_loss =
      integrated_filter.observe(false, 2'050U);
  if (confirmed_loss ==
      GroundUsbHostPresenceUpdate::ConfirmedDisconnected) {
    integrated_pacer.set_usb_connected(false, 2'050U);
    integrated_backlog.discard_all();
    (void)integrated_pacer.discard_for_order(2'050U);
  }
  const GroundUsbHostPresenceUpdate repeated_absence =
      integrated_filter.observe(false, 2'100U);
  if (repeated_absence ==
      GroundUsbHostPresenceUpdate::ConfirmedDisconnected) {
    integrated_pacer.set_usb_connected(false, 2'100U);
    integrated_backlog.discard_all();
    (void)integrated_pacer.discard_for_order(2'100U);
  }
  report.check(confirmed_loss ==
                       GroundUsbHostPresenceUpdate::ConfirmedDisconnected &&
                   repeated_absence == GroundUsbHostPresenceUpdate::Stable &&
                   integrated_backlog.empty() &&
                   integrated_backlog.diagnostics().discarded_frames == 2U &&
                   integrated_backlog.diagnostics().discarded_bytes ==
                       held.size + behind.size &&
                   integrated_pacer.queued() == 0U &&
                   integrated_pacer.diagnostics().usb_disconnect_events == 1U &&
                   integrated_pacer.diagnostics().order_preservation_drops ==
                       1U,
               "confirmed loss did not invoke each destructive effect once");
  report.detail =
      "raw loss pauses immediately; only 50-ms continuous absence changes "
      "confirmed host presence, while the seven measured pulses are filtered";
}

MavlinkFrame heartbeat(std::uint8_t sequence,
                       std::uint8_t marker) noexcept {
  std::array<std::uint8_t, 9U> payload{};
  payload[0U] = marker;
  payload[4U] = 2U;
  payload[5U] = 3U;
  payload[7U] = 4U;
  payload[8U] = 3U;
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 1U, 1U, 0U, payload.data(),
                          payload.size(), frame);
  return frame;
}

MavlinkFrame foreign_heartbeat(std::uint8_t sequence,
                               std::uint8_t marker) noexcept {
  std::array<std::uint8_t, 9U> payload{};
  payload[0U] = marker;
  payload[4U] = 2U;
  payload[5U] = 3U;
  payload[7U] = 4U;
  payload[8U] = 3U;
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 42U, 1U, 0U, payload.data(),
                          payload.size(), frame);
  return frame;
}

MavlinkFrame signed_heartbeat(std::uint8_t sequence,
                              std::uint8_t marker) noexcept {
  std::array<std::uint8_t, 9U> payload{};
  payload[0U] = marker;
  payload[4U] = 2U;
  payload[5U] = 3U;
  payload[7U] = 4U;
  payload[8U] = 3U;
  std::array<std::uint8_t, kMavlinkSignatureBytes> signature{};
  for (std::size_t index = 0U; index < signature.size(); ++index) {
    signature[index] = static_cast<std::uint8_t>(0x80U + index);
  }
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 1U, 1U, 0U, payload.data(),
                          payload.size(), frame, 0x01U, 0U,
                          signature.data());
  return frame;
}

MavlinkFrame timesync(std::uint8_t sequence,
                      std::uint8_t marker) noexcept {
  std::array<std::uint8_t, 16U> payload{};
  payload[0U] = marker;
  payload[15U] = static_cast<std::uint8_t>(marker ^ 0x5AU);
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 1U, 1U, 111U, payload.data(),
                          payload.size(), frame);
  return frame;
}

MavlinkFrame timesync_v1(std::uint8_t sequence,
                         std::uint8_t marker) noexcept {
  std::array<std::uint8_t, 16U> payload{};
  payload[0U] = marker;
  payload[15U] = static_cast<std::uint8_t>(marker ^ 0xA5U);
  MavlinkFrame frame{};
  (void)encode_mavlink_v1(sequence, 1U, 1U, 111U, payload.data(),
                          payload.size(), frame);
  return frame;
}

MavlinkFrame param_request_list(std::uint8_t sequence) noexcept {
  constexpr std::array<std::uint8_t, 2U> payload{{1U, 1U}};
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 255U, 190U, 21U, payload.data(),
                          payload.size(), frame);
  return frame;
}

MavlinkFrame param_value(std::uint8_t sequence,
                         std::uint16_t index,
                         std::uint16_t count) noexcept {
  std::array<std::uint8_t, 25U> payload{};
  constexpr float value = 57.0F;
  std::memcpy(payload.data(), &value, sizeof(value));
  payload[4U] = static_cast<std::uint8_t>(count & 0xFFU);
  payload[5U] = static_cast<std::uint8_t>((count >> 8U) & 0xFFU);
  payload[6U] = static_cast<std::uint8_t>(index & 0xFFU);
  payload[7U] = static_cast<std::uint8_t>((index >> 8U) & 0xFFU);
  constexpr char id[] = "SERIAL1_BAUD";
  std::copy_n(reinterpret_cast<const std::uint8_t*>(id), sizeof(id) - 1U,
              payload.begin() + 8U);
  payload[24U] = 9U;
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 1U, 1U, 22U, payload.data(),
                          payload.size(), frame);
  return frame;
}

bool same_wire(const MavlinkFrame& frame,
               const std::vector<std::uint8_t>& wire,
               std::size_t offset) noexcept {
  return offset <= wire.size() && frame.size <= wire.size() - offset &&
         std::equal(frame.bytes.begin(), frame.bytes.begin() + frame.size,
                    wire.begin() + static_cast<std::ptrdiff_t>(offset));
}

template <typename Endpoint>
bool admit_paced_heartbeat(
    GroundUsbHeartbeatPacer& pacer, Endpoint& endpoint,
    const GroundUsbHeartbeatLease& lease, std::uint64_t& commit_goal,
    TestReport& report) {
  auto& egress = endpoint.egress();
  const std::uint64_t committed_before = egress.stats().bytes_committed;
  const std::size_t queued_before = egress.queued_bytes();
  const auto status = endpoint.admit_validated_frame(lease.frame);
  if (status != ValidatedLocalIngressStatus::QueuedFrame) {
    (void)pacer.complete_emit(lease.token, TxResult::Rejected,
                              lease.rf_received_ms);
    return false;
  }
  commit_goal = committed_before + queued_before + lease.frame.size;
  const bool marked = mark_emit_admitted_if_present(pacer, lease.token);
  report.check(marked,
               "RED: pacer lacks mark_emit_admitted admission/commit split");
  return marked;
}

template <typename Endpoint>
void drain_one_physical_write(
    Endpoint& endpoint, std::vector<std::uint8_t>& wire,
    GroundUsbHeartbeatPacer& pacer, bool& commit_active,
    std::uint32_t& commit_token, std::uint64_t commit_goal,
    std::uint64_t completed_ms, std::size_t accept_limit,
    TestReport& report) {
  auto& egress = endpoint.egress();
  std::array<std::uint8_t, kEmbeddedPhysicalWriteBytes> staged{};
  const std::size_t staged_size = egress.peek(staged.data(), staged.size());
  report.check(staged_size > 0U, "USB egress produced no physical prefix");
  if (staged_size == 0U) {
    return;
  }
  const std::size_t accepted = std::min(staged_size, accept_limit);
  wire.insert(wire.end(), staged.begin(), staged.begin() + accepted);
  const UartWriteProgress progress = egress.complete_write(accepted);
  report.check(progress != UartWriteProgress::Invalid,
               "USB egress rejected a valid physical commit");
  if (commit_active && egress.stats().bytes_committed >= commit_goal) {
    report.check(pacer.complete_emit(commit_token, TxResult::Accepted,
                                     completed_ms),
                 "physical commit goal did not complete paced HB");
    commit_active = false;
    commit_token = 0U;
  }
}

void check_order_and_commit(TestReport& report) {
  report.check(HasMarkEmitAdmitted<GroundUsbHeartbeatPacer>::value,
               "RED: mark_emit_admitted API is missing");
  if constexpr (!HasMarkEmitAdmitted<GroundUsbHeartbeatPacer>::value) {
    return;
  }

  using Endpoint = MavlinkValidatedLocalEgressAdapter<
      96U, kEmbeddedPhysicalWriteBytes,
      LocalEgressOverflowPolicy::DropNewestFrame>;
  GroundUsbHeartbeatPacer pacer{pacer_config()};
  GroundUsbOrderedFrameBacklog<> ordered{};
  Endpoint endpoint{};
  pacer.set_usb_connected(true, 0U);
  const MavlinkFrame held = heartbeat(0x31U, 0xA1U);
  const MavlinkFrame later = timesync(0x32U, 0xB2U);
  report.check(pacer.ingest(held, 1000U) ==
                   GroundUsbHeartbeatIngestStatus::Held,
               "primary RF heartbeat was not reserved");

  GroundUsbHeartbeatLease lease{};
  report.check(pacer.select_before_next_frame(1500U, lease) ==
                   GroundUsbHeartbeatBarrierStatus::LeaseReady,
               "held heartbeat did not acquire the next-frame barrier");
  std::uint64_t commit_goal = 0U;
  report.check(admit_paced_heartbeat(pacer, endpoint, lease, commit_goal,
                                     report),
               "held heartbeat was not atomically admitted first");
  report.check(pacer.ingest(held, 1501U) ==
                   GroundUsbHeartbeatIngestStatus::Held &&
                   pacer.queued() == 0U,
               "inflight exact duplicate was retained for a second emit");
  report.check(ordered.enqueue(later, false) ==
                       GroundUsbOrderedBacklogStatus::Queued &&
                   endpoint.egress().queued_bytes() == held.size,
               "later frame was not isolated behind paced heartbeat commit");
  report.check(commit_goal == held.size,
               "heartbeat commit goal included a later enqueue");
  report.check(pacer.diagnostics().emitted_heartbeats == 0U,
               "FIFO admission was incorrectly counted as physical emit");

  bool commit_active = true;
  std::uint32_t commit_token = lease.token;
  std::vector<std::uint8_t> wire{};
  drain_one_physical_write(endpoint, wire, pacer, commit_active,
                           commit_token, commit_goal, 1550U,
                           held.size - 1U, report);
  report.check(pacer.diagnostics().emitted_heartbeats == 0U &&
                   endpoint.egress().stats().bytes_committed == 0U,
               "partial writer acceptance completed heartbeat early");
  drain_one_physical_write(endpoint, wire, pacer, commit_active,
                           commit_token, commit_goal, 1556U,
                           kEmbeddedPhysicalWriteBytes, report);
  report.check(!commit_active &&
                   pacer.diagnostics().emitted_heartbeats == 1U,
                "paced heartbeat was not counted at its fixed commit goal");
  MavlinkFrame ordered_front{};
  bool ordered_marker = true;
  report.check(ordered.peek(ordered_front, ordered_marker) &&
                   !ordered_marker &&
                   endpoint.admit_validated_frame(ordered_front) ==
                       ValidatedLocalIngressStatus::QueuedFrame &&
                   ordered.pop_front(),
               "later frame was not released after HB publication");
  while (!endpoint.egress().empty()) {
    drain_one_physical_write(endpoint, wire, pacer, commit_active,
                             commit_token, commit_goal, 1557U,
                             kEmbeddedPhysicalWriteBytes, report);
  }
  report.check(same_wire(held, wire, 0U) &&
                   same_wire(later, wire, held.size) && ordered.empty(),
               "HB/non-HB bytes were re-encoded, duplicated, or reordered");

  // A replay of the just-emitted A can arrive while a different B marker and
  // its telemetry are held. Suppress only A; B's paired reserve must survive.
  GroundUsbHeartbeatPacer replay_pacer{pacer_config()};
  GroundUsbOrderedFrameBacklog<> replay_backlog{};
  replay_pacer.set_usb_connected(true, 0U);
  const MavlinkFrame emitted_a = heartbeat(0x33U, 0xA3U);
  const MavlinkFrame held_b = heartbeat(0x34U, 0xA4U);
  const MavlinkFrame behind_b = timesync(0x35U, 0xB5U);
  GroundUsbHeartbeatLease replay_lease{};
  report.check(replay_pacer.ingest(emitted_a, 0U) ==
                   GroundUsbHeartbeatIngestStatus::Held &&
                   replay_pacer.select_due(0U, false, replay_lease) &&
                   replay_pacer.complete_emit(replay_lease.token,
                                               TxResult::Accepted, 0U) &&
                   replay_pacer.ingest(held_b, 1000U) ==
                       GroundUsbHeartbeatIngestStatus::Held &&
                   replay_backlog.enqueue(held_b, true) ==
                       GroundUsbOrderedBacklogStatus::Queued &&
                   replay_backlog.enqueue(behind_b, false) ==
                       GroundUsbOrderedBacklogStatus::Queued,
               "recent-replay fixture did not retain B pair");
  const std::uint64_t duplicate_before =
      replay_pacer.diagnostics().duplicate_ingests;
  report.check(!replay_pacer.contains_wire_heartbeat(emitted_a) &&
                   replay_pacer.ingest(emitted_a, 1001U) ==
                       GroundUsbHeartbeatIngestStatus::Held &&
                   replay_pacer.queued() == 1U &&
                   replay_pacer.diagnostics().duplicate_ingests ==
                       duplicate_before + 1U,
               "recent emitted A replay was not identified without a marker");
  MavlinkFrame preserved_front{};
  bool preserved_marker = false;
  report.check(replay_backlog.peek(preserved_front, preserved_marker) &&
                   preserved_marker &&
                   preserved_front.size == held_b.size &&
                   std::equal(preserved_front.bytes.begin(),
                              preserved_front.bytes.begin() +
                                  preserved_front.size,
                              held_b.bytes.begin()),
               "recent A replay displaced the existing B marker/backlog");

  const std::filesystem::path bridge_path =
      std::filesystem::path(VC_LORA_SOURCE_ROOT) / "firmware" / "phase6" /
      "vc_lora_phase6_bridge.hpp";
  std::ifstream bridge_input(bridge_path, std::ios::binary);
  const std::string source{std::istreambuf_iterator<char>(bridge_input),
                           std::istreambuf_iterator<char>()};
  report.check(source.find("recent_emitted_duplicate") !=
                   std::string::npos,
               "Phase6 handler does not preserve B on recent A replay");
  report.detail =
      "paced primary HB is admitted byte-exact before the later frame; "
      "emitted increments only at fixed bytes_committed goal, and recent A "
      "replay does not disturb a different held B pair";
}

void prepare_proxy_awaiting_value(GroundParameterDownloadProxy& proxy,
                                  TestReport& report) {
  report.check(proxy.on_gcs_frame(param_request_list(1U), 0U) ==
                   GroundParameterProxyDisposition::Consumed,
               "proxy did not consume PARAM_REQUEST_LIST");
  proxy.tick(0U);
  MavlinkFrame request{};
  std::uint32_t token = 0U;
  report.check(proxy.peek_next_request(request, token) && token != 0U,
               "proxy did not produce PARAM_REQUEST_READ");
  report.check(proxy.mark_request_admitted(token, 1U) &&
                   proxy.mark_request_dequeued(token, 2U) &&
                   proxy.complete_request_tx(token, TxResult::Accepted, 3U),
                 "proxy did not enter PARAM_VALUE wait state");
}

void check_endpoint_dip_retention(TestReport& report) {
  // HWCDC::operator bool() can fall false after a short write-progress stall
  // even while USB SOF/host presence remains true.  The production bridge must
  // use host presence for destructive disconnect handling and endpoint-ready
  // only to pause physical writes.
  using Endpoint = MavlinkValidatedLocalEgressAdapter<
      96U, kEmbeddedPhysicalWriteBytes,
      LocalEgressOverflowPolicy::DropNewestFrame>;
  GroundUsbHeartbeatPacer pacer{pacer_config()};
  GroundUsbOrderedFrameBacklog<> backlog{};
  Endpoint endpoint{};
  pacer.set_usb_connected(true, 0U);
  const MavlinkFrame held = heartbeat(0x8AU, 0xEAU);
  const MavlinkFrame behind = param_value(0x8BU, 0U, 2U);
  report.check(pacer.ingest(held, 100U) ==
                       GroundUsbHeartbeatIngestStatus::Held &&
                   backlog.enqueue(held, true) ==
                       GroundUsbOrderedBacklogStatus::Queued &&
                   backlog.enqueue(behind, false) ==
                       GroundUsbOrderedBacklogStatus::Queued,
               "endpoint-dip fixture did not hold heartbeat and following "
               "PARAM_VALUE");

  // Model host_present=true, endpoint_ready=false: no disconnect callback,
  // dequeue, admission, or physical write is permitted during the dip.
  const std::size_t held_before_dip = pacer.queued();
  const std::size_t frames_before_dip = backlog.queued_frames();
  const std::size_t bytes_before_dip = backlog.queued_bytes();
  report.check(pacer.queued() == held_before_dip &&
                   backlog.queued_frames() == frames_before_dip &&
                   backlog.queued_bytes() == bytes_before_dip &&
                   backlog.diagnostics().discarded_frames == 0U &&
                   backlog.diagnostics().discarded_bytes == 0U &&
                   pacer.diagnostics().usb_disconnect_events == 0U &&
                   pacer.diagnostics().order_preservation_drops == 0U,
               "temporary endpoint dip discarded a complete ordered frame");

  // Endpoint recovery releases the same heartbeat first, then the exact
  // following frame. Pause once more after a partial heartbeat write to prove
  // that the fixed commit goal and unsent suffix survive too.
  GroundUsbHeartbeatLease lease{};
  report.check(pacer.select_before_next_frame(200U, lease) ==
                       GroundUsbHeartbeatBarrierStatus::LeaseReady,
               "retained heartbeat did not reacquire its order barrier");
  std::uint64_t commit_goal = 0U;
  report.check(admit_paced_heartbeat(pacer, endpoint, lease, commit_goal,
                                     report),
               "retained heartbeat was not admitted after endpoint recovery");
  MavlinkFrame front{};
  bool marker = false;
  report.check(backlog.peek(front, marker) && marker &&
                   backlog.pop_front() && backlog.peek(front, marker) &&
                   !marker && endpoint.egress().queued_bytes() == held.size,
               "retained PARAM_VALUE did not stay behind the HB commit");
  bool commit_active = true;
  std::uint32_t commit_token = lease.token;
  std::vector<std::uint8_t> wire{};
  drain_one_physical_write(endpoint, wire, pacer, commit_active,
                           commit_token, commit_goal, 210U,
                           held.size - 1U, report);
  const std::size_t queued_during_partial_dip = endpoint.egress().queued_bytes();
  report.check(commit_active && queued_during_partial_dip > 0U &&
                   pacer.diagnostics().rejected_emits == 0U &&
                   pacer.diagnostics().emitted_heartbeats == 0U,
               "partial endpoint dip rejected or prematurely committed the "
               "paced heartbeat");
  while (!endpoint.egress().empty()) {
    drain_one_physical_write(endpoint, wire, pacer, commit_active,
                             commit_token, commit_goal, 220U,
                             kEmbeddedPhysicalWriteBytes, report);
  }
  report.check(!commit_active && backlog.peek(front, marker) && !marker &&
                   endpoint.admit_validated_frame(front) ==
                       ValidatedLocalIngressStatus::QueuedFrame &&
                   backlog.pop_front(),
               "retained PARAM_VALUE was not released after HB publication");
  while (!endpoint.egress().empty()) {
    drain_one_physical_write(endpoint, wire, pacer, commit_active,
                             commit_token, commit_goal, 221U,
                             kEmbeddedPhysicalWriteBytes, report);
  }
  report.check(!commit_active && backlog.empty() &&
                   same_wire(held, wire, 0U) &&
                   same_wire(behind, wire, held.size) &&
                   wire.size() == held.size + behind.size &&
                   pacer.diagnostics().emitted_heartbeats == 1U &&
                   pacer.diagnostics().rejected_emits == 0U,
               "endpoint recovery changed, duplicated, reordered, or rejected "
               "the retained heartbeat/PARAM_VALUE bytes");

  const std::filesystem::path bridge_path =
      std::filesystem::path(VC_LORA_SOURCE_ROOT) / "firmware" / "phase6" /
      "vc_lora_phase6_bridge.hpp";
  std::ifstream bridge_input(bridge_path, std::ios::binary);
  const std::string source{std::istreambuf_iterator<char>(bridge_input),
                           std::istreambuf_iterator<char>()};
  const std::size_t update_begin =
      source.find(
          "void update_ground_usb_connection(std::uint64_t now_ms) noexcept {");
  const std::size_t update_end = source.find("\n}\n", update_begin);
  report.check(update_begin != std::string::npos &&
                   update_end != std::string::npos,
               "Ground USB connection update function is missing");
  if (update_begin != std::string::npos &&
      update_end != std::string::npos) {
    const std::string update =
        source.substr(update_begin, update_end - update_begin);
    const std::size_t sample_raw_host =
        update.find("ground_usb_host_present_now()");
    const std::size_t sample_endpoint =
        update.find("ground_usb_endpoint_ready_now(raw_host_present)");
    const std::size_t cache_endpoint =
        update.find("ground_usb_endpoint_ready_state");
    const std::size_t observe_filter =
        update.find("ground_usb_host_presence_filter.observe");
    const std::size_t read_confirmed =
        update.find("ground_usb_host_presence_filter.confirmed_present");
    const std::size_t cache_confirmed =
        update.find("ground_usb_host_present_state = host_present");
    const std::size_t gate_confirmed_transition =
        update.find("GroundUsbHostPresenceUpdate::ConfirmedDisconnected");
    const std::size_t set_pacer =
        update.find("set_usb_connected(host_present");
    const std::size_t confirmed_absence =
        update.find("if (host_present)");
    const std::size_t discard_backlog =
        update.find("discard_ground_ordered_backlog", confirmed_absence);
    const std::size_t discard_held =
        update.find("discard_ground_held_heartbeats", confirmed_absence);
    report.check(sample_raw_host != std::string::npos &&
                     sample_endpoint != std::string::npos &&
                     cache_endpoint != std::string::npos &&
                     observe_filter != std::string::npos &&
                     read_confirmed != std::string::npos &&
                     cache_confirmed != std::string::npos &&
                     gate_confirmed_transition != std::string::npos &&
                     set_pacer != std::string::npos &&
                     confirmed_absence != std::string::npos &&
                     discard_backlog != std::string::npos &&
                     discard_held != std::string::npos &&
                     sample_raw_host < sample_endpoint &&
                     sample_endpoint < cache_endpoint &&
                     cache_endpoint < observe_filter &&
                     observe_filter < read_confirmed &&
                     read_confirmed < cache_confirmed &&
                     cache_confirmed < gate_confirmed_transition &&
                     gate_confirmed_transition < set_pacer &&
                     set_pacer < confirmed_absence &&
                     confirmed_absence < discard_backlog &&
                     confirmed_absence < discard_held,
                 "endpoint-ready dip is not isolated from confirmed host-loss "
                 "destruction");
  }

  report.check(source.find("bool ground_usb_host_present_state{false};") !=
                       std::string::npos &&
                   source.find("bool ground_usb_endpoint_ready_state{false};") !=
                       std::string::npos &&
                   source.find("return Serial.isPlugged();") !=
                       std::string::npos &&
                   source.find("kGroundUsbHostLossConfirmMs = 50U") !=
                       std::string::npos &&
                   source.find("GroundUsbHostPresenceFilter ") !=
                       std::string::npos &&
                   source.find(
                       "return host_present && static_cast<bool>(Serial);") !=
                       std::string::npos &&
                   source.find("return ground_usb_host_present_state;") !=
                       std::string::npos &&
                   source.find("ground_usb_endpoint_ready_state);") !=
                       std::string::npos,
               "Ground USB host-presence admission and endpoint-ready write "
               "states are not independently wired");
  report.detail =
      "raw HWCDC false pauses writes immediately and retains exact ordered "
      "data until the 50-ms filter confirms physical host loss";
}

void check_disconnected_handler_model(TestReport& report) {
  using Endpoint = MavlinkValidatedLocalEgressAdapter<
      96U, kEmbeddedPhysicalWriteBytes,
      LocalEgressOverflowPolicy::DropNewestFrame>;
  GroundUsbHeartbeatPacer pacer{pacer_config()};
  GroundUsbOrderedFrameBacklog<> backlog{};
  Endpoint endpoint{};
  GroundParameterDownloadProxy proxy{};
  pacer.set_usb_connected(false, 0U);
  prepare_proxy_awaiting_value(proxy, report);

  std::size_t rejected_frames = 0U;
  const auto dispatch_while_disconnected =
      [&proxy, &rejected_frames, &report](const MavlinkFrame& frame,
                                         std::uint64_t now_ms) {
        // This mirrors the production handler boundary: proxy quarantine must
        // run first, then every otherwise-forwardable frame is rejected before
        // heartbeat classification, pacer/backlog mutation, or USB admission.
        const GroundParameterProxyDisposition preclassification =
            proxy.preclassify_vehicle_frame(frame, now_ms);
        report.check(preclassification !=
                         GroundParameterProxyDisposition::Invalid,
                     "disconnected handler model received an invalid frame");
        if (preclassification != GroundParameterProxyDisposition::Forward) {
          return;
        }
        (void)proxy.on_vehicle_frame(frame, false, now_ms);
        ++rejected_frames;
      };

  const std::array<MavlinkFrame, 4U> downlink{{
      heartbeat(0x90U, 0x10U), foreign_heartbeat(0x91U, 0x11U),
      timesync(0x92U, 0x12U), param_value(0x93U, 0U, 2U)}};
  for (std::size_t index = 0U; index < downlink.size(); ++index) {
    dispatch_while_disconnected(downlink[index], 100U + index);
  }

  const GroundUsbHeartbeatPacerDiagnostics& pacer_diagnostics =
      pacer.diagnostics();
  report.check(rejected_frames == downlink.size() && pacer.queued() == 0U &&
                   pacer_diagnostics.valid_real_heartbeats == 0U &&
                   pacer_diagnostics.foreign_heartbeats_passthrough == 0U &&
                   backlog.empty() && backlog.queued_bytes() == 0U &&
                   endpoint.egress().empty() &&
                   endpoint.egress().stats().bytes_ingested == 0U &&
                   endpoint.egress().stats().bytes_queued == 0U &&
                   endpoint.egress().stats().bytes_committed == 0U,
               "disconnected frame reached pacer, ordered backlog, or USB "
               "egress before rejection");
  report.check(proxy.expected_index() == 0U &&
                   proxy.diagnostics().matching_values_seen == 1U &&
                   proxy.diagnostics().matching_values_usb_queued == 0U &&
                   proxy.diagnostics().matching_values_usb_rejected == 1U,
               "disconnected matching #22 advanced the proxy");

  // usb_queued=false deliberately leaves the same index awaiting a bounded
  // timeout/retry; it must not look like a successful Mission Planner delivery.
  proxy.tick(30'003U);
  proxy.tick(31'003U);
  MavlinkFrame retry{};
  std::uint32_t retry_token = 0U;
  report.check(proxy.peek_next_request(retry, retry_token) &&
                   retry_token != 0U && retry.message_id == 20U &&
                   proxy.expected_index() == 0U &&
                   proxy.diagnostics().value_timeouts == 1U &&
                   proxy.diagnostics().request_retries == 1U,
               "rejected disconnected #22 did not re-arm index-zero retry");
}

void check_overflow_and_proxy_nonadvance(TestReport& report) {
  check_disconnected_handler_model(report);
  report.check(HasMarkEmitAdmitted<GroundUsbHeartbeatPacer>::value,
               "RED: mark_emit_admitted API is missing");
  using Endpoint = MavlinkValidatedLocalEgressAdapter<
      32U, kEmbeddedPhysicalWriteBytes,
      LocalEgressOverflowPolicy::DropNewestFrame>;
  GroundUsbHeartbeatPacer pacer{pacer_config()};
  Endpoint endpoint{};
  GroundParameterDownloadProxy proxy{};
  pacer.set_usb_connected(true, 0U);
  prepare_proxy_awaiting_value(proxy, report);

  const MavlinkFrame earlier = timesync(0x40U, 0xC0U);
  const MavlinkFrame held = heartbeat(0x41U, 0xC1U);
  const MavlinkFrame value = param_value(0x42U, 0U, 2U);
  report.check(earlier.size < endpoint.egress().capacity() &&
                   endpoint.egress().capacity() - earlier.size < held.size,
               "overflow fixture does not leave the required short prefix");
  report.check(endpoint.admit_validated_frame(earlier) ==
                   ValidatedLocalIngressStatus::QueuedFrame &&
                   pacer.ingest(held, 10U) ==
                       GroundUsbHeartbeatIngestStatus::Held,
               "overflow fixture did not queue prefix and reserve HB");
  GroundUsbHeartbeatLease lease{};
  report.check(pacer.select_before_next_frame(11U, lease) ==
                   GroundUsbHeartbeatBarrierStatus::LeaseReady,
               "overflow barrier did not lease prior heartbeat");
  const auto heartbeat_status = endpoint.admit_validated_frame(lease.frame);
  report.check(heartbeat_status ==
                   ValidatedLocalIngressStatus::DroppedOverflow,
               "full endpoint unexpectedly admitted the paced heartbeat");
  report.check(pacer.complete_emit(lease.token, TxResult::Rejected, 11U) &&
                   pacer.discard_for_order(12U),
               "rejected barrier heartbeat was not explicitly dropped");
  report.check(proxy.on_vehicle_frame(value, false, 12U) ==
                   GroundParameterProxyDisposition::Consumed &&
                   proxy.expected_index() == 0U &&
                   proxy.diagnostics().matching_values_usb_rejected == 1U,
               "#22 advanced proxy after heartbeat barrier/USB rejection");
  report.check(endpoint.stats().frames_dropped_overflow == 1U &&
                   pacer.diagnostics().rejected_emits == 1U &&
                   pacer.diagnostics().order_preservation_drops == 1U,
               "endpoint/barrier loss diagnostics do not match events");

  // Once a paced heartbeat is already in the byte FIFO, a newly held second
  // heartbeat cannot be leased until the first reaches its physical commit
  // goal. A later current frame is therefore dropped instead of overtaking.
  using WideEndpoint = MavlinkValidatedLocalEgressAdapter<
      96U, kEmbeddedPhysicalWriteBytes,
      LocalEgressOverflowPolicy::DropNewestFrame>;
  GroundUsbHeartbeatPacer pending_pacer{pacer_config()};
  WideEndpoint wide_endpoint{};
  pending_pacer.set_usb_connected(true, 20U);
  const MavlinkFrame first = heartbeat(0x50U, 0xD0U);
  const MavlinkFrame second = heartbeat(0x51U, 0xD1U);
  (void)pending_pacer.ingest(first, 20U);
  GroundUsbHeartbeatLease first_lease{};
  report.check(pending_pacer.select_before_next_frame(21U, first_lease) ==
                   GroundUsbHeartbeatBarrierStatus::LeaseReady,
               "pending-inflight fixture did not lease first HB");
  std::uint64_t first_goal = 0U;
  report.check(admit_paced_heartbeat(pending_pacer, wide_endpoint,
                                     first_lease, first_goal, report),
               "pending-inflight fixture did not admit first HB");
  (void)pending_pacer.ingest(second, 22U);
  GroundUsbHeartbeatLease blocked{};
  report.check(pending_pacer.select_before_next_frame(23U, blocked) ==
                   GroundUsbHeartbeatBarrierStatus::BlockedByPendingEmit,
               "second held HB bypassed an uncommitted paced HB");
  report.check(pending_pacer.discard_for_order(23U) &&
                   pending_pacer.queued() == 0U,
               "second held HB was not safely dropped with current frame");
  report.detail =
      "disconnected primary/foreign HB, normal frame, and #22 leave pacer, "
      "backlog, and egress empty; #22 uses usb_queued=false, stays at index "
      "zero, and retries; endpoint/order rejection cases also remain atomic";
}

void check_stale_pair_recovery(TestReport& report) {
  GroundUsbHeartbeatPacer pacer{pacer_config()};
  GroundUsbOrderedFrameBacklog<> backlog{};
  GroundParameterDownloadProxy proxy{};
  pacer.set_usb_connected(true, 0U);
  prepare_proxy_awaiting_value(proxy, report);

  const MavlinkFrame stale_hb = heartbeat(0x58U, 0xD8U);
  const MavlinkFrame buffered_value = param_value(0x59U, 0U, 2U);
  report.check(pacer.ingest(stale_hb, 10U) ==
                   GroundUsbHeartbeatIngestStatus::Held &&
                   backlog.enqueue(stale_hb, true) ==
                       GroundUsbOrderedBacklogStatus::Queued &&
                   backlog.enqueue(buffered_value, false) ==
                       GroundUsbOrderedBacklogStatus::Queued,
               "stale-recovery fixture did not create a paired backlog");

  const std::size_t held_before_select = pacer.queued();
  GroundUsbHeartbeatLease lease{};
  const bool selected = pacer.select_due(2411U, false, lease);
  const bool expiry_changed_pair =
      pacer.queued() != held_before_select;
  report.check(!selected && held_before_select == 1U &&
                   expiry_changed_pair && pacer.queued() == 0U &&
                   pacer.diagnostics().expired_heartbeats == 1U,
               "hard-age expiry did not expose the marker/pacer mismatch");

  // Model the production synchronized recovery: every later complete frame
  // is rejected whole (so #22 cannot advance), then all stale markers leave.
  while (!backlog.empty()) {
    MavlinkFrame frame{};
    bool marker = false;
    report.check(backlog.peek(frame, marker),
                 "stale backlog head became unreadable");
    if (!marker) {
      (void)proxy.on_vehicle_frame(frame, false, 2411U);
    }
    report.check(backlog.discard_front(),
                 "stale backlog frame was not atomically discarded");
  }
  report.check(backlog.empty() &&
                   backlog.diagnostics().discarded_frames == 2U &&
                   proxy.expected_index() == 0U &&
                   proxy.diagnostics().matching_values_usb_rejected == 1U,
               "stale recovery left HOL state or advanced buffered #22");

  const MavlinkFrame fresh_hb = heartbeat(0x5AU, 0xDAU);
  report.check(pacer.ingest(fresh_hb, 2500U) ==
                   GroundUsbHeartbeatIngestStatus::Held &&
                   backlog.enqueue(fresh_hb, true) ==
                       GroundUsbOrderedBacklogStatus::Queued &&
                   pacer.select_due(2500U, false, lease),
               "stale synchronized drop did not permit a fresh HB lease");

  // Two-entry edge: select_due expires stale HB0 and leases fresh HB1 in the
  // same call. The lease must be explicitly aborted before both marker/pacer
  // stores can be discarded without fail-close or a permanent pending token.
  report.check(HasAbortPendingEmit<GroundUsbHeartbeatPacer>::value,
               "pacer lacks explicit pending-lease abort API");
  GroundUsbHeartbeatPacer two_pacer{pacer_config()};
  GroundUsbOrderedFrameBacklog<> two_backlog{};
  two_pacer.set_usb_connected(true, 0U);
  const MavlinkFrame stale0 = heartbeat(0x5BU, 0xDBU);
  const MavlinkFrame fresh1 = heartbeat(0x5CU, 0xDCU);
  const MavlinkFrame after1 = timesync(0x5DU, 0xDDU);
  report.check(two_pacer.ingest(stale0, 0U) ==
                   GroundUsbHeartbeatIngestStatus::Held &&
                   two_backlog.enqueue(stale0, true) ==
                       GroundUsbOrderedBacklogStatus::Queued &&
                   two_pacer.ingest(fresh1, 1000U) ==
                       GroundUsbHeartbeatIngestStatus::Held &&
                   two_backlog.enqueue(fresh1, true) ==
                       GroundUsbOrderedBacklogStatus::Queued &&
                   two_backlog.enqueue(after1, false) ==
                       GroundUsbOrderedBacklogStatus::Queued,
               "two-entry stale fixture was not paired");
  const std::size_t two_before = two_pacer.queued();
  GroundUsbHeartbeatLease fresh1_lease{};
  const bool selected_fresh1 =
      two_pacer.select_due(2500U, false, fresh1_lease);
  report.check(selected_fresh1 && two_before == 2U &&
                   two_pacer.queued() == 1U,
               "select_due did not expire HB0 and lease fresh HB1");
  const bool aborted = abort_pending_emit_if_present(
      two_pacer, fresh1_lease.token);
  if (aborted) {
    two_backlog.discard_all();
  }
  report.check(aborted && two_pacer.discard_for_order(2500U) &&
                   two_pacer.queued() == 0U && two_backlog.empty() &&
                   !two_pacer.has_pending_emit() &&
                   two_pacer.diagnostics().aborted_pending_emits == 1U &&
                   two_pacer.diagnostics().invalid_pending_aborts == 0U,
               "two-entry stale recovery retained lease or forced fail-close");
  const MavlinkFrame next_fresh = heartbeat(0x5EU, 0xDEU);
  report.check(two_pacer.ingest(next_fresh, 2600U) ==
                   GroundUsbHeartbeatIngestStatus::Held &&
                   two_pacer.select_due(2600U, false, fresh1_lease),
               "two-entry recovery did not accept next fresh RF HB");

  const std::filesystem::path bridge_path =
      std::filesystem::path(VC_LORA_SOURCE_ROOT) / "firmware" / "phase6" /
      "vc_lora_phase6_bridge.hpp";
  std::ifstream bridge_input(bridge_path, std::ios::binary);
  const std::string source{std::istreambuf_iterator<char>(bridge_input),
                           std::istreambuf_iterator<char>()};
  report.check(source.find("held_before_select") != std::string::npos &&
                   source.find("recover_ground_stale_pacer_pair") !=
                       std::string::npos &&
                   source.find("abort_pending_emit") != std::string::npos,
               "Phase6 service lacks synchronized stale marker recovery");
  report.detail =
      "stale pacer expiry rejects marker+following #22 atomically, leaves no "
      "HOL marker, and permits the next fresh heartbeat";
}

void check_due_and_cadence(TestReport& report) {
  report.check(HasMarkEmitAdmitted<GroundUsbHeartbeatPacer>::value,
               "RED: mark_emit_admitted API is missing");
  report.check(kSoftDueMs + kLoopJitterMs + kCurrentFrameBlockMs +
                       kHeartbeatWriteMs + kTransportFlushMs ==
                   2455U &&
                   2455U <= kUsbHeartbeatLimitMs,
               "2200+100+49+6+100 no longer proves the 2500-ms cadence");
  if constexpr (!HasMarkEmitAdmitted<GroundUsbHeartbeatPacer>::value) {
    return;
  }

  using Endpoint = MavlinkValidatedLocalEgressAdapter<
      96U, kEmbeddedPhysicalWriteBytes,
      LocalEgressOverflowPolicy::DropNewestFrame>;
  GroundUsbHeartbeatPacer pacer{pacer_config()};
  Endpoint endpoint{};
  constexpr std::uint64_t base = 10'000U;
  pacer.set_usb_connected(true, base);

  const auto timer_admit = [&pacer, &endpoint, &report](
                               std::uint64_t now_ms,
                               bool writer_available,
                               std::uint64_t& goal,
                               std::uint32_t& token) {
    auto& egress = endpoint.egress();
    if (!egress.empty() || egress.write_pending() || !writer_available) {
      return false;
    }
    GroundUsbHeartbeatLease lease{};
    if (!pacer.select_due(now_ms, false, lease)) {
      return false;
    }
    if (!admit_paced_heartbeat(pacer, endpoint, lease, goal, report)) {
      return false;
    }
    token = lease.token;
    return true;
  };

  const MavlinkFrame baseline = heartbeat(0x60U, 0xE0U);
  const MavlinkFrame reserve = heartbeat(0x61U, 0xE1U);
  (void)pacer.ingest(baseline, base);
  std::uint64_t commit_goal = 0U;
  std::uint32_t commit_token = 0U;
  report.check(timer_admit(base, true, commit_goal, commit_token),
               "empty baseline endpoint did not admit due heartbeat");
  bool commit_active = true;
  std::vector<std::uint8_t> wire{};
  drain_one_physical_write(endpoint, wire, pacer, commit_active,
                           commit_token, commit_goal, base + 100U,
                           kEmbeddedPhysicalWriteBytes, report);
  (void)pacer.ingest(reserve, base + 1000U);

  // Deadline is first observed after 100 ms of loop jitter while a maximum
  // normal MAVLink frame is still finishing. Keep its current physical prefix
  // active until the 49-ms boundary and verify the timer cannot preempt it.
  const MavlinkFrame normal = timesync(0x62U, 0xE2U);
  report.check(endpoint.admit_validated_frame(normal) ==
                   ValidatedLocalIngressStatus::QueuedFrame,
               "current-frame timing fixture was not queued");
  bool no_heartbeat_commit = false;
  std::uint32_t no_token = 0U;
  drain_one_physical_write(endpoint, wire, pacer, no_heartbeat_commit,
                           no_token, 0U, base + 2400U, normal.size - 1U,
                           report);
  report.check(endpoint.egress().write_pending() &&
                   !timer_admit(base + 2400U, true, commit_goal,
                                commit_token),
               "timer preempted an active normal-frame physical write");
  drain_one_physical_write(endpoint, wire, pacer, no_heartbeat_commit,
                           no_token, 0U, base + 2449U,
                           kEmbeddedPhysicalWriteBytes, report);
  report.check(endpoint.egress().empty() &&
                   !endpoint.egress().write_pending(),
               "normal frame was not complete at its 49-ms boundary");
  report.check(!timer_admit(base + 2449U, false, commit_goal,
                            commit_token),
               "timer admitted heartbeat with unavailable Serial writer");
  report.check(timer_admit(base + 2449U, true, commit_goal,
                           commit_token),
               "due heartbeat did not win the first empty/writable boundary");
  commit_active = true;
  drain_one_physical_write(endpoint, wire, pacer, commit_active,
                           commit_token, commit_goal, base + 2555U,
                           kEmbeddedPhysicalWriteBytes, report);
  report.check(!commit_active &&
                   pacer.diagnostics().emitted_heartbeats == 2U &&
                   pacer.diagnostics().max_usb_gap_ms == 2455U &&
                   pacer.diagnostics().max_usb_gap_ms <=
                       kUsbHeartbeatLimitMs,
               "fenced USB heartbeat cadence was not exactly 2455 ms");
  report.detail =
      "timer admission requires empty generic egress, no write_pending and "
      "an available Serial writer; 2200+100+49+6+100=2455 ms";
}

void check_backlog_capacity_and_atomicity(TestReport& report) {
  report.check(VC_LORA_HAS_GROUND_USB_ORDERED_FRAME_BACKLOG != 0,
               "RED: fixed Ground USB ordered backlog is missing");
  report.check(kGroundUsbOrderedBacklogBytes == 224U &&
                   kGroundUsbOrderedBacklogFrames == 28U &&
                   kGroundUsbOrderedBacklogBytes + kLocalEgressBytes ==
                       4320U,
               "224B/28-frame/4320B combined capacity proof changed");
  if constexpr (VC_LORA_HAS_GROUND_USB_ORDERED_FRAME_BACKLOG == 0) {
    return;
  }

  GroundUsbOrderedFrameBacklog<> backlog{};
  const MavlinkFrame signed_hb = signed_heartbeat(0x68U, 0x88U);
  const MavlinkFrame v1 = timesync_v1(0x69U, 0x89U);
  const MavlinkFrame v2 = timesync(0x6AU, 0x8AU);
  report.check(signed_hb.size == 34U,
               "signed MAVLink2 heartbeat size is not the 34-byte bound");
  report.check(backlog.enqueue(signed_hb, true) ==
                   GroundUsbOrderedBacklogStatus::Queued &&
                   backlog.enqueue(v1, false) ==
                       GroundUsbOrderedBacklogStatus::Queued &&
                   backlog.enqueue(v2, false) ==
                       GroundUsbOrderedBacklogStatus::Queued,
               "signed/v1/v2 ordered backlog fixture was rejected");
  const std::array<MavlinkFrame, 3U> expected{{signed_hb, v1, v2}};
  for (std::size_t index = 0U; index < expected.size(); ++index) {
    MavlinkFrame observed{};
    bool paced_marker = false;
    report.check(backlog.peek(observed, paced_marker) &&
                     same_wire(expected[index],
                               std::vector<std::uint8_t>(
                                   observed.bytes.begin(),
                                   observed.bytes.begin() + observed.size),
                               0U) &&
                     paced_marker == (index == 0U) &&
                     backlog.pop_front(),
                 "signed/v1/v2 backlog changed byte order or marker");
  }
  report.check(backlog.empty() &&
                   backlog.diagnostics().frames_released == 3U,
               "ordered backlog did not release each frame once");

  GroundUsbOrderedFrameBacklog<40U, 4U> small{};
  const MavlinkFrame held = heartbeat(0x6BU, 0x8BU);
  const MavlinkFrame value = param_value(0x6CU, 0U, 2U);
  report.check(small.enqueue(held, true) ==
                   GroundUsbOrderedBacklogStatus::Queued,
               "small-backlog setup heartbeat was rejected");
  const std::size_t bytes_before = small.queued_bytes();
  report.check(small.enqueue(value, false) ==
                   GroundUsbOrderedBacklogStatus::Overflow &&
                   small.queued_bytes() == bytes_before &&
                   small.queued_frames() == 1U &&
                   small.diagnostics().overflow_frames == 1U &&
                   small.diagnostics().overflow_bytes == value.size,
               "overflow did not reject the whole current #22 atomically");
  small.reset();
  report.check(small.empty() && small.queued_bytes() == 0U,
               "disconnect/reset retained ordered backlog bytes");
  report.detail =
      "34B signed HB +31B same-chunk tail +4*32B/550ms =193B; "
      "rounded to 224B/28 minimum v1 frames, combined egress bound 4320B";
}

void check_real_burst_blackout(TestReport& report) {
  report.check(VC_LORA_HAS_GROUND_USB_ORDERED_FRAME_BACKLOG != 0,
               "RED: fixed Ground USB ordered backlog is missing");
  if constexpr (VC_LORA_HAS_GROUND_USB_ORDERED_FRAME_BACKLOG == 0) {
    return;
  }
  using Endpoint = MavlinkValidatedLocalEgressAdapter<
      256U, kEmbeddedPhysicalWriteBytes,
      LocalEgressOverflowPolicy::DropNewestFrame>;
  GroundUsbHeartbeatPacer pacer{pacer_config()};
  GroundUsbOrderedFrameBacklog<> backlog{};
  Endpoint endpoint{};
  pacer.set_usb_connected(true, 0U);
  std::vector<std::uint8_t> wire{};
  std::vector<MavlinkFrame> expected{};

  const auto receive_pair = [&pacer, &backlog, &expected, &report](
                                const MavlinkFrame& hb,
                                const MavlinkFrame& following,
                                std::uint64_t rf_ms) {
    report.check(pacer.ingest(hb, rf_ms) ==
                     GroundUsbHeartbeatIngestStatus::Held &&
                     backlog.enqueue(hb, true) ==
                         GroundUsbOrderedBacklogStatus::Queued &&
                     backlog.enqueue(following, false) ==
                         GroundUsbOrderedBacklogStatus::Queued,
                 "RF HB/telemetry pair was not retained atomically");
    expected.push_back(hb);
    expected.push_back(following);
  };

  const auto service_due = [&pacer, &backlog, &endpoint, &wire, &report](
                               std::uint64_t selection_ms,
                               std::uint64_t completed_ms,
                               bool expect_due) {
    GroundUsbHeartbeatLease lease{};
    const bool selected = pacer.select_due(selection_ms, false, lease);
    report.check(selected == expect_due,
                 "ordered backlog due decision changed");
    if (!selected) {
      return;
    }
    MavlinkFrame front{};
    bool marker = false;
    report.check(backlog.peek(front, marker) && marker &&
                     same_wire(lease.frame,
                               std::vector<std::uint8_t>(
                                   front.bytes.begin(),
                                   front.bytes.begin() + front.size),
                               0U),
                 "pacer lease did not match ordered backlog head HB");
    std::uint64_t goal = 0U;
    report.check(admit_paced_heartbeat(pacer, endpoint, lease, goal, report) &&
                      backlog.pop_front(),
                  "due HB was not moved atomically to USB egress");
    bool active = true;
    std::uint32_t token = lease.token;
    while (!endpoint.egress().empty()) {
      drain_one_physical_write(endpoint, wire, pacer, active, token, goal,
                               completed_ms, kEmbeddedPhysicalWriteBytes,
                               report);
    }
    while (backlog.peek(front, marker) && !marker) {
      report.check(endpoint.admit_validated_frame(front) ==
                           ValidatedLocalIngressStatus::QueuedFrame &&
                       backlog.pop_front(),
                   "telemetry release after due HB publication failed");
      while (!endpoint.egress().empty()) {
        drain_one_physical_write(endpoint, wire, pacer, active, token, goal,
                                 completed_ms,
                                 kEmbeddedPhysicalWriteBytes, report);
      }
    }
    report.check(!active &&
                     completed_ms - lease.rf_received_ms <= 2400U,
                 "burst heartbeat exceeded physical age cap");
  };

  receive_pair(signed_heartbeat(0x70U, 0xF0U),
               timesync_v1(0x71U, 0xA0U), 0U);
  service_due(0U, 6U, true);
  receive_pair(heartbeat(0x72U, 0xF1U), timesync(0x73U, 0xA1U),
               1000U);
  receive_pair(heartbeat(0x74U, 0xF2U), timesync_v1(0x75U, 0xA2U),
               2000U);
  service_due(1001U, 1001U, false);
  service_due(2306U, 2312U, true);
  // HB at t=2000 must be advanced by its age deadline rather than waiting for
  // last-complete+2200, otherwise it would be stale before physical commit.
  service_due(4394U, 4400U, true);
  // The next real supply appears only after a 3200-ms RF blackout.
  receive_pair(heartbeat(0x76U, 0xF3U), timesync(0x77U, 0xA3U),
               5200U);
  service_due(6599U, 6599U, false);
  service_due(6700U, 6706U, true);

  std::size_t offset = 0U;
  for (const MavlinkFrame& frame : expected) {
    report.check(same_wire(frame, wire, offset),
                 "burst output changed frame bytes/order/once contract");
    offset += frame.size;
  }
  report.check(offset == wire.size() && backlog.empty() &&
                   pacer.diagnostics().emitted_heartbeats == 4U &&
                   pacer.diagnostics().max_hold_age_ms <= 2400U &&
                   pacer.diagnostics().max_usb_gap_ms <=
                       kUsbHeartbeatLimitMs,
               "1Hzx3 plus 3200-ms blackout violated ordered USB HB bound");
  report.stress.heartbeat_gap_after_rx_ms =
      pacer.diagnostics().max_usb_gap_ms;
  report.detail =
      "signed/v1/v2 HB->telemetry sequence remains byte-exact while age-aware "
      "deadline pacing bridges a 3200-ms RF blackout";
}

void check_pregrant_reserve_capacity(TestReport& report) {
  report.check(VC_LORA_HAS_GROUND_USB_ORDERED_FRAME_BACKLOG != 0,
               "RED: fixed Ground USB ordered backlog is missing");
  report.check(GroundUsbHeartbeatPacer::capacity() == 3U,
               "RED: the two-entry pacer can reject the fresh pre-Grant "
               "heartbeat while two older heartbeats are held");
  if constexpr (VC_LORA_HAS_GROUND_USB_ORDERED_FRAME_BACKLOG == 0) {
    return;
  }

  using Endpoint = MavlinkValidatedLocalEgressAdapter<
      256U, kEmbeddedPhysicalWriteBytes,
      LocalEgressOverflowPolicy::DropNewestFrame>;
  GroundUsbHeartbeatPacer pacer{pacer_config()};
  GroundUsbOrderedFrameBacklog<> backlog{};
  Endpoint endpoint{};
  pacer.set_usb_connected(true, 0U);
  std::vector<std::uint8_t> wire{};
  std::uint64_t capacity_rejects = 0U;

  const auto receive_pair = [&pacer, &backlog, &endpoint,
                             &capacity_rejects, &report](
                                const MavlinkFrame& hb,
                                const MavlinkFrame& following,
                                std::uint64_t rf_ms) {
    const std::size_t held_before = pacer.queued();
    const bool can_hold =
        held_before < GroundUsbHeartbeatPacer::capacity() &&
        backlog.can_enqueue(hb);
    if (can_hold) {
      report.check(pacer.ingest(hb, rf_ms) ==
                           GroundUsbHeartbeatIngestStatus::Held &&
                       pacer.queued() == held_before + 1U &&
                       backlog.enqueue(hb, true) ==
                           GroundUsbOrderedBacklogStatus::Queued,
                   "pre-Grant heartbeat did not enter its paired reserve");
    } else {
      ++capacity_rejects;
    }

    if (!backlog.empty() || pacer.queued() != 0U) {
      report.check(backlog.enqueue(following, false) ==
                       GroundUsbOrderedBacklogStatus::Queued,
                   "following PARAM_VALUE overflowed the ordered backlog");
    } else {
      report.check(endpoint.admit_validated_frame(following) ==
                       ValidatedLocalIngressStatus::QueuedFrame,
                   "following PARAM_VALUE did not enter the USB egress");
    }
  };

  const auto service_due = [&pacer, &backlog, &endpoint, &wire, &report](
                               std::uint64_t selection_ms,
                               std::uint64_t completed_ms) {
    GroundUsbHeartbeatLease lease{};
    report.check(pacer.select_due(selection_ms, false, lease),
                 "expected reserve heartbeat was not due");
    if (lease.token == 0U) {
      return;
    }
    MavlinkFrame front{};
    bool marker = false;
    report.check(backlog.peek(front, marker) && marker &&
                     same_wire(lease.frame,
                               std::vector<std::uint8_t>(
                                   front.bytes.begin(),
                                   front.bytes.begin() + front.size),
                               0U),
                 "reserve lease and ordered marker no longer match");
    std::uint64_t goal = 0U;
    report.check(admit_paced_heartbeat(pacer, endpoint, lease, goal,
                                        report) &&
                      backlog.pop_front(),
                  "reserve heartbeat was not admitted atomically");
    bool active = true;
    std::uint32_t token = lease.token;
    while (!endpoint.egress().empty()) {
      drain_one_physical_write(endpoint, wire, pacer, active, token, goal,
                               completed_ms, kEmbeddedPhysicalWriteBytes,
                               report);
    }
    while (backlog.peek(front, marker) && !marker) {
      report.check(endpoint.admit_validated_frame(front) ==
                           ValidatedLocalIngressStatus::QueuedFrame &&
                       backlog.pop_front(),
                   "following PARAM_VALUE was not released after HB publish");
      while (!endpoint.egress().empty()) {
        drain_one_physical_write(endpoint, wire, pacer, active, token, goal,
                                 completed_ms,
                                 kEmbeddedPhysicalWriteBytes, report);
      }
    }
    report.check(!active,
                 "reserve heartbeat physical completion was not fenced");
  };

  const MavlinkFrame baseline = heartbeat(0x80U, 0xE0U);
  const MavlinkFrame old0 = heartbeat(0x81U, 0xE1U);
  const MavlinkFrame old1 = heartbeat(0x82U, 0xE2U);
  const MavlinkFrame pregrant = heartbeat(0x83U, 0xE3U);
  const MavlinkFrame post_idle = heartbeat(0x84U, 0xE4U);

  receive_pair(baseline, param_value(0x90U, 0U, 5U), 0U);
  service_due(0U, 6U);
  receive_pair(old0, param_value(0x91U, 1U, 5U), 1000U);
  receive_pair(old1, param_value(0x92U, 2U, 5U), 1550U);
  // The fresh tail arrives while two older HBs are paired. Rejecting it here
  // exposes the following empty-Grant physical interval directly at USB.
  receive_pair(pregrant, param_value(0x93U, 3U, 5U), 2100U);
  service_due(2206U, 2212U);
  service_due(3744U, 3750U);
  if (capacity_rejects == 0U) {
    service_due(4294U, 4300U);
  }

  // 2950 ms is the fixed empty-Grant path:
  // GRANT service 550 + UL guard 650 + UL_IDLE service 550 +
  // return guard 650 + next-HB service 550. The 6-ms USB publication fence
  // makes the measured completion gap 2951 ms in the two-entry failure case.
  receive_pair(post_idle, param_value(0x94U, 4U, 5U), 6695U);
  service_due(6695U, 6701U);

  MavlinkStreamParser parser{};
  std::array<bool, 5U> heartbeat_seen{};
  std::array<bool, 5U> parameter_seen{};
  std::size_t heartbeat_count = 0U;
  std::size_t parameter_count = 0U;
  for (std::uint8_t byte : wire) {
    MavlinkFrame frame{};
    const MavlinkParseStatus status = parser.push(byte, frame);
    report.check(status != MavlinkParseStatus::BadLength &&
                     status != MavlinkParseStatus::BadCrc &&
                     status != MavlinkParseStatus::UnsupportedMessage &&
                     status != MavlinkParseStatus::UnsupportedFlags,
                 "reserve output contained an invalid MAVLink frame");
    if (status != MavlinkParseStatus::FrameReady) {
      continue;
    }
    if (frame.message_id == 0U && frame.sequence >= 0x80U &&
        frame.sequence <= 0x84U) {
      const std::size_t index = frame.sequence - 0x80U;
      report.check(!heartbeat_seen[index],
                   "reserve output duplicated a heartbeat");
      heartbeat_seen[index] = true;
      ++heartbeat_count;
    } else if (frame.message_id == 22U) {
      const std::uint16_t index = static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(frame.payload()[6U]) |
          static_cast<std::uint16_t>(
              static_cast<std::uint16_t>(frame.payload()[7U]) << 8U));
      report.check(index < parameter_seen.size() &&
                       index == parameter_count &&
                       !parameter_seen[index],
                   "PARAM_VALUE reserve companion was missing, duplicated, "
                   "or out of order");
      if (index < parameter_seen.size() && !parameter_seen[index]) {
        parameter_seen[index] = true;
        ++parameter_count;
      }
    }
  }

  pacer.observe_usb_egress(endpoint.egress().queued_bytes(),
                           endpoint.egress().write_pending(), true);
  report.check(capacity_rejects == 0U && heartbeat_count == 5U &&
                   std::all_of(heartbeat_seen.begin(), heartbeat_seen.end(),
                               [](bool value) { return value; }),
               "fresh pre-Grant heartbeat was rejected instead of retained");
  report.check(parameter_count == 5U &&
                   std::all_of(parameter_seen.begin(), parameter_seen.end(),
                               [](bool value) { return value; }),
               "ordered PARAM_VALUE companions were not exact 0..4");
  report.check(parser.buffered_size() == 0U && backlog.empty() &&
                   endpoint.egress().empty(),
               "reserve test left a partial frame or queued suffix");
  report.check(pacer.guarantee_available(6695U),
               "three-real-HB/6200-ms supply precondition was not met");
  report.check(pacer.diagnostics().max_usb_gap_ms <=
                       kUsbHeartbeatLimitMs &&
                   pacer.diagnostics().max_usb_gap_ms == 2401U,
               "fresh reserve did not reduce the measured 2951-ms empty-"
               "Grant gap to 2401 ms");
  report.check(pacer.diagnostics().max_hold_age_ms <= 2400U &&
                   pacer.diagnostics().expired_heartbeats == 0U &&
                   pacer.diagnostics().fifo_replacements == 0U &&
                   pacer.diagnostics().order_preservation_drops == 0U &&
                   backlog.diagnostics().overflow_frames == 0U,
               "reserve expansion changed age, replacement, ordering, or "
               "overflow safety");
  report.stress.heartbeat_gap_before_rx_ms = 2951U;
  report.stress.heartbeat_gap_after_rx_ms =
      pacer.diagnostics().max_usb_gap_ms;
  report.detail =
      "two older held HBs plus a fresh pre-Grant HB remain paired; the real "
      "fresh reserve bridges the fixed 2950-ms empty-UL_IDLE path while "
      "PARAM_VALUE order stays exact";
}

struct TwoStageHwCdcModel {
  std::vector<MavlinkFrame> private_ring{};
  std::vector<MavlinkFrame> host_frames{};
  std::vector<std::uint64_t> host_heartbeat_ms{};
  std::uint64_t last_internal_heartbeat_ms{0U};
  std::uint64_t max_internal_heartbeat_gap_ms{0U};

  void accept(const MavlinkFrame& frame, std::uint64_t accepted_ms) {
    if (frame.message_id == 0U) {
      if (last_internal_heartbeat_ms > 0U) {
        max_internal_heartbeat_gap_ms = std::max(
            max_internal_heartbeat_gap_ms,
            accepted_ms - last_internal_heartbeat_ms);
      }
      last_internal_heartbeat_ms = accepted_ms;
    }
    private_ring.push_back(frame);
  }

  void publish(std::uint64_t published_ms) {
    for (const MavlinkFrame& frame : private_ring) {
      host_frames.push_back(frame);
      if (frame.message_id == 0U) {
        host_heartbeat_ms.push_back(published_ms);
      }
    }
    private_ring.clear();
  }

  std::uint64_t max_host_heartbeat_gap_ms() const noexcept {
    std::uint64_t maximum = 0U;
    for (std::size_t index = 1U; index < host_heartbeat_ms.size(); ++index) {
      maximum = std::max(maximum,
                         host_heartbeat_ms[index] -
                             host_heartbeat_ms[index - 1U]);
    }
    return maximum;
  }
};

struct DestructiveHwCdcByteModel {
  std::vector<std::uint8_t> private_ring{};
  std::vector<std::uint8_t> host_bytes{};

  void accept(const std::uint8_t* bytes, std::size_t size) {
    private_ring.insert(private_ring.end(), bytes, bytes + size);
  }

  void publish_prefix(std::size_t size) {
    const std::size_t published = std::min(size, private_ring.size());
    host_bytes.insert(host_bytes.end(), private_ring.begin(),
                      private_ring.begin() +
                          static_cast<std::ptrdiff_t>(published));
    private_ring.erase(private_ring.begin(),
                       private_ring.begin() +
                           static_cast<std::ptrdiff_t>(published));
  }

  void destructive_flush_timeout() { private_ring.clear(); }

  void publish_all() { publish_prefix(private_ring.size()); }
};

std::vector<MavlinkFrame> parse_complete_frames(
    const std::vector<std::uint8_t>& bytes, TestReport& report) {
  MavlinkStreamParser parser{};
  std::vector<MavlinkFrame> frames{};
  for (const std::uint8_t byte : bytes) {
    MavlinkFrame frame{};
    const MavlinkParseStatus status = parser.push(byte, frame);
    report.check(status != MavlinkParseStatus::BadLength &&
                     status != MavlinkParseStatus::BadCrc &&
                     status != MavlinkParseStatus::UnsupportedMessage &&
                     status != MavlinkParseStatus::UnsupportedFlags,
                 "HWCDC byte model produced a parser error");
    if (status == MavlinkParseStatus::FrameReady) {
      frames.push_back(frame);
    }
  }
  return frames;
}

void check_hwcdc_flush_isolation(TestReport& report) {
  const MavlinkFrame hb = heartbeat(0x60U, 0xE5U);
  const MavlinkFrame value = param_value(0x61U, 247U, 932U);
  const MavlinkFrame following = timesync(0x62U, 0xE6U);
  report.check(hb.size == 21U && value.size == 37U,
               "R17 flush-isolation fixtures lost HB21/PARAM_VALUE37 sizes");

  // Reproduce the former mixed write exactly: the first 32-byte physical
  // stage contains HB21 plus the first 11 bytes of PARAM_VALUE. If HWCDC has
  // already exposed the HB and its destructive flush timeout clears the
  // remaining private bytes, only the 26-byte #22 suffix reaches the host.
  std::vector<std::uint8_t> mixed{};
  mixed.insert(mixed.end(), hb.bytes.begin(), hb.bytes.begin() + hb.size);
  mixed.insert(mixed.end(), value.bytes.begin(),
               value.bytes.begin() + value.size);
  DestructiveHwCdcByteModel unfenced{};
  unfenced.accept(mixed.data(), kEmbeddedPhysicalWriteBytes);
  unfenced.publish_prefix(hb.size);
  unfenced.destructive_flush_timeout();
  unfenced.accept(mixed.data() + kEmbeddedPhysicalWriteBytes,
                  mixed.size() - kEmbeddedPhysicalWriteBytes);
  unfenced.accept(following.bytes.data(), following.size);
  unfenced.publish_all();
  const std::vector<MavlinkFrame> unfenced_frames =
      parse_complete_frames(unfenced.host_bytes, report);
  report.check(unfenced_frames.size() == 2U &&
                   unfenced_frames[0U].message_id == 0U &&
                   unfenced_frames[1U].message_id == following.message_id &&
                   same_wire(following, unfenced.host_bytes,
                             hb.size + mixed.size() -
                                 kEmbeddedPhysicalWriteBytes),
               "byte model did not reproduce #22-only loss and next-frame "
               "resynchronization");

  // The required boundary keeps #22 as a complete descriptor until the HB
  // publication fence has returned. A later 32+5-byte #22 transfer therefore
  // remains byte-exact and independently parseable.
  DestructiveHwCdcByteModel isolated{};
  isolated.accept(hb.bytes.data(), hb.size);
  isolated.publish_all();
  isolated.accept(value.bytes.data(), kEmbeddedPhysicalWriteBytes);
  isolated.publish_all();
  isolated.accept(value.bytes.data() + kEmbeddedPhysicalWriteBytes,
                  value.size - kEmbeddedPhysicalWriteBytes);
  isolated.publish_all();
  isolated.accept(following.bytes.data(), following.size);
  isolated.publish_all();
  const std::vector<MavlinkFrame> isolated_frames =
      parse_complete_frames(isolated.host_bytes, report);
  report.check(isolated_frames.size() == 3U &&
                   isolated_frames[0U].message_id == 0U &&
                   isolated_frames[1U].message_id == 22U &&
                   isolated_frames[2U].message_id == following.message_id &&
                   same_wire(hb, isolated.host_bytes, 0U) &&
                   same_wire(value, isolated.host_bytes, hb.size) &&
                   same_wire(following, isolated.host_bytes,
                             hb.size + value.size),
               "publication isolation changed or lost HB/#22 bytes");

  // A matching PARAM_VALUE remains logically uncommitted while its physical
  // publication is pending. Only the successful publication callback may
  // advance the proxy to the next index.
  GroundParameterDownloadProxyConfig proxy_config{};
  proxy_config.list_strategy = GroundParameterListStrategy::NativeStream;
  GroundParameterDownloadProxy proxy{proxy_config};
  prepare_proxy_awaiting_value(proxy, report);
  const MavlinkFrame first_value = param_value(0x63U, 0U, 932U);
  report.check(proxy.preclassify_vehicle_frame(first_value, 4U) ==
                       GroundParameterProxyDisposition::Forward &&
                   proxy.expected_index() == 0U,
               "pre-publication classification advanced parameter index");
  report.check(proxy.on_vehicle_frame(first_value, true, 5U) ==
                       GroundParameterProxyDisposition::Consumed &&
                   proxy.expected_index() == 1U,
               "successful modeled publication did not advance exactly once");

  const std::filesystem::path bridge_path =
      std::filesystem::path(VC_LORA_SOURCE_ROOT) / "firmware" / "phase6" /
      "vc_lora_phase6_bridge.hpp";
  std::ifstream bridge_input(bridge_path, std::ios::binary);
  const std::string source{std::istreambuf_iterator<char>(bridge_input),
                           std::istreambuf_iterator<char>()};

  const std::size_t replay_begin =
      source.find("bool replay_ground_usb_ordered_backlog");
  const std::size_t replay_end = source.find("\n}\n", replay_begin);
  report.check(replay_begin != std::string::npos &&
                   replay_end != std::string::npos,
               "Ground ordered-backlog replay slice is missing");
  if (replay_begin != std::string::npos && replay_end != std::string::npos) {
    const std::string replay =
        source.substr(replay_begin, replay_end - replay_begin);
    const std::size_t commit_gate =
        replay.find("if (ground_paced_heartbeat_commit_active)");
    const std::size_t parameter_commit_gate =
        replay.find("ground_parameter_publish_commit_active");
    const std::size_t replay_loop =
        replay.find("while (!ground_usb_ordered_backlog.empty())");
    report.check(commit_gate != std::string::npos &&
                     parameter_commit_gate != std::string::npos &&
                     replay_loop != std::string::npos &&
                     commit_gate < replay_loop &&
                     parameter_commit_gate < replay_loop,
                 "RED: backlog can replay behind an uncommitted USB frame");
  }

  const std::size_t service_begin =
      source.find("void service_ground_usb_heartbeat_pacer");
  const std::size_t service_end = source.find("\n}\n#endif", service_begin);
  report.check(service_begin != std::string::npos &&
                   service_end != std::string::npos,
               "Ground heartbeat service slice is missing");
  if (service_begin != std::string::npos && service_end != std::string::npos) {
    const std::string service =
        source.substr(service_begin, service_end - service_begin);
    const std::size_t fresh_time =
        service.find("std::max(now_ms, monotonic_now_ms())");
    const std::size_t endpoint_refresh =
        service.find("update_ground_usb_connection(observed_ms)");
    const std::size_t admit =
        service.find("admit_ground_paced_heartbeat(lease, observed_ms)");
    const std::size_t replay_after_admit =
        service.find("replay_ground_usb_ordered_backlog", admit);
    report.check(fresh_time != std::string::npos &&
                     endpoint_refresh != std::string::npos &&
                     admit != std::string::npos &&
                     fresh_time < endpoint_refresh &&
                     endpoint_refresh < admit &&
                     replay_after_admit == std::string::npos,
                 "RED: heartbeat admission uses stale loop time or immediately "
                 "replays following data");
  }

  const std::size_t handler_begin =
      source.find("void handle_ground_validated_frame");
  const std::size_t handler_end = source.find("\n}\n#endif", handler_begin);
  report.check(handler_begin != std::string::npos &&
                   handler_end != std::string::npos,
               "Ground validated-frame handler slice is missing");
  if (handler_begin != std::string::npos && handler_end != std::string::npos) {
    const std::string handler =
        source.substr(handler_begin, handler_end - handler_begin);
    const std::size_t parameter_defer =
        handler.find("if (ground_parameter_publish_commit_active &&");
    const std::size_t preclassify =
        handler.find("preclassify_vehicle_frame(frame, now_ms)");
    const std::size_t direct_admit =
        handler.rfind("admit_validated_frame(frame)");
    const std::size_t commit_gate =
        handler.rfind("ground_paced_heartbeat_commit_active", direct_admit);
    const std::size_t parameter_commit_gate =
        handler.rfind("ground_parameter_publish_commit_active", direct_admit);
    report.check(parameter_defer != std::string::npos &&
                     preclassify != std::string::npos &&
                     parameter_defer < preclassify &&
                     direct_admit != std::string::npos &&
                     commit_gate != std::string::npos &&
                     parameter_commit_gate != std::string::npos &&
                     commit_gate < direct_admit &&
                     parameter_commit_gate < direct_admit,
                 "RED: new non-HB can bypass backlog during USB commit");
  }

  const std::size_t parameter_observer_begin =
      source.find("void observe_ground_parameter_publish_commit");
  const std::size_t parameter_observer_end =
      source.find("\n}\n", parameter_observer_begin);
  report.check(parameter_observer_begin != std::string::npos &&
                   parameter_observer_end != std::string::npos,
               "RED: PARAM_VALUE has no physical publication observer");
  if (parameter_observer_begin != std::string::npos &&
      parameter_observer_end != std::string::npos) {
    const std::string observer = source.substr(
        parameter_observer_begin,
        parameter_observer_end - parameter_observer_begin);
    const std::size_t endpoint_refresh =
        observer.find("update_ground_usb_connection(observed_ms)");
    const std::size_t endpoint_gate =
        observer.find("if (!ground_usb_endpoint_ready_state)");
    const std::size_t goal =
        observer.find("ground_parameter_publish_commit_goal");
    const std::size_t flush =
        observer.find("flush_ground_usb_transport(");
    const std::size_t reconnect =
        observer.find("update_ground_usb_connection(flush_completed_ms)");
    const std::size_t proxy_commit =
        observer.find("ground_parameter_proxy.on_vehicle_frame");
    const std::size_t fail_closed =
        observer.find("latch_runtime_fail_closed");
    report.check(endpoint_refresh != std::string::npos &&
                     endpoint_gate != std::string::npos &&
                     goal != std::string::npos && flush != std::string::npos &&
                      reconnect != std::string::npos &&
                      proxy_commit != std::string::npos &&
                      fail_closed != std::string::npos &&
                      endpoint_refresh < endpoint_gate &&
                      endpoint_gate < flush && goal < flush &&
                      flush < reconnect && reconnect < proxy_commit,
                  "RED: proxy index can advance before PARAM_VALUE physical "
                  "publication and endpoint revalidation");
  }

  const std::size_t proxy_service_begin =
      source.find("void service_ground_parameter_proxy");
  const std::size_t proxy_service_end =
      source.find("\n}\n", proxy_service_begin);
  report.check(proxy_service_begin != std::string::npos &&
                   proxy_service_end != std::string::npos,
               "Ground parameter proxy service slice is missing");
  if (proxy_service_begin != std::string::npos &&
      proxy_service_end != std::string::npos) {
    const std::string proxy_service = source.substr(
        proxy_service_begin, proxy_service_end - proxy_service_begin);
    const std::size_t publication_gate =
        proxy_service.find("ground_parameter_publish_commit_active");
    const std::size_t tick =
        proxy_service.find("ground_parameter_proxy.tick(now_ms)");
    report.check(publication_gate != std::string::npos &&
                     tick != std::string::npos && publication_gate < tick,
                 "RED: proxy timeout can run while its #22 publication is "
                 "still pending");
  }

  const std::size_t setup_begin = source.find("void setup_bridge() noexcept");
  const std::size_t setup_end = source.find("\n}\n", setup_begin);
  if (setup_begin != std::string::npos && setup_end != std::string::npos) {
    const std::string setup =
        source.substr(setup_begin, setup_end - setup_begin);
    report.check(
        setup.find("ground_parameter_publish_commit_active = false") !=
                std::string::npos &&
            setup.find("ground_parameter_publish_commit_frame = {}") !=
                std::string::npos &&
            setup.find("ground_parameter_publish_commit_goal = 0U") !=
                std::string::npos,
        "RED: boot does not clear the PARAM_VALUE publication slot");
  }

  report.check(source.find("soft_due_ms = 2100U") != std::string::npos &&
                   source.find("loop_jitter_budget_ms = 200U") !=
                       std::string::npos &&
                   source.find(
                       "kGroundUsbHeartbeatCommitDeadlineMs = 106U") !=
                       std::string::npos &&
                   source.find(
                       "ground_paced_heartbeat_commit_deadline_ms") !=
                       std::string::npos &&
                   source.find(
                       "kGroundUsbParameterCommitDeadlineMs = 100U") !=
                       std::string::npos,
               "RED: HB/PARAM publication budgets are absent from the "
               "2500-ms heartbeat proof");
  report.check(source.find("ground_paced_heartbeat_commit_loss_epoch") !=
                        std::string::npos &&
                   source.find("ground_parameter_publish_commit_loss_epoch") !=
                       std::string::npos &&
                   source.find("ground_usb_observed_loss_epoch") !=
                       std::string::npos &&
                   source.find("ground_usb_transport_epoch_healthy") !=
                       std::string::npos &&
                   source.find("Serial.txLossEpoch()") != std::string::npos &&
                   source.find("Serial.writeTxChecked(") !=
                       std::string::npos &&
                   source.find("Serial.flushTxComplete(") != std::string::npos,
               "RED: physical commits and idle transport do not bind to the "
               "HWCDC loss epoch");
  report.check(
      source.find("retire_ground_usb_publication_commits") !=
          std::string::npos,
      "RED: generic Ground fail-close can strand an active USB commit");

  report.detail =
      "HB21/#22-37 32-byte split reproduces #22-only loss and clean next-"
      "frame resync; Phase6 isolates both physical commits and advances the "
      "proxy only after PARAM_VALUE publication";
}

void check_host_drain_boundary(TestReport& report) {
  const MavlinkFrame baseline = heartbeat(0x58U, 0xD0U);
  const MavlinkFrame held = heartbeat(0x59U, 0xD1U);
  const MavlinkFrame value = param_value(0x5AU, 0U, 932U);
  const MavlinkFrame following = heartbeat(0x5BU, 0xD2U);
  report.check(baseline.size == 21U && held.size == 21U &&
                   value.size == 37U && following.size == 21U,
               "HWCDC batching fixtures lost HB21/PARAM_VALUE37 sizes");

  // R5-shaped old boundary: LocalEgress accepts on time, but two unique real
  // heartbeats become visible together only when a later endpoint publication
  // occurs. The internal <=2201-ms metric is therefore a false green.
  TwoStageHwCdcModel unfenced{};
  unfenced.accept(baseline, 1U);
  unfenced.publish(1U);
  unfenced.accept(held, 2202U);
  unfenced.accept(value, 2203U);
  unfenced.accept(following, 4216U);
  unfenced.publish(4216U);
  report.check(unfenced.max_internal_heartbeat_gap_ms == 2201U &&
                   unfenced.max_host_heartbeat_gap_ms() == 4215U &&
                   unfenced.host_heartbeat_ms.size() == 3U &&
                   unfenced.host_heartbeat_ms[2U] -
                           unfenced.host_heartbeat_ms[1U] ==
                       0U,
               "two-stage model did not reproduce 2201-ms false green and "
               "4215-ms/zero-gap host batch");

  // Publication-fenced boundary: each paced heartbeat is drained and closed
  // within the reserved 100 ms before its completion clock advances.
  TwoStageHwCdcModel fenced{};
  fenced.accept(baseline, 1U);
  fenced.publish(101U);
  fenced.accept(held, 2202U);
  fenced.publish(2302U);
  fenced.accept(value, 2303U);
  fenced.publish(2303U);
  fenced.accept(following, 4216U);
  fenced.publish(4316U);
  report.check(fenced.max_internal_heartbeat_gap_ms == 2201U &&
                   fenced.max_host_heartbeat_gap_ms() == 2201U &&
                   fenced.max_host_heartbeat_gap_ms() <=
                       kUsbHeartbeatLimitMs,
               "bounded HWCDC publication fence did not close the host gap");

  const std::array<MavlinkFrame, 4U> expected{{
      baseline, held, value, following}};
  report.check(unfenced.host_frames.size() == expected.size() &&
                   fenced.host_frames.size() == expected.size(),
               "two-stage model lost or duplicated a complete frame");
  for (std::size_t index = 0U; index < expected.size() &&
                              index < unfenced.host_frames.size() &&
                              index < fenced.host_frames.size();
       ++index) {
    const auto exact_frame = [](const MavlinkFrame& left,
                                const MavlinkFrame& right) noexcept {
      return left.size == right.size &&
             std::equal(left.bytes.begin(), left.bytes.begin() + left.size,
                        right.bytes.begin());
    };
    report.check(exact_frame(expected[index],
                             unfenced.host_frames[index]) &&
                     exact_frame(expected[index], fenced.host_frames[index]),
                 "HWCDC fence changed frame bytes or HB/#22 ordering");
  }
  report.stress.heartbeat_gap_before_rx_ms =
      unfenced.max_host_heartbeat_gap_ms();
  report.stress.heartbeat_gap_after_rx_ms =
      fenced.max_host_heartbeat_gap_ms();
  report.detail =
      "two-stage HWCDC reproduces internal=2201/host=4215+0 ms; bounded "
      "publication fence yields host max=2201 ms with exact HB21/#22-37 order";
}

void check_phase6_source_contract(TestReport& report) {
  const std::filesystem::path source_root{VC_LORA_SOURCE_ROOT};
  const std::filesystem::path bridge_path =
      source_root / "firmware" / "phase6" / "vc_lora_phase6_bridge.hpp";
  std::ifstream bridge_input(bridge_path, std::ios::binary);
  const std::string source{std::istreambuf_iterator<char>(bridge_input),
                           std::istreambuf_iterator<char>()};
  const auto has = [&source](const char* token) {
    return source.find(token) != std::string::npos;
  };
  report.check(has("vc_lora/ground_usb_heartbeat_pacer.hpp") &&
                   has("GroundUsbHeartbeatPacer ground_usb_heartbeat_pacer") &&
                   has("admit_ground_paced_heartbeat") &&
                   has("service_ground_usb_heartbeat_pacer") &&
                   has("observe_ground_paced_heartbeat_commit") &&
                   has("ground_paced_heartbeat_commit_goal") &&
                   has("bytes_committed") && has("write_pending()") &&
                   has("availableForWrite()"),
               "RED: Phase 6 Ground USB path is not wired to the pacer");
  report.check(has("ground_usb_can_accept_downlink") &&
                      has("pump_ground_usb_egress") &&
                      has("pump_local_egress_if_connected"),
                  "RED: disconnected HWCDC can still admit/commit Ground USB "
                  "downlink bytes");
  report.check(
      has("ground_usb_transport_published_bytes") &&
          has("GroundUsbTransportEpochSnapshot") &&
          has("assess_ground_usb_transport_epoch"),
      "RED: Ground USB loss-epoch recovery lacks a physical-publication "
      "watermark decision");

  const std::size_t epoch_begin =
      source.find("bool ground_usb_transport_epoch_healthy");
  const std::size_t epoch_end = source.find("\n}\n", epoch_begin);
  report.check(epoch_begin != std::string::npos &&
                   epoch_end != std::string::npos,
               "Ground USB loss-epoch health slice is missing");
  if (epoch_begin != std::string::npos && epoch_end != std::string::npos) {
    const std::string epoch =
        source.substr(epoch_begin, epoch_end - epoch_begin);
    const std::size_t snapshot =
        epoch.find("GroundUsbTransportEpochSnapshot");
    const std::size_t assess =
        epoch.find("assess_ground_usb_transport_epoch", snapshot);
    const std::size_t recoverable = epoch.find(
        "GroundUsbTransportEpochDisposition::RecoverableBoundary", assess);
    const std::size_t discard_rx =
        epoch.find("discard_ground_usb_rx_bytes", recoverable);
    const std::size_t discard_backlog =
        epoch.find("discard_ground_ordered_backlog", recoverable);
    const std::size_t discard_heartbeats =
        epoch.find("discard_ground_held_heartbeats", recoverable);
    const std::size_t parser_reset =
        epoch.find("ground_usb_parser = {}", recoverable);
    const std::size_t rebaseline =
        epoch.find("ground_usb_observed_loss_epoch = observed", parser_reset);
    const std::size_t fail_closed =
        epoch.find("latch_runtime_fail_closed", assess);
    report.check(
        snapshot != std::string::npos && assess != std::string::npos &&
            recoverable != std::string::npos &&
            discard_rx != std::string::npos &&
            discard_backlog != std::string::npos &&
            discard_heartbeats != std::string::npos &&
            parser_reset != std::string::npos &&
            rebaseline != std::string::npos &&
            fail_closed != std::string::npos && snapshot < assess &&
            assess < recoverable && recoverable < discard_rx &&
            discard_rx < discard_backlog &&
            discard_backlog < discard_heartbeats &&
            discard_heartbeats < parser_reset && parser_reset < rebaseline,
        "RED: a clean BUS_RESET is not isolated and recovered, or an "
        "uncertain USB byte can avoid fail-close");
  }

  const std::size_t pump_begin =
      source.find("void pump_ground_usb_egress");
  const std::size_t pump_end = source.find("\n}\n", pump_begin);
  report.check(pump_begin != std::string::npos &&
                   pump_end != std::string::npos,
               "Ground USB pump slice is missing");
  if (pump_begin != std::string::npos && pump_end != std::string::npos) {
    const std::string pump = source.substr(pump_begin, pump_end - pump_begin);
    const std::size_t fresh_time =
        pump.find("std::max(now_ms, monotonic_now_ms())");
    const std::size_t update =
        pump.find("update_ground_usb_connection(observed_ms)");
    const std::size_t epoch =
        pump.find("ground_usb_transport_epoch_healthy(observed_ms)");
    const std::size_t write =
        pump.find("pump_local_egress_if_connected");
    report.check(fresh_time != std::string::npos &&
                     update != std::string::npos &&
                     epoch != std::string::npos &&
                     write != std::string::npos && fresh_time < update &&
                     update < epoch && epoch < write,
                 "RED: stale pump time or LocalEgress suffix can cross an "
                 "HWCDC loss epoch before the next publication commit");
  }

  const char* connection_signature =
      "void update_ground_usb_connection(std::uint64_t now_ms)";
  const std::size_t connection_declaration =
      source.find(connection_signature);
  const std::size_t connection_begin =
      connection_declaration == std::string::npos
          ? std::string::npos
          : source.find(connection_signature, connection_declaration + 1U);
  const std::size_t connection_end =
      source.find("\n}\n", connection_begin);
  report.check(connection_begin != std::string::npos &&
                   connection_end != std::string::npos,
               "Ground USB connection update slice is missing");
  if (connection_begin != std::string::npos &&
      connection_end != std::string::npos) {
    const std::string connection =
        source.substr(connection_begin, connection_end - connection_begin);
    const std::size_t irreversible =
        connection.find("had_irreversible_usb_bytes");
    const std::size_t heartbeat =
        connection.find("ground_paced_heartbeat_commit_active", irreversible);
    const std::size_t parameter =
        connection.find("ground_parameter_publish_commit_active", heartbeat);
    const std::size_t pending =
        connection.find("egress.write_pending()", parameter);
    const std::size_t queued =
        connection.find("egress.queued_bytes()", pending);
    const std::size_t unpublished = connection.find(
        "ground_usb_transport_published_bytes", queued);
    const std::size_t retire =
        connection.find("retire_ground_usb_publication_commits", unpublished);
    const std::size_t fail_closed =
        connection.find("if (had_irreversible_usb_bytes)", retire);
    const std::size_t latch =
        connection.find("latch_runtime_fail_closed()", fail_closed);
    const std::size_t discard_rx =
        connection.find("discard_ground_usb_rx_bytes", latch);
    const std::size_t parser_reset =
        connection.find("ground_usb_parser = {}", discard_rx);
    report.check(irreversible != std::string::npos &&
                     heartbeat != std::string::npos &&
                     parameter != std::string::npos &&
                      pending != std::string::npos &&
                      queued != std::string::npos &&
                      unpublished != std::string::npos &&
                      retire != std::string::npos &&
                      fail_closed != std::string::npos &&
                      latch != std::string::npos &&
                      discard_rx != std::string::npos &&
                      parser_reset != std::string::npos &&
                      irreversible < heartbeat &&
                      heartbeat < parameter && parameter < pending &&
                      pending < queued && queued < unpublished &&
                      unpublished < retire && retire < fail_closed &&
                      fail_closed < latch && latch < discard_rx &&
                      discard_rx < parser_reset,
                  "RED: confirmed USB disconnect can resume after a partial "
                  "HB/PARAM/ordinary LocalEgress publication or retain an "
                  "old-session RX suffix");
  }

  const std::size_t health_begin =
      source.find("bool ground_usb_runtime_healthy_or_retire");
  const std::size_t health_end = source.find("\n}\n", health_begin);
  report.check(health_begin != std::string::npos &&
                   health_end != std::string::npos,
               "Ground USB runtime health slice is missing");
  if (health_begin != std::string::npos &&
      health_end != std::string::npos) {
    const std::string health =
        source.substr(health_begin, health_end - health_begin);
    const std::size_t fresh_time =
        health.find("std::max(now_ms, monotonic_now_ms())");
    const std::size_t epoch =
        health.find("ground_usb_transport_epoch_healthy(observed_ms)");
    const std::size_t retire =
        health.find("retire_ground_usb_publication_commits(observed_ms)");
    report.check(fresh_time != std::string::npos &&
                     epoch != std::string::npos &&
                     retire != std::string::npos && fresh_time < epoch &&
                     epoch < retire,
                 "RED: checked-write loss epoch can remain latent through a "
                 "same-loop TDD action");
  }

  const std::size_t fence_begin =
      source.find("bool flush_ground_usb_transport");
  const std::size_t fence_end =
      source.find("\n}\n", fence_begin);
  report.check(fence_begin != std::string::npos &&
                   fence_end != std::string::npos,
               "Ground HWCDC publication-fence slice is missing");
  if (fence_begin != std::string::npos &&
      fence_end != std::string::npos) {
    const std::string fence =
        source.substr(fence_begin, fence_end - fence_begin);
    report.check(fence.find("Serial.flushTxComplete(") !=
                         std::string::npos &&
                     fence.find("Serial.flush()") == std::string::npos &&
                     fence.find("monotonic_now_ms()") != std::string::npos,
                 "RED: HWCDC fence is not result-bearing and non-destructive");
  }

  const std::size_t commit_begin =
      source.find("void observe_ground_paced_heartbeat_commit");
  const std::size_t commit_end =
      source.find("\n}\n", commit_begin);
  report.check(commit_begin != std::string::npos &&
                   commit_end != std::string::npos,
               "Ground paced-heartbeat commit slice is missing");
  if (commit_begin != std::string::npos &&
      commit_end != std::string::npos) {
    const std::string commit =
        source.substr(commit_begin, commit_end - commit_begin);
    const std::size_t endpoint_refresh =
        commit.find("update_ground_usb_connection(observed_ms)");
    const std::size_t deadline_gate = commit.find(
        "observed_ms >= ground_paced_heartbeat_commit_deadline_ms");
    const std::size_t endpoint_gate =
        commit.find("if (!ground_usb_endpoint_ready_state)");
    const std::size_t remaining = commit.find(
        "ground_paced_heartbeat_commit_deadline_ms - observed_ms");
    const std::size_t flush =
        commit.find("flush_ground_usb_transport(");
    const std::size_t refresh =
        commit.find("flush_completed_ms", flush);
    const std::size_t reconnect = commit.find(
        "update_ground_usb_connection(flush_completed_ms)", refresh);
    const std::size_t complete =
        commit.find("ground_usb_heartbeat_pacer.complete_emit", reconnect);
    const std::size_t watermark =
        commit.find("ground_usb_transport_published_bytes", reconnect);
    const std::size_t fail_closed =
        commit.find("latch_runtime_fail_closed", reconnect);
    report.check(endpoint_refresh != std::string::npos &&
                     deadline_gate != std::string::npos &&
                     endpoint_gate != std::string::npos &&
                     remaining != std::string::npos &&
                     flush != std::string::npos &&
                      refresh != std::string::npos &&
                      reconnect != std::string::npos &&
                       complete != std::string::npos &&
                       watermark != std::string::npos &&
                        fail_closed != std::string::npos &&
                       endpoint_refresh < deadline_gate &&
                       deadline_gate < endpoint_gate &&
                       endpoint_gate < remaining && remaining < flush &&
                       flush < refresh && refresh < reconnect &&
                        reconnect < watermark && watermark < complete &&
                        reconnect < fail_closed,
                   "RED: a partial paced heartbeat can outlive its absolute "
                   "publication deadline or acknowledge before the bounded "
                   "HWCDC fence is revalidated");
  }

  const std::size_t parameter_commit_begin =
      source.find("void observe_ground_parameter_publish_commit");
  const std::size_t parameter_commit_end =
      source.find("\n}\n", parameter_commit_begin);
  report.check(parameter_commit_begin != std::string::npos &&
                   parameter_commit_end != std::string::npos,
               "Ground parameter publication-commit slice is missing");
  if (parameter_commit_begin != std::string::npos &&
      parameter_commit_end != std::string::npos) {
    const std::string commit = source.substr(
        parameter_commit_begin, parameter_commit_end - parameter_commit_begin);
    const std::size_t success_gate =
        commit.find("if (!transport_published");
    const std::size_t watermark =
        commit.find("ground_usb_transport_published_bytes", success_gate);
    const std::size_t proxy_commit =
        commit.find("ground_parameter_proxy.on_vehicle_frame", watermark);
    report.check(success_gate != std::string::npos &&
                     watermark != std::string::npos &&
                     proxy_commit != std::string::npos &&
                     success_gate < watermark && watermark < proxy_commit,
                 "RED: PARAM_VALUE can be acknowledged without advancing the "
                 "physical-publication watermark");
  }

  const std::size_t handler_begin =
      source.find("void handle_ground_validated_frame");
  const std::size_t handler_end =
      source.find("\n}\n#endif", handler_begin);
  report.check(handler_begin != std::string::npos &&
                   handler_end != std::string::npos,
               "Phase6 Ground validated-frame handler slice is missing");
  if (handler_begin != std::string::npos &&
      handler_end != std::string::npos) {
    const std::string handler =
        source.substr(handler_begin, handler_end - handler_begin);
    const std::size_t update =
        handler.find("update_ground_usb_connection(now_ms)");
    const std::size_t transport_epoch =
        handler.find("ground_usb_transport_epoch_healthy(now_ms)");
    const std::size_t primary =
        handler.find("ground_is_primary_vehicle_heartbeat(frame)");
    const std::size_t parameter_defer =
        handler.find("if (ground_parameter_publish_commit_active &&");
    const std::size_t preclassify =
        handler.find("preclassify_vehicle_frame(frame, now_ms)");
    const std::size_t disconnected =
        handler.find("if (!ground_usb_can_accept_downlink())");
    const std::size_t reject =
        handler.find("reject_ground_usb_frame(frame, now_ms)", disconnected);
    const std::size_t pacer =
        handler.find("ground_usb_heartbeat_pacer", disconnected);
    const std::size_t backlog =
        handler.find("ground_usb_ordered_backlog", disconnected);
    const std::size_t admission =
        handler.find("admit_validated_frame(frame)", disconnected);
    report.check(update != std::string::npos &&
                     transport_epoch != std::string::npos &&
                     update < transport_epoch && transport_epoch < primary &&
                     primary < parameter_defer &&
                     parameter_defer < preclassify &&
                     preclassify < disconnected && disconnected < reject &&
                     reject < pacer && reject < backlog && reject < admission,
                  "Ground handler does not reject an HWCDC loss epoch or "
                  "isolate an in-flight PARAM_VALUE before classification "
                  "while retaining normal "
                 "preclassify->disconnected rejection before "
                 "pacer/backlog/egress admission");

    if (parameter_defer != std::string::npos &&
        preclassify != std::string::npos && parameter_defer < preclassify) {
      const std::string defer_block =
          handler.substr(parameter_defer, preclassify - parameter_defer);
      report.check(
          defer_block.find("frame.message_id == 22U") != std::string::npos &&
              defer_block.find("ground_usb_can_accept_downlink()") !=
                  std::string::npos &&
              defer_block.find("ground_usb_ordered_backlog.enqueue(frame, "
                               "false)") != std::string::npos &&
              defer_block.find("return;") != std::string::npos,
          "Ground handler early PARAM_VALUE deferral is not restricted to "
          "a live endpoint and a complete ordered-backlog descriptor");
    }
  }

  const std::size_t loop_begin = source.find("void loop_bridge() noexcept");
  const std::size_t ground_ingress_begin = source.find(
      "#else\n  // Classify a newly arrived GCS PARAM_SET", loop_begin);
  const std::size_t ground_ingress_end =
      source.find("\n#endif", ground_ingress_begin);
  report.check(loop_begin != std::string::npos &&
                   ground_ingress_begin != std::string::npos &&
                   ground_ingress_end != std::string::npos,
               "Phase6 Ground ingress slice is missing");
  if (ground_ingress_begin != std::string::npos &&
      ground_ingress_end != std::string::npos) {
    const std::string ingress = source.substr(
        ground_ingress_begin, ground_ingress_end - ground_ingress_begin);
    const std::size_t update =
        ingress.find("update_ground_usb_connection(now_ms)");
    const std::size_t epoch =
        ingress.find("ground_usb_runtime_healthy_or_retire(now_ms)", update);
    const std::size_t collect =
        ingress.find("collect_local_ingress(now_ms)", epoch);
    report.check(update != std::string::npos && epoch != std::string::npos &&
                     collect != std::string::npos && update < epoch &&
                     epoch < collect,
                 "RED: pre-reset GCS bytes can reach the MAVLink parser before "
                 "loss-epoch isolation");
  }
  const std::size_t ground_pump_begin = source.find(
      "#else\n  service_ground_usb_heartbeat_pacer(now_ms);", loop_begin);
  const std::size_t ground_pump_end =
      source.find("\n#endif", ground_pump_begin);
  report.check(loop_begin != std::string::npos &&
                   ground_pump_begin != std::string::npos &&
                   ground_pump_end != std::string::npos,
               "Phase6 Ground loop pump slice is missing");
  if (ground_pump_begin != std::string::npos &&
      ground_pump_end != std::string::npos) {
    const std::string ground_pumps = source.substr(
        ground_pump_begin, ground_pump_end - ground_pump_begin);
    constexpr const char* wrapper = "pump_ground_usb_egress(now_ms);";
    std::size_t wrapper_count = 0U;
    for (std::size_t match = ground_pumps.find(wrapper);
         match != std::string::npos;
         match = ground_pumps.find(wrapper, match + 1U)) {
      ++wrapper_count;
    }
    report.check(wrapper_count == 2U &&
                     ground_pumps.find("pump_local_egress(") ==
                         std::string::npos &&
                     ground_pumps.find("Serial.write(") == std::string::npos &&
                     ground_pumps.find(
                         "ground_usb_runtime_healthy_or_retire") !=
                         std::string::npos,
                 "both Ground loop pumps are not wrapper-only");
  }
  report.check(has("e220_subpacket_service_floor_ms == 550U"),
               "Ground USB integration changed the E220 550-ms service floor");

  const std::filesystem::path contract_path =
      source_root / "firmware" / "phase6" / "README.md";
  std::ifstream contract_input(contract_path, std::ios::binary);
  const std::string contract{std::istreambuf_iterator<char>(contract_input),
                             std::istreambuf_iterator<char>()};
  report.check(contract.find("cannot retract") != std::string::npos &&
                   contract.find("mid-disconnect") != std::string::npos,
               "RED: unretractable byte-ring mid-disconnect limit is undocumented");
  report.detail =
      "source contract keeps Vehicle/TDD/RF/profile unchanged and wires only "
      "Ground RF primary heartbeats through admission and physical commit";
}

}  // namespace

TestReport run_ground_usb_heartbeat_phase6_test(const std::string& test_id,
                                                std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;
  if (test_id == "IT-GROUND-USB-HB-PHASE6-ORDER-001") {
    check_order_and_commit(report);
  } else if (test_id ==
             "IT-GROUND-USB-HB-PHASE6-HOST-FILTER-001") {
    check_host_presence_filter(report);
  } else if (test_id ==
             "IT-GROUND-USB-HB-PHASE6-ENDPOINT-DIP-001") {
    check_endpoint_dip_retention(report);
  } else if (test_id == "IT-GROUND-USB-HB-PHASE6-FAILSAFE-001") {
    check_overflow_and_proxy_nonadvance(report);
  } else if (test_id == "IT-GROUND-USB-HB-PHASE6-DUE-001") {
    check_due_and_cadence(report);
  } else if (test_id == "IT-GROUND-USB-HB-PHASE6-BURST-001") {
    check_real_burst_blackout(report);
  } else if (test_id ==
             "IT-GROUND-USB-HB-PHASE6-PREGRANT-RESERVE-001") {
    check_pregrant_reserve_capacity(report);
  } else if (test_id == "IT-GROUND-USB-HB-PHASE6-HOST-DRAIN-001") {
    check_host_drain_boundary(report);
  } else if (test_id ==
             "IT-GROUND-USB-HB-PHASE6-FLUSH-ISOLATION-001") {
    check_hwcdc_flush_isolation(report);
  } else if (test_id == "IT-GROUND-USB-HB-PHASE6-STALE-001") {
    check_stale_pair_recovery(report);
  } else if (test_id == "UT-GROUND-USB-HB-BACKLOG-CAPACITY-001") {
    check_backlog_capacity_and_atomicity(report);
  } else if (test_id == "IT-GROUND-USB-HB-PHASE6-SOURCE-001") {
    check_phase6_source_contract(report);
  } else {
    report.check(false, "unknown Ground USB Phase 6 integration test ID");
  }
  return report;
}

}  // namespace vc_lora::test
