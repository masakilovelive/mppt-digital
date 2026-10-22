#include "vc_lora/runtime_contract.hpp"
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <vector>
using namespace vc_lora;
struct Sample { std::uint64_t ms; bool high; };
struct Case {
  const char* name;
  const char* assumed_physical_waveform;
  std::vector<Sample> samples;
  E220WriteState expected_state;
  E220WriteFault expected_fault;
  bool expected_complete;
  bool uart_aux_high{false};
};
int main() {
  try {
    const std::vector<Case> cases {
      {"A_busy_continuously_low_dense",
       "synthetic LOW from100 through2100ms",
       {{650,false},{1100,false},{1600,false},{2099,false},{2100,false}},
       E220WriteState::FailClosed,E220WriteFault::AuxDidNotReturnHigh,false},
      {"B_returned_high_unobserved_until_timeout",
       "synthetic LOW100..119ms HIGH120..2100ms; no samples101..2099",
       {{2100,true}},
       E220WriteState::FailClosed,E220WriteFault::AuxDidNotReturnHigh,false},
      {"C_same_short_low_prompt_observation",
       "synthetic LOW100..119ms HIGH120..2100ms; HIGH first sampled120",
       {{120,true},{134,true},{135,true},{649,true},{650,true}},
       E220WriteState::Ready,E220WriteFault::None,true},
      {"D_high_first_seen_15ms_before_timeout",
       "synthetic LOW100..119ms HIGH120..2100ms; HIGH first sampled2085",
       {{2085,true},{2100,true}},
       E220WriteState::Ready,E220WriteFault::None,true},
      {"E_high_first_seen_14ms_before_timeout",
       "synthetic LOW100..119ms HIGH120..2100ms; HIGH first sampled2086",
       {{2086,true},{2100,true}},
       E220WriteState::FailClosed,E220WriteFault::AuxDidNotReturnHigh,false},
      {"F_first_high_one_ms_before_timeout",
       "synthetic LOW100..119ms HIGH120..2100ms; HIGH first sampled2099",
       {{2099,true},{2100,true}},
       E220WriteState::FailClosed,E220WriteFault::AuxDidNotReturnHigh,false},
      {"G_first_high_after_timeout",
       "synthetic LOW100..119ms HIGH120..2101ms; HIGH first sampled2101",
       {{2101,true}},
       E220WriteState::FailClosed,E220WriteFault::AuxDidNotReturnHigh,false},
      {"H_prior_high_observation_then_long_gap",
       "synthetic LOW100..119ms HIGH120..2100ms; HIGH sampled200 then2100",
       {{200,true},{2100,true}},
       E220WriteState::Ready,E220WriteFault::None,true},
      {"I_prior_high_then_sample_after_nominal_timeout",
       "synthetic LOW100..119ms HIGH120..2110ms; HIGH samples2090 and2110",
       {{2090,true},{2110,true}},
       E220WriteState::Ready,E220WriteFault::None,true},
      {"J_short_low_never_observed",
       "synthetic HIGH100 LOW110..119ms HIGH120..2100ms; LOW never sampled",
       {{2100,true}},
       E220WriteState::Ready,E220WriteFault::None,true,true}
    };
    unsigned checks=0;
    auto check=[&](bool ok,const char* why){++checks;if(!ok)throw std::runtime_error(why);};
    check(FixedFirmwareContract::aux_transition_timeout_ms==2000U,"timeout changed");
    check(FixedFirmwareContract::aux_high_stable_ms==15U,"HIGH stable changed");
    check(FixedFirmwareContract::e220_subpacket_service_floor_ms==550U,"floor changed");
    std::cout<<"{\n\"schema\":\"vc-lora-aux-busy-observation-probe-v1\",\n"
       "\"hardware_interaction\":false,\n"
       "\"physical_waveforms_are_assumptions_not_measurements\":true,\n"
       "\"product_code_modified\":false,\n\"cases\":[\n";
    bool first=true;
    for(const auto& test:cases) {
      E220WriteContract c{};
      check(!c.observe_aux(true,0),"initial HIGH ready too early");
      check(c.observe_aux(true,15),"initial HIGH stabilization failed");
      check(c.begin_write(32),"32byte write admission failed");
      check(c.report_write_result(32,100,test.uart_aux_high)==E220WriteDisposition::AcceptedAll,
          "full UART API result not accepted");
      check(c.state()==(test.uart_aux_high ? E220WriteState::AwaitingAuxLow : E220WriteState::AwaitingAuxHigh),"wrong post-write state");
      std::uint64_t previous=100,maxgap=0,first_high=test.uart_aux_high?100U:0U,last=100;
      bool level=false;
      std::size_t sampleIndex=0U;
      for(const auto& sample:test.samples) {
        check(sample.ms>=previous,"nonmonotonic fixture");
        if(sample.ms-previous>maxgap)maxgap=sample.ms-previous;
        previous=last=sample.ms; level=sample.high;
        if(sample.high&&first_high==0)first_high=sample.ms;
        (void)c.observe_aux(sample.high,sample.ms);
        if(++sampleIndex < test.samples.size()) {
          check(c.state()==E220WriteState::AwaitingAuxHigh && c.fault()==E220WriteFault::None,"intermediate state must remain pending");
          check(!c.take_write_completion(),"intermediate sample completed too early");
        }
      }
      const bool completed=c.take_write_completion();
      check(c.state()==test.expected_state,"unexpected state");
      check(c.fault()==test.expected_fault,"unexpected fault");
      check(completed==test.expected_complete,"unexpected completion");
      check(!c.take_write_completion(),"completion must be one-shot");
      if(c.fail_closed()) {
        check(!c.observe_aux(true,last+15U),"fault unexpectedly recovered");
        check(c.fail_closed() && c.fault()==test.expected_fault,"fault latch changed");
      }
      if(!first)std::cout<<",\n"; first=false;
      std::cout<<"{\"name\":\""<<test.name<<"\",\"assumed_physical_waveform\":\""
        <<test.assumed_physical_waveform<<"\",\"observations\":[";
      bool first_sample=true;
      std::cout<<"{\"ms\":100,\"aux_high\":"<<(test.uart_aux_high?"true":"false")<<",\"kind\":\"UART_RESULT\"}";
      first_sample=false;
      for(const auto& sample:test.samples) {
        if(!first_sample)std::cout<<",";
        first_sample=false;
        std::cout<<"{\"ms\":"<<sample.ms<<",\"aux_high\":"
          <<(sample.high?"true":"false")<<",\"kind\":\"OBSERVE_AUX\"}";
      }
      std::cout<<"],\"max_sample_gap_ms\":"<<maxgap
        <<",\"first_high_observed_ms\":";
      if(first_high)std::cout<<first_high;else std::cout<<"null";
      std::cout<<",\"last_sample_ms\":"<<last<<",\"last_sample_high\":"
        <<(level?"true":"false")<<",\"state\":"<<static_cast<unsigned>(c.state())
        <<",\"fault\":"<<static_cast<unsigned>(c.fault())
        <<",\"completion\":"<<(completed?"true":"false")<<"}";
    }
    check(cases[0].expected_fault==cases[1].expected_fault,
        "busy and observation-gap projection should match");
    std::cout<<"\n],\"checks\":"<<checks
      <<",\"result\":\"PASS_OFFLINE_DISCRIMINATION_NOT_HARDWARE_CAUSE\","
      "\"conclusion\":\"Fault5 alone cannot distinguish sustained physical LOW from insufficient HIGH observation. The waveform and real sample schedule of the recorded live failure are unmeasured.\"}\n";
    return 0;
  } catch(const std::exception& e) {
    std::cerr<<"PROBE_FAILED "<<e.what()<<"\n";
    return 1;
  }
}

