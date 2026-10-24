#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <type_traits>
#include "../../../firmware/high_speed/r19_timed_path_record.hpp"

namespace vc_lora::experimental {
struct R19TimedPathRecordTestAccess final {
  static std::uint32_t word(const R19TimedPathRecord& r, std::size_t n) { return r.words_[n]; }
  static void begin(R19TimedPathRecord& r) { r.begin_write(); }
  static void end(R19TimedPathRecord& r) { r.commit_write(); }
};
}
int main(int argc,char** argv) {
  using namespace vc_lora;
  using namespace vc_lora::experimental;
  static_assert(sizeof(R19TimedPathRecord)==512U);
  static_assert(alignof(R19TimedPathRecord)==4U);
  static_assert(std::is_standard_layout_v<R19TimedPathRecord>);
  unsigned checks=0U,failures=0U;
  const auto check=[&](bool value,const char* name){++checks;if(!value){++failures;std::cerr<<"FAIL "<<name<<'\n';}};
  const R19RuntimeBuildFingerprint fp{1U,2U,3U,4U};
  const R19BootInstance boot{11U,12U,13U,14U};
  constexpr std::uint64_t nonce=0x5219000000000123ULL;
  constexpr std::uint64_t base=0x1234567800000000ULL;
  R19TimedPathRecord r;
  R19TimedPathSnapshot s;
  check(r.try_snapshot(s)&&!s.valid_header(),"zero is not initialized");
  check(!r.initialize(R19RuntimeStageRole::Invalid,fp,boot,2U),"invalid role");
  check(!r.initialize(R19RuntimeStageRole::Ground,fp,{},2U),"zero boot");
  check(!r.initialize(R19RuntimeStageRole::Ground,fp,boot,0U),"disabled mode");
  check(r.initialize(R19RuntimeStageRole::Ground,fp,boot,2U),"initialize");
  check(!r.initialize(R19RuntimeStageRole::Ground,fp,boot,2U),"no reinitialize");
  check(!r.observe_session(0U,nonce,7U,base),"zero reader rejected");
  check(!r.observe_session(91U,1U,7U,base),"foreign nonce rejected");
  check(r.observe_session(91U,nonce,7U,base),"first session");
  check(r.observe_arm(91U,nonce,7U,base+10U),"ARM bound");
  std::array<std::uint8_t,9U> payload{0U,0U,0U,0U,2U,3U,0U,4U,3U};
  MavlinkFrame frame;
  check(encode_mavlink_v2(43U,1U,1U,0U,payload.data(),payload.size(),frame),"heartbeat fixture");
  check(r.latch_enqueue(frame,17U,7U,base+20U,base+106000U),"first enqueue");
  auto saved_frame=frame;
  frame.bytes[10U]^=1U;
  check(r.try_snapshot(s)&&s.frame_bytes[10U]==saved_frame.bytes[10U]&&s.enqueue_us==base+20U&&
        s.armed_us==base+10U&&s.reader_session==91U&&s.nonce==nonce&&s.expected_epoch==7U,
        "immutable byte identity and full-width time");
  check(!r.latch_enqueue(saved_frame,18U,7U,base+21U,base+106000U),"second frame not substituted");
  check(!r.latch_accepted(17U,22U,base+22U),"accepted overflow");
  check(r.latch_accepted(17U,21U,base+23U),"final acceptance");
  check(!r.latch_accepted(17U,0U,base+24U),"accepted immutable");
  R19HwcdcFlushCallEvidence sdk;
  sdk.validity_flags=0x1FU;sdk.transaction_token=17U;sdk.attempt_id=4U;
  sdk.terminal_reason=5U;sdk.publish_generation=3U;sdk.pickup_generation=2U;
  sdk.state_flags=0x2417U;sdk.flush_blocker_mask=0x1CU;
  check(r.latch_sdk_observation(17U,sdk,base+106001U),"coherent SDK observation");
  check(!r.latch_sdk_observation(17U,sdk,base+106002U),"SDK immutable");
  check(r.latch_failure(17U,1U,7U,base+24U,base+106000U,base+106001U),"first failure");
  check(r.try_snapshot(s)&&s.failure_latched()&&!s.completion_latched()&&s.accepted_bytes==21U&&
        s.publish_generation==3U&&s.pickup_generation==2U&&s.sdk_snapshot_us==base+106001U&&
        s.started_us==base+24U&&s.finished_us==base+106000U&&s.terminal_us==base+106001U&&s.budget_ms==106U,
        "terminal evidence preserved, observation not exact hardware event");
  const auto sequence=s.sequence;
  check(!r.latch_completed(17U,7U,base+106002U),"failure cannot become success");
  check(!r.latch_failure(17U,4U,7U,base+24U,base+106000U,base+106003U)&&r.try_snapshot(s)&&s.sequence==sequence,
        "later failure cannot overwrite");
  check(R19TimedPathRecordTestAccess::word(r,2U)==0x52313954U&&R19TimedPathRecordTestAccess::word(r,26U)==10U&&
        R19TimedPathRecordTestAccess::word(r,27U)==0x12345678U&&R19TimedPathRecordTestAccess::word(r,58U)==0x000009FDU,
        "fixed ABI offsets");
  for(std::size_t i=frame.size;i<280U;++i)check(s.frame_bytes[i]==0U,"zero frame padding");
  auto sentinel=s;R19TimedPathRecordTestAccess::begin(r);
  check(!r.try_snapshot(s,1U)&&s.sequence==sentinel.sequence,"torn read rejected without output change");
  R19TimedPathRecordTestAccess::end(r);
  check(!r.try_snapshot(s,0U),"zero snapshot attempts");

  R19TimedPathRecord vehicle;
  check(vehicle.initialize(R19RuntimeStageRole::Vehicle,fp,boot,2U)&&
        !vehicle.observe_session(91U,nonce,7U,base)&&!vehicle.latch_enqueue(saved_frame,17U,7U,base,base+106000U),
        "vehicle has identity, no invented Ground observations");
  R19TimedPathRecord early;
  check(early.initialize(R19RuntimeStageRole::Ground,fp,boot,1U)&&
        early.latch_enqueue(saved_frame,9U,0U,base+20U,base+106000U)&&
        early.latch_accepted(9U,0U,base+21U)&&
        early.latch_failure(9U,2U,0U,base+20U,base+106000U,base+106001U),
        "SyncOnly can record failure before clock session");
  check(!early.observe_arm(91U,nonce,0U,base+106002U),"SyncOnly cannot invent ARM");
  check(early.observe_session(91U,nonce,0U,base+106010U)&&early.try_snapshot(s)&&
        s.enqueue_us==base+20U&&s.clock_request_us==base+106010U&&(s.flags&4U)==0U,
        "later session does not rewrite earlier times");
  R19TimedPathRecord mismatch;
  check(mismatch.initialize(R19RuntimeStageRole::Ground,fp,boot,2U)&&
        mismatch.observe_session(91U,nonce,7U,base)&&
        !mismatch.observe_arm(91U,nonce,8U,base+1U)&&mismatch.try_snapshot(s)&&(s.flags&256U)!=0U,
        "identity mismatch explicitly taints trace");
  check(!mismatch.observe_arm(91U,nonce,7U,base+2U),"tainted session cannot recover silently");
  R19TimedPathRecord completed;
  check(completed.initialize(R19RuntimeStageRole::Ground,fp,boot,2U)&&completed.observe_session(91U,nonce,7U,base)&&
        completed.observe_arm(91U,nonce,7U,base+1U)&&completed.latch_enqueue(saved_frame,1U,7U,base+2U,base+106000U)&&
        completed.latch_accepted(1U,21U,base+3U)&&completed.latch_completed(1U,7U,base+4U)&&completed.try_snapshot(s)&&
        s.completion_latched()&&!s.failure_latched(),"success trace is separately terminal");
  check(!completed.latch_failure(1U,1U,7U,base+2U,base+4U,base+5U),"success cannot become failure");
  R19TimedPathRecord backwards_enqueue;
  check(backwards_enqueue.initialize(R19RuntimeStageRole::Ground,fp,boot,1U)&&
        backwards_enqueue.observe_session(91U,nonce,7U,base+10U)&&
        !backwards_enqueue.latch_enqueue(saved_frame,1U,7U,base+5U,base+106000U)&&
        backwards_enqueue.try_snapshot(s)&&(s.flags&512U)!=0U,
        "SyncOnly enqueue cannot regress behind earlier clock session");
  R19TimedPathRecord backwards_sync;
  check(backwards_sync.initialize(R19RuntimeStageRole::Ground,fp,boot,1U)&&
        backwards_sync.latch_enqueue(saved_frame,1U,7U,base+10U,base+106000U)&&
        backwards_sync.latch_accepted(1U,21U,base+11U)&&
        backwards_sync.latch_completed(1U,7U,base+12U)&&
        !backwards_sync.observe_session(91U,nonce,7U,base+9U)&&
        backwards_sync.try_snapshot(s)&&(s.flags&512U)!=0U,
        "later synchronization cannot hide observed clock regression");
  if(argc==3&&std::string(argv[1])=="--export-fixtures") {
    const std::filesystem::path directory(argv[2]);
    std::filesystem::create_directories(directory);
    const auto write_fixture=[&](const char* name,const R19TimedPathRecord& record) {
      std::array<char,512U> bytes{};
      for(std::size_t n=0U;n<128U;++n) {
        const auto word=R19TimedPathRecordTestAccess::word(record,n);
        for(unsigned k=0U;k<4U;++k)bytes[n*4U+k]=static_cast<char>(word>>(8U*k));
      }
      std::ofstream output(directory/name,std::ios::binary|std::ios::trunc);
      output.write(bytes.data(),static_cast<std::streamsize>(bytes.size()));
      check(output.good(),"cross-language fixture export");
    };
    R19TimedPathRecord no_frame;
    check(no_frame.initialize(R19RuntimeStageRole::Ground,fp,boot,2U),"initialize no-frame export");
    write_fixture("ground_failed.bin",r);
    write_fixture("ground_completed.bin",completed);
    write_fixture("ground_no_frame.bin",no_frame);
    write_fixture("vehicle_no_frame.bin",vehicle);
  }
  std::cout<<"UT-R19-TIMED-PATH-RECORD-001 checks="<<checks<<" failures="<<failures<<'\n';
  return failures==0U?0:1;
}
