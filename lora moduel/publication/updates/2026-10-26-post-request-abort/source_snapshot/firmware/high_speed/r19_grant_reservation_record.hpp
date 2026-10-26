#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include "r19_grant_reservation.hpp"

namespace vc_lora::experimental {

// Separate diagnostic ABI. No reserved word of any existing record is reused.
// Words0..31 header; words32..127 twelve chronological journal entries of eight
// words (first8/last4). Entire record freezes at first controller failure.
class alignas(4) R19GrantReservationRecord final {
 public:
  volatile std::uint32_t words[128U]{};

  bool initialize(R19GrantReservationRole role,
      const std::array<std::uint32_t,4U>& build,
      const std::array<std::uint32_t,4U>& boot) noexcept {
    if(words[2U]==0x52313952U || !r19_grant_reservation_detail::valid_role(role) ||
       (build[0U]|build[1U]|build[2U]|build[3U])==0U ||
       (boot[0U]|boot[1U])==0U) return false;
    words[0U]=1U;words[1U]=1U;
    for(std::size_t i=2U;i<128U;++i) words[i]=0U;
    words[2U]=0x52313952U;words[3U]=1U;words[4U]=static_cast<std::uint32_t>(role);
    for(std::size_t i=0U;i<4U;++i){words[5U+i]=build[i];words[9U+i]=boot[i];}
    words[13U]=1U;words[14U]=512U;words[18U]=boot[0U];words[19U]=boot[1U];
    words[1U]=2U;words[0U]=0U;return true;
  }

  bool observe(const R19GrantReservationSnapshot& s) noexcept {
    if(words[2U]!=0x52313952U || words[0U]!=0U || (words[1U]&1U)!=0U ||
       !s.initialized || words[4U]!=static_cast<std::uint32_t>(s.role) ||
       s.own_boot_id!=(static_cast<std::uint64_t>(words[9U])|
                      (static_cast<std::uint64_t>(words[10U])<<32U)) ||
       static_cast<std::uint32_t>(s.state)>14U || static_cast<std::uint32_t>(s.reason)>21U ||
       s.journal_count>12U || s.event_count!=static_cast<std::uint32_t>(s.journal_count)+s.journal_dropped ||
       (s.journal_dropped!=0U && s.journal_count!=12U) ||
       (s.frozen!=(s.state==R19GrantReservationState::Failed)) ||
       (s.frozen!=(s.reason!=R19GrantReservationReason::None))) return false;
    for(std::size_t i=0U;i<s.journal_count;++i) {
      const auto& entry=s.journal[i];
      const auto state=entry.state_reason&0xFFFFU;
      const auto reason=entry.state_reason>>16U;
      const bool failure=entry.event==15U;
      if(entry.event==0U || entry.event>15U || state>14U || reason>21U ||
         (i!=0U && entry.timestamp_ms<s.journal[i-1U].timestamp_ms) ||
         failure!=(state==14U) || failure!=(reason!=0U) ||
         (failure && (!s.frozen || i+1U!=s.journal_count))) return false;
    }
    if(s.journal_count!=0U && s.journal[s.journal_count-1U].state_reason!=
       (static_cast<std::uint32_t>(s.state)|(static_cast<std::uint32_t>(s.reason)<<16U))) return false;
    if(words[13U]==7U) return true;
    const auto state_reason=static_cast<std::uint32_t>(s.state)|
        (static_cast<std::uint32_t>(s.reason)<<16U);
    if(words[16U]==s.event_count && words[15U]==state_reason &&
       words[22U]==s.own_epoch && words[23U]==s.peer_epoch &&
       words[26U]==static_cast<std::uint32_t>(s.reader_session) &&
       words[27U]==static_cast<std::uint32_t>(s.reader_session>>32U)) return true;
    if(words[1U]>std::numeric_limits<std::uint32_t>::max()-2U) return false;
    if(s.frozen && (s.journal_count==0U || s.journal[s.journal_count-1U].event!=15U)) return false;
    const auto next_sequence=words[1U]+2U;
    words[0U]=1U;words[1U]=next_sequence-1U;
    words[13U]=s.frozen?7U:1U;words[15U]=state_reason;words[16U]=s.event_count;
    words[17U]=static_cast<std::uint32_t>(s.journal_count)|(static_cast<std::uint32_t>(s.journal_dropped)<<16U);
    words[18U]=static_cast<std::uint32_t>(s.own_boot_id);words[19U]=static_cast<std::uint32_t>(s.own_boot_id>>32U);
    words[20U]=static_cast<std::uint32_t>(s.peer_boot_id);words[21U]=static_cast<std::uint32_t>(s.peer_boot_id>>32U);
    words[22U]=s.own_epoch;words[23U]=s.peer_epoch;
    words[24U]=static_cast<std::uint32_t>(s.slot_nonce);words[25U]=static_cast<std::uint32_t>(s.slot_nonce>>32U);
    words[26U]=static_cast<std::uint32_t>(s.reader_session);words[27U]=static_cast<std::uint32_t>(s.reader_session>>32U);
    words[28U]=static_cast<std::uint32_t>(s.grant_session)|(static_cast<std::uint32_t>(s.grant_cycle)<<16U);
    words[29U]=s.action_token;words[30U]=s.writer_generation;words[31U]=0U;
    for(std::size_t i=0U;i<12U;++i) {
      const auto offset=32U+8U*i;
      const auto entry=i<s.journal_count?s.journal[i]:R19GrantReservationJournalEntry{};
      words[offset]=entry.event;words[offset+1U]=entry.state_reason;
      words[offset+2U]=static_cast<std::uint32_t>(entry.timestamp_ms);
      words[offset+3U]=static_cast<std::uint32_t>(entry.timestamp_ms>>32U);
      words[offset+4U]=entry.grant_tuple;words[offset+5U]=entry.action_token;
      words[offset+6U]=entry.writer_generation;words[offset+7U]=entry.aux;
    }
    words[1U]=next_sequence;words[0U]=0U;return true;
  }
};
static_assert(sizeof(R19GrantReservationRecord)==512U);
static_assert(alignof(R19GrantReservationRecord)>=4U);
} // namespace vc_lora::experimental
