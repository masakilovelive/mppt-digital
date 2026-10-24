cmake_minimum_required(VERSION 3.20)

project(vc_lora_host LANGUAGES CXX)

option(VC_LORA_BUILD_TESTS "Build deterministic VC LoRa host tests" ON)
option(VC_LORA_ENABLE_SANITIZERS
  "Instrument host targets with AddressSanitizer and UndefinedBehaviorSanitizer"
  OFF
)

if(VC_LORA_ENABLE_SANITIZERS)
  if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    message(FATAL_ERROR
      "VC_LORA_ENABLE_SANITIZERS requires a Clang-family compiler"
    )
  endif()

  message(STATUS "VC LoRa host sanitizers: address,undefined")
  add_compile_options(
    -fsanitize=address,undefined
    -fno-omit-frame-pointer
    -fno-sanitize-recover=all
  )
  add_link_options(
    -fsanitize=address,undefined
    -fno-sanitize-recover=all
  )
endif()

add_library(vc_lora_core
  core/src/bulk_heartbeat_sla.cpp
  core/src/bulk_negotiation_codec.cpp
  core/src/bulk_session_controller.cpp
  core/src/bulk_transcript.cpp
  core/src/high_speed_tdd_coordinator.cpp
  core/src/bulk_data_codec.cpp
  core/src/bulk_tx_lease.cpp
  core/src/ground_usb_heartbeat_pacer.cpp
  core/src/ground_parameter_download_proxy.cpp
  core/src/late_uplink_recovery.cpp
  core/src/link_data_codec.cpp
  core/src/link_diagnostics.cpp
  core/src/mavlink_frame.cpp
  core/src/mavlink_scheduler.cpp
  core/src/runtime_contract.cpp
  core/src/tdd_control_codec.cpp
  core/src/tdd_ground.cpp
  core/src/tdd_link_demux.cpp
  core/src/tdd_vehicle.cpp
  core/src/tx_gate.cpp
)

target_include_directories(vc_lora_core PUBLIC core/include)
target_compile_features(vc_lora_core PUBLIC cxx_std_17)
set_target_properties(vc_lora_core PROPERTIES CXX_EXTENSIONS OFF)

if(MSVC)
  target_compile_options(vc_lora_core PRIVATE /W4 /permissive-)
else()
  target_compile_options(vc_lora_core PRIVATE -Wall -Wextra -Wpedantic -Wconversion)
endif()

if(VC_LORA_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests/host)

  if(WIN32)
    find_program(VC_LORA_POWERSHELL_EXECUTABLE
      NAMES pwsh powershell
      REQUIRED
    )

    foreach(r19_new_contract IN ITEMS diagnostic_usb_failure_record usb_role_contract diagnostic_usb_outer_contract diagnostic_usb_outer_raw)
      add_test(NAME R19-${r19_new_contract}-CONTRACT-001
        COMMAND "${VC_LORA_POWERSHELL_EXECUTABLE}"
          -NoProfile -NonInteractive -ExecutionPolicy Bypass
          -File "${CMAKE_SOURCE_DIR}/tests/hil/check_r19_${r19_new_contract}.ps1"
          -RepoRoot "${CMAKE_SOURCE_DIR}")
    endforeach()

    add_test(
      NAME FW-R19-CANDIDATE-ARTIFACT-BUILDER-001
      COMMAND "${VC_LORA_POWERSHELL_EXECUTABLE}"
        -NoProfile -NonInteractive -ExecutionPolicy Bypass
        -File
        "${CMAKE_SOURCE_DIR}/tests/arduino_compile/check_r19_candidate_artifact_builder_contract.ps1"
        -RepoRoot "${CMAKE_SOURCE_DIR}"
    )
    add_test(
      NAME FW-HWCDC-INSTALLER-CONTRACT-001
      COMMAND "${VC_LORA_POWERSHELL_EXECUTABLE}"
        -NoProfile -NonInteractive -ExecutionPolicy Bypass
        -File
        "${CMAKE_SOURCE_DIR}/tests/arduino_compile/check_hwcdc_installer_contract.ps1"
        -RepoRoot "${CMAKE_SOURCE_DIR}"
    )
    add_test(
      NAME R19-CANDIDATE-APP-FLASH-ORCHESTRATOR-CONTRACT-001
      COMMAND "${VC_LORA_POWERSHELL_EXECUTABLE}"
        -NoProfile -NonInteractive -ExecutionPolicy Bypass
        -File
        "${CMAKE_SOURCE_DIR}/tests/hil/check_r19_candidate_flash_orchestrator_contract.ps1"
        -RepoRoot "${CMAKE_SOURCE_DIR}"
    )
    add_test(
      NAME R19-PIXHAWK-PARAM-LIST-E2E-RUNNER-CONTRACT-001
      COMMAND "${VC_LORA_POWERSHELL_EXECUTABLE}"
        -NoProfile -NonInteractive -ExecutionPolicy Bypass
        -File
        "${CMAKE_SOURCE_DIR}/tests/hil/check_r19_pixhawk_param_list_e2e_runner_contract.ps1"
        -RepoRoot "${CMAKE_SOURCE_DIR}"
    )
    add_test(
      NAME R19-RUNTIME-FAIL-DIAGNOSTIC-RUNNER-CONTRACT-001
      COMMAND "${VC_LORA_POWERSHELL_EXECUTABLE}"
        -NoProfile -NonInteractive -ExecutionPolicy Bypass
        -File
        "${CMAKE_SOURCE_DIR}/tests/hil/check_r19_runtime_fail_diagnostic_hil_runner_contract.ps1"
        -RepoRoot "${CMAKE_SOURCE_DIR}"
    )
    add_test(
      NAME R19-STARTUP-READER-OFFLINE-CONTRACT-001
      COMMAND "${VC_LORA_POWERSHELL_EXECUTABLE}"
        -NoProfile -NonInteractive -ExecutionPolicy Bypass
        -File
        "${CMAKE_SOURCE_DIR}/tests/hil/check_r19_startup_reader_contract.ps1"
        -RepoRoot "${CMAKE_SOURCE_DIR}"
    )
    add_test(
      NAME R19-STARTUP-READER-OFFLINE-INTEGRATION-001
      COMMAND "${VC_LORA_POWERSHELL_EXECUTABLE}"
        -NoProfile -NonInteractive -ExecutionPolicy Bypass
        -File
        "${CMAKE_SOURCE_DIR}/tests/hil/check_r19_startup_reader_integration.ps1"
        -RepoRoot "${CMAKE_SOURCE_DIR}"
    )
    foreach(r19_contract continuous_reader_contract continuous_reader_integration
        host_readiness_wire host_readiness_workflow startup_boundary_evaluation
        timed_path_trace timed_path_acquisition timed_path_capture_entrypoint timed_path_capture_persistence
        timed_path_artifact_contract timed_path_outer
        timed_path_outer_raw read_comparison_capture_contract read_comparison_permit
        param_list_diagnostics param_list_capture_contract param_list_outer_contract aux_readiness_record aux_readiness_artifact
        aux_readiness_bridge aux_readiness_outer aux_readiness_capture_routing)
      add_test(NAME R19-${r19_contract}-OFFLINE-001
        COMMAND "${VC_LORA_POWERSHELL_EXECUTABLE}"
          -NoProfile -NonInteractive -ExecutionPolicy Bypass -File
          "${CMAKE_SOURCE_DIR}/tests/hil/check_r19_${r19_contract}.ps1"
          -RepoRoot "${CMAKE_SOURCE_DIR}")
    endforeach()
    add_test(NAME R19-HOST-READINESS-INTEGRATION-OFFLINE-001
      COMMAND "${VC_LORA_POWERSHELL_EXECUTABLE}"
        -NoProfile -NonInteractive -ExecutionPolicy Bypass -File
        "${CMAKE_SOURCE_DIR}/tests/host/standalone/check_r19_host_readiness_integration.ps1"
        -RepoRoot "${CMAKE_SOURCE_DIR}")
    add_test(
      NAME R19-USB-EXTENDED-RECORDS-OFFLINE-CONTRACT-001
      COMMAND "${VC_LORA_POWERSHELL_EXECUTABLE}"
        -NoProfile -NonInteractive -ExecutionPolicy Bypass
        -File
        "${CMAKE_SOURCE_DIR}/tests/arduino_compile/check_r19_usb_extended_records_reader_contract.ps1"
    )
    add_test(
      NAME R19-USB-EXTENDED-LIVE-READER-CONTRACT-001
      COMMAND "${VC_LORA_POWERSHELL_EXECUTABLE}"
        -NoProfile -NonInteractive -ExecutionPolicy Bypass
        -File
        "${CMAKE_SOURCE_DIR}/tests/arduino_compile/check_r19_usb_extended_live_reader_contract.ps1"
    )
    add_test(NAME UT-R19-HWCDC-FLUSH-CALL-EVIDENCE-001
      COMMAND "${VC_LORA_POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive
      -ExecutionPolicy Bypass -File
      "${CMAKE_SOURCE_DIR}/tests/arduino_compile/check_r19_hwcdc_flush_call_evidence_behavior.ps1"
      -RepoRoot "${CMAKE_SOURCE_DIR}" -Compiler "${CMAKE_CXX_COMPILER}")
    foreach(first_cause_contract IN ITEMS
        "arduino_compile/check_r19_first_usb_failure_record_contract.ps1"
        "arduino_compile/check_r19_first_failure_packaging_contract.ps1"
        "hil/check_r19_first_usb_failure_outer_contract.ps1"
        "hil/check_r19_runtime_stage_cause_experiment_orchestrator_contract.ps1"
        "hil/check_r19_usb_clock_correlation_contract.ps1"
        "hil/check_r19_pc_lifecycle_trace_contract.ps1")
      get_filename_component(first_cause_name "${first_cause_contract}" NAME_WE)
      set(first_cause_powershell "${VC_LORA_POWERSHELL_EXECUTABLE}")
      if(first_cause_name STREQUAL
          "check_r19_runtime_stage_cause_experiment_orchestrator_contract")
        # The native child-launch fixture intentionally uses the same
        # Windows PowerShell host as the live orchestrator ($PSHOME).
        find_program(VC_LORA_WINDOWS_POWERSHELL_EXECUTABLE
          NAMES powershell.exe powershell REQUIRED)
        set(first_cause_powershell "${VC_LORA_WINDOWS_POWERSHELL_EXECUTABLE}")
      endif()
      add_test(NAME "${first_cause_name}"
        COMMAND "${first_cause_powershell}" -NoProfile -NonInteractive
        -ExecutionPolicy Bypass -File
        "${CMAKE_SOURCE_DIR}/tests/${first_cause_contract}")
      set_tests_properties("${first_cause_name}" PROPERTIES
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}" LABELS "r19;contract;offline" TIMEOUT 120)
    endforeach()
    set_tests_properties(
      check_r19_runtime_stage_cause_experiment_orchestrator_contract
      PROPERTIES RUN_SERIAL TRUE TIMEOUT 300)
    set_tests_properties(UT-R19-HWCDC-FLUSH-CALL-EVIDENCE-001 PROPERTIES
      WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}" LABELS "r19;contract;offline" TIMEOUT 120)

    set_tests_properties(
      FW-R19-CANDIDATE-ARTIFACT-BUILDER-001
      FW-HWCDC-INSTALLER-CONTRACT-001
      R19-CANDIDATE-APP-FLASH-ORCHESTRATOR-CONTRACT-001
      R19-PIXHAWK-PARAM-LIST-E2E-RUNNER-CONTRACT-001
      R19-RUNTIME-FAIL-DIAGNOSTIC-RUNNER-CONTRACT-001
      R19-USB-EXTENDED-RECORDS-OFFLINE-CONTRACT-001
      R19-USB-EXTENDED-LIVE-READER-CONTRACT-001
      PROPERTIES
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        LABELS "r19;contract;offline"
        RUN_SERIAL TRUE
    )
    set_tests_properties(
      FW-R19-CANDIDATE-ARTIFACT-BUILDER-001
      # Expanded v3/v4/v5 fixture and rehashed-tamper coverage measured
      # 129.09 s under build load. This is only the offline test-process
      # allowance; no transport deadline or product SLA is changed.
      PROPERTIES TIMEOUT 300
    )
    set_tests_properties(
      R19-CANDIDATE-APP-FLASH-ORCHESTRATOR-CONTRACT-001
      PROPERTIES TIMEOUT 60
    )
    set_tests_properties(
      R19-PIXHAWK-PARAM-LIST-E2E-RUNNER-CONTRACT-001
      PROPERTIES TIMEOUT 180
    )
    set_tests_properties(
      R19-RUNTIME-FAIL-DIAGNOSTIC-RUNNER-CONTRACT-001
      PROPERTIES TIMEOUT 60
    )
    set_tests_properties(
      R19-USB-EXTENDED-RECORDS-OFFLINE-CONTRACT-001
      PROPERTIES TIMEOUT 180
    )
    set_tests_properties(
      R19-USB-EXTENDED-LIVE-READER-CONTRACT-001
      PROPERTIES TIMEOUT 180
    )
  endif()
endif()
