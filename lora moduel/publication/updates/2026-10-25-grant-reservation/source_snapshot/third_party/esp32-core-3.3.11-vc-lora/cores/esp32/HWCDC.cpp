// Copyright 2015-2026 Espressif Systems (Shanghai) PTE LTD
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
#include "USB.h"
#if SOC_USB_SERIAL_JTAG_SUPPORTED

#include "Arduino.h"  // defines ARDUINO_SERIAL_EVENT_TASK_STACK_SIZE and ARDUINO_SERIAL_EVENT_TASK_PRIORITY
#include "esp32-hal.h"
#include "esp32-hal-periman.h"
#include "HWCDC.h"
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
#include "HWCDCR19Diagnostic.h"
#endif
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/queue.h"
#include "freertos/ringbuf.h"
#include "esp_intr_alloc.h"
#include "soc/periph_defs.h"
#include "soc/io_mux_reg.h"
#include "soc/usb_serial_jtag_struct.h"
#include <string.h>
#pragma GCC diagnostic ignored "-Wvolatile"
#include "hal/usb_serial_jtag_ll.h"
#pragma GCC diagnostic warning "-Wvolatile"
#include "rom/ets_sys.h"

#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
// Every R19 payload publication is deliberately shorter than the USB
// Serial/JTAG IN endpoint.  A picked-up short packet terminates the USB
// transfer by itself; publishing a second zero-length packet would create a
// new transfer and an unnecessary completion dependency.
static constexpr size_t k_usb_endpoint_packet_bytes = 64U;
static constexpr size_t k_maximum_payload_publication_bytes = 32U;
static_assert(
  k_maximum_payload_publication_bytes < k_usb_endpoint_packet_bytes,
  "R19 payload publications must remain USB short packets"
);
#endif

ESP_EVENT_DEFINE_BASE(ARDUINO_HW_CDC_EVENTS);

static RingbufHandle_t tx_ring_buf = NULL;
static QueueHandle_t rx_queue = NULL;
static uint8_t rx_data_buf[64] = {0};
// tx_stash_buf / tx_stash_len hold the tail of a FIFO write the hardware
// couldn't accept in one shot. They are written by the ISR (drain path and
// BUS_RESET) and cleared by task-side reset paths (flushTXBuffer(NULL,...) and
// setTxBufferSize()), so every access must go through hw_cdc_tx_mux below.
static uint8_t tx_stash_buf[64] = {0};
static volatile size_t tx_stash_len = 0;
// Monotonic witness for any path which deliberately discards accepted TX
// bytes. VC LoRa freezes this value before a frame publication commit and
// refuses to acknowledge the frame if the value changes.
static volatile uint32_t tx_loss_epoch = 0;
// A BUS_RESET which is first observed after bytes were written into the
// hardware FIFO leaves their session ownership ambiguous. While quarantined,
// no path may publish or refill that FIFO. Only a later clean BUS_RESET can
// prove that hardware discarded those bytes and release the quarantine.
static volatile bool tx_fifo_quarantined = false;
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
// The diagnostic bootstrap producer must prove an empty ring/stash/FIFO,
// enqueue its whole 63-byte frame, and recheck reset/epoch state before any
// ISR can remove even the first byte.  This fence is protected by
// hw_cdc_tx_mux and does not exist in production builds.
static volatile bool tx_bootstrap_enqueue_fence = false;
// BUS_RESET may release the producer-owned fence while the task is between
// its precheck and postcheck.  Keep ISR/task-side kicks blocked until that
// producer observes the epoch change and rolls back its possible enqueue.
static volatile bool tx_bootstrap_enqueue_aborted = false;
static volatile bool tx_debug_writer_active = false;
// SERIAL_IN_EMPTY may fire for the empty/ZLP kick used to start a cold CDC
// session.  That event alone does not prove that any application payload was
// picked up by the host, so the diagnostic cached-connected state must be
// gated by this explicit non-empty FIFO publication witness.
static volatile bool tx_payload_in_flight = false;
// If task-side priming observes BUS_RESET only after writing FIFO registers,
// the later reset ISR must preserve that late-write quarantine instead of
// treating the same reset as clean.  The ISR consumes this one-shot handoff.
static volatile bool tx_task_fifo_written_after_pending_reset = false;
// A cached connected bit proves that some payload was picked up, but it does
// not prove that the most recently published packet was picked up.  Keep an
// exact monotonic publication/pickup pair so flushTxComplete cannot complete
// while the final diagnostic packet is still owned by the IN endpoint.
static volatile uint32_t tx_payload_publish_generation = 0;
static volatile uint32_t tx_payload_pickup_generation = 0;
// A terminal ZLP belongs to one exact completed payload boundary.  The state
// must outlive a bounded flushTxComplete() call because the host may pick up
// the ZLP after that call times out but before the caller retries.  Keeping
// this diagnostic-only avoids changing the accepted product-core behavior.
enum class HwCdcR19TerminalZlpState : uint8_t {
  None = 0U,
  InFlight = 1U,
  PickedUp = 2U,
};
static volatile HwCdcR19TerminalZlpState tx_terminal_zlp_state =
  HwCdcR19TerminalZlpState::None;
static volatile uint32_t tx_terminal_zlp_loss_epoch = 0U;
static volatile uint32_t tx_terminal_zlp_publish_generation = 0U;
static volatile uint32_t tx_terminal_zlp_pickup_generation = 0U;
// True only between successful ISR installation and end(). It describes the
// diagnostic observation window, not whether FIFO traffic is currently live.
static volatile bool tx_r19_observation_active = false;
#endif
static intr_handle_t intr_handle = NULL;
static SemaphoreHandle_t tx_lock = NULL;
static volatile bool connected = false;

// Protects TX state shared between the producer task and the ISR (which may
// run on the other core on dual-core SoCs). It covers:
//   - read-modify-write of the USB_SERIAL_JTAG INT_ENA register (without this
//     a producer's "enable IN_EMPTY" can race with the ISR's "disable
//     IN_EMPTY" in the empty-ring branch and get silently dropped, leaving
//     the link permanently stalled),
//   - all accesses to tx_stash_buf / tx_stash_len (without this a task-side
//     "clear stash" can be lost when the ISR's later write-back resurrects
//     stale state, and a torn tx_stash_len read could make the ISR
//     dereference an inconsistent stash).
static portMUX_TYPE hw_cdc_tx_mux = portMUX_INITIALIZER_UNLOCKED;

#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
// JTAG-only evidence. This symbol is never serialized onto CDC, RF, or the
// Pixhawk UART. Every mutator below runs while hw_cdc_tx_mux is held, so ISR
// and task writers preserve the record's odd/even sequence transaction.
extern "C" {
__attribute__((used, aligned(4)))
vc_lora::experimental::R19HwcdcFifoDiagnosticRecord
  vc_lora_r19_hwcdc_fifo_diagnostic_record{};
__attribute__((used, aligned(4)))
vc_lora::experimental::R19HwcdcRestartDiagnosticRecord
  vc_lora_r19_hwcdc_restart_diagnostic_record{};
}

static inline uint32_t hw_cdc_r19_diagnostic_flags_locked(
  bool reset_pending, bool fifo_writable
) {
  using vc_lora::experimental::R19HwcdcFifoDiagnosticFlag;
  using vc_lora::experimental::r19_hwcdc_fifo_diagnostic_flag;
  uint32_t flags = 0U;
  if (tx_r19_observation_active) {
    flags |= r19_hwcdc_fifo_diagnostic_flag(
      R19HwcdcFifoDiagnosticFlag::ObservationActive
    );
  }
  if (connected) {
    flags |= r19_hwcdc_fifo_diagnostic_flag(
      R19HwcdcFifoDiagnosticFlag::Connected
    );
  }
  if (fifo_writable) {
    flags |= r19_hwcdc_fifo_diagnostic_flag(
      R19HwcdcFifoDiagnosticFlag::FifoWritable
    );
  }
  if (tx_payload_in_flight) {
    flags |= r19_hwcdc_fifo_diagnostic_flag(
      R19HwcdcFifoDiagnosticFlag::PayloadInFlight
    );
  }
  if (tx_fifo_quarantined) {
    flags |= r19_hwcdc_fifo_diagnostic_flag(
      R19HwcdcFifoDiagnosticFlag::FifoQuarantined
    );
  }
  if (reset_pending) {
    flags |= r19_hwcdc_fifo_diagnostic_flag(
      R19HwcdcFifoDiagnosticFlag::ResetPending
    );
  }
  if (tx_bootstrap_enqueue_fence) {
    flags |= r19_hwcdc_fifo_diagnostic_flag(
      R19HwcdcFifoDiagnosticFlag::BootstrapFence
    );
  }
  if (tx_bootstrap_enqueue_aborted) {
    flags |= r19_hwcdc_fifo_diagnostic_flag(
      R19HwcdcFifoDiagnosticFlag::BootstrapAborted
    );
  }
  if (tx_debug_writer_active) {
    flags |= r19_hwcdc_fifo_diagnostic_flag(
      R19HwcdcFifoDiagnosticFlag::DebugWriterActive
    );
  }
  return flags;
}

// Caller holds hw_cdc_tx_mux. Ring-buffer inspection under this same mux is
// already the completion invariant used by flushTxComplete and the ISR.
static inline vc_lora::experimental::R19HwcdcFifoDiagnosticState
hw_cdc_r19_diagnostic_state_locked(
  uint32_t flush_blocker_mask = 0U,
  uint32_t interrupt_status = 0U
) {
  UBaseType_t bytes_waiting = 0;
  if (tx_ring_buf != NULL) {
    vRingbufferGetInfo(
      tx_ring_buf, NULL, NULL, NULL, NULL, &bytes_waiting
    );
  }
  const uint32_t sampled_interrupt_status = interrupt_status != 0U
    ? interrupt_status
    : usb_serial_jtag_ll_get_intsts_mask();
  const bool reset_pending =
    (sampled_interrupt_status & USB_SERIAL_JTAG_INTR_BUS_RESET) != 0U;
  const bool fifo_writable =
    usb_serial_jtag_ll_txfifo_writable() == 1;
  return {
    hw_cdc_r19_diagnostic_flags_locked(reset_pending, fifo_writable),
    tx_loss_epoch,
    tx_payload_publish_generation,
    tx_payload_pickup_generation,
    static_cast<uint32_t>(bytes_waiting),
    static_cast<uint32_t>(tx_stash_len),
    sampled_interrupt_status,
    flush_blocker_mask,
  };
}

// A separate append-only JTAG record retains the raw source and enable mask.
// INT_ST alone is masked status and cannot explain an idle pending queue.
// Caller holds hw_cdc_tx_mux; no USB traffic is emitted for this evidence.
static inline vc_lora::experimental::R19HwcdcRestartDiagnosticState
hw_cdc_r19_restart_state_locked() {
  const auto state = hw_cdc_r19_diagnostic_state_locked();
  return {
    state.flags, state.tx_loss_epoch,
    state.ring_pending_bytes, state.stash_pending_bytes,
    state.publish_generation, state.pickup_generation,
    usb_serial_jtag_ll_get_intraw_mask(),
    usb_serial_jtag_ll_get_intr_ena_status(),
  };
}

static inline uint32_t hw_cdc_r19_flush_blockers_locked(
  bool host_present, bool epoch_matches, bool software_empty,
  bool fifo_writable, bool payload_pickup_complete, bool reset_pending
) {
  using vc_lora::experimental::R19HwcdcFifoFlushBlocker;
  using vc_lora::experimental::r19_hwcdc_fifo_flush_blocker;
  uint32_t blockers = 0U;
  if (!host_present) {
    blockers |= r19_hwcdc_fifo_flush_blocker(
      R19HwcdcFifoFlushBlocker::HostAbsent
    );
  }
  if (!epoch_matches) {
    blockers |= r19_hwcdc_fifo_flush_blocker(
      R19HwcdcFifoFlushBlocker::EpochMismatch
    );
  }
  if (!software_empty) {
    blockers |= r19_hwcdc_fifo_flush_blocker(
      R19HwcdcFifoFlushBlocker::SoftwarePending
    );
  }
  if (!fifo_writable) {
    blockers |= r19_hwcdc_fifo_flush_blocker(
      R19HwcdcFifoFlushBlocker::FifoNotWritable
    );
  }
  if (!payload_pickup_complete) {
    blockers |= r19_hwcdc_fifo_flush_blocker(
      R19HwcdcFifoFlushBlocker::PayloadPickupPending
    );
  }
  if (tx_fifo_quarantined) {
    blockers |= r19_hwcdc_fifo_flush_blocker(
      R19HwcdcFifoFlushBlocker::Quarantined
    );
  }
  if (reset_pending) {
    blockers |= r19_hwcdc_fifo_flush_blocker(
      R19HwcdcFifoFlushBlocker::ResetPending
    );
  }
  return blockers;
}

// Caller holds hw_cdc_tx_mux.
static inline void hw_cdc_r19_invalidate_terminal_zlp_locked(void) {
  tx_terminal_zlp_state = HwCdcR19TerminalZlpState::None;
  tx_terminal_zlp_loss_epoch = 0U;
  tx_terminal_zlp_publish_generation = 0U;
  tx_terminal_zlp_pickup_generation = 0U;
}

// Caller holds hw_cdc_tx_mux.  Matching all three witnesses prevents a late
// IN_EMPTY from an older packet/epoch from completing the current flush.
static inline bool hw_cdc_r19_terminal_zlp_matches_current_locked(void) {
  return tx_terminal_zlp_state != HwCdcR19TerminalZlpState::None &&
    tx_terminal_zlp_loss_epoch == tx_loss_epoch &&
    tx_terminal_zlp_publish_generation == tx_payload_publish_generation &&
    tx_terminal_zlp_pickup_generation == tx_payload_pickup_generation;
}

static inline bool hw_cdc_r19_terminal_zlp_matches_locked(
  uint32_t expected_loss_epoch
) {
  return hw_cdc_r19_terminal_zlp_matches_current_locked() &&
    tx_terminal_zlp_loss_epoch == expected_loss_epoch;
}

// Publish exactly one terminal ZLP for an exact payload boundary.  The stale
// IN_EMPTY bit is masked and cleared before ownership becomes visible; the ISR
// then re-samples the live bit under this same mux before it may acknowledge
// the new ZLP.
static inline bool hw_cdc_r19_issue_terminal_zlp_locked(
  uint32_t expected_loss_epoch
) {
  if (tx_terminal_zlp_state != HwCdcR19TerminalZlpState::None ||
      tx_loss_epoch != expected_loss_epoch || tx_fifo_quarantined ||
      tx_bootstrap_enqueue_fence || tx_bootstrap_enqueue_aborted ||
      tx_payload_in_flight ||
      tx_payload_publish_generation != tx_payload_pickup_generation ||
      (usb_serial_jtag_ll_get_intsts_mask() &
       USB_SERIAL_JTAG_INTR_BUS_RESET) != 0U ||
      usb_serial_jtag_ll_txfifo_writable() != 1) {
    return false;
  }

  usb_serial_jtag_ll_disable_intr_mask(
    USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY
  );
  usb_serial_jtag_ll_clr_intsts_mask(
    USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY
  );
  if ((usb_serial_jtag_ll_get_intsts_mask() &
       USB_SERIAL_JTAG_INTR_BUS_RESET) != 0U ||
      tx_loss_epoch != expected_loss_epoch || tx_fifo_quarantined) {
    return false;
  }

  tx_terminal_zlp_loss_epoch = tx_loss_epoch;
  tx_terminal_zlp_publish_generation = tx_payload_publish_generation;
  tx_terminal_zlp_pickup_generation = tx_payload_pickup_generation;
  tx_terminal_zlp_state = HwCdcR19TerminalZlpState::InFlight;
  using vc_lora::experimental::R19HwcdcFifoZlpOrigin;
  (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_zlp_wr_done(
    R19HwcdcFifoZlpOrigin::Task, [&]() noexcept {
      usb_serial_jtag_ll_txfifo_flush();
      return hw_cdc_r19_diagnostic_state_locked();
    }
  );

  const bool reset_pending =
    (usb_serial_jtag_ll_get_intsts_mask() &
     USB_SERIAL_JTAG_INTR_BUS_RESET) != 0U;
  if (!reset_pending && !tx_fifo_quarantined &&
      tx_loss_epoch == expected_loss_epoch &&
      hw_cdc_r19_terminal_zlp_matches_current_locked()) {
    usb_serial_jtag_ll_ena_intr_mask(
      USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY
    );
  } else {
    usb_serial_jtag_ll_disable_intr_mask(
      USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY
    );
  }
  return true;
}
#endif

#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
// Serialize the legacy ets_putc/debug path with the diagnostic bootstrap
// fence.  The reservation spans its ring/FIFO operation, so this is not a
// racy check-then-enqueue: either debug owns the boundary first and bootstrap
// refuses it, or bootstrap fences first and the debug byte is rejected.
static inline bool hw_cdc_try_begin_debug_write(void) {
  bool allowed = false;
  portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
  allowed = !tx_bootstrap_enqueue_fence &&
    !tx_bootstrap_enqueue_aborted && !tx_debug_writer_active;
  if (allowed) {
    tx_debug_writer_active = true;
  }
  portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
  return allowed;
}

static inline void hw_cdc_end_debug_write(void) {
  portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
  tx_debug_writer_active = false;
  portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
}
#endif

// Context-safe variants: use portENTER_CRITICAL_SAFE which picks the ISR or
// task critical-section macro at runtime based on xPortInIsrContext(). These
// are reachable from ISR context via, e.g., cdc0_write_char() (installed as
// ets_putc2 for the debug log path) -> HWCDC::isConnected() ->
// isCDC_Connected() -> hw_cdc_enable_tx_intr(). Calling the plain task
// portENTER_CRITICAL() from ISR asserts on ESP-IDF, so the helpers must
// auto-select.
static inline void hw_cdc_enable_tx_intr(void) {
  portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  const bool enqueue_allowed =
    !tx_fifo_quarantined && !tx_bootstrap_enqueue_fence &&
    !tx_bootstrap_enqueue_aborted;
  if (enqueue_allowed) {
#else
  if (!tx_fifo_quarantined) {
#endif
    const bool reset_pending =
      (usb_serial_jtag_ll_get_intsts_mask() &
       USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
    if (!reset_pending) {
      usb_serial_jtag_ll_ena_intr_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
    } else {
      usb_serial_jtag_ll_disable_intr_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
    }
  } else {
    usb_serial_jtag_ll_disable_intr_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
  }
  portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
}

// ISR-only fast paths: skip the runtime context check when we know statically
// that we're already inside the hw_cdc_isr_handler. Functionally identical to
// the _SAFE variants but a touch leaner in the interrupt hot path.
static inline void hw_cdc_enable_tx_intr_from_isr(void) {
  portENTER_CRITICAL_ISR(&hw_cdc_tx_mux);
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  const bool enqueue_allowed =
    !tx_fifo_quarantined && !tx_bootstrap_enqueue_fence &&
    !tx_bootstrap_enqueue_aborted;
  if (enqueue_allowed) {
#else
  if (!tx_fifo_quarantined) {
#endif
    const bool reset_pending =
      (usb_serial_jtag_ll_get_intsts_mask() &
       USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
    if (!reset_pending) {
      usb_serial_jtag_ll_ena_intr_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
    } else {
      usb_serial_jtag_ll_disable_intr_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
    }
  } else {
    usb_serial_jtag_ll_disable_intr_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
  }
  portEXIT_CRITICAL_ISR(&hw_cdc_tx_mux);
}

static inline void hw_cdc_disable_tx_intr_from_isr(void) {
  portENTER_CRITICAL_ISR(&hw_cdc_tx_mux);
  usb_serial_jtag_ll_disable_intr_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
  portEXIT_CRITICAL_ISR(&hw_cdc_tx_mux);
}

static inline bool hw_cdc_tx_fifo_is_quarantined(void) {
  bool quarantined = false;
  portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
  quarantined = tx_fifo_quarantined ||
    (usb_serial_jtag_ll_get_intsts_mask() &
     USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
  portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
  return quarantined;
}

// A task-side kick may emit only a zero-length packet from a proven-empty
// FIFO. Payload publication remains owned by the ISR's write/check/flush
// sequence below. Checking reset and FIFO state under the TX mux prevents a
// stale payload from being flushed into a new USB session.
static inline bool hw_cdc_flush_txfifo_if_safe(void) {
  bool flushed = false;
  portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  const bool allowed =
    !tx_fifo_quarantined && !tx_bootstrap_enqueue_fence &&
    !tx_bootstrap_enqueue_aborted;
#else
  const bool allowed = !tx_fifo_quarantined;
#endif
  if (allowed) {
    const bool reset_pending =
      (usb_serial_jtag_ll_get_intsts_mask() &
       USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
    if (!reset_pending && usb_serial_jtag_ll_txfifo_writable() == 1) {
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
      using vc_lora::experimental::R19HwcdcFifoZlpOrigin;
      const auto zlp_origin = xPortInIsrContext()
        ? R19HwcdcFifoZlpOrigin::Isr
        : R19HwcdcFifoZlpOrigin::Task;
      (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_zlp_wr_done(
        zlp_origin, [&]() noexcept {
          usb_serial_jtag_ll_txfifo_flush();
          return hw_cdc_r19_diagnostic_state_locked();
        }
      );
#else
      usb_serial_jtag_ll_txfifo_flush();
#endif
      flushed = true;
    }
  }
  portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
  return flushed;
}

// Atomically drops any partial FIFO bytes the ISR may have stashed. Without
// the lock, the clear could be lost if the ISR is mid-drain and writes a
// fresh tx_stash_len after the task's store. Also _SAFE because callers like
// flushTXBuffer() are reachable from cdc0_write_char() in ISR context.
static inline void hw_cdc_clear_tx_stash(void) {
  portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
  auto discard_and_sample = [&]() noexcept {
    tx_stash_len = 0;
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    tx_bootstrap_enqueue_fence = false;
    tx_bootstrap_enqueue_aborted = false;
    tx_payload_in_flight = false;
    tx_payload_pickup_generation = tx_payload_publish_generation;
    hw_cdc_r19_invalidate_terminal_zlp_locked();
#endif
    tx_loss_epoch = tx_loss_epoch + 1U;
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    return hw_cdc_r19_diagnostic_state_locked();
  };
  (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_payload_publish_abort(
    discard_and_sample
  );
#else
  };
  discard_and_sample();
#endif
  portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
}

// A USB bus reset destroys the host-visible byte-stream boundary. Quarantine
// every software-side TX byte before handling a simultaneously pending
// IN_EMPTY interrupt; otherwise an old suffix could be delivered to the new
// host session and prefix a later MAVLink frame. The epoch changes even when
// the software queues are empty because the hardware FIFO was also reset.
static void hw_cdc_discard_tx_from_isr(
  BaseType_t *task_woken, bool fifo_written_after_reset
) {
  portENTER_CRITICAL_ISR(&hw_cdc_tx_mux);
  auto reset_and_sample = [&]() noexcept {
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    const bool bootstrap_enqueue_was_fenced = tx_bootstrap_enqueue_fence;
    const bool effective_fifo_written_after_reset =
      fifo_written_after_reset ||
      tx_task_fifo_written_after_pending_reset;
    tx_task_fifo_written_after_pending_reset = false;
    // Read the hardware bit while owning the same mux as BUS_RESET quarantine.
    // This keeps the reset helper's two-argument production contract intact and
    // still records a co-pending raw IN_EMPTY without qualifying it as pickup.
    const uint32_t source_interrupt_status =
      usb_serial_jtag_ll_get_intsts_mask();
    const bool raw_in_empty_pending =
      (source_interrupt_status &
       USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY) != 0U;
#endif
    // Keep the pending-status clear and epoch transition under the same mux
    // observed by flushTxComplete(). If the publisher wins the mux first it
    // still sees BUS_RESET pending; if this ISR wins it sees the new epoch.
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    usb_serial_jtag_ll_clr_intsts_mask(
      USB_SERIAL_JTAG_INTR_BUS_RESET |
      USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY
    );
#else
    usb_serial_jtag_ll_clr_intsts_mask(USB_SERIAL_JTAG_INTR_BUS_RESET);
#endif
    usb_serial_jtag_ll_disable_intr_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
    tx_stash_len = 0;
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    tx_bootstrap_enqueue_fence = false;
    tx_bootstrap_enqueue_aborted = bootstrap_enqueue_was_fenced;
    tx_payload_in_flight = false;
    tx_payload_pickup_generation = tx_payload_publish_generation;
    hw_cdc_r19_invalidate_terminal_zlp_locked();
#endif
    if (tx_ring_buf != NULL) {
      for (;;) {
        size_t queued_size = 0;
        uint8_t *queued_buff = (uint8_t *)xRingbufferReceiveUpToFromISR(tx_ring_buf, &queued_size, 64);
        if (queued_buff == NULL || queued_size == 0) {
          break;
        }
        vRingbufferReturnItemFromISR(tx_ring_buf, queued_buff, task_woken);
      }
    }
    tx_loss_epoch = tx_loss_epoch + 1U;
    // A clean reset happens before this ISR writes any FIFO byte and therefore
    // clears a quarantine left by an earlier reset. A late reset preserves the
    // ambiguous post-reset FIFO until another clean reset occurs.
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    tx_fifo_quarantined = effective_fifo_written_after_reset;
#else
    tx_fifo_quarantined = fifo_written_after_reset;
#endif
    connected = false;
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    return vc_lora::experimental::R19HwcdcFifoBusResetResult{
      raw_in_empty_pending,
      source_interrupt_status,
      hw_cdc_r19_diagnostic_state_locked()
    };
#endif
  };
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_bus_reset(
    reset_and_sample
  );
#else
  reset_and_sample();
#endif
  portEXIT_CRITICAL_ISR(&hw_cdc_tx_mux);
}

// Caller holds hw_cdc_tx_mux from task context and, for producer exclusion,
// tx_lock. This is the post-enqueue rollback used when BUS_RESET raced an
// epoch-checked write. No byte from that ambiguous stream may reach IN_EMPTY.
static void hw_cdc_discard_tx_from_task_locked(void) {
  auto discard_and_sample = [&]() noexcept {
    tx_stash_len = 0;
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    tx_bootstrap_enqueue_fence = false;
    tx_bootstrap_enqueue_aborted = false;
    tx_payload_in_flight = false;
    tx_payload_pickup_generation = tx_payload_publish_generation;
    hw_cdc_r19_invalidate_terminal_zlp_locked();
#endif
    if (tx_ring_buf != NULL) {
      for (;;) {
        size_t queued_size = 0;
        uint8_t *queued_buff = (uint8_t *)xRingbufferReceiveUpTo(tx_ring_buf, &queued_size, 0, 64);
        if (queued_buff == NULL || queued_size == 0) {
          break;
        }
        vRingbufferReturnItem(tx_ring_buf, queued_buff);
      }
    }
    tx_loss_epoch = tx_loss_epoch + 1U;
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    return hw_cdc_r19_diagnostic_state_locked();
  };
  (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_payload_publish_abort(
    discard_and_sample
  );
#else
  };
  discard_and_sample();
#endif
}

// SOF in ISR causes problems for uploading firmware
//static volatile unsigned long lastSOF_ms;
//static volatile uint8_t SOF_TIMEOUT;

// timeout has no effect when USB CDC is unplugged
static uint32_t tx_timeout_ms = 100;

static esp_event_loop_handle_t arduino_hw_cdc_event_loop_handle = NULL;

static esp_err_t
  arduino_hw_cdc_event_post(esp_event_base_t event_base, int32_t event_id, void *event_data, size_t event_data_size, BaseType_t *task_unblocked) {
  if (arduino_hw_cdc_event_loop_handle == NULL) {
    return ESP_FAIL;
  }
  return esp_event_isr_post_to(arduino_hw_cdc_event_loop_handle, event_base, event_id, event_data, event_data_size, task_unblocked);
}

static esp_err_t
  arduino_hw_cdc_event_handler_register_with(esp_event_base_t event_base, int32_t event_id, esp_event_handler_t event_handler, void *event_handler_arg) {
  if (!arduino_hw_cdc_event_loop_handle) {
    esp_event_loop_args_t event_task_args = {
      .queue_size = 5,
      .task_name = "arduino_hw_cdc_events",
      .task_priority = ARDUINO_SERIAL_EVENT_TASK_PRIORITY,
      .task_stack_size = ARDUINO_SERIAL_EVENT_TASK_STACK_SIZE,
      .task_core_id = tskNO_AFFINITY
    };
    if (esp_event_loop_create(&event_task_args, &arduino_hw_cdc_event_loop_handle) != ESP_OK) {
      log_e("esp_event_loop_create failed");
    }
  }
  if (arduino_hw_cdc_event_loop_handle == NULL) {
    return ESP_FAIL;
  }
  return esp_event_handler_register_with(arduino_hw_cdc_event_loop_handle, event_base, event_id, event_handler, event_handler_arg);
}

static void hw_cdc_isr_handler(void *arg) {
  portBASE_TYPE xTaskWoken = 0;
  uint32_t usbjtag_intr_status = 0;
  arduino_hw_cdc_event_data_t event = {0};
  usbjtag_intr_status = usb_serial_jtag_ll_get_intsts_mask();

  // Reset wins over IN_EMPTY when hardware reports both in one ISR snapshot.
  // Do not let the old FIFO/ring stream establish a false connected state.
  if (usbjtag_intr_status & USB_SERIAL_JTAG_INTR_BUS_RESET) {
    hw_cdc_discard_tx_from_isr(&xTaskWoken, false);
    arduino_hw_cdc_event_post(ARDUINO_HW_CDC_EVENTS, ARDUINO_HW_CDC_BUS_RESET_EVENT, &event, sizeof(arduino_hw_cdc_event_data_t), &xTaskWoken);
    // Do not let IN_EMPTY or RX from the reset snapshot restore connected.
    usbjtag_intr_status = 0;
  }

  if (usbjtag_intr_status & USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY) {
    // IN_EMPTY firing means the host just picked up our last IN packet, so the
    // CDC link is healthy regardless of any transient isPlugged() glitches
    // (isPlugged() is driven by a tick-hook SOF watchdog with several ms of
    // tolerance and can briefly flap to false even while USB is fine).
    bool reset_pending_before_in_empty_pickup = false;
    bool live_in_empty_pending = false;
    bool in_empty_allowed = false;
    uint32_t live_interrupt_status = 0U;
    portENTER_CRITICAL_ISR(&hw_cdc_tx_mux);
    // Both BUS_RESET and IN_EMPTY are asynchronous to the ISR entry snapshot.
    // Re-sample them after acquiring the same mux used by the task-side ZLP
    // publisher. A stale pre-publication snapshot must not clear, disable, or
    // acknowledge a newly published terminal ZLP.
    live_interrupt_status = usb_serial_jtag_ll_get_intsts_mask();
    reset_pending_before_in_empty_pickup =
      (live_interrupt_status &
       USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
    live_in_empty_pending =
      (live_interrupt_status &
       USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY) != 0U;
    if (!reset_pending_before_in_empty_pickup && live_in_empty_pending) {
      in_empty_allowed = !tx_fifo_quarantined
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
        && !tx_bootstrap_enqueue_fence && !tx_bootstrap_enqueue_aborted
#endif
        ;
      bool payload_pickup_allowed = !tx_fifo_quarantined;
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
      const bool payload_pickup_observed = tx_payload_in_flight;
      payload_pickup_allowed = payload_pickup_allowed &&
        payload_pickup_observed && !tx_bootstrap_enqueue_fence &&
        !tx_bootstrap_enqueue_aborted;
      const bool terminal_zlp_pickup_allowed =
        !payload_pickup_observed && !tx_fifo_quarantined &&
        !tx_bootstrap_enqueue_fence && !tx_bootstrap_enqueue_aborted &&
        tx_terminal_zlp_state == HwCdcR19TerminalZlpState::InFlight &&
        hw_cdc_r19_terminal_zlp_matches_current_locked();
#endif
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
      (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_in_empty(
        payload_pickup_allowed, [&]() noexcept {
          // Consume this exact hardware event while the diagnostic seqlock is
          // odd. Otherwise JTAG could accept the committed counter/state while
          // the same raw status bit was still pending and count it twice later.
          usb_serial_jtag_ll_clr_intsts_mask(
            USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY
          );
          if (payload_pickup_allowed) {
            connected = true;
            tx_payload_pickup_generation = tx_payload_publish_generation;
            tx_payload_in_flight = false;
          } else if (terminal_zlp_pickup_allowed) {
            connected = true;
            tx_terminal_zlp_state = HwCdcR19TerminalZlpState::PickedUp;
          } else {
            if (tx_fifo_quarantined) {
              connected = false;
            }
            // A stale/pending IN_EMPTY may have entered before the bootstrap
            // producer disabled the mask. Leave connected unchanged and
            // prevent this snapshot from touching the ring or FIFO.
            usb_serial_jtag_ll_disable_intr_mask(
              USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY
            );
          }
          return hw_cdc_r19_diagnostic_state_locked(
            0U, live_interrupt_status
          );
        }
      );
#else
      if (payload_pickup_allowed) {
        connected = true;
      } else if (tx_fifo_quarantined) {
        connected = false;
        usb_serial_jtag_ll_clr_intsts_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
        usb_serial_jtag_ll_disable_intr_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
      }
#endif
    }
    portEXIT_CRITICAL_ISR(&hw_cdc_tx_mux);

    if (reset_pending_before_in_empty_pickup) {
      // The IN_EMPTY bit is deliberately still pending here. Diagnostic reset
      // discard records it as raw-only in the same BUS_RESET transaction,
      // then clears both status bits before making the new epoch visible.
      hw_cdc_discard_tx_from_isr(&xTaskWoken, false);
      arduino_hw_cdc_event_post(ARDUINO_HW_CDC_EVENTS, ARDUINO_HW_CDC_BUS_RESET_EVENT, &event, sizeof(arduino_hw_cdc_event_data_t), &xTaskWoken);
      usbjtag_intr_status = 0;
    } else if (!live_in_empty_pending) {
      // The ISR entered from an older snapshot which the task-side publisher
      // deliberately cleared. Leave the current enable/status ownership alone;
      // a genuine later pickup will assert a fresh interrupt.
    } else if (in_empty_allowed && tx_ring_buf != NULL &&
        usb_serial_jtag_ll_txfifo_writable() == 1) {
      size_t queued_size = 0;
      uint8_t *queued_buff = NULL;
      bool from_stash = false;
      uint32_t sent_size = 0;
      bool wrote_anything = false;
      bool fifo_written_after_reset = false;

      // Clear interrupt so we won't be called again until this transfer finishes.
#if !defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) || !VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
      usb_serial_jtag_ll_clr_intsts_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
#endif

      // Hold hw_cdc_tx_mux across the entire stash read/write region so that a
      // task-side hw_cdc_clear_tx_stash() (from flushTXBuffer(NULL,...) or
      // setTxBufferSize()) cannot interleave with us deciding to drain the
      // stash, writing to the FIFO, and writing back the new tx_stash_len.
      // The lock is per-core re-entrant, so the nested calls in
      // hw_cdc_enable_tx_intr_from_isr() / hw_cdc_disable_tx_intr_from_isr()
      // are safe.
      portENTER_CRITICAL_ISR(&hw_cdc_tx_mux);

      // BUS_RESET can assert after the ISR's entry snapshot. Recheck it while
      // holding the same mux as the reset quarantine before touching either
      // software queue or the post-reset hardware FIFO.
      bool reset_pending_before_tx =
        (usb_serial_jtag_ll_get_intsts_mask() &
         USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
      const bool bootstrap_enqueue_fenced =
        tx_bootstrap_enqueue_fence || tx_bootstrap_enqueue_aborted;
      // The pickup half of this ISR released the mux before this drain half.
      // A task may have published a new packet in that interval. This older
      // ISR must not drain, clear or disable the new packet's pickup source.
      const bool payload_published_since_pickup = tx_payload_in_flight;
      const bool fifo_writable_before_drain =
        usb_serial_jtag_ll_txfifo_writable() == 1;
      if (bootstrap_enqueue_fenced) {
        usb_serial_jtag_ll_clr_intsts_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
        usb_serial_jtag_ll_disable_intr_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
      }
#endif
      if (!reset_pending_before_tx
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
          && !bootstrap_enqueue_fenced && !payload_published_since_pickup &&
          fifo_writable_before_drain
#endif
      ) {
        if (tx_stash_len) {
          queued_buff = tx_stash_buf;
          queued_size = tx_stash_len;
          from_stash = true;
        } else {
          // BYTEBUF does not preserve writeTxChecked() item boundaries. Keep
          // every hardware fill below the 64-byte endpoint auto-flush size so
          // the post-write BUS_RESET check remains able to suppress publish.
          queued_buff = (uint8_t *)xRingbufferReceiveUpToFromISR(tx_ring_buf, &queued_size, 32);
        }
        // Queue inspection has non-zero latency. Keep the final pre-write
        // reset sample adjacent to the FIFO write.
        reset_pending_before_tx =
          (usb_serial_jtag_ll_get_intsts_mask() &
           USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
      }

      if (reset_pending_before_tx && !from_stash && queued_buff != NULL) {
        // BYTEBUF permits only one outstanding receive. Return the item
        // selected above before reset quarantine drains the remaining stream.
        vRingbufferReturnItemFromISR(tx_ring_buf, queued_buff, &xTaskWoken);
        queued_buff = NULL;
        queued_size = 0;
      }

      if (!reset_pending_before_tx && !tx_fifo_quarantined &&
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
          !bootstrap_enqueue_fenced && !payload_published_since_pickup &&
          fifo_writable_before_drain &&
#endif
          queued_buff != NULL && queued_size > 0) {
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
        (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_fifo_write(
          [&]() noexcept {
            sent_size = usb_serial_jtag_ll_write_txfifo(
              queued_buff, queued_size
            );
            return vc_lora::experimental::R19HwcdcFifoWriteResult{
              sent_size,
              hw_cdc_r19_diagnostic_state_locked(0U, usbjtag_intr_status)
            };
          }
        );
#else
        sent_size = usb_serial_jtag_ll_write_txfifo(queued_buff, queued_size);
#endif
        // Do not publish the FIFO until a reset which raced the register
        // writes has been sampled. Product writes are <=32 bytes, so hardware
        // cannot auto-flush the 64-byte endpoint before this check.
        const bool reset_pending_after_fifo_write =
          (usb_serial_jtag_ll_get_intsts_mask() &
           USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
        if (reset_pending_after_fifo_write) {
          reset_pending_before_tx = true;
          fifo_written_after_reset = sent_size > 0U;
          // Latch before releasing the mux. No task/debug path may flush the
          // post-reset FIFO in the gap before the discard helper reacquires it.
          // A zero-byte LL write has no ambiguous FIFO content, so reset still
          // purges/releases/advances the epoch but does not retain quarantine.
          tx_fifo_quarantined = fifo_written_after_reset;
          if (!from_stash) {
            vRingbufferReturnItemFromISR(tx_ring_buf, queued_buff, &xTaskWoken);
          }
        } else {
          // txfifo_writable() is only a sample: the LL write may still accept
          // zero bytes. Only a positive write may publish a generation,
          // WR_DONE, TX event, or any other forward-progress witness.
          if (sent_size > 0U) {
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
            // Arm the transaction-specific witness before wr_done publishes
            // this non-empty packet. The current IN_EMPTY status was cleared
            // at ISR entry, and this ISR still owns hw_cdc_tx_mux, so the next
            // permitted IN_EMPTY can only acknowledge this generation.
            hw_cdc_r19_invalidate_terminal_zlp_locked();
            tx_payload_publish_generation =
              tx_payload_publish_generation + 1U;
            tx_payload_in_flight = true;
#endif
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
            (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_wr_done(
              [&]() noexcept {
                usb_serial_jtag_ll_txfifo_flush();
                return hw_cdc_r19_diagnostic_state_locked(
                  0U, usbjtag_intr_status
                );
              }
            );
#else
            usb_serial_jtag_ll_txfifo_flush();
#endif
            wrote_anything = true;
          }

          if (sent_size < queued_size) {
            tx_stash_len = queued_size - sent_size;
            memmove(tx_stash_buf, queued_buff + sent_size, tx_stash_len);
          } else {
            tx_stash_len = 0;
          }
          if (!from_stash) {
            vRingbufferReturnItemFromISR(tx_ring_buf, queued_buff, &xTaskWoken);
          }
          // Always re-arm IN_EMPTY so that the next host pickup brings us back
          // to drain whatever remains (stash + ring).
          hw_cdc_enable_tx_intr_from_isr();
        }
      } else if (!reset_pending_before_tx && !tx_fifo_quarantined
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
                 && !bootstrap_enqueue_fenced && !payload_published_since_pickup &&
                 fifo_writable_before_drain
#endif
      ) {
        // Every payload publication in this fork is capped below the 64-byte
        // endpoint size.  Its final packet is therefore already a USB short
        // packet and does not need a terminating ZLP.  Publishing a new ZLP
        // from this empty-queue callback would replace each picked-up ZLP and
        // keep flushTxComplete() permanently at FifoNotWritable.  The task-side
        // completion path owns its one-shot terminal ZLP when one is required.
        hw_cdc_disable_tx_intr_from_isr();

        // Re-check the ring AFTER disabling the interrupt. If a producer
        // queued data between our ReceiveUpToFromISR() above and the disable,
        // its hw_cdc_enable_tx_intr() may have raced with our disable and got
        // overwritten. Re-arming here under the same spinlock guarantees we
        // don't lose that wakeup. tx_stash_len is also re-checked because the
        // task could have cleared it (e.g. via flushTXBuffer(NULL,...)) right
        // before we took the lock, while a previous ISR pass had left
        // residual data we no longer need to chase.
        UBaseType_t bytes_waiting = 0;
        vRingbufferGetInfo(tx_ring_buf, NULL, NULL, NULL, NULL, &bytes_waiting);
        if (bytes_waiting || tx_stash_len) {
          hw_cdc_enable_tx_intr_from_isr();
        }
      }

      portEXIT_CRITICAL_ISR(&hw_cdc_tx_mux);

      if (reset_pending_before_tx) {
        // The ring item selected above was either never removed or was
        // explicitly returned. Purge the complete remaining software stream,
        // advance its loss epoch, and prevent stale RX/TX handling from this
        // entry snapshot. An unflushed <=32-byte product FIFO is not exposed.
        hw_cdc_discard_tx_from_isr(
          &xTaskWoken, fifo_written_after_reset
        );
        arduino_hw_cdc_event_post(ARDUINO_HW_CDC_EVENTS, ARDUINO_HW_CDC_BUS_RESET_EVENT, &event, sizeof(arduino_hw_cdc_event_data_t), &xTaskWoken);
        usbjtag_intr_status = 0;
      } else if (wrote_anything) {
        event.tx.len = sent_size;
        arduino_hw_cdc_event_post(ARDUINO_HW_CDC_EVENTS, ARDUINO_HW_CDC_TX_EVENT, &event, sizeof(arduino_hw_cdc_event_data_t), &xTaskWoken);
      }
    } else if (in_empty_allowed) {
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
      portENTER_CRITICAL_ISR(&hw_cdc_tx_mux);
      if (!tx_payload_in_flight) {
        usb_serial_jtag_ll_clr_intsts_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
      }
      portEXIT_CRITICAL_ISR(&hw_cdc_tx_mux);
#else
      usb_serial_jtag_ll_clr_intsts_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
#endif
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    } else {
      portENTER_CRITICAL_ISR(&hw_cdc_tx_mux);
      if (!tx_payload_in_flight) {
        usb_serial_jtag_ll_clr_intsts_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
        usb_serial_jtag_ll_disable_intr_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
      }
      portEXIT_CRITICAL_ISR(&hw_cdc_tx_mux);
#endif
    }
  }

  if (usbjtag_intr_status & USB_SERIAL_JTAG_INTR_SERIAL_OUT_RECV_PKT) {
    // read rx buffer(max length is 64), and send available data to ringbuffer.
    // Ensure the rx buffer size is larger than RX_MAX_SIZE.
    usb_serial_jtag_ll_clr_intsts_mask(USB_SERIAL_JTAG_INTR_SERIAL_OUT_RECV_PKT);
    uint32_t rx_fifo_len = usb_serial_jtag_ll_read_rxfifo(rx_data_buf, 64);
    uint32_t i = 0;
    for (i = 0; i < rx_fifo_len; i++) {
      if (rx_queue == NULL || !xQueueSendFromISR(rx_queue, rx_data_buf + i, &xTaskWoken)) {
        break;
      }
    }
    event.rx.len = i;
    arduino_hw_cdc_event_post(ARDUINO_HW_CDC_EVENTS, ARDUINO_HW_CDC_RX_EVENT, &event, sizeof(arduino_hw_cdc_event_data_t), &xTaskWoken);
    portENTER_CRITICAL_ISR(&hw_cdc_tx_mux);
    if (!tx_fifo_quarantined) {
      connected = true;
    } else {
      connected = false;
    }
    portEXIT_CRITICAL_ISR(&hw_cdc_tx_mux);
  }

  // SOF ISR is causing esptool to be unable to upload firmware to the board
  // if (usbjtag_intr_status & USB_SERIAL_JTAG_INTR_SOF) {
  //   usb_serial_jtag_ll_clr_intsts_mask(USB_SERIAL_JTAG_INTR_SOF);
  //   lastSOF_ms = millis();
  // }

  if (xTaskWoken == pdTRUE) {
    portYIELD_FROM_ISR();
  }
}

// Moved to header file as inline function. Kept just as future reference.
//inline bool HWCDC::isPlugged(void) {
// SOF ISR is causing esptool to be unable to upload firmware to the board
// Timer test for SOF seems to work when uploading firmware
//  return usb_serial_jtag_is_connected();//(lastSOF_ms + SOF_TIMEOUT) >= millis();
//}
bool HWCDC::isCDC_Connected() {
  // This check must precede the cached-connected fast path. A late reset may
  // have invalidated that cached state while leaving isPlugged() true.
  if (hw_cdc_tx_fifo_is_quarantined()) {
    connected = false;
    return false;
  }

#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  // The IDF SOF watchdog may transiently (and on affected ESP32-S3 hosts,
  // persistently) report false even after an IN transaction completed.  The
  // diagnostic candidate has a stronger local witness: only the permitted
  // IN_EMPTY ISR path sets `connected`, after a host pickup and after the
  // reset/quarantine check above.  Trust that witness so a false SOF sample
  // cannot turn a read-only diagnostic stream back into a zero-byte gate.
  // Production builds retain the original SOF-first behavior below.
  if (connected) {
    return true;
  }
#endif

  // USB may be unplugged. Do NOT touch tx_stash_len here: a single transient
  // !isPlugged() reading (the SOF watchdog has a few-ms tolerance and is
  // known to flap even on a healthy link) would otherwise silently drop bytes
  // we already pulled out of the ring buffer into the stash.
  if (!isPlugged()) {
    connected = false;
    return false;
  }

  if (connected) {
    return true;
  }

  // Not yet (re)connected. Make sure the IN_EMPTY interrupt is armed and that
  // there is something for the host to clock out so the next IN token will
  // generate the interrupt that flips us back to connected = true. We arm on
  // every call (not just once) so that a stalled int_ena -- whether from a
  // producer/ISR race or from the ISR's empty-branch disable -- always gets
  // re-enabled, breaking what would otherwise be a permanent TX deadlock.
  hw_cdc_enable_tx_intr();
#if !defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) || !VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  // Retain the accepted R18 cold-start kick.  The R19 diagnostic publisher
  // primes real payload explicitly, so an empty FIFO flush here would only
  // create an unowned ZLP before that payload exists.
  hw_cdc_flush_txfifo_if_safe();
#endif
  return false;
}

static size_t flushTXBuffer(const uint8_t *buffer, size_t size) {
  if (!tx_ring_buf || hw_cdc_tx_fifo_is_quarantined()) {
    return 0;
  }
  UBaseType_t uxItemsWaiting = 0;
  vRingbufferGetInfo(tx_ring_buf, NULL, NULL, NULL, NULL, &uxItemsWaiting);
  size_t freeSpace = xRingbufferGetCurFreeSize(tx_ring_buf);
  size_t ringbufferLength = freeSpace + uxItemsWaiting;

  if (buffer == NULL) {
    // just flush the whole ring buffer and exit - used by HWCDC::flush()
    hw_cdc_clear_tx_stash();
    size_t queued_size = 0;
    uint8_t *queued_buff = (uint8_t *)xRingbufferReceiveUpTo(tx_ring_buf, &queued_size, 0, ringbufferLength);
    if (queued_size && queued_buff != NULL) {
      vRingbufferReturnItem(tx_ring_buf, (void *)queued_buff);
      portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
      hw_cdc_r19_invalidate_terminal_zlp_locked();
#endif
      tx_loss_epoch = tx_loss_epoch + 1U;
      portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
    }
    return 0;
  }
  if (size == 0) {
    return 0;  // nothing to do
  }
  const size_t original_size = size;
  if (freeSpace >= size) {
    // there is enough space, just add the data to the ring buffer
    if (xRingbufferSend(tx_ring_buf, (void *)buffer, size, 0) != pdTRUE) {
      return 0;
    }
  } else {
    // how many byte should be flushed to make space for the new data
    size_t to_flush = size - freeSpace;
    if (to_flush > ringbufferLength) {
      to_flush = ringbufferLength;
    }
    size_t queued_size = 0;
    uint8_t *queued_buff = (uint8_t *)xRingbufferReceiveUpTo(tx_ring_buf, &queued_size, 0, to_flush);
    if (queued_size && queued_buff != NULL) {
      vRingbufferReturnItem(tx_ring_buf, (void *)queued_buff);
      portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
      hw_cdc_r19_invalidate_terminal_zlp_locked();
#endif
      tx_loss_epoch = tx_loss_epoch + 1U;
      portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
    }
    // now add the new data that fits into the ring buffer
    uint8_t *bptr = (uint8_t *)buffer;
    if (size >= ringbufferLength) {
      size = ringbufferLength;
      bptr = (uint8_t *)buffer + (original_size - size);
      if (original_size > size) {
        // The caller must not report the discarded new prefix as accepted.
        portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
        hw_cdc_r19_invalidate_terminal_zlp_locked();
#endif
        tx_loss_epoch = tx_loss_epoch + 1U;
        portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
      }
    }
    if (xRingbufferSend(tx_ring_buf, (void *)bptr, size, 0) != pdTRUE) {
      return 0;
    }
  }
  hw_cdc_flush_txfifo_if_safe();
  return size;
}

static void ARDUINO_ISR_ATTR cdc0_write_char(char c) {
  if (tx_ring_buf == NULL) {
    return;
  }
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  if (!hw_cdc_try_begin_debug_write()) {
    return;
  }
#endif
  if (!HWCDC::isConnected()) {
    // just pop/push RingBuffer and apply FIFO policy
    flushTXBuffer((const uint8_t *)&c, 1);
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    hw_cdc_end_debug_write();
#endif
    return;
  }
  if (xPortInIsrContext()) {
    xRingbufferSendFromISR(tx_ring_buf, (void *)(&c), 1, NULL);
    hw_cdc_enable_tx_intr_from_isr();
  } else {
    xRingbufferSend(tx_ring_buf, (void *)(&c), 1, tx_timeout_ms / portTICK_PERIOD_MS);
    hw_cdc_enable_tx_intr();
  }
  hw_cdc_flush_txfifo_if_safe();
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  hw_cdc_end_debug_write();
#endif
}

HWCDC::HWCDC() {
  // SOF in ISR causes problems for uploading firmware
  //  lastSOF_ms = 0;
  //  SOF_TIMEOUT = 5;
}

HWCDC::~HWCDC() {
  end();
}

// It should return <true> just when USB is plugged and CDC is connected.
HWCDC::operator bool() const {
  return HWCDC::isCDC_Connected();
}

void HWCDC::onEvent(esp_event_handler_t callback) {
  onEvent(ARDUINO_HW_CDC_ANY_EVENT, callback);
}

void HWCDC::onEvent(arduino_hw_cdc_event_t event, esp_event_handler_t callback) {
  arduino_hw_cdc_event_handler_register_with(ARDUINO_HW_CDC_EVENTS, event, callback, this);
}

bool HWCDC::deinit(void *busptr) {
  // avoid any recursion issue with Peripheral Manager perimanSetPinBus() call
  static bool running = false;
  if (running) {
    return true;
  }
  running = true;
  // Setting USB D+ D- pins
  bool retCode = true;
  retCode &= perimanClearPinBus(USB_INT_PHY0_DM_GPIO_NUM);
  retCode &= perimanClearPinBus(USB_INT_PHY0_DP_GPIO_NUM);
  if (retCode) {
    // Force the host to re-enumerate (BUS_RESET)
    pinMode(USB_INT_PHY0_DM_GPIO_NUM, OUTPUT_OPEN_DRAIN);
    pinMode(USB_INT_PHY0_DP_GPIO_NUM, OUTPUT_OPEN_DRAIN);
    digitalWrite(USB_INT_PHY0_DM_GPIO_NUM, LOW);
    digitalWrite(USB_INT_PHY0_DP_GPIO_NUM, LOW);
  }
  // release the flag
  running = false;
  return retCode;
}

void HWCDC::begin(unsigned long baud) {
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  // Keep this declaration ahead of the Peripheral Manager error jumps below.
  // Diagnostic builds must not let `goto err` cross its initialization.
  bool diagnostic_record_ready = false;
#endif
  if (tx_lock == NULL) {
    tx_lock = xSemaphoreCreateMutex();
  }
  //RX Buffer default has 256 bytes if not preset
  if (rx_queue == NULL) {
    if (!setRxBufferSize(256)) {
      log_e("HW CDC RX Buffer error");
    }
  }
  //TX Buffer default has 256 bytes if not preset
  if (tx_ring_buf == NULL) {
    if (!setTxBufferSize(256)) {
      log_e("HW CDC TX Buffer error");
    }
  }

  // the HW Serial pins needs to be first deinited in order to allow `if(Serial)` to work :-(
  // But this is also causing terminal to hang, so they are disabled
  // deinit(NULL);
  // delay(10);  // USB Host has to enumerate it again

  // Peripheral Manager setting for USB D+ D- pins
  uint8_t pin = USB_INT_PHY0_DM_GPIO_NUM;
  if (perimanGetBusDeinit(ESP32_BUS_TYPE_USB_DM) == NULL) {
    perimanSetBusDeinit(ESP32_BUS_TYPE_USB_DM, HWCDC::deinit);
  }
  if (!perimanSetPinBus(pin, ESP32_BUS_TYPE_USB_DM, (void *)this, -1, -1)) {
    goto err;
  }
  pin = USB_INT_PHY0_DP_GPIO_NUM;
  if (perimanGetBusDeinit(ESP32_BUS_TYPE_USB_DP) == NULL) {
    perimanSetBusDeinit(ESP32_BUS_TYPE_USB_DP, HWCDC::deinit);
  }
  if (!perimanSetPinBus(pin, ESP32_BUS_TYPE_USB_DP, (void *)this, -1, -1)) {
    goto err;
  }
  // Configure PHY
  // USB_Serial_JTAG use internal PHY
  USB_SERIAL_JTAG.conf0.phy_sel = 0;
  // Disable software control USB D+ D- pullup pulldown (Device FS: dp_pullup = 1)
  USB_SERIAL_JTAG.conf0.pad_pull_override = 0;
  // Enable USB D+ pullup
  USB_SERIAL_JTAG.conf0.dp_pullup = 1;
  // Enable USB pad function
  USB_SERIAL_JTAG.conf0.usb_pad_enable = 1;
  usb_serial_jtag_ll_disable_intr_mask(USB_SERIAL_JTAG_LL_INTR_MASK);
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
  // No valid record is exposed until the ISR which owns the observation
  // window is installed successfully.
  tx_r19_observation_active = false;
  tx_payload_in_flight = false;
  tx_task_fifo_written_after_pending_reset = false;
  tx_payload_pickup_generation = tx_payload_publish_generation;
  hw_cdc_r19_invalidate_terminal_zlp_locked();
  vc_lora_r19_hwcdc_fifo_diagnostic_record.reset();
  vc_lora_r19_hwcdc_restart_diagnostic_record.reset();
  portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
  if (!intr_handle && esp_intr_alloc(ETS_USB_SERIAL_JTAG_INTR_SOURCE, 0, hw_cdc_isr_handler, NULL, &intr_handle) != ESP_OK) {
    isr_log_e("HW USB CDC failed to init interrupts");
    end();
    return;
  }
  portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
  tx_r19_observation_active = true;
  diagnostic_record_ready =
    vc_lora_r19_hwcdc_fifo_diagnostic_record.initialize(
      hw_cdc_r19_diagnostic_state_locked()
    );
  diagnostic_record_ready =
    vc_lora_r19_hwcdc_restart_diagnostic_record.initialize() &&
    diagnostic_record_ready;
  if (!diagnostic_record_ready) {
    tx_r19_observation_active = false;
    vc_lora_r19_hwcdc_fifo_diagnostic_record.reset();
    vc_lora_r19_hwcdc_restart_diagnostic_record.reset();
  }
  portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
  if (!diagnostic_record_ready) {
    isr_log_e("HW USB CDC failed to initialize R19 diagnostics");
    end();
    return;
  }
  usb_serial_jtag_ll_ena_intr_mask(USB_SERIAL_JTAG_INTR_SERIAL_OUT_RECV_PKT | USB_SERIAL_JTAG_INTR_BUS_RESET);
  hw_cdc_enable_tx_intr();
  // SOF ISR is causing esptool to be unable to upload firmware to the board
  // usb_serial_jtag_ll_ena_intr_mask(
  //   USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY | USB_SERIAL_JTAG_INTR_SERIAL_OUT_RECV_PKT | USB_SERIAL_JTAG_INTR_BUS_RESET | USB_SERIAL_JTAG_INTR_SOF
  // );
#else
  usb_serial_jtag_ll_ena_intr_mask(USB_SERIAL_JTAG_INTR_SERIAL_OUT_RECV_PKT | USB_SERIAL_JTAG_INTR_BUS_RESET);
  hw_cdc_enable_tx_intr();
  if (!intr_handle && esp_intr_alloc(ETS_USB_SERIAL_JTAG_INTR_SOURCE, 0, hw_cdc_isr_handler, NULL, &intr_handle) != ESP_OK) {
    isr_log_e("HW USB CDC failed to init interrupts");
    end();
    return;
  }
#endif
  return;

err:
  log_e("Serial JTAG Pin %u can't be set into Peripheral Manager.", pin);
  end();
}

void HWCDC::updateBaudRate(unsigned long baud) {
  log_w("USB Serial/JTAG baud rate is set by the USB standard; updateBaudRate(%lu) has no effect", baud);
}

uint32_t HWCDC::baudRate() {
  log_w("USB Serial/JTAG does not have a configurable baud rate");
  return 115200;
}

void HWCDC::end() {
  //Disable/clear/free tx/rx interrupt.
  usb_serial_jtag_ll_disable_intr_mask(USB_SERIAL_JTAG_LL_INTR_MASK);
  usb_serial_jtag_ll_clr_intsts_mask(USB_SERIAL_JTAG_LL_INTR_MASK);
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
  tx_r19_observation_active = false;
  tx_task_fifo_written_after_pending_reset = false;
  hw_cdc_r19_invalidate_terminal_zlp_locked();
  vc_lora_r19_hwcdc_fifo_diagnostic_record.reset();
  vc_lora_r19_hwcdc_restart_diagnostic_record.reset();
  portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
#endif
  esp_intr_free(intr_handle);
  intr_handle = NULL;
  if (tx_lock != NULL) {
    vSemaphoreDelete(tx_lock);
    tx_lock = NULL;
  }
  setRxBufferSize(0);
  setTxBufferSize(0);
  if (arduino_hw_cdc_event_loop_handle) {
    esp_event_loop_delete(arduino_hw_cdc_event_loop_handle);
    arduino_hw_cdc_event_loop_handle = NULL;
  }
  HWCDC::deinit(this);
  setDebugOutput(false);
  connected = false;
}

void HWCDC::setTxTimeoutMs(uint32_t timeout) {
  tx_timeout_ms = timeout;
}

/*
 * WRITING
*/

size_t HWCDC::setTxBufferSize(size_t tx_queue_len) {
  hw_cdc_clear_tx_stash();
  if (tx_ring_buf) {
    vRingbufferDelete(tx_ring_buf);
    tx_ring_buf = NULL;
  }
  if (!tx_queue_len) {
    return 0;
  }
  tx_ring_buf = xRingbufferCreate(tx_queue_len, RINGBUF_TYPE_BYTEBUF);
  if (!tx_ring_buf) {
    return 0;
  }
  return tx_queue_len;
}

int HWCDC::availableForWrite(void) {
  if (tx_ring_buf == NULL || tx_lock == NULL ||
      hw_cdc_tx_fifo_is_quarantined()) {
    return 0;
  }
  if (xSemaphoreTake(tx_lock, tx_timeout_ms / portTICK_PERIOD_MS) != pdPASS) {
    return 0;
  }
  size_t a = xRingbufferGetCurFreeSize(tx_ring_buf);
  xSemaphoreGive(tx_lock);
  return a;
}

size_t HWCDC::write(const uint8_t *buffer, size_t size) {
  if (buffer == NULL || size == 0 || tx_ring_buf == NULL || tx_lock == NULL) {
    return 0;
  }
  if (xSemaphoreTake(tx_lock, tx_timeout_ms / portTICK_PERIOD_MS) != pdPASS) {
    return 0;
  }
  if (!isCDC_Connected()) {
    // just pop/push RingBuffer and apply FIFO policy
    size = flushTXBuffer(buffer, size);
    // Kick the ISR after queuing: the not-connected path doesn't otherwise
    // re-arm IN_EMPTY, which means a transient isPlugged() glitch that flipped
    // `connected` to false would leave new data sitting in the ring with no
    // wakeup pending -- a permanent hang. Re-arming here lets the ISR drain
    // the ring and flip `connected` back to true on the next host pickup.
    hw_cdc_enable_tx_intr();
  } else {
    size_t to_send = size, so_far = 0;
    size_t ring_max = xRingbufferGetMaxItemSize(tx_ring_buf);
    if (ring_max == 0) {
      ring_max = size;
    }

    // Two independent progress caps share the same per-iteration timeout so
    // the total bounded wait is roughly max_consec_timeouts * tx_timeout_ms:
    //
    //   - "real disconnect"  -> consec_timeouts >= cap AND !isPlugged().
    //     Mark connected = false and route the remainder through the
    //     not-connected FIFO-replacement policy.
    //
    //   - "host backpressure" -> consec_timeouts >= cap, but isPlugged() is
    //     still true (e.g. the OS read buffer filled because the host app
    //     stopped reading). USB is still alive, so we do NOT touch
    //     `connected`; we just return what we managed to enqueue. Anything
    //     already in the ring stays queued for whenever the host resumes,
    //     and the caller sees a short write (Arduino's Stream::write
    //     contract) so it can decide whether to retry or drop.
    //
    // Without this second cap the loop could block forever whenever the
    // host stops consuming -- isPlugged() (SOF watchdog) keeps reporting
    // true, so the original `&& !isPlugged()` guard never fires.
    uint32_t consec_timeouts = 0;
    const uint32_t max_consec_timeouts = 20;  // ~ max_consec_timeouts * tx_timeout_ms total wait
    bool gave_up_disconnect = false;

    while (to_send) {
      size_t chunk = to_send > ring_max ? ring_max : to_send;

      // Blocking send into the TX ring buffer. The ISR drains the buffer into
      // the USB Serial/JTAG FIFO whenever the host picks up data.
      if (xRingbufferSend(tx_ring_buf, (void *)(buffer + so_far), chunk, tx_timeout_ms / portTICK_PERIOD_MS) != pdTRUE) {
        // Kick the ISR in case it stopped draining the ring.
        hw_cdc_enable_tx_intr();
        consec_timeouts++;
        if (consec_timeouts >= max_consec_timeouts) {
          // Bounded-progress deadline reached. Decide why and bail out.
          if (!isPlugged()) {
            connected = false;
            gave_up_disconnect = true;
          }
          size = so_far;
          break;
        }
        continue;
      }

      consec_timeouts = 0;
      so_far += chunk;
      to_send -= chunk;
      // Notify the ISR that new data is ready to be moved into the TX FIFO.
      hw_cdc_enable_tx_intr();
    }

    // Only dump pending bytes through the not-connected FIFO policy if we
    // actually decided this is a real disconnection. On plain host
    // backpressure we leave already-queued bytes alone and just report the
    // short write.
    if (gave_up_disconnect && to_send) {
      size = so_far + flushTXBuffer(buffer + so_far, to_send);
    }
  }
  xSemaphoreGive(tx_lock);
  return size;
}

size_t HWCDC::write(uint8_t c) {
  return write(&c, 1);
}

size_t HWCDC::writeTxChecked(const uint8_t *buffer, size_t size, uint32_t expected_loss_epoch) {
  // The reset/publication proof depends on staying below the 64-byte endpoint
  // auto-flush threshold. Reject misuse at this API boundary as well as in the
  // product adapter which currently emits at most 32 bytes.
  if (size > 32U) {
    return 0;
  }
  if (buffer == NULL || size == 0 || tx_ring_buf == NULL || tx_lock == NULL) {
    return 0;
  }
  if (xSemaphoreTake(tx_lock, tx_timeout_ms / portTICK_PERIOD_MS) != pdPASS) {
    return 0;
  }

  bool epoch_matches = false;
  portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
  const bool reset_pending_before =
    (usb_serial_jtag_ll_get_intsts_mask() &
     USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
  epoch_matches =
    tx_loss_epoch == expected_loss_epoch && !reset_pending_before &&
    !tx_fifo_quarantined;
  portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
  if (!epoch_matches || !isCDC_Connected()) {
    xSemaphoreGive(tx_lock);
    return 0;
  }

#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  // Reserve an exact clean-idle endpoint before making the new ring item
  // visible.  Ground can otherwise enqueue its next 21-byte frame after the
  // preceding IN_EMPTY ISR has disabled itself, with no fresh edge guaranteed
  // to restart the FIFO.  Reusing the producer fence also excludes a stale ISR
  // snapshot and the debug writer while the task publishes the first chunk.
  bool task_prime_reserved = false;
  bool task_prime_after_enqueue = false;
  portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
  UBaseType_t bytes_waiting = 0;
  vRingbufferGetInfo(tx_ring_buf, NULL, NULL, NULL, NULL, &bytes_waiting);
  const bool reset_pending_before_task_prime =
    (usb_serial_jtag_ll_get_intsts_mask() &
     USB_SERIAL_JTAG_INTR_BUS_RESET) != 0U;
  const bool clean_idle_boundary =
    tx_loss_epoch == expected_loss_epoch &&
    !reset_pending_before_task_prime && !tx_fifo_quarantined &&
    !tx_bootstrap_enqueue_fence && !tx_bootstrap_enqueue_aborted &&
    !tx_debug_writer_active && bytes_waiting == 0U && tx_stash_len == 0U &&
    !tx_payload_in_flight &&
    tx_payload_pickup_generation == tx_payload_publish_generation &&
    usb_serial_jtag_ll_txfifo_writable() == 1;
  if (clean_idle_boundary) {
    tx_bootstrap_enqueue_fence = true;
    usb_serial_jtag_ll_disable_intr_mask(
      USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY
    );
    usb_serial_jtag_ll_clr_intsts_mask(
      USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY
    );
    task_prime_reserved = true;
  }
  portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
#endif

  // The product calls this only with its bounded physical chunk (<=32 B).
  // A nonblocking single-item send makes the return value unambiguous.
  if (xRingbufferSend(tx_ring_buf, (void *)buffer, size, 0) != pdTRUE) {
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    bool restore_tx_interrupt = false;
    if (task_prime_reserved) {
      portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
      const bool reset_pending =
        (usb_serial_jtag_ll_get_intsts_mask() &
         USB_SERIAL_JTAG_INTR_BUS_RESET) != 0U;
      if (tx_bootstrap_enqueue_fence && !tx_bootstrap_enqueue_aborted &&
          tx_loss_epoch == expected_loss_epoch && !reset_pending &&
          !tx_fifo_quarantined) {
        tx_bootstrap_enqueue_fence = false;
        restore_tx_interrupt = true;
      } else {
        hw_cdc_discard_tx_from_task_locked();
      }
      portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
    }
    if (restore_tx_interrupt) {
      hw_cdc_enable_tx_intr();
    }
#endif
    xSemaphoreGive(tx_lock);
    return 0;
  }

  size_t accepted = size;
  portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
  const bool reset_pending_after =
    (usb_serial_jtag_ll_get_intsts_mask() &
     USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
  epoch_matches =
    tx_loss_epoch == expected_loss_epoch && !reset_pending_after &&
    !tx_fifo_quarantined;
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  // The previous packet can be picked up after the entry check but before
  // xRingbufferSend. Its ISR may then consume IN_EMPTY and disable itself on
  // the still-empty ring. Merely re-enabling that source does not guarantee
  // another event. Recheck this exact single-item idle boundary under the
  // same mux, reserve it, and reuse the checked publication transaction below.
  bytes_waiting = 0;
  vRingbufferGetInfo(tx_ring_buf, NULL, NULL, NULL, NULL, &bytes_waiting);
  const bool post_enqueue_idle_boundary =
    epoch_matches && !task_prime_reserved &&
    !tx_bootstrap_enqueue_fence && !tx_bootstrap_enqueue_aborted &&
    !tx_debug_writer_active && bytes_waiting == size && tx_stash_len == 0U &&
    !tx_payload_in_flight &&
    tx_payload_pickup_generation == tx_payload_publish_generation &&
    usb_serial_jtag_ll_txfifo_writable() == 1;
  if (post_enqueue_idle_boundary) {
    (void)vc_lora_r19_hwcdc_restart_diagnostic_record.record_blocked(
      hw_cdc_r19_restart_state_locked(),
      vc_lora::experimental::R19HwcdcRestartPhase::PostEnqueueIdleTransition
    );
    tx_bootstrap_enqueue_fence = true;
    usb_serial_jtag_ll_disable_intr_mask(
      USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY
    );
    usb_serial_jtag_ll_clr_intsts_mask(
      USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY
    );
    task_prime_reserved = true;
    task_prime_after_enqueue = true;
  }
#endif
  if (!epoch_matches) {
    hw_cdc_discard_tx_from_task_locked();
    accepted = 0;
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    if (task_prime_reserved) {
      (void)vc_lora_r19_hwcdc_restart_diagnostic_record.record_restart(
        hw_cdc_r19_restart_state_locked(),
        vc_lora::experimental::R19HwcdcRestartOrigin::EntryCleanIdle,
        vc_lora::experimental::R19HwcdcRestartOutcome::ResetBeforeWrite,
        static_cast<uint32_t>(size), 0U
      );
    }
  } else if (task_prime_reserved) {
    using vc_lora::experimental::R19HwcdcRestartOrigin;
    using vc_lora::experimental::R19HwcdcRestartOutcome;
    const auto task_prime_origin = task_prime_after_enqueue
      ? R19HwcdcRestartOrigin::PostEnqueueIdleTransition
      : R19HwcdcRestartOrigin::EntryCleanIdle;
    // The interrupt is still masked and its stale status was cleared before
    // enqueue.  Prove that the new item is the only software payload, then
    // transfer at most one short packet directly from task context.
    bytes_waiting = 0;
    vRingbufferGetInfo(tx_ring_buf, NULL, NULL, NULL, NULL, &bytes_waiting);
    const bool task_prime_still_valid =
      tx_bootstrap_enqueue_fence && !tx_bootstrap_enqueue_aborted &&
      !tx_debug_writer_active && bytes_waiting == size &&
      tx_stash_len == 0U && !tx_payload_in_flight &&
      tx_payload_pickup_generation == tx_payload_publish_generation &&
      usb_serial_jtag_ll_txfifo_writable() == 1;
    size_t queued_size = 0U;
    uint8_t *queued_buff = task_prime_still_valid
      ? (uint8_t *)xRingbufferReceiveUpTo(
          tx_ring_buf, &queued_size, 0, 32U
        )
      : NULL;
    const bool reset_pending_before_fifo_write =
      (usb_serial_jtag_ll_get_intsts_mask() &
       USB_SERIAL_JTAG_INTR_BUS_RESET) != 0U;
    const bool queued_item_valid =
      queued_buff != NULL && queued_size > 0U && queued_size <= 32U &&
      tx_loss_epoch == expected_loss_epoch &&
      !reset_pending_before_fifo_write && !tx_fifo_quarantined &&
      tx_bootstrap_enqueue_fence && !tx_bootstrap_enqueue_aborted;
    if (!queued_item_valid) {
      const bool invalidated_by_reset = reset_pending_before_fifo_write ||
        tx_loss_epoch != expected_loss_epoch;
      if (queued_buff != NULL) {
        vRingbufferReturnItem(tx_ring_buf, queued_buff);
      }
      hw_cdc_discard_tx_from_task_locked();
      accepted = 0;
      (void)vc_lora_r19_hwcdc_restart_diagnostic_record.record_restart(
        hw_cdc_r19_restart_state_locked(), task_prime_origin,
        invalidated_by_reset
          ? R19HwcdcRestartOutcome::ResetBeforeWrite
          : R19HwcdcRestartOutcome::Invalidated,
        static_cast<uint32_t>(size), 0U
      );
    } else {
      uint32_t sent_size = 0U;
      (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_fifo_write(
        [&]() noexcept {
          sent_size = usb_serial_jtag_ll_write_txfifo(
            queued_buff, queued_size
          );
          return vc_lora::experimental::R19HwcdcFifoWriteResult{
            sent_size, hw_cdc_r19_diagnostic_state_locked()
          };
        }
      );
      // A reset after the register write but before WR_DONE owns this
      // boundary.  Positive bytes are quarantined; zero bytes never acquire a
      // publication generation and the caller keeps ownership for a retry.
      const bool reset_pending_after_fifo_write =
        (usb_serial_jtag_ll_get_intsts_mask() &
         USB_SERIAL_JTAG_INTR_BUS_RESET) != 0U;
      if (reset_pending_after_fifo_write ||
          tx_loss_epoch != expected_loss_epoch || tx_fifo_quarantined) {
        if (sent_size > 0U) {
          tx_fifo_quarantined = true;
          tx_task_fifo_written_after_pending_reset = true;
        }
        vRingbufferReturnItem(tx_ring_buf, queued_buff);
        hw_cdc_discard_tx_from_task_locked();
        accepted = 0;
        (void)vc_lora_r19_hwcdc_restart_diagnostic_record.record_restart(
          hw_cdc_r19_restart_state_locked(), task_prime_origin,
          // With a zero-byte LL result the reset preceded any positive
          // hardware write, so it has no post-write quarantine ownership.
          sent_size > 0U ? R19HwcdcRestartOutcome::ResetAfterWrite
                         : R19HwcdcRestartOutcome::ResetBeforeWrite,
          static_cast<uint32_t>(queued_size), sent_size
        );
      } else if (sent_size == 0U) {
        vRingbufferReturnItem(tx_ring_buf, queued_buff);
        hw_cdc_discard_tx_from_task_locked();
        accepted = 0;
        (void)vc_lora_r19_hwcdc_restart_diagnostic_record.record_restart(
          hw_cdc_r19_restart_state_locked(), task_prime_origin,
          R19HwcdcRestartOutcome::ZeroWriteRejected,
          static_cast<uint32_t>(queued_size), 0U
        );
      } else {
        if (sent_size < queued_size) {
          tx_stash_len = queued_size - sent_size;
          memmove(tx_stash_buf, queued_buff + sent_size, tx_stash_len);
        } else {
          tx_stash_len = 0U;
        }
        vRingbufferReturnItem(tx_ring_buf, queued_buff);

        hw_cdc_r19_invalidate_terminal_zlp_locked();
        tx_payload_publish_generation =
          tx_payload_publish_generation + 1U;
        tx_payload_in_flight = true;
        tx_bootstrap_enqueue_fence = false;
        usb_serial_jtag_ll_clr_intsts_mask(
          USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY
        );
        (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_wr_done(
          [&]() noexcept {
            usb_serial_jtag_ll_txfifo_flush();
            return hw_cdc_r19_diagnostic_state_locked();
          }
        );
        usb_serial_jtag_ll_ena_intr_mask(
          USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY
        );
        (void)vc_lora_r19_hwcdc_restart_diagnostic_record.record_restart(
          hw_cdc_r19_restart_state_locked(), task_prime_origin,
          R19HwcdcRestartOutcome::Published,
          static_cast<uint32_t>(queued_size), sent_size
        );
      }
    }
#endif
  } else {
    // Enable only after the post-enqueue epoch/reset check. This closes the
    // reset helper's ring-empty -> epoch++ race with a producer on the other
    // core without holding a spinlock across xRingbufferSend().
    usb_serial_jtag_ll_ena_intr_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
  }
  portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);

  xSemaphoreGive(tx_lock);
  return accepted;
}

#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
size_t HWCDC::writeTxBootstrapFrameChecked(const uint8_t *buffer, size_t size, uint32_t expected_loss_epoch) {
  // This escape exists only for the fixed diagnostic R19A/R19F wire image.
  // Requiring the complete 63-byte image prevents a cached-connected cold
  // start from exposing a prefix that the publisher cannot retract.
  // Do not gate this cold-start escape on usb_serial_jtag_is_connected().
  // That SOF watchdog is advisory and can remain false on an enumerated S3.
  // A host pickup is proved later by the IN_EMPTY ISR and flushTxComplete;
  // no-host/reset cases keep or discard the complete frame without claiming
  // publication.
  if (buffer == NULL || size != 63U || tx_ring_buf == NULL ||
      tx_lock == NULL || intr_handle == NULL) {
    return 0;
  }
  if (xSemaphoreTake(tx_lock, tx_timeout_ms / portTICK_PERIOD_MS) != pdPASS) {
    return 0;
  }

  const size_t free_space = xRingbufferGetCurFreeSize(tx_ring_buf);
  bool empty_boundary = false;
  portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
  UBaseType_t bytes_waiting = 0;
  vRingbufferGetInfo(tx_ring_buf, NULL, NULL, NULL, NULL, &bytes_waiting);
  const bool reset_pending_before =
    (usb_serial_jtag_ll_get_intsts_mask() &
     USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
  // The LL bit alone means "has room", not a byte count.  Empty follows from
  // this core's stronger invariant: the ISR is the only payload FIFO writer,
  // it holds hw_cdc_tx_mux from its first byte through wr_done, and every
  // partial write is either flushed immediately or reset-quarantined.  Thus a
  // task holding this mux can see writable==1 only with no unflushed payload.
  empty_boundary =
    tx_loss_epoch == expected_loss_epoch && !reset_pending_before &&
    !connected && !tx_fifo_quarantined && !tx_bootstrap_enqueue_fence &&
    !tx_bootstrap_enqueue_aborted && !tx_debug_writer_active &&
    bytes_waiting == 0 &&
    tx_stash_len == 0 && free_space >= size &&
    usb_serial_jtag_ll_txfifo_writable() == 1;
  if (empty_boundary) {
    // A previously pending ISR may already have sampled IN_EMPTY.  The ISR
    // rechecks this fence while holding the same mux immediately before ring
    // removal/FIFO access, so neither that snapshot nor a new one can drain
    // the frame before the post-enqueue proof below.
    tx_bootstrap_enqueue_fence = true;
    usb_serial_jtag_ll_disable_intr_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
    usb_serial_jtag_ll_clr_intsts_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
  }
  portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
  if (!empty_boundary) {
    xSemaphoreGive(tx_lock);
    return 0;
  }

  if (xRingbufferSend(tx_ring_buf, (void *)buffer, size, 0) != pdTRUE) {
    portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
    const bool reset_pending =
      (usb_serial_jtag_ll_get_intsts_mask() &
       USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
    if (tx_bootstrap_enqueue_fence && !tx_bootstrap_enqueue_aborted &&
        tx_loss_epoch == expected_loss_epoch && !reset_pending &&
        !tx_fifo_quarantined) {
      tx_bootstrap_enqueue_fence = false;
      usb_serial_jtag_ll_ena_intr_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
    } else {
      hw_cdc_discard_tx_from_task_locked();
    }
    portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
    xSemaphoreGive(tx_lock);
    return 0;
  }

  size_t accepted = 0;
  portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
  bytes_waiting = 0;
  vRingbufferGetInfo(tx_ring_buf, NULL, NULL, NULL, NULL, &bytes_waiting);
  const bool reset_pending_after =
    (usb_serial_jtag_ll_get_intsts_mask() &
     USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
  const bool postcheck_valid =
    tx_loss_epoch == expected_loss_epoch &&
    !reset_pending_after && !connected && !tx_fifo_quarantined &&
    tx_bootstrap_enqueue_fence && !tx_bootstrap_enqueue_aborted &&
    bytes_waiting == size && tx_stash_len == 0 &&
    usb_serial_jtag_ll_txfifo_writable() == 1;
  if (!postcheck_valid) {
    hw_cdc_discard_tx_from_task_locked();
  } else {
    // A read-only cold host cannot be bootstrapped by an empty-FIFO/ZLP kick
    // alone on every ESP32-S3 revision.  Keep the complete frame behind the
    // publication fence, remove only one sub-endpoint chunk from BYTEBUF, and
    // prime that real payload into the FIFO before enabling IN_EMPTY.  The
    // remaining ring bytes and any unwritten suffix stay in software until a
    // payload pickup proves that the host can service the endpoint.
    size_t queued_size = 0;
    uint8_t *queued_buff = (uint8_t *)xRingbufferReceiveUpTo(
      tx_ring_buf, &queued_size, 0, 32U
    );
    const bool reset_pending_before_fifo_write =
      (usb_serial_jtag_ll_get_intsts_mask() &
       USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
    const bool prime_still_valid =
      queued_buff != NULL && queued_size > 0U &&
      tx_loss_epoch == expected_loss_epoch &&
      !reset_pending_before_fifo_write && !tx_fifo_quarantined &&
      tx_bootstrap_enqueue_fence && !tx_bootstrap_enqueue_aborted;
    if (!prime_still_valid) {
      if (queued_buff != NULL) {
        vRingbufferReturnItem(tx_ring_buf, queued_buff);
      }
      hw_cdc_discard_tx_from_task_locked();
    } else {
      uint32_t sent_size = 0U;
      (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_fifo_write(
        [&]() noexcept {
          sent_size = usb_serial_jtag_ll_write_txfifo(
            queued_buff, queued_size
          );
          return vc_lora::experimental::R19HwcdcFifoWriteResult{
            sent_size, hw_cdc_r19_diagnostic_state_locked()
          };
        }
      );
      // As in the ISR path, a <=32-byte fill cannot auto-publish the 64-byte
      // endpoint.  Sample BUS_RESET after the register writes and before
      // wr_done so a raced session can be quarantined without exposing a
      // prefix from the immutable 63-byte frame.
      const bool reset_pending_after_fifo_write =
        (usb_serial_jtag_ll_get_intsts_mask() &
         USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
      if (reset_pending_after_fifo_write ||
          tx_loss_epoch != expected_loss_epoch || tx_fifo_quarantined) {
        if (sent_size > 0U) {
          tx_fifo_quarantined = true;
        }
        vRingbufferReturnItem(tx_ring_buf, queued_buff);
        hw_cdc_discard_tx_from_task_locked();
      } else if (sent_size == 0U) {
        vRingbufferReturnItem(tx_ring_buf, queued_buff);
        hw_cdc_discard_tx_from_task_locked();
      } else {
        if (sent_size < queued_size) {
          tx_stash_len = queued_size - sent_size;
          memmove(tx_stash_buf, queued_buff + sent_size, tx_stash_len);
        } else {
          tx_stash_len = 0;
        }
        vRingbufferReturnItem(tx_ring_buf, queued_buff);

        // Release and publish in one critical section.  Clear the stale
        // empty-FIFO status adjacent to wr_done, publish while IN_EMPTY is
        // still masked, then arm the interrupt.  If the host picks up between
        // wr_done and enable, the raw status remains latched and is serviced
        // after the mask is enabled; an old empty event can no longer consume
        // this payload's witness.
        hw_cdc_r19_invalidate_terminal_zlp_locked();
        tx_payload_publish_generation =
          tx_payload_publish_generation + 1U;
        tx_payload_in_flight = true;
        tx_bootstrap_enqueue_fence = false;
        usb_serial_jtag_ll_clr_intsts_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
        (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_wr_done(
          [&]() noexcept {
            usb_serial_jtag_ll_txfifo_flush();
            return hw_cdc_r19_diagnostic_state_locked();
          }
        );
        usb_serial_jtag_ll_ena_intr_mask(USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY);
        accepted = size;
      }
    }
  }
  portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);

  xSemaphoreGive(tx_lock);
  return accepted;
}
#endif

void HWCDC::flush(void) {
  if (tx_ring_buf == NULL || tx_lock == NULL) {
    return;
  }
  if (xSemaphoreTake(tx_lock, tx_timeout_ms / portTICK_PERIOD_MS) != pdPASS) {
    return;
  }
  if (!isCDC_Connected()) {
    flushTXBuffer(NULL, 0);
  } else {
    UBaseType_t uxItemsWaiting = 0;
    vRingbufferGetInfo(tx_ring_buf, NULL, NULL, NULL, NULL, &uxItemsWaiting);
    if (uxItemsWaiting) {
      // Now trigger the ISR to read data from the ring buffer.
      hw_cdc_flush_txfifo_if_safe();
      hw_cdc_enable_tx_intr();
    }
    uint32_t tries = tx_timeout_ms;  // waits 1ms per ISR sending data attempt, in case CDC is unplugged
    while (connected && tries && uxItemsWaiting) {
      delay(1);
      UBaseType_t lastUxItemsWaiting = uxItemsWaiting;
      vRingbufferGetInfo(tx_ring_buf, NULL, NULL, NULL, NULL, &uxItemsWaiting);
      if (lastUxItemsWaiting == uxItemsWaiting) {
        tries--;
      }
      hw_cdc_enable_tx_intr();
    }
    if (tries == 0) {  // CDC isn't connected anymore...
      connected = false;
      flushTXBuffer(NULL, 0);  // flushes all TX Buffer
    }
  }
  xSemaphoreGive(tx_lock);
}

uint32_t HWCDC::txLossEpoch() const {
  uint32_t epoch = 0;
  portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
  epoch = tx_loss_epoch;
  portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
  return epoch;
}

bool HWCDC::flushTxComplete(uint32_t timeout_ms, uint32_t expected_loss_epoch) {
  if (tx_ring_buf == NULL || tx_lock == NULL) {
    return false;
  }

  const uint32_t started_ms = millis();
  if (xSemaphoreTake(tx_lock, pdMS_TO_TICKS(timeout_ms)) != pdPASS) {
    return false;
  }

  bool complete = false;
#if !defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) || !VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  bool final_flush_issued = false;
#endif
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
  uint32_t last_flush_blocker_mask = 0U;
  portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
  const auto initial_flush_state = hw_cdc_r19_diagnostic_state_locked();
  if (hw_cdc_r19_terminal_zlp_matches_locked(expected_loss_epoch)) {
    (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.
      record_flush_retry_attempt(initial_flush_state);
  } else {
    (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_flush_attempt(
      initial_flush_state
    );
  }
  portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
#endif
  for (;;) {
    const uint32_t elapsed_ms = millis() - started_ms;
    // Timeout is checked before any success predicate so this API can never
    // turn a completion observed after its caller's budget into true.
    if (elapsed_ms >= timeout_ms) {
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
      portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
      using vc_lora::experimental::R19HwcdcFifoDiagnosticFlag;
      using vc_lora::experimental::r19_hwcdc_fifo_diagnostic_flag;
      const bool terminal_host_present = connected || isPlugged();
      auto terminal_state = hw_cdc_r19_diagnostic_state_locked();
      const bool terminal_reset_pending =
        (terminal_state.flags & r19_hwcdc_fifo_diagnostic_flag(
          R19HwcdcFifoDiagnosticFlag::ResetPending
        )) != 0U;
      const bool terminal_quarantined =
        (terminal_state.flags & r19_hwcdc_fifo_diagnostic_flag(
          R19HwcdcFifoDiagnosticFlag::FifoQuarantined
        )) != 0U;
      const bool terminal_epoch_matches =
        terminal_state.tx_loss_epoch == expected_loss_epoch &&
        !terminal_reset_pending && !terminal_quarantined;
      const bool terminal_software_empty =
        terminal_state.ring_pending_bytes == 0U &&
        terminal_state.stash_pending_bytes == 0U;
      const bool terminal_fifo_writable =
        (terminal_state.flags & r19_hwcdc_fifo_diagnostic_flag(
          R19HwcdcFifoDiagnosticFlag::FifoWritable
        )) != 0U;
      const bool terminal_payload_pickup_complete =
        (terminal_state.flags & r19_hwcdc_fifo_diagnostic_flag(
          R19HwcdcFifoDiagnosticFlag::PayloadInFlight
        )) == 0U &&
        terminal_state.pickup_generation == terminal_state.publish_generation;
      const uint32_t terminal_flush_blocker_mask =
        hw_cdc_r19_flush_blockers_locked(
          terminal_host_present, terminal_epoch_matches,
          terminal_software_empty, terminal_fifo_writable,
          terminal_payload_pickup_complete, terminal_reset_pending
        );
      terminal_state.flush_blocker_mask = terminal_flush_blocker_mask;
      (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_flush_timeout(
        terminal_state
      );
      portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
#endif
      break;
    }
    const bool host_present =
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
      // `connected` is set only by a permitted IN_EMPTY/RX ISR and survives a
      // false SOF watchdog sample. BUS_RESET/quarantine still invalidates the
      // epoch before completion can be reported.
      connected || isPlugged();
#else
      isPlugged();
#endif
    bool epoch_matches = false;
    bool software_empty = false;
    bool fifo_writable = false;
    bool reset_pending = false;
    bool payload_pickup_complete = true;

    // The ISR uses the same lock around ring->stash->FIFO transfer. Reading
    // both pending stores and the loss witness in one critical section avoids
    // declaring completion between its ring removal and stash update.
    portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
    UBaseType_t bytes_waiting = 0;
    vRingbufferGetInfo(tx_ring_buf, NULL, NULL, NULL, NULL, &bytes_waiting);
    reset_pending =
      (usb_serial_jtag_ll_get_intsts_mask() &
       USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
    epoch_matches =
      tx_loss_epoch == expected_loss_epoch && !reset_pending &&
      !tx_fifo_quarantined;
    software_empty = bytes_waiting == 0 && tx_stash_len == 0;
    fifo_writable = usb_serial_jtag_ll_txfifo_writable() == 1;
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    payload_pickup_complete =
      !tx_payload_in_flight &&
      tx_payload_pickup_generation == tx_payload_publish_generation;
    last_flush_blocker_mask = hw_cdc_r19_flush_blockers_locked(
      host_present, epoch_matches, software_empty, fifo_writable,
      payload_pickup_complete, reset_pending
    );
    (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.observe_state(
      hw_cdc_r19_diagnostic_state_locked(last_flush_blocker_mask)
    );
    if (epoch_matches && bytes_waiting > 0U && tx_stash_len == 0U &&
        fifo_writable && payload_pickup_complete &&
        !tx_bootstrap_enqueue_fence && !tx_bootstrap_enqueue_aborted &&
        !tx_debug_writer_active) {
      (void)vc_lora_r19_hwcdc_restart_diagnostic_record.record_blocked(
        hw_cdc_r19_restart_state_locked(),
        vc_lora::experimental::R19HwcdcRestartPhase::FlushIdlePending
      );
    }
#endif
    if (host_present && epoch_matches && software_empty && fifo_writable &&
        payload_pickup_complete) {
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
      // Current R19 publications are all <=32 bytes into a 64-byte endpoint,
      // so the final data packet is already a terminating short packet.  Keep
      // the persistent terminal-ZLP branch for a future full/unknown packet
      // policy, but do not create that extra transfer in this candidate.
      const bool terminal_zlp_required = false;
      if (terminal_zlp_required) {
        if (tx_terminal_zlp_state == HwCdcR19TerminalZlpState::None) {
          (void)hw_cdc_r19_issue_terminal_zlp_locked(expected_loss_epoch);
        }
      }
      const bool terminal_zlp_picked_up =
        !terminal_zlp_required ||
        (tx_terminal_zlp_state == HwCdcR19TerminalZlpState::PickedUp &&
         hw_cdc_r19_terminal_zlp_matches_locked(expected_loss_epoch));
#else
      if (!final_flush_issued) {
        // Terminate a possible 64-byte transfer with the required ZLP. If the
        // hardware makes that transfer pending, the next loop waits for its
        // host pickup before returning true.
        final_flush_issued = hw_cdc_flush_txfifo_if_safe();
      }
#endif

      // BUS_RESET is asynchronous to the software mux. Re-read its pending
      // status at the final linearization point, after the terminating flush,
      // so a reset FIFO cannot masquerade as a host pickup while the ISR is
      // pending or temporarily masked.
      const bool fifo_picked_up =
        usb_serial_jtag_ll_txfifo_writable() == 1
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
        && terminal_zlp_picked_up
#endif
        ;
      // If reset happens before this read it invalidates completion; if it
      // happens afterwards, this is the publication linearization point and
      // the later reset starts a new epoch.
      reset_pending =
        (usb_serial_jtag_ll_get_intsts_mask() &
         USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
      // Sample elapsed time after every hardware/reset observation. Taking
      // it earlier could cross the timeout tick before the success predicate
      // and still return true using the stale sample.
      const uint32_t completion_elapsed_ms = millis() - started_ms;
      if (!tx_fifo_quarantined && !reset_pending &&
          tx_loss_epoch == expected_loss_epoch &&
          fifo_picked_up &&
          completion_elapsed_ms <= timeout_ms) {
        complete = true;
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
        last_flush_blocker_mask = 0U;
        (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_flush_success(
          hw_cdc_r19_diagnostic_state_locked(), false
        );
        hw_cdc_r19_invalidate_terminal_zlp_locked();
#endif
      }
    }
#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
    if (!complete && !epoch_matches) {
      // Epoch mismatch is an immediate non-timeout terminal result. Close the
      // active attempt explicitly so a later JTAG read can distinguish it
      // from a flush which was halted while still executing.
      (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_flush_abort(
        hw_cdc_r19_diagnostic_state_locked(last_flush_blocker_mask)
      );
    }
#endif
    portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);

    if (complete || !epoch_matches) {
      break;
    }
    if (host_present) {
#if !defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) || !VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
      hw_cdc_flush_txfifo_if_safe();
#endif
      hw_cdc_enable_tx_intr();
    }
    delay(1);
  }

  xSemaphoreGive(tx_lock);
  return complete;
}

#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS
// Diagnostic-only sibling of the unchanged two-argument API above. Its
// transport predicates and actions deliberately match that API's diagnostic
// build. An actual-method host harness checks their outcome/delay parity.
// Evidence never changes ownership, retries, FIFO contents, or the result.
bool HWCDC::flushTxCompleteDiagnostic(
  uint32_t timeout_ms, uint32_t expected_loss_epoch,
  vc_lora::experimental::R19HwcdcFlushCallEvidence &evidence
) {
  using vc_lora::experimental::R19HwcdcFlushTerminalReason;
  const uint32_t token = evidence.transaction_token;
  const uint32_t attempt = evidence.attempt_id;
  evidence = {};
  evidence.transaction_token = token;
  evidence.attempt_id = attempt;
  evidence.validity_flags = 1U | 2U;
  if (token != 0U && attempt != 0U) {
    evidence.validity_flags |= 64U;
  }
  evidence.timeout_ms = timeout_ms;
  evidence.expected_loss_epoch = expected_loss_epoch;
  const uint32_t started_ms = millis();
  evidence.started_ms = started_ms;

  // This value is owned only by this task/call. It is not a shared "latest"
  // record, and no ISR can mutate it after the publication lock is released.
  const auto finish = [&](R19HwcdcFlushTerminalReason reason, bool result) {
    evidence.terminal_reason = static_cast<uint32_t>(reason);
    evidence.raw_return = result ? 1U : 0U;
    evidence.finished_ms = millis();
    evidence.elapsed_ms = evidence.finished_ms - started_ms;
    evidence.validity_flags |= 16U;
    return result;
  };
  // Caller holds hw_cdc_tx_mux. The terminal software state, raw source and
  // enable mask are copied before its release, never reconstructed afterwards
  // from the shared 112-byte last-event record. USB hardware can of course
  // change asynchronously to this software critical section; the sample is
  // an observation adjacent to the return predicate, not a frozen USB bus.
  const auto capture_locked = [&](bool host_present, bool publication_lock_owned) {
    const uint32_t snapshot_us = micros();
    evidence.snapshot_started_ms = millis();
    const auto state = hw_cdc_r19_diagnostic_state_locked();
    const bool reset = (state.flags & 64U) != 0U;
    const bool epoch = state.tx_loss_epoch == expected_loss_epoch &&
      !reset && (state.flags & 32U) == 0U;
    const bool empty = state.ring_pending_bytes == 0U &&
      state.stash_pending_bytes == 0U;
    const bool writable = (state.flags & 8U) != 0U;
    const bool pickup = (state.flags & 16U) == 0U &&
      state.publish_generation == state.pickup_generation;
    evidence.state_flags = state.flags;
    evidence.observed_loss_epoch = state.tx_loss_epoch;
    evidence.ring_pending_bytes = state.ring_pending_bytes;
    evidence.stash_pending_bytes = state.stash_pending_bytes;
    evidence.publish_generation = state.publish_generation;
    evidence.pickup_generation = state.pickup_generation;
    evidence.raw_interrupt_status = usb_serial_jtag_ll_get_intraw_mask();
    evidence.interrupt_enable_mask = usb_serial_jtag_ll_get_intr_ena_status();
    evidence.flush_blocker_mask = hw_cdc_r19_flush_blockers_locked(
      host_present, epoch, empty, writable, pickup, reset
    );
    evidence.snapshot_finished_ms = millis();
    evidence.snapshot_duration_us = micros() - snapshot_us;
    evidence.validity_flags |= 8U;
    if (host_present) {
      evidence.validity_flags |= 32U;
    }
    if (!publication_lock_owned) {
      evidence.validity_flags |= 128U;
    }
  };
  if (tx_ring_buf == NULL) {
    return finish(R19HwcdcFlushTerminalReason::NullRing, false);
  }
  if (tx_lock == NULL) {
    return finish(R19HwcdcFlushTerminalReason::NullLock, false);
  }
  if (xSemaphoreTake(tx_lock, pdMS_TO_TICKS(timeout_ms)) != pdPASS) {
    evidence.lock_wait_ms = millis() - started_ms;
    // A lock-timeout caller may observe the other producer's state but must
    // not claim ownership of that publication. Null resource exits above do
    // not inspect the FIFO at all and retain SnapshotValid=false.
    portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
    capture_locked(connected || isPlugged(), false);
    portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
    return finish(R19HwcdcFlushTerminalReason::LockTimeout, false);
  }
  evidence.validity_flags |= 4U;
  evidence.lock_wait_ms = millis() - started_ms;
  bool complete = false;
  uint32_t last_flush_blocker_mask = 0U;
  R19HwcdcFlushTerminalReason reason = R19HwcdcFlushTerminalReason::LoopTimeout;
  portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
  const auto initial_flush_state = hw_cdc_r19_diagnostic_state_locked();
  if (hw_cdc_r19_terminal_zlp_matches_locked(expected_loss_epoch)) {
    (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_flush_retry_attempt(initial_flush_state);
  } else {
    (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_flush_attempt(initial_flush_state);
  }
  portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
  for (;;) {
    const uint32_t elapsed_ms = millis() - started_ms;
    if (elapsed_ms >= timeout_ms) {
      portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
      const bool host = connected || isPlugged();
      auto terminal_state = hw_cdc_r19_diagnostic_state_locked();
      const bool reset = (terminal_state.flags & 64U) != 0U;
      terminal_state.flush_blocker_mask = hw_cdc_r19_flush_blockers_locked(
        host,
        terminal_state.tx_loss_epoch == expected_loss_epoch && !reset &&
          (terminal_state.flags & 32U) == 0U,
        terminal_state.ring_pending_bytes == 0U && terminal_state.stash_pending_bytes == 0U,
        (terminal_state.flags & 8U) != 0U,
        (terminal_state.flags & 16U) == 0U &&
          terminal_state.pickup_generation == terminal_state.publish_generation,
        reset
      );
      (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_flush_timeout(terminal_state);
      capture_locked(host, true);
      portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
      break;
    }
    const bool host_present = connected || isPlugged();
    bool epoch_matches = false;
    bool software_empty = false;
    bool fifo_writable = false;
    bool reset_pending = false;
    bool payload_pickup_complete = true;
    portENTER_CRITICAL_SAFE(&hw_cdc_tx_mux);
    UBaseType_t bytes_waiting = 0;
    vRingbufferGetInfo(tx_ring_buf, NULL, NULL, NULL, NULL, &bytes_waiting);
    reset_pending = (usb_serial_jtag_ll_get_intsts_mask() & USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
    epoch_matches = tx_loss_epoch == expected_loss_epoch && !reset_pending && !tx_fifo_quarantined;
    software_empty = bytes_waiting == 0 && tx_stash_len == 0;
    fifo_writable = usb_serial_jtag_ll_txfifo_writable() == 1;
    payload_pickup_complete = !tx_payload_in_flight &&
      tx_payload_pickup_generation == tx_payload_publish_generation;
    last_flush_blocker_mask = hw_cdc_r19_flush_blockers_locked(
      host_present, epoch_matches, software_empty, fifo_writable,
      payload_pickup_complete, reset_pending
    );
    (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.observe_state(
      hw_cdc_r19_diagnostic_state_locked(last_flush_blocker_mask)
    );
    if (epoch_matches && bytes_waiting > 0U && tx_stash_len == 0U &&
        fifo_writable && payload_pickup_complete &&
        !tx_bootstrap_enqueue_fence && !tx_bootstrap_enqueue_aborted && !tx_debug_writer_active) {
      (void)vc_lora_r19_hwcdc_restart_diagnostic_record.record_blocked(
        hw_cdc_r19_restart_state_locked(),
        vc_lora::experimental::R19HwcdcRestartPhase::FlushIdlePending
      );
    }
    if (host_present && epoch_matches && software_empty && fifo_writable && payload_pickup_complete) {
      const bool terminal_zlp_required = false;
      if (terminal_zlp_required) {
        if (tx_terminal_zlp_state == HwCdcR19TerminalZlpState::None) {
          (void)hw_cdc_r19_issue_terminal_zlp_locked(expected_loss_epoch);
        }
      }
      const bool terminal_zlp_picked_up = !terminal_zlp_required ||
        (tx_terminal_zlp_state == HwCdcR19TerminalZlpState::PickedUp &&
         hw_cdc_r19_terminal_zlp_matches_locked(expected_loss_epoch));
      const bool fifo_picked_up = usb_serial_jtag_ll_txfifo_writable() == 1 && terminal_zlp_picked_up;
      reset_pending = (usb_serial_jtag_ll_get_intsts_mask() & USB_SERIAL_JTAG_INTR_BUS_RESET) != 0;
      const uint32_t completion_elapsed_ms = millis() - started_ms;
      if (!tx_fifo_quarantined && !reset_pending && tx_loss_epoch == expected_loss_epoch &&
          fifo_picked_up && completion_elapsed_ms <= timeout_ms) {
        complete = true;
        reason = R19HwcdcFlushTerminalReason::Success;
        last_flush_blocker_mask = 0U;
        (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_flush_success(
          hw_cdc_r19_diagnostic_state_locked(), false
        );
        hw_cdc_r19_invalidate_terminal_zlp_locked();
      }
    }
    if (!complete && !epoch_matches) {
      reason = R19HwcdcFlushTerminalReason::EpochAbort;
      (void)vc_lora_r19_hwcdc_fifo_diagnostic_record.record_flush_abort(
        hw_cdc_r19_diagnostic_state_locked(last_flush_blocker_mask)
      );
    }
    if (complete || !epoch_matches) {
      capture_locked(host_present, true);
    }
    portEXIT_CRITICAL_SAFE(&hw_cdc_tx_mux);
    if (complete || !epoch_matches) {
      break;
    }
    if (host_present) {
      hw_cdc_enable_tx_intr();
    }
    delay(1);
  }
  xSemaphoreGive(tx_lock);
  return finish(reason, complete);
}
#endif

/*
 * READING
*/

size_t HWCDC::setRxBufferSize(size_t rx_queue_len) {
  if (rx_queue) {
    vQueueDelete(rx_queue);
    rx_queue = NULL;
  }
  if (!rx_queue_len) {
    return 0;
  }
  rx_queue = xQueueCreate(rx_queue_len, sizeof(uint8_t));
  if (!rx_queue) {
    return 0;
  }
  return rx_queue_len;
}

int HWCDC::available(void) {
  if (rx_queue == NULL) {
    return -1;
  }
  return uxQueueMessagesWaiting(rx_queue);
}

int HWCDC::peek(void) {
  if (rx_queue == NULL) {
    return -1;
  }
  uint8_t c;
  if (xQueuePeek(rx_queue, &c, 0)) {
    return c;
  }
  return -1;
}

int HWCDC::read(void) {
  if (rx_queue == NULL) {
    return -1;
  }
  uint8_t c = 0;
  if (xQueueReceive(rx_queue, &c, 0)) {
    return c;
  }
  return -1;
}

size_t HWCDC::read(uint8_t *buffer, size_t size) {
  if (rx_queue == NULL) {
    return -1;
  }
  uint8_t c = 0;
  size_t count = 0;
  while (count < size && xQueueReceive(rx_queue, &c, 0)) {
    buffer[count++] = c;
  }
  return count;
}

/*
 * DEBUG
*/

void HWCDC::setDebugOutput(bool en) {
  if (en) {
    uartSetDebug(NULL);
    ets_install_putc2((void (*)(char)) & cdc0_write_char);
  } else {
    ets_install_putc2(NULL);
  }
  ets_install_putc1(NULL);  // closes UART log output
}

#if ARDUINO_USB_MODE && ARDUINO_USB_CDC_ON_BOOT  // Hardware JTAG CDC selected
// USBSerial is always available to be used
HWCDC HWCDCSerial;
#endif

#endif /* SOC_USB_SERIAL_JTAG_SUPPORTED */
