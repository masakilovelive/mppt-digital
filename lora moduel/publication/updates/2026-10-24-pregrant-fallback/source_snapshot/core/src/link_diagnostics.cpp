#include "vc_lora/link_diagnostics.hpp"

#include "vc_lora/tdd_control_codec.hpp"

namespace vc_lora {

void LinkDiagnostics::clear() noexcept { *this = LinkDiagnostics{}; }

void LinkDiagnostics::note_decode_status(DecodeStatus status) noexcept {
  switch (status) {
    case DecodeStatus::BadCrc:
      ++control_crc_errors;
      break;
    case DecodeStatus::UnknownVersion:
      ++control_unknown_version;
      break;
    case DecodeStatus::UnknownType:
      ++control_unknown_type;
      break;
    case DecodeStatus::Malformed:
      ++control_malformed;
      break;
    case DecodeStatus::NeedMore:
    case DecodeStatus::Message:
      break;
  }
}

}  // namespace vc_lora
