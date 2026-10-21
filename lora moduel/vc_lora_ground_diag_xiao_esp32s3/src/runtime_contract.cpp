#include "vc_lora/runtime_contract.hpp"

#include <limits>

namespace vc_lora {

BootSessionProvisioner::BootSessionProvisioner(
    BootSessionIdentity previous, bool persistent_read_succeeded) noexcept {
  if (!persistent_read_succeeded) {
    return;
  }
  candidate_ = next_boot_session(previous);
  status_ = BootSessionStatus::AwaitingPersistence;
  fault_ = BootSessionFault::None;
}

void BootSessionProvisioner::confirm_persisted(bool succeeded) noexcept {
  if (status_ != BootSessionStatus::AwaitingPersistence) {
    return;
  }
  if (succeeded) {
    status_ = BootSessionStatus::Ready;
    return;
  }
  status_ = BootSessionStatus::FailClosed;
  fault_ = BootSessionFault::PersistentWriteFailed;
}

bool BootSessionProvisioner::lease(BootSessionIdentity& output) const noexcept {
  if (status_ != BootSessionStatus::Ready) {
    return false;
  }
  output = candidate_;
  return true;
}

bool MonotonicMillis32::sample(std::uint32_t raw_ms,
                               std::uint64_t& output_ms) noexcept {
  if (status_ == MonotonicTimeStatus::FailClosed) {
    return false;
  }
  if (status_ == MonotonicTimeStatus::Uninitialized) {
    previous_raw_ms_ = raw_ms;
    extended_ms_ = raw_ms;
    status_ = MonotonicTimeStatus::Valid;
    output_ms = extended_ms_;
    return true;
  }

  const std::uint32_t delta = raw_ms - previous_raw_ms_;
  if (delta > max_sample_gap_ms) {
    status_ = MonotonicTimeStatus::FailClosed;
    fault_ = MonotonicTimeFault::AmbiguousOrBackward;
    return false;
  }
  if (extended_ms_ > std::numeric_limits<std::uint64_t>::max() - delta) {
    status_ = MonotonicTimeStatus::FailClosed;
    fault_ = MonotonicTimeFault::ExtendedOverflow;
    return false;
  }
  extended_ms_ += delta;
  previous_raw_ms_ = raw_ms;
  output_ms = extended_ms_;
  return true;
}

bool E220WriteContract::accept_time(std::uint64_t now_ms) noexcept {
  if (has_time_ && now_ms < last_time_ms_) {
    latch_fault(E220WriteFault::NonMonotonicTime);
    return false;
  }
  last_time_ms_ = now_ms;
  has_time_ = true;
  return true;
}

void E220WriteContract::set_aux(bool aux_high,
                                std::uint64_t now_ms) noexcept {
  aux_high_ = aux_high;
  if (!aux_high) {
    tracking_high_ = false;
    return;
  }
  if (!tracking_high_) {
    tracking_high_ = true;
    high_since_ms_ = now_ms;
  }
}

void E220WriteContract::latch_fault(E220WriteFault fault) noexcept {
  if (state_ == E220WriteState::FailClosed) {
    return;
  }
  fault_ = fault;
  state_ = E220WriteState::FailClosed;
  requested_bytes_ = 0U;
  completion_pending_ = false;
}

bool E220WriteContract::observe_aux(bool aux_high,
                                    std::uint64_t now_ms) noexcept {
  if (state_ == E220WriteState::FailClosed || !accept_time(now_ms)) {
    return false;
  }

  set_aux(aux_high, now_ms);
  switch (state_) {
    case E220WriteState::WaitingForStableHigh:
      if (aux_high &&
          now_ms - high_since_ms_ >=
              FixedFirmwareContract::aux_high_stable_ms) {
        state_ = E220WriteState::Ready;
      }
      break;

    case E220WriteState::Ready:
      if (!aux_high) {
        state_ = E220WriteState::WaitingForStableHigh;
      }
      break;

    case E220WriteState::AwaitingWriteResult:
      // HardwareSerial::write() is synchronous.  The result call supplies a
      // fresh AUX sample, so no state transition is made here.
      break;

    case E220WriteState::AwaitingAuxLow:
      if (!aux_high) {
        state_ = E220WriteState::AwaitingAuxHigh;
        state_since_ms_ = now_ms;
      } else if (now_ms - state_since_ms_ >=
                 FixedFirmwareContract::min_tx_gap_ms) {
        state_ = E220WriteState::Ready;
        requested_bytes_ = 0U;
        completion_pending_ = true;
      }
      break;

    case E220WriteState::AwaitingAuxHigh:
      if (aux_high &&
          now_ms - high_since_ms_ >=
              FixedFirmwareContract::aux_high_stable_ms) {
        state_ = E220WriteState::Ready;
        requested_bytes_ = 0U;
        completion_pending_ = true;
      } else if (now_ms - state_since_ms_ >=
                 FixedFirmwareContract::aux_transition_timeout_ms) {
        latch_fault(E220WriteFault::AuxDidNotReturnHigh);
      }
      break;

    case E220WriteState::FailClosed:
      break;
  }
  return state_ == E220WriteState::Ready;
}

bool E220WriteContract::begin_write(std::size_t requested_bytes) noexcept {
  if (state_ == E220WriteState::FailClosed) {
    return false;
  }
  if (requested_bytes == 0U ||
      requested_bytes > FixedFirmwareContract::radio_chunk_bytes) {
    latch_fault(E220WriteFault::InvalidWriteSize);
    return false;
  }
  if (state_ != E220WriteState::Ready) {
    return false;
  }
  requested_bytes_ = requested_bytes;
  state_ = E220WriteState::AwaitingWriteResult;
  return true;
}

E220WriteDisposition E220WriteContract::report_write_result(
    std::size_t written_bytes, std::uint64_t now_ms, bool aux_high) noexcept {
  if (state_ == E220WriteState::FailClosed || !accept_time(now_ms)) {
    return E220WriteDisposition::ContractViolation;
  }
  if (state_ != E220WriteState::AwaitingWriteResult) {
    latch_fault(E220WriteFault::UnexpectedWriteResult);
    return E220WriteDisposition::ContractViolation;
  }
  set_aux(aux_high, now_ms);
  if (written_bytes == 0U) {
    requested_bytes_ = 0U;
    state_ = aux_high ? E220WriteState::Ready
                      : E220WriteState::WaitingForStableHigh;
    return E220WriteDisposition::Rejected;
  }
  if (written_bytes != requested_bytes_) {
    latch_fault(E220WriteFault::PartialWrite);
    return E220WriteDisposition::ContractViolation;
  }

  state_since_ms_ = now_ms;
  if (aux_high) {
    state_ = E220WriteState::AwaitingAuxLow;
  } else {
    state_ = E220WriteState::AwaitingAuxHigh;
  }
  return E220WriteDisposition::AcceptedAll;
}

bool E220WriteContract::take_write_completion() noexcept {
  const bool result = completion_pending_;
  completion_pending_ = false;
  return result;
}

void FirmwareStartupContract::latch_fault(
    FirmwareStartupFault fault) noexcept {
  if (fault_ == FirmwareStartupFault::None) {
    fault_ = fault;
  }
}

void FirmwareStartupContract::confirm_identity_persisted(
    bool succeeded) noexcept {
  if (fail_closed()) {
    return;
  }
  if (!succeeded) {
    latch_fault(FirmwareStartupFault::IdentityNotPersisted);
    return;
  }
  identity_persisted_ = true;
}

bool FirmwareStartupContract::verify_e220_profile(
    const std::uint8_t* profile, std::size_t size) noexcept {
  if (fail_closed()) {
    return false;
  }
  if (profile == nullptr || size != FixedFirmwareContract::e220_profile.size()) {
    latch_fault(FirmwareStartupFault::ProfileReadInvalid);
    return false;
  }
  for (std::size_t index = 0U; index < size; ++index) {
    if (profile[index] != FixedFirmwareContract::e220_profile[index]) {
      latch_fault(FirmwareStartupFault::ProfileMismatch);
      return false;
    }
  }
  profile_verified_ = true;
  return true;
}

bool FirmwareStartupContract::transmission_allowed() const noexcept {
  return !fail_closed() && identity_persisted_ && profile_verified_;
}

FirmwareStartupStatus FirmwareStartupContract::status() const noexcept {
  if (fail_closed()) {
    return FirmwareStartupStatus::FailClosed;
  }
  return transmission_allowed() ? FirmwareStartupStatus::Ready
                                : FirmwareStartupStatus::AwaitingChecks;
}

}  // namespace vc_lora
