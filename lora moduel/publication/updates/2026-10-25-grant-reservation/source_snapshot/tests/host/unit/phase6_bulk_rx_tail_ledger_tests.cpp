#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

#include "../../../firmware/high_speed/phase6_bulk_rx_tail_ledger.hpp"
#include "test_support.hpp"
#include "vc_lora/bulk_data_codec.hpp"
#include "vc_lora/bulk_session_controller.hpp"
#include "vc_lora/mavlink_frame.hpp"

namespace vc_lora::test {
namespace {

using vc_lora::BulkDataStreamDecoder;
using vc_lora::BulkDataStreamStatus;
using vc_lora::BulkDataWireStatus;
using vc_lora::BulkSessionAccounting;
using vc_lora::EncodedBulkDataFrame;
using vc_lora::HighSpeedLocalRxRecordIdentity;
using vc_lora::MavlinkFrame;
using vc_lora::experimental::R19BulkRxTailLedger;
using vc_lora::experimental::R19BulkRxTailLedgerCounterSeed;
using vc_lora::experimental::R19BulkRxTailLedgerStatus;
using Report = TestReport;

constexpr std::uint32_t kTagOne = 0x13572468U;
constexpr std::uint32_t kTagTwo = 0x24681357U;

MavlinkFrame heartbeat(std::uint8_t sequence) {
  constexpr std::array<std::uint8_t, 9U> payload{
      {0U, 0U, 0U, 0U, 2U, 3U, 0U, 4U, 3U}};
  MavlinkFrame frame{};
  (void)vc_lora::encode_mavlink_v2(sequence, 1U, 1U, 0U, payload.data(),
                                   payload.size(), frame);
  return frame;
}

MavlinkFrame parameter_value(std::uint16_t parameter_index,
                             std::uint8_t sequence) {
  std::array<std::uint8_t, 25U> payload{};
  payload[4U] =
      static_cast<std::uint8_t>(BulkSessionAccounting::parameter_count & 0xFFU);
  payload[5U] = static_cast<std::uint8_t>(
      (BulkSessionAccounting::parameter_count >> 8U) & 0xFFU);
  payload[6U] = static_cast<std::uint8_t>(parameter_index & 0xFFU);
  payload[7U] = static_cast<std::uint8_t>(parameter_index >> 8U);
  payload[8U] = static_cast<std::uint8_t>('P');
  payload[9U] = static_cast<std::uint8_t>('0' + (parameter_index % 10U));
  payload[24U] = 9U;
  MavlinkFrame frame{};
  (void)vc_lora::encode_mavlink_v2(sequence, 1U, 1U, 22U, payload.data(),
                                   payload.size(), frame);
  return frame;
}

bool accept_frame(R19BulkRxTailLedger &ledger, BulkDataStreamDecoder &decoder,
                  const MavlinkFrame &frame, std::uint16_t &ordinal,
                  std::uint64_t &now_ms,
                  R19BulkRxTailLedgerStatus expected_tail, Report &report) {
  EncodedBulkDataFrame encoded{};
  if (vc_lora::encode_bulk_data_frame(frame, decoder.expected_transfer_tag(),
                                      ordinal, encoded) !=
      BulkDataWireStatus::FrameReady) {
    report.check(false, "fixture could not encode a complete VCB1 frame");
    return false;
  }
  MavlinkFrame decoded{};
  report.check(ledger.accept_decoder_fragment(decoder, encoded.fragments[0U],
                                              decoded, now_ms++) ==
                   R19BulkRxTailLedgerStatus::FragmentAccepted,
               "ledger rejected a decoder-accepted VCB1 head");
  const R19BulkRxTailLedgerStatus tail = ledger.accept_decoder_fragment(
      decoder, encoded.fragments[1U], decoded, now_ms++);
  report.check(tail == expected_tail,
               "ledger returned the wrong status for a VCB1 tail");
  ordinal = static_cast<std::uint16_t>(ordinal + 2U);
  return report.passed;
}

bool complete_session(R19BulkRxTailLedger &ledger,
                      BulkDataStreamDecoder &decoder,
                      std::uint32_t heartbeat_count, std::uint64_t &now_ms,
                      Report &report,
                      R19BulkRxTailLedgerStatus expected_final =
                          R19BulkRxTailLedgerStatus::FinalIdentityReady) {
  std::uint16_t ordinal = 0U;
  std::uint32_t heartbeat_index = 0U;
  for (std::uint16_t index = 0U; index < BulkSessionAccounting::parameter_count;
       ++index) {
    while (heartbeat_index < heartbeat_count &&
           index == (heartbeat_index * BulkSessionAccounting::parameter_count) /
                        heartbeat_count) {
      if (!accept_frame(
              ledger, decoder,
              heartbeat(static_cast<std::uint8_t>(heartbeat_index + 1U)),
              ordinal, now_ms, R19BulkRxTailLedgerStatus::FragmentAccepted,
              report)) {
        return false;
      }
      ++heartbeat_index;
    }
    const bool final = index + 1U == BulkSessionAccounting::parameter_count;
    if (!accept_frame(ledger, decoder,
                      parameter_value(index, static_cast<std::uint8_t>(index)),
                      ordinal, now_ms,
                      final ? expected_final
                            : R19BulkRxTailLedgerStatus::FragmentAccepted,
                      report)) {
      return false;
    }
  }
  return decoder.complete() && !decoder.latched();
}

void test_positive_and_monotonic_rearm(Report &report) {
  R19BulkRxTailLedger ledger{};
  BulkDataStreamDecoder first_decoder{kTagOne};
  constexpr std::uint32_t first_fragments =
      BulkSessionAccounting::parameter_fragment_count + 6U;
  std::uint64_t now_ms = 10U;
  report.check(ledger.arm(kTagOne, now_ms++) ==
                   R19BulkRxTailLedgerStatus::Armed,
               "ledger did not arm for a nonzero negotiated tag");
  report.check(complete_session(ledger, first_decoder, 3U, now_ms, report),
               "first decoder corpus did not complete");
  HighSpeedLocalRxRecordIdentity first{};
  report.check(
      ledger.issue_final_identity(first, now_ms++) ==
              R19BulkRxTailLedgerStatus::IdentityIssued &&
          first.transfer_tag == kTagOne &&
          first.final_wire_ordinal + 1U == first_fragments &&
          first.fragment_count == first_fragments &&
          R19BulkRxTailLedger::is_local_rx_token(first.rx_record_token) &&
          R19BulkRxTailLedger::is_local_rx_generation(
              first.rx_ledger_generation),
      "ledger did not issue exact local-domain final identity");

  BulkDataStreamDecoder second_decoder{kTagTwo};
  report.check(ledger.arm(kTagTwo, now_ms++) ==
                   R19BulkRxTailLedgerStatus::Armed,
               "issued ledger could not arm a fresh tag");
  report.check(complete_session(ledger, second_decoder, 0U, now_ms, report),
               "second decoder corpus did not complete");
  HighSpeedLocalRxRecordIdentity second{};
  report.check(ledger.issue_final_identity(second, now_ms++) ==
                       R19BulkRxTailLedgerStatus::IdentityIssued &&
                   second.rx_record_token > first.rx_record_token &&
                   second.rx_ledger_generation > first.rx_ledger_generation,
               "local RX token/generation did not increase across sessions");
}

EncodedBulkDataFrame encoded_heartbeat(std::uint32_t tag, std::uint16_t ordinal,
                                       Report &report) {
  EncodedBulkDataFrame encoded{};
  report.check(
      vc_lora::encode_bulk_data_frame(heartbeat(2U), tag, ordinal, encoded) ==
          BulkDataWireStatus::FrameReady,
      "negative fixture could not encode heartbeat");
  return encoded;
}

void test_invalid_fragments_fail_closed(Report &report) {
  {
    R19BulkRxTailLedger ledger{};
    BulkDataStreamDecoder decoder{kTagOne};
    EncodedBulkDataFrame encoded = encoded_heartbeat(kTagOne, 0U, report);
    encoded.fragments[0U][15U] ^= 0x40U;
    MavlinkFrame output{};
    report.check(ledger.arm(kTagOne, 1U) == R19BulkRxTailLedgerStatus::Armed &&
                     ledger.accept_decoder_fragment(
                         decoder, encoded.fragments[0U], output, 2U) ==
                         R19BulkRxTailLedgerStatus::InvalidFragment &&
                     ledger.fail_closed() && decoder.next_wire_ordinal() == 0U,
                 "bad CRC advanced the ledger or decoder");
  }
  {
    R19BulkRxTailLedger ledger{};
    BulkDataStreamDecoder decoder{kTagOne};
    const EncodedBulkDataFrame encoded = encoded_heartbeat(kTagTwo, 0U, report);
    MavlinkFrame output{};
    report.check(ledger.arm(kTagOne, 1U) == R19BulkRxTailLedgerStatus::Armed &&
                     ledger.accept_decoder_fragment(
                         decoder, encoded.fragments[0U], output, 2U) ==
                         R19BulkRxTailLedgerStatus::EvidenceMismatch &&
                     ledger.fail_closed() && decoder.next_wire_ordinal() == 0U,
                 "wrong transfer tag advanced the ledger or decoder");
  }
  {
    R19BulkRxTailLedger ledger{};
    BulkDataStreamDecoder decoder{kTagOne};
    const EncodedBulkDataFrame encoded = encoded_heartbeat(kTagOne, 2U, report);
    MavlinkFrame output{};
    report.check(ledger.arm(kTagOne, 1U) == R19BulkRxTailLedgerStatus::Armed &&
                     ledger.accept_decoder_fragment(
                         decoder, encoded.fragments[0U], output, 2U) ==
                         R19BulkRxTailLedgerStatus::EvidenceMismatch &&
                     ledger.fail_closed(),
                 "skipped first ordinal did not fail closed");
  }
  {
    R19BulkRxTailLedger ledger{};
    BulkDataStreamDecoder decoder{kTagOne};
    const EncodedBulkDataFrame encoded = encoded_heartbeat(kTagOne, 0U, report);
    MavlinkFrame output{};
    report.check(ledger.arm(kTagOne, 1U) == R19BulkRxTailLedgerStatus::Armed &&
                     ledger.accept_decoder_fragment(
                         decoder, encoded.fragments[0U], output, 2U) ==
                         R19BulkRxTailLedgerStatus::FragmentAccepted &&
                     ledger.accept_decoder_fragment(
                         decoder, encoded.fragments[0U], output, 3U) ==
                         R19BulkRxTailLedgerStatus::EvidenceMismatch &&
                     ledger.fail_closed(),
                 "duplicate/out-of-order fragment did not fail closed");
  }
  {
    R19BulkRxTailLedger ledger{};
    BulkDataStreamDecoder decoder{kTagOne};
    const EncodedBulkDataFrame encoded = encoded_heartbeat(kTagOne, 0U, report);
    MavlinkFrame output{};
    report.check(ledger.arm(kTagOne, 10U) == R19BulkRxTailLedgerStatus::Armed &&
                     ledger.accept_decoder_fragment(
                         decoder, encoded.fragments[0U], output, 11U) ==
                         R19BulkRxTailLedgerStatus::FragmentAccepted &&
                     ledger.accept_decoder_fragment(
                         decoder, encoded.fragments[1U], output, 10U) ==
                         R19BulkRxTailLedgerStatus::ClockRegression &&
                     ledger.fail_closed(),
                 "time regression did not fail closed");
  }
}

void test_invalid_configuration_and_double_final_fail_closed(Report &report) {
  {
    R19BulkRxTailLedger ledger{};
    report.check(ledger.arm(0U, 1U) ==
                         R19BulkRxTailLedgerStatus::InvalidConfiguration &&
                     ledger.fail_closed(),
                 "zero tag did not fail closed");
  }
  {
    R19BulkRxTailLedger ledger{};
    report.check(ledger.arm(kTagOne, 1U) == R19BulkRxTailLedgerStatus::Armed &&
                     ledger.arm(kTagTwo, 2U) ==
                         R19BulkRxTailLedgerStatus::InvalidConfiguration &&
                     ledger.fail_closed(),
                 "active ledger accepted a second arm");
  }
  {
    R19BulkRxTailLedger ledger{};
    BulkDataStreamDecoder decoder{kTagOne};
    std::uint64_t now_ms = 1U;
    report.check(ledger.arm(kTagOne, now_ms++) ==
                     R19BulkRxTailLedgerStatus::Armed,
                 "double-final fixture did not arm");
    report.check(complete_session(ledger, decoder, 0U, now_ms, report),
                 "double-final fixture did not complete");
    HighSpeedLocalRxRecordIdentity identity{};
    report.check(ledger.issue_final_identity(identity, now_ms++) ==
                         R19BulkRxTailLedgerStatus::IdentityIssued &&
                     ledger.issue_final_identity(identity, now_ms++) ==
                         R19BulkRxTailLedgerStatus::InvalidState &&
                     ledger.fail_closed(),
                 "final local RX identity was issued twice");
  }
}

void test_counter_domains_fail_closed_at_suffix_limit(Report &report) {
  {
    R19BulkRxTailLedger ledger{R19BulkRxTailLedgerCounterSeed{
        R19BulkRxTailLedger::local_rx_token_domain,
        R19BulkRxTailLedger::local_rx_generation_limit}};
    report.check(
        ledger.arm(kTagOne, 1U) == R19BulkRxTailLedgerStatus::CounterOverflow &&
            ledger.fail_closed(),
        "generation suffix exhaustion escaped the local identity domain");
  }
  {
    R19BulkRxTailLedger ledger{R19BulkRxTailLedgerCounterSeed{
        R19BulkRxTailLedger::local_rx_token_limit,
        R19BulkRxTailLedger::local_rx_generation_domain}};
    BulkDataStreamDecoder decoder{kTagOne};
    std::uint64_t now_ms = 1U;
    report.check(ledger.arm(kTagOne, now_ms++) ==
                     R19BulkRxTailLedgerStatus::Armed,
                 "token exhaustion fixture did not arm");
    report.check(complete_session(ledger, decoder, 0U, now_ms, report,
                                  R19BulkRxTailLedgerStatus::CounterOverflow) &&
                     ledger.fail_closed(),
                 "token suffix exhaustion escaped the local identity domain");
  }
  {
    R19BulkRxTailLedger ledger{R19BulkRxTailLedgerCounterSeed{0U, 0U}};
    report.check(ledger.fail_closed() &&
                     ledger.last_status() ==
                         R19BulkRxTailLedgerStatus::InvalidConfiguration,
                 "identity counters accepted a seed outside local domains");
  }
}

} // namespace

TestReport run_phase6_bulk_rx_tail_ledger_test(const std::string &test_id,
                                               std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;
  if (test_id == "UT-HS-BULK-RX-TAIL-LEDGER-001") {
    test_positive_and_monotonic_rearm(report);
    test_invalid_fragments_fail_closed(report);
    test_invalid_configuration_and_double_final_fail_closed(report);
    test_counter_domains_fail_closed_at_suffix_limit(report);
  } else {
    report.check(false, "unknown Phase6 bulk RX tail ledger test ID");
  }
  report.trace.record({0U, "host", "HS_BULK_RX_TAIL_LEDGER", 0U,
                       report.passed ? "PASS" : "FAIL", true, 0U, 0U, 0U});
  return report;
}

} // namespace vc_lora::test
