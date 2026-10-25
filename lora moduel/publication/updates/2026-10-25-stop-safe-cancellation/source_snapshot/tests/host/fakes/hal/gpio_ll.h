#pragma once
#include "../fake_arduino_test_api.hpp"
inline constexpr int GPIO_PORT_0=0;
inline int GPIO_LL_GET_HW(int port) noexcept{return port;}
inline int gpio_ll_get_level(int,std::uint32_t pin) noexcept{
  return digitalRead(static_cast<int>(pin));
}
