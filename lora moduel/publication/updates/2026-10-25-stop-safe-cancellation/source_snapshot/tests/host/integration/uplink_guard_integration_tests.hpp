#pragma once

#include <cstdint>
#include <string>

#include "test_support.hpp"

namespace vc_lora::test {

TestReport run_uplink_guard_integration_test(const std::string& test_id,
                                             std::uint32_t seed);

}  // namespace vc_lora::test
