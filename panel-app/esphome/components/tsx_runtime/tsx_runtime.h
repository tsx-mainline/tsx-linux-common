// tsx_runtime: the device name and the API encryption key of the panel app
// at run time. See __init__.py and docs/panel-app.md.
#pragma once

#include <array>
#include <cstdint>
#include <string>

#include "esphome/core/component.h"

namespace esphome {
namespace tsx_runtime {

class TsxRuntime : public Component {
 public:
  /// Take the device name and the friendly name from the environment.
  void apply_identity();
  void set_key_file(const std::string &path) { this->key_file_ = path; }

  void setup() override;
  void loop() override;
  void dump_config() override;
  // Before the api component, so the first client gets the key of the file.
  float get_setup_priority() const override { return setup_priority::BUS; }

 protected:
  bool read_key_(std::array<uint8_t, 32> &out, const char *&why);
  void apply_key_(bool initial);
  long long file_sig_() const;

  std::string key_file_;
  // The api component keeps a pointer to the key, so the key lives here for
  // the life of the program.
  std::array<uint8_t, 32> psk_{};
  bool from_file_{false};
  const char *why_{""};
  long long sig_{-1};
  uint32_t last_check_{0};
};

}  // namespace tsx_runtime
}  // namespace esphome
