#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <type_traits>
#include "r19_runtime_stage_record.hpp"
#include "high_speed_phase6_adapter.hpp"

namespace vc_lora::experimental {

inline constexpr std::uint32_t r19_grant_diagnostic_magic=0x52313947U;
inline constexpr std::uint32_t r19_grant_diagnostic_schema=1U;
enum class R19GrantDiagnosticEvent : std::uint32_t {
  None=0U,Other=1U,ObserveStandardGrant=2U,ParameterRequest=3U,
  FreshGrant=4U,Tick=5U,GrantGenerated=6U,GrantWriteAccepted=7U,
  GrantPhysicalTail=8U,GrantReceivedRaw=9U,
};
// These values copy the adapter diagnostic enums, never a wire protocol.
// The record is independent of the adapter so neither transport nor policy
// depends on whether this diagnostic-only JTAG record is compiled in.
struct R19GrantDiagnosticEvidence final {
  std::uint32_t event{0U},validity_flags{0U};
  std::uint32_t owner_state_before{0U},owner_state_after{0U};
  std::uint32_t coordinator_state_before{0U},coordinator_state_after{0U};
  std::uint32_t owner_result{0U},owner_last_error{0U};
  std::uint32_t coordinator_result{0U},coordinator_last_error{0U};
  std::uint32_t adapter_status{0U},adapter_failure_reason{0U};
  std::uint64_t observed_ms{0U},request_origin_ms{0U};
  std::uint64_t await_fresh_grant_started_ms{0U},standard_grant_observed_ms{0U};
  std::uint64_t fresh_grant_observed_ms{0U},coordinator_grant_staged_ms{0U};
  std::uint32_t standard_grant_session{0U},standard_grant_cycle{0U};
  std::uint32_t fresh_grant_session{0U},fresh_grant_cycle{0U},source_line{0U};
  std::uint32_t action_token{0U},generation{0U},disposition{0U};
};
[[nodiscard]] inline R19GrantDiagnosticEvidence make_r19_grant_diagnostic_evidence(
    const GroundHighSpeedPhase6DiagnosticSnapshot& s,std::uint32_t source_line)noexcept {
  R19GrantDiagnosticEvidence e{};e.event=static_cast<std::uint32_t>(s.event);
  e.validity_flags=(s.owner_result_valid?1U:0U)|(s.coordinator_result_valid?2U:0U)|
    (s.request_origin_valid?4U:0U)|(s.await_fresh_grant_started_valid?8U:0U)|
    (s.standard_grant_observed_valid?16U:0U)|(s.fresh_grant_observed_valid?32U:0U)|
    (s.coordinator_grant_staged_valid?64U:0U);
  e.owner_state_before=static_cast<std::uint32_t>(s.owner_state_before);e.owner_state_after=static_cast<std::uint32_t>(s.owner_state_after);
  e.coordinator_state_before=static_cast<std::uint32_t>(s.coordinator_state_before);e.coordinator_state_after=static_cast<std::uint32_t>(s.coordinator_state_after);
  e.owner_result=static_cast<std::uint32_t>(s.owner_result);e.owner_last_error=static_cast<std::uint32_t>(s.owner_last_error);
  e.coordinator_result=static_cast<std::uint32_t>(s.coordinator_result);e.coordinator_last_error=static_cast<std::uint32_t>(s.coordinator_last_error);
  e.adapter_status=static_cast<std::uint32_t>(s.adapter_status);e.adapter_failure_reason=static_cast<std::uint32_t>(s.adapter_failure_reason);
  e.observed_ms=s.observed_ms;e.request_origin_ms=s.request_origin_ms;e.await_fresh_grant_started_ms=s.await_fresh_grant_started_ms;
  e.standard_grant_observed_ms=s.standard_grant_observed_ms;e.fresh_grant_observed_ms=s.fresh_grant_observed_ms;e.coordinator_grant_staged_ms=s.coordinator_grant_staged_ms;
  e.standard_grant_session=s.standard_grant_session;e.standard_grant_cycle=s.standard_grant_cycle;
  e.fresh_grant_session=s.fresh_grant_session;e.fresh_grant_cycle=s.fresh_grant_cycle;e.source_line=source_line;return e;
}
// validity_flags: owner_result1, coordinator_result2, request_origin4,
// AwaitFreshGrant entry8, standard Grant16, fresh Grant32, Grant staged64.
// A missing flag is unavailable; its associated clock/identity/result is zero.
struct R19GrantDiagnosticJournalEntry final {
  std::uint32_t ordinal{0U},event{0U},flags{0U};
  std::uint64_t observed_ms{0U};
  std::uint32_t owner_state_before{0U},owner_state_after{0U};
  std::uint32_t coordinator_state_before{0U},coordinator_state_after{0U};
  std::uint32_t owner_result{0U},owner_last_error{0U};
  std::uint32_t coordinator_result{0U},coordinator_last_error{0U};
  std::uint32_t adapter_status{0U},adapter_failure_reason{0U},source_line{0U};
  std::uint32_t session{0U},cycle{0U},action_token{0U},generation{0U},disposition{0U};
};
struct R19GrantDiagnosticSnapshot final {
  std::uint32_t sequence{0U},magic{0U},schema{0U},flags{0U},size_bytes{0U};
  R19RuntimeStageRole role{R19RuntimeStageRole::Invalid};
  R19RuntimeBuildFingerprint build_fingerprint{};
  std::array<std::uint32_t,4U> boot_instance{};
  R19GrantDiagnosticEvidence latest{},first_failure{};
  std::uint32_t observation_count{0U},journal_count{0U},journal_next{0U};
  std::uint32_t journal_dropped{0U},first_failure_ordinal{0U};
  std::array<R19GrantDiagnosticJournalEntry,10U> journal{};
  [[nodiscard]] bool valid_header()const noexcept {
    return magic==r19_grant_diagnostic_magic && schema==r19_grant_diagnostic_schema &&
        size_bytes==1024U && (flags&1U)!=0U && (flags&~7U)==0U &&
        (flags&4U)==0U &&
        (role==R19RuntimeStageRole::Ground || role==R19RuntimeStageRole::Vehicle) &&
        (boot_instance[0]|boot_instance[1]|boot_instance[2]|boot_instance[3])!=0U;
  }
  [[nodiscard]] bool failure_latched()const noexcept{return valid_header()&&(flags&2U)!=0U;}
};
struct R19GrantDiagnosticRecordTestAccess;

// One application-task writer. No ISR, heap, locks, USB, UART, or RF writes.
// First six and last four meaningful transitions are retained, with explicit
// dropped count. This preserves early Vehicle Grant events after a later fault.
// Unchanged Tick observations update latest but do not displace transitions.
// The complete record freezes on first failure, including the pre-failure
// journal. Counter exhaustion is visible and cannot be decoded as healthy.
class alignas(std::uint32_t) R19GrantDiagnosticRecord final {
 public:
  static constexpr std::size_t storage_word_count=256U;
  R19GrantDiagnosticRecord()noexcept=default;
  R19GrantDiagnosticRecord(const R19GrantDiagnosticRecord&)=delete;
  R19GrantDiagnosticRecord& operator=(const R19GrantDiagnosticRecord&)=delete;
  [[nodiscard]] bool initialize(R19RuntimeStageRole role,
      const R19RuntimeBuildFingerprint& build,
      const std::array<std::uint32_t,4U>& boot)noexcept {
    if(words_[2U]!=0U ||
        (role!=R19RuntimeStageRole::Ground&&role!=R19RuntimeStageRole::Vehicle) ||
        (boot[0]|boot[1]|boot[2]|boot[3])==0U)return false;
    begin_write();
    for(std::size_t n=2U;n<storage_word_count;++n)words_[n]=0U;
    words_[2U]=r19_grant_diagnostic_magic;words_[3U]=r19_grant_diagnostic_schema;
    words_[4U]=static_cast<std::uint32_t>(role);
    for(std::size_t n=0U;n<4U;++n){words_[5U+n]=build[n];words_[9U+n]=boot[n];}
    words_[13U]=1U;words_[14U]=1024U;commit_write();return true;
  }
  [[nodiscard]] bool observe(const R19GrantDiagnosticEvidence& e,bool failure=false)noexcept {
    if(words_[2U]!=r19_grant_diagnostic_magic || words_[3U]!=1U ||
        words_[13U]!=1U || !valid_evidence(e))return false;
    if(words_[80U]==std::numeric_limits<std::uint32_t>::max()){
      begin_write();words_[13U]|=4U;commit_write();return false;
    }
    const auto body=encode(e);
    bool journal=words_[80U]==0U || e.event!=5U || failure;
    // Only state/result/availability changes make Tick meaningful. A new
    // timestamp alone does not hide the request and Grant transition history.
    for(std::size_t n=1U;n<=11U;++n)journal=journal||words_[16U+n]!=body[n];
    begin_write();++words_[80U];
    for(std::size_t n=0U;n<32U;++n)words_[16U+n]=body[n];
    if(journal){
      const auto offset=96U+static_cast<std::size_t>(words_[82U])*16U;
      words_[offset]=words_[80U];words_[offset+1U]=e.event;
      words_[offset+2U]=(e.validity_flags<<1U)|(failure?1U:0U);
      write_u64(offset+3U,e.observed_ms);
      if(e.event<=5U){for(std::size_t n=0U;n<10U;++n)words_[offset+5U+n]=body[2U+n];}
      else{
        words_[offset+5U]=e.standard_grant_session;words_[offset+6U]=e.standard_grant_cycle;
        words_[offset+7U]=e.action_token;words_[offset+8U]=e.generation;words_[offset+9U]=e.disposition;
        for(std::size_t n=10U;n<15U;++n)words_[offset+n]=0U;
      }
      words_[offset+15U]=e.source_line;
      if(words_[81U]<10U)++words_[81U];else ++words_[83U];
      words_[82U]=words_[82U]<6U?words_[82U]+1U:6U+(words_[82U]-6U+1U)%4U;
    }
    if(failure){
      for(std::size_t n=0U;n<32U;++n)words_[48U+n]=body[n];
      words_[84U]=words_[80U];words_[13U]|=2U;
    }
    commit_write();return true;
  }
  [[nodiscard]] bool observe_grant_event(R19GrantDiagnosticEvent kind,
      std::uint64_t observed_ms,std::uint16_t session,std::uint16_t cycle,
      std::uint32_t token,std::uint32_t generation,std::uint32_t source_line,
      std::uint32_t disposition=0U)noexcept {
    const auto event=static_cast<std::uint32_t>(kind);if(event<6U||event>9U)return false;
    R19GrantDiagnosticEvidence e{};e.event=event;e.validity_flags=16U;
    e.observed_ms=observed_ms;e.standard_grant_observed_ms=observed_ms;
    e.standard_grant_session=session;e.standard_grant_cycle=cycle;e.action_token=token;
    e.generation=generation;e.source_line=source_line;e.disposition=disposition;return observe(e);
  }
  [[nodiscard]] bool try_snapshot(R19GrantDiagnosticSnapshot& output,
      std::uint32_t maximum_attempts=8U)const noexcept {
    for(std::uint32_t attempt=0U;attempt<maximum_attempts;++attempt){
      if(words_[0U]!=0U)continue;
      fence();const auto before=words_[1U];if((before&1U)!=0U)continue;
      std::array<std::uint32_t,storage_word_count> w{};
      for(std::size_t n=0U;n<storage_word_count;++n)w[n]=words_[n];
      fence();if(words_[0U]!=0U||words_[1U]!=before||(before&1U)!=0U)continue;
      R19GrantDiagnosticSnapshot s{};s.sequence=before;s.magic=w[2U];s.schema=w[3U];
      s.role=static_cast<R19RuntimeStageRole>(w[4U]);s.flags=w[13U];s.size_bytes=w[14U];
      for(std::size_t n=0U;n<4U;++n){s.build_fingerprint[n]=w[5U+n];s.boot_instance[n]=w[9U+n];}
      s.latest=decode(w.data()+16U);s.first_failure=decode(w.data()+48U);
      s.observation_count=w[80U];s.journal_count=w[81U];s.journal_next=w[82U];
      s.journal_dropped=w[83U];s.first_failure_ordinal=w[84U];
      if(s.journal_count<=10U && s.journal_next<10U){
        for(std::size_t n=0U;n<s.journal_count;++n){
          const auto slot=s.journal_count<10U||n<6U?n:6U+(s.journal_next-6U+n-6U)%4U;
          const auto offset=96U+slot*16U;auto& j=s.journal[n];
          j.ordinal=w[offset];j.event=w[offset+1U];j.flags=w[offset+2U];j.observed_ms=read_u64(w.data(),offset+3U);
          if(j.event<=5U){
            j.owner_state_before=w[offset+5U];j.owner_state_after=w[offset+6U];
            j.coordinator_state_before=w[offset+7U];j.coordinator_state_after=w[offset+8U];
            j.owner_result=w[offset+9U];j.owner_last_error=w[offset+10U];
            j.coordinator_result=w[offset+11U];j.coordinator_last_error=w[offset+12U];
            j.adapter_status=w[offset+13U];j.adapter_failure_reason=w[offset+14U];
          }else{
            j.session=w[offset+5U];j.cycle=w[offset+6U];j.action_token=w[offset+7U];
            j.generation=w[offset+8U];j.disposition=w[offset+9U];
          }
          j.source_line=w[offset+15U];
        }
      }
      output=s;return true;
    }
    return false;
  }
 private:
  friend struct R19GrantDiagnosticRecordTestAccess;
  static bool valid_evidence(const R19GrantDiagnosticEvidence& e)noexcept {
    if(e.event>9U || (e.validity_flags&~127U)!=0U ||
        e.owner_state_before>9U || e.owner_state_after>9U ||
        e.coordinator_state_before>14U || e.coordinator_state_after>14U ||
        e.owner_result>41U || e.owner_last_error>41U ||
        e.coordinator_result>21U || e.coordinator_last_error>21U ||
        e.adapter_status>26U || e.adapter_failure_reason>26U ||
        e.standard_grant_session>65535U || e.standard_grant_cycle>65535U ||
        e.fresh_grant_session>65535U || e.fresh_grant_cycle>65535U ||e.disposition>255U)return false;
    if(e.event<=5U && (e.action_token!=0U||e.generation!=0U||e.disposition!=0U))return false;
    if(e.event>=6U && (e.validity_flags!=16U || e.owner_state_before!=0U||e.owner_state_after!=0U||
        e.coordinator_state_before!=0U||e.coordinator_state_after!=0U||e.owner_result!=0U||e.owner_last_error!=0U||
        e.coordinator_result!=0U||e.coordinator_last_error!=0U||e.adapter_status!=0U||e.adapter_failure_reason!=0U||
        e.standard_grant_observed_ms!=e.observed_ms))return false;
    if((e.validity_flags&1U)==0U && e.owner_result!=0U)return false;
    if((e.validity_flags&2U)==0U && e.coordinator_result!=0U)return false;
    if((e.validity_flags&4U)==0U && e.request_origin_ms!=0U)return false;
    if((e.validity_flags&8U)==0U && e.await_fresh_grant_started_ms!=0U)return false;
    if((e.validity_flags&16U)==0U && (e.standard_grant_observed_ms!=0U||e.standard_grant_session!=0U||e.standard_grant_cycle!=0U))return false;
    if((e.validity_flags&32U)==0U && (e.fresh_grant_observed_ms!=0U||e.fresh_grant_session!=0U||e.fresh_grant_cycle!=0U))return false;
    if((e.validity_flags&64U)==0U && e.coordinator_grant_staged_ms!=0U)return false;
    return true;
  }
  static std::array<std::uint32_t,32U> encode(const R19GrantDiagnosticEvidence& e)noexcept {
    std::array<std::uint32_t,32U> w{e.event,e.validity_flags,e.owner_state_before,e.owner_state_after,
      e.coordinator_state_before,e.coordinator_state_after,e.owner_result,e.owner_last_error,
      e.coordinator_result,e.coordinator_last_error,e.adapter_status,e.adapter_failure_reason};
    const std::array<std::uint64_t,6U> times{e.observed_ms,e.request_origin_ms,e.await_fresh_grant_started_ms,
      e.standard_grant_observed_ms,e.fresh_grant_observed_ms,e.coordinator_grant_staged_ms};
    for(std::size_t n=0U;n<times.size();++n){w[12U+n*2U]=static_cast<std::uint32_t>(times[n]);w[13U+n*2U]=static_cast<std::uint32_t>(times[n]>>32U);}
    w[24U]=e.standard_grant_session;w[25U]=e.standard_grant_cycle;
    w[26U]=e.fresh_grant_session;w[27U]=e.fresh_grant_cycle;w[28U]=e.source_line;
    w[29U]=e.action_token;w[30U]=e.generation;w[31U]=e.disposition;return w;
  }
  static R19GrantDiagnosticEvidence decode(const std::uint32_t* w)noexcept {
    R19GrantDiagnosticEvidence e{};e.event=w[0U];e.validity_flags=w[1U];
    e.owner_state_before=w[2U];e.owner_state_after=w[3U];e.coordinator_state_before=w[4U];e.coordinator_state_after=w[5U];
    e.owner_result=w[6U];e.owner_last_error=w[7U];e.coordinator_result=w[8U];e.coordinator_last_error=w[9U];
    e.adapter_status=w[10U];e.adapter_failure_reason=w[11U];e.observed_ms=read_u64(w,12U);
    e.request_origin_ms=read_u64(w,14U);e.await_fresh_grant_started_ms=read_u64(w,16U);
    e.standard_grant_observed_ms=read_u64(w,18U);e.fresh_grant_observed_ms=read_u64(w,20U);e.coordinator_grant_staged_ms=read_u64(w,22U);
    e.standard_grant_session=w[24U];e.standard_grant_cycle=w[25U];e.fresh_grant_session=w[26U];e.fresh_grant_cycle=w[27U];e.source_line=w[28U];
    e.action_token=w[29U];e.generation=w[30U];e.disposition=w[31U];return e;
  }
  static std::uint64_t read_u64(const std::uint32_t* w,std::size_t n)noexcept{return w[n]|(static_cast<std::uint64_t>(w[n+1U])<<32U);}
  void write_u64(std::size_t n,std::uint64_t value)noexcept{words_[n]=static_cast<std::uint32_t>(value);words_[n+1U]=static_cast<std::uint32_t>(value>>32U);}
  static void fence()noexcept{std::atomic_signal_fence(std::memory_order_seq_cst);}
  void begin_write()noexcept{words_[0U]=1U;fence();words_[1U]=(words_[1U]&~1U)+1U;fence();}
  void commit_write()noexcept{fence();words_[1U]=(words_[1U]|1U)+1U;fence();words_[0U]=0U;}
  // 0 writer,1 sequence,2 magic,3 schema,4 role,5..8 build,9..12 boot,
  // 13 initialized/failure/counter-overflow,14 bytes=1024,15 reserved,
  // 16..47 latest,48..79 first-failure,80 observation-count,81 journal-count,
  // 82 journal-next,83 journal-dropped,84 first-failure-ordinal,85..95 zero,
  // 96..255 ten16-word event summaries (first6+last4). Evidence word29..31:
  // action_token/generation/disposition only for explicit Grant wire events.
  volatile std::uint32_t words_[storage_word_count]{};
};
static_assert(sizeof(R19GrantDiagnosticRecord)==1024U);
static_assert(alignof(R19GrantDiagnosticRecord)==4U);
static_assert(std::is_standard_layout_v<R19GrantDiagnosticRecord>);
static_assert(std::is_trivially_copyable_v<R19GrantDiagnosticEvidence>);
static_assert(static_cast<std::uint32_t>(GroundHighSpeedDiagnosticEvent::Tick)==5U);
static_assert(static_cast<std::uint32_t>(GroundBulkSessionState::FailClosed)==9U);
static_assert(static_cast<std::uint32_t>(GroundHighSpeedTddState::FailClosed)==14U);
static_assert(static_cast<std::uint32_t>(BulkSessionResult::Latched)==41U);
static_assert(static_cast<std::uint32_t>(HighSpeedCoordinatorResult::Latched)==21U);
static_assert(static_cast<std::uint32_t>(HighSpeedPhase6AdapterStatus::FailClosed)==26U);
} // namespace vc_lora::experimental
