#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 1
#include "HWCDCR19Diagnostic.h"
#include <algorithm>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <type_traits>

using namespace vc_lora::experimental;
using UBaseType_t = std::uint32_t;
static constexpr int pdPASS = 1;
static constexpr std::uint32_t USB_SERIAL_JTAG_INTR_BUS_RESET = 0x200U;
static std::uint64_t clock_us;
static bool lock_allowed, plugged, connected, writable, tx_fifo_quarantined;
static bool tx_payload_in_flight, tx_bootstrap_enqueue_fence;
static bool tx_bootstrap_enqueue_aborted, tx_debug_writer_active;
static std::uint32_t tx_loss_epoch, tx_payload_publish_generation;
static std::uint32_t tx_payload_pickup_generation, raw_status, enabled_status;
static std::uint32_t ring_bytes, tx_stash_len, lock_delay_ms;
static std::uint64_t pickup_at_us;
static unsigned mux_depth, mux_entries, delay_count, micros_reads;
static void* tx_ring_buf;
static void* tx_lock;
enum class HwCdcR19TerminalZlpState { None, InFlight, PickedUp };
static HwCdcR19TerminalZlpState tx_terminal_zlp_state;
static std::uint32_t millis() { return static_cast<std::uint32_t>(clock_us / 1000U); }
static std::uint32_t micros() { ++micros_reads; return static_cast<std::uint32_t>(clock_us); }
static std::uint32_t pdMS_TO_TICKS(std::uint32_t n) { return n; }
static int xSemaphoreTake(void*, std::uint32_t n) {
  clock_us += static_cast<std::uint64_t>(lock_allowed ? lock_delay_ms : n) * 1000U;
  return lock_allowed ? pdPASS : 0;
}
static void xSemaphoreGive(void*) {}
static void portENTER_CRITICAL_SAFE(void*) { ++mux_depth; ++mux_entries; }
static void portEXIT_CRITICAL_SAFE(void*) { --mux_depth; }
static int hw_cdc_tx_mux;
static void vRingbufferGetInfo(void*, void*, void*, void*, void*, UBaseType_t* n) {
  if (mux_depth == 0U) { std::cerr << "unlocked ring sample\n"; std::abort(); }
  *n = ring_bytes;
}
static std::uint32_t usb_serial_jtag_ll_get_intsts_mask() { return raw_status; }
static std::uint32_t usb_serial_jtag_ll_get_intraw_mask() { return raw_status; }
static std::uint32_t usb_serial_jtag_ll_get_intr_ena_status() { return enabled_status; }
static int usb_serial_jtag_ll_txfifo_writable() { return writable ? 1 : 0; }
static void hw_cdc_enable_tx_intr() { enabled_status |= 8U; }
static void delay(unsigned n) {
  ++delay_count; clock_us += static_cast<std::uint64_t>(n) * 1000U;
  if (pickup_at_us != 0U && clock_us >= pickup_at_us) {
    writable = true; tx_payload_in_flight = false;
    tx_payload_pickup_generation = tx_payload_publish_generation;
  }
}
static bool hw_cdc_r19_terminal_zlp_matches_locked(std::uint32_t) { return false; }
static bool hw_cdc_r19_issue_terminal_zlp_locked(std::uint32_t) { return false; }
static void hw_cdc_r19_invalidate_terminal_zlp_locked() {}
struct Sink {
  template<class... Args> bool record_flush_retry_attempt(Args...) { return true; }
  template<class... Args> bool record_flush_attempt(Args...) { return true; }
  template<class... Args> bool record_flush_timeout(Args...) { return true; }
  template<class... Args> bool record_flush_success(Args...) { return true; }
  template<class... Args> bool record_flush_abort(Args...) { return true; }
  template<class... Args> bool observe_state(Args...) { return true; }
  template<class... Args> bool record_blocked(Args...) { return true; }
};
static Sink vc_lora_r19_hwcdc_fifo_diagnostic_record;
static Sink vc_lora_r19_hwcdc_restart_diagnostic_record;
static std::uint32_t flags() {
  return 2U | (connected ? 4U : 0U) | (writable ? 8U : 0U) |
      (tx_payload_in_flight ? 16U : 0U) | (tx_fifo_quarantined ? 32U : 0U) |
      ((raw_status & 0x200U) != 0U ? 64U : 0U);
}
static R19HwcdcFifoDiagnosticState hw_cdc_r19_diagnostic_state_locked(
    std::uint32_t blocker = 0U, std::uint32_t status = 0U) {
  if (mux_depth == 0U) { std::cerr << "unlocked state sample\n"; std::abort(); }
  return {flags(), tx_loss_epoch, tx_payload_publish_generation,
    tx_payload_pickup_generation, ring_bytes, tx_stash_len,
    status != 0U ? status : raw_status, blocker};
}
static R19HwcdcRestartDiagnosticState hw_cdc_r19_restart_state_locked() {
  return {flags(), tx_loss_epoch, ring_bytes, tx_stash_len,
    tx_payload_publish_generation, tx_payload_pickup_generation,
    raw_status, enabled_status};
}
static std::uint32_t hw_cdc_r19_flush_blockers_locked(bool host, bool epoch,
    bool empty, bool fifo, bool pickup, bool reset) {
  return (!host ? 1U : 0U) | (!epoch ? 2U : 0U) | (!empty ? 4U : 0U) |
    (!fifo ? 8U : 0U) | (!pickup ? 16U : 0U) |
    (tx_fifo_quarantined ? 32U : 0U) | (reset ? 64U : 0U);
}
class HWCDC {
 public:
  static bool isPlugged() { return plugged; }
  bool flushTxComplete(std::uint32_t timeout_ms, std::uint32_t expected_loss_epoch);
  bool flushTxCompleteDiagnostic(std::uint32_t timeout_ms,
      std::uint32_t expected_loss_epoch, R19HwcdcFlushCallEvidence& evidence);
};
// @ACTUAL_LEGACY_FUNCTION@
// @ACTUAL_DIAGNOSTIC_FUNCTION@

static void reset(unsigned scenario) {
  clock_us = 1000000U; plugged = connected = writable = lock_allowed = true;
  tx_ring_buf = reinterpret_cast<void*>(1); tx_lock = reinterpret_cast<void*>(2);
  tx_fifo_quarantined = tx_payload_in_flight = tx_bootstrap_enqueue_fence = false;
  tx_bootstrap_enqueue_aborted = tx_debug_writer_active = false;
  tx_loss_epoch = tx_payload_publish_generation = tx_payload_pickup_generation = 1U;
  raw_status = 0U; enabled_status = 0x204U; ring_bytes = tx_stash_len = 0U;
  lock_delay_ms = 0U; pickup_at_us = 0U;
  mux_depth = mux_entries = delay_count = micros_reads = 0U;
  tx_terminal_zlp_state = HwCdcR19TerminalZlpState::None;
  if (scenario == 1U) tx_ring_buf = nullptr;
  if (scenario == 2U) tx_lock = nullptr;
  if (scenario == 3U) lock_allowed = false;
  if (scenario == 4U) plugged = connected = false;
  if (scenario == 5U) ring_bytes = 31U;
  if (scenario == 6U) tx_stash_len = 7U;
  if (scenario == 7U) writable = false;
  if (scenario == 8U || scenario == 12U) {
    writable = false; tx_payload_in_flight = true; tx_payload_publish_generation = 2U;
    if (scenario == 12U) pickup_at_us = 1002000U;
  }
  if (scenario == 9U) tx_loss_epoch = 2U;
  if (scenario == 10U) raw_status = 0x200U;
  if (scenario == 11U) tx_fifo_quarantined = true;
  if (scenario == 13U) {
    clock_us = static_cast<std::uint64_t>(0xFFFFFFFEU) * 1000U;
    writable = false; tx_payload_in_flight = true; tx_payload_publish_generation = 2U;
    pickup_at_us = clock_us + 3000U;
  }
  if (scenario == 14U) lock_delay_ms = 5U;
}
int main() {
  static_assert(sizeof(R19HwcdcFlushCallEvidence) == 96U);
  static_assert(std::is_standard_layout_v<R19HwcdcFlushCallEvidence>);
  static_assert(std::is_trivially_copyable_v<R19HwcdcFlushCallEvidence>);
  unsigned checks = 0U, failures = 0U, max_mux = 0U, max_micros = 0U;
  const auto check = [&](bool ok, const char* message) {
    ++checks; if (!ok) { ++failures; std::cerr << "FAIL " << message << '\n'; }
  };
  HWCDC serial;
  for (unsigned scenario = 0U; scenario <= 15U; ++scenario) {
    const auto budget = scenario == 15U ? 0U : 5U;
    reset(scenario);
    const bool legacy = serial.flushTxComplete(budget, 1U);
    const auto legacy_delays = delay_count;
    reset(scenario);
    R19HwcdcFlushCallEvidence evidence{};
    evidence.transaction_token = 73U; evidence.attempt_id = 29U;
    const bool actual = serial.flushTxCompleteDiagnostic(budget, 1U, evidence);
    const unsigned actual_mux_entries = mux_entries;
    const unsigned actual_micros_reads = micros_reads;
    check(actual == legacy && legacy_delays == delay_count, "legacy/new actual method result and delay parity");
    check(evidence.schema == 1U && evidence.transaction_token == 73U && evidence.attempt_id == 29U,
      "call context must survive evidence initialization");
    check(evidence.raw_return == static_cast<unsigned>(actual) &&
      (evidence.validity_flags & 19U) == 19U && evidence.timeout_ms == budget &&
      evidence.expected_loss_epoch == 1U && evidence.elapsed_ms ==
        static_cast<std::uint32_t>(evidence.finished_ms - evidence.started_ms),
      "terminal outcome timing completeness");
    const auto reason = scenario == 1U ? 2U : scenario == 2U ? 3U :
      scenario == 3U ? 4U : (scenario >= 9U && scenario <= 11U) ? 6U :
      (actual ? 1U : 5U);
    check(evidence.terminal_reason == reason, "all actual return paths have exact reason");
    if (scenario == 1U || scenario == 2U) {
      check((evidence.validity_flags & 8U) == 0U && evidence.state_flags == 0U,
        "null resource must not claim a FIFO snapshot");
    } else {
      check((evidence.validity_flags & 8U) != 0U && mux_depth == 0U,
        "terminal snapshot is captured under and releases TX mux");
      check(evidence.ring_pending_bytes == ring_bytes && evidence.stash_pending_bytes == tx_stash_len &&
        evidence.publish_generation == tx_payload_publish_generation &&
        evidence.pickup_generation == tx_payload_pickup_generation &&
        evidence.interrupt_enable_mask == enabled_status && evidence.raw_interrupt_status == raw_status,
        "same-call terminal software/hardware observation is exact");
    }
    check(((evidence.validity_flags & 128U) != 0U) == (scenario == 3U),
      "lock failure distinguishes unowned snapshot from publication ownership");
    check((evidence.validity_flags & 64U) != 0U &&
      ((evidence.validity_flags & 4U) != 0U) == (scenario != 1U && scenario != 2U && scenario != 3U),
      "identity and publication-lock validity must not be inferred from snapshot");
    const unsigned blockers = scenario == 4U ? 1U :
      (scenario == 5U || scenario == 6U) ? 4U : scenario == 7U ? 8U :
      scenario == 8U ? 24U : scenario == 9U ? 2U : scenario == 10U ? 66U :
      scenario == 11U ? 34U : 0U;
    check(evidence.flush_blocker_mask == blockers, "terminal blocker cause is not stale");
    check(actual_micros_reads == ((scenario == 1U || scenario == 2U) ? 0U : 2U),
      "at most one terminal instrumentation snapshot per call");
    if (scenario == 13U) check(evidence.finished_ms < evidence.started_ms &&
      evidence.elapsed_ms == 3U, "elapsed time must survive SDK millis wrap");
    if (scenario == 3U || scenario == 14U) check(evidence.lock_wait_ms == 5U, "lock wait recorded separately");
    const auto frozen = evidence;
    R19HwcdcFlushCallEvidence later{};
    reset(9U); (void)serial.flushTxCompleteDiagnostic(5U, 1U, later);
    check(std::memcmp(&frozen, &evidence, sizeof(evidence)) == 0,
      "later diagnostic calls cannot overwrite caller-local evidence");
    max_mux = std::max(max_mux, actual_mux_entries);
    max_micros = std::max(max_micros, actual_micros_reads);
  }
  std::cout << "UT-R19-HWCDC-FLUSH-CALL-EVIDENCE-001 cases=16 checks=" << checks
    << " failures=" << failures << " evidence_bytes=96 max_snapshot_clock_reads="
    << max_micros << " max_mux_entries=" << max_mux << '\n';
  return failures == 0U ? 0 : 1;
}
