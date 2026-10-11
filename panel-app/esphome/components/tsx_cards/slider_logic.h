// slider_logic.h: the numbers of a slider card, with no LVGL (slider.cpp uses
// it, tests/test-panel-app-slider.sh tests it). See docs/panel-app.md,
// "Slider cards".
//
// The LVGL slider holds an index from 0 to `count`. Index i is the value
// lo + i * step, at most hi. A light, fan, cover or volume slider is in
// percent (0 to 100). A number slider has the unit of its entity.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <utility>
#include <vector>

#include "layout.h"

namespace esphome {
namespace tsx_cards {

// The most positions of one slider.
static const int SLIDER_MAX_COUNT = 100000;
// The feature bits of Home Assistant that a slider uses.
static const long COVER_SET_POSITION = 4;
static const long MEDIA_VOLUME_SET = 4;
static const long MEDIA_VOLUME_MUTE = 8;

struct SliderRange {
  double lo{0}, hi{100}, step{1};
  int count{100};
  int decimals{0};
};

inline bool slider_percent(SliderMode m) { return m != SliderMode::NUMBER; }

// A number in a text of Home Assistant ("70.0"), or false.
inline bool slider_number(const std::string &t, double &out) {
  if (t.empty())
    return false;
  char *end = nullptr;
  out = strtod(t.c_str(), &end);
  return end != nullptr && *end == '\0' && std::isfinite(out);
}

// Home Assistant sends a bool attribute as "on" or "off".
inline bool slider_true(const std::string &t) { return t == "on" || t == "true" || t == "True"; }

// The supported_features bits, or -1 when the text is not a number.
inline long slider_features(const std::string &t) {
  if (t.empty())
    return -1;
  char *end = nullptr;
  long f = strtol(t.c_str(), &end, 10);
  return end != nullptr && *end == '\0' && f >= 0 ? f : -1;
}

// supported_color_modes with only "onoff" ("['onoff']" or the enum form).
inline bool slider_onoff_only(const std::string &modes) {
  return modes.find("onoff") != std::string::npos && modes.find(',') == std::string::npos;
}

// The decimals that show x (at most 4).
inline int slider_decimals(double x) {
  double m = std::fabs(x);
  for (int d = 0; d < 4; d++, m *= 10)
    if (std::fabs(m - std::round(m)) < 1e-6 * std::max(1.0, m))
      return d;
  return 4;
}

// The range from the entity (emin, emax, estep: nullptr when not known) and
// the layout ("min" and "max" narrow the range, the limits of the entity
// stay). A fan takes estep as its percentage_step. False when no range is
// left (max not above min).
inline bool slider_range(const CardSpec &c, const double *emin, const double *emax, const double *estep,
                         SliderRange &r) {
  double lo = 0, hi = 100, step = 1;
  bool kmin = true, kmax = true;
  if (c.slider == SliderMode::NUMBER) {
    kmin = emin != nullptr;
    kmax = emax != nullptr;
    lo = kmin ? *emin : 0;
    hi = kmax ? *emax : 100;
    if (estep != nullptr && *estep > 0)
      step = *estep;
  } else if (c.slider == SliderMode::FAN && estep != nullptr && *estep >= 1 && *estep <= 100) {
    step = *estep;
  }
  if (c.has_min)
    lo = kmin ? std::max(lo, c.min) : c.min;
  if (c.has_max)
    hi = kmax ? std::min(hi, c.max) : c.max;
  if (!(hi > lo))
    return false;
  double n = (hi - lo) / step;
  if (n > SLIDER_MAX_COUNT) {
    step = (hi - lo) / SLIDER_MAX_COUNT;
    n = SLIDER_MAX_COUNT;
  }
  int count = (int) std::ceil(n - 1e-9);
  if (count < 1)
    return false;
  r.lo = lo;
  r.hi = hi;
  r.step = step;
  r.count = count;
  // The decimals of the step and of the ends (the top can be off the grid of the steps).
  r.decimals = slider_percent(c.slider)
                   ? 0
                   : std::max(slider_decimals(step), std::max(slider_decimals(lo), slider_decimals(hi)));
  return true;
}

inline double slider_value(const SliderRange &r, int i) { return std::min(r.hi, r.lo + i * r.step); }

inline int slider_index(const SliderRange &r, double v) {
  long i = std::lround((v - r.lo) / r.step);
  return (int) std::max(0L, std::min((long) r.count, i));
}

// True when the value of Home Assistant is the value that the slider sent.
inline bool slider_confirms(const SliderRange &r, double ha, double target) {
  return std::fabs(ha - target) <= r.step / 2 + 1e-9;
}

// The value with its unit: "40%", "21.5 °C", "12 h". No space before a unit
// that starts with "%" or "°".
inline std::string slider_text(const SliderRange &r, double v, const std::string &unit) {
  char buf[48];
  snprintf(buf, sizeof buf, "%.*f", r.decimals, v);
  std::string out = buf;
  if (out[0] == '-' && strtod(out.c_str(), nullptr) == 0)
    out.erase(0, 1);  // "-0.0" -> "0.0"
  if (!unit.empty())
    out += (unit[0] == '%' || unit.compare(0, 2, "\xC2\xB0") == 0) ? unit : " " + unit;
  return out;
}

struct SliderAction {
  std::string action;
  std::vector<std::pair<std::string, std::string>> data;
  double target{0};  // the value that Home Assistant reports after the action
};

// The Home Assistant action for index i of the slider.
inline SliderAction slider_action(const CardSpec &c, const SliderRange &r, int i, bool onoff_only) {
  SliderAction a;
  double val = slider_value(r, i);
  long pct = std::lround(val);
  char buf[48];
  a.target = slider_percent(c.slider) ? (double) pct : val;
  switch (c.slider) {
    case SliderMode::LIGHT:
      if (pct <= 0) {
        a.action = "light.turn_off";
      } else {
        a.action = "light.turn_on";
        if (!onoff_only)
          a.data.emplace_back("brightness_pct", std::to_string(pct));
      }
      break;
    case SliderMode::FAN:
      a.action = "fan.set_percentage";
      a.data.emplace_back("percentage", std::to_string(pct));
      break;
    case SliderMode::COVER:
      a.action = "cover.set_cover_position";
      a.data.emplace_back("position", std::to_string(pct));
      break;
    case SliderMode::VOLUME:
      a.action = "media_player.volume_set";
      snprintf(buf, sizeof buf, "%.2f", pct / 100.0);
      a.data.emplace_back("volume_level", buf);
      break;
    case SliderMode::NUMBER:
      a.action = c.entity_id.substr(0, c.entity_id.find('.')) + ".set_value";
      snprintf(buf, sizeof buf, "%.*f", r.decimals, val);
      a.data.emplace_back("value", buf);
      break;
  }
  return a;
}

}  // namespace tsx_cards
}  // namespace esphome
