#pragma once

#include "r19_grant_reservation.hpp"

namespace vc_lora::experimental {

// A separate, first-wins diagnostic ABI. It does not reinterpret or reuse any
// word in the existing 512-byte reservation journal, and grants no permission.
enum class R19GrantReservationStopReason : std::uint32_t {
  None=0U, ReservationFailed=1U, HeartbeatDeadlineConflict=2U, AuxLow=3U,
  LeaseInvalid=4U, LeaseOwnerMismatch=5U, ActionTokenMismatch=6U,
  WriterGenerationMismatch=7U, RadioBusy=8U, PendingRadioAction=9U,
  WriterTailPending=10U
};

struct R19GrantReservationStopSnapshot final {
  static constexpr std::uint32_t heartbeat_valid=1U<<0U;
  static constexpr std::uint32_t heartbeat_available=1U<<1U;
  static constexpr std::uint32_t aux_high=1U<<2U;
  static constexpr std::uint32_t lease_valid=1U<<3U;
  static constexpr std::uint32_t reservation_failed=1U<<4U;
  static constexpr std::uint32_t radio_busy=1U<<5U;
  static constexpr std::uint32_t pending_action=1U<<6U;
  static constexpr std::uint32_t tail_pending=1U<<7U;
  static constexpr std::uint32_t release_requested=1U<<8U;
  static constexpr std::uint32_t zero_uart_proven=1U<<9U;
  static constexpr std::uint32_t old_cycle_retired=1U<<10U;
  static constexpr std::uint32_t old_lease_retired=1U<<11U;
  std::uint64_t now_ms{0U},heartbeat_deadline_ms{0U},hold_deadline_ms{0U};
  std::uint64_t heartbeat_order{0U};
  std::uint32_t predicates{0U},reserve_ms{0U};
  std::uint32_t expected_token{0U},expected_generation{0U};
  std::uint32_t active_token{0U},active_generation{0U},active_owner{0U};
  std::uint32_t current_usb_epoch{0U};
};

constexpr R19GrantReservationStopReason r19_grant_reservation_stop_reason(
    const R19GrantReservationStopSnapshot& s) noexcept {
  using S=R19GrantReservationStopSnapshot;using R=R19GrantReservationStopReason;
  if((s.predicates&S::reservation_failed)!=0U) return R::ReservationFailed;
  if((s.predicates&(S::heartbeat_valid|S::heartbeat_available))==
      (S::heartbeat_valid|S::heartbeat_available) &&
      (s.heartbeat_deadline_ms<=s.now_ms ||
       s.heartbeat_deadline_ms-s.now_ms<=s.reserve_ms))
    return R::HeartbeatDeadlineConflict;
  if((s.predicates&S::aux_high)==0U) return R::AuxLow;
  if((s.predicates&S::lease_valid)==0U) return R::LeaseInvalid;
  if(s.active_owner!=1U) return R::LeaseOwnerMismatch;
  if(s.active_token!=s.expected_token) return R::ActionTokenMismatch;
  if(s.active_generation!=s.expected_generation) return R::WriterGenerationMismatch;
  if((s.predicates&S::radio_busy)!=0U) return R::RadioBusy;
  if((s.predicates&S::pending_action)!=0U) return R::PendingRadioAction;
  if((s.predicates&S::tail_pending)!=0U) return R::WriterTailPending;
  return R::None;
}

class alignas(4) R19GrantReservationStopRecord final {
 public:
  volatile std::uint32_t words[32U]{};
  bool initialize(R19GrantReservationRole role,
      const std::array<std::uint32_t,4U>& build,
      const std::array<std::uint32_t,4U>& boot) noexcept {
    if(words[2U]!=0U || !r19_grant_reservation_detail::valid_role(role) ||
       (build[0U]|build[1U]|build[2U]|build[3U])==0U ||
       (boot[0U]|boot[1U])==0U) return false;
    words[0U]=1U;words[1U]=1U;words[2U]=0x52315354U;words[3U]=1U;
    words[4U]=static_cast<std::uint32_t>(role);
    for(std::size_t i=0U;i<4U;++i){words[5U+i]=build[i];words[9U+i]=boot[i];}
    words[13U]=1U;words[14U]=128U;words[1U]=2U;words[0U]=0U;
    return true;
  }
  bool latch(const R19GrantReservationStopSnapshot& s,bool safe_cancel=false) noexcept {
    const auto reason=r19_grant_reservation_stop_reason(s);
    if(words[0U]!=0U || words[1U]!=2U || words[2U]!=0x52315354U ||
       words[3U]!=1U || words[4U]!=2U || words[13U]!=1U ||
       reason==R19GrantReservationStopReason::None ||
       (s.predicates&~0xFFFU)!=0U || s.reserve_ms==0U ||
       (safe_cancel && (reason!=R19GrantReservationStopReason::HeartbeatDeadlineConflict ||
        (s.predicates&0xE00U)!=0xE00U)) ||
       (!safe_cancel && (s.predicates&0xE00U)!=0U)) return false;
    words[0U]=1U;words[1U]=3U;words[13U]=safe_cancel?15U:7U;
    words[15U]=static_cast<std::uint32_t>(reason);
    words[16U]=static_cast<std::uint32_t>(s.now_ms);words[17U]=static_cast<std::uint32_t>(s.now_ms>>32U);
    words[18U]=static_cast<std::uint32_t>(s.heartbeat_deadline_ms);words[19U]=static_cast<std::uint32_t>(s.heartbeat_deadline_ms>>32U);
    words[20U]=static_cast<std::uint32_t>(s.hold_deadline_ms);words[21U]=static_cast<std::uint32_t>(s.hold_deadline_ms>>32U);
    words[22U]=s.predicates;words[23U]=s.reserve_ms;
    words[24U]=s.expected_token;words[25U]=s.expected_generation;
    words[26U]=s.active_token;words[27U]=s.active_generation;words[28U]=s.active_owner;
    words[29U]=static_cast<std::uint32_t>(s.heartbeat_order);words[30U]=static_cast<std::uint32_t>(s.heartbeat_order>>32U);
    words[31U]=s.current_usb_epoch;
    words[1U]=4U;words[0U]=0U;return true;
  }
};
static_assert(sizeof(R19GrantReservationStopRecord)==128U);
static_assert(alignof(R19GrantReservationStopRecord)>=4U);
} // namespace vc_lora::experimental
