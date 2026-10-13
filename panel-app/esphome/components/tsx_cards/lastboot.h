#pragma once
// The sensor "Last boot" of the panel app (docs/panel-app.md, "Last boot"): the
// time of the last boot as ISO 8601 text in UTC. It is the wall clock minus the
// uptime (CLOCK_BOOTTIME). Pure C++ with no ESPHome include, so that a host test
// can compile it (tests/test-panel-app-lastboot.sh).
//
// The two readings are never exact, so the difference moves by a fraction of a
// second at each report. LastBoot keeps its value until a new one differs from it
// by BOOT_JITTER_S or more: a reboot, or a step of the clock (the panel has no
// RTC, and NTP steps the clock after the boot). The text does not change by
// a second between two reports. The constant has the same value as BOOT_JITTER in
// the ESPHome shim and in tsx-mqtt.

#include <cmath>
#include <cstdio>
#include <ctime>
#include <string>

namespace esphome {
namespace tsx_cards {

constexpr double BOOT_JITTER_S = 30.0;

// last_boot_text: "2026-10-13T03:01:13+00:00" for the epoch seconds, UTC.
inline std::string last_boot_text(double epoch) {
  time_t t = (time_t) std::llround(epoch);
  struct tm tmv;
  if (gmtime_r(&t, &tmv) == nullptr)
    return "";
  char buf[40];
  if (strftime(buf, sizeof buf, "%Y-%m-%dT%H:%M:%S+00:00", &tmv) == 0)
    return "";
  return buf;
}

class LastBoot {
 public:
  // update: wall_s is the wall clock (epoch seconds), uptime_s the seconds since
  // the boot. A negative uptime means that the clock could not be read. It
  // returns the text, or "" while there is no value yet.
  std::string update(double wall_s, double uptime_s) {
    if (uptime_s >= 0.0 && wall_s > 0.0) {
      double boot = wall_s - uptime_s;
      if (!this->have_ || std::fabs(boot - this->boot_) >= BOOT_JITTER_S) {
        this->boot_ = boot;
        this->have_ = true;
      }
    }
    return this->have_ ? last_boot_text(this->boot_) : std::string();
  }

 private:
  bool have_{false};
  double boot_{0.0};
};

}  // namespace tsx_cards
}  // namespace esphome
