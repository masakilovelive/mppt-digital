#include "high_speed/r19_diagnostic_usb_failure_record.hpp"
#include <array>
#include <cstdint>
#include <cstring>
#include <iostream>

namespace vc_lora::experimental {
struct R19DiagnosticUsbFailureRecordTestAccess {
  static void writer(R19DiagnosticUsbFailureRecord& r, std::uint32_t v) { r.words_[0U]=v; }
  static void sequence(R19DiagnosticUsbFailureRecord& r, std::uint32_t v) { r.words_[1U]=v; }
};
}

int main() {
  using namespace vc_lora::experimental;
  unsigned checks=0U, failures=0U;
  const auto check=[&](bool value,const char* message) {
    ++checks; if(!value){++failures;std::cerr<<"FAIL "<<message<<'\n';}
  };
  const R19RuntimeBuildFingerprint build{1U,2U,3U,4U};
  const std::array<std::uint32_t,4U> boot{5U,6U,7U,8U};
  R19DiagnosticUsbFailureRecord empty{};
  R19DiagnosticUsbFailureSnapshot snap{};
  check(empty.try_snapshot(snap) && !snap.valid_header(),"uninitialized snapshot remains invalid");
  check(!empty.initialize(R19RuntimeStageRole::Invalid,build,boot),"invalid role rejected");
  check(!empty.initialize(R19RuntimeStageRole::Ground,build,{}),"zero boot rejected");
  check(empty.initialize(R19RuntimeStageRole::Ground,build,boot),"Ground initialize");
  check(!empty.initialize(R19RuntimeStageRole::Ground,build,boot),"reinitialize rejected");
  check(empty.try_snapshot(snap) && snap.valid_header() && !snap.failure_latched() &&
      snap.boot_instance==boot && snap.build_fingerprint==build,"initialized identity preserved");
  check(sizeof(empty)==256U && alignof(R19DiagnosticUsbFailureRecord)==4U,"fixed256-byte ABI");

  R19DiagnosticUsbFailureEvidence good{};
  good.reason=16U; good.source_line=5037U; good.action=2U; good.diagnostic_sequence=1U;
  good.bootstrap_flags=0U; good.expected_epoch=7U; good.observed_epoch=7U;
  good.budget_ms=100U; good.attempt_id=5U; good.wrapper_flags=1U|4U|16U;
  good.started_us=9007199254741101ULL;good.finished_us=good.started_us+100001U;
  good.deadline_us=good.started_us+100000U;good.failure_observed_us=good.finished_us+12U;
  good.expected_frame_bytes=63U; good.accepted_frame_bytes=63U;
  good.sdk.schema=1U;good.sdk.validity_flags=1U|2U|4U|8U|16U|32U|64U;
  good.sdk.transaction_token=good.diagnostic_sequence+1U;good.sdk.attempt_id=good.attempt_id;
  good.sdk.terminal_reason=5U;good.sdk.timeout_ms=100U;good.sdk.expected_loss_epoch=7U;
  good.sdk.started_ms=0xfffffff0U;good.sdk.finished_ms=84U;good.sdk.elapsed_ms=100U;
  good.sdk.state_flags=0x2417U;good.sdk.observed_loss_epoch=7U;
  good.sdk.ring_pending_bytes=31U;good.sdk.stash_pending_bytes=1U;
  good.sdk.publish_generation=8U;good.sdk.pickup_generation=7U;
  good.sdk.flush_blocker_mask=0x1cU;good.sdk.snapshot_started_ms=84U;
  good.sdk.snapshot_finished_ms=84U;good.sdk.snapshot_duration_us=5U;
  const auto reject=[&](const R19DiagnosticUsbFailureEvidence& e,const char* message) {
    R19DiagnosticUsbFailureRecord r{};
    (void)r.initialize(R19RuntimeStageRole::Ground,build,boot);
    check(!r.latch_first_failure(e),message);
  };
  auto bad=good;bad.reason=0U;reject(bad,"zero reason rejected");
  bad=good;bad.action=4U;reject(bad,"unknown action rejected");
  bad=good;bad.wrapper_flags|=32U;reject(bad,"unknown wrapper flag rejected");
  bad=good;bad.accepted_frame_bytes=64U;reject(bad,"accepted byte overflow rejected");
  bad=good;bad.finished_us=bad.started_us-1U;reject(bad,"backward caller clocks rejected");
  bad=good;bad.failure_observed_us=bad.finished_us-1U;reject(bad,"failure before return rejected");
  bad=good;bad.wrapper_flags|=8U;reject(bad,"false within-deadline claim rejected");
  bad=good;bad.sdk.validity_flags|=256U;reject(bad,"unknown SDK flag rejected");
  bad=good;bad.sdk.terminal_reason=7U;reject(bad,"unknown SDK terminal rejected");
  bad=good;bad.sdk.state_flags|=0x4000U;reject(bad,"unknown FIFO flag rejected");
  bad=good;bad.sdk.flush_blocker_mask|=0x100U;reject(bad,"unknown wait reason rejected");
  bad=good;bad.sdk.attempt_id++;reject(bad,"matching flag cannot hide stale attempt");
  bad=good;bad.sdk.transaction_token++;reject(bad,"matching flag cannot hide stale ordinal");
  bad=good;bad.sdk.expected_loss_epoch++;reject(bad,"matching flag cannot hide stale epoch");
  bad=good;bad.sdk.timeout_ms++;reject(bad,"matching flag cannot hide stale budget");
  bad=good;bad.sdk.validity_flags&=~8U;reject(bad,"unobserved FIFO payload rejected");

  check(empty.latch_first_failure(good),"first complete terminal evidence latched");
  check(empty.try_snapshot(snap) && snap.failure_latched() &&
      snap.started_us==good.started_us && snap.finished_us==good.finished_us &&
      snap.failure_observed_us==good.failure_observed_us &&
      snap.sdk.ring_pending_bytes==31U && snap.sdk.flush_blocker_mask==0x1cU &&
      snap.attempt_id==5U && snap.diagnostic_sequence==1U,"all exact64-bit times and SDK terminal fields preserved");
  std::array<std::uint8_t,256U> saved{},after{};
  std::memcpy(saved.data(),&empty,saved.size());
  bad=good;bad.reason=18U;bad.diagnostic_sequence=9U;
  check(!empty.latch_first_failure(bad),"subsequent failure cannot overwrite first");
  std::memcpy(after.data(),&empty,after.size());
  check(saved==after,"immutable first failure record remains byte-identical");
  std::array<std::uint32_t,64U> words{};
  std::memcpy(words.data(),&empty,sizeof(empty));
  check(words[2U]==0x44313955U && words[14U]==16U && words[17U]==1U &&
      words[22U]==5U && words[32U]==1U && words[56U]==63U && words[57U]==63U,
      "agreed raw word offsets preserved");
  bool reserved_zero=true;
  for(std::size_t i=58U;i<64U;++i)reserved_zero=reserved_zero&&words[i]==0U;
  check(reserved_zero,"reserved tail remains zero");
  const auto old=snap;
  R19DiagnosticUsbFailureRecordTestAccess::writer(empty,1U);
  check(!empty.try_snapshot(snap,3U) && snap.sequence==old.sequence,
      "active writer rejected without altering output");
  R19DiagnosticUsbFailureRecordTestAccess::writer(empty,0U);
  R19DiagnosticUsbFailureRecordTestAccess::sequence(empty,5U);
  check(!empty.try_snapshot(snap,3U),"odd sequence rejected");
  R19DiagnosticUsbFailureRecordTestAccess::sequence(empty,6U);
  check(empty.try_snapshot(snap) && snap.failure_latched(),"even stable sequence accepted");

  R19DiagnosticUsbFailureRecord vehicle{};
  check(vehicle.initialize(R19RuntimeStageRole::Vehicle,build,boot) &&
      vehicle.latch_first_failure(good),"Vehicle diagnostic record supported independently of product Ground-only ABI");
  R19DiagnosticUsbFailureRecord stale{};
  (void)stale.initialize(R19RuntimeStageRole::Vehicle,build,boot);
  bad=good;bad.wrapper_flags&=~16U;bad.sdk.transaction_token=42U;bad.sdk.attempt_id=99U;
  check(stale.latch_first_failure(bad) && stale.try_snapshot(snap) &&
      !snap.sdk_context_matches(),"explicitly nonmatching SDK evidence retained but never bound as current call");
  R19DiagnosticUsbFailureRecord uncalled{};
  (void)uncalled.initialize(R19RuntimeStageRole::Vehicle,build,boot);
  R19DiagnosticUsbFailureEvidence no_call{};
  no_call.reason=10U;no_call.source_line=4744U;no_call.action=2U;
  no_call.failure_observed_us=100U;no_call.expected_frame_bytes=63U;
  check(uncalled.latch_first_failure(no_call) && uncalled.try_snapshot(snap) &&
      !snap.api_called() && !snap.sdk_context_matches(),"uncalled API records unknown result without invented snapshot");
  bad=no_call;bad.wrapper_flags=2U;reject(bad,"uncalled API cannot claim raw return");
  bad=no_call;bad.sdk.ring_pending_bytes=1U;reject(bad,"uncalled API cannot claim healthy or stale SDK payload");
  std::cout<<"R19-DIAGNOSTIC-USB-FAILURE-RECORD checks="<<checks
      <<" failures="<<failures<<'\n';
  return failures==0U?0:1;
}
