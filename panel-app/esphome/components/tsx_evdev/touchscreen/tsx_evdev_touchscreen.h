#pragma once

#ifdef USE_HOST
#include "../tsx_evdev.h"
#include "esphome/components/touchscreen/touchscreen.h"

namespace esphome::tsx_evdev {

/// The touch points of a TsxEvdev input device. A change of the touch state
/// is handled in the next loop, so a swipe gets every point that the device
/// reports.
class TsxEvdevTouchscreen final : public touchscreen::Touchscreen, public Parented<TsxEvdev> {
 public:
  void setup() override {
    // No calibration in the YAML: use the range that the device reports.
    if (this->x_raw_max_ == this->x_raw_min_) {
      this->x_raw_min_ = this->parent_->x_min();
      this->x_raw_max_ = this->parent_->x_max();
      this->y_raw_min_ = this->parent_->y_min();
      this->y_raw_max_ = this->parent_->y_max();
    }
  }
  void loop() override {
    if (this->parent_->take_touch_changed())
      this->store_.touched = true;
    Touchscreen::loop();
  }

 protected:
  void update_touches() override {
    const auto &pts = this->parent_->points();
    for (int i = 0; i < TsxEvdev::kSlots; i++) {
      if (pts[i].id >= 0)
        this->add_raw_touch_position_(i, pts[i].x, pts[i].y);
    }
  }
};

}  // namespace esphome::tsx_evdev
#endif
