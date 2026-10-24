#include "high_speed/r19_grant_diagnostic_record.hpp"
#include <array>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>

namespace vc_lora::experimental {
struct R19GrantDiagnosticRecordTestAccess {
  static void writer(R19GrantDiagnosticRecord& r,std::uint32_t v){r.words_[0]=v;}
  static void sequence(R19GrantDiagnosticRecord& r,std::uint32_t v){r.words_[1]=v;}
  static void count(R19GrantDiagnosticRecord& r,std::uint32_t v){r.words_[80]=v;}
};
}
int main(int argc,char** argv){
  using namespace vc_lora::experimental;
  unsigned checks=0,failures=0;
  const auto check=[&](bool v,const char* text){++checks;if(!v){++failures;std::cerr<<"FAIL "<<text<<'\n';}};
  const R19RuntimeBuildFingerprint build{1,2,3,4};
  const std::array<std::uint32_t,4> boot{5,6,7,8};
  R19GrantDiagnosticRecord record{};R19GrantDiagnosticSnapshot snap{};
  check(sizeof(record)==1024 && alignof(R19GrantDiagnosticRecord)==4,"fixed1024-byte ABI");
  check(record.try_snapshot(snap)&&!snap.valid_header(),"uninitialized remains invalid");
  check(!record.initialize(R19RuntimeStageRole::Invalid,build,boot),"invalid role rejected");
  check(!record.initialize(R19RuntimeStageRole::Ground,build,{}),"zero boot rejected");
  check(record.initialize(R19RuntimeStageRole::Ground,build,boot),"Ground initialize");
  check(!record.initialize(R19RuntimeStageRole::Ground,build,boot),"reinitialize rejected");
  check(record.try_snapshot(snap)&&snap.valid_header()&&!snap.failure_latched()&&snap.observation_count==0,"initialized empty snapshot");
  R19GrantDiagnosticEvidence e{};e.event=3;e.validity_flags=1|2|4|8;e.observed_ms=9007199254741101ULL;
  e.request_origin_ms=e.observed_ms;e.await_fresh_grant_started_ms=e.observed_ms;
  e.owner_state_before=0;e.owner_state_after=2;e.coordinator_state_before=0;e.coordinator_state_after=1;e.source_line=123;
  const auto reject=[&](R19GrantDiagnosticEvidence bad,const char* text){std::array<std::uint8_t,1024> before{},after{};std::memcpy(before.data(),&record,1024);check(!record.observe(bad),text);std::memcpy(after.data(),&record,1024);check(before==after,"invalid observation has no mutation");};
  auto bad=e;bad.event=10;reject(bad,"unknown event rejected");
  bad=e;bad.validity_flags|=128;reject(bad,"unknown validity flag rejected");
  bad=e;bad.owner_state_after=10;reject(bad,"unknown owner state rejected");
  bad=e;bad.coordinator_state_after=15;reject(bad,"unknown coordinator state rejected");
  bad=e;bad.owner_result=42;reject(bad,"unknown owner result rejected");
  bad=e;bad.coordinator_result=22;reject(bad,"unknown coordinator result rejected");
  bad=e;bad.adapter_status=27;reject(bad,"unknown adapter status rejected");
  bad=e;bad.validity_flags&=~4U;reject(bad,"unavailable request clock cannot hold stale value");
  bad=e;bad.standard_grant_session=1;reject(bad,"unavailable standard Grant cannot hold stale identity");
  check(record.observe(e),"request event accepted");
  check(record.try_snapshot(snap)&&snap.latest.observed_ms==e.observed_ms&&snap.journal_count==1&&snap.observation_count==1,"exact uint64 clock retained");
  for(unsigned i=0;i<20;++i){e.event=5;e.observed_ms++;check(record.observe(e),"unchanged tick accepted");}
  check(record.try_snapshot(snap)&&snap.journal_count==1&&snap.observation_count==21,"unchanged ticks do not consume journal");
  for(unsigned i=0;i<14;++i){e.event=2;e.validity_flags|=16;e.standard_grant_observed_ms=e.observed_ms++;e.standard_grant_session=1;e.standard_grant_cycle=i;check(record.observe(e),"Grant observation accepted");}
  check(record.try_snapshot(snap)&&snap.journal_count==10&&snap.journal_dropped==5&&!snap.failure_latched(),"bounded journal drops explicitly counted");
  check(snap.journal[0].ordinal==1&&snap.journal[5].ordinal==26&&snap.journal[6].ordinal==32&&snap.journal[9].ordinal==35,"first six and last four transitions retained in order");
  e.event=5;e.observed_ms=e.request_origin_ms+500;e.owner_result=24;e.owner_last_error=24;e.owner_state_after=9;e.adapter_status=3;e.adapter_failure_reason=3;e.source_line=2299;
  check(record.observe(e,true),"first failure freezes exact event");
  check(record.try_snapshot(snap)&&snap.failure_latched()&&snap.first_failure.source_line==2299&&snap.first_failure.owner_result==24&&snap.first_failure.observed_ms==e.observed_ms,"immutable firstfailure detail captured");
  std::array<std::uint8_t,1024> before{},after{};std::memcpy(before.data(),&record,1024);e.source_line=9999;check(!record.observe(e,true),"second failure rejected");std::memcpy(after.data(),&record,1024);check(before==after,"entire record freezes after firstfailure");
  std::array<std::uint32_t,256> raw{};std::memcpy(raw.data(),&record,1024);
  check(raw[2]==r19_grant_diagnostic_magic&&raw[14]==1024&&raw[16+28]==2299&&raw[48+28]==2299,"published offsets match record ABI");
  bool zero=true;for(unsigned i=85;i<96;++i)zero=zero&&raw[i]==0;check(zero,"reserved metadata zero");
  const auto old=snap;R19GrantDiagnosticRecordTestAccess::writer(record,1);check(!record.try_snapshot(snap,2)&&snap.sequence==old.sequence,"active writer not exposed");
  R19GrantDiagnosticRecordTestAccess::writer(record,0);R19GrantDiagnosticRecordTestAccess::sequence(record,3);check(!record.try_snapshot(snap,2),"odd sequence rejected");
  R19GrantDiagnosticRecordTestAccess::sequence(record,4);check(record.try_snapshot(snap),"stable seqlock accepted");
  R19GrantDiagnosticRecord vehicle{};check(vehicle.initialize(R19RuntimeStageRole::Vehicle,build,boot),"Vehicle identity supported");
  bad={};bad.event=1;check(vehicle.observe(bad),"absent fields explicitly unavailable not fabricated healthy Grant");
  check(vehicle.observe_grant_event(R19GrantDiagnosticEvent::GrantGenerated,500,3,4,5,6,700,1),"Vehicle Grant generated boundary accepted");
  check(vehicle.observe_grant_event(R19GrantDiagnosticEvent::GrantWriteAccepted,501,3,4,5,6,701,2),"Vehicle UART acceptance boundary distinct");
  check(vehicle.observe_grant_event(R19GrantDiagnosticEvent::GrantPhysicalTail,1050,3,4,5,6,702,3),"Vehicle physical tail boundary distinct");
  check(vehicle.try_snapshot(snap)&&snap.latest.action_token==5&&snap.latest.generation==6&&snap.latest.disposition==3&&snap.journal[3].session==3&&snap.journal[3].cycle==4,"wire identity retained without invented adapter state");
  check(!vehicle.observe_grant_event(R19GrantDiagnosticEvent::Tick,501,3,4,5,6,701),"non-wire event rejected by wire API");
  check(!vehicle.observe_grant_event(R19GrantDiagnosticEvent::GrantGenerated,501,3,4,5,6,701,256),"unknown wire disposition rejected");
  GroundHighSpeedPhase6DiagnosticSnapshot adapter{};adapter.event=GroundHighSpeedDiagnosticEvent::ParameterRequest;adapter.request_origin_valid=true;adapter.request_origin_ms=0;adapter.observed_ms=1;
  const auto converted=make_r19_grant_diagnostic_evidence(adapter,444);
  check(converted.validity_flags==4&&converted.request_origin_ms==0&&converted.source_line==444,"adapter conversion preserves valid epoch-zero versus unavailable");
  R19GrantDiagnosticRecord exhausted{};(void)exhausted.initialize(R19RuntimeStageRole::Ground,build,boot);R19GrantDiagnosticRecordTestAccess::count(exhausted,0xffffffffU);
  check(!exhausted.observe(converted)&&exhausted.try_snapshot(snap)&&!snap.valid_header()&&(snap.flags&4U)!=0,"counter overflow cannot become healthy evidence");
  if(argc>1){std::ofstream file(argv[1],std::ios::binary);file.write(reinterpret_cast<const char*>(&record),sizeof(record));check(file.good(),"fixture raw bytes written");}
  if(argc>2){std::ofstream file(argv[2],std::ios::binary);file.write(reinterpret_cast<const char*>(&vehicle),sizeof(vehicle));check(file.good(),"Vehicle fixture raw bytes written");}
  std::cout<<"R19-GRANT-DIAGNOSTIC-RECORD checks="<<checks<<" failures="<<failures<<'\n';return failures?1:0;
}
