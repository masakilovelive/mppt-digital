#pragma once

#include "fake_arduino_test_api.hpp"

class Preferences final {
 public:
  bool begin(const char* name, bool read_only = false) {
    if (name == nullptr || *name == '\0') {
      return false;
    }
    namespace_ = name;
    read_only_ = read_only;
    open_ = true;
    return true;
  }

  std::size_t getBytesLength(const char* key) const {
    const auto iterator = fake_arduino::preferences_store.find(path(key));
    return iterator == fake_arduino::preferences_store.end()
               ? 0U
               : iterator->second.size();
  }

  std::size_t getBytes(const char* key, void* output,
                       std::size_t maximum) const {
    if (!open_ || output == nullptr) {
      return 0U;
    }
    const auto iterator = fake_arduino::preferences_store.find(path(key));
    if (iterator == fake_arduino::preferences_store.end() ||
        iterator->second.size() > maximum) {
      return 0U;
    }
    std::memcpy(output, iterator->second.data(), iterator->second.size());
    return iterator->second.size();
  }

  std::size_t putBytes(const char* key, const void* input,
                       std::size_t size) {
    if (!open_ || read_only_ || input == nullptr) {
      return 0U;
    }
    const auto* first = static_cast<const std::uint8_t*>(input);
    fake_arduino::preferences_store[path(key)] =
        std::vector<std::uint8_t>(first, first + size);
    return size;
  }

  void end() noexcept {
    namespace_.clear();
    read_only_ = false;
    open_ = false;
  }

 private:
  std::string path(const char* key) const {
    return namespace_ + "/" + (key == nullptr ? std::string{} : key);
  }

  std::string namespace_{};
  bool read_only_{false};
  bool open_{false};
};

