#include "../../../firmware/high_speed/r19_aux_readiness_record.hpp"
#include "vc_lora/runtime_contract.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <limits>
#include <string>
#include <type_traits>

using namespace vc_lora::experimental;

namespace vc_lora::experimental {
struct R19AuxReadinessRecordTestAccess {
  static void set_word(R19AuxObservationRecord& r,std::size_t n,std::uint32_t value){r.words_[n]=value;}
  static void set_word(R19AuxEdgeRecord& r,std::size_t n,std::uint32_t value){r.words_[n]=value;}
  static void set_word(R19UsbReadinessRecord& r,std::size_t n,std::uint32_t value){r.words_[n]=value;}
};
}

namespace {
unsigned checks=0U, failures=0U;
void check(bool value,const char* message){++checks;if(!value){++failures;std::cerr<<"FAIL "<<message<<'\n';}}
using Words=std::array<std::uint32_t,512U>;
std::uint64_t u64(const Words& w,std::size_t n){return w[n]|(static_cast<std::uint64_t>(w[n+1U])<<32U);}
const R19RuntimeBuildFingerprint build{11U,22U,33U,44U};
const std::array<std::uint32_t,4U> boot{1U,2U,3U,4U};

void initialize(R19AuxReadinessRecord& record){
  check(record.aux.initialize(R19RuntimeStageRole::Ground,build,boot),"aux initialize");
  check(record.edges.initialize(R19RuntimeStageRole::Ground,build,boot,0U,1U),"edge initialize before attach");
  check(record.ready.initialize(R19RuntimeStageRole::Ground,build,boot),"ready initialize");
}

void basic_and_fault(){
  R19AuxReadinessRecord r{};Words a{},e{},s{};initialize(r);
  check(!r.aux.initialize(R19RuntimeStageRole::Ground,build,boot),"reinitialize rejected");
  check(r.aux.observe_gpio(0U,1U,900U,0U,2U),"zero time low sample is real");
  check(r.aux.observe_gpio(15001U,15003U,914U,1U,2U),"high sample actual clock differs from supplied millis");
  check(r.aux.observe_uart(16000U,16010U,32U,32U,3U),"full uart acceptance");
  check(r.aux.observe_gpio(16011U,16012U,915U,0U,3U),"tx first low");
  check(r.aux.observe_gpio(30011U,30013U,929U,1U,3U),"14 ms high observation");
  check(r.aux.observe_gpio(31011U,31013U,930U,1U,3U),"15 ms high observation");
  check(r.aux.observe_state(31014U,3U,4U,0U),"state transition");
  check(r.aux.latch_fault(31015U,5U,4U),"first fault");
  check(r.aux.try_snapshot(a),"aux snapshot");
  check(a[2U]==r19_aux_observation_magic&&a[3U]==1U&&a[4U]==1U,"aux header");
  check(a[0U]==0U&&(a[1U]&1U)==0U,"committed seqlock");
  check(a[16U]==5U&&a[45U]==7U,"poll count and zero timestamp presence bits");
  check(u64(a,20U)==0U&&u64(a,22U)==15001U,"boot first low and high remain independent");
  check(u64(a,28U)==15000U&&u64(a,104U)==1U&&u64(a,106U)==15001U,"max gap is previous read end to next read begin");
  check(a[30U]==930U&&a[31U]==1U,"supplied contract millis retained not derived");
  check(a[32U]==1U&&a[33U]==32U&&a[34U]==32U,"uart requests and accepted count");
  check(u64(a,36U)==16000U&&u64(a,38U)==16010U,"uart call bracket");
  check(a[96U]==1U&&a[97U]==3U&&u64(a,98U)==16010U,"tx identity and acceptance");
  check(u64(a,100U)==16011U&&u64(a,102U)==30011U,"transaction low/high separated from boot");
  check(a[44U]==1U&&u64(a,48U)==31015U&&a[50U]==5U,"first fault latched");
  check(a[80U]==1U&&a[81U]==3U&&u64(a,84U)==16011U,"first fault tx snapshot");
  std::array<std::uint32_t,48U> frozen{};for(std::size_t i=0;i<frozen.size();++i)frozen[i]=a[48U+i];
  check(!r.aux.latch_fault(31016U,99U,99U),"later fault cannot replace first");
  check(r.aux.observe_uart(32000U,32001U,16U,16U,3U),"new transaction after diagnostic fault");
  check(r.aux.observe_gpio(32002U,32003U,931U,1U,3U),"continued observations after fault");
  check(r.aux.try_snapshot(a),"post fault snapshot");
  for(std::size_t i=0;i<frozen.size();++i)check(a[48U+i]==frozen[i],"fault words immutable");
  check(a[96U]==2U&&a[97U]==2U&&u64(a,100U)==0U,"new tx resets low presence without inventing observation");
  check(r.edges.observe_edge(0U,0U)&&r.edges.observe_edge(15000U,1U),"ISR edge timestamps");
  check(r.edges.try_snapshot(e)&&e[15U]==2U&&e[19U]==7U,"ISR zero timestamp observed");
  check(u64(e,24U)==0U&&u64(e,26U)==15000U,"edge low/high chronology");
  check(r.ready.event(R19ReadinessEvent::ClockFlushBegin,0U,106U,8U,999U,0U),"clock flush start");
  check(r.ready.event(R19ReadinessEvent::ClockFlushEnd,100U,1U,106U,8U,0U),"clock flush completed");
  check(r.ready.event(R19ReadinessEvent::GateUpdate,101U,1U,3U,1U,8U),"internal gate update");
  check(r.ready.event(R19ReadinessEvent::ReadyEncode,102U,1U,63U,8U,0U),"ready encoded");
  check(r.ready.event(R19ReadinessEvent::ReadyPublishBegin,103U,63U,8U,106U,0U),"ready publish begins");
  check(r.ready.event(R19ReadinessEvent::ReadyPublishEnd,104U,1U,8U,63U,0U),"ready publish end");
  check(r.ready.event(R19ReadinessEvent::ArmReceived,105U,8U,1U,0U,0U),"arm reception separate");
  check(r.ready.event(R19ReadinessEvent::ArmAccepted,106U,1U,8U,3U,0U),"arm accepted separate");
  check(r.ready.try_snapshot(s)&&s[17U]==8U&&s[28U]==3U,"readiness stages retained");
  check(u64(s,24U)==106U&&u64(s,26U)==104U,"arm and ready timestamps");
  check(s[80U+2U]==1U&&u64(s,80U)==0U,"event zero timestamp retained");
  check(s[22U]==8U&&s[23U]==3U,"gate epoch and result state retain real caller argument order");
  Words again{};check(r.ready.try_snapshot(again)&&again==s,"two stable reads agree");
}

void uncertainty_overflow_and_saturation(){
  R19AuxReadinessRecord r{};initialize(r);Words a{},e{},s{};
  check(r.aux.observe_uart(1U,2U,32U,0U,1U),"zero write observed but not full acceptance");
  check(r.aux.try_snapshot(a)&&a[96U]==0U&&(a[45U]&4U)==0U,"zero uart not invented acceptance");
  for(std::uint32_t n=0U;n<61U;++n)check(r.aux.observe_gpio(10U+n*2U,11U+n*2U,n,n%2U,1U),"poll ring continues bounded");
  check(r.aux.try_snapshot(a)&&a[17U]==48U&&a[19U]>0U&&(a[13U]&8U)!=0U,"poll history wrap taints coverage without losing summary");
  check(a[16U]==61U&&u64(a,20U)==10U,"poll summary remains exact after wrap");
  for(std::uint32_t n=0U;n<121U;++n)static_cast<void>(r.edges.observe_edge(1000U+n,n%2U));
  check(r.edges.try_snapshot(e)&&e[15U]==120U&&e[17U]==1U&&(e[13U]&72U)==72U,"ISR full buffer is sticky missing coverage");
  check(e[32U+3U]==1U&&u64(e,32U)==1000U,"old edge not overwritten at overflow");
  for(std::uint32_t n=0U;n<55U;++n)static_cast<void>(r.ready.event(R19ReadinessEvent::GateUpdate,2000U+n,1U,3U,1U,8U));
  check(r.ready.try_snapshot(s)&&s[17U]==54U&&s[18U]==1U&&(s[13U]&8U)!=0U,"ready event overflow visible");
  check(!r.aux.observe_gpio(1U,2U,1U,1U,1U),"regressing clock rejected");
  check(r.aux.try_snapshot(a)&&(a[13U]&2U)!=0U,"clock regression sticky");
  check(!r.edges.observe_edge(1U,1U)&&r.edges.try_snapshot(e)&&(e[13U]&2U)!=0U,"ISR regression sticky");
  check(!r.ready.event(R19ReadinessEvent::ArmAccepted,1U,0U,0U,0U,0U)&&r.ready.try_snapshot(s)&&(s[13U]&2U)!=0U,"ready clock regression sticky");
  R19AuxReadinessRecord invalid{};initialize(invalid);
  check(!invalid.aux.observe_gpio(10U,9U,0U,1U,1U),"invalid gpio bracket");
  check(!invalid.aux.observe_uart(10U,11U,1U,2U,1U),"written larger than requested invalid");
  check(!invalid.edges.observe_edge(1U,2U),"nonbinary GPIO invalid");
  check(!invalid.ready.interval(static_cast<R19ObservationInterval>(4U),1U,2U,false),"unknown interval invalid");
  check(invalid.aux.try_snapshot(a)&&(a[13U]&16U)!=0U,"invalid input trace incomplete");
  R19AuxReadinessRecordTestAccess::set_word(invalid.aux,16U,std::numeric_limits<std::uint32_t>::max());
  check(invalid.aux.observe_gpio(20U,21U,0U,1U,1U),"saturated counter never blocks product observation");
  check(invalid.aux.try_snapshot(a)&&a[16U]==std::numeric_limits<std::uint32_t>::max()&&(a[13U]&4U)!=0U,"counter saturates no wrap");
  Words untouched{};untouched.fill(0xABCDEFU);
  R19AuxReadinessRecordTestAccess::set_word(invalid.aux,0U,1U);
  check(!invalid.aux.try_snapshot(untouched,2U)&&untouched[0U]==0xABCDEFU,"active writer never becomes coherent snapshot");
  R19AuxReadinessRecordTestAccess::set_word(invalid.aux,0U,0U);
  R19AuxReadinessRecordTestAccess::set_word(invalid.aux,1U,3U);
  check(!invalid.aux.try_snapshot(untouched,2U),"odd sequence rejected");
  R19AuxReadinessRecord wrapped{};initialize(wrapped);
  R19AuxReadinessRecordTestAccess::set_word(wrapped.aux,1U,0xFFFFFFFEU);
  check(wrapped.aux.observe_gpio(0U,1U,0U,1U,1U),"sequence wrapping keeps observation");
  check(wrapped.aux.try_snapshot(a)&&a[1U]==0U&&(a[13U]&32U)!=0U,"sequence wrap explicitly taints trace");
  R19AuxReadinessRecordTestAccess::set_word(wrapped.edges,14U,0xFFFFFFFFU);
  R19AuxReadinessRecordTestAccess::set_word(wrapped.edges,28U,0xFFFFFFFFU);
  check(wrapped.edges.observe_edge(1U,1U)&&wrapped.edges.try_snapshot(e)&&e[14U]==0xFFFFFFFFU&&e[28U]==0xFFFFFFFFU&&(e[13U]&4U)!=0U,"ISR counters saturate without clearing coverage warning");
  R19AuxReadinessRecordTestAccess::set_word(wrapped.ready,32U,0xFFFFFFFFU);
  R19AuxReadinessRecordTestAccess::set_word(wrapped.ready,39U,0xFFFFFFFFU);
  check(wrapped.ready.interval(R19ObservationInterval::PrivateReply,0U,1U,true)&&wrapped.ready.try_snapshot(s)&&s[32U]==0xFFFFFFFFU&&s[39U]==0xFFFFFFFFU&&(s[13U]&4U)!=0U,"USB interval counters saturate");
  R19AuxReadinessRecord empty{};const std::array<std::uint32_t,4U> zero_boot{};
  check(!empty.aux.initialize(R19RuntimeStageRole::Invalid,build,boot),"invalid role rejected");
  check(!empty.edges.initialize(R19RuntimeStageRole::Ground,build,zero_boot,0U,1U),"zero boot identity rejected");
  check(!empty.ready.event(R19ReadinessEvent::ClockFlushBegin,0U),"not initialized cannot record readiness");
  R19AuxReadinessRecord rejected{};initialize(rejected);
  check(rejected.ready.event(R19ReadinessEvent::ArmAccepted,0U,0U,1U,2U,0U),"rejected ARM result still recorded");
  check(rejected.ready.try_snapshot(s)&&(s[28U]&1U)==0U,"rejected ARM cannot become accepted ARM evidence");
  check(rejected.ready.event(R19ReadinessEvent::ReadyPublishEnd,1U,0U,1U,63U,0U),"failed READY publication return recorded");
  check(rejected.ready.try_snapshot(s)&&(s[28U]&2U)==0U,"failed READY publication cannot become success evidence");
  R19AuxReadinessRecord wide_clock{};initialize(wide_clock);
  check(wide_clock.aux.observe_gpio(5000000000000ULL,5000000000001ULL,0x100000001ULL,1U,1U),"64 bit supplied contract clock");
  check(wide_clock.aux.latch_fault(5000000000002ULL,5U,1U),"wide-clock first fault");
  check(wide_clock.aux.try_snapshot(a)&&a[30U]==1U&&a[108U]==1U&&a[64U]==1U&&a[92U]==1U,"full 64 bit supplied clock retained live and frozen");
}

void high_rate_intervals(){
  R19AuxReadinessRecord r{};initialize(r);Words s{};
  for(std::uint32_t n=0U;n<1000000U;++n)static_cast<void>(r.ready.interval(R19ObservationInterval::PrivateReply,n*20ULL,n*20ULL+17U,true));
  check(r.ready.try_snapshot(s)&&s[17U]==0U&&s[18U]==0U,"million USB loops cannot consume low rate event history");
  check(s[32U]==1000000U&&s[39U]==1000000U&&u64(s,37U)==17U,"USB interval count earlyreturn and max duration");
  check((s[13U]&8U)==0U,"aggregation is not event history overflow");
  check(r.ready.interval(R19ObservationInterval::AliveDrain,20000000U,20000010U,false),"other USB interval comparison");
  check(r.ready.try_snapshot(s)&&s[56U]==1U&&s[63U]==0U&&u64(s,61U)==10U,"other execution interval aggregate");
  check(u64(s,40U)==0U&&u64(s,42U)==17U,"maximum-duration interval timestamps survive million shorter intervals");
  check(r.ready.interval(R19ObservationInterval::PrivateReply,20000011U,20000041U,true),"longest private-reply interval");
  check(r.ready.interval(R19ObservationInterval::PrivateReply,20000042U,20000043U,false),"later shorter private-reply interval");
  check(r.ready.try_snapshot(s)&&u64(s,37U)==30U&&u64(s,40U)==20000011U&&u64(s,42U)==20000041U,"maximum interval start/end frozen independently of latest interval");
}

void comparison_hypotheses(){
  R19AuxReadinessRecord busy{},late{},normal{};initialize(busy);initialize(late);initialize(normal);Words b{},l{},n{},be{},le{},ne{};
  check(busy.aux.observe_uart(100U,110U,32U,32U,1U)&&late.aux.observe_uart(100U,110U,32U,32U,1U)&&normal.aux.observe_uart(100U,110U,32U,32U,1U),"all hypotheses UART accepted");
  check(busy.edges.observe_edge(111U,0U)&&late.edges.observe_edge(111U,0U)&&normal.edges.observe_edge(111U,0U),"all hypotheses LOW edge");
  check(busy.aux.observe_gpio(112U,113U,0U,0U,1U)&&late.aux.observe_gpio(112U,113U,0U,0U,1U)&&normal.aux.observe_gpio(112U,113U,0U,0U,1U),"all hypotheses observed LOW");
  check(late.edges.observe_edge(1000U,1U)&&normal.edges.observe_edge(1000U,1U),"returning hypotheses HIGH edge");
  check(busy.aux.observe_gpio(2000112U,2000113U,2000U,0U,1U)&&late.aux.observe_gpio(2000112U,2000113U,2000U,1U,1U),"timeout-time observations");
  check(normal.aux.observe_gpio(1001U,1002U,1U,1U,1U)&&normal.aux.observe_gpio(16001U,16002U,16U,1U,1U),"normal observations at 15ms stable");
  check(busy.aux.latch_fault(2000114U,5U,1U)&&late.aux.latch_fault(2000114U,5U,1U),"same synthetic first fault");
  check(busy.aux.try_snapshot(b)&&late.aux.try_snapshot(l)&&normal.aux.try_snapshot(n),"hypothesis gpio evidence");
  check(busy.edges.try_snapshot(be)&&late.edges.try_snapshot(le)&&normal.edges.try_snapshot(ne),"hypothesis independent edge evidence");
  check(b[50U]==l[50U]&&b[31U]==0U&&l[31U]==1U,"same fault code does not identify physical cause");
  check(be[15U]==1U&&le[15U]==2U&&u64(le,26U)==1000U,"edge history distinguishes supplied synthetic traces");
  check(u64(l,28U)==1999999U&&u64(n,28U)==14999U,"observation delay quantitatively visible");
  check(n[44U]==0U&&u64(n,102U)==1001U,"normal case not assigned fault");
}

void unchanged_product_contract_threshold(){
  using vc_lora::E220WriteContract;using vc_lora::E220WriteFault;using vc_lora::E220WriteState;
  check(vc_lora::FixedFirmwareContract::aux_high_stable_ms==15U,"production HIGH stable condition remains 15ms");
  check(vc_lora::FixedFirmwareContract::aux_transition_timeout_ms==2000U,"production AUX timeout remains 2000ms");
  for(const std::uint32_t first_high_ms:{2085U,2086U}){
    E220WriteContract product{};R19AuxReadinessRecord r{};initialize(r);Words a{};
    check(!product.observe_aux(true,0U)&&product.observe_aux(true,15U),"real product initial HIGH ready");
    check(product.begin_write(32U),"real product 32 byte admission");
    const auto before_uart=static_cast<std::uint32_t>(product.state());
    check(r.aux.observe_uart(100000U,100001U,32U,32U,before_uart),"record real product UART acceptance");
    check(r.aux.observe_gpio(100002U,100003U,100U,0U,before_uart),"record product LOW GPIO bracket");
    check(product.report_write_result(32U,100U,false)==vc_lora::E220WriteDisposition::AcceptedAll,"product write accepted");
    check(r.aux.observe_state(100004U,before_uart,static_cast<std::uint32_t>(product.state()),0U),"record post UART state");
    const auto first_begin=static_cast<std::uint64_t>(first_high_ms)*1000U;
    auto before=static_cast<std::uint32_t>(product.state());
    check(r.aux.observe_gpio(first_begin,first_begin+1U,first_high_ms,1U,before),"record timeout-near first HIGH");
    static_cast<void>(product.observe_aux(true,first_high_ms));
    check(r.aux.observe_state(first_begin+2U,before,static_cast<std::uint32_t>(product.state()),static_cast<std::uint32_t>(product.fault())),"record first HIGH outcome");
    before=static_cast<std::uint32_t>(product.state());
    check(r.aux.observe_gpio(2100000U,2100001U,2100U,1U,before),"record timeout boundary GPIO");
    static_cast<void>(product.observe_aux(true,2100U));
    check(r.aux.observe_state(2100002U,before,static_cast<std::uint32_t>(product.state()),static_cast<std::uint32_t>(product.fault())),"record actual timeout boundary outcome");
    if(product.fault()!=E220WriteFault::None)check(r.aux.latch_fault(2100003U,static_cast<std::uint32_t>(product.fault()),static_cast<std::uint32_t>(product.state())),"record actual first product fault");
    check(r.aux.try_snapshot(a)&&u64(a,102U)==first_begin&&a[30U]==2100U,"same MCU trace retains first HIGH and exact contract milliseconds");
    const bool enough=first_high_ms==2085U;
    check(product.state()==(enough?E220WriteState::Ready:E220WriteState::FailClosed),"15 vs14 ms real product boundary unchanged");
    check(product.fault()==(enough?E220WriteFault::None:E220WriteFault::AuxDidNotReturnHigh),"real product fault reason not inferred from code alone");
    check((a[44U]!=0U)==!enough,"record failure only when product actually failed");
    check(product.take_write_completion()==enough,"product completion independent of diagnostic record");
  }
}
}

int main(int argc,char** argv){
  static_assert(sizeof(R19AuxReadinessRecord)==6144U);
  static_assert(sizeof(R19AuxObservationRecord)==2048U&&sizeof(R19AuxEdgeRecord)==2048U&&sizeof(R19UsbReadinessRecord)==2048U);
  static_assert(std::is_standard_layout_v<R19AuxReadinessRecord>);
  static_assert(offsetof(R19AuxReadinessRecord,edges)==2048U&&offsetof(R19AuxReadinessRecord,ready)==4096U);
  basic_and_fault();uncertainty_overflow_and_saturation();high_rate_intervals();comparison_hypotheses();unchanged_product_contract_threshold();
  if(argc==3&&(std::string{argv[1]}=="--fixture"||std::string{argv[1]}=="--empty-fixture"||std::string{argv[1]}=="--overflow-fixture")){
    R19AuxReadinessRecord r{};initialize(r);
    if(std::string{argv[1]}=="--overflow-fixture"){
      for(std::uint32_t i=0U;i<61U;++i)check(r.aux.observe_gpio(100U+2U*i,101U+2U*i,i,i%2U,1U),"overflow fixture GPIO");
      for(std::uint32_t i=0U;i<121U;++i)check(r.edges.observe_edge(1000U+i,i%2U),"overflow fixture edge");
      for(std::uint32_t i=0U;i<55U;++i)check(r.ready.event(R19ReadinessEvent::GateUpdate,2000U+i,1U,3U,1U,7U),"overflow fixture readiness");
    }else if(std::string{argv[1]}=="--fixture"){
    check(r.aux.observe_uart(100U,110U,32U,32U,1U),"fixture UART");check(r.aux.observe_gpio(111U,112U,0U,0U,1U),"fixture LOW");
    check(r.edges.observe_edge(111U,0U)&&r.edges.observe_edge(1000U,1U),"fixture edges");check(r.aux.observe_gpio(2000111U,2000112U,2000U,1U,1U),"fixture late HIGH");check(r.aux.latch_fault(2000113U,5U,1U),"fixture fault");
    check(r.ready.event(R19ReadinessEvent::ClockFlushContext,2099999U,100U,7U,2200000U,0U),"fixture flush budget and absolute deadline");
    check(r.ready.event(R19ReadinessEvent::ClockFlushBegin,2100000U,1U,7U,28U,28U)&&r.ready.event(R19ReadinessEvent::ClockFlushEnd,2100100U,1U,7U,1U,0U),"fixture clock response");
    check(r.ready.event(R19ReadinessEvent::GateUpdate,2100101U,1U,3U,1U,7U)&&r.ready.event(R19ReadinessEvent::ReadyEncode,2100102U,1U,1U,7U,63U),"fixture gate and encode");
    check(r.ready.event(R19ReadinessEvent::ReadyPublishEnd,2100103U,1U,7U,63U,0U)&&r.ready.event(R19ReadinessEvent::ArmAccepted,2100104U,1U,7U,3U,0U),"fixture publish and ARM");
    }
    Words w{};std::ofstream out{argv[2],std::ios::binary|std::ios::trunc};
    for(auto section:{0U,1U,2U}){bool ok=section==0U?r.aux.try_snapshot(w):section==1U?r.edges.try_snapshot(w):r.ready.try_snapshot(w);check(ok,"fixture snapshot");for(auto v:w){for(unsigned k=0;k<4U;++k)out.put(static_cast<char>(v>>(8U*k)));}}
    check(static_cast<bool>(out),"fixture file written");
  }
  std::cout<<"R19_AUX_READINESS_RECORD "<<(failures?"FAIL":"PASS")<<" checks="<<checks<<" failures="<<failures<<'\n';return failures?1:0;
}
