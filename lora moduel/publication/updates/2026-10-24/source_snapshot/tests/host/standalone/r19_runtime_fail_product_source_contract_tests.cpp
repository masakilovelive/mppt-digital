#include <cstddef>
#include <cctype>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

#ifndef VC_LORA_SOURCE_ROOT
#define VC_LORA_SOURCE_ROOT "."
#endif

namespace {

struct TestReport final {
  std::size_t checks{0U};
  std::size_t failures{0U};

  void check(bool condition, const char* message) noexcept {
    ++checks;
    if (!condition) {
      ++failures;
      std::cerr << "FAIL: " << message << '\n';
    }
  }
};

std::string read_file(const std::string& relative_path) {
  std::ifstream input(std::string{VC_LORA_SOURCE_ROOT} + relative_path,
                      std::ios::binary);
  std::ostringstream content;
  content << input.rdbuf();
  return content.str();
}

std::size_t count_occurrences(const std::string& text,
                              const std::string& needle) {
  std::size_t count = 0U;
  std::size_t offset = 0U;
  while ((offset = text.find(needle, offset)) != std::string::npos) {
    ++count;
    offset += needle.size();
  }
  return count;
}

bool ordered(const std::string& text, const std::string& first,
             const std::string& second) {
  const std::size_t first_offset = text.find(first);
  const std::size_t second_offset = text.find(second);
  return first_offset != std::string::npos &&
         second_offset != std::string::npos && first_offset < second_offset;
}

bool ordered_after(const std::string& text, std::size_t start,
                   const std::string& first, const std::string& second) {
  if (start == std::string::npos) {
    return false;
  }
  const std::size_t first_offset = text.find(first, start);
  const std::size_t second_offset =
      first_offset == std::string::npos
          ? std::string::npos
          : text.find(second, first_offset + first.size());
  return first_offset != std::string::npos &&
         second_offset != std::string::npos && first_offset < second_offset;
}

std::string source_section(const std::string& text,
                           const std::string& begin_marker,
                           const std::string& end_marker) {
  const std::size_t begin = text.find(begin_marker);
  const std::size_t end = begin == std::string::npos
                              ? std::string::npos
                              : text.find(end_marker,
                                          begin + begin_marker.size());
  return begin == std::string::npos || end == std::string::npos
             ? std::string{}
             : text.substr(begin, end - begin);
}

std::string compact_source(const std::string& text) {
  std::string result;
  for (const char character : text) {
    if (std::isspace(static_cast<unsigned char>(character)) == 0) {
      result.push_back(character);
    }
  }
  return result;
}

void test_product_integration_contract(TestReport& report) {
  const std::string bridge =
      read_file("/firmware/phase6/vc_lora_phase6_bridge.hpp");
  const std::string diagnostic =
      read_file("/firmware/high_speed/r19_runtime_fail_diagnostic.hpp");
  const std::string stage_record =
      read_file("/firmware/high_speed/r19_runtime_stage_record.hpp");
  const std::string stage_reader =
      read_file("/tools/read_r19_runtime_stage_jtag.ps1");
  const std::string hwcdc_header = read_file(
      "/third_party/esp32-core-3.3.11-vc-lora/cores/esp32/HWCDC.h");
  const std::string hwcdc_fifo_record = read_file(
      "/third_party/esp32-core-3.3.11-vc-lora/cores/esp32/"
      "HWCDCR19Diagnostic.h");
  const std::string hwcdc_source = read_file(
      "/third_party/esp32-core-3.3.11-vc-lora/cores/esp32/HWCDC.cpp");
  const std::size_t loop_offset =
      bridge.find("void loop_bridge() noexcept {");
  const std::string loop = loop_offset == std::string::npos
                               ? std::string{}
                               : bridge.substr(loop_offset);
  const std::size_t service_offset = bridge.find(
      "void r19_service_runtime_fail_diagnostic() noexcept {");
  const std::size_t service_end =
      service_offset == std::string::npos
          ? std::string::npos
          : bridge.find(
                "\n}\n#endif\n\n// Start the transaction quarantine",
                service_offset);
  const std::string service =
      service_offset == std::string::npos || service_end == std::string::npos
          ? std::string{}
          : bridge.substr(service_offset, service_end - service_offset);
  const std::string recovery_enum = source_section(
      bridge,
      "enum class R19RuntimeDiagnosticTransportRecovery : std::uint8_t {",
      "#if defined(VC_LORA_PHASE6_GROUND)");
  const std::string clear_recovery = source_section(
      bridge, "void r19_clear_diagnostic_transport_recovery() noexcept {",
      "void r19_fail_diagnostic_transport(");
  const std::string fail_transport = source_section(
      bridge, "void r19_fail_diagnostic_transport(",
      "bool r19_arm_diagnostic_transport_recovery(");
  const std::string arm_recovery = source_section(
      bridge, "bool r19_arm_diagnostic_transport_recovery(",
      "R19RuntimeFailGroundBoundaryStatus "
      "r19_runtime_fail_ground_boundary_status{");
  const std::string ground_recovery_safe = source_section(
      bridge,
      "bool r19_ground_runtime_fail_boundary_recovery_safe() noexcept {",
      "void r19_retire_ground_candidate_usb_commit() noexcept {");
  const std::string ground_convergence = source_section(
      bridge, "bool r19_converge_ground_runtime_fail_boundary(",
      "bool r19_recover_ground_runtime_fail_boundary_flush() noexcept {");
  const std::string ground_recovery = source_section(
      bridge,
      "bool r19_recover_ground_runtime_fail_boundary_flush() noexcept {",
      "bool r19_ground_runtime_alive_reservation_pending() noexcept {");
  const std::string frame_recovery = source_section(
      bridge, "bool r19_recover_runtime_diagnostic_frame_flush() noexcept {",
      "void r19_service_runtime_fail_diagnostic() noexcept {");
  const std::string diagnostic_flush = source_section(
      bridge,
      "bool r19_flush_runtime_diagnostic(std::uint32_t expected_epoch,\n"
      "    std::uint32_t budget_ms, std::uint64_t& completed_ms,\n"
      "    std::uint64_t deadline_ms) noexcept {",
      "\nbool r19_recover_runtime_diagnostic_frame_flush() noexcept {");
  const std::string diagnostic_flush_enabled = source_section(
      diagnostic_flush, "#if VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD",
      "#else\n  (void)deadline_ms;");
  const std::string diagnostic_flush_legacy = source_section(
      diagnostic_flush, "#else\n  (void)deadline_ms;", "\n#endif\n}");
  const std::string compact_flush_enabled =
      compact_source(diagnostic_flush_enabled);
  const std::string compact_flush_legacy =
      compact_source(diagnostic_flush_legacy);
  const std::string compact_ground_recovery = compact_source(ground_recovery);
  const std::string compact_frame_recovery = compact_source(frame_recovery);
  const std::string compact_service = compact_source(service);
  const std::string failed_transport_dispatch = source_section(
      service, "if (r19_runtime_fail_diagnostic_transport_failed) {",
      "const std::uint64_t now_ms = monotonic_now_ms();");
  report.check(!bridge.empty() && !diagnostic.empty() &&
                   !stage_record.empty() && !stage_reader.empty() &&
                   !hwcdc_header.empty() && !hwcdc_fifo_record.empty() &&
                   !hwcdc_source.empty(),
               "canonical diagnostic sources are unreadable");

  const std::string diagnostic_guard =
      "#if defined(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS) && "
      "VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS";
  const std::size_t bootstrap_offset =
      hwcdc_source.find("HWCDC::writeTxBootstrapFrameChecked(");
  const std::size_t bootstrap_end =
      bootstrap_offset == std::string::npos
          ? std::string::npos
          : hwcdc_source.find("\n#endif", bootstrap_offset);
  const std::string bootstrap =
      bootstrap_offset == std::string::npos ||
              bootstrap_end == std::string::npos
          ? std::string{}
          : hwcdc_source.substr(bootstrap_offset,
                                bootstrap_end - bootstrap_offset);
  const std::size_t flush_complete_offset =
      hwcdc_source.find("bool HWCDC::flushTxComplete(");
  const std::size_t flush_complete_end =
      flush_complete_offset == std::string::npos
          ? std::string::npos
          : hwcdc_source.find("\n/*\n * READING", flush_complete_offset);
  const std::string flush_complete =
      flush_complete_offset == std::string::npos ||
              flush_complete_end == std::string::npos
          ? std::string{}
          : hwcdc_source.substr(flush_complete_offset,
                                flush_complete_end - flush_complete_offset);
  const std::size_t isr_offset =
      hwcdc_source.find("static void hw_cdc_isr_handler(void *arg)");
  const std::size_t isr_end =
      isr_offset == std::string::npos
          ? std::string::npos
          : hwcdc_source.find("\n}\n\n// Moved to header", isr_offset);
  const std::string isr =
      isr_offset == std::string::npos || isr_end == std::string::npos
          ? std::string{}
          : hwcdc_source.substr(isr_offset, isr_end - isr_offset);
  const std::size_t in_empty_branch_offset = isr.find(
      "if (usbjtag_intr_status & USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY)");
  const std::size_t in_empty_lock_offset =
      in_empty_branch_offset == std::string::npos
          ? std::string::npos
          : isr.find("portENTER_CRITICAL_ISR(&hw_cdc_tx_mux);",
                     in_empty_branch_offset);
  const std::size_t live_sample_offset =
      in_empty_lock_offset == std::string::npos
          ? std::string::npos
          : isr.find(
                "live_interrupt_status = "
                "usb_serial_jtag_ll_get_intsts_mask();",
                in_empty_lock_offset);
  const std::size_t discard_isr_offset =
      hwcdc_source.find("static void hw_cdc_discard_tx_from_isr(");
  const std::size_t discard_isr_end =
      discard_isr_offset == std::string::npos
          ? std::string::npos
          : hwcdc_source.find("\n}\n\n// Caller holds hw_cdc_tx_mux",
                              discard_isr_offset);
  const std::string discard_isr =
      discard_isr_offset == std::string::npos ||
              discard_isr_end == std::string::npos
          ? std::string{}
          : hwcdc_source.substr(discard_isr_offset,
                                discard_isr_end - discard_isr_offset);
  const std::size_t debug_writer_offset =
      hwcdc_source.find("cdc0_write_char(char c)");
  const std::size_t debug_writer_end =
      debug_writer_offset == std::string::npos
          ? std::string::npos
          : hwcdc_source.find("\n}\n\nHWCDC::HWCDC()", debug_writer_offset);
  const std::string debug_writer =
      debug_writer_offset == std::string::npos ||
              debug_writer_end == std::string::npos
          ? std::string{}
          : hwcdc_source.substr(debug_writer_offset,
                                debug_writer_end - debug_writer_offset);
  report.check(
      hwcdc_header.find(diagnostic_guard) != std::string::npos &&
          hwcdc_header.find("writeTxBootstrapFrameChecked(") !=
              std::string::npos &&
          hwcdc_source.find(diagnostic_guard) != std::string::npos &&
          hwcdc_source.find("HWCDC::writeTxBootstrapFrameChecked(") !=
              std::string::npos,
      "diagnostic-only HWCDC bootstrap API is absent or not compile-guarded");
  report.check(
      hwcdc_fifo_record.find("r19_hwcdc_fifo_diagnostic_schema = 2U") !=
              std::string::npos &&
          hwcdc_fifo_record.find("storage_word_count = 28U") !=
              std::string::npos &&
          hwcdc_fifo_record.find("r19_hwcdc_fifo_diagnostic_magic") !=
              std::string::npos &&
          hwcdc_fifo_record.find("fifo_write_attempt_count") !=
              std::string::npos &&
          hwcdc_fifo_record.find("payload_in_empty_count") !=
              std::string::npos &&
          hwcdc_fifo_record.find("last_flush_blocker_mask") !=
              std::string::npos &&
          hwcdc_fifo_record.find("last_flush_outcome") !=
              std::string::npos &&
          hwcdc_fifo_record.find("last_flush_task_zlp_count") !=
              std::string::npos &&
          hwcdc_fifo_record.find("last_flush_isr_zlp_count") !=
              std::string::npos &&
          hwcdc_fifo_record.find("last_flush_terminal_blocker_mask") !=
              std::string::npos &&
          hwcdc_fifo_record.find("Fixed 112-byte") != std::string::npos &&
          hwcdc_fifo_record.find("sizeof(R19HwcdcFifoDiagnosticRecord)") !=
              std::string::npos,
      "the append-only schema 2, 28-word/112-byte Endpoint FIFO "
      "diagnostic ABI is absent");
  report.check(
      hwcdc_source.find(
          "vc_lora_r19_hwcdc_fifo_diagnostic_record") !=
              std::string::npos &&
          hwcdc_source.find("record_fifo_write(") != std::string::npos &&
          hwcdc_source.find("record_wr_done(") != std::string::npos &&
          hwcdc_source.find("record_in_empty(") != std::string::npos &&
          hwcdc_source.find("record_bus_reset(") != std::string::npos &&
          hwcdc_source.find("record_flush_attempt(") != std::string::npos &&
          hwcdc_source.find("record_flush_success(") != std::string::npos &&
          hwcdc_source.find("record_flush_timeout(") != std::string::npos &&
          hwcdc_source.find("record_flush_abort(") != std::string::npos &&
          hwcdc_fifo_record.find("FlushActive") != std::string::npos &&
          hwcdc_fifo_record.find("PayloadPublishPending") !=
              std::string::npos &&
          hwcdc_fifo_record.find("PayloadPublishAborted") !=
              std::string::npos &&
          hwcdc_fifo_record.find("PayloadFlushPending") !=
              std::string::npos &&
          hwcdc_fifo_record.find("record_payload_publish_abort") !=
              std::string::npos,
      "HWCDC does not publish the required FIFO/write/pickup/reset/flush "
      "witnesses to the JTAG-only record");
  report.check(
      hwcdc_fifo_record.find("PayloadPublishPending = 1U << 11U") !=
              std::string::npos &&
          hwcdc_fifo_record.find("PayloadPublishAborted = 1U << 12U") !=
              std::string::npos &&
          hwcdc_fifo_record.find("PayloadFlushPending = 1U << 13U") !=
              std::string::npos &&
          hwcdc_fifo_record.find(
              "r19_hwcdc_fifo_diagnostic_known_flag_mask = 0x00003FFFU") !=
              std::string::npos &&
          hwcdc_fifo_record.find("set_payload_publish_pending()") !=
              std::string::npos &&
          hwcdc_fifo_record.find("clear_payload_publish_pending()") !=
              std::string::npos &&
          hwcdc_fifo_record.find("set_payload_publish_aborted()") !=
              std::string::npos &&
          count_occurrences(hwcdc_fifo_record,
                            "set_payload_publish_aborted()") >= 2U &&
          hwcdc_fifo_record.find("clear_payload_publish_aborted()") !=
              std::string::npos &&
          count_occurrences(hwcdc_source,
                            "record_payload_publish_abort(") >= 2U,
      "the second positive FIFO publish can reuse historical completion, or "
      "task-side reset/rollback can leave its pending witness stuck");
  report.check(
      hwcdc_fifo_record.find("set_payload_flush_pending()") !=
              std::string::npos &&
          hwcdc_fifo_record.find("clear_payload_flush_pending()") !=
              std::string::npos &&
          hwcdc_fifo_record.find("had_payload_flush_pending") !=
              std::string::npos &&
          hwcdc_fifo_record.find(
              "payload_in_flight && !payload_flush_pending()") !=
              std::string::npos &&
          hwcdc_fifo_record.find(
              "payload_publish_pending() && !payload_flush_pending()") !=
              std::string::npos,
      "a new positive publication is not bound to its own later clean flush "
      "success, so historical success may be reused");
  report.check(
      in_empty_branch_offset != std::string::npos &&
          in_empty_lock_offset != std::string::npos &&
          live_sample_offset != std::string::npos &&
          in_empty_branch_offset < in_empty_lock_offset &&
          in_empty_lock_offset < live_sample_offset &&
          isr.find("record_in_empty(", live_sample_offset) !=
              std::string::npos &&
          isr.find("payload_pickup_allowed, [&]() noexcept") !=
              std::string::npos &&
          ordered_after(isr, live_sample_offset,
                        "reset_pending_before_in_empty_pickup =",
                        "live_in_empty_pending =") &&
          ordered_after(isr, live_sample_offset,
                        "live_in_empty_pending =",
                        "if (!reset_pending_before_in_empty_pickup && "
                        "live_in_empty_pending)") &&
          ordered_after(isr, live_sample_offset,
                        "if (!reset_pending_before_in_empty_pickup && "
                        "live_in_empty_pending)",
                        "record_in_empty(") &&
          ordered_after(isr, live_sample_offset, "record_in_empty(",
                        "tx_payload_pickup_generation =") &&
          count_occurrences(isr.substr(live_sample_offset),
                            "live_interrupt_status &") >= 2U &&
          isr.find("0U, live_interrupt_status", live_sample_offset) !=
              std::string::npos &&
          hwcdc_fifo_record.find(
              "saturating_increment(in_empty_irq_count_)") !=
              std::string::npos &&
          hwcdc_fifo_record.find("if (payload_pickup)") !=
              std::string::npos &&
          hwcdc_fifo_record.find(
              "saturating_increment(payload_in_empty_count_)") !=
              std::string::npos,
      "raw IN_EMPTY and transaction-qualified payload pickup are not "
      "recorded separately");
  report.check(
      discard_isr.find("const bool raw_in_empty_pending") !=
              std::string::npos &&
          ordered(discard_isr, "portENTER_CRITICAL_ISR(&hw_cdc_tx_mux);",
                  "const uint32_t source_interrupt_status") &&
          ordered(discard_isr, "const uint32_t source_interrupt_status",
                  "const bool raw_in_empty_pending") &&
          ordered(discard_isr, "const bool raw_in_empty_pending",
                  "usb_serial_jtag_ll_clr_intsts_mask(") &&
          ordered(discard_isr, "usb_serial_jtag_ll_clr_intsts_mask(",
                  "R19HwcdcFifoBusResetResult{") &&
          ordered(discard_isr, "R19HwcdcFifoBusResetResult{",
                  "record_bus_reset(") &&
          discard_isr.find("source_interrupt_status &") !=
              std::string::npos &&
          discard_isr.find("USB_SERIAL_JTAG_INTR_BUS_RESET |") !=
              std::string::npos &&
          discard_isr.find("raw_in_empty_pending,") != std::string::npos &&
          discard_isr.find("source_interrupt_status,") != std::string::npos &&
          ordered_after(
              isr,
              isr.find("if (reset_pending_before_in_empty_pickup)"),
              "hw_cdc_discard_tx_from_isr(&xTaskWoken, false)",
              "else if (!live_in_empty_pending)") &&
          ordered_after(
              isr,
              isr.find("if (reset_pending_before_in_empty_pickup)"),
              "else if (!live_in_empty_pending)",
              "else if (in_empty_allowed") &&
          ordered_after(
              hwcdc_fifo_record,
              hwcdc_fifo_record.find("if (result.raw_in_empty_pending)"),
              "if (result.raw_in_empty_pending)",
              "saturating_increment(in_empty_irq_count_)") &&
          hwcdc_fifo_record.find(
              "last_interrupt_status_ = result.source_interrupt_status") !=
              std::string::npos,
      "a BUS_RESET co-pending with IN_EMPTY loses the raw interrupt witness");
  report.check(
      hwcdc_source.find("vc_lora_r19_hwcdc_fifo_diagnostic_record") !=
              std::string::npos &&
          bridge.find("vc_lora_r19_hwcdc_fifo_diagnostic_record") ==
              std::string::npos &&
          service.find("vc_lora_r19_hwcdc_fifo_diagnostic_record") ==
              std::string::npos,
      "the Endpoint FIFO diagnostic record is not isolated from product "
      "CDC/RF/Pixhawk serialization paths");
  report.check(
      bootstrap.find("size != 63U") != std::string::npos &&
          bootstrap.find("usb_serial_jtag_ll_disable_intr_mask(") !=
              std::string::npos &&
          bootstrap.find("hw_cdc_discard_tx_from_task_locked();") !=
              std::string::npos &&
          ordered(bootstrap, "xRingbufferSend(tx_ring_buf",
                  "usb_serial_jtag_ll_ena_intr_mask(") &&
          bootstrap.find("bytes_waiting == 0") != std::string::npos &&
          bootstrap.find("tx_stash_len == 0") != std::string::npos &&
          hwcdc_source.find("tx_bootstrap_enqueue_fence") !=
              std::string::npos,
      "HWCDC bootstrap is not exact-63/all-or-zero with empty-boundary, "
      "rollback, and postcheck-before-IRQ proof");
  report.check(
      bootstrap.find("buffer == NULL || size != 63U") != std::string::npos &&
          bootstrap.find("!isPlugged()") == std::string::npos &&
          bootstrap.find("host_still_present") == std::string::npos &&
          bootstrap.find("intr_handle == NULL") != std::string::npos &&
          bootstrap.find("!connected") != std::string::npos &&
          bootstrap.find("reset_pending_before") != std::string::npos &&
          bootstrap.find("reset_pending_after") != std::string::npos &&
          bootstrap.find("!tx_fifo_quarantined") != std::string::npos &&
          bootstrap.find("free_space >= size") != std::string::npos &&
          bootstrap.find("!tx_debug_writer_active") != std::string::npos,
      "HWCDC bootstrap does not enforce null/non-63, cached-ready, dirty/full, "
      "reset, quarantine, uninitialized-ISR, and debug-writer guards while "
      "remaining independent of the fallible SOF gate");
  report.check(
      ordered(bootstrap, "xRingbufferReceiveUpTo(",
              "usb_serial_jtag_ll_write_txfifo(") &&
          ordered(bootstrap, "usb_serial_jtag_ll_write_txfifo(",
                  "reset_pending_after_fifo_write") &&
          ordered(bootstrap, "reset_pending_after_fifo_write",
                  "tx_payload_in_flight = true") &&
          bootstrap.find("sent_size < queued_size") != std::string::npos &&
          bootstrap.find("memmove(tx_stash_buf") != std::string::npos &&
          bootstrap.find("sent_size == 0U") != std::string::npos &&
          ordered(bootstrap, "tx_payload_in_flight = true",
                  "usb_serial_jtag_ll_txfifo_flush();") &&
          ordered(bootstrap, "tx_bootstrap_enqueue_fence = false",
                  "usb_serial_jtag_ll_txfifo_flush();") &&
          ordered_after(bootstrap,
                        bootstrap.find("tx_payload_in_flight = true"),
                        "usb_serial_jtag_ll_txfifo_flush();",
                        "usb_serial_jtag_ll_ena_intr_mask(") &&
          ordered(bootstrap, "usb_serial_jtag_ll_ena_intr_mask(",
                  "accepted = size") &&
          hwcdc_source.find("if (connected) {\n    return true;") !=
              std::string::npos &&
          hwcdc_source.find("connected || isPlugged();") !=
              std::string::npos,
      "false-SOF bootstrap does not prime a reset-protected payload head, "
      "retain a short-write suffix, or establish the ISR pickup witness "
      "before checked flush");
  const std::size_t bootstrap_pickup_witness =
      bootstrap.find("tx_payload_in_flight = true");
  const std::size_t bootstrap_stale_in_empty_clear =
      bootstrap_pickup_witness == std::string::npos
          ? std::string::npos
          : bootstrap.find("usb_serial_jtag_ll_clr_intsts_mask(",
                           bootstrap_pickup_witness);
  const std::size_t bootstrap_payload_publish =
      bootstrap_stale_in_empty_clear == std::string::npos
          ? std::string::npos
          : bootstrap.find("usb_serial_jtag_ll_txfifo_flush();",
                           bootstrap_stale_in_empty_clear);
  const std::size_t bootstrap_in_empty_enable =
      bootstrap_payload_publish == std::string::npos
          ? std::string::npos
          : bootstrap.find("usb_serial_jtag_ll_ena_intr_mask(",
                           bootstrap_payload_publish);
  report.check(
      bootstrap_pickup_witness != std::string::npos &&
          bootstrap_stale_in_empty_clear > bootstrap_pickup_witness &&
          bootstrap_payload_publish > bootstrap_stale_in_empty_clear &&
          bootstrap_in_empty_enable > bootstrap_payload_publish,
      "diagnostic bootstrap can arm IN_EMPTY before wr_done publishes the "
      "payload, allowing a stale empty interrupt to consume the pickup "
      "witness");
  report.check(
      !flush_complete.empty() &&
          hwcdc_source.find(
              "static volatile uint32_t tx_payload_publish_generation = 0;") !=
              std::string::npos &&
          hwcdc_source.find(
              "static volatile uint32_t tx_payload_pickup_generation = 0;") !=
              std::string::npos &&
          hwcdc_source.find(
              "tx_payload_pickup_generation = "
              "tx_payload_publish_generation;") != std::string::npos &&
          count_occurrences(hwcdc_source,
                            "tx_payload_publish_generation + 1U") >= 2U &&
          flush_complete.find("payload_pickup_complete") !=
              std::string::npos &&
          flush_complete.find("!tx_payload_in_flight") !=
              std::string::npos &&
          flush_complete.find("tx_payload_pickup_generation ==") !=
              std::string::npos &&
          flush_complete.find("tx_payload_publish_generation") !=
              std::string::npos &&
          ordered(flush_complete, "payload_pickup_complete",
                  "complete = true"),
      "flushTxComplete can report completion while the final diagnostic "
      "payload is still awaiting an IN_EMPTY pickup witness");
  report.check(
      flush_complete.find("record_flush_abort(") != std::string::npos &&
          ordered(flush_complete, "!epoch_matches", "record_flush_abort("),
      "epoch mismatch leaves a diagnostic flush attempt active instead of "
      "publishing an explicit abort outcome");
  const std::size_t isr_payload_write =
      isr.find("sent_size = usb_serial_jtag_ll_write_txfifo(");
  const std::size_t isr_fifo_record = isr.find("record_fifo_write(");
  const std::size_t isr_fifo_post_write_state =
      isr_payload_write == std::string::npos
          ? std::string::npos
          : isr.find("hw_cdc_r19_diagnostic_state_locked(",
                     isr_payload_write);
  const std::size_t isr_post_write_reset_sample =
      isr_payload_write == std::string::npos
          ? std::string::npos
          : isr.find("reset_pending_after_fifo_write", isr_payload_write);
  const std::size_t isr_payload_publish_generation =
      isr_payload_write == std::string::npos
          ? std::string::npos
          : isr.find("tx_payload_publish_generation =", isr_payload_write);
  const std::size_t isr_payload_in_flight =
      isr_payload_write == std::string::npos
          ? std::string::npos
          : isr.find("tx_payload_in_flight = true", isr_payload_write);
  const std::size_t isr_payload_flush =
      isr_payload_write == std::string::npos
          ? std::string::npos
          : isr.find("usb_serial_jtag_ll_txfifo_flush();", isr_payload_write);
  const std::size_t isr_wr_done_record =
      isr_payload_in_flight == std::string::npos
          ? std::string::npos
          : isr.find("record_wr_done(", isr_payload_in_flight);
  const std::size_t isr_payload_rearm =
      isr_payload_flush == std::string::npos
          ? std::string::npos
          : isr.find("hw_cdc_enable_tx_intr_from_isr();", isr_payload_flush);
  report.check(
      isr_fifo_record != std::string::npos &&
          isr_payload_write != std::string::npos &&
          isr_fifo_post_write_state != std::string::npos &&
          isr_post_write_reset_sample != std::string::npos &&
          isr_payload_publish_generation != std::string::npos &&
          isr_payload_in_flight != std::string::npos &&
          isr_wr_done_record != std::string::npos &&
          isr_payload_flush != std::string::npos &&
          isr_payload_rearm != std::string::npos &&
          isr_fifo_record < isr_payload_write &&
          isr_payload_write < isr_fifo_post_write_state &&
          isr_fifo_post_write_state < isr_post_write_reset_sample &&
          isr_post_write_reset_sample < isr_payload_publish_generation &&
          isr_payload_publish_generation < isr_payload_flush &&
          isr_payload_in_flight < isr_payload_flush &&
          isr_wr_done_record < isr_payload_flush &&
          isr_payload_rearm > isr_payload_flush,
      "ISR FIFO accounting does not sample the LL-write boundary before "
      "generation/in-flight publication, or payload refill publishes before "
      "arming its WR_DONE/pickup witness");
  report.check(
      hwcdc_source.find("hw_cdc_try_begin_debug_write") !=
              std::string::npos &&
          !debug_writer.empty() &&
          ordered(debug_writer, "hw_cdc_try_begin_debug_write()",
                  "flushTXBuffer(") &&
          ordered(debug_writer, "hw_cdc_try_begin_debug_write()",
                  "xRingbufferSend"),
      "cdc0_write_char can enter a ring/FIFO path without the bootstrap "
      "fence/debug-writer reservation");

  report.check(
      bridge.find("#ifndef VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS") !=
              std::string::npos &&
          bridge.find("#define VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS 0") !=
              std::string::npos &&
          bridge.find(
              "VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS must be 0 or 1") !=
              std::string::npos &&
          bridge.find(
              "R19 runtime diagnostics require the R19 candidate") !=
              std::string::npos,
      "diagnostics are not default-off and candidate-only");
  report.check(
          bridge.find(
              "#include \"high_speed/r19_runtime_fail_diagnostic.hpp\"") !=
              std::string::npos &&
          bridge.find(
              "#include \"high_speed/r19_runtime_stage_record.hpp\"") !=
              std::string::npos &&
          diagnostic.find(
              "r19_runtime_fail_diagnostic_deployment_authorized") !=
              std::string::npos &&
          diagnostic.find("false;") != std::string::npos,
      "diagnostic/stage header is absent or diagnostics are not explicitly "
      "deployment-forbidden");

  report.check(
      !recovery_enum.empty() &&
          count_occurrences(recovery_enum, "None = 0U") == 1U &&
          count_occurrences(recovery_enum, "FrameFlush") == 1U &&
          count_occurrences(recovery_enum, "GroundBoundaryFlush") == 1U &&
          ordered(recovery_enum, "None = 0U", "FrameFlush") &&
          ordered(recovery_enum, "FrameFlush", "GroundBoundaryFlush") &&
          bridge.find(
              "kR19RuntimeDiagnosticRecoveryBudgetMs = 120000U") !=
              std::string::npos &&
          bridge.find(
              "R19RuntimeDiagnosticTransportRecovery\n"
              "    r19_runtime_diagnostic_transport_recovery{") !=
              std::string::npos &&
          bridge.find("r19_runtime_diagnostic_recovery_epoch{0U}") !=
              std::string::npos &&
          bridge.find("r19_runtime_diagnostic_recovery_until_ms{0U}") !=
              std::string::npos &&
          bridge.find("r19_runtime_diagnostic_recovery_target_bytes{0U}") !=
              std::string::npos,
      "the bounded None/Frame/Ground diagnostic recovery state is absent or "
      "has drifted");
  report.check(
      !clear_recovery.empty() && !fail_transport.empty() &&
          ordered(clear_recovery,
                  "r19_runtime_diagnostic_transport_recovery =",
                  "r19_runtime_diagnostic_recovery_epoch = 0U") &&
          ordered(clear_recovery,
                  "r19_runtime_diagnostic_recovery_epoch = 0U",
                  "r19_runtime_diagnostic_recovery_until_ms = 0U") &&
          ordered(clear_recovery,
                  "r19_runtime_diagnostic_recovery_until_ms = 0U",
                  "r19_runtime_diagnostic_recovery_target_bytes = 0U") &&
          ordered(fail_transport,
                  "r19_latch_runtime_stage_transport_failure(reason, now_ms)",
                  "r19_runtime_diagnostic_transport_trace.latch_failure") &&
          ordered(fail_transport,
                  "r19_runtime_diagnostic_transport_trace.latch_failure",
                  "r19_clear_diagnostic_transport_recovery()") &&
          ordered(fail_transport,
                  "r19_clear_diagnostic_transport_recovery()",
                  "r19_runtime_fail_diagnostic_transport_failed = true"),
      "transport failure does not preserve first-wins evidence while "
      "invalidating every stale recovery owner");
  report.check(
      !arm_recovery.empty() &&
          arm_recovery.find(
              "recovery == R19RuntimeDiagnosticTransportRecovery::None") !=
              std::string::npos &&
          arm_recovery.find(
              "!r19_runtime_fail_diagnostic_transport_failed") !=
              std::string::npos &&
          arm_recovery.find(
              "r19_runtime_diagnostic_transport_recovery !=") !=
              std::string::npos &&
          arm_recovery.find("Serial.txLossEpoch() != expected_epoch") !=
              std::string::npos &&
          arm_recovery.find(
              "std::numeric_limits<std::uint64_t>::max() -") !=
              std::string::npos &&
          ordered(arm_recovery,
                  "r19_runtime_diagnostic_transport_recovery = recovery",
                  "r19_runtime_diagnostic_recovery_epoch = expected_epoch") &&
          ordered(arm_recovery,
                  "r19_runtime_diagnostic_recovery_epoch = expected_epoch",
                  "now_ms + kR19RuntimeDiagnosticRecoveryBudgetMs") &&
          ordered(arm_recovery,
                  "r19_runtime_diagnostic_recovery_target_bytes = "
                  "target_bytes",
                  "R19RuntimeStage::TransportRecoveryEntered") &&
          ordered(arm_recovery,
                  "R19RuntimeStage::TransportRecoveryEntered",
                  "return true"),
      "recovery can arm without a failed same-epoch owner, overflow-safe "
      "deadline, target snapshot, or entered-stage witness");

  report.check(
      stage_record.find(
          "TransportRecoveryEntered = 1U << 15U") != std::string::npos &&
          stage_record.find(
              "TransportRecoveryCompleted = 1U << 16U") !=
              std::string::npos &&
          ordered(stage_record, "FlushCompleted = 1U << 14U",
                  "TransportRecoveryEntered = 1U << 15U") &&
          ordered(stage_record, "TransportRecoveryEntered = 1U << 15U",
                  "TransportRecoveryCompleted = 1U << 16U") &&
          count_occurrences(
              stage_reader,
              "0x8000 = 'TransportRecoveryEntered'") == 1U &&
          count_occurrences(
              stage_reader,
              "0x10000 = 'TransportRecoveryCompleted'") == 1U,
      "recovery entered/completed bits are not fixed at 15/16 in both the "
      "record and JTAG decoder");

  report.check(
      !ground_recovery_safe.empty() &&
          ground_recovery_safe.find(
              "R19RuntimeFailGroundBoundaryStatus::DrainingAdmitted") !=
              std::string::npos &&
          ground_recovery_safe.find(
              "!ground_paced_heartbeat_commit_active") !=
              std::string::npos &&
          ground_recovery_safe.find(
              "!ground_parameter_publish_commit_active") !=
              std::string::npos &&
          ground_recovery_safe.find("!r19_ground_usb_commit_active") !=
              std::string::npos &&
          ground_recovery_safe.find(
              "ground_usb_ordered_backlog.empty()") != std::string::npos &&
          ground_recovery_safe.find(
              "ground_usb_heartbeat_pacer.queued() == 0U") !=
              std::string::npos &&
          ground_recovery_safe.find("egress.empty()") != std::string::npos &&
          ground_recovery_safe.find("!egress.write_pending()") !=
              std::string::npos &&
          ground_recovery_safe.find("egress.stats().bytes_committed >") !=
              std::string::npos &&
          ground_recovery_safe.find(
              "ground_usb_transport_published_bytes") != std::string::npos,
      "Ground recovery-safe admission does not require one complete drained "
      "admitted prefix with every product owner/backlog inactive");
  report.check(
      !ground_convergence.empty() &&
          count_occurrences(
              ground_convergence,
              "r19_arm_diagnostic_transport_recovery(") == 3U &&
          ground_convergence.find("GroundBoundaryDeadlineExpired") !=
              std::string::npos &&
          ground_convergence.find("GroundBoundaryFlushFailed") !=
              std::string::npos &&
          ground_convergence.find("GroundBoundaryFlushLate") !=
              std::string::npos &&
          count_occurrences(
              ground_convergence,
              "R19RuntimeDiagnosticTransportRecovery::GroundBoundaryFlush") ==
              3U,
      "Ground deadline/failed-flush/late-flush paths do not exclusively arm "
      "the retained-boundary recovery owner");
  report.check(
      !ground_recovery.empty() &&
          ground_recovery.find(
              "R19RuntimeDiagnosticTransportRecovery::GroundBoundaryFlush") !=
              std::string::npos &&
          ground_recovery.find(
              "R19RuntimeFailGroundBoundaryStatus::Impossible") !=
              std::string::npos &&
          ground_recovery.find(
              "r19_runtime_diagnostic_recovery_epoch !=") !=
              std::string::npos &&
          ground_recovery.find(
              "Serial.txLossEpoch() != "
              "r19_runtime_diagnostic_recovery_epoch") !=
              std::string::npos &&
          ground_recovery.find(
              "now_ms >= r19_runtime_diagnostic_recovery_until_ms") !=
              std::string::npos &&
          ground_recovery.find(
              "egress.stats().bytes_committed !=") != std::string::npos &&
          ground_recovery.find(
              "r19_runtime_diagnostic_recovery_target_bytes") !=
              std::string::npos &&
          count_occurrences(ground_recovery,
                            "r19_flush_runtime_diagnostic(") == 1U &&
          compact_ground_recovery.find(
              "if(!r19_flush_runtime_diagnostic("
              "r19_runtime_diagnostic_recovery_epoch,"
              "kR19RuntimeFailDiagnosticFlushBudgetMs,completed_ms,"
              "r19_runtime_diagnostic_recovery_until_ms)){returnfalse;}") !=
              std::string::npos &&
          compact_ground_recovery.find(
              "if(Serial.txLossEpoch()!=r19_runtime_diagnostic_recovery_epoch"
              "||completed_ms>=r19_runtime_diagnostic_recovery_until_ms)"
              "{r19_clear_diagnostic_transport_recovery();returnfalse;}"
              "ground_usb_transport_published_bytes=") !=
              std::string::npos &&
          ground_recovery.find("flush_ground_usb_transport(") ==
              std::string::npos &&
          ground_recovery.find("Serial.flushTxComplete(") ==
              std::string::npos &&
          ordered_after(
              ground_recovery,
              ground_recovery.find("if (!r19_flush_runtime_diagnostic("),
              "completed_ms >= r19_runtime_diagnostic_recovery_until_ms",
              "ground_usb_transport_published_bytes =") &&
          ground_recovery.find("pump_local_egress_if_connected") ==
              std::string::npos &&
          ground_recovery.find("writeTx") == std::string::npos &&
          ordered_after(
              ground_recovery,
              ground_recovery.find("ground_usb_transport_published_bytes ="),
              "R19RuntimeFailGroundBoundaryStatus::Clean",
              "r19_clear_diagnostic_transport_recovery()") &&
          ordered_after(
              ground_recovery,
              ground_recovery.find("ground_usb_transport_published_bytes ="),
              "r19_clear_diagnostic_transport_recovery()",
              "r19_runtime_fail_diagnostic_transport_failed = false") &&
          ordered_after(
              ground_recovery,
              ground_recovery.find("ground_usb_transport_published_bytes ="),
              "R19RuntimeStageCounter::Retry",
              "R19RuntimeStage::TransportRecoveryCompleted"),
      "Ground recovery is not a target-stable same-epoch flush-only proof, or "
      "it clears fail-stop before committing the exact boundary and stage");
  report.check(
      !frame_recovery.empty() &&
          frame_recovery.find(
              "R19RuntimeDiagnosticTransportRecovery::FrameFlush") !=
              std::string::npos &&
          frame_recovery.find(
              "!r19_runtime_fail_diagnostic_transport_failed") !=
              std::string::npos &&
          frame_recovery.find("!r19_runtime_fail_diagnostic_staged") !=
              std::string::npos &&
          frame_recovery.find("!r19_runtime_fail_diagnostic_flush_pending") !=
              std::string::npos &&
          frame_recovery.find(
              "r19_runtime_diagnostic_action == "
              "R19RuntimeDiagnosticAction::None") != std::string::npos &&
          frame_recovery.find("r19_runtime_diagnostic_pending()") !=
              std::string::npos &&
          frame_recovery.find(
              "Serial.txLossEpoch() != "
              "r19_runtime_diagnostic_recovery_epoch") !=
              std::string::npos &&
          frame_recovery.find(
              "now_ms >= r19_runtime_diagnostic_recovery_until_ms") !=
              std::string::npos &&
          count_occurrences(frame_recovery,
                            "r19_flush_runtime_diagnostic(") == 1U &&
          compact_frame_recovery.find(
              "constboolflushed=r19_flush_runtime_diagnostic("
              "r19_runtime_diagnostic_recovery_epoch,"
              "kR19RuntimeFailDiagnosticFlushBudgetMs,flush_completed_ms);") !=
              std::string::npos &&
          compact_frame_recovery.find(
              "if(!flushed){if(Serial.txLossEpoch()!="
              "r19_runtime_diagnostic_recovery_epoch||"
              "flush_completed_ms>=r19_runtime_diagnostic_recovery_until_ms)"
              "{r19_clear_diagnostic_transport_recovery();}returnfalse;}") !=
              std::string::npos &&
          compact_frame_recovery.find(
              "if(Serial.txLossEpoch()!=r19_runtime_diagnostic_recovery_epoch"
              "||flush_completed_ms>=r19_runtime_diagnostic_recovery_until_ms)"
              "{r19_clear_diagnostic_transport_recovery();returnfalse;}"
              "r19_mark_runtime_stage(R19RuntimeStage::FlushCompleted);") !=
              std::string::npos &&
          ordered_after(
              frame_recovery,
              frame_recovery.find("if (!flushed) {"),
              "flush_completed_ms >= r19_runtime_diagnostic_recovery_until_ms",
              "r19_mark_runtime_stage(R19RuntimeStage::FlushCompleted)") &&
          frame_recovery.find("flush_ground_usb_transport(") ==
              std::string::npos &&
          frame_recovery.find("Serial.flushTxComplete(") ==
              std::string::npos &&
          frame_recovery.find("writeTx") == std::string::npos &&
          frame_recovery.find("r19_runtime_diagnostic_pending_write") ==
              std::string::npos &&
          ordered_after(
              frame_recovery,
              frame_recovery.find(
                  "r19_mark_runtime_stage(R19RuntimeStage::FlushCompleted)"),
              "r19_clear_diagnostic_transport_recovery()",
              "r19_runtime_diagnostic_cadence.commit") &&
          ordered_after(
              frame_recovery,
              frame_recovery.find(
                  "r19_mark_runtime_stage(R19RuntimeStage::FlushCompleted)"),
              "r19_runtime_fail_diagnostic_transport_failed = false",
              "R19RuntimeStageCounter::Retry") &&
          ordered_after(
              frame_recovery,
              frame_recovery.find(
                  "r19_mark_runtime_stage(R19RuntimeStage::FlushCompleted)"),
              "R19RuntimeStageCounter::Retry",
              "R19RuntimeStage::TransportRecoveryCompleted"),
      "frame recovery can replay bytes, cross an epoch/deadline, or release "
      "fail-stop before the retained publisher and cadence commit");
  report.check(
      !failed_transport_dispatch.empty() &&
          ordered(failed_transport_dispatch,
                  "R19RuntimeDiagnosticTransportRecovery::"
                  "GroundBoundaryFlush",
                  "r19_recover_ground_runtime_fail_boundary_flush()") &&
          ordered(failed_transport_dispatch,
                  "r19_recover_ground_runtime_fail_boundary_flush()",
                  "R19RuntimeDiagnosticTransportRecovery::FrameFlush") &&
          ordered(failed_transport_dispatch,
                  "R19RuntimeDiagnosticTransportRecovery::FrameFlush",
                  "r19_recover_runtime_diagnostic_frame_flush()") &&
          count_occurrences(failed_transport_dispatch, "return;") == 3U &&
          failed_transport_dispatch.find("writeTx") == std::string::npos &&
          failed_transport_dispatch.find("r19_stage_runtime_diagnostic") ==
              std::string::npos &&
          count_occurrences(service,
                            "r19_arm_diagnostic_transport_recovery(") == 4U,
      "failed transport does not dispatch only the owned recovery before "
      "returning, or the four complete-frame failure sites are not wired");

  report.check(
      stage_record.find("enum class R19RuntimeStage") != std::string::npos &&
          stage_record.find("single firmware task writer") !=
              std::string::npos &&
          stage_record.find("must not be called from an ISR") !=
              std::string::npos &&
          stage_record.find("SetupEntered") != std::string::npos &&
          stage_record.find("SerialBeginReturned") != std::string::npos &&
          stage_record.find("CadenceStarted") != std::string::npos &&
          stage_record.find("IdentityReady") != std::string::npos &&
          stage_record.find("E220ProfileChecked") != std::string::npos &&
          stage_record.find("StartupAllowed") != std::string::npos &&
          stage_record.find("E220NormalMode") != std::string::npos &&
          stage_record.find("AdapterReady") != std::string::npos &&
          stage_record.find("SetupComplete") != std::string::npos &&
          stage_record.find("LoopEntered") != std::string::npos &&
          stage_record.find("HostGateObserved") != std::string::npos &&
          stage_record.find("FrameStaged") != std::string::npos &&
          stage_record.find("WriteAttempted") != std::string::npos &&
          stage_record.find("WriteAccepted") != std::string::npos &&
          stage_record.find("FlushCompleted") != std::string::npos &&
          stage_record.find("TransportRecoveryEntered") !=
              std::string::npos &&
          stage_record.find("TransportRecoveryCompleted") !=
              std::string::npos,
      "the fixed runtime stage vocabulary is incomplete");
  report.check(
      stage_record.find("std::atomic<std::uint32_t>") ==
              std::string::npos &&
          stage_record.find("fetch_add(") == std::string::npos &&
          stage_record.find("compare_exchange") == std::string::npos &&
          stage_record.find(
              "volatile std::uint32_t active_writer_") !=
              std::string::npos &&
          stage_record.find("(sequence_before & 1U) != 0U") !=
              std::string::npos &&
          stage_record.find("(sequence_after & 1U) == 0U") !=
              std::string::npos &&
          stage_record.find("active_writer_ == 0U") !=
              std::string::npos &&
          ordered(stage_record, "first_failure_stage_mask_ = stage_mask_",
                  "first_failure_ = failure"),
      "stage record violates the ESP32 single-writer odd/even publication "
      "contract");
  report.check(
      bridge.find("extern \"C\" {") != std::string::npos &&
          bridge.find("vc_lora_r19_runtime_stage_record") !=
              std::string::npos &&
          bridge.find("__attribute__((used, aligned(4)))") !=
              std::string::npos &&
          bridge.find("kR19RuntimeDiagnosticGenerationFingerprint") !=
              std::string::npos &&
          bridge.find("Exact candidate") != std::string::npos &&
          bridge.find("identity comes from the") != std::string::npos &&
          bridge.find("sealed artifact/readback SHA-256 evidence") !=
              std::string::npos &&
          bridge.find("r19_initialize_runtime_stage_record()") !=
              std::string::npos,
      "the fixed-name, aligned JTAG runtime stage record is not integrated");

  const std::size_t setup_offset =
      bridge.find("void setup_bridge() noexcept {");
  const std::size_t setup_end =
      setup_offset == std::string::npos
          ? std::string::npos
          : bridge.find("\n}\n\nvoid loop_bridge() noexcept {", setup_offset);
  const std::string setup =
      setup_offset == std::string::npos || setup_end == std::string::npos
          ? std::string{}
          : bridge.substr(setup_offset, setup_end - setup_offset);
  report.check(
      ordered(setup, "r19_initialize_runtime_stage_record();",
              "digitalWrite(kE220M0Pin, HIGH);") &&
          bridge.find(
              "r19_mark_runtime_stage(R19RuntimeStage::SetupEntered);") !=
              std::string::npos &&
          ordered(setup, "digitalWrite(kE220M0Pin, HIGH);",
                  "Serial.begin(") &&
          ordered(setup, "Serial.begin(",
                  "R19RuntimeStage::SerialBeginReturned") &&
          ordered(setup, "R19RuntimeStage::SerialBeginReturned",
                  "R19RuntimeStage::CadenceStarted") &&
          ordered(setup, "R19RuntimeStage::CadenceStarted",
                  "R19RuntimeStage::IdentityReady") &&
          ordered(setup, "R19RuntimeStage::IdentityReady",
                  "R19RuntimeStage::E220ProfileChecked") &&
          ordered(setup, "R19RuntimeStage::E220ProfileChecked",
                  "R19RuntimeStage::StartupAllowed") &&
          ordered(setup, "R19RuntimeStage::StartupAllowed",
                  "R19RuntimeStage::E220NormalMode") &&
          ordered(setup, "R19RuntimeStage::E220NormalMode",
                  "R19RuntimeStage::AdapterReady") &&
          ordered(setup, "R19RuntimeStage::AdapterReady",
                  "R19RuntimeStage::SetupComplete"),
      "setup milestones are absent or out of execution order");
  report.check(
      ordered(loop, "R19RuntimeStage::LoopEntered",
              "r19_service_runtime_fail_diagnostic();") &&
          loop.find("R19RuntimeStageCounter::Loop") != std::string::npos &&
          ordered(service, "R19RuntimeStage::HostGateObserved",
                  "R19RuntimeStage::FrameStaged") &&
          ordered(service, "R19RuntimeStage::FrameStaged",
                  "R19RuntimeStage::WriteAttempted") &&
          ordered(service, "R19RuntimeStage::WriteAttempted",
                  "R19RuntimeStage::WriteAccepted") &&
          ordered(service, "R19RuntimeStage::WriteAccepted",
                  "R19RuntimeStage::FlushCompleted") &&
          service.find("R19RuntimeStageCounter::PublishAttempt") !=
              std::string::npos &&
          count_occurrences(service,
                            "R19RuntimeStageCounter::Retry") == 3U &&
          bridge.find("r19_latch_runtime_stage_transport_failure(") !=
              std::string::npos,
      "loop/publication milestones, counters, or first transport failure "
      "latch are not integrated");
  report.check(
      bridge.find("vc_lora_r19_runtime_stage_record.try_snapshot") ==
              std::string::npos &&
          service.find("e220_serial.write(") == std::string::npos &&
          service.find("pixhawk_serial.write(") == std::string::npos,
      "the JTAG-only stage record can be serialized to CDC/RF/Pixhawk");

  report.check(
      bridge.find("#define latch_runtime_fail_closed()") !=
              std::string::npos &&
          bridge.find("latch_runtime_fail_closed_at(") != std::string::npos &&
          bridge.find("__LINE__") != std::string::npos &&
          count_occurrences(bridge, "latch_runtime_fail_closed();") >= 12U,
      "existing fail-close sites are not captured by a source-line macro");
  report.check(
      bridge.find("R19RuntimeFailLatch r19_runtime_fail_latch") !=
              std::string::npos &&
          bridge.find("R19RuntimeFailDiagnosticPublisher") !=
              std::string::npos &&
          bridge.find("r19_runtime_fail_latch.latch(") != std::string::npos,
      "first-wins evidence is not owned by the canonical bridge");
  report.check(
          diagnostic.find("startup_fault") != std::string::npos &&
          diagnostic.find("adapter_fail_closed ? 0x80U : 0U") !=
              std::string::npos &&
          diagnostic.find("status.tdd_state > 0x7FU") != std::string::npos,
      "startup fault or bounded adapter/TDD status packing is absent");

  report.check(
      bridge.find("startup_contract.transmission_allowed()") !=
              std::string::npos &&
          bridge.find("capture_r19_startup_contract_failure") !=
              std::string::npos &&
          ordered(setup, "capture_r19_startup_contract_failure();",
                  "return;") &&
          ordered(setup, "capture_r19_startup_contract_failure();",
                  "start_e220_normal_mode();"),
      "identity/profile startup failure is not latched before setup returns");
  report.check(
      ordered(loop, "void loop_bridge() noexcept {",
              "r19_service_runtime_fail_diagnostic();") &&
          ordered(loop, "r19_service_runtime_fail_diagnostic();",
                  "if (!bridge_ready || runtime_fail_closed)"),
      "diagnostic service cannot advance through the loop fail/!ready guard");

  report.check(
      bridge.find("r19_ground_runtime_fail_boundary_clean") !=
              std::string::npos &&
          bridge.find("ground_paced_heartbeat_commit_active") !=
              std::string::npos &&
          bridge.find("ground_parameter_publish_commit_active") !=
              std::string::npos &&
          bridge.find("r19_ground_usb_commit_active") != std::string::npos &&
          bridge.find("egress.write_pending()") != std::string::npos &&
          bridge.find("egress.empty()") != std::string::npos &&
          bridge.find("ground_usb_transport_published_bytes") !=
              std::string::npos,
      "Ground diagnostics are not fenced by the complete clean USB boundary");
  const auto ground_boundary_reason_is_wired =
      [&bridge, &diagnostic](const char* reason) noexcept {
        return diagnostic.find(reason) != std::string::npos &&
               bridge.find(reason) != std::string::npos;
      };
  report.check(
      ground_boundary_reason_is_wired(
          "GroundBoundaryHostLostWhileDraining"),
      "Ground host-loss-while-draining reason is not wired");
  report.check(
      ground_boundary_reason_is_wired(
          "GroundBoundaryHostAbsentWithIrreversiblePrefix"),
      "Ground host-absent irreversible-prefix reason is not wired");
  report.check(ground_boundary_reason_is_wired(
                   "GroundBoundaryEpochChanged"),
               "Ground boundary epoch-change reason is not wired");
  report.check(ground_boundary_reason_is_wired(
                   "GroundBoundaryDeadlineExpired"),
               "Ground boundary deadline-expiry reason is not wired");
  report.check(
      ground_boundary_reason_is_wired(
          "GroundBoundaryOrderedBacklogDiscardFailed"),
      "Ground ordered-backlog discard reason is not wired");
  report.check(
      ground_boundary_reason_is_wired(
          "GroundBoundaryHeldHeartbeatDiscardFailed"),
      "Ground held-heartbeat discard reason is not wired");
  report.check(ground_boundary_reason_is_wired(
                   "GroundBoundaryEgressPumpInvalid"),
               "Ground egress-pump-invalid reason is not wired");
  report.check(ground_boundary_reason_is_wired(
                   "GroundBoundaryFlushFailed"),
               "Ground boundary flush-failure reason is not wired");
  report.check(ground_boundary_reason_is_wired(
                   "GroundBoundaryFlushEpochChanged"),
               "Ground boundary flush epoch-change reason is not wired");
  report.check(ground_boundary_reason_is_wired(
                   "GroundBoundaryFlushLate"),
               "Ground boundary late-flush reason is not wired");
  report.check(
      count_occurrences(
          bridge,
          "r19_mark_ground_runtime_fail_boundary_impossible(") == 14U &&
          bridge.find("R19RuntimeDiagnosticTransportFailureReason reason") !=
              std::string::npos &&
          diagnostic.find("GroundBoundaryImpossible") != std::string::npos &&
          bridge.find("GroundBoundaryImpossible") == std::string::npos,
      "Ground boundary marker is not one definition plus thirteen exact-reason "
      "calls, or the legacy aggregate reason is still emitted");
  report.check(
      bridge.find("kR19RuntimeFailDiagnosticWriteChunkBytes = 32U") !=
              std::string::npos &&
          bridge.find("Serial.writeTxChecked(") != std::string::npos &&
          bridge.find("Serial.writeTxBootstrapFrameChecked(") !=
              std::string::npos &&
          bridge.find("flush_ground_usb_transport(") != std::string::npos,
      "Ground diagnostic lacks bounded product writes, complete-frame "
      "bootstrap, or flush proof");
  report.check(
      bridge.find("kR19RuntimeFailDiagnosticVehicleBaud = 115200U") !=
              std::string::npos &&
          bridge.find("Serial.begin(kR19RuntimeFailDiagnosticVehicleBaud)") !=
              std::string::npos &&
          service.find("Serial.isPlugged()") != std::string::npos &&
          service.find("const bool endpoint_ready = static_cast<bool>(Serial)") !=
              std::string::npos &&
          service.find("if (!host_plugged)") == std::string::npos &&
          service.find("Serial.writeTxChecked(") != std::string::npos &&
          count_occurrences(service, "r19_flush_runtime_diagnostic(") == 1U &&
          compact_service.find(
              "constboolflushed=r19_flush_runtime_diagnostic("
              "r19_runtime_fail_diagnostic_transport_epoch,flush_budget_ms,"
              "flush_completed_ms);") != std::string::npos &&
          compact_service.find(
              "std::min<std::uint64_t>(kR19RuntimeFailDiagnosticFlushBudgetMs,"
              "flush_remaining_ms)") != std::string::npos &&
          ordered(service, "r19_runtime_diagnostic_frame_deadline_ms - "
                           "flush_started_ms",
                  "const bool flushed = r19_flush_runtime_diagnostic(") &&
          ordered_after(service,
              service.find("const bool flushed = r19_flush_runtime_diagnostic("),
              "if (!flushed)",
              "failed_flush_epoch ==") &&
          service.find("Serial.flushTxComplete(") == std::string::npos,
      "Vehicle COM3 is not host-ready, epoch-checked, written, and flushed");
  report.check(
      !diagnostic_flush_enabled.empty() &&
          count_occurrences(diagnostic_flush_enabled,
                            "Serial.flushTxCompleteDiagnostic(") == 1U &&
          compact_flush_enabled.find(
              "call.budget_ms=budget_ms;call.expected_epoch=expected_epoch;") !=
              std::string::npos &&
          compact_flush_enabled.find(
              "call.deadline_us=(deadline_ms!=0U?deadline_ms:"
              "r19_runtime_diagnostic_frame_deadline_ms)*1000U;") !=
              std::string::npos &&
          compact_flush_enabled.find(
              "constboolcalled=budget_ms!=0U;constboolraw=called&&"
              "Serial.flushTxCompleteDiagnostic(budget_ms,expected_epoch,"
              "call.sdk);") != std::string::npos &&
          compact_flush_enabled.find("if(!called)call.sdk={};") !=
              std::string::npos &&
          ordered(diagnostic_flush_enabled, "call.started_us =",
                  "Serial.flushTxCompleteDiagnostic(") &&
          ordered(diagnostic_flush_enabled, "Serial.flushTxCompleteDiagnostic(",
                  "call.finished_us =") &&
          compact_flush_enabled.find(
              "completed_ms=call.finished_us/1000U;"
              "#ifdefined(VC_LORA_PHASE6_GROUND)"
              "returnraw&&completed_ms-call.started_us/1000U<=budget_ms;"
              "#elsereturnraw;#endif") != std::string::npos &&
          diagnostic_flush_enabled.find("flush_ground_usb_transport(") ==
              std::string::npos &&
          diagnostic_flush_enabled.find("Serial.flushTxComplete(") ==
              std::string::npos,
      "feature1 diagnostic flush does not preserve same-epoch bounded SDK "
      "completion and role-specific raw-return semantics");
  report.check(
      !diagnostic_flush_legacy.empty() &&
          compact_flush_legacy ==
              "#else(void)deadline_ms;#ifdefined(VC_LORA_PHASE6_GROUND)"
              "returnflush_ground_usb_transport(expected_epoch,budget_ms,"
              "completed_ms);#elseconstboolraw=Serial.flushTxComplete("
              "budget_ms,expected_epoch);completed_ms=monotonic_now_ms();"
              "returnraw;#endif" &&
          count_occurrences(diagnostic_flush_legacy,
                            "flush_ground_usb_transport(") == 1U &&
          count_occurrences(diagnostic_flush_legacy,
                            "Serial.flushTxComplete(") == 1U,
      "feature0 diagnostic flush changes the exact existing checked Ground "
      "transport or Vehicle budget/epoch/raw completion contract");
  report.check(
      !diagnostic_flush.empty() &&
          diagnostic_flush.find("writeTx") == std::string::npos &&
          diagnostic_flush.find("Serial.write(") == std::string::npos &&
          diagnostic_flush.find(".commit(") == std::string::npos &&
          diagnostic_flush.find(".reset(") == std::string::npos &&
          diagnostic_flush.find("r19_clear_diagnostic_transport_recovery(") ==
              std::string::npos &&
          diagnostic_flush.find("r19_runtime_fail_diagnostic_transport_failed =") ==
              std::string::npos &&
          diagnostic_flush.find("r19_mark_runtime_stage(") ==
              std::string::npos &&
          diagnostic_flush.find("return true") == std::string::npos,
      "diagnostic flush wrapper can replay payload, commit/reset publisher "
      "state, release recovery ownership, or manufacture completion");
  report.check(
      bridge.find("Serial.print(") == std::string::npos &&
          bridge.find("Serial.println(") == std::string::npos &&
          !service.empty() &&
          service.find("e220_serial.write(") == std::string::npos &&
          service.find("pixhawk_serial.write(") == std::string::npos,
      "diagnostic bytes can leak as ASCII or into RF/Pixhawk transports");
}

}  // namespace

int main() {
  TestReport report{};
  test_product_integration_contract(report);
  std::cout << "UT-R19-RUNTIME-FAIL-PRODUCT-SOURCE-001 checks="
            << report.checks << " failures=" << report.failures << '\n';
  return report.failures == 0U ? 0 : 1;
}
