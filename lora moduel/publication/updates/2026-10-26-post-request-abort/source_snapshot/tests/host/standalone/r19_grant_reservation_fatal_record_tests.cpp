#include "high_speed/r19_grant_reservation_fatal_record.hpp"
#include <array>
#include <cstdint>
#include <iostream>

using namespace vc_lora::experimental;
namespace {
unsigned checks = 0U, failures = 0U;
void check(bool ok, const char* label) {
  ++checks;
  if (!ok) { ++failures; std::cerr << "FAIL " << label << '\n'; }
}
}
int main() {
  const std::array<std::uint32_t,4U> build{{1U,2U,3U,4U}}, boot{{5U,6U,7U,8U}};
  R19GrantReservationStopRecord first{};
  R19GrantReservationFatalRecord fatal{};
  check(sizeof(fatal) == 128U && alignof(decltype(fatal)) >= 4U, "independent128B ABI");
  check(first.initialize(R19GrantReservationRole::Vehicle,build,boot) &&
        fatal.initialize(R19GrantReservationRole::Vehicle,build,boot), "both records initialize");
  R19GrantReservationStopSnapshot stop{};
  stop.now_ms=36099U;stop.heartbeat_deadline_ms=38599U;stop.hold_deadline_ms=36716U;
  stop.reserve_ms=5050U;stop.predicates=15U|0xE00U;stop.expected_token=1U;
  stop.expected_generation=1U;stop.active_token=1U;stop.active_generation=1U;stop.active_owner=1U;
  check(first.latch(stop,true), "first SAFE_CANCEL preserved");
  R19GrantReservationFatalContext context{};
  context.flags=R19GrantReservationFatalContext::cancellation_supported |
      R19GrantReservationFatalContext::holding | R19GrantReservationFatalContext::agreement_committed |
      R19GrantReservationFatalContext::epoch_matches | R19GrantReservationFatalContext::action_valid;
  context.cancellation_phase=3U;
  context.cancel_block_reason=R19GrantReservationCancelBlockReason::Unavailable;
  stop.now_ms=37100U;stop.heartbeat_deadline_ms=39600U;stop.hold_deadline_ms=37402U;
  stop.predicates=15U;stop.expected_token=3U;stop.expected_generation=3U;
  stop.active_token=3U;stop.active_generation=3U;
  check(fatal.latch(stop,context), "independent first fatal captures later HB conflict");
  check(first.words[13U]==15U && first.words[16U]==36099U && first.words[20U]==36716U,
        "fatal does not alter first SAFE_CANCEL");
  check(fatal.words[2U]==0x52314654U && fatal.words[3U]==1U && fatal.words[14U]==128U &&
        fatal.words[16U]==37100U && fatal.words[18U]==39600U && fatal.words[20U]==37402U,
        "fatal has distinctmagic and exact same-MCU deadlines");
  check((fatal.words[15U]&0xFFU)==2U && ((fatal.words[15U]>>8U)&0xFFU)==13U &&
        ((fatal.words[15U]>>16U)&0xFFU)==1U && (fatal.words[15U]>>24U)==3U,
        "fatal packs stopreason detail13 cancelblock phase unambiguously");
  const auto sequence=fatal.words[1U];
  stop.now_ms=38000U;stop.predicates=0U;
  check(!fatal.latch(stop,context) && fatal.words[1U]==sequence && fatal.words[16U]==37100U,
        "later fault never overwrites first fatal");
  R19GrantReservationFatalRecord ground{};
  check(ground.initialize(R19GrantReservationRole::Ground,build,boot) &&
        !ground.latch(stop,context) && ground.words[1U]==2U, "Ground remains valid unlatched");
  R19GrantReservationFatalRecord invalid{};
  check(!invalid.initialize(R19GrantReservationRole::Invalid,build,boot), "invalid role rejected");
  check(invalid.initialize(R19GrantReservationRole::Vehicle,build,boot), "valid initialization after rejected input");
  stop.predicates=12U;
  check(!invalid.latch(stop,context), "healthy predicate cannot become fatal");
  stop.predicates=15U|0xE00U;
  check(!invalid.latch(stop,context), "safe-cancellation retirement bits rejected by fatal-only record");
  stop.predicates=15U;context.flags|=0x80000000U;
  check(!invalid.latch(stop,context), "unknown context flags rejected");
  std::cout << "fatal128 checks=" << checks << " failures=" << failures << '\n';
  return failures==0U?0:1;
}
