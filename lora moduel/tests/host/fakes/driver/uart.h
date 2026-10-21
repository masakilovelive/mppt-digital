#pragma once

#include <cstdint>

using esp_err_t = int;
using uart_port_t = int;

inline constexpr esp_err_t ESP_OK = 0;
inline constexpr esp_err_t ESP_ERR_TIMEOUT = 0x107;
inline constexpr uart_port_t UART_NUM_2 = 2;

inline esp_err_t uart_wait_tx_done(uart_port_t port,
                                   std::uint32_t) noexcept {
  return port == UART_NUM_2 ? ESP_OK : ESP_ERR_TIMEOUT;
}

