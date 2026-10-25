#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <type_traits>
#include "r19_runtime_stage_record.hpp"

#ifndef VC_LORA_R19_AUX_READINESS_DIAGNOSTICS
#define VC_LORA_R19_AUX_READINESS_DIAGNOSTICS 0
#endif

#if defined(__GNUC__) || defined(__clang__)
#define VC_LORA_R19_AUX_ALWAYS_INLINE inline __attribute__((always_inline))
#else
#define VC_LORA_R19_AUX_ALWAYS_INLINE inline
#endif

namespace vc_lora::experimental {
inline constexpr std::uint32_t r19_aux_observation_magic=0x5231414FU;
inline constexpr std::uint32_t r19_aux_edge_magic=0x52314145U;
inline constexpr std::uint32_t r19_usb_readiness_magic=0x52315552U;
inline constexpr std::uint32_t r19_aux_readiness_schema=1U;
inline constexpr std::uint32_t r19_aux_initialized=1U;
inline constexpr std::uint32_t r19_aux_clock_regression=2U;
inline constexpr std::uint32_t r19_aux_counter_saturated=4U;
inline constexpr std::uint32_t r19_aux_history_coverage_lost=8U;
inline constexpr std::uint32_t r19_aux_invalid_input=16U;
inline constexpr std::uint32_t r19_aux_sequence_wrapped=32U;
inline constexpr std::uint32_t r19_aux_edge_overflow=64U;

enum class R19UsbReadinessEvent : std::uint32_t {
  ClockFlushBegin=1U,ClockFlushEnd=2U,GateUpdate=3U,ReadyEncode=4U,
  ReadyPublishBegin=5U,ReadyPublishEnd=6U,ArmReceived=7U,ArmAccepted=8U,
  IrqAttach=9U,GateReset=10U,ReadySuppressed=11U,ClockFlushContext=12U,
};
enum class R19UsbIntervalKind : std::uint32_t {
  PrivateReply=0U,RuntimeDiagnostic=1U,AliveDrain=2U,Loop=3U,
};
using R19ReadinessEvent=R19UsbReadinessEvent;
using R19ObservationInterval=R19UsbIntervalKind;

namespace r19_aux_detail {
using Snapshot=std::array<std::uint32_t,512U>;
// Compiler ordering only. Each section has one writer; the ISR never writes
// main-task sections. JTAG readers must require two identical coherent reads.
VC_LORA_R19_AUX_ALWAYS_INLINE void fence() noexcept {std::atomic_signal_fence(std::memory_order_seq_cst);}
VC_LORA_R19_AUX_ALWAYS_INLINE std::uint64_t read64(const volatile std::uint32_t* w,std::size_t n) noexcept {
  return w[n]|(static_cast<std::uint64_t>(w[n+1U])<<32U);
}
VC_LORA_R19_AUX_ALWAYS_INLINE void write64(volatile std::uint32_t* w,std::size_t n,std::uint64_t v) noexcept {
  w[n]=static_cast<std::uint32_t>(v);w[n+1U]=static_cast<std::uint32_t>(v>>32U);
}
VC_LORA_R19_AUX_ALWAYS_INLINE void begin(volatile std::uint32_t* w) noexcept {
  w[0U]=1U;fence();if(w[1U]>=0xFFFFFFFEU)w[13U]|=r19_aux_sequence_wrapped;
  w[1U]=(w[1U]&~1U)+1U;fence();
}
VC_LORA_R19_AUX_ALWAYS_INLINE void commit(volatile std::uint32_t* w) noexcept {
  fence();w[1U]=(w[1U]|1U)+1U;fence();w[0U]=0U;
}
VC_LORA_R19_AUX_ALWAYS_INLINE void increment(volatile std::uint32_t* w,std::size_t n) noexcept {
  if(w[n]==std::numeric_limits<std::uint32_t>::max())w[13U]|=r19_aux_counter_saturated;
  else ++w[n];
}
VC_LORA_R19_AUX_ALWAYS_INLINE bool header(const volatile std::uint32_t* w,std::uint32_t magic) noexcept {
  return w[2U]==magic&&w[3U]==1U&&(w[13U]&r19_aux_initialized)!=0U;
}
VC_LORA_R19_AUX_ALWAYS_INLINE void taint(volatile std::uint32_t* w,std::uint32_t bit) noexcept {
  begin(w);w[13U]|=bit;commit(w);
}
inline bool initialize(volatile std::uint32_t* w,std::uint32_t magic,R19RuntimeStageRole role,
    const R19RuntimeBuildFingerprint& build,const std::array<std::uint32_t,4U>& boot) noexcept {
  if(w[2U]!=0U||(role!=R19RuntimeStageRole::Ground&&role!=R19RuntimeStageRole::Vehicle)||
      (boot[0U]|boot[1U]|boot[2U]|boot[3U])==0U)return false;
  begin(w);for(std::size_t n=2U;n<512U;++n)w[n]=0U;
  w[2U]=magic;w[3U]=1U;w[4U]=static_cast<std::uint32_t>(role);
  for(std::size_t n=0U;n<4U;++n){w[5U+n]=build[n];w[9U+n]=boot[n];}
  w[13U]=r19_aux_initialized;commit(w);return true;
}
inline bool snapshot(const volatile std::uint32_t* w,Snapshot& out,std::uint32_t attempts) noexcept {
  for(std::uint32_t n=0U;n<attempts;++n){
    if(w[0U]!=0U)continue;fence();const auto before=w[1U];if((before&1U)!=0U)continue;
    Snapshot value{};for(std::size_t i=0U;i<512U;++i)value[i]=w[i];
    fence();if(w[0U]!=0U||before!=w[1U]||(w[1U]&1U)!=0U)continue;
    out=value;return true;
  }return false;
}
}

struct R19AuxReadinessRecordTestAccess;

// 2048-byte ABI. Main-task SINGLE writer. GPIO timestamps bracket the actual
// read, not the physical edge. now_ms is the exact separately supplied runtime
// clock input; it is not reconstructed from esp_timer microseconds. UART written
// bytes mean UART API acceptance only, never RF arrival or FIFO physical proof.
class alignas(std::uint32_t) R19AuxObservationRecord final {
 public:
  static constexpr std::size_t storage_word_count=512U,history_capacity=48U;
  [[nodiscard]] bool initialize(R19RuntimeStageRole role,const R19RuntimeBuildFingerprint& build,
      const std::array<std::uint32_t,4U>& boot) noexcept {return r19_aux_detail::initialize(words_,r19_aux_observation_magic,role,build,boot);}
  [[nodiscard]] bool observe_gpio(std::uint64_t begin_us,std::uint64_t end_us,
      std::uint64_t now_ms,std::uint32_t level,std::uint32_t state) noexcept {
    if(!valid())return false;
    if(begin_us>end_us||level>1U){r19_aux_detail::taint(words_,r19_aux_invalid_input);return false;}
    if(!time_ok(begin_us))return false;
    r19_aux_detail::begin(words_);
    if(words_[16U]!=0U){const auto previous_end=r19_aux_detail::read64(words_,26U);const auto gap=begin_us-previous_end;
      if(gap>r19_aux_detail::read64(words_,28U)){r19_aux_detail::write64(words_,28U,gap);
        r19_aux_detail::write64(words_,104U,previous_end);r19_aux_detail::write64(words_,106U,begin_us);}}
    r19_aux_detail::increment(words_,16U);r19_aux_detail::write64(words_,24U,begin_us);r19_aux_detail::write64(words_,26U,end_us);
    words_[30U]=static_cast<std::uint32_t>(now_ms);words_[108U]=static_cast<std::uint32_t>(now_ms>>32U);
    words_[31U]=level;words_[35U]=state;
    const auto seen=level==0U?1U:2U;const auto timestamp_offset=level==0U?20U:22U;
    if((words_[45U]&seen)==0U){words_[45U]|=seen;r19_aux_detail::write64(words_,timestamp_offset,begin_us);}
    if(words_[96U]!=0U&&(words_[97U]&seen)==0U){words_[97U]|=seen;
      r19_aux_detail::write64(words_,level==0U?100U:102U,begin_us);}
    append(begin_us,end_us,static_cast<std::uint32_t>(now_ms),level,state,1U);r19_aux_detail::commit(words_);return true;
  }
  [[nodiscard]] bool observe_uart(std::uint64_t begin_us,std::uint64_t accepted_us,
      std::uint32_t requested,std::uint32_t written,std::uint32_t state) noexcept {
    if(!valid())return false;
    if(begin_us>accepted_us||written>requested){r19_aux_detail::taint(words_,r19_aux_invalid_input);return false;}
    if(!time_ok(begin_us))return false;
    r19_aux_detail::begin(words_);r19_aux_detail::increment(words_,32U);
    words_[33U]=requested;words_[34U]=written;words_[35U]=state;
    r19_aux_detail::write64(words_,36U,begin_us);r19_aux_detail::write64(words_,38U,accepted_us);
    if(written!=0U&&(words_[45U]&4U)==0U){words_[45U]|=4U;r19_aux_detail::write64(words_,40U,accepted_us);}
    if(requested!=0U&&written==requested){r19_aux_detail::increment(words_,96U);words_[97U]=0U;
      r19_aux_detail::write64(words_,98U,accepted_us);r19_aux_detail::write64(words_,100U,0U);r19_aux_detail::write64(words_,102U,0U);}
    append(begin_us,accepted_us,requested,written,state,2U);r19_aux_detail::commit(words_);return true;
  }
  [[nodiscard]] bool observe_state(std::uint64_t now_us,std::uint32_t from,std::uint32_t to,std::uint32_t reason) noexcept {
    if(!valid()||!time_ok(now_us))return false;
    if(from==to&&reason==0U)return true; // Avoid consuming history on unchanged high-rate polls.
    r19_aux_detail::begin(words_);r19_aux_detail::increment(words_,42U);words_[35U]=to;
    append(now_us,now_us,from,to,reason,3U);r19_aux_detail::commit(words_);return true;
  }
  [[nodiscard]] bool latch_fault(std::uint64_t now_us,std::uint32_t code,std::uint32_t state) noexcept {
    if(!valid()||words_[44U]!=0U||code==0U||!time_ok(now_us))return false;
    r19_aux_detail::begin(words_);words_[43U]=code;words_[44U]=1U;words_[35U]=state;
    append(now_us,now_us,code,state,0U,4U);
    r19_aux_detail::write64(words_,48U,now_us);words_[50U]=code;words_[51U]=state;
    words_[52U]=words_[16U];words_[53U]=words_[32U];copy64(54U,20U);copy64(56U,22U);
    copy64(58U,24U);copy64(60U,26U);copy64(62U,28U);words_[64U]=words_[30U];words_[65U]=words_[31U];
    words_[66U]=words_[33U];words_[67U]=words_[34U];copy64(68U,36U);copy64(70U,38U);copy64(72U,40U);
    words_[74U]=words_[13U];words_[75U]=words_[42U];words_[76U]=words_[14U];words_[77U]=words_[45U];
    words_[80U]=words_[96U];words_[81U]=words_[97U];copy64(82U,98U);copy64(84U,100U);copy64(86U,102U);
    copy64(88U,104U);copy64(90U,106U);words_[92U]=words_[108U];r19_aux_detail::commit(words_);return true;
  }
  [[nodiscard]] bool try_snapshot(r19_aux_detail::Snapshot& out,std::uint32_t attempts=8U) const noexcept {
    return r19_aux_detail::snapshot(words_,out,attempts);
  }
 private:
  friend struct R19AuxReadinessRecordTestAccess;
  bool valid() const noexcept {return r19_aux_detail::header(words_,r19_aux_observation_magic);}
  bool time_ok(std::uint64_t now_us) noexcept {
    if(words_[14U]!=0U&&now_us<r19_aux_detail::read64(words_,46U)){
      r19_aux_detail::taint(words_,r19_aux_clock_regression);return false;}return true;
  }
  void copy64(std::size_t to,std::size_t from) noexcept {words_[to]=words_[from];words_[to+1U]=words_[from+1U];}
  void append(std::uint64_t begin_us,std::uint64_t end_us,std::uint32_t a,std::uint32_t b,
      std::uint32_t c,std::uint32_t kind) noexcept {
    r19_aux_detail::increment(words_,14U);r19_aux_detail::write64(words_,46U,end_us);
    const auto base=128U+words_[18U]*8U;r19_aux_detail::write64(words_,base,begin_us);
    r19_aux_detail::write64(words_,base+2U,end_us);words_[base+4U]=a;words_[base+5U]=b;words_[base+6U]=c;words_[base+7U]=kind;
    if(words_[17U]<history_capacity)++words_[17U];else{words_[13U]|=r19_aux_history_coverage_lost;r19_aux_detail::increment(words_,19U);}
    words_[18U]=(words_[18U]+1U)%history_capacity;
  }
  // w0 writer,1 seq,2 magic,3 schema,4 role,5..8 build,9..12 boot,13 flags,
  // 14 events,15 zero. w16 pollcount,17 history-used,18 ring-next,19 replaced,
  // 20 firstLOW64,22 firstHIGH64,24 last-read-begin64,26 end64,28 maxgap64,
  // 30 supplied-now-ms,31 level,32 uartcalls,33 requested,34 written,35 state,
  // 36 uartbegin64,38 uartreturn64,40 firstnonzeroaccepted64,42 statechanges,
  // 43 faultcode,44 faultlatched,45 seenLOW1/HIGH2/accepted4,46 last-event64.
  // w48..95 first-fault IMMUTABLE: fault64,code,state,polls,uartcalls,
  // firstLOW64,firstHIGH64,lastreadbegin64,end64,maxgap64,nowms,level,req,written,
  // uartbegin64,return64,firstaccepted64,flags,statechanges,eventcount,seenbits,
  // zeros78..79,txseq80,txseen81,accepted64@82,low64@84,high64@86,
  // maxgap-previous-end64@88,next-begin64@90,nowms-high32@92,zeros93..95.
  // w96 txseq,97 seenLOW1/HIGH2,98 last full UART acceptance64,100 txLOW64,
  // 102 txHIGH64,104 maxgap previous-end64,106 next-begin64,108nowms-high32,
  // 109..127zero. w128: 48 ring entries x8 [readbegin64,readend64,a,b,c,kind];
  // poll a is now-ms LOW32, while live/frozen fields retain full64 supplied-ms.
  volatile std::uint32_t words_[512U]{};
};

// 2048-byte ABI, ISR SINGLE writer AFTER initialize (done before attach).
// ISR path has bounded O(1) stores, compiler barriers only: no heap, locks,
// Serial/USB, snapshot or callback. A full buffer STOPS, never silently wraps.
// No edge seen is not proof of no physical transition or a functioning ISR.
class alignas(std::uint32_t) R19AuxEdgeRecord final {
 public:
  static constexpr std::size_t storage_word_count=512U,history_capacity=120U;
  [[nodiscard]] bool initialize(R19RuntimeStageRole role,const R19RuntimeBuildFingerprint& build,
      const std::array<std::uint32_t,4U>& boot,std::uint64_t initial_us,std::uint32_t initial_level) noexcept {
    if(initial_level>1U||!r19_aux_detail::initialize(words_,r19_aux_edge_magic,role,build,boot))return false;
    r19_aux_detail::begin(words_);words_[16U]=history_capacity;words_[18U]=initial_level;
    r19_aux_detail::write64(words_,30U,initial_us);r19_aux_detail::commit(words_);return true;
  }
  [[nodiscard]] VC_LORA_R19_AUX_ALWAYS_INLINE bool observe_edge(std::uint64_t now_us,std::uint32_t level) noexcept {
    if(!r19_aux_detail::header(words_,r19_aux_edge_magic))return false;
    if(level>1U){r19_aux_detail::taint(words_,r19_aux_invalid_input);return false;}
    if(now_us<r19_aux_detail::read64(words_,30U)||
        ((words_[19U]&4U)!=0U&&now_us<r19_aux_detail::read64(words_,22U))){
      r19_aux_detail::taint(words_,r19_aux_clock_regression);return false;}
    r19_aux_detail::begin(words_);r19_aux_detail::increment(words_,14U);r19_aux_detail::increment(words_,28U);
    if((words_[19U]&4U)==0U){r19_aux_detail::write64(words_,20U,now_us);words_[19U]|=4U;}
    r19_aux_detail::write64(words_,22U,now_us);const auto bit=level==0U?1U:2U;
    if((words_[19U]&bit)==0U){words_[19U]|=bit;r19_aux_detail::write64(words_,level==0U?24U:26U,now_us);}
    if(words_[15U]<history_capacity){const auto base=32U+words_[15U]*4U;
      r19_aux_detail::write64(words_,base,now_us);words_[base+2U]=level;words_[base+3U]=words_[28U];++words_[15U];}
    else{words_[13U]|=r19_aux_history_coverage_lost|r19_aux_edge_overflow;r19_aux_detail::increment(words_,17U);}
    r19_aux_detail::commit(words_);return true;
  }
  [[nodiscard]] bool try_snapshot(r19_aux_detail::Snapshot& out,std::uint32_t attempts=8U) const noexcept {
    return r19_aux_detail::snapshot(words_,out,attempts);
  }
 private:
  friend struct R19AuxReadinessRecordTestAccess;
  // Common header; w15 used,w16 capacity120,w17 dropped,w18 initial GPIO,
  // w19 seenLOW1/HIGH2/edge4,w20 firstedge64,w22 latestedge64,w24 LOW64,
  // w26 HIGH64,w28 edge sequence,w29zero,w30 initial timestamp64.
  // w32: 120 entries x4 [edge-us64,GPIO-level,edge-sequence].
  volatile std::uint32_t words_[512U]{};
};

// 2048-byte ABI, main-task SINGLE writer. Low-rate stage events are append-only.
// The four high-rate loop/call intervals aggregate separately, so millions of
// early returns cannot consume ClockResponse/READY/ARM event storage.
class alignas(std::uint32_t) R19UsbReadinessRecord final {
 public:
  static constexpr std::size_t storage_word_count=512U,history_capacity=54U;
  [[nodiscard]] bool initialize(R19RuntimeStageRole role,const R19RuntimeBuildFingerprint& build,
      const std::array<std::uint32_t,4U>& boot) noexcept {return r19_aux_detail::initialize(words_,r19_usb_readiness_magic,role,build,boot);}
  [[nodiscard]] bool event(R19ReadinessEvent type,std::uint64_t now_us,std::uint32_t a=0U,
      std::uint32_t b=0U,std::uint32_t c=0U,std::uint32_t d=0U) noexcept {
    if(!valid())return false;const auto value=static_cast<std::uint32_t>(type);
    if(value<1U||value>12U){r19_aux_detail::taint(words_,r19_aux_invalid_input);return false;}
    if(!time_ok(now_us))return false;r19_aux_detail::begin(words_);
    r19_aux_detail::increment(words_,14U);r19_aux_detail::increment(words_,16U);words_[19U]=value;
    r19_aux_detail::write64(words_,20U,now_us);
    if(type==R19ReadinessEvent::ClockFlushBegin)words_[22U]=b;
    if(type==R19ReadinessEvent::ClockFlushContext)words_[22U]=b;
    if(type==R19ReadinessEvent::GateUpdate){words_[23U]=b;words_[22U]=d;}
    if(type==R19ReadinessEvent::ArmAccepted&&a!=0U&&(words_[28U]&1U)==0U){words_[28U]|=1U;r19_aux_detail::write64(words_,24U,now_us);}
    if(type==R19ReadinessEvent::ReadyPublishEnd&&a!=0U){words_[28U]|=2U;r19_aux_detail::write64(words_,26U,now_us);}
    if(words_[17U]<history_capacity){const auto base=80U+words_[17U]*8U;
      r19_aux_detail::write64(words_,base,now_us);words_[base+2U]=value;words_[base+3U]=a;words_[base+4U]=b;
      words_[base+5U]=c;words_[base+6U]=d;words_[base+7U]=words_[16U];++words_[17U];}
    else{words_[13U]|=r19_aux_history_coverage_lost;r19_aux_detail::increment(words_,18U);}
    r19_aux_detail::commit(words_);return true;
  }
  [[nodiscard]] bool interval(R19ObservationInterval kind,std::uint64_t begin_us,
      std::uint64_t end_us,bool early_return=false) noexcept {
    if(!valid())return false;const auto value=static_cast<std::uint32_t>(kind);
    if(value>3U||begin_us>end_us){r19_aux_detail::taint(words_,r19_aux_invalid_input);return false;}
    if(!time_ok(end_us))return false;r19_aux_detail::begin(words_);const auto base=32U+value*12U;
    r19_aux_detail::increment(words_,base);r19_aux_detail::write64(words_,base+1U,begin_us);
    r19_aux_detail::write64(words_,base+3U,end_us);const auto duration=end_us-begin_us;
    if(words_[base]==1U||duration>r19_aux_detail::read64(words_,base+5U)){
      r19_aux_detail::write64(words_,base+5U,duration);r19_aux_detail::write64(words_,base+8U,begin_us);
      r19_aux_detail::write64(words_,base+10U,end_us);}
    if(early_return)r19_aux_detail::increment(words_,base+7U);
    r19_aux_detail::write64(words_,20U,end_us);r19_aux_detail::commit(words_);return true;
  }
  [[nodiscard]] bool try_snapshot(r19_aux_detail::Snapshot& out,std::uint32_t attempts=8U) const noexcept {
    return r19_aux_detail::snapshot(words_,out,attempts);
  }
 private:
  friend struct R19AuxReadinessRecordTestAccess;
  bool valid() const noexcept {return r19_aux_detail::header(words_,r19_usb_readiness_magic);}
  bool time_ok(std::uint64_t now_us) noexcept {
    // Interval calls do not increment event count, so inspect all presence
    // counters as well. Timestamp zero remains a valid first observation.
    if((words_[14U]!=0U||words_[32U]!=0U||words_[44U]!=0U||words_[56U]!=0U||words_[68U]!=0U)&&
        now_us<r19_aux_detail::read64(words_,20U)){r19_aux_detail::taint(words_,r19_aux_clock_regression);return false;}return true;
  }
  // Header; w16 total-events,w17 stored,w18 dropped,w19 last-type,
  // w20 last-observation-us64 (event OR interval),w22 epoch,w23 gate-state,
  // w24 first ARM-accepted-us64,w26 last READY-publish-return-us64,
  // w28 presence ARM-accepted1/READY-success-return2,w29..31zero.
  // w32: four interval aggregates x12 [count,begin64,end64,maxduration64,
  // earlycount,maxbegin64,maxend64]. The max interval survives later short calls.
  // w80: 54 events x8 [timestamp64,type,a,b,c,d,event-sequence]. GateUpdate
  // values are before-state,after-state,result,epoch; ARM/READY result is a.
  // Context12 values are budget-ms,epoch,absolute-deadline-us low32,high32.
  // Raw completion return evidence is NOT physical USB delivery proof.
  volatile std::uint32_t words_[512U]{};
};

struct alignas(std::uint32_t) R19AuxReadinessRecord final {
  R19AuxObservationRecord aux{};
  R19AuxEdgeRecord edges{};
  R19UsbReadinessRecord ready{};
};
static_assert(sizeof(R19AuxObservationRecord)==2048U&&sizeof(R19AuxEdgeRecord)==2048U&&sizeof(R19UsbReadinessRecord)==2048U);
static_assert(sizeof(R19AuxReadinessRecord)==6144U&&alignof(R19AuxReadinessRecord)==4U);
static_assert(std::is_standard_layout_v<R19AuxReadinessRecord>);
static_assert(offsetof(R19AuxReadinessRecord,edges)==2048U&&offsetof(R19AuxReadinessRecord,ready)==4096U);
} // namespace vc_lora::experimental

#undef VC_LORA_R19_AUX_ALWAYS_INLINE
