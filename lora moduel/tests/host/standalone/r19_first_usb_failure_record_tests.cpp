#include <cstddef>
#include <cstdint>
#include <iostream>
#include <type_traits>
#include "../../../firmware/high_speed/r19_first_usb_failure_record.hpp"

namespace vc_lora::experimental {
struct R19FirstUsbFailureRecordTestAccess final {
  static std::uint32_t word(const R19FirstUsbFailureRecord& r, std::size_t n) { return r.words_[n]; }
  static void begin(R19FirstUsbFailureRecord& r) { r.begin_write(); }
  static void end(R19FirstUsbFailureRecord& r) { r.commit_write(); }
};
}
int main() {
  using namespace vc_lora::experimental;
  static_assert(sizeof(R19FirstUsbFailureRecord) == 384U);
  static_assert(alignof(R19FirstUsbFailureRecord) == 4U);
  static_assert(std::is_standard_layout_v<R19FirstUsbFailureRecord>);
  std::size_t checks = 0, failures = 0;
  auto check = [&](bool ok, const char* name) { ++checks; if (!ok) { ++failures; std::cerr << "FAIL " << name << '\n'; } };
  constexpr R19RuntimeBuildFingerprint fp{1U,2U,3U,4U};
  constexpr R19BootInstance boot{0xAAU,0xBBU,0xCCU,0xDDU};
  R19FirstUsbFailureRecord record;
  R19FirstUsbFailureSnapshot s;
  check(record.try_snapshot(s) && !s.valid_header(), "zero not initialized");
  check(!record.initialize(R19RuntimeStageRole::Invalid, fp, boot), "invalid role");
  check(!record.initialize(R19RuntimeStageRole::Ground, fp, {}), "zero boot rejected");
  check(record.initialize(R19RuntimeStageRole::Ground, fp, boot), "initialize ground");
  check(!record.initialize(R19RuntimeStageRole::Ground, fp, boot), "cannot reinitialize immutable boot");
  check(record.try_snapshot(s) && s.valid_header() && !s.failure_latched() && s.boot_instance == boot, "header identity");
  R19FirstUsbFailureEvidence e;
  e.reason = 1; e.source_line = 3243; e.token = 0x1234; e.attempt_id = 5;
  e.wrapper_flags = 1U | 4U | 8U; e.budget_ms = 106; e.expected_epoch = 1; e.observed_epoch = 1;
  e.started_us = 0x1234567800000001ULL; e.finished_us = e.started_us + 106000; e.deadline_us = e.finished_us;
  e.failure_observed_us = e.finished_us + 10U;
  e.expected_frame_bytes = 21; e.accepted_frame_bytes = 21;
  e.sdk.schema = 1; e.sdk.validity_flags = 0x1F; e.sdk.transaction_token = e.token; e.sdk.attempt_id = e.attempt_id;
  e.sdk.terminal_reason = 5; e.sdk.timeout_ms = 100; e.sdk.lock_wait_ms = 2; e.sdk.elapsed_ms = 106;
  e.sdk.raw_return = 0; e.sdk.state_flags = 0x2417; e.sdk.ring_pending_bytes = 31;
  e.sdk.publish_generation = 98; e.sdk.pickup_generation = 97; e.sdk.raw_interrupt_status = 0x102;
  e.sdk.interrupt_enable_mask = 0x20c; e.sdk.flush_blocker_mask = 0x1c;
  auto bad = e; bad.wrapper_flags = 0x10; check(!record.latch_first_failure(bad), "unknown flags");
  bad = e; bad.accepted_frame_bytes = 22; check(!record.latch_first_failure(bad), "impossible bytes");
  bad = e; bad.sdk.transaction_token++; check(!record.latch_first_failure(bad), "wrong sdk transaction");
  bad = e; bad.sdk.terminal_reason = 7; check(!record.latch_first_failure(bad), "unknown sdk terminal");
  bad = e; bad.sdk.terminal_reason = 1; check(!record.latch_first_failure(bad), "success/false contradiction");
  bad = e; bad.failure_observed_us = bad.finished_us - 1; check(!record.latch_first_failure(bad), "failure clock precedes return");
  bad = e; bad.sdk.state_flags |= 0x4000U; check(!record.latch_first_failure(bad), "unknown SDK state flag");
  bad = e; bad.sdk.flush_blocker_mask |= 0x100U; check(!record.latch_first_failure(bad), "unknown SDK blocker flag");
  bad = e; bad.sdk.validity_flags &= ~8U; check(!record.latch_first_failure(bad), "unobserved SDK snapshot cannot contain state");
  check(record.latch_first_failure(e), "first failure saved");
  check(record.try_snapshot(s) && s.failure_latched() && s.started_us == e.started_us && s.finished_us == e.finished_us &&
        s.failure_observed_us == e.finished_us + 10U && s.sdk.lock_wait_ms == 2 && s.sdk.ring_pending_bytes == 31 && s.sdk.publish_generation == 98 && s.sdk.pickup_generation == 97,
        "full-width time and first FIFO captured");
  auto seq = s.sequence; bad = e; bad.source_line = 9999;
  check(!record.latch_first_failure(bad) && record.try_snapshot(s) && s.source_line == 3243 && s.sequence == seq, "later diagnostic cannot overwrite");
  check(!record.observe_clock_sync(1, 10), "foreign nonce rejected");
  constexpr std::uint64_t nonce = 0x5219000000000123ULL;
  check(record.observe_clock_sync(nonce, 0xABCDEF0100000042ULL), "sameboot later clock sync");
  check(record.try_snapshot(s) && s.sync_count == 1 && s.last_sync_nonce == nonce && s.last_sync_device_us == 0xABCDEF0100000042ULL &&
        s.source_line == 3243 && s.sdk.ring_pending_bytes == 31 && s.boot_instance == boot, "sync mutable first failure immutable");
  check(R19FirstUsbFailureRecordTestAccess::word(record, 2) == 0x52313955 &&
        R19FirstUsbFailureRecordTestAccess::word(record, 16) == 0x123 &&
        R19FirstUsbFailureRecordTestAccess::word(record, 17) == 0x52190000 &&
        R19FirstUsbFailureRecordTestAccess::word(record, 28) == 1 &&
        R19FirstUsbFailureRecordTestAccess::word(record, 29) == 0x12345678 &&
        R19FirstUsbFailureRecordTestAccess::word(record, 36) == 1 &&
        R19FirstUsbFailureRecordTestAccess::word(record, 50) == 31, "fixed raw offsets little endian");
  auto sentinel = s; R19FirstUsbFailureRecordTestAccess::begin(record);
  check(!record.try_snapshot(s, 1) && s.sequence == sentinel.sequence, "torn read rejected without output mutation");
  R19FirstUsbFailureRecordTestAccess::end(record);
  check(!record.try_snapshot(s, 0), "zero attempts");
  R19FirstUsbFailureRecord vehicle;
  check(vehicle.initialize(R19RuntimeStageRole::Vehicle, fp, boot) && !vehicle.latch_first_failure(e) && vehicle.observe_clock_sync(nonce, 20), "vehicle identity/sync not Groundfailure");
  R19FirstUsbFailureRecord noapi;
  check(noapi.initialize(R19RuntimeStageRole::Ground, fp, boot), "initialize uncalled");
  bad = e; bad.wrapper_flags = 4; check(!noapi.latch_first_failure(bad), "uncalled sdk data rejected");
  e.reason = 2; e.wrapper_flags = 4; e.sdk = {}; e.finished_us = e.started_us;
  check(noapi.latch_first_failure(e) && noapi.try_snapshot(s) && !s.api_called(), "uncalled is not false API result");
  R19FirstUsbFailureRecord nosnapshot;
  check(nosnapshot.initialize(R19RuntimeStageRole::Ground, fp, boot), "initialize no snapshot");
  e.reason=1U;e.wrapper_flags=1U|4U|8U;e.sdk={};e.sdk.validity_flags=0x13U;e.sdk.transaction_token=e.token;e.sdk.attempt_id=e.attempt_id;e.sdk.terminal_reason=2U;
  check(nosnapshot.latch_first_failure(e) && nosnapshot.try_snapshot(s) && (s.sdk.validity_flags&8U)==0U, "null resource explicitly lacks snapshot");
  std::cout << "UT-R19-FIRST-USB-FAILURE-RECORD-001 checks=" << checks << " failures=" << failures << '\n';
  return failures == 0 ? 0 : 1;
}
