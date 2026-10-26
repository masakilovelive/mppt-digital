add_executable(vc_lora_host_tests
  test_main.cpp
  unit/unit_tests.cpp
  unit/buffer_tests.cpp
  unit/encoded_accounting_tests.cpp
  unit/embedded_adapter_tests.cpp
  unit/runtime_contract_tests.cpp
  unit/e220_startup_contract_tests.cpp
  unit/control_v2_tests.cpp
  unit/link_data_codec_tests.cpp
  unit/bulk_data_codec_tests.cpp
  unit/bulk_tx_lease_tests.cpp
  unit/bulk_heartbeat_policy_tests.cpp
  unit/bulk_heartbeat_sla_tests.cpp
  unit/bulk_transcript_tests.cpp
  unit/bulk_negotiation_codec_tests.cpp
  unit/bulk_session_controller_tests.cpp
  unit/high_speed_tdd_coordinator_tests.cpp
  unit/high_speed_phase6_adapter_tests.cpp
  unit/phase6_radio_writer_arbiter_tests.cpp
  unit/phase6_high_speed_radio_session_tests.cpp
  unit/terminal_completion_ack_tests.cpp
  unit/phase6_bulk_rx_tail_ledger_tests.cpp
  unit/phase6_high_speed_role_config_tests.cpp
  unit/phase6_product_writer_source_contract_tests.cpp
  unit/phase6_high_speed_product_route_source_contract_tests.cpp
  unit/mavlink_tests.cpp
  unit/vehicle_parameter_priority_tests.cpp
  unit/vehicle_boundary_tests.cpp
  unit/uplink_guard_tests.cpp
  unit/uplink_residual_tests.cpp
  unit/late_uplink_recovery_tests.cpp
  integration/tdd_integration_tests.cpp
  integration/uplink_guard_integration_tests.cpp
  integration/control_subpacket_integration_tests.cpp
  integration/buffered_e220_integration_tests.cpp
  integration/ground_usb_heartbeat_pacer_tests.cpp
  integration/ground_usb_heartbeat_phase6_tests.cpp
  integration/buffer_integration_tests.cpp
  integration/phase6_high_speed_route_integration_tests.cpp
  integration/r19_candidate_standard_path_tests.cpp
  integration/mavlink_e2e_tests.cpp
  integration/mavlink_e2e_sim.cpp
  integration/tdd_simulation.cpp
  integration/parameter_proxy_tests.cpp
  stress/phase5_stress_tests.cpp
  sim/rf_medium_sim.cpp
  sim/trace_recorder.cpp
)

add_executable(vc_lora_r19_aux_readiness_record_tests
  unit/r19_aux_readiness_record_tests.cpp)
target_link_libraries(vc_lora_r19_aux_readiness_record_tests PRIVATE vc_lora_core)
target_compile_features(vc_lora_r19_aux_readiness_record_tests PRIVATE cxx_std_17)
set_target_properties(vc_lora_r19_aux_readiness_record_tests PROPERTIES CXX_EXTENSIONS OFF)
if(NOT MSVC)
  target_compile_options(vc_lora_r19_aux_readiness_record_tests PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion)
  if(WIN32)
    target_link_options(vc_lora_r19_aux_readiness_record_tests PRIVATE -static)
  endif()
endif()
add_test(NAME R19-AUX-READINESS-RECORD-UNIT-001
  COMMAND vc_lora_r19_aux_readiness_record_tests)

target_link_libraries(vc_lora_host_tests PRIVATE vc_lora_core)

foreach(grant_unit IN ITEMS adapter_diagnostics diagnostic_record)
  if(grant_unit STREQUAL "adapter_diagnostics")
    set(grant_source unit/r19_grant_adapter_diagnostics_tests.cpp)
  else()
    set(grant_source standalone/r19_grant_diagnostic_record_tests.cpp)
  endif()
  add_executable(vc_lora_r19_grant_${grant_unit}_tests ${grant_source})
  target_link_libraries(vc_lora_r19_grant_${grant_unit}_tests PRIVATE vc_lora_core)
  target_include_directories(vc_lora_r19_grant_${grant_unit}_tests PRIVATE ${CMAKE_SOURCE_DIR}/firmware)
  target_compile_features(vc_lora_r19_grant_${grant_unit}_tests PRIVATE cxx_std_17)
  if(NOT MSVC)
    target_compile_options(vc_lora_r19_grant_${grant_unit}_tests PRIVATE -Wall -Wextra -Wpedantic -Wconversion)
    if(WIN32)
      target_link_options(vc_lora_r19_grant_${grant_unit}_tests PRIVATE -static)
    endif()
  endif()
  add_test(NAME R19-GRANT-${grant_unit}-UNIT-001 COMMAND vc_lora_r19_grant_${grant_unit}_tests)
endforeach()
foreach(grant_alignment IN ITEMS grant_admission_timing standard_grant_phase start_admission)
  add_executable(vc_lora_r19_${grant_alignment}_tests
    standalone/r19_${grant_alignment}_tests.cpp)
  target_link_libraries(vc_lora_r19_${grant_alignment}_tests PRIVATE vc_lora_core)
  target_include_directories(vc_lora_r19_${grant_alignment}_tests PRIVATE
    ${CMAKE_SOURCE_DIR}/firmware)
  target_compile_features(vc_lora_r19_${grant_alignment}_tests PRIVATE cxx_std_17)
  set_target_properties(vc_lora_r19_${grant_alignment}_tests PROPERTIES CXX_EXTENSIONS OFF)
  if(NOT MSVC)
    target_compile_options(vc_lora_r19_${grant_alignment}_tests PRIVATE
      -Wall -Wextra -Wpedantic -Wconversion)
    if(WIN32)
      target_link_options(vc_lora_r19_${grant_alignment}_tests PRIVATE -static)
    endif()
  endif()
  add_test(NAME R19-${grant_alignment}-ALIGNMENT-OFFLINE-001
    COMMAND vc_lora_r19_${grant_alignment}_tests)
  set_tests_properties(R19-${grant_alignment}-ALIGNMENT-OFFLINE-001 PROPERTIES
    LABELS "r19;grant;offline;characterization" TIMEOUT 30)
endforeach()

target_include_directories(vc_lora_host_tests PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${CMAKE_CURRENT_SOURCE_DIR}/sim
  ${CMAKE_CURRENT_SOURCE_DIR}/integration
)
target_compile_definitions(vc_lora_host_tests PRIVATE
  VC_LORA_SOURCE_ROOT="${CMAKE_SOURCE_DIR}"
)
target_compile_features(vc_lora_host_tests PRIVATE cxx_std_17)
set_target_properties(vc_lora_host_tests PROPERTIES CXX_EXTENSIONS OFF)

if(MSVC)
  target_compile_options(vc_lora_host_tests PRIVATE /W4 /permissive-)
else()
  target_compile_options(vc_lora_host_tests PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion
  )
  if(WIN32)
    # Keep ctest/direct reproductions independent of llvm-mingw runtime DLLs.
    target_link_options(vc_lora_host_tests PRIVATE -static)
  endif()
endif()

add_executable(vc_lora_e220_continuous_aux_credit_tests
  standalone/e220_continuous_aux_credit_red.cpp
)
target_compile_features(vc_lora_e220_continuous_aux_credit_tests PRIVATE
  cxx_std_17
)
set_target_properties(vc_lora_e220_continuous_aux_credit_tests PROPERTIES
  CXX_EXTENSIONS OFF
)
if(MSVC)
  target_compile_options(vc_lora_e220_continuous_aux_credit_tests PRIVATE
    /W4 /permissive-
  )
else()
  target_compile_options(vc_lora_e220_continuous_aux_credit_tests PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion
  )
  if(WIN32)
    target_link_options(vc_lora_e220_continuous_aux_credit_tests PRIVATE
      -static
    )
  endif()
endif()

add_executable(vc_lora_r19_runtime_fail_diagnostic_tests
  standalone/r19_runtime_fail_diagnostic_tests.cpp
)
add_executable(vc_lora_r19_hwcdc_ll_bootstrap_model_tests
  standalone/r19_hwcdc_ll_bootstrap_model_tests.cpp
)
add_executable(vc_lora_r19_hwcdc_task_prime_model_tests
  standalone/r19_hwcdc_task_prime_model_tests.cpp
)
add_executable(vc_lora_r19_usb_clock_sync_tests
  standalone/r19_usb_clock_sync_tests.cpp
)
add_executable(vc_lora_r19_host_readiness_tests
  standalone/r19_host_readiness_tests.cpp)
target_link_libraries(vc_lora_r19_host_readiness_tests PRIVATE vc_lora_core)
target_include_directories(vc_lora_r19_host_readiness_tests PRIVATE
  ${CMAKE_SOURCE_DIR}/firmware)
target_compile_features(vc_lora_r19_host_readiness_tests PRIVATE cxx_std_17)
if(WIN32 AND NOT MSVC)
  target_link_options(vc_lora_r19_host_readiness_tests PRIVATE -static)
endif()
add_test(NAME UT-R19-HOST-READINESS-001 COMMAND vc_lora_r19_host_readiness_tests)
set_tests_properties(UT-R19-HOST-READINESS-001 PROPERTIES
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} LABELS "r19;diagnostic;offline" TIMEOUT 30)

add_executable(vc_lora_r19_timed_path_record_tests standalone/r19_timed_path_record_tests.cpp)
target_link_libraries(vc_lora_r19_timed_path_record_tests PRIVATE vc_lora_core)
target_include_directories(vc_lora_r19_timed_path_record_tests PRIVATE
  ${CMAKE_SOURCE_DIR}/firmware
  ${CMAKE_SOURCE_DIR}/third_party/esp32-core-3.3.11-vc-lora/cores/esp32)
target_compile_features(vc_lora_r19_timed_path_record_tests PRIVATE cxx_std_17)
if(WIN32 AND NOT MSVC)
  target_link_options(vc_lora_r19_timed_path_record_tests PRIVATE -static)
endif()
add_test(NAME UT-R19-TIMED-PATH-RECORD-001 COMMAND vc_lora_r19_timed_path_record_tests)
set_tests_properties(UT-R19-TIMED-PATH-RECORD-001 PROPERTIES
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} LABELS "r19;diagnostic;offline" TIMEOUT 30)

foreach(timed_mode IN ITEMS 1 2)
  set(timed_target vc_lora_phase6_timed_path_mode_${timed_mode}_tests)
  add_executable(${timed_target} standalone/phase6_timed_path_integration_tests.cpp)
  target_link_libraries(${timed_target} PRIVATE vc_lora_core)
  target_include_directories(${timed_target} PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/fakes ${CMAKE_SOURCE_DIR}/firmware
    ${CMAKE_SOURCE_DIR}/third_party/esp32-core-3.3.11-vc-lora/cores/esp32)
  target_compile_definitions(${timed_target} PRIVATE VC_LORA_R19_USB_READINESS_MODE=${timed_mode})
  target_compile_features(${timed_target} PRIVATE cxx_std_17)
  if(WIN32 AND NOT MSVC)
    target_link_options(${timed_target} PRIVATE -static)
  endif()
  foreach(timed_case IN ITEMS timeout success before_deadline)
    add_test(NAME IT-R19-TIMED-PATH-MODE-${timed_mode}-${timed_case}-001
      COMMAND ${timed_target} ${timed_case})
  endforeach()
endforeach()
add_test(NAME IT-R19-TIMED-PATH-EPOCH-ABORT-001
  COMMAND vc_lora_phase6_timed_path_mode_2_tests epoch_aborted)
target_link_libraries(vc_lora_r19_usb_clock_sync_tests PRIVATE vc_lora_core)
target_include_directories(vc_lora_r19_usb_clock_sync_tests PRIVATE
  ${CMAKE_SOURCE_DIR}/firmware
)
target_compile_features(vc_lora_r19_usb_clock_sync_tests PRIVATE cxx_std_17)
if(WIN32 AND NOT MSVC)
  target_link_options(vc_lora_r19_usb_clock_sync_tests PRIVATE -static)
endif()
add_test(NAME UT-R19-USB-CLOCK-SYNC-001
  COMMAND vc_lora_r19_usb_clock_sync_tests)
set_tests_properties(UT-R19-USB-CLOCK-SYNC-001 PROPERTIES
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} LABELS "r19;diagnostic;offline" TIMEOUT 30)
add_executable(vc_lora_r19_first_usb_failure_record_tests
  standalone/r19_first_usb_failure_record_tests.cpp)
target_include_directories(vc_lora_r19_first_usb_failure_record_tests PRIVATE
  ${CMAKE_SOURCE_DIR}/third_party/esp32-core-3.3.11-vc-lora/cores/esp32)
target_compile_features(vc_lora_r19_first_usb_failure_record_tests PRIVATE cxx_std_17)
if(WIN32 AND NOT MSVC)
  target_link_options(vc_lora_r19_first_usb_failure_record_tests PRIVATE -static)
endif()
add_test(NAME UT-R19-FIRST-USB-FAILURE-RECORD-001
  COMMAND vc_lora_r19_first_usb_failure_record_tests)

add_executable(vc_lora_r19_diagnostic_usb_failure_record_tests
  standalone/r19_diagnostic_usb_failure_record_tests.cpp)
target_include_directories(vc_lora_r19_diagnostic_usb_failure_record_tests PRIVATE
  ${CMAKE_SOURCE_DIR}/firmware
  ${CMAKE_SOURCE_DIR}/third_party/esp32-core-3.3.11-vc-lora/cores/esp32)
target_compile_features(vc_lora_r19_diagnostic_usb_failure_record_tests PRIVATE cxx_std_17)
if(WIN32 AND NOT MSVC)
  target_link_options(vc_lora_r19_diagnostic_usb_failure_record_tests PRIVATE -static)
endif()
add_test(NAME UT-R19-DIAGNOSTIC-USB-FAILURE-RECORD-001
  COMMAND vc_lora_r19_diagnostic_usb_failure_record_tests)
set_tests_properties(UT-R19-FIRST-USB-FAILURE-RECORD-001 PROPERTIES
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} LABELS "r19;diagnostic;offline" TIMEOUT 30)
target_compile_definitions(
  vc_lora_r19_hwcdc_task_prime_model_tests PRIVATE
  VC_LORA_SOURCE_ROOT="${CMAKE_SOURCE_DIR}"
)
add_executable(vc_lora_r19_runtime_stage_record_tests
  standalone/r19_runtime_stage_record_tests.cpp
)
add_executable(vc_lora_r19_ground_usb_commit_record_tests
  standalone/r19_ground_usb_commit_record_tests.cpp
)
add_executable(vc_lora_r19_ground_usb_commit_source_contract_tests
  standalone/r19_ground_usb_commit_source_contract_tests.cpp
)
target_compile_features(vc_lora_r19_ground_usb_commit_source_contract_tests PRIVATE
  cxx_std_17
)
set_target_properties(vc_lora_r19_ground_usb_commit_source_contract_tests PROPERTIES
  CXX_EXTENSIONS OFF
)
target_compile_features(vc_lora_r19_ground_usb_commit_record_tests PRIVATE
  cxx_std_17
)
set_target_properties(vc_lora_r19_ground_usb_commit_record_tests PROPERTIES
  CXX_EXTENSIONS OFF
)
add_executable(vc_lora_r19_hwcdc_fifo_diagnostic_record_tests
  standalone/r19_hwcdc_fifo_diagnostic_record_tests.cpp
)
target_compile_features(vc_lora_r19_runtime_stage_record_tests PRIVATE
  cxx_std_17
)
target_compile_features(vc_lora_r19_hwcdc_fifo_diagnostic_record_tests PRIVATE
  cxx_std_17
)
set_target_properties(vc_lora_r19_runtime_stage_record_tests PROPERTIES
  CXX_EXTENSIONS OFF
)
set_target_properties(vc_lora_r19_hwcdc_fifo_diagnostic_record_tests PROPERTIES
  CXX_EXTENSIONS OFF
)
target_link_libraries(vc_lora_r19_runtime_fail_diagnostic_tests PRIVATE
  vc_lora_core
)
target_include_directories(vc_lora_r19_runtime_fail_diagnostic_tests PRIVATE
  ${CMAKE_SOURCE_DIR}/core/include
)
target_compile_features(vc_lora_r19_runtime_fail_diagnostic_tests PRIVATE
  cxx_std_17
)
set_target_properties(vc_lora_r19_runtime_fail_diagnostic_tests PROPERTIES
  CXX_EXTENSIONS OFF
)

add_executable(vc_lora_r19_runtime_fail_product_source_contract_tests
  standalone/r19_runtime_fail_product_source_contract_tests.cpp
)
target_compile_definitions(
  vc_lora_r19_runtime_fail_product_source_contract_tests PRIVATE
  VC_LORA_SOURCE_ROOT="${CMAKE_SOURCE_DIR}"
)
target_compile_features(
  vc_lora_r19_runtime_fail_product_source_contract_tests PRIVATE cxx_std_17
)
set_target_properties(
  vc_lora_r19_runtime_fail_product_source_contract_tests PROPERTIES
  CXX_EXTENSIONS OFF
)

foreach(runtime_fail_target IN ITEMS
    vc_lora_r19_runtime_fail_diagnostic_tests
    vc_lora_r19_runtime_fail_product_source_contract_tests
    vc_lora_r19_hwcdc_ll_bootstrap_model_tests
    vc_lora_r19_hwcdc_task_prime_model_tests
    vc_lora_r19_runtime_stage_record_tests
    vc_lora_r19_ground_usb_commit_record_tests
    vc_lora_r19_ground_usb_commit_source_contract_tests
    vc_lora_r19_hwcdc_fifo_diagnostic_record_tests)
  if(MSVC)
    target_compile_options(${runtime_fail_target} PRIVATE /W4 /permissive-)
  else()
    target_compile_options(${runtime_fail_target} PRIVATE
      -Wall -Wextra -Wpedantic -Wconversion
    )
    if(WIN32)
      target_link_options(${runtime_fail_target} PRIVATE -static)
    endif()
  endif()
endforeach()

add_test(
  NAME UT-R19-RUNTIME-FAIL-DIAGNOSTIC-001
  COMMAND vc_lora_r19_runtime_fail_diagnostic_tests
)
add_test(
  NAME UT-R19-RUNTIME-FAIL-PRODUCT-SOURCE-001
  COMMAND vc_lora_r19_runtime_fail_product_source_contract_tests
)
add_test(
  NAME UT-R19-HWCDC-LL-BOOTSTRAP-001
  COMMAND vc_lora_r19_hwcdc_ll_bootstrap_model_tests
)
add_test(
  NAME UT-R19-HWCDC-TASK-PRIME-001
  COMMAND vc_lora_r19_hwcdc_task_prime_model_tests
)
add_test(
  NAME UT-R19-RUNTIME-STAGE-RECORD-001
  COMMAND vc_lora_r19_runtime_stage_record_tests
)
add_test(
  NAME UT-R19-GROUND-USB-COMMIT-RECORD-001
  COMMAND vc_lora_r19_ground_usb_commit_record_tests
)
add_test(
  NAME UT-R19-GROUND-USB-COMMIT-SOURCE-001
  COMMAND vc_lora_r19_ground_usb_commit_source_contract_tests
)
add_test(
  NAME UT-R19-HWCDC-FIFO-DIAGNOSTIC-RECORD-001
  COMMAND vc_lora_r19_hwcdc_fifo_diagnostic_record_tests
)
set_tests_properties(
  UT-R19-RUNTIME-FAIL-DIAGNOSTIC-001
  UT-R19-RUNTIME-FAIL-PRODUCT-SOURCE-001
  UT-R19-HWCDC-LL-BOOTSTRAP-001
  UT-R19-HWCDC-TASK-PRIME-001
  UT-R19-RUNTIME-STAGE-RECORD-001
  UT-R19-GROUND-USB-COMMIT-RECORD-001
  UT-R19-GROUND-USB-COMMIT-SOURCE-001
  UT-R19-HWCDC-FIFO-DIAGNOSTIC-RECORD-001
  PROPERTIES
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    TIMEOUT 30
    LABELS "r19;diagnostic;offline"
)

add_executable(vc_lora_phase6_ground_runtime_fail_diagnostic_tests
  standalone/phase6_ground_runtime_fail_diagnostic_tests.cpp
)
add_executable(vc_lora_phase6_ground_usb_commit_latch_tests
  standalone/phase6_ground_usb_commit_latch_tests.cpp
)
add_executable(vc_lora_phase6_first_usb_failure_integration_tests
  standalone/phase6_first_usb_failure_integration_tests.cpp
)
add_executable(vc_lora_phase6_vehicle_runtime_fail_diagnostic_tests
  standalone/phase6_vehicle_runtime_fail_diagnostic_tests.cpp
)
add_executable(vc_lora_phase6_ground_runtime_alive_diagnostic_tests
  standalone/phase6_ground_runtime_alive_diagnostic_tests.cpp
)
add_executable(vc_lora_phase6_ground_runtime_alive_starvation_tests
  standalone/phase6_ground_runtime_alive_starvation_tests.cpp
)
add_executable(vc_lora_phase6_ground_runtime_alive_backpressure_tests
  standalone/phase6_ground_runtime_alive_backpressure_tests.cpp
)
add_executable(vc_lora_phase6_vehicle_runtime_alive_diagnostic_tests
  standalone/phase6_vehicle_runtime_alive_diagnostic_tests.cpp
)
add_executable(vc_lora_phase6_vehicle_runtime_alive_read_only_bootstrap_tests
  standalone/phase6_vehicle_runtime_alive_read_only_bootstrap_tests.cpp
)
add_executable(vc_lora_phase6_ground_runtime_alive_read_only_bootstrap_tests
  standalone/phase6_ground_runtime_alive_read_only_bootstrap_tests.cpp
)
add_executable(vc_lora_phase6_ground_runtime_fail_boundary_loss_tests
  standalone/phase6_ground_runtime_fail_boundary_loss_tests.cpp
)
add_executable(vc_lora_phase6_ground_runtime_fail_deadline_tests
  standalone/phase6_ground_runtime_fail_deadline_tests.cpp
)
add_executable(vc_lora_phase6_ground_runtime_fail_pending_alive_tests
  standalone/phase6_ground_runtime_fail_pending_alive_tests.cpp
)
add_executable(vc_lora_phase6_vehicle_runtime_fail_staged_zero_tests
  standalone/phase6_vehicle_runtime_fail_staged_zero_tests.cpp
)
add_executable(vc_lora_phase6_vehicle_runtime_fail_staged_partial_tests
  standalone/phase6_vehicle_runtime_fail_staged_partial_tests.cpp
)
add_executable(vc_lora_phase6_vehicle_runtime_fail_partial_deadline_tests
  standalone/phase6_vehicle_runtime_fail_partial_deadline_tests.cpp
)
add_executable(vc_lora_phase6_vehicle_runtime_fail_flush_deadline_tests
  standalone/phase6_vehicle_runtime_fail_flush_deadline_tests.cpp
)
add_executable(vc_lora_phase6_vehicle_runtime_fail_recovery_guard_tests
  standalone/phase6_vehicle_runtime_fail_recovery_guard_tests.cpp
)
add_executable(vc_lora_phase6_ground_runtime_fail_recovery_guard_tests
  standalone/phase6_ground_runtime_fail_recovery_guard_tests.cpp
)
add_executable(vc_lora_phase6_ground_host_readiness_tests
  standalone/phase6_ground_host_readiness_tests.cpp)
add_executable(vc_lora_phase6_grant_diagnostic_hooks_tests
  standalone/phase6_grant_diagnostic_hooks_tests.cpp)
add_executable(vc_lora_phase6_grant_reservation_ground_tests
  standalone/phase6_grant_reservation_bridge_tests.cpp)
add_executable(vc_lora_r19_grant_reservation_tests
  standalone/r19_grant_reservation_tests.cpp)
target_link_libraries(vc_lora_r19_grant_reservation_tests PRIVATE vc_lora_core)
target_compile_features(vc_lora_r19_grant_reservation_tests PRIVATE cxx_std_17)
if(NOT MSVC)
  target_compile_options(vc_lora_r19_grant_reservation_tests PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion)
  if(WIN32)
    target_link_options(vc_lora_r19_grant_reservation_tests PRIVATE -static)
  endif()
endif()
add_test(NAME UT-R19-GRANT-RESERVATION-CORE-001
  COMMAND vc_lora_r19_grant_reservation_tests)
add_executable(vc_lora_r19_grant_reservation_stop_tests
  standalone/r19_grant_reservation_stop_tests.cpp)
target_link_libraries(vc_lora_r19_grant_reservation_stop_tests PRIVATE vc_lora_core)
target_compile_features(vc_lora_r19_grant_reservation_stop_tests PRIVATE cxx_std_17)
if(WIN32 AND NOT MSVC)
  target_link_options(vc_lora_r19_grant_reservation_stop_tests PRIVATE -static)
endif()
add_test(NAME UT-R19-GRANT-RESERVATION-STOP-RECORD-001
  COMMAND vc_lora_r19_grant_reservation_stop_tests)
add_executable(vc_lora_r19_grant_reservation_fatal_record_tests
  standalone/r19_grant_reservation_fatal_record_tests.cpp)
target_link_libraries(vc_lora_r19_grant_reservation_fatal_record_tests PRIVATE vc_lora_core)
target_include_directories(vc_lora_r19_grant_reservation_fatal_record_tests PRIVATE
  ${CMAKE_SOURCE_DIR}/firmware)
target_compile_features(vc_lora_r19_grant_reservation_fatal_record_tests PRIVATE cxx_std_17)
if(WIN32 AND NOT MSVC)
  target_link_options(vc_lora_r19_grant_reservation_fatal_record_tests PRIVATE -static)
endif()
add_test(NAME UT-R19-GRANT-RESERVATION-FATAL-RECORD-001
  COMMAND vc_lora_r19_grant_reservation_fatal_record_tests)
add_executable(vc_lora_r19_grant_agreement_tests
  standalone/r19_grant_agreement_tests.cpp)
target_link_libraries(vc_lora_r19_grant_agreement_tests PRIVATE vc_lora_core)
target_compile_features(vc_lora_r19_grant_agreement_tests PRIVATE cxx_std_17)
if(WIN32 AND NOT MSVC)
  target_link_options(vc_lora_r19_grant_agreement_tests PRIVATE -static)
endif()
add_test(NAME UT-R19-GRANT-AGREEMENT-CORE-001 COMMAND vc_lora_r19_grant_agreement_tests)
foreach(agreement_capability_role IN ITEMS ground vehicle)
  add_executable(vc_lora_r19_grant_agreement_capability_${agreement_capability_role}_tests
    standalone/r19_grant_agreement_capability_tests.cpp)
  if(agreement_capability_role STREQUAL "vehicle")
    target_compile_definitions(vc_lora_r19_grant_agreement_capability_${agreement_capability_role}_tests
      PRIVATE AGREEMENT_CAPABILITY_VEHICLE=1)
  endif()
  add_test(NAME IT-R19-GRANT-AGREEMENT-CAPABILITY-${agreement_capability_role}-001
    COMMAND vc_lora_r19_grant_agreement_capability_${agreement_capability_role}_tests)
  set_tests_properties(IT-R19-GRANT-AGREEMENT-CAPABILITY-${agreement_capability_role}-001 PROPERTIES
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}" LABELS "r19;agreement;offline" TIMEOUT 30)
endforeach()
add_executable(vc_lora_phase6_grant_agreement_ground_tests
  standalone/phase6_grant_agreement_flow_tests.cpp)
add_executable(vc_lora_phase6_grant_agreement_vehicle_tests
  standalone/phase6_grant_agreement_flow_tests.cpp)
target_compile_definitions(vc_lora_phase6_grant_agreement_vehicle_tests PRIVATE AGREEMENT_TEST_VEHICLE=1)
add_executable(vc_lora_phase6_grant_reservation_fatal_flow_tests
  standalone/phase6_grant_reservation_fatal_flow_tests.cpp)
foreach(fatal_case IN ITEMS repeat-heartbeat no-new-heartbeat aux-fault lease-fault
    heartbeat-aux-fault heartbeat-lease-fault)
  add_test(NAME IT-R19-GRANT-RESERVATION-FATAL-${fatal_case}-001
    COMMAND vc_lora_phase6_grant_reservation_fatal_flow_tests ${fatal_case})
  set_tests_properties(IT-R19-GRANT-RESERVATION-FATAL-${fatal_case}-001 PROPERTIES
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}" LABELS "r19;agreement;fatal;offline" TIMEOUT 30)
endforeach()
foreach(agreement_case IN ITEMS commit request-without-commit commit-wrong-tuple abort-held abort-preheld
    unsafe-busy unsafe-pending unsafe-tail unsafe-frozen unsafe-negotiation unsafe-session
    unsafe-usb unsafe-epoch unsafe-high-speed unsafe-writer unsafe-ingress unsafe-proxy unsafe-origin wrong-wire
    abort-wrong-identity failed-loop-abort loop-abort abort-prefix-fault abort-after-grant-deadline)
  add_test(NAME IT-R19-GRANT-AGREEMENT-GROUND-${agreement_case}-001
    COMMAND vc_lora_phase6_grant_agreement_ground_tests ${agreement_case})
endforeach()
foreach(agreement_case IN ITEMS commit release-without-commit abort abort-after-withdrawal
    unsafe-uart unsafe-busy unsafe-tail unsafe-epoch wrong-wire
    abort-wrong-identity failed-loop-abort loop-abort abort-prefix-fault
    abort-after-withdrawal-data abort-after-withdrawal-writer-mismatch
    abort-after-withdrawal-writer-owner defer-prepared-heartbeat defer-prepared-budget)
  add_test(NAME IT-R19-GRANT-AGREEMENT-VEHICLE-${agreement_case}-001
    COMMAND vc_lora_phase6_grant_agreement_vehicle_tests ${agreement_case})
endforeach()
add_test(NAME IT-R19-GRANT-RESERVATION-GROUND-001
  COMMAND vc_lora_phase6_grant_reservation_ground_tests)
add_executable(vc_lora_phase6_grant_reservation_ground_flow_tests
  standalone/phase6_grant_reservation_flow_tests.cpp)
add_executable(vc_lora_phase6_grant_reservation_vehicle_flow_tests
  standalone/phase6_grant_reservation_flow_tests.cpp)
add_executable(vc_lora_phase6_grant_reservation_ground_stop_flow_tests
  standalone/phase6_grant_reservation_flow_tests.cpp)
add_executable(vc_lora_phase6_grant_reservation_vehicle_stop_flow_tests
  standalone/phase6_grant_reservation_flow_tests.cpp)
target_compile_definitions(vc_lora_phase6_grant_reservation_ground_stop_flow_tests PRIVATE
  RESERVATION_TEST_STOP=1)
target_compile_definitions(vc_lora_phase6_grant_reservation_vehicle_stop_flow_tests PRIVATE
  RESERVATION_TEST_STOP=1 RESERVATION_TEST_VEHICLE=1)
target_compile_definitions(vc_lora_phase6_grant_reservation_vehicle_flow_tests PRIVATE
  RESERVATION_TEST_VEHICLE=1)
foreach(reservation_case IN ITEMS positive grant-late busy-at-request duplicate-request stale-loop-ms wrong-wire-version)
  add_test(NAME IT-R19-GRANT-RESERVATION-GROUND-${reservation_case}-001
    COMMAND vc_lora_phase6_grant_reservation_ground_flow_tests ${reservation_case})
endforeach()
foreach(reservation_case IN ITEMS positive hold-expired epoch-after-prepare usb-prefix-expired wrong-wire-version)
  add_test(NAME IT-R19-GRANT-RESERVATION-VEHICLE-${reservation_case}-001
    COMMAND vc_lora_phase6_grant_reservation_vehicle_flow_tests ${reservation_case})
endforeach()
foreach(reservation_case IN ITEMS positive wrong-wire-version stop-aux stop-lease stop-token
    stop-generation stop-busy stop-pending stop-tail stop-reservation
    cancel-heartbeat154 cancel-replay hold-expired epoch-after-prepare usb-prefix-expired)
  add_test(NAME IT-R19-GRANT-RESERVATION-VEHICLE-STOP-${reservation_case}-001
    COMMAND vc_lora_phase6_grant_reservation_vehicle_stop_flow_tests ${reservation_case})
endforeach()
foreach(reservation_case IN ITEMS positive wrong-wire-version cancel-ground-preheld
    cancel-ground-same-nonce cancel-ground-after-held)
  add_test(NAME IT-R19-GRANT-RESERVATION-GROUND-STOP-${reservation_case}-001
    COMMAND vc_lora_phase6_grant_reservation_ground_stop_flow_tests ${reservation_case})
endforeach()
add_test(NAME IT-R19-GRANT-DIAGNOSTIC-BRIDGE-001 COMMAND vc_lora_phase6_grant_diagnostic_hooks_tests)
add_executable(vc_lora_r19_pre_negotiation_fallback_tests
  standalone/r19_pre_negotiation_fallback_tests.cpp)
foreach(fallback_case IN ITEMS success boundary500 duplicate epoch epoch-during-admission late-fresh staged writer standard-writer session frozen partial-prefix occupied-proxy queue-full unknown-error nonparam negotiation-success)
  add_test(NAME IT-R19-PRENEGOTIATION-FALLBACK-${fallback_case}-001
    COMMAND vc_lora_r19_pre_negotiation_fallback_tests ${fallback_case})
  set_tests_properties(IT-R19-PRENEGOTIATION-FALLBACK-${fallback_case}-001 PROPERTIES
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} LABELS "r19;grant;fallback;offline" TIMEOUT 30)
endforeach()
add_executable(vc_lora_phase6_ground_aux_independence_tests
  standalone/phase6_ground_aux_independence_tests.cpp)
add_executable(vc_lora_phase6_vehicle_usb_clock_tests
  standalone/phase6_vehicle_usb_clock_tests.cpp)
foreach(clock_case IN ITEMS basic partial zero epoch deadline pending_diag runtime_failed cold cold_bootstrap flush_retry)
  add_test(NAME IT-R19-VEHICLE-USB-CLOCK-${clock_case}-001
    COMMAND vc_lora_phase6_vehicle_usb_clock_tests ${clock_case})
  set_tests_properties(IT-R19-VEHICLE-USB-CLOCK-${clock_case}-001 PROPERTIES
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} LABELS "r19;diagnostic;offline" TIMEOUT 30)
endforeach()
foreach(diagnostic_role IN ITEMS ground vehicle)
  add_executable(vc_lora_phase6_${diagnostic_role}_diagnostic_usb_failure_tests
    standalone/phase6_diagnostic_usb_failure_tests.cpp)
  if(diagnostic_role STREQUAL "ground")
    target_compile_definitions(vc_lora_phase6_${diagnostic_role}_diagnostic_usb_failure_tests PRIVATE REPRO_GROUND=1)
  else()
    target_compile_definitions(vc_lora_phase6_${diagnostic_role}_diagnostic_usb_failure_tests PRIVATE REPRO_GROUND=0)
  endif()
  foreach(diagnostic_case IN ITEMS deadline no_api epoch unknown_sdk bootstrap_epoch)
    add_test(NAME IT-R19-${diagnostic_role}-DIAGNOSTIC-USB-FAILURE-${diagnostic_case}-001
      COMMAND vc_lora_phase6_${diagnostic_role}_diagnostic_usb_failure_tests ${diagnostic_case})
    set_tests_properties(IT-R19-${diagnostic_role}-DIAGNOSTIC-USB-FAILURE-${diagnostic_case}-001 PROPERTIES
      WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} LABELS "r19;diagnostic;offline" TIMEOUT 30)
  endforeach()
endforeach()
foreach(aux_independence_case IN ITEMS hold expiry alive runtime notready)
  add_test(NAME IT-R19-GROUND-AUX-INDEPENDENCE-${aux_independence_case}-001
    COMMAND vc_lora_phase6_ground_aux_independence_tests ${aux_independence_case})
  set_tests_properties(IT-R19-GROUND-AUX-INDEPENDENCE-${aux_independence_case}-001
    PROPERTIES WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    LABELS "r19;diagnostic;offline" TIMEOUT 30)
endforeach()
add_test(NAME IT-R19-GROUND-HOST-READINESS-001
  COMMAND vc_lora_phase6_ground_host_readiness_tests)
set_tests_properties(IT-R19-GROUND-HOST-READINESS-001 PROPERTIES
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} LABELS "r19;diagnostic;offline" TIMEOUT 30)

foreach(runtime_fail_bridge_target IN ITEMS
    vc_lora_r19_grant_agreement_capability_ground_tests
    vc_lora_r19_grant_agreement_capability_vehicle_tests
    vc_lora_phase6_grant_agreement_ground_tests
    vc_lora_phase6_grant_agreement_vehicle_tests
    vc_lora_phase6_grant_reservation_fatal_flow_tests
    vc_lora_phase6_grant_reservation_ground_tests
  vc_lora_phase6_grant_reservation_ground_flow_tests
  vc_lora_phase6_grant_reservation_vehicle_flow_tests
  vc_lora_phase6_grant_reservation_ground_stop_flow_tests
  vc_lora_phase6_grant_reservation_vehicle_stop_flow_tests
    vc_lora_r19_pre_negotiation_fallback_tests
    vc_lora_phase6_grant_diagnostic_hooks_tests
    vc_lora_phase6_vehicle_usb_clock_tests
    vc_lora_phase6_ground_diagnostic_usb_failure_tests
    vc_lora_phase6_vehicle_diagnostic_usb_failure_tests
    vc_lora_phase6_ground_host_readiness_tests
    vc_lora_phase6_ground_aux_independence_tests
    vc_lora_phase6_first_usb_failure_integration_tests
    vc_lora_phase6_ground_usb_commit_latch_tests
    vc_lora_phase6_ground_runtime_fail_diagnostic_tests
    vc_lora_phase6_vehicle_runtime_fail_diagnostic_tests
    vc_lora_phase6_ground_runtime_alive_diagnostic_tests
    vc_lora_phase6_ground_runtime_alive_starvation_tests
    vc_lora_phase6_ground_runtime_alive_backpressure_tests
    vc_lora_phase6_vehicle_runtime_alive_diagnostic_tests
    vc_lora_phase6_vehicle_runtime_alive_read_only_bootstrap_tests
    vc_lora_phase6_ground_runtime_alive_read_only_bootstrap_tests
    vc_lora_phase6_ground_runtime_fail_boundary_loss_tests
    vc_lora_phase6_ground_runtime_fail_deadline_tests
    vc_lora_phase6_ground_runtime_fail_pending_alive_tests
    vc_lora_phase6_vehicle_runtime_fail_staged_zero_tests
    vc_lora_phase6_vehicle_runtime_fail_staged_partial_tests
    vc_lora_phase6_vehicle_runtime_fail_partial_deadline_tests
    vc_lora_phase6_vehicle_runtime_fail_flush_deadline_tests
    vc_lora_phase6_vehicle_runtime_fail_recovery_guard_tests
    vc_lora_phase6_ground_runtime_fail_recovery_guard_tests)
  target_link_libraries(${runtime_fail_bridge_target} PRIVATE vc_lora_core)
  target_include_directories(${runtime_fail_bridge_target} PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/fakes
    ${CMAKE_SOURCE_DIR}/firmware
    ${CMAKE_SOURCE_DIR}/core/include
    ${CMAKE_SOURCE_DIR}/third_party/esp32-core-3.3.11-vc-lora/cores/esp32
  )
  target_compile_features(${runtime_fail_bridge_target} PRIVATE cxx_std_17)
  set_target_properties(${runtime_fail_bridge_target} PROPERTIES
    CXX_EXTENSIONS OFF
  )
  if(MSVC)
    target_compile_options(${runtime_fail_bridge_target} PRIVATE
      /W4 /permissive-
    )
  else()
    target_compile_options(${runtime_fail_bridge_target} PRIVATE
      -Wall -Wextra -Wpedantic -Wconversion
    )
    if(WIN32)
      target_link_options(${runtime_fail_bridge_target} PRIVATE -static)
    endif()
  endif()
endforeach()

foreach(first_failure_mode IN ITEMS transport before_deadline endpoint wrapper_late sync_partial)
  add_test(NAME "IT-R19-FIRST-USB-FAILURE-${first_failure_mode}-001"
    COMMAND vc_lora_phase6_first_usb_failure_integration_tests "${first_failure_mode}")
  set_tests_properties("IT-R19-FIRST-USB-FAILURE-${first_failure_mode}-001" PROPERTIES
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} TIMEOUT 30 LABELS "r19;diagnostic;offline")
endforeach()

foreach(commit_latch_case IN ITEMS transport endpoint late deadline retired postflush_retired success)
  add_test(
    NAME IT-R19-GROUND-USB-COMMIT-LATCH-${commit_latch_case}-001
    COMMAND vc_lora_phase6_ground_usb_commit_latch_tests ${commit_latch_case}
  )
  set_tests_properties(
    IT-R19-GROUND-USB-COMMIT-LATCH-${commit_latch_case}-001 PROPERTIES
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    TIMEOUT 30
    LABELS "r19;diagnostic;product-loop;offline"
  )
endforeach()

add_test(
  NAME IT-R19-GROUND-RUNTIME-FAIL-DIAGNOSTIC-001
  COMMAND vc_lora_phase6_ground_runtime_fail_diagnostic_tests
)
add_test(
  NAME IT-R19-VEHICLE-RUNTIME-FAIL-DIAGNOSTIC-001
  COMMAND vc_lora_phase6_vehicle_runtime_fail_diagnostic_tests
)
add_test(
  NAME IT-R19-GROUND-RUNTIME-ALIVE-DIAGNOSTIC-001
  COMMAND vc_lora_phase6_ground_runtime_alive_diagnostic_tests
)
add_test(
  NAME IT-R19-GROUND-RUNTIME-ALIVE-STARVATION-001
  COMMAND vc_lora_phase6_ground_runtime_alive_starvation_tests
)
add_test(
  NAME IT-R19-GROUND-RUNTIME-ALIVE-BACKPRESSURE-001
  COMMAND vc_lora_phase6_ground_runtime_alive_backpressure_tests
)
add_test(
  NAME IT-R19-VEHICLE-RUNTIME-ALIVE-DIAGNOSTIC-001
  COMMAND vc_lora_phase6_vehicle_runtime_alive_diagnostic_tests
)
add_test(
  NAME IT-R19-VEHICLE-RUNTIME-ALIVE-READ-ONLY-BOOTSTRAP-001
  COMMAND vc_lora_phase6_vehicle_runtime_alive_read_only_bootstrap_tests
)
add_test(
  NAME IT-R19-GROUND-RUNTIME-ALIVE-READ-ONLY-BOOTSTRAP-001
  COMMAND vc_lora_phase6_ground_runtime_alive_read_only_bootstrap_tests
)
add_test(
  NAME IT-R19-GROUND-RUNTIME-FAIL-BOUNDARY-LOSS-001
  COMMAND vc_lora_phase6_ground_runtime_fail_boundary_loss_tests
)
add_test(
  NAME IT-R19-GROUND-RUNTIME-FAIL-DEADLINE-001
  COMMAND vc_lora_phase6_ground_runtime_fail_deadline_tests
)
add_test(
  NAME IT-R19-GROUND-RUNTIME-FAIL-PENDING-ALIVE-001
  COMMAND vc_lora_phase6_ground_runtime_fail_pending_alive_tests
)
add_test(
  NAME IT-R19-VEHICLE-RUNTIME-FAIL-STAGED-ZERO-001
  COMMAND vc_lora_phase6_vehicle_runtime_fail_staged_zero_tests
)
add_test(
  NAME IT-R19-VEHICLE-RUNTIME-FAIL-STAGED-PARTIAL-001
  COMMAND vc_lora_phase6_vehicle_runtime_fail_staged_partial_tests
)
add_test(
  NAME IT-R19-VEHICLE-RUNTIME-FAIL-PARTIAL-DEADLINE-001
  COMMAND vc_lora_phase6_vehicle_runtime_fail_partial_deadline_tests
)
add_test(
  NAME IT-R19-VEHICLE-RUNTIME-FAIL-FLUSH-DEADLINE-001
  COMMAND vc_lora_phase6_vehicle_runtime_fail_flush_deadline_tests
)
add_test(
  NAME IT-R19-VEHICLE-RUNTIME-FAIL-RECOVERY-EPOCH-001
  COMMAND vc_lora_phase6_vehicle_runtime_fail_recovery_guard_tests epoch
)
add_test(
  NAME IT-R19-VEHICLE-RUNTIME-FAIL-RECOVERY-EXPIRY-001
  COMMAND vc_lora_phase6_vehicle_runtime_fail_recovery_guard_tests expiry
)
add_test(
  NAME IT-R19-GROUND-RUNTIME-FAIL-RECOVERY-EPOCH-001
  COMMAND vc_lora_phase6_ground_runtime_fail_recovery_guard_tests epoch
)
add_test(
  NAME IT-R19-GROUND-RUNTIME-FAIL-RECOVERY-TARGET-001
  COMMAND vc_lora_phase6_ground_runtime_fail_recovery_guard_tests target
)
add_test(
  NAME IT-R19-GROUND-RUNTIME-FAIL-RECOVERY-EXPIRY-001
  COMMAND vc_lora_phase6_ground_runtime_fail_recovery_guard_tests expiry
)
set_tests_properties(
  IT-R19-GROUND-RUNTIME-FAIL-DIAGNOSTIC-001
  IT-R19-VEHICLE-RUNTIME-FAIL-DIAGNOSTIC-001
  IT-R19-GROUND-RUNTIME-ALIVE-DIAGNOSTIC-001
  IT-R19-GROUND-RUNTIME-ALIVE-STARVATION-001
  IT-R19-GROUND-RUNTIME-ALIVE-BACKPRESSURE-001
  IT-R19-VEHICLE-RUNTIME-ALIVE-DIAGNOSTIC-001
  IT-R19-VEHICLE-RUNTIME-ALIVE-READ-ONLY-BOOTSTRAP-001
  IT-R19-GROUND-RUNTIME-ALIVE-READ-ONLY-BOOTSTRAP-001
  IT-R19-GROUND-RUNTIME-FAIL-BOUNDARY-LOSS-001
  IT-R19-GROUND-RUNTIME-FAIL-DEADLINE-001
  IT-R19-GROUND-RUNTIME-FAIL-PENDING-ALIVE-001
  IT-R19-VEHICLE-RUNTIME-FAIL-STAGED-ZERO-001
  IT-R19-VEHICLE-RUNTIME-FAIL-STAGED-PARTIAL-001
  IT-R19-VEHICLE-RUNTIME-FAIL-PARTIAL-DEADLINE-001
  IT-R19-VEHICLE-RUNTIME-FAIL-FLUSH-DEADLINE-001
  IT-R19-VEHICLE-RUNTIME-FAIL-RECOVERY-EPOCH-001
  IT-R19-VEHICLE-RUNTIME-FAIL-RECOVERY-EXPIRY-001
  IT-R19-GROUND-RUNTIME-FAIL-RECOVERY-EPOCH-001
  IT-R19-GROUND-RUNTIME-FAIL-RECOVERY-TARGET-001
  IT-R19-GROUND-RUNTIME-FAIL-RECOVERY-EXPIRY-001
  PROPERTIES
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    TIMEOUT 30
    LABELS "r19;diagnostic;product-loop;offline"
)

# Compile and execute the actual production Ground bridge entry points under
# a deterministic Arduino platform double.  This deliberately remains a
# standalone translation unit: including the production adapter exactly once
# preserves its Arduino one-sketch ownership model and catches setup/loop-only
# failures that the platform-neutral core tests cannot observe.
add_executable(vc_lora_phase6_ground_product_loop_tests
  standalone/phase6_ground_product_loop_tests.cpp
)
target_link_libraries(vc_lora_phase6_ground_product_loop_tests PRIVATE
  vc_lora_core
)
target_include_directories(vc_lora_phase6_ground_product_loop_tests PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/fakes
  ${CMAKE_SOURCE_DIR}/firmware
  ${CMAKE_SOURCE_DIR}/core/include
)
target_compile_features(vc_lora_phase6_ground_product_loop_tests PRIVATE
  cxx_std_17
)
set_target_properties(vc_lora_phase6_ground_product_loop_tests PROPERTIES
  CXX_EXTENSIONS OFF
)
if(MSVC)
  target_compile_options(vc_lora_phase6_ground_product_loop_tests PRIVATE
    /W4 /permissive-
  )
else()
  target_compile_options(vc_lora_phase6_ground_product_loop_tests PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion
  )
  if(WIN32)
    target_link_options(vc_lora_phase6_ground_product_loop_tests PRIVATE
      -static
    )
  endif()
endif()

add_test(
  NAME IT-R19-GROUND-PRODUCT-LOOP-COLD-BOOT-001
  COMMAND vc_lora_phase6_ground_product_loop_tests
    --output-dir=${CMAKE_SOURCE_DIR}/runs/IT-R19-GROUND-PRODUCT-LOOP-COLD-BOOT-001
)
set_tests_properties(IT-R19-GROUND-PRODUCT-LOOP-COLD-BOOT-001 PROPERTIES
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  TIMEOUT 30
  LABELS "r19;phase6;product-loop;offline"
)

add_executable(vc_lora_phase6_vehicle_product_loop_tests
  standalone/phase6_vehicle_product_loop_tests.cpp
)
target_link_libraries(vc_lora_phase6_vehicle_product_loop_tests PRIVATE
  vc_lora_core
)
target_include_directories(vc_lora_phase6_vehicle_product_loop_tests PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/fakes
  ${CMAKE_SOURCE_DIR}/firmware
  ${CMAKE_SOURCE_DIR}/core/include
)
target_compile_features(vc_lora_phase6_vehicle_product_loop_tests PRIVATE
  cxx_std_17
)
set_target_properties(vc_lora_phase6_vehicle_product_loop_tests PROPERTIES
  CXX_EXTENSIONS OFF
)
if(MSVC)
  target_compile_options(vc_lora_phase6_vehicle_product_loop_tests PRIVATE
    /W4 /permissive-
  )
else()
  target_compile_options(vc_lora_phase6_vehicle_product_loop_tests PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion
  )
  if(WIN32)
    target_link_options(vc_lora_phase6_vehicle_product_loop_tests PRIVATE
      -static
    )
  endif()
endif()

add_test(
  NAME IT-R19-VEHICLE-PRODUCT-LOOP-COLD-BOOT-001
  COMMAND vc_lora_phase6_vehicle_product_loop_tests
    --output-dir=${CMAKE_SOURCE_DIR}/runs/IT-R19-VEHICLE-PRODUCT-LOOP-COLD-BOOT-001
)
set_tests_properties(IT-R19-VEHICLE-PRODUCT-LOOP-COLD-BOOT-001 PROPERTIES
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  TIMEOUT 30
  LABELS "r19;phase6;product-loop;offline"
)

set(VC_LORA_TEST_IDS
  FW-BUF-001
  FW-UART-001
  FW-USB-DISCONNECT-001
  FW-SESSION-001
  FW-TIME-001
  FW-AUX-001
  FW-CONTRACT-001
  FW-USB-EPOCH-RECOVERY-001
  FW-E220-STARTUP-001
  FW-MAV-001
  FW-MAV-002
  FW-SCHED-001
  FW-CONTROL-WIRE-001
  PHASE1-LEGACY-COLLISION
  PHASE1-LEGACY-INVARIANT
  UT-CODEC-001
  UT-CODEC-002
  UT-CODEC-003
  UT-CODEC-004
  UT-CODEC-005
  UT-CODEC-006
  UT-CODEC-007
  UT-DEMUX-001
  UT-CONTROL-V2-WIRE-001
  UT-CONTROL-V2-CORRUPTION-001
  UT-CONTROL-V2-STREAM-001
  UT-CONTROL-V2-DEMUX-001
  UT-CONTROL-V2-VCTA-DEMUX-001
  UT-CONTROL-V2-VCB1-DEMUX-001
  UT-CONTROL-V2-VCBN-DEMUX-001
  UT-CONTROL-V2-VCRC-DEMUX-001
  UT-CONTROL-V2-MIXED-001
  UT-BUF-001
  UT-BUF-002
  UT-BUF-003
  UT-BUF-004
  UT-BUF-005
  UT-GATE-001
  UT-GATE-002
  UT-GATE-003
  UT-GATE-004
  UT-GATE-005
  UT-GATE-006
  UT-GATE-007
  UT-GROUND-BOUNDED-CONTINUATION-001
  UT-LINK-001
  UT-LINK-002
  UT-LINK-003
  UT-LINK-004
  UT-LINK-005
  UT-LINK-006
  UT-LINK-ACCOUNT-001
  UT-LINK-ACCOUNT-002
  UT-LINK-ACCOUNT-003
  UT-BULK-WIRE-001
  UT-BULK-WIRE-002
  UT-BULK-WIRE-003
  UT-BULK-WIRE-004
  UT-BULK-WIRE-005
  UT-BULK-WIRE-006
  UT-BULK-WIRE-007
  UT-BULK-WIRE-008
  UT-BULK-WIRE-009
  IT-BULK-RX-REARM-001
  IT-BULK-DEMUX-DECODER-001
  IT-BULK-WIRE-PARAM-932-001
  IT-BULK-BUDGET-001
  UT-BULK-TX-LEASE-001
  UT-BULK-TX-LEASE-002
  UT-BULK-TX-LEASE-003
  UT-BULK-TX-LEASE-004
  UT-BULK-TX-LEASE-005
  UT-BULK-TX-LEASE-006
  UT-BULK-TX-LEASE-007
  UT-BULK-TX-LEASE-008
  UT-BULK-TX-LEASE-009
  UT-BULK-HB-POLICY-001
  UT-BULK-HB-POLICY-002
  UT-BULK-HB-POLICY-003
  UT-BULK-HB-POLICY-004
  UT-BULK-HB-POLICY-005
  UT-BULK-HB-POLICY-006
  UT-BULK-HB-SLA-001
  UT-BULK-HB-SLA-002
  UT-BULK-HB-SLA-003
  UT-BULK-HB-SLA-004
  UT-BULK-HB-SLA-005
  UT-BULK-TRANSCRIPT-001
  UT-BULK-TRANSCRIPT-002
  UT-BULK-TRANSCRIPT-003
  UT-BULK-TRANSCRIPT-004
  UT-BULK-TRANSCRIPT-005
  UT-BULK-TRANSCRIPT-006
  UT-BULK-TRANSCRIPT-007
  UT-BULK-TRANSCRIPT-008
  UT-BULK-NEG-WIRE-001
  UT-BULK-NEG-WIRE-002
  UT-BULK-NEG-WIRE-003
  UT-BULK-NEG-WIRE-004
  UT-BULK-NEG-WIRE-005
  UT-BULK-SESSION-001
  UT-BULK-SESSION-002
  UT-BULK-SESSION-003
  UT-BULK-SESSION-004
  UT-BULK-SESSION-005
  UT-HS-TDD-COORD-001
  UT-HS-TDD-COORD-002
  UT-HS-TDD-COORD-003
  UT-HS-TDD-COORD-004
  UT-HS-TDD-COORD-005
  UT-HS-TDD-COORD-006
  UT-HS-TDD-COORD-007
  UT-HS-TDD-COORD-008
  UT-HS-PHASE6-ADAPTER-001
  UT-HS-PHASE6-ADAPTER-002
  UT-HS-PHASE6-ADAPTER-003
  UT-HS-PHASE6-ADAPTER-004
  UT-HS-PHASE6-ADAPTER-005
  UT-HS-PHASE6-ADAPTER-006
  UT-HS-PHASE6-ADAPTER-007
  UT-HS-RADIO-WRITER-001
  UT-HS-RADIO-WRITER-002
  UT-HS-RADIO-WRITER-003
  UT-HS-RADIO-WRITER-004
  UT-HS-RADIO-SESSION-001
  UT-HS-RADIO-SESSION-002
  UT-HS-RADIO-SESSION-003
  UT-PEER-COMPLETION-WIRE-001
  UT-PEER-COMPLETION-WIRE-002
  UT-PEER-COMPLETION-LEDGER-001
  UT-PEER-COMPLETION-LEDGER-002
  UT-PEER-COMPLETION-DEADLINE-001
  UT-HS-PEER-COMPLETION-001
  UT-HS-VCRC-AUX-NOT-PROOF-001
  UT-HS-VCRC-MISSING-TIMEOUT-001
  UT-HS-BULK-RX-TAIL-LEDGER-001
  UT-HS-ROLE-CONFIG-001
  UT-HS-PRODUCT-WRITER-SOURCE-001
  UT-HS-PRODUCT-ROUTE-SOURCE-001
  IT-HS-ROUTE-E2E-001
  IT-HS-CANDIDATE-STANDARD-001
  UT-BULK-TX-LEASE-010
  UT-BULK-TX-LEASE-011
  UT-BULK-TX-LEASE-012
  UT-BULK-TX-LEASE-013
  UT-MAV-BOUNDARY-001
  UT-MAV-BOUNDARY-002
  UT-MAV-BOUNDARY-003
  UT-MAV-BOUNDARY-004
  UT-MAV-BOUNDARY-005
  UT-MAV-BOUNDARY-006
  UT-MAV-BOUNDARY-007
  UT-MAV-BOUNDARY-008
  UT-UPLINK-GUARD-DATA-001
  UT-UPLINK-GUARD-DATA-002
  UT-UPLINK-GUARD-CONTROL-001
  UT-UPLINK-GUARD-CONTROL-002
  UT-UPLINK-GRANT-DRAIN-001
  UT-UPLINK-GUARD-EPOCH-001
  UT-UPLINK-IDENTITY-001
  UT-UPLINK-RESIDUAL-ESCAPE-001
  UT-UPLINK-RESIDUAL-CONTROL-001
  UT-UPLINK-RESIDUAL-DONE-001
  UT-UPLINK-RESIDUAL-TIMEOUT-001
  FW-UPLINK-RESIDUAL-CONTRACT-001
  UT-UPLINK-LATE-COMMIT-001
  UT-UPLINK-LATE-IDLE-001
  UT-UPLINK-LATE-IDENTITY-001
  UT-UPLINK-LATE-TERMINAL-001
  UT-UPLINK-LATE-INTEGRITY-001
  UT-UPLINK-LATE-OVERFLOW-001
  UT-UPLINK-LATE-ISOLATION-001
  UT-UPLINK-LATE-64B-001
  UT-UPLINK-LATE-TIMING-001
  UT-UPLINK-LATE-NORMAL-001
  IT-UPLINK-LATE-ESCAPE-001
  IT-UPLINK-LATE-HIL-001
  IT-UPLINK-GUARD-001
  IT-CONTROL-SUBPACKET-TIMING-001
  IT-CONTROL-SUBPACKET-MSG20-001
  IT-CONTROL-SUBPACKET-HB-SLOT-001
  IT-E220-BUFFERED-UPLINK-001
  IT-E220-BUFFERED-RF-HB-RED-001
  IT-E220-BUFFERED-VEHICLE-PARAM-PRIORITY-001
  IT-E220-BUFFERED-R2-HB-DEADLINE-001
  UT-GROUND-USB-HB-PACER-INTEGRITY-001
  IT-GROUND-USB-HB-PACER-TIMING-001
  UT-GROUND-USB-HB-PACER-DISCONNECT-001
  UT-GROUND-USB-HB-PACER-BOUNDARY-001
  UT-GROUND-USB-HB-PACER-SUPPLY-001
  IT-GROUND-USB-HB-PHASE6-ORDER-001
  IT-GROUND-USB-HB-PHASE6-HOST-FILTER-001
  IT-GROUND-USB-HB-PHASE6-ENDPOINT-DIP-001
  IT-GROUND-USB-HB-PHASE6-FAILSAFE-001
  IT-GROUND-USB-HB-PHASE6-DUE-001
  IT-GROUND-USB-HB-PHASE6-BURST-001
  IT-GROUND-USB-HB-PHASE6-PREGRANT-RESERVE-001
  IT-GROUND-USB-HB-PHASE6-HOST-DRAIN-001
  IT-GROUND-USB-HB-PHASE6-FLUSH-ISOLATION-001
  IT-GROUND-USB-HB-PHASE6-STALE-001
  UT-GROUND-USB-HB-BACKLOG-CAPACITY-001
  IT-GROUND-USB-HB-PHASE6-SOURCE-001
  UT-PARAM-PROXY-MP-V2-TRUNCATION-001
  UT-PARAM-PROXY-LIST-001
  UT-PARAM-PROXY-NATIVE-STREAM-001
  UT-PARAM-PROXY-NATIVE-RECOVERY-EXHAUSTION-001
  UT-PARAM-PROXY-MATCH-001
  UT-PARAM-PROXY-RETRY-001
  UT-PARAM-PROXY-DUPLICATE-001
  UT-PARAM-PROXY-BOUNDS-001
  UT-PARAM-PROXY-RESET-001
  UT-PARAM-PROXY-REGRESSION-001
  IT-PARAM-PROXY-HEARTBEAT-001
  IT-PARAM-PROXY-R15-PERIODIC-BOUND-001
  IT-PARAM-PROXY-ADMISSION-WATCHDOG-001
  IT-PARAM-PROXY-MP-STARTUP-BACKLOG-001
  IT-PARAM-PROXY-TDD-V2-001
  UT-MAV-001
  UT-MAV-002
  UT-MAV-003
  UT-MAV-004
  UT-MAV-005
  UT-MAV-006
  UT-MAV-007
  UT-MAV-008
  UT-MAV-009
  UT-MAV-010
  UT-MAV-011
  UT-MAV-012
  UT-MAV-013
  UT-VEHICLE-PARAM-PRIORITY-BACKLOG-001
  UT-VEHICLE-PARAM-PRIORITY-RETRY-001
  UT-VEHICLE-PARAM-PRIORITY-MATCH-001
  UT-VEHICLE-PARAM-PRIORITY-BOUNDARY-001
  UT-VEHICLE-PARAM-PRIORITY-NATIVE-FENCE-001
  UT-VEHICLE-PARAM-PRIORITY-PHASE6-001
  E2E-MAV-001
  E2E-MAV-002
  E2E-MAV-003
  E2E-MAV-004
  E2E-MAV-005
  E2E-MAV-006
  E2E-MAV-007
  E2E-MAV-008
  E2E-MAV-009
  E2E-MAV-010
  ST-MAV-001
  ST-MAV-PHASE-001
  IT-TDD-001
  IT-TDD-002
  IT-TDD-003
  IT-TDD-004
  IT-TDD-005
  IT-TDD-006
  IT-TDD-007
  IT-TDD-008
  IT-TDD-009
  IT-TDD-010
  IT-TDD-011
  IT-TDD-012
  IT-TDD-013
  IT-TDD-014
  IT-TDD-015
  IT-RF-HDX-001
  IT-BUF-001
  IT-BUF-002
  IT-BUF-003
  IT-BUF-004
  IT-BUF-005
  IT-BUF-006
  ST-001
  ST-002
  ST-003
  ST-004
  ST-005
  ST-006
)

foreach(test_id IN LISTS VC_LORA_TEST_IDS)
  add_test(
    NAME ${test_id}
    COMMAND vc_lora_host_tests
      --test-case=${test_id}
      --seed=20260817
      --output-dir=${CMAKE_SOURCE_DIR}/runs/${test_id}
  )
  set_tests_properties(${test_id} PROPERTIES
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    TIMEOUT 30
  )
endforeach()

add_test(
  NAME UT-E220-CONTINUOUS-AUX-CREDIT-001
  COMMAND vc_lora_e220_continuous_aux_credit_tests
)
set_tests_properties(UT-E220-CONTINUOUS-AUX-CREDIT-001 PROPERTIES
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  TIMEOUT 30
  LABELS phase4
)

set_tests_properties(
  FW-BUF-001 FW-UART-001 FW-USB-DISCONNECT-001 FW-SESSION-001
  FW-TIME-001 FW-AUX-001
  FW-CONTRACT-001 FW-USB-EPOCH-RECOVERY-001 FW-E220-STARTUP-001
  FW-MAV-001 FW-MAV-002 FW-SCHED-001
  FW-CONTROL-WIRE-001
  PROPERTIES LABELS phase6
)

set_tests_properties(PHASE1-LEGACY-COLLISION PROPERTIES LABELS phase1)
set_tests_properties(PHASE1-LEGACY-INVARIANT PROPERTIES
  LABELS phase1
  WILL_FAIL TRUE
)
set_tests_properties(
  IT-TDD-001 IT-TDD-002 IT-TDD-003 IT-TDD-004 IT-TDD-005
  IT-TDD-006 IT-TDD-007 IT-TDD-008 IT-TDD-009 IT-TDD-010
  IT-TDD-011 IT-TDD-012 IT-TDD-013 IT-TDD-014 IT-TDD-015
  PROPERTIES LABELS phase2
)
set_tests_properties(IT-RF-HDX-001 PROPERTIES LABELS phase2)
set_tests_properties(
  UT-BUF-001 UT-BUF-002 UT-BUF-003 UT-BUF-004 UT-BUF-005
  IT-BUF-001 IT-BUF-002 IT-BUF-003 IT-BUF-004 IT-BUF-005 IT-BUF-006
  PROPERTIES LABELS phase3
)
set_tests_properties(
  UT-LINK-001 UT-LINK-002 UT-LINK-003 UT-LINK-004 UT-LINK-005
  UT-LINK-006 UT-LINK-ACCOUNT-001 UT-LINK-ACCOUNT-002
  UT-LINK-ACCOUNT-003
  UT-BULK-WIRE-001 UT-BULK-WIRE-002 UT-BULK-WIRE-003
  UT-BULK-WIRE-004 UT-BULK-WIRE-005 UT-BULK-WIRE-006
  UT-BULK-WIRE-007 UT-BULK-WIRE-008 UT-BULK-WIRE-009
  IT-BULK-RX-REARM-001
  IT-BULK-DEMUX-DECODER-001 IT-BULK-WIRE-PARAM-932-001
  IT-BULK-BUDGET-001
  UT-BULK-TX-LEASE-001 UT-BULK-TX-LEASE-002 UT-BULK-TX-LEASE-003
  UT-BULK-TX-LEASE-004 UT-BULK-TX-LEASE-005 UT-BULK-TX-LEASE-006
  UT-BULK-TX-LEASE-007 UT-BULK-TX-LEASE-008 UT-BULK-TX-LEASE-009
  UT-BULK-HB-POLICY-001 UT-BULK-HB-POLICY-002
  UT-BULK-HB-POLICY-003 UT-BULK-HB-POLICY-004
  UT-BULK-HB-POLICY-005 UT-BULK-HB-POLICY-006
  UT-BULK-HB-SLA-001 UT-BULK-HB-SLA-002 UT-BULK-HB-SLA-003
  UT-BULK-HB-SLA-004 UT-BULK-HB-SLA-005
  UT-BULK-TRANSCRIPT-001 UT-BULK-TRANSCRIPT-002
  UT-BULK-TRANSCRIPT-003 UT-BULK-TRANSCRIPT-004
  UT-BULK-TRANSCRIPT-005 UT-BULK-TRANSCRIPT-006
  UT-BULK-TRANSCRIPT-007 UT-BULK-TRANSCRIPT-008
  UT-BULK-NEG-WIRE-001 UT-BULK-NEG-WIRE-002 UT-BULK-NEG-WIRE-003
  UT-BULK-NEG-WIRE-004 UT-BULK-NEG-WIRE-005
  UT-BULK-SESSION-001 UT-BULK-SESSION-002 UT-BULK-SESSION-003
  UT-BULK-SESSION-004 UT-BULK-SESSION-005
  UT-HS-TDD-COORD-001 UT-HS-TDD-COORD-002 UT-HS-TDD-COORD-003
  UT-HS-TDD-COORD-004 UT-HS-TDD-COORD-005 UT-HS-TDD-COORD-006
  UT-HS-TDD-COORD-007 UT-HS-TDD-COORD-008
  UT-HS-PHASE6-ADAPTER-001 UT-HS-PHASE6-ADAPTER-002
  UT-HS-PHASE6-ADAPTER-003 UT-HS-PHASE6-ADAPTER-004
  UT-HS-PHASE6-ADAPTER-005 UT-HS-PHASE6-ADAPTER-006
  UT-HS-PHASE6-ADAPTER-007
  UT-HS-RADIO-WRITER-001 UT-HS-RADIO-WRITER-002
  UT-HS-RADIO-WRITER-003 UT-HS-RADIO-WRITER-004
  UT-HS-RADIO-SESSION-001 UT-HS-RADIO-SESSION-002
  UT-HS-RADIO-SESSION-003
  UT-PEER-COMPLETION-WIRE-001 UT-PEER-COMPLETION-WIRE-002
  UT-PEER-COMPLETION-LEDGER-001 UT-PEER-COMPLETION-LEDGER-002
  UT-PEER-COMPLETION-DEADLINE-001
  UT-HS-PEER-COMPLETION-001
  UT-HS-VCRC-AUX-NOT-PROOF-001 UT-HS-VCRC-MISSING-TIMEOUT-001
  UT-HS-BULK-RX-TAIL-LEDGER-001
  UT-HS-ROLE-CONFIG-001
  UT-HS-PRODUCT-WRITER-SOURCE-001
  UT-HS-PRODUCT-ROUTE-SOURCE-001
  IT-HS-ROUTE-E2E-001
  IT-HS-CANDIDATE-STANDARD-001
  UT-BULK-TX-LEASE-010 UT-BULK-TX-LEASE-011
  UT-BULK-TX-LEASE-012 UT-BULK-TX-LEASE-013
  UT-MAV-BOUNDARY-001 UT-MAV-BOUNDARY-002 UT-MAV-BOUNDARY-003
  UT-MAV-BOUNDARY-004 UT-MAV-BOUNDARY-005 UT-MAV-BOUNDARY-006
  UT-MAV-BOUNDARY-007 UT-MAV-BOUNDARY-008
  UT-UPLINK-GUARD-DATA-001 UT-UPLINK-GUARD-DATA-002
  UT-UPLINK-GUARD-CONTROL-001 UT-UPLINK-GUARD-CONTROL-002
  UT-UPLINK-GRANT-DRAIN-001 UT-UPLINK-GUARD-EPOCH-001
  UT-UPLINK-IDENTITY-001
  UT-UPLINK-RESIDUAL-ESCAPE-001 UT-UPLINK-RESIDUAL-CONTROL-001
  UT-UPLINK-RESIDUAL-DONE-001 UT-UPLINK-RESIDUAL-TIMEOUT-001
  UT-UPLINK-LATE-COMMIT-001 UT-UPLINK-LATE-IDLE-001
  UT-UPLINK-LATE-IDENTITY-001 UT-UPLINK-LATE-TERMINAL-001
  UT-UPLINK-LATE-INTEGRITY-001
  UT-UPLINK-LATE-OVERFLOW-001 UT-UPLINK-LATE-ISOLATION-001
  UT-UPLINK-LATE-64B-001 UT-UPLINK-LATE-TIMING-001
  UT-UPLINK-LATE-NORMAL-001 IT-UPLINK-LATE-ESCAPE-001
  IT-UPLINK-LATE-HIL-001
  IT-UPLINK-GUARD-001
  UT-CONTROL-V2-WIRE-001 UT-CONTROL-V2-CORRUPTION-001
  UT-CONTROL-V2-STREAM-001 UT-CONTROL-V2-DEMUX-001
  UT-CONTROL-V2-VCTA-DEMUX-001
  UT-CONTROL-V2-VCB1-DEMUX-001
  UT-CONTROL-V2-VCBN-DEMUX-001
  UT-CONTROL-V2-VCRC-DEMUX-001
  UT-CONTROL-V2-MIXED-001
  IT-CONTROL-SUBPACKET-TIMING-001
  IT-CONTROL-SUBPACKET-MSG20-001
  IT-CONTROL-SUBPACKET-HB-SLOT-001
  IT-E220-BUFFERED-UPLINK-001
  IT-E220-BUFFERED-VEHICLE-PARAM-PRIORITY-001
  IT-E220-BUFFERED-R2-HB-DEADLINE-001
  UT-GROUND-USB-HB-PACER-INTEGRITY-001
  IT-GROUND-USB-HB-PACER-TIMING-001
  UT-GROUND-USB-HB-PACER-DISCONNECT-001
  UT-GROUND-USB-HB-PACER-BOUNDARY-001
  UT-GROUND-USB-HB-PACER-SUPPLY-001
  IT-GROUND-USB-HB-PHASE6-ORDER-001
  IT-GROUND-USB-HB-PHASE6-HOST-FILTER-001
  IT-GROUND-USB-HB-PHASE6-ENDPOINT-DIP-001
  IT-GROUND-USB-HB-PHASE6-FAILSAFE-001
  IT-GROUND-USB-HB-PHASE6-DUE-001
  IT-GROUND-USB-HB-PHASE6-BURST-001
  IT-GROUND-USB-HB-PHASE6-PREGRANT-RESERVE-001
  IT-GROUND-USB-HB-PHASE6-HOST-DRAIN-001
  IT-GROUND-USB-HB-PHASE6-FLUSH-ISOLATION-001
  IT-GROUND-USB-HB-PHASE6-STALE-001
  UT-GROUND-USB-HB-BACKLOG-CAPACITY-001
  IT-GROUND-USB-HB-PHASE6-SOURCE-001
  UT-PARAM-PROXY-MP-V2-TRUNCATION-001
  UT-PARAM-PROXY-LIST-001 UT-PARAM-PROXY-NATIVE-STREAM-001
  UT-PARAM-PROXY-NATIVE-RECOVERY-EXHAUSTION-001
  UT-PARAM-PROXY-MATCH-001
  UT-PARAM-PROXY-RETRY-001 UT-PARAM-PROXY-DUPLICATE-001
  UT-PARAM-PROXY-BOUNDS-001 UT-PARAM-PROXY-RESET-001
  UT-PARAM-PROXY-REGRESSION-001 IT-PARAM-PROXY-HEARTBEAT-001
  IT-PARAM-PROXY-R15-PERIODIC-BOUND-001
  IT-PARAM-PROXY-ADMISSION-WATCHDOG-001
  IT-PARAM-PROXY-MP-STARTUP-BACKLOG-001 IT-PARAM-PROXY-TDD-V2-001
  UT-MAV-001 UT-MAV-002 UT-MAV-003 UT-MAV-004 UT-MAV-005
  UT-MAV-006 UT-MAV-007 UT-MAV-008 UT-MAV-009 UT-MAV-010 UT-MAV-011
  UT-MAV-012 UT-MAV-013
  UT-VEHICLE-PARAM-PRIORITY-BACKLOG-001
  UT-VEHICLE-PARAM-PRIORITY-RETRY-001
  UT-VEHICLE-PARAM-PRIORITY-MATCH-001
  UT-VEHICLE-PARAM-PRIORITY-BOUNDARY-001
  UT-VEHICLE-PARAM-PRIORITY-NATIVE-FENCE-001
  UT-VEHICLE-PARAM-PRIORITY-PHASE6-001
  E2E-MAV-001 E2E-MAV-002 E2E-MAV-003 E2E-MAV-004 E2E-MAV-005
  E2E-MAV-006 E2E-MAV-007 E2E-MAV-008 E2E-MAV-009
  E2E-MAV-010
  PROPERTIES LABELS phase4
)
set_tests_properties(FW-UPLINK-RESIDUAL-CONTRACT-001 PROPERTIES LABELS phase6)
set_tests_properties(IT-E220-BUFFERED-RF-HB-RED-001 PROPERTIES
  LABELS diagnostic
  WILL_FAIL TRUE
)
set_tests_properties(IT-BUF-006 PROPERTIES TIMEOUT 60)
set_tests_properties(
  ST-MAV-001 ST-MAV-PHASE-001 ST-001 ST-002 ST-003 ST-004 ST-005 ST-006
  PROPERTIES LABELS phase5 TIMEOUT 300
)
set_tests_properties(ST-MAV-001 ST-MAV-PHASE-001 ST-001
  PROPERTIES TIMEOUT 600)
