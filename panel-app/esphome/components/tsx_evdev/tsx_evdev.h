#pragma once

#ifdef USE_HOST
#include <array>
#include <string>
#include <utility>
#include <vector>

#include <linux/input.h>

#include "esphome/components/binary_sensor/binary_sensor.h"
#include "esphome/core/component.h"

namespace esphome::tsx_evdev {

/// One Linux input device (/dev/input/eventN), read with no SDL and no
/// libinput. It keeps the touch points (multi-touch protocol B, or single
/// touch) for the touchscreen platform and sends key changes to the
/// binary sensors. The device is not grabbed: other programs still get the
/// events.
class TsxEvdev : public Component {
 public:
  struct Point {
    int id{-1};  // tracking id, -1: no finger
    int x{0}, y{0};
  };
  static constexpr int kSlots = 10;

  void set_device(const std::string &path) { this->path_ = path; }
  void set_name_match(const std::string &name) { this->name_ = name; }
  void add_key_sensor(int code, binary_sensor::BinarySensor *sensor) {
    this->keys_.emplace_back(code, sensor);
  }

  void setup() override;
  void loop() override;
  void dump_config() override;
  float get_setup_priority() const override { return setup_priority::HARDWARE; }

  /// True once after the touch state changed (a SYN_REPORT after touch data).
  bool take_touch_changed() {
    bool c = this->touch_changed_;
    this->touch_changed_ = false;
    return c;
  }
  const std::array<Point, kSlots> &points() const { return this->slots_; }
  /// The range of the touch coordinates that the device reports.
  int x_min() const { return this->x_min_; }
  int x_max() const { return this->x_max_; }
  int y_min() const { return this->y_min_; }
  int y_max() const { return this->y_max_; }

 protected:
  bool open_();
  void close_();

  std::string path_, name_, opened_;
  int fd_{-1};
  uint32_t last_try_{0};
  std::vector<std::pair<int, binary_sensor::BinarySensor *>> keys_;
  std::array<Point, kSlots> slots_{};
  int slot_{0};
  bool mt_{false};
  bool touch_data_{false}, touch_changed_{false};
  int x_min_{0}, x_max_{0}, y_min_{0}, y_max_{0};
};

}  // namespace esphome::tsx_evdev
#endif
