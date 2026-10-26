#pragma once

#include "fake_arduino_test_api.hpp"

inline std::uint32_t esp_random() noexcept {
  fake_arduino::random_state =
      fake_arduino::random_state * 1664525U + 1013904223U;
  return fake_arduino::random_state == 0U
             ? static_cast<std::uint32_t>(1U)
             : fake_arduino::random_state;
}

