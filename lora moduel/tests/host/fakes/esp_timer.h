#pragma once

#include "fake_arduino_test_api.hpp"

inline std::int64_t esp_timer_get_time() noexcept {
  return static_cast<std::int64_t>(fake_arduino::now_us);
}

