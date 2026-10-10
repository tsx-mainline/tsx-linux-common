// cpu.cpp: the CPU speed of the panel app. See docs/panel-app.md, "CPU speed".
//
// A UI draws in short bursts. A load governor (ondemand) sees the load of a
// burst only after its sample time, so the first frames of a page change run
// at a low clock. Instead, the app sets the lowest allowed frequency
// (scaling_min_freq) to the highest one for CPUFREQ_BOOST_MS after each
// touch, key press and redraw burst, and at a wake. The governor scales down
// again after the boost. With CPUFREQ_SCREEN_OFF=lowest the highest allowed
// frequency (scaling_max_freq) is the lowest one while the screen is off.
//
// The values come from panel-board.conf (TSX_PANEL_BOARD_CONF):
//   CPUFREQ_BOOST_MS=1500        0 or not set: no boost
//   CPUFREQ_SCREEN_OFF=lowest    or "keep" (not set: keep)
// The governor and its settings are the job of the board (its boot
// service). The app writes only the two limits, and gives the full range
// back at the start and at the end. TSX_CPUFREQ_SYS replaces
// /sys/devices/system/cpu/cpufreq (tests).
#include "tsx_cards.h"
#include "hwconf.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>

#include "esphome/core/hal.h"
#include "esphome/core/log.h"

namespace esphome {
namespace tsx_cards {

static const char *const TAG = "tsx_cards.cpu";

static bool read_khz(const std::string &path, uint32_t &out) {
  FILE *f = fopen(path.c_str(), "r");
  if (f == nullptr)
    return false;
  unsigned long v = 0;
  bool ok = fscanf(f, "%lu", &v) == 1;
  fclose(f);
  if (ok)
    out = (uint32_t) v;
  return ok && v > 0;
}

static bool write_khz(const std::string &path, uint32_t khz) {
  FILE *f = fopen(path.c_str(), "w");
  if (f == nullptr) {
    ESP_LOGW(TAG, "%s: %s", path.c_str(), strerror(errno));
    return false;
  }
  bool ok = fprintf(f, "%u\n", (unsigned) khz) > 0;
  ok = fclose(f) == 0 && ok;
  if (!ok)
    ESP_LOGW(TAG, "%s %u: %s", path.c_str(), (unsigned) khz, strerror(errno));
  return ok;
}

void TsxCards::cpu_setup_() {
  const char *bc = getenv("TSX_PANEL_BOARD_CONF");
  std::string conf = bc != nullptr && bc[0] != '\0' ? bc : "/etc/tsx/panel-board.conf";
  std::string v;
  if (conf_value(conf, "CPUFREQ_BOOST_MS", v))
    this->cpu_boost_ms_ = std::min<unsigned long>(strtoul(v.c_str(), nullptr, 10), 60000);
  if (conf_value(conf, "CPUFREQ_SCREEN_OFF", v))
    this->cpu_off_lowest_ = v == "lowest";
  if (this->cpu_boost_ms_ == 0 && !this->cpu_off_lowest_)
    return;
  const char *sys = getenv("TSX_CPUFREQ_SYS");
  std::string base = sys != nullptr && sys[0] != '\0' ? sys : "/sys/devices/system/cpu/cpufreq";
  DIR *d = opendir(base.c_str());
  if (d != nullptr) {
    for (dirent *e; (e = readdir(d)) != nullptr;) {
      if (strncmp(e->d_name, "policy", 6) != 0)
        continue;
      CpuPolicy p;
      p.dir = base + "/" + e->d_name;
      if (read_khz(p.dir + "/cpuinfo_min_freq", p.min) && read_khz(p.dir + "/cpuinfo_max_freq", p.max) &&
          p.min < p.max)
        this->cpu_policies_.push_back(p);
    }
    closedir(d);
  }
  if (this->cpu_policies_.empty()) {
    ESP_LOGW(TAG, "no cpufreq policy in %s: no CPU boost", base.c_str());
    return;
  }
  std::sort(this->cpu_policies_.begin(), this->cpu_policies_.end(),
            [](const CpuPolicy &a, const CpuPolicy &b) { return a.dir < b.dir; });
  // The full range, also when an earlier run ended with other limits.
  for (auto &p : this->cpu_policies_) {
    write_khz(p.dir + "/scaling_max_freq", p.max);
    write_khz(p.dir + "/scaling_min_freq", p.min);
    p.set_min = p.min;
    p.set_max = p.max;
  }
  this->cpu_mode_ = CPU_FULL_RANGE;
  const CpuPolicy &p0 = this->cpu_policies_.front();
  ESP_LOGI(TAG, "CPU boost to %u MHz for %u ms after an input; screen off: %s (%u policies, %u..%u MHz)",
           (unsigned) (p0.max / 1000), (unsigned) this->cpu_boost_ms_,
           this->cpu_off_lowest_ ? "the lowest frequency" : "the full range", (unsigned) this->cpu_policies_.size(),
           (unsigned) (p0.min / 1000), (unsigned) (p0.max / 1000));
}

// Write the limits of a mode. A write that changes the frequency runs the
// change at once (it takes some milliseconds: the core voltage changes too).
void TsxCards::cpu_apply_(CpuMode m) {
  if (m == this->cpu_mode_)
    return;
  this->cpu_mode_ = m;
  for (auto &p : this->cpu_policies_) {
    uint32_t mn = m == CPU_BOOST ? p.max : p.min;
    uint32_t mx = m == CPU_LOWEST ? p.min : p.max;
    // The kernel keeps min <= max: raise the maximum first, lower it last.
    if (mx >= p.set_min) {
      if (mx != p.set_max && write_khz(p.dir + "/scaling_max_freq", mx))
        p.set_max = mx;
      if (mn != p.set_min && write_khz(p.dir + "/scaling_min_freq", mn))
        p.set_min = mn;
    } else {
      if (mn != p.set_min && write_khz(p.dir + "/scaling_min_freq", mn))
        p.set_min = mn;
      if (mx != p.set_max && write_khz(p.dir + "/scaling_max_freq", mx))
        p.set_max = mx;
    }
  }
  static const char *const NAMES[] = {"full range", "boost", "lowest"};
  ESP_LOGV(TAG, "CPU %s", NAMES[m]);
}

void TsxCards::cpu_boost_() {
  if (this->cpu_boost_ms_ == 0 || this->cpu_policies_.empty() || this->screen_ != SCREEN_ON)
    return;
  this->cpu_boost_until_ = millis() + this->cpu_boost_ms_;
  this->cpu_apply_(CPU_BOOST);
}

void TsxCards::cpu_loop_() {
  if (this->cpu_mode_ == CPU_BOOST && (int32_t) (millis() - this->cpu_boost_until_) >= 0)
    this->cpu_apply_(CPU_FULL_RANGE);
}

void TsxCards::cpu_screen_(bool on) {
  if (this->cpu_policies_.empty())
    return;
  if (on) {
    if (this->cpu_boost_ms_ > 0) {
      this->cpu_boost_until_ = millis() + this->cpu_boost_ms_;
      this->cpu_apply_(CPU_BOOST);
    } else {
      this->cpu_apply_(CPU_FULL_RANGE);
    }
  } else {
    this->cpu_apply_(this->cpu_off_lowest_ ? CPU_LOWEST : CPU_FULL_RANGE);
  }
}

void TsxCards::on_shutdown() { this->cpu_apply_(CPU_FULL_RANGE); }

}  // namespace tsx_cards
}  // namespace esphome
