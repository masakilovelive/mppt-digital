#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <type_traits>
#include <HWCDCR19Diagnostic.h>
#include "r19_runtime_stage_record.hpp"

namespace vc_lora::experimental {

inline constexpr std::uint32_t r19_first_usb_failure_magic = 0x52313955U;
inline constexpr std::uint32_t r19_first_usb_failure_schema = 1U;
using R19BootInstance = std::array<std::uint32_t, 4U>;
enum class R19FirstUsbFailureReason : std::uint32_t {
  None = 0U, PublicationRejected = 1U, BeforeFlushDeadline = 2U,
  EmitStateRejected = 3U, OtherRejected = 4U,
};
enum class R19FirstUsbWrapperFlag : std::uint32_t {
  ApiCalled = 1U, RawReturn = 2U, EndpointReady = 4U, WithinDeadline = 8U,
};

// All wrapper clocks are esp_timer_get_time microseconds in the same boot.
// The nested SDK clocks are uint32 millis/micros observations, not PC clocks.
struct R19FirstUsbFailureEvidence {
  std::uint32_t reason{0U}, source_line{0U}, token{0U}, attempt_id{0U};
  std::uint32_t wrapper_flags{0U}, budget_ms{0U}, expected_epoch{0U}, observed_epoch{0U};
  std::uint64_t started_us{0U}, finished_us{0U}, deadline_us{0U};
  std::uint64_t failure_observed_us{0U};
  std::uint32_t expected_frame_bytes{0U}, accepted_frame_bytes{0U};
  R19HwcdcFlushCallEvidence sdk{};
};
struct R19FirstUsbFailureSnapshot final : R19FirstUsbFailureEvidence {
  std::uint32_t sequence{0U}, magic{0U}, schema{0U};
  R19RuntimeStageRole role{R19RuntimeStageRole::Invalid};
  R19RuntimeBuildFingerprint build_fingerprint{};
  R19BootInstance boot_instance{};
  std::uint32_t flags{0U}, sync_count{0U};
  std::uint64_t last_sync_nonce{0U}, last_sync_device_us{0U};
  [[nodiscard]] bool valid_header() const noexcept {
    return magic == r19_first_usb_failure_magic && schema == r19_first_usb_failure_schema &&
      (role == R19RuntimeStageRole::Ground || role == R19RuntimeStageRole::Vehicle) &&
      (boot_instance[0] | boot_instance[1] | boot_instance[2] | boot_instance[3]) != 0U && (flags & 1U) != 0U;
  }
  [[nodiscard]] bool failure_latched() const noexcept { return valid_header() && (flags & 2U) != 0U; }
  [[nodiscard]] bool api_called() const noexcept { return (wrapper_flags & 1U) != 0U; }
};
struct R19FirstUsbFailureRecordTestAccess;

// A separate JTAG-only ABI; the old 68/112/128/128-byte records do not change.
// Exactly one application task may mutate this record, never an ISR. The SDK
// supplies a by-value transaction snapshot; this record never acquires its lock.
// First evidence words 20..61 are immutable after latch. Only clock-sync words
// change afterwards, under the same seqlock, retaining boot/fingerprint identity.
class alignas(std::uint32_t) R19FirstUsbFailureRecord final {
 public:
  static constexpr std::size_t storage_word_count = 96U;
  R19FirstUsbFailureRecord() noexcept = default;
  R19FirstUsbFailureRecord(const R19FirstUsbFailureRecord&) = delete;
  R19FirstUsbFailureRecord& operator=(const R19FirstUsbFailureRecord&) = delete;

  [[nodiscard]] bool initialize(R19RuntimeStageRole role, const R19RuntimeBuildFingerprint& fingerprint,
                                const R19BootInstance& boot) noexcept {
    if (words_[2U] != 0U || (role != R19RuntimeStageRole::Ground && role != R19RuntimeStageRole::Vehicle) ||
        (boot[0] | boot[1] | boot[2] | boot[3]) == 0U) return false;
    begin_write();
    for (std::size_t n = 2U; n < storage_word_count; ++n) words_[n] = 0U;
    words_[2U] = r19_first_usb_failure_magic; words_[3U] = r19_first_usb_failure_schema;
    words_[4U] = static_cast<std::uint32_t>(role);
    for (std::size_t n = 0U; n < 4U; ++n) { words_[5U+n] = fingerprint[n]; words_[9U+n] = boot[n]; }
    words_[13U] = 1U;
    commit_write(); return true;
  }

  [[nodiscard]] bool latch_first_failure(const R19FirstUsbFailureEvidence& e) noexcept {
    if (!initialized() || words_[4U] != static_cast<std::uint32_t>(R19RuntimeStageRole::Ground) ||
        (words_[13U] & 2U) != 0U || e.reason == 0U || e.reason > 4U ||
        (e.wrapper_flags & ~15U) != 0U || e.accepted_frame_bytes > e.expected_frame_bytes ||
        e.finished_us < e.started_us || e.failure_observed_us < e.finished_us ||
        ((e.wrapper_flags & 2U) != 0U && (e.wrapper_flags & 1U) == 0U)) return false;
    if ((e.wrapper_flags & 1U) != 0U && (e.sdk.schema != 1U || e.sdk.transaction_token != e.token ||
        e.sdk.attempt_id != e.attempt_id || (e.sdk.validity_flags & 0x13U) != 0x13U ||
        (e.sdk.validity_flags & ~255U) != 0U || e.sdk.terminal_reason == 0U || e.sdk.terminal_reason > 6U ||
        e.sdk.raw_return > 1U || e.sdk.raw_return != ((e.wrapper_flags >> 1U) & 1U) ||
        ((e.sdk.terminal_reason == 1U) != (e.sdk.raw_return == 1U)))) return false;
    if ((e.wrapper_flags & 1U) != 0U) {
      if ((e.sdk.validity_flags & 8U) != 0U) {
        if ((e.sdk.state_flags & ~0x3FFFU) != 0U || (e.sdk.flush_blocker_mask & ~0xFFU) != 0U) return false;
      } else {
        // An absent terminal snapshot must not masquerade as a zero/healthy
        // FIFO observation. Its raw snapshot payload is required to be absent.
        if ((e.sdk.validity_flags & 128U) != 0U) return false;
        std::array<std::uint32_t,24U> raw_sdk{};
        std::memcpy(raw_sdk.data(), &e.sdk, sizeof(e.sdk));
        for (std::size_t n=12U;n<raw_sdk.size();++n) if (raw_sdk[n] != 0U) return false;
      }
    }
    if ((e.wrapper_flags & 1U) == 0U) {
      std::array<std::uint32_t,24U> raw_sdk{};
      std::memcpy(raw_sdk.data(), &e.sdk, sizeof(e.sdk));
      if (raw_sdk[0U] != 1U) return false;
      for (std::size_t n=1U;n<raw_sdk.size();++n) if (raw_sdk[n] != 0U) return false;
    }
    begin_write();
    words_[20U] = e.reason; words_[21U] = e.source_line; words_[22U] = e.token; words_[23U] = e.attempt_id;
    words_[24U] = e.wrapper_flags; words_[25U] = e.budget_ms; words_[26U] = e.expected_epoch; words_[27U] = e.observed_epoch;
    write_u64(28U,e.started_us); write_u64(30U,e.finished_us); write_u64(32U,e.deadline_us);
    words_[34U] = e.expected_frame_bytes; words_[35U] = e.accepted_frame_bytes;
    std::array<std::uint32_t,24U> sdk_words{};
    std::memcpy(sdk_words.data(), &e.sdk, sizeof(e.sdk));
    for (std::size_t n = 0U; n < sdk_words.size(); ++n) words_[36U+n] = sdk_words[n];
    write_u64(60U,e.failure_observed_us);
    fence(); words_[13U] |= 2U; commit_write(); return true;
  }

  [[nodiscard]] bool observe_clock_sync(std::uint64_t nonce, std::uint64_t device_us) noexcept {
    if (!initialized() || (nonce >> 48U) != 0x5219U || (nonce & 0x0000FFFFFFFFFFFFULL) == 0U) return false;
    begin_write(); write_u64(16U,nonce); write_u64(18U,device_us);
    if (words_[14U] != std::numeric_limits<std::uint32_t>::max()) ++words_[14U];
    words_[13U] |= 4U; commit_write(); return true;
  }

  [[nodiscard]] bool try_snapshot(R19FirstUsbFailureSnapshot& out, std::uint32_t attempts = 8U) const noexcept {
    for (std::uint32_t n = 0U; n < attempts; ++n) {
      if (words_[0U] != 0U) continue;
      fence(); const auto before = words_[1U]; if ((before & 1U) != 0U) continue;
      std::array<std::uint32_t,storage_word_count> raw{};
      for (std::size_t k = 0U; k < storage_word_count; ++k) raw[k] = words_[k];
      fence(); if (words_[0U] != 0U || before != words_[1U] || (words_[1U] & 1U) != 0U) continue;
      R19FirstUsbFailureSnapshot s{};
      s.sequence=before; s.magic=raw[2]; s.schema=raw[3]; s.role=static_cast<R19RuntimeStageRole>(raw[4]);
      for (std::size_t k=0U;k<4U;++k) {s.build_fingerprint[k]=raw[5+k]; s.boot_instance[k]=raw[9+k];}
      s.flags=raw[13]; s.sync_count=raw[14]; s.last_sync_nonce=read_u64(raw,16U);s.last_sync_device_us=read_u64(raw,18U);
      s.reason=raw[20];s.source_line=raw[21];s.token=raw[22];s.attempt_id=raw[23];s.wrapper_flags=raw[24];
      s.budget_ms=raw[25];s.expected_epoch=raw[26];s.observed_epoch=raw[27];s.started_us=read_u64(raw,28U);
      s.finished_us=read_u64(raw,30U);s.deadline_us=read_u64(raw,32U);s.expected_frame_bytes=raw[34];s.accepted_frame_bytes=raw[35];
      std::memcpy(&s.sdk,raw.data()+36U,sizeof(s.sdk));s.failure_observed_us=read_u64(raw,60U);out=s;return true;
    }
    return false;
  }
 private:
  friend struct R19FirstUsbFailureRecordTestAccess;
  static void fence() noexcept { std::atomic_signal_fence(std::memory_order_seq_cst); }
  [[nodiscard]] bool initialized() const noexcept { return words_[2U]==r19_first_usb_failure_magic && words_[3U]==r19_first_usb_failure_schema; }
  void begin_write() noexcept {words_[0U]=1U;fence();words_[1U]=(words_[1U]&~1U)+1U;fence();}
  void commit_write() noexcept {fence();words_[1U]=(words_[1U]|1U)+1U;fence();words_[0U]=0U;}
  void write_u64(std::size_t n,std::uint64_t value) noexcept {words_[n]=static_cast<std::uint32_t>(value);words_[n+1U]=static_cast<std::uint32_t>(value>>32U);}
  static std::uint64_t read_u64(const std::array<std::uint32_t,storage_word_count>& w,std::size_t n) noexcept {return w[n]|(static_cast<std::uint64_t>(w[n+1U])<<32U);}
  // Word ABI: 0 writer, 1 sequence, 2 magic, 3 schema, 4 role, 5..8 build,
  // 9..12 boot, 13 flags (initialized/first/sync), 14 sync count, 15 reserved,
  // 16..17 nonce, 18..19 sync time, 20 reason, 21 source, 22 token, 23 attempt,
  // 24 wrapper flags, 25 budget, 26 expected epoch, 27 observed epoch,
  // 28..29 start us, 30..31 return us, 32..33 deadline us, 34 frame size,
  // 35 accepted size, 36..59 SDK POD, 60..61 failure-observed us, 62..95 zero.
  // U64 values are explicitly low/high; serialization assumes target little endian.
  volatile std::uint32_t words_[storage_word_count]{};
};
static_assert(sizeof(R19HwcdcFlushCallEvidence)==96U);
static_assert(std::is_trivially_copyable_v<R19HwcdcFlushCallEvidence>);
static_assert(sizeof(R19FirstUsbFailureRecord)==384U);
static_assert(std::is_standard_layout_v<R19FirstUsbFailureRecord>);
static_assert(alignof(R19FirstUsbFailureRecord)==4U);
} // namespace vc_lora::experimental
