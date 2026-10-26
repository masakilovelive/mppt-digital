#pragma once
#include "r19_grant_reservation_stop_record.hpp"

namespace vc_lora::experimental {
// Separate diagnostic ABI: it neither extends STOP128 nor reuses journal512.
enum class R19GrantReservationCancelBlockReason : std::uint32_t {
  None=0U,Unavailable=1U,HoldExpired=2U,ActionUnavailable=3U,UartAccepted=4U,
  Releasing=5U,RadioBusy=6U,PendingAction=7U,TailPending=8U,ActionTypeMismatch=9U,
  LeaseInvalid=10U,LeaseOwnerMismatch=11U,TokenMismatch=12U,GenerationMismatch=13U,
  EpochMismatch=14U,NotHolding=15U,TddOrWriterReleaseRejected=16U,
  BeginCancelRejected=17U,NotHeartbeatOnlyConflict=18U
};
struct R19GrantReservationFatalContext final {
  static constexpr std::uint32_t cancellation_supported=1U;
  static constexpr std::uint32_t cancellation_available=2U;
  static constexpr std::uint32_t cancellation_pending=4U;
  static constexpr std::uint32_t holding=8U;
  static constexpr std::uint32_t agreement_committed=16U;
  static constexpr std::uint32_t uart_accepted=32U;
  static constexpr std::uint32_t releasing=64U;
  static constexpr std::uint32_t epoch_matches=128U;
  static constexpr std::uint32_t action_valid=256U;
  std::uint32_t flags{0U},cancellation_phase{0U};
  R19GrantReservationCancelBlockReason cancel_block_reason{R19GrantReservationCancelBlockReason::None};
};
class alignas(4) R19GrantReservationFatalRecord final {
 public:
  volatile std::uint32_t words[32U]{};
  bool initialize(R19GrantReservationRole role,const std::array<std::uint32_t,4U>& build,
                  const std::array<std::uint32_t,4U>& boot) noexcept {
    if(words[2U]!=0U || !r19_grant_reservation_detail::valid_role(role) ||
       (build[0U]|build[1U]|build[2U]|build[3U])==0U || (boot[0U]|boot[1U])==0U) return false;
    words[0U]=1U;words[1U]=1U;words[2U]=0x52314654U;words[3U]=1U;
    words[4U]=static_cast<std::uint32_t>(role);
    for(std::size_t i=0U;i<4U;++i){words[5U+i]=build[i];words[9U+i]=boot[i];}
    words[13U]=1U;words[14U]=128U;words[1U]=2U;words[0U]=0U;return true;
  }
  // Caller supplies the pre-abort/pre-cancellation snapshot. Only the first
  // reserved-Grant detail13 fatal is covered, never other runtime fail sites.
  bool latch(const R19GrantReservationStopSnapshot& s,
             const R19GrantReservationFatalContext& c) noexcept {
    const auto reason=r19_grant_reservation_stop_reason(s);
    if(words[0U]!=0U || words[1U]!=2U || words[2U]!=0x52314654U ||
       words[3U]!=1U || words[4U]!=2U || words[13U]!=1U ||
       reason==R19GrantReservationStopReason::None || (s.predicates&~0x1FFU)!=0U ||
       s.reserve_ms==0U || (c.flags&~0x1FFU)!=0U || c.cancellation_phase>3U ||
       static_cast<std::uint32_t>(c.cancel_block_reason)>18U) return false;
    words[0U]=1U;words[1U]=3U;words[13U]=7U|(c.flags<<8U);
    words[15U]=static_cast<std::uint32_t>(reason)|(13U<<8U)|
        (static_cast<std::uint32_t>(c.cancel_block_reason)<<16U)|(c.cancellation_phase<<24U);
    words[16U]=static_cast<std::uint32_t>(s.now_ms);words[17U]=static_cast<std::uint32_t>(s.now_ms>>32U);
    words[18U]=static_cast<std::uint32_t>(s.heartbeat_deadline_ms);words[19U]=static_cast<std::uint32_t>(s.heartbeat_deadline_ms>>32U);
    words[20U]=static_cast<std::uint32_t>(s.hold_deadline_ms);words[21U]=static_cast<std::uint32_t>(s.hold_deadline_ms>>32U);
    words[22U]=s.predicates;words[23U]=s.reserve_ms;
    words[24U]=s.expected_token;words[25U]=s.expected_generation;
    words[26U]=s.active_token;words[27U]=s.active_generation;words[28U]=s.active_owner;
    words[29U]=static_cast<std::uint32_t>(s.heartbeat_order);words[30U]=static_cast<std::uint32_t>(s.heartbeat_order>>32U);
    words[31U]=s.current_usb_epoch;words[1U]=4U;words[0U]=0U;return true;
  }
};
static_assert(sizeof(R19GrantReservationFatalRecord)==128U);
static_assert(alignof(R19GrantReservationFatalRecord)>=4U);
} // namespace vc_lora::experimental
