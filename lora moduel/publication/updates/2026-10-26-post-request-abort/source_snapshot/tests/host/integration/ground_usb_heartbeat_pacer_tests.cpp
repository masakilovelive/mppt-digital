#include "test_support.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "vc_lora/mavlink_frame.hpp"
#include "vc_lora/tdd_types.hpp"

#if __has_include("vc_lora/ground_usb_heartbeat_pacer.hpp")
#include "vc_lora/ground_usb_heartbeat_pacer.hpp"
#define VC_LORA_HAS_GROUND_USB_HEARTBEAT_PACER 1
#else
#define VC_LORA_HAS_GROUND_USB_HEARTBEAT_PACER 0

// RED-only compile shim.  The production header deliberately does not exist
// yet.  Keeping the expected surface here lets every behavioural test compile
// and report a deterministic missing-implementation failure instead of
// stopping the rest of the host binary at preprocessing time.
namespace vc_lora {

struct GroundUsbHeartbeatPacerConfig {
  std::uint32_t soft_due_ms{2200U};
  std::uint32_t hard_max_age_ms{2400U};
  std::uint32_t loop_jitter_budget_ms{100U};
  std::uint32_t physical_write_budget_ms{6U};
  std::uint32_t transport_flush_budget_ms{100U};
  std::uint32_t supply_window_ms{6200U};
  std::uint8_t minimum_supply_frames{3U};
  std::uint8_t target_system_id{1U};
  std::uint8_t target_component_id{1U};
};

enum class GroundUsbHeartbeatIngestStatus : std::uint8_t {
  Held,
  ReplacedOldest,
  PassThrough,
  Invalid,
};

enum class GroundUsbHeartbeatBarrierStatus : std::uint8_t {
  Clear,
  LeaseReady,
  BlockedByPendingEmit,
  DroppedForOrder,
};

struct GroundUsbHeartbeatLease {
  std::uint32_t token{0U};
  MavlinkFrame frame{};
  std::uint64_t rf_received_ms{0U};
};

struct GroundUsbHeartbeatPacerDiagnostics {
  std::uint64_t valid_real_heartbeats{0U};
  std::uint64_t emitted_heartbeats{0U};
  std::uint64_t expired_heartbeats{0U};
  std::uint64_t fifo_replacements{0U};
  std::uint64_t invalid_heartbeats{0U};
  std::uint64_t foreign_heartbeats_passthrough{0U};
  std::uint64_t duplicate_ingests{0U};
  std::uint64_t rejected_emits{0U};
  std::uint64_t duplicate_completions{0U};
  std::uint64_t order_barrier_blocks{0U};
  std::uint64_t order_preservation_drops{0U};
  std::uint64_t supply_shortage_events{0U};
  std::uint64_t usb_backlog_non_guaranteed_events{0U};
  std::uint64_t usb_writer_unavailable_events{0U};
  std::size_t max_observed_usb_backlog_bytes{0U};
  std::uint64_t max_hold_age_ms{0U};
  std::uint64_t max_usb_gap_ms{0U};
  std::size_t max_fifo_depth{0U};
};

class GroundUsbHeartbeatPacer {
 public:
  explicit GroundUsbHeartbeatPacer(
      const GroundUsbHeartbeatPacerConfig&) noexcept {}

  static constexpr std::size_t capacity() noexcept { return 2U; }
  GroundUsbHeartbeatIngestStatus ingest(const MavlinkFrame&,
                                        std::uint64_t) noexcept {
    return GroundUsbHeartbeatIngestStatus::Invalid;
  }
  void set_usb_connected(bool, std::uint64_t) noexcept {}
  void expire(std::uint64_t) noexcept {}
  bool select_due(std::uint64_t, bool,
                  GroundUsbHeartbeatLease&) noexcept {
    return false;
  }
  GroundUsbHeartbeatBarrierStatus select_before_next_frame(
      std::uint64_t, GroundUsbHeartbeatLease&) noexcept {
    return GroundUsbHeartbeatBarrierStatus::Clear;
  }
  bool discard_for_order(std::uint64_t) noexcept { return false; }
  bool complete_emit(std::uint32_t, TxResult, std::uint64_t) noexcept {
    return false;
  }
  void observe_usb_egress(std::size_t, bool, bool) noexcept {}
  bool guarantee_available(std::uint64_t) noexcept { return false; }
  std::size_t queued() const noexcept { return 0U; }
  const GroundUsbHeartbeatPacerDiagnostics& diagnostics() const noexcept {
    return diagnostics_;
  }

 private:
  GroundUsbHeartbeatPacerDiagnostics diagnostics_{};
};

}  // namespace vc_lora
#endif

namespace vc_lora::test {
namespace {

constexpr std::uint64_t kSoftDueMs = 2200U;
constexpr std::uint64_t kHardMaxAgeMs = 2400U;
constexpr std::uint64_t kUsbGapLimitMs = 2500U;
constexpr std::uint64_t kRadioHeartbeatBlackoutMs = 3200U;
constexpr std::uint64_t kLoopJitterMs = 100U;
constexpr std::uint64_t kCurrentFrameBlockMs = 49U;
constexpr std::uint64_t kHeartbeatWriteMs = 6U;
constexpr std::uint64_t kTransportFlushMs = 100U;
constexpr std::uint64_t kSupplyWindowMs = 6200U;

struct Emission {
  std::uint8_t sequence{0U};
  std::uint64_t completed_ms{0U};
  std::uint64_t rf_received_ms{0U};
  std::uint64_t wire_hash{0U};
};

GroundUsbHeartbeatPacerConfig fixed_config() noexcept {
  GroundUsbHeartbeatPacerConfig config{};
  config.soft_due_ms = static_cast<std::uint32_t>(kSoftDueMs);
  config.hard_max_age_ms = static_cast<std::uint32_t>(kHardMaxAgeMs);
  config.loop_jitter_budget_ms = static_cast<std::uint32_t>(kLoopJitterMs);
  config.physical_write_budget_ms =
      static_cast<std::uint32_t>(kHeartbeatWriteMs);
  config.transport_flush_budget_ms =
      static_cast<std::uint32_t>(kTransportFlushMs);
  config.supply_window_ms = static_cast<std::uint32_t>(kSupplyWindowMs);
  config.minimum_supply_frames = 3U;
  config.target_system_id = 1U;
  config.target_component_id = 1U;
  return config;
}

std::uint64_t hash_wire(const MavlinkFrame& frame) noexcept {
  std::uint64_t hash = 1469598103934665603ULL;
  for (std::size_t index = 0U; index < frame.size; ++index) {
    hash ^= frame.bytes[index];
    hash *= 1099511628211ULL;
  }
  return hash;
}

bool same_wire(const MavlinkFrame& left,
               const MavlinkFrame& right) noexcept {
  return left.size == right.size && left.sequence == right.sequence &&
         left.message_id == right.message_id &&
         std::memcmp(left.bytes.data(), right.bytes.data(), left.size) == 0;
}

MavlinkFrame make_heartbeat(std::uint8_t sequence,
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

MavlinkFrame make_timesync(std::uint8_t sequence) noexcept {
  std::array<std::uint8_t, 16U> payload{};
  payload[0U] = 0x55U;
  MavlinkFrame frame{};
  (void)encode_mavlink_v2(sequence, 255U, 190U, 111U,
                          payload.data(), payload.size(), frame);
  return frame;
}

void check_api_present(TestReport& report) {
  report.check(VC_LORA_HAS_GROUND_USB_HEARTBEAT_PACER != 0,
               "RED: missing vc_lora/ground_usb_heartbeat_pacer.hpp");
  report.check(GroundUsbHeartbeatPacer::capacity() == 3U,
               "Ground USB real-heartbeat FIFO capacity is not exactly three");
}

bool select_and_complete(GroundUsbHeartbeatPacer& pacer,
                         std::uint64_t selection_ms,
                         std::uint64_t completion_ms,
                         bool normal_frame_active,
                         std::vector<Emission>& emissions,
                         TestReport& report,
                         MavlinkFrame* selected = nullptr) {
  GroundUsbHeartbeatLease lease{};
  if (!pacer.select_due(selection_ms, normal_frame_active, lease)) {
    return false;
  }
  MavlinkFrame validated{};
  report.check(
      validate_mavlink_frame(lease.frame.bytes.data(), lease.frame.size,
                             validated) == MavlinkParseStatus::FrameReady &&
          validated.message_id == 0U,
      "pacer selected a non-heartbeat or CRC-invalid frame");
  report.check(lease.token != 0U,
               "pacer issued a zero emit token");
  if (selected != nullptr) {
    *selected = lease.frame;
  }
  if (!pacer.complete_emit(lease.token, TxResult::Accepted, completion_ms)) {
    report.check(false, "accepted USB heartbeat was not committed");
    return false;
  }
  emissions.push_back({lease.frame.sequence, completion_ms,
                       lease.rf_received_ms, hash_wire(lease.frame)});
  return true;
}

void check_integrity_contract(TestReport& report) {
  check_api_present(report);
  GroundUsbHeartbeatPacer pacer{fixed_config()};
  pacer.set_usb_connected(true, 0U);

  const MavlinkFrame normal = make_timesync(0x30U);
  MavlinkFrame foreign = make_heartbeat(0x32U, 0x32U);
  foreign.bytes[5U] = 42U;
  MavlinkFrame foreign_validated{};
  report.check(validate_mavlink_frame(foreign.bytes.data(), foreign.size,
                                      foreign_validated) !=
                   MavlinkParseStatus::FrameReady,
               "foreign-HB test setup unexpectedly retained a valid CRC");
  std::array<std::uint8_t, 9U> foreign_payload{};
  foreign_payload[4U] = 2U;
  foreign_payload[5U] = 3U;
  foreign_payload[7U] = 4U;
  foreign_payload[8U] = 3U;
  (void)encode_mavlink_v2(0x32U, 1U, 42U, 0U,
                          foreign_payload.data(), foreign_payload.size(),
                          foreign);
  MavlinkFrame corrupt = make_heartbeat(0x31U, 0x31U);
  if (corrupt.size > 0U) {
    corrupt.bytes[corrupt.size - 1U] ^= 0x80U;
  }
  report.check(pacer.ingest(normal, 10U) ==
                   GroundUsbHeartbeatIngestStatus::PassThrough,
               "non-heartbeat frame was not passed through");
  report.check(pacer.ingest(foreign, 15U) ==
                   GroundUsbHeartbeatIngestStatus::PassThrough &&
                   pacer.queued() == 0U,
               "foreign component HB displaced the primary reserve");
  report.check(pacer.ingest(corrupt, 20U) ==
                   GroundUsbHeartbeatIngestStatus::Invalid,
               "CRC-invalid heartbeat was retained");

  const MavlinkFrame heartbeat1 = make_heartbeat(0x41U, 0xA1U);
  const MavlinkFrame heartbeat2 = make_heartbeat(0x42U, 0xA2U);
  const MavlinkFrame heartbeat3 = make_heartbeat(0x43U, 0xA3U);
  const MavlinkFrame heartbeat4 = make_heartbeat(0x44U, 0xA4U);
  const MavlinkFrame heartbeat5 = make_heartbeat(0x45U, 0xA5U);
  report.check(pacer.ingest(heartbeat1, 100U) ==
                   GroundUsbHeartbeatIngestStatus::Held &&
                   pacer.ingest(heartbeat2, 200U) ==
                       GroundUsbHeartbeatIngestStatus::Held &&
                   pacer.ingest(heartbeat3, 300U) ==
                       GroundUsbHeartbeatIngestStatus::Held,
               "three unique real heartbeats did not fill FIFO3");
  report.check(pacer.ingest(heartbeat2, 201U) ==
                   GroundUsbHeartbeatIngestStatus::Held &&
                   pacer.queued() == 3U,
               "duplicate primary heartbeat was queued twice");
  report.check(pacer.ingest(heartbeat4, 400U) ==
                   GroundUsbHeartbeatIngestStatus::ReplacedOldest,
               "FIFO3 did not replace its oldest unsent heartbeat");
  report.check(pacer.queued() == 3U,
               "heartbeat FIFO exceeded or underfilled capacity three");

  GroundUsbHeartbeatLease first{};
  report.check(pacer.select_due(400U, false, first),
               "first real heartbeat was not immediately selectable");
  report.check(same_wire(first.frame, heartbeat2),
               "FIFO replacement or first selection changed exact wire bytes");
  GroundUsbHeartbeatLease duplicate_start{};
  report.check(!pacer.select_due(400U, false, duplicate_start),
               "pending heartbeat obtained a second physical-send lease");
  report.check(pacer.ingest(heartbeat5, 500U) ==
                       GroundUsbHeartbeatIngestStatus::ReplacedOldest &&
                   same_wire(first.frame, heartbeat2),
               "full FIFO3 replacement changed the immutable leased head");
  report.check(pacer.complete_emit(first.token, TxResult::Accepted, 500U),
               "first exact heartbeat commit failed");
  report.check(!pacer.complete_emit(first.token, TxResult::Accepted, 501U),
               "same heartbeat token committed twice");

  GroundUsbHeartbeatLease early{};
  report.check(!pacer.select_due(2593U, false, early),
               "second heartbeat was emitted before its bounded "
               "hard-age completion budget");
  GroundUsbHeartbeatLease second{};
  report.check(pacer.select_due(2594U, false, second) &&
                   same_wire(second.frame, heartbeat4),
               "second heartbeat was not byte-exact at its age deadline");
  report.check(pacer.complete_emit(second.token, TxResult::Accepted, 2800U),
               "second exact heartbeat fenced completion failed");
  GroundUsbHeartbeatLease third{};
  report.check(pacer.select_due(2800U, false, third) &&
                   same_wire(third.frame, heartbeat5),
               "third heartbeat was not retained byte-exactly after FIFO3 "
               "replacement");
  report.check(pacer.complete_emit(third.token, TxResult::Accepted, 2900U),
               "third exact heartbeat fenced completion failed");
  report.check(pacer.queued() == 0U,
               "emit-once commits left a duplicate heartbeat queued");

  // MAVLink's 8-bit sequence can wrap to an identical wire image. Suppress
  // an immediate replay, but do not blacklist that valid image forever.
  GroundUsbHeartbeatPacer wrap_pacer{fixed_config()};
  wrap_pacer.set_usb_connected(true, 0U);
  const MavlinkFrame wrapped = make_heartbeat(0x00U, 0x5AU);
  std::vector<Emission> wrap_emissions{};
  report.check(wrap_pacer.ingest(wrapped, 0U) ==
                   GroundUsbHeartbeatIngestStatus::Held &&
                   select_and_complete(wrap_pacer, 0U, 0U, false,
                                       wrap_emissions, report) &&
                   wrap_pacer.ingest(wrapped, 1U) ==
                       GroundUsbHeartbeatIngestStatus::Held &&
                   wrap_pacer.queued() == 0U,
               "immediate exact replay was not suppressed");
  const std::uint64_t duplicates_after_immediate =
      wrap_pacer.diagnostics().duplicate_ingests;
  report.check(wrap_pacer.ingest(wrapped, 2400U) ==
                   GroundUsbHeartbeatIngestStatus::Held &&
                   wrap_pacer.queued() == 0U &&
                   wrap_pacer.diagnostics().duplicate_ingests ==
                       duplicates_after_immediate + 1U,
               "exact replay at hard-age boundary was not suppressed");
  const std::uint64_t duplicates_at_boundary =
      wrap_pacer.diagnostics().duplicate_ingests;
  report.check(wrap_pacer.ingest(wrapped, 2401U) ==
                   GroundUsbHeartbeatIngestStatus::Held &&
                   wrap_pacer.queued() == 1U &&
                   wrap_pacer.diagnostics().duplicate_ingests ==
                       duplicates_at_boundary,
               "sequence-wrap heartbeat stayed blacklisted past max age");

  const auto& diagnostics = pacer.diagnostics();
  report.check(diagnostics.emitted_heartbeats == 3U &&
                   diagnostics.fifo_replacements == 2U &&
                   diagnostics.invalid_heartbeats == 1U &&
                   diagnostics.foreign_heartbeats_passthrough == 1U &&
                   diagnostics.duplicate_ingests == 1U,
               "integrity/FIFO diagnostics do not match exact events");
  report.detail =
      "contract: CRC-valid real HB only, FIFO3 drop-oldest, exact bytes, "
      "unique token and emit-once";
}

void check_timing_contract(TestReport& report) {
  check_api_present(report);
  report.check(kSoftDueMs + kLoopJitterMs + kCurrentFrameBlockMs +
                           kHeartbeatWriteMs + kTransportFlushMs ==
                       2455U &&
                   kSoftDueMs + kLoopJitterMs + kCurrentFrameBlockMs +
                           kHeartbeatWriteMs + kTransportFlushMs <=
                       kUsbGapLimitMs,
               "2200+100+49+6+100 timing budget no longer fits 2500 ms");

  GroundUsbHeartbeatPacer pacer{fixed_config()};
  constexpr std::uint64_t base = 10'000U;
  pacer.set_usb_connected(true, base);
  std::array<MavlinkFrame, 5U> source{{
      make_heartbeat(0x50U, 0xB0U),
      make_heartbeat(0x51U, 0xB1U),
      make_heartbeat(0x52U, 0xB2U),
      make_heartbeat(0x53U, 0xB3U),
      make_heartbeat(0x54U, 0xB4U),
  }};
  std::vector<Emission> emitted{};

  report.check(pacer.ingest(source[0U], base) ==
                   GroundUsbHeartbeatIngestStatus::Held,
               "baseline heartbeat was not held");
  report.check(select_and_complete(pacer, base, base + 100U, false, emitted,
                                   report),
               "baseline heartbeat was not emitted");
  (void)pacer.ingest(source[1U], base + 1000U);
  (void)pacer.ingest(source[2U], base + 2000U);

  GroundUsbHeartbeatLease blocked1{};
  report.check(!pacer.select_due(base + 2400U, true, blocked1),
               "current normal frame was preempted after 100-ms loop jitter");
  report.check(select_and_complete(pacer, base + 2449U, base + 2555U, false,
                                   emitted, report),
               "heartbeat was not prioritized at the next frame boundary");

  // Last real RF heartbeat before the planned v2 uplink blackout.
  (void)pacer.ingest(source[3U], base + 3000U);
  constexpr std::uint64_t next_rf = base + 3000U +
                                    kRadioHeartbeatBlackoutMs;
  static_assert(next_rf == base + 6200U,
                "3200-ms RF heartbeat blackout model changed");

  GroundUsbHeartbeatLease blocked2{};
  report.check(!pacer.select_due(base + 4855U, true, blocked2),
               "second current normal frame was preempted");
  report.check(select_and_complete(pacer, base + 4904U, base + 5010U, false,
                                   emitted, report),
               "fresh reserve did not bridge the 3200-ms RF blackout");

  (void)pacer.ingest(source[4U], next_rf);
  GroundUsbHeartbeatLease blocked3{};
  report.check(!pacer.select_due(base + 7310U, true, blocked3),
               "third current normal frame was preempted");
  report.check(select_and_complete(pacer, base + 7359U, base + 7465U, false,
                                   emitted, report),
               "post-blackout heartbeat missed its boundary-priority slot");

  report.check(emitted.size() == 4U,
               "timing model emitted the wrong heartbeat count");
  const std::array<std::uint8_t, 4U> expected_sequences{{
      0x50U, 0x51U, 0x53U, 0x54U}};
  for (std::size_t index = 0U;
       index < emitted.size() && index < expected_sequences.size(); ++index) {
    report.check(emitted[index].sequence == expected_sequences[index],
                 "timing path duplicated, reordered, or emitted stale HB");
    const std::size_t source_index =
        static_cast<std::size_t>(emitted[index].sequence - 0x50U);
    report.check(source_index < source.size() &&
                     emitted[index].wire_hash ==
                         hash_wire(source[source_index]),
                 "timing path re-encoded or changed heartbeat bytes");
    if (index > 0U) {
      report.check(emitted[index].completed_ms -
                           emitted[index - 1U].completed_ms <=
                       kUsbGapLimitMs,
                   "USB heartbeat completion gap exceeded 2500 ms");
    }
    report.check(emitted[index].completed_ms -
                         emitted[index].rf_received_ms <=
                     kHardMaxAgeMs,
                 "emitted heartbeat exceeded the 2400-ms age cap");
  }
  report.check(pacer.diagnostics().expired_heartbeats >= 1U,
               "stale pre-blackout heartbeat was not expired");
  report.check(pacer.diagnostics().max_usb_gap_ms <= kUsbGapLimitMs,
               "pacer max-gap diagnostic exceeded 2500 ms");
  report.stress.heartbeat_gap_after_rx_ms =
      pacer.diagnostics().max_usb_gap_ms;
  report.detail =
      "timing: L=3200, 1-Hz arrivals, due=2200, jitter=100, "
      "current-frame block=49, HB write=6, HWCDC fence=100, expected max "
      "USB HB gap=2455 ms";
}

void check_disconnect_contract(TestReport& report) {
  check_api_present(report);
  GroundUsbHeartbeatPacer pacer{fixed_config()};
  constexpr std::uint64_t base = 20'000U;
  pacer.set_usb_connected(true, base);
  const MavlinkFrame baseline = make_heartbeat(0x60U, 0xC0U);
  const MavlinkFrame held = make_heartbeat(0x61U, 0xC1U);
  const MavlinkFrame fresh = make_heartbeat(0x62U, 0xC2U);
  std::vector<Emission> emitted{};
  (void)pacer.ingest(baseline, base);
  report.check(select_and_complete(pacer, base, base, false, emitted, report),
               "disconnect baseline heartbeat was not emitted");
  (void)pacer.ingest(held, base + 1000U);

  GroundUsbHeartbeatLease lease{};
  report.check(pacer.select_due(base + 2200U, false, lease),
               "due heartbeat did not obtain a pre-disconnect lease");
  pacer.set_usb_connected(false, base + 2200U);
  (void)pacer.complete_emit(lease.token, TxResult::Rejected,
                            base + 2200U);
  report.check(pacer.diagnostics().emitted_heartbeats == 1U &&
                   pacer.queued() == 1U,
               "USB disconnect committed or lost an unaccepted heartbeat");

  const std::uint64_t reconnect_ms = base + 3401U;
  pacer.set_usb_connected(true, reconnect_ms);
  pacer.expire(reconnect_ms);
  GroundUsbHeartbeatLease stale{};
  report.check(!pacer.select_due(reconnect_ms, false, stale) &&
                   pacer.queued() == 0U,
               "reconnect exposed a heartbeat older than 2400 ms");
  report.check(pacer.diagnostics().expired_heartbeats >= 1U &&
                   pacer.diagnostics().rejected_emits >= 1U,
               "disconnect rejection/stale-expiry diagnostics missing");

  (void)pacer.ingest(fresh, reconnect_ms + 1U);
  report.check(select_and_complete(pacer, reconnect_ms + 1U,
                                   reconnect_ms + 1U, false,
                                   emitted, report),
               "fresh post-reconnect heartbeat was not emitted");
  report.check(emitted.size() == 2U &&
                   emitted[0U].sequence == baseline.sequence &&
                   emitted[1U].sequence == fresh.sequence,
               "stale disconnect heartbeat leaked to USB");
  report.detail =
      "disconnect: rejected write is not committed; reconnect drops "
      "age>2400 before any USB output";
}

void check_boundary_contract(TestReport& report) {
  check_api_present(report);
  GroundUsbHeartbeatPacer pacer{fixed_config()};
  constexpr std::uint64_t base = 30'000U;
  pacer.set_usb_connected(true, base);
  std::vector<Emission> emitted{};
  const MavlinkFrame first = make_heartbeat(0x70U, 0xD0U);
  const MavlinkFrame second = make_heartbeat(0x71U, 0xD1U);
  const MavlinkFrame third = make_heartbeat(0x72U, 0xD2U);
  const MavlinkFrame fourth = make_heartbeat(0x73U, 0xD3U);
  (void)pacer.ingest(first, base);
  (void)select_and_complete(pacer, base, base, false, emitted, report);
  (void)pacer.ingest(second, base + 1000U);

  // A later complete non-HB frame is about to enter the generic USB egress.
  // The older held heartbeat must obtain the physical-send lease first even
  // though its 2200-ms pacing deadline has not arrived.
  GroundUsbHeartbeatLease ordering{};
  report.check(pacer.select_before_next_frame(base + 1500U, ordering) ==
                   GroundUsbHeartbeatBarrierStatus::LeaseReady &&
                   same_wire(ordering.frame, second),
               "held HB did not precede a later complete frame admission");
  GroundUsbHeartbeatLease ordering_blocked{};
  report.check(pacer.select_before_next_frame(base + 1500U,
                                              ordering_blocked) ==
                   GroundUsbHeartbeatBarrierStatus::BlockedByPendingEmit,
               "pending order-barrier lease allowed a later frame to pass");
  report.check(pacer.complete_emit(ordering.token, TxResult::Accepted,
                                   base + 1506U),
               "early order-preserving heartbeat commit failed");
  report.check(pacer.queued() == 0U,
               "order-preserving release left the held HB behind");

  // If the endpoint cannot accept the prior HB, reject its lease and discard
  // it explicitly before admitting the later frame. Silent reordering is not
  // permitted; the loss must be diagnosed.
  (void)pacer.ingest(third, base + 1600U);
  GroundUsbHeartbeatLease rejected_ordering{};
  report.check(pacer.select_before_next_frame(base + 1650U,
                                              rejected_ordering) ==
                   GroundUsbHeartbeatBarrierStatus::LeaseReady,
               "second order barrier did not lease the held HB");
  report.check(pacer.complete_emit(rejected_ordering.token,
                                   TxResult::Rejected, base + 1650U),
               "rejected order-barrier lease was not retired");
  report.check(pacer.discard_for_order(base + 1651U) &&
                   pacer.queued() == 0U,
               "unavailable held HB was not safely dropped before later data");

  // With no later RF frame, the ordinary deadline path still waits for the
  // current USB normal frame and wins immediately at its ending boundary.
  (void)pacer.ingest(fourth, base + 2000U);

  GroundUsbHeartbeatLease blocked{};
  report.check(!pacer.select_due(base + 3806U, true, blocked),
               "pacer interleaved heartbeat into an active normal frame");
  GroundUsbHeartbeatLease boundary{};
  report.check(pacer.select_due(base + 3855U, false, boundary) &&
                   same_wire(boundary.frame, fourth),
               "due heartbeat did not win the next frame boundary");
  GroundUsbHeartbeatLease duplicate{};
  report.check(!pacer.select_due(base + 3855U, false, duplicate),
               "same due frame obtained two simultaneous leases");
  report.check(pacer.complete_emit(boundary.token, TxResult::Accepted,
                                   base + 3861U),
               "boundary heartbeat commit failed");
  report.check(!pacer.complete_emit(boundary.token, TxResult::Accepted,
                                    base + 3862U),
               "boundary heartbeat was committed twice");
  report.check(pacer.diagnostics().emitted_heartbeats == 3U &&
                   pacer.diagnostics().order_barrier_blocks >= 1U &&
                   pacer.diagnostics().order_preservation_drops == 1U &&
                   pacer.queued() == 0U,
               "boundary arbitration duplicated or retained heartbeat");
  report.detail =
      "mux contract: held oldest HB precedes later-frame admission; "
      "active normal frame remains atomic; unavailable barrier is diagnosed";
}

void check_supply_contract(TestReport& report) {
  check_api_present(report);
  constexpr std::uint64_t base = 40'000U;
  GroundUsbHeartbeatPacer insufficient{fixed_config()};
  insufficient.set_usb_connected(true, base);
  (void)insufficient.ingest(make_heartbeat(0x80U, 0xE0U), base);
  (void)insufficient.ingest(make_heartbeat(0x81U, 0xE1U),
                            base + 1000U);
  report.check(!insufficient.guarantee_available(base + kSupplyWindowMs),
               "two HBs per 6200 ms incorrectly claimed a 2500-ms guarantee");
  report.check(insufficient.diagnostics().supply_shortage_events >= 1U,
               "RF supply shortage was not diagnosed");

  GroundUsbHeartbeatPacer sufficient{fixed_config()};
  sufficient.set_usb_connected(true, base);
  (void)sufficient.ingest(make_heartbeat(0x82U, 0xE2U), base);
  (void)sufficient.ingest(make_heartbeat(0x83U, 0xE3U),
                          base + 1000U);
  (void)sufficient.ingest(make_heartbeat(0x84U, 0xE4U),
                          base + 2000U);
  report.check(sufficient.guarantee_available(base + kSupplyWindowMs),
               "three HBs in the inclusive 6200-ms supply window were "
               "not sufficient");
  sufficient.observe_usb_egress(4096U, true, true);
  report.check(!sufficient.guarantee_available(base + kSupplyWindowMs),
               "4KB normal USB backlog incorrectly retained hard guarantee");
  report.check(
      sufficient.diagnostics().usb_backlog_non_guaranteed_events >= 1U &&
          sufficient.diagnostics().max_observed_usb_backlog_bytes == 4096U,
      "4KB USB backlog non-guarantee was not diagnosed");
  sufficient.observe_usb_egress(0U, true, true);
  report.check(sufficient.guarantee_available(base + kSupplyWindowMs),
               "one bounded current frame was mistaken for queued backlog");
  sufficient.observe_usb_egress(0U, false, false);
  report.check(!sufficient.guarantee_available(base + kSupplyWindowMs) &&
                   sufficient.diagnostics()
                           .usb_writer_unavailable_events >= 1U,
               "unavailable USB writer incorrectly retained hard guarantee");
  sufficient.observe_usb_egress(0U, false, true);
  report.check(!sufficient.guarantee_available(
                   base + kSupplyWindowMs + 1U),
               "expired supply history kept claiming a hard guarantee");
  report.detail =
      "supply: >=3 unique valid RF HBs/6200 ms required; 4KB normal "
      "backlog or unavailable writer independently disables the guarantee";
}

}  // namespace

TestReport run_ground_usb_heartbeat_pacer_test(const std::string& test_id,
                                               std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;
  if (test_id == "UT-GROUND-USB-HB-PACER-INTEGRITY-001") {
    check_integrity_contract(report);
  } else if (test_id == "IT-GROUND-USB-HB-PACER-TIMING-001") {
    check_timing_contract(report);
  } else if (test_id == "UT-GROUND-USB-HB-PACER-DISCONNECT-001") {
    check_disconnect_contract(report);
  } else if (test_id == "UT-GROUND-USB-HB-PACER-BOUNDARY-001") {
    check_boundary_contract(report);
  } else if (test_id == "UT-GROUND-USB-HB-PACER-SUPPLY-001") {
    check_supply_contract(report);
  } else {
    report.check(false, "unknown Ground USB heartbeat pacer test ID");
  }
  return report;
}

}  // namespace vc_lora::test
