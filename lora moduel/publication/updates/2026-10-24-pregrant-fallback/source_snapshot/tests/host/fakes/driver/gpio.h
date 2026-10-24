#pragma once
// Offline bridge fixture only. No physical interrupt delivery is simulated.
#ifndef IRAM_ATTR
#define IRAM_ATTR
#endif
using esp_err_t=int;
using gpio_num_t=int;
inline constexpr esp_err_t ESP_OK=0;
inline constexpr esp_err_t ESP_ERR_INVALID_STATE=0x103;
inline constexpr int ESP_INTR_FLAG_IRAM=1;
inline constexpr int GPIO_INTR_ANYEDGE=3;
inline esp_err_t gpio_install_isr_service(int) noexcept{return ESP_OK;}
inline esp_err_t gpio_set_intr_type(gpio_num_t,int) noexcept{return ESP_OK;}
inline esp_err_t gpio_isr_handler_add(gpio_num_t,void(*)(void*),void*) noexcept{return ESP_OK;}
inline esp_err_t gpio_intr_enable(gpio_num_t) noexcept{return ESP_OK;}
