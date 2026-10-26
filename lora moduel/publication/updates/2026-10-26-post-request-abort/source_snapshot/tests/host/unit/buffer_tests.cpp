#include "test_support.hpp"

#include <array>
#include <cstddef>
#include <cstdint>

#include "vc_lora/byte_ring_buffer.hpp"

namespace vc_lora::test {

TestReport run_buffer_test(const std::string& test_id, std::uint32_t seed) {
  TestReport report{};
  report.test_id = test_id;
  report.seed = seed;

  if (test_id == "UT-BUF-001") {
    ByteRingBuffer<4> buffer{};
    std::array<std::uint8_t, 4> input{{1U, 2U, 3U, 4U}};
    std::array<std::uint8_t, 4> output{};
    report.check(buffer.empty() && buffer.size() == 0U,
                 "new buffer is not empty");
    report.check(buffer.capacity() == 4U && buffer.free_space() == 4U,
                 "new buffer capacity/free space is incorrect");
    report.check(buffer.read(output.data(), 1U) == 0U,
                 "empty buffer returned one byte");
    report.check(buffer.write(input.data(), input.size()) == input.size(),
                 "exact-capacity write was not accepted");
    report.check(buffer.full() && buffer.free_space() == 0U,
                 "exact-capacity write did not make the buffer full");
    report.check(buffer.read(output.data(), output.size()) == output.size(),
                 "full buffer did not return all bytes");
    report.check(output == input, "boundary read changed byte order");
    report.check(buffer.empty(), "buffer was not empty after full read");
    std::uint8_t recycled = 0U;
    report.check(buffer.push(9U) && buffer.pop(recycled) && recycled == 9U,
                 "fully drained buffer could not be reused");
  } else if (test_id == "UT-BUF-002") {
    ByteRingBuffer<8> buffer{};
    const std::array<std::uint8_t, 6> first{{0U, 1U, 2U, 3U, 4U, 5U}};
    const std::array<std::uint8_t, 6> second{{6U, 7U, 8U, 9U, 10U, 11U}};
    std::array<std::uint8_t, 4> prefix{};
    std::array<std::uint8_t, 8> output{};
    const std::array<std::uint8_t, 8> expected{{
        4U, 5U, 6U, 7U, 8U, 9U, 10U, 11U}};
    report.check(buffer.write(first.data(), first.size()) == first.size(),
                 "initial wrap setup write failed");
    report.check(buffer.read(prefix.data(), prefix.size()) == prefix.size(),
                 "initial wrap setup read failed");
    report.check(buffer.write(second.data(), second.size()) == second.size(),
                 "wrapped write failed");
    report.check(buffer.read(output.data(), output.size()) == output.size(),
                 "wrapped read returned the wrong byte count");
    report.check(output == expected, "wrap-around changed byte order");
  } else if (test_id == "UT-BUF-003") {
    ByteRingBuffer<4> buffer{};
    const std::array<std::uint8_t, 6> input{{10U, 11U, 12U, 13U, 14U, 15U}};
    std::array<std::uint8_t, 4> output{};
    report.check(buffer.write(input.data(), input.size()) == 4U,
                 "overflow did not accept exactly the available capacity");
    report.check(buffer.stats().overflow_events == 1U,
                 "overflow event was not counted once");
    report.check(buffer.stats().bytes_dropped == 2U,
                 "overflow dropped-byte count is not two");
    report.check(buffer.write(input.data(), 1U) == 0U,
                 "full buffer accepted a newest byte");
    report.check(buffer.stats().overflow_events == 2U &&
                     buffer.stats().bytes_dropped == 3U,
                 "second overflow was not diagnosed");
    report.check(buffer.read(output.data(), output.size()) == output.size(),
                 "overflow survivor bytes could not be read");
    const std::array<std::uint8_t, 4> expected{{10U, 11U, 12U, 13U}};
    report.check(output == expected,
                 "drop-newest policy changed already queued bytes");
  } else if (test_id == "UT-BUF-004") {
    ByteRingBuffer<7> buffer{};
    for (std::uint16_t value = 0; value < 1024U; ++value) {
      const auto expected = static_cast<std::uint8_t>(value & 0xFFU);
      std::uint8_t actual = 0;
      report.check(buffer.push(expected), "single-byte push failed");
      report.check(buffer.pop(actual), "single-byte pop failed");
      report.check(actual == expected, "single-byte round trip changed data");
    }
    report.check(buffer.empty(), "single-byte loop left queued data");
    report.check(buffer.stats().bytes_written == 1024U &&
                     buffer.stats().bytes_read == 1024U,
                 "single-byte accounting is incorrect");
  } else if (test_id == "UT-BUF-005") {
    constexpr std::size_t kBurstBytes = 16U * 1024U;
    ByteRingBuffer<kBurstBytes> buffer{};
    std::array<std::uint8_t, kBurstBytes> input{};
    std::array<std::uint8_t, kBurstBytes> output{};
    for (std::size_t index = 0; index < input.size(); ++index) {
      input[index] = static_cast<std::uint8_t>((index * 37U + 11U) & 0xFFU);
    }
    report.check(buffer.write(input.data(), input.size()) == input.size(),
                 "16 KiB burst was not accepted in full");
    report.check(buffer.stats().bytes_dropped == 0U,
                 "16 KiB in-capacity burst reported a drop");
    report.check(buffer.stats().high_watermark == kBurstBytes,
                 "16 KiB burst high-water mark is incorrect");
    report.check(buffer.read(output.data(), output.size()) == output.size(),
                 "16 KiB burst was not read in full");
    report.check(output == input, "16 KiB burst changed byte order/content");
  } else {
    report.check(false, "unknown ring-buffer test ID");
  }

  report.trace.record({0, "host", "BYTE_RING_BUFFER", 0,
                       report.passed ? "PASS" : "FAIL", true, 0, 0, 0});
  return report;
}

}  // namespace vc_lora::test
