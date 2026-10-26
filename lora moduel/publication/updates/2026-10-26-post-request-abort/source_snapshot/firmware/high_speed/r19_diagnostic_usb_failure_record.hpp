#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <type_traits>
#include <HWCDCR19Diagnostic.h>
#include "r19_runtime_stage_record.hpp"

namespace vc_lora::experimental {

inline constexpr std::uint32_t r19_diagnostic_usb_failure_magic = 0x44313955U;
inline constexpr std::uint32_t r19_diagnostic_usb_failure_schema = 1U;
enum class R19DiagnosticUsbWrapperFlag : std::uint32_t {
  ApiCalled=1U, RawReturn=2U, EndpointReady=4U, WithinDeadline=8U,
  CallContextMatches=16U,
};

// This independent diagnostic record does not change the384-byte product
// Heartbeat ABI. Caller clocks are continuous MCU64 microseconds. SDK clocks
// retain their own millis32 semantics and are never substituted for them.
struct R19DiagnosticUsbFailureEvidence {
  std::uint32_t reason{0U}, source_line{0U}, action{0U}, diagnostic_sequence{0U};
  std::uint32_t bootstrap_flags{0U}, expected_epoch{0U}, observed_epoch{0U};
  std::uint32_t budget_ms{0U}, attempt_id{0U}, wrapper_flags{0U};
  std::uint64_t failure_observed_us{0U}, started_us{0U}, finished_us{0U}, deadline_us{0U};
  std::uint32_t expected_frame_bytes{0U}, accepted_frame_bytes{0U};
  R19HwcdcFlushCallEvidence sdk{};
};

struct R19DiagnosticUsbFailureSnapshot final : R19DiagnosticUsbFailureEvidence {
  std::uint32_t sequence{0U}, magic{0U}, schema{0U}, flags{0U};
  R19RuntimeStageRole role{R19RuntimeStageRole::Invalid};
  R19RuntimeBuildFingerprint build_fingerprint{};
  std::array<std::uint32_t,4U> boot_instance{};
  [[nodiscard]] bool valid_header() const noexcept {
    return magic==r19_diagnostic_usb_failure_magic &&
        schema==r19_diagnostic_usb_failure_schema &&
        (role==R19RuntimeStageRole::Ground || role==R19RuntimeStageRole::Vehicle) &&
        (boot_instance[0]|boot_instance[1]|boot_instance[2]|boot_instance[3])!=0U &&
        (flags&1U)!=0U && (flags&~3U)==0U;
  }
  [[nodiscard]] bool failure_latched() const noexcept { return valid_header() && (flags&2U)!=0U; }
  [[nodiscard]] bool api_called() const noexcept { return (wrapper_flags&1U)!=0U; }
  [[nodiscard]] bool sdk_context_matches() const noexcept { return (wrapper_flags&16U)!=0U; }
};

struct R19DiagnosticUsbFailureRecordTestAccess;

// JTAG-only, one application-task writer, no ISR/heap/locks/USB writes.
// The first failure body and its identity are permanently immutable after
// latch. A seqlock prevents an interrupted writer from presenting mixed data.
class alignas(std::uint32_t) R19DiagnosticUsbFailureRecord final {
 public:
  static constexpr std::size_t storage_word_count=64U;
  R19DiagnosticUsbFailureRecord() noexcept=default;
  R19DiagnosticUsbFailureRecord(const R19DiagnosticUsbFailureRecord&)=delete;
  R19DiagnosticUsbFailureRecord& operator=(const R19DiagnosticUsbFailureRecord&)=delete;

  [[nodiscard]] bool initialize(R19RuntimeStageRole role,
      const R19RuntimeBuildFingerprint& build,
      const std::array<std::uint32_t,4U>& boot) noexcept {
    if(words_[2U]!=0U ||
        (role!=R19RuntimeStageRole::Ground && role!=R19RuntimeStageRole::Vehicle) ||
        (boot[0]|boot[1]|boot[2]|boot[3])==0U) return false;
    begin_write();
    for(std::size_t n=2U;n<storage_word_count;++n) words_[n]=0U;
    words_[2U]=r19_diagnostic_usb_failure_magic;
    words_[3U]=r19_diagnostic_usb_failure_schema;
    words_[4U]=static_cast<std::uint32_t>(role);
    for(std::size_t n=0U;n<4U;++n){words_[5U+n]=build[n];words_[9U+n]=boot[n];}
    words_[13U]=1U;
    commit_write();
    return true;
  }

  [[nodiscard]] bool latch_first_failure(const R19DiagnosticUsbFailureEvidence& e) noexcept {
    if(words_[2U]!=r19_diagnostic_usb_failure_magic ||
        words_[3U]!=r19_diagnostic_usb_failure_schema || (words_[13U]&3U)!=1U ||
        !valid_evidence(e)) return false;
    begin_write();
    words_[14U]=e.reason;words_[15U]=e.source_line;words_[16U]=e.action;
    words_[17U]=e.diagnostic_sequence;words_[18U]=e.bootstrap_flags;
    words_[19U]=e.expected_epoch;words_[20U]=e.observed_epoch;
    words_[21U]=e.budget_ms;words_[22U]=e.attempt_id;words_[23U]=e.wrapper_flags;
    write_u64(24U,e.failure_observed_us);write_u64(26U,e.started_us);
    write_u64(28U,e.finished_us);write_u64(30U,e.deadline_us);
    std::array<std::uint32_t,24U> sdk_words{};
    std::memcpy(sdk_words.data(),&e.sdk,sizeof(e.sdk));
    for(std::size_t n=0U;n<sdk_words.size();++n)words_[32U+n]=sdk_words[n];
    words_[56U]=e.expected_frame_bytes;words_[57U]=e.accepted_frame_bytes;
    fence();words_[13U]=3U;commit_write();
    return true;
  }

  [[nodiscard]] bool try_snapshot(R19DiagnosticUsbFailureSnapshot& output,
      std::uint32_t maximum_attempts=8U) const noexcept {
    for(std::uint32_t n=0U;n<maximum_attempts;++n){
      if(words_[0U]!=0U)continue;
      fence();const auto before=words_[1U];if((before&1U)!=0U)continue;
      std::array<std::uint32_t,storage_word_count> raw{};
      for(std::size_t k=0U;k<storage_word_count;++k)raw[k]=words_[k];
      fence();if(words_[0U]!=0U || words_[1U]!=before || (before&1U)!=0U)continue;
      R19DiagnosticUsbFailureSnapshot s{};
      s.sequence=before;s.magic=raw[2U];s.schema=raw[3U];
      s.role=static_cast<R19RuntimeStageRole>(raw[4U]);s.flags=raw[13U];
      for(std::size_t k=0U;k<4U;++k){s.build_fingerprint[k]=raw[5U+k];s.boot_instance[k]=raw[9U+k];}
      s.reason=raw[14U];s.source_line=raw[15U];s.action=raw[16U];
      s.diagnostic_sequence=raw[17U];s.bootstrap_flags=raw[18U];
      s.expected_epoch=raw[19U];s.observed_epoch=raw[20U];s.budget_ms=raw[21U];
      s.attempt_id=raw[22U];s.wrapper_flags=raw[23U];
      s.failure_observed_us=read_u64(raw,24U);s.started_us=read_u64(raw,26U);
      s.finished_us=read_u64(raw,28U);s.deadline_us=read_u64(raw,30U);
      std::memcpy(&s.sdk,raw.data()+32U,sizeof(s.sdk));
      s.expected_frame_bytes=raw[56U];s.accepted_frame_bytes=raw[57U];
      output=s;return true;
    }
    return false;
  }

 private:
  friend struct R19DiagnosticUsbFailureRecordTestAccess;
  static bool valid_evidence(const R19DiagnosticUsbFailureEvidence& e) noexcept {
    const bool called=(e.wrapper_flags&1U)!=0U;
    const bool raw=(e.wrapper_flags&2U)!=0U;
    const bool matches=(e.wrapper_flags&16U)!=0U;
    if(e.reason==0U || e.reason>30U || e.action>3U || e.diagnostic_sequence>255U ||
        (e.bootstrap_flags&~15U)!=0U || (e.wrapper_flags&~31U)!=0U ||
        e.accepted_frame_bytes>e.expected_frame_bytes ||
        e.finished_us<e.started_us || e.failure_observed_us<e.finished_us ||
        (!called && (raw || matches)) ||
        ((e.wrapper_flags&8U)!=0U &&
          (e.deadline_us==0U || e.finished_us>e.deadline_us))) return false;
    std::array<std::uint32_t,24U> sdk{};
    std::memcpy(sdk.data(),&e.sdk,sizeof(e.sdk));
    if(e.sdk.schema!=1U)return false;
    bool absent=true;
    for(std::size_t n=1U;n<sdk.size();++n)absent=absent && sdk[n]==0U;
    if(!called)return absent;
    // No matching call-local SDK value is unknown, not a zero/healthy FIFO.
    if(absent)return !matches;
    if((e.sdk.validity_flags&0x13U)!=0x13U ||
        (e.sdk.validity_flags&~255U)!=0U ||
        e.sdk.terminal_reason==0U || e.sdk.terminal_reason>6U ||
        e.sdk.raw_return>1U ||
        ((e.sdk.terminal_reason==1U)!=(e.sdk.raw_return==1U)))return false;
    if((e.sdk.validity_flags&8U)!=0U){
      if((e.sdk.state_flags&~0x3FFFU)!=0U ||
          (e.sdk.flush_blocker_mask&~0xFFU)!=0U)return false;
    }else{
      if((e.sdk.validity_flags&128U)!=0U)return false;
      for(std::size_t n=12U;n<sdk.size();++n)if(sdk[n]!=0U)return false;
    }
    if(matches && (e.sdk.transaction_token!=e.diagnostic_sequence+1U ||
        e.sdk.attempt_id!=e.attempt_id ||
        e.sdk.expected_loss_epoch!=e.expected_epoch ||
        e.sdk.timeout_ms!=e.budget_ms || e.sdk.raw_return!=(raw?1U:0U)))return false;
    return true;
  }
  static void fence() noexcept {std::atomic_signal_fence(std::memory_order_seq_cst);}
  void begin_write() noexcept {words_[0U]=1U;fence();words_[1U]=(words_[1U]&~1U)+1U;fence();}
  void commit_write() noexcept {fence();words_[1U]=(words_[1U]|1U)+1U;fence();words_[0U]=0U;}
  void write_u64(std::size_t n,std::uint64_t value) noexcept {
    words_[n]=static_cast<std::uint32_t>(value);words_[n+1U]=static_cast<std::uint32_t>(value>>32U);
  }
  static std::uint64_t read_u64(const std::array<std::uint32_t,storage_word_count>& w,
      std::size_t n) noexcept {return w[n]|(static_cast<std::uint64_t>(w[n+1U])<<32U);}
  // words0 writer,1 sequence,2 magic,3 schema,4 role,5..8 build,9..12 boot,
  //13 initialized/latched,14 reason,15 source,16 action,17 wire diagnostic seq,
  //18 bootstrap flags,19 expected epoch,20 observed epoch,21 budget,22 attempt,
  //23 wrapper flags,24..25 failure MCUus,26..27 start,28..29 return,30..31 deadline,
  //32..55 SDK96-byte POD,56 expected frame bytes,57 accepted bytes,58..63 zero.
  volatile std::uint32_t words_[storage_word_count]{};
};
static_assert(sizeof(R19HwcdcFlushCallEvidence)==96U);
static_assert(std::is_trivially_copyable_v<R19HwcdcFlushCallEvidence>);
static_assert(sizeof(R19DiagnosticUsbFailureRecord)==256U);
static_assert(alignof(R19DiagnosticUsbFailureRecord)==4U);
static_assert(std::is_standard_layout_v<R19DiagnosticUsbFailureRecord>);
} // namespace vc_lora::experimental
