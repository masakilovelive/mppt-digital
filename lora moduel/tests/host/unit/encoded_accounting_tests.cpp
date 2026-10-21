#include "test_support.hpp"

#include <cstdint>

#include "vc_lora/tdd_ground.hpp"
#include "vc_lora/tdd_vehicle.hpp"

namespace vc_lora::test {

TestReport run_encoded_accounting_test(const std::string& test_id,
                                       std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  TddConfig config{};
  config.downlink_send_ms = 100U;
  config.uplink_guard_ms = 0U;
  config.uplink_window_ms = 1'000U;
  config.aux_stable_ms = 0U;
  config.min_tx_gap_ms = 0U;

  if (test_id == "UT-LINK-ACCOUNT-001") {
    LinkDiagnostics diagnostics{};
    GroundTddController ground(config, diagnostics);
    ground.reset(0U);
    TddControlMessage grant{};
    grant.type = ControlType::UlGrant;
    grant.session_id = 7U;
    grant.cycle_id = 3U;
    grant.window_ms = 1'000U;
    grant.max_bytes = 64U;
    report.check(ground.on_control(grant, 0U) ==
                     ControlDisposition::Accepted,
                 "test GRANT was not accepted");
    (void)ground.tick({0U, true, true, true, 32U});
    const LinkAction action = ground.tick({0U, true, true, true, 32U});
    report.check(action.type == LinkActionType::SendRadioData &&
                     action.byte_budget == 32U,
                 "Ground did not issue the expected 32-byte logical action");
    ground.complete_action(action.token, TxResult::Accepted, 0U, 31U);
    report.check(ground.actual_bytes() == 31U,
                 "Ground accounted the requested budget instead of the "
                 "accepted application-byte count");
    report.check(diagnostics.uplink_payload_bytes == 31U,
                 "Ground payload diagnostics ignored encoded byte expansion");
    report.diagnostics = diagnostics;
  } else if (test_id == "UT-LINK-ACCOUNT-002") {
    LinkDiagnostics diagnostics{};
    VehicleTddController vehicle(config, diagnostics);
    vehicle.reset(7U, 3U, 0U);
    (void)vehicle.tick({0U, true, true, true, 0U});
    const LinkAction action = vehicle.tick({1U, true, true, true, 32U});
    report.check(action.type == LinkActionType::SendRadioData &&
                     action.byte_budget == 32U,
                 "Vehicle did not issue the expected 32-byte logical action");
    vehicle.complete_action(action.token, TxResult::Accepted, 1U, 31U);
    report.check(diagnostics.downlink_payload_bytes == 31U,
                 "Vehicle payload diagnostics ignored encoded byte expansion");
    report.diagnostics = diagnostics;
  } else if (test_id == "UT-LINK-ACCOUNT-003") {
    LinkDiagnostics diagnostics{};
    GroundTddController ground(config, diagnostics);
    ground.reset(0U);
    TddControlMessage grant{};
    grant.type = ControlType::UlGrant;
    grant.session_id = 7U;
    grant.cycle_id = 4U;
    grant.window_ms = 100U;
    grant.max_bytes = 64U;
    report.check(ground.on_control(grant, 0U) ==
                     ControlDisposition::Accepted,
                 "encoded-fit test GRANT was not accepted");
    TddInput input{0U, true, true, true, 64U};
    input.next_tx_application_bytes = 16U;
    input.next_tx_wire_bytes = 32U;
    (void)ground.tick(input);
    const LinkAction action = ground.tick(input);
    report.check(action.type == LinkActionType::SendRadioData,
                 "exact encoded wire chunk was rejected by a fit estimate");
    report.check(action.byte_budget == 16U,
                 "Ground action ignored the encoded application prefix");

    LinkDiagnostics tight_diagnostics{};
    GroundTddController tight_ground(config, tight_diagnostics);
    tight_ground.reset(0U);
    grant.cycle_id = 5U;
    grant.window_ms = 10U;
    report.check(tight_ground.on_control(grant, 0U) ==
                     ControlDisposition::Accepted,
                 "tight-window test GRANT was not accepted");
    TddInput tight_input{0U, true, true, true, 16U};
    tight_input.next_tx_application_bytes = 16U;
    tight_input.next_tx_wire_bytes = 32U;
    const LinkAction tight_action = tight_ground.tick(tight_input);
    report.check(tight_action.type == LinkActionType::None &&
                     tight_ground.state() == GroundTddState::SendUlDone,
                 "expanded wire chunk was allowed to overrun its window");
    report.diagnostics = diagnostics;
  } else {
    report.check(false, "unknown encoded-accounting test ID");
  }
  return report;
}

}  // namespace vc_lora::test
