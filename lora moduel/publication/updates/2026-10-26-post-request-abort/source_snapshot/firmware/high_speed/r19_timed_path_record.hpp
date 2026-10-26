#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <type_traits>
#include <vc_lora/mavlink_frame.hpp>
#include "r19_first_usb_failure_record.hpp"

namespace vc_lora::experimental {

inline constexpr std::uint32_t r19_timed_path_magic=0x52313954U;
inline constexpr std::uint32_t r19_timed_path_schema=1U;

struct R19TimedPathSnapshot final {
  std::uint32_t sequence{0U},magic{0U},schema{0U};
  R19RuntimeStageRole role{R19RuntimeStageRole::Invalid};
  R19RuntimeBuildFingerprint build_fingerprint{};
  R19BootInstance boot_instance{};
  std::uint32_t flags{0U},mode{0U},expected_epoch{0U};
  std::uint64_t reader_session{0U},nonce{0U};
  std::uint32_t token{0U},frame_size{0U},accepted_bytes{0U},failure_reason{0U};
  std::uint32_t budget_ms{0U},observed_epoch{0U};
  std::uint64_t armed_us{0U},enqueue_us{0U},accepted_us{0U},sdk_snapshot_us{0U};
  std::uint64_t terminal_us{0U},started_us{0U},finished_us{0U},deadline_us{0U};
  std::uint32_t publish_generation{0U},pickup_generation{0U};
  std::uint32_t ring_pending_bytes{0U},stash_pending_bytes{0U},sdk_validity_flags{0U};
  std::uint32_t sdk_state_flags{0U},sdk_terminal_reason{0U},sdk_blocker_mask{0U},attempt_id{0U};
  std::uint64_t clock_request_us{0U};
  std::array<std::uint8_t,280U> frame_bytes{};
  [[nodiscard]] bool valid_header() const noexcept {
    return magic==r19_timed_path_magic&&schema==r19_timed_path_schema&&
      (role==R19RuntimeStageRole::Ground||role==R19RuntimeStageRole::Vehicle)&&
      (mode==1U||mode==2U)&&(flags&1U)!=0U&&
      (boot_instance[0]|boot_instance[1]|boot_instance[2]|boot_instance[3])!=0U;
  }
  [[nodiscard]] bool failure_latched() const noexcept {return valid_header()&&(flags&128U)!=0U;}
  [[nodiscard]] bool completion_latched() const noexcept {return valid_header()&&(flags&64U)!=0U;}
};
struct R19TimedPathRecordTestAccess;

// Diagnostic-only, JTAG-only, fixed 512-byte little-endian ABI. Exactly ONE
// application task writes; no ISR, Arduino, heap, USB output or SDK lock here.
// Each stage is latched once. Session/epoch mismatch and clock regression taint
// the trace permanently, never silently rebind it. The byte copy is the first
// actual Ground product Heartbeat admitted to LocalEgress, not a synthetic HB.
// SDK fields are coherent OBSERVATIONS taken after the API returns. Their
// timestamp is NOT the instant of a FIFO publish/pickup or PC application Read.
class alignas(std::uint32_t) R19TimedPathRecord final {
 public:
  static constexpr std::size_t storage_word_count=128U;
  R19TimedPathRecord() noexcept=default;
  R19TimedPathRecord(const R19TimedPathRecord&)=delete;
  R19TimedPathRecord& operator=(const R19TimedPathRecord&)=delete;

  [[nodiscard]] bool initialize(R19RuntimeStageRole role,const R19RuntimeBuildFingerprint& build,
      const R19BootInstance& boot,std::uint32_t mode) noexcept {
    if(words_[2U]!=0U||(role!=R19RuntimeStageRole::Ground&&role!=R19RuntimeStageRole::Vehicle)||
        (boot[0]|boot[1]|boot[2]|boot[3])==0U||(mode!=1U&&mode!=2U))return false;
    begin_write();
    for(std::size_t i=2U;i<storage_word_count;++i)words_[i]=0U;
    words_[2U]=r19_timed_path_magic;words_[3U]=r19_timed_path_schema;words_[4U]=static_cast<std::uint32_t>(role);
    for(std::size_t i=0U;i<4U;++i){words_[5U+i]=build[i];words_[9U+i]=boot[i];}
    words_[13U]=1U;words_[14U]=mode;commit_write();return true;
  }

  [[nodiscard]] bool observe_session(std::uint64_t reader,std::uint64_t nonce,
      std::uint32_t epoch,std::uint64_t now_us) noexcept {
    if(!ground()||tainted()||reader==0U||(nonce>>48U)!=0x5219U||
        (nonce&0x0000FFFFFFFFFFFFULL)==0U)return false;
    if((words_[13U]&2U)!=0U){
      if(read_stored_u64(16U)!=reader||read_stored_u64(18U)!=nonce||words_[15U]!=epoch)taint(256U);
      return false;
    }
    if((words_[13U]&8U)!=0U&&words_[15U]!=epoch){taint(256U);return false;}
    if(!observed_clock_ok(now_us))return false;
    begin_write();words_[15U]=epoch;write_u64(16U,reader);write_u64(18U,nonce);
    write_u64(52U,now_us);words_[13U]|=2U;commit_write();return true;
  }

  [[nodiscard]] bool observe_arm(std::uint64_t reader,std::uint64_t nonce,
      std::uint32_t epoch,std::uint64_t now_us) noexcept {
    if(!ground()||tainted()||words_[14U]!=2U||(words_[13U]&2U)==0U||
        (words_[13U]&(4U|8U))!=0U)return false;
    if(read_stored_u64(16U)!=reader||read_stored_u64(18U)!=nonce||words_[15U]!=epoch){taint(256U);return false;}
    if(!observed_clock_ok(now_us))return false;
    begin_write();write_u64(26U,now_us);words_[13U]|=4U;commit_write();return true;
  }

  // Record an observed readiness-gate abort without inventing ARM/USB events.
  // A later disconnect cannot rewrite a terminal transaction's evidence.
  [[nodiscard]] bool latch_gate_abort(std::uint32_t flag) noexcept {
    if(!ground()||terminal()||tainted()||(flag!=256U&&flag!=512U))return false;
    taint(flag);return true;
  }

  [[nodiscard]] bool latch_enqueue(const MavlinkFrame& frame,std::uint32_t token,
      std::uint32_t epoch,std::uint64_t now_us,std::uint64_t deadline_us) noexcept {
    if(!ground()||tainted()||(words_[13U]&8U)!=0U||token==0U||frame.size<21U||frame.size>280U||
        frame.message_id!=0U||deadline_us<now_us)return false;
    MavlinkFrame validated{};
    if(validate_mavlink_frame(frame.bytes.data(),frame.size,validated)!=MavlinkParseStatus::FrameReady||
        validated.message_id!=0U)return false;
    if((words_[13U]&2U)!=0U&&words_[15U]!=epoch){taint(256U);return false;}
    if(words_[14U]==2U&&(words_[13U]&4U)==0U)return false;
    if(!observed_clock_ok(now_us))return false;
    begin_write();words_[15U]=epoch;words_[20U]=token;words_[21U]=static_cast<std::uint32_t>(frame.size);
    words_[24U]=106U;words_[25U]=epoch;write_u64(28U,now_us);write_u64(40U,deadline_us);
    for(std::size_t i=0U;i<frame.size;++i)words_[58U+i/4U]|=
        static_cast<std::uint32_t>(frame.bytes[i])<<((i%4U)*8U);
    words_[13U]|=8U;commit_write();return true;
  }

  // Final cumulative LocalEgress->HWCDC accepted count for this frame. A zero
  // count is a software observation, not proof that no physical byte escaped.
  [[nodiscard]] bool latch_accepted(std::uint32_t token,std::uint32_t bytes,
      std::uint64_t now_us) noexcept {
    if(!transaction(token)||(words_[13U]&16U)!=0U||terminal()||bytes>words_[21U])return false;
    if(!observed_clock_ok(now_us))return false;
    begin_write();words_[22U]=bytes;write_u64(30U,now_us);words_[13U]|=16U;commit_write();return true;
  }

  [[nodiscard]] bool latch_sdk_observation(std::uint32_t token,const R19HwcdcFlushCallEvidence& sdk,
      std::uint64_t observed_us) noexcept {
    if(!transaction(token)||terminal()||(words_[13U]&32U)!=0U||(words_[13U]&16U)==0U||
        sdk.schema!=1U||sdk.transaction_token!=token||(sdk.validity_flags&8U)==0U||
        (sdk.validity_flags&~255U)!=0U||(sdk.state_flags&~0x3FFFU)!=0U||
        (sdk.flush_blocker_mask&~0xFFU)!=0U||sdk.terminal_reason==0U||sdk.terminal_reason>6U)return false;
    if(!observed_clock_ok(observed_us))return false;
    begin_write();write_u64(32U,observed_us);words_[42U]=sdk.publish_generation;words_[43U]=sdk.pickup_generation;
    words_[44U]=sdk.ring_pending_bytes;words_[45U]=sdk.stash_pending_bytes;words_[46U]=sdk.validity_flags;
    words_[47U]=sdk.state_flags;words_[48U]=sdk.terminal_reason;words_[49U]=sdk.flush_blocker_mask;words_[50U]=sdk.attempt_id;
    words_[13U]|=32U;commit_write();return true;
  }

  [[nodiscard]] bool latch_completed(std::uint32_t token,std::uint32_t epoch,std::uint64_t now_us) noexcept {
    if(!transaction(token)||terminal()||(words_[13U]&16U)==0U||words_[22U]!=words_[21U])return false;
    if(epoch!=words_[15U]){taint(256U);return false;}
    if(!observed_clock_ok(now_us))return false;
    begin_write();words_[25U]=epoch;write_u64(34U,now_us);words_[13U]|=64U;commit_write();return true;
  }

  [[nodiscard]] bool latch_failure(std::uint32_t token,std::uint32_t reason,std::uint32_t observed_epoch,
      std::uint64_t started_us,std::uint64_t finished_us,std::uint64_t observed_us) noexcept {
    if(!transaction(token)||terminal()||(words_[13U]&16U)==0U||reason==0U||reason>4U)return false;
    if(started_us<read_stored_u64(28U)||finished_us<started_us||observed_us<finished_us||
        observed_us<last_transaction_observation()){taint(512U);return false;}
    if(!observed_clock_ok(observed_us))return false;
    begin_write();words_[23U]=reason;words_[25U]=observed_epoch;write_u64(34U,observed_us);
    write_u64(36U,started_us);write_u64(38U,finished_us);words_[13U]|=128U;
    if(observed_epoch!=words_[15U])words_[13U]|=256U;
    commit_write();return true;
  }

  [[nodiscard]] bool try_snapshot(R19TimedPathSnapshot& out,std::uint32_t attempts=8U) const noexcept {
    for(std::uint32_t n=0U;n<attempts;++n){
      if(words_[0U]!=0U)continue;fence();const auto before=words_[1U];if((before&1U)!=0U)continue;
      std::array<std::uint32_t,storage_word_count> w{};
      for(std::size_t k=0U;k<storage_word_count;++k)w[k]=words_[k];
      fence();if(words_[0U]!=0U||before!=words_[1U]||(words_[1U]&1U)!=0U)continue;
      R19TimedPathSnapshot s{};s.sequence=before;s.magic=w[2U];s.schema=w[3U];s.role=static_cast<R19RuntimeStageRole>(w[4U]);
      for(std::size_t k=0U;k<4U;++k){s.build_fingerprint[k]=w[5U+k];s.boot_instance[k]=w[9U+k];}
      s.flags=w[13U];s.mode=w[14U];s.expected_epoch=w[15U];s.reader_session=read_u64(w,16U);s.nonce=read_u64(w,18U);
      s.token=w[20U];s.frame_size=w[21U];s.accepted_bytes=w[22U];s.failure_reason=w[23U];s.budget_ms=w[24U];s.observed_epoch=w[25U];
      s.armed_us=read_u64(w,26U);s.enqueue_us=read_u64(w,28U);s.accepted_us=read_u64(w,30U);s.sdk_snapshot_us=read_u64(w,32U);
      s.terminal_us=read_u64(w,34U);s.started_us=read_u64(w,36U);s.finished_us=read_u64(w,38U);s.deadline_us=read_u64(w,40U);
      s.publish_generation=w[42U];s.pickup_generation=w[43U];s.ring_pending_bytes=w[44U];s.stash_pending_bytes=w[45U];
      s.sdk_validity_flags=w[46U];s.sdk_state_flags=w[47U];s.sdk_terminal_reason=w[48U];s.sdk_blocker_mask=w[49U];s.attempt_id=w[50U];
      s.clock_request_us=read_u64(w,52U);
      for(std::size_t k=0U;k<280U;++k)s.frame_bytes[k]=static_cast<std::uint8_t>(w[58U+k/4U]>>((k%4U)*8U));
      out=s;return true;
    }return false;
  }
 private:
  friend struct R19TimedPathRecordTestAccess;
  static void fence() noexcept {std::atomic_signal_fence(std::memory_order_seq_cst);}
  [[nodiscard]] bool ground() const noexcept {return words_[2U]==r19_timed_path_magic&&words_[3U]==r19_timed_path_schema&&words_[4U]==1U;}
  [[nodiscard]] bool tainted() const noexcept {return (words_[13U]&768U)!=0U;}
  [[nodiscard]] bool terminal() const noexcept {return (words_[13U]&192U)!=0U;}
  [[nodiscard]] bool transaction(std::uint32_t token) const noexcept {return ground()&&!tainted()&&(words_[13U]&8U)!=0U&&words_[20U]==token;}
  [[nodiscard]] std::uint64_t last_transaction_observation() const noexcept {return read_stored_u64((words_[13U]&32U)!=0U?32U:30U);}
  [[nodiscard]] bool observed_clock_ok(std::uint64_t now_us) noexcept {
    // No separate mutable clock is serialized: compare every already-latched
    // observation, including a SyncOnly request acquired after the terminal.
    const std::uint32_t flag_bits[6U]{2U,4U,8U,16U,32U,192U};
    const std::size_t word_offsets[6U]{52U,26U,28U,30U,32U,34U};
    for(std::size_t n=0U;n<6U;++n)if((words_[13U]&flag_bits[n])!=0U&&now_us<read_stored_u64(word_offsets[n])){
      taint(512U);return false;
    }
    return true;
  }
  void taint(std::uint32_t bit) noexcept {begin_write();words_[13U]|=bit;commit_write();}
  void begin_write() noexcept {words_[0U]=1U;fence();words_[1U]=(words_[1U]&~1U)+1U;fence();}
  void commit_write() noexcept {fence();words_[1U]=(words_[1U]|1U)+1U;fence();words_[0U]=0U;}
  void write_u64(std::size_t n,std::uint64_t value) noexcept {words_[n]=static_cast<std::uint32_t>(value);words_[n+1U]=static_cast<std::uint32_t>(value>>32U);}
  [[nodiscard]] std::uint64_t read_stored_u64(std::size_t n) const noexcept {return words_[n]|(static_cast<std::uint64_t>(words_[n+1U])<<32U);}
  static std::uint64_t read_u64(const std::array<std::uint32_t,storage_word_count>& w,std::size_t n) noexcept {return w[n]|(static_cast<std::uint64_t>(w[n+1U])<<32U);}
  // ABI w0 writer,1 sequence,2 magic,3 schema,4 role,5..8 build,9..12 boot,
  // 13 flags(init1/session2/arm4/enqueue8/finalaccepted16/SDK32/completed64/
  // failed128/identitymismatch256/clockregression512),14 mode,15 epoch,
  // 16..17 reader,18..19 nonce,20 token,21 size,22 accepted,23 reason,24=106,
  // 25 observedepoch,26 ARM,28 enqueue,30 acceptance-observed,32 SDK-observed,
  // 34 terminal-observed,36 failurestart,38 failurereturn,40 deadline(u64LE),
  // 42 publish,43 pickup,44 ring,45 stash,46SDKvalid,47SDKstate,48SDKterminal,
  // 49SDKblockers,50attempt,51zero,52..53 clockrequest-us,54..57zero,
  // 58..127 exact frame bytes and zero padding. No physical FIFO proof flag.
  volatile std::uint32_t words_[storage_word_count]{};
};
static_assert(sizeof(R19TimedPathRecord)==512U);
static_assert(std::is_standard_layout_v<R19TimedPathRecord>);
static_assert(alignof(R19TimedPathRecord)==4U);
} // namespace vc_lora::experimental
