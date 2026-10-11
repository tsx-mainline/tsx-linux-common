#!/bin/bash
# Host test for panel-app/esphome/components/tsx_cards/slider_logic.h: the
# numbers of the slider card (docs/panel-app.md, "Slider cards").
#  - the range of each mode: percent for a light, fan, cover and volume
#    slider, the min, max and step of a number entity, the "min" and "max"
#    of the layout (they narrow the range, the limits of the entity stay),
#    missing attributes, a range with no room, the most positions
#  - the index of a value and the value of an index, the decimals and the
#    unit of the text
#  - the action and its data for each mode (light off at 0, only on/off
#    lights, the percentage step of a fan, the volume level, the value of a
#    number and an input_number), and the value that confirms a send
#  - the attribute texts of Home Assistant: supported_features, the bool
#    attributes, supported_color_modes
# It compiles C++, so run it only on a build host or in CI.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=$HERE/panel-app/esphome/components/tsx_cards
CXX=${CXX:-c++}
command -v "$CXX" >/dev/null 2>&1 || { echo "SKIPPED test-panel-app-slider: no $CXX"; exit 0; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

cat > "$T/main.cpp" <<'C'
#include <cstdio>
#include <string>
#include "slider_logic.h"
using namespace esphome::tsx_cards;
static int N = 0, F = 0;
static void ok(bool c, const std::string &what) {
  if (c) { N++; printf("  ok: %s\n", what.c_str()); } else { F++; printf("  FAIL: %s\n", what.c_str()); }
}
static CardSpec card(const char *entity, SliderMode m) {
  CardSpec c;
  c.type = CardType::SLIDER;
  c.entity_id = entity;
  c.slider = m;
  return c;
}
static std::string act(const SliderAction &a) {
  std::string s = a.action;
  for (const auto &d : a.data) s += " " + d.first + "=" + d.second;
  return s;
}
static std::string rng(const SliderRange &r) {
  char b[128];
  snprintf(b, sizeof b, "%g..%g step %g count %d dec %d", r.lo, r.hi, r.step, r.count, r.decimals);
  return b;
}
int main() {
  SliderRange r;
  puts("== light ==");
  CardSpec l = card("light.a", SliderMode::LIGHT);
  ok(slider_range(l, nullptr, nullptr, nullptr, r) && rng(r) == "0..100 step 1 count 100 dec 0", "light: 0 to 100 percent: " + rng(r));
  ok(slider_index(r, 128 * 100.0 / 255.0) == 50, "light: brightness 128 is index 50");
  ok(act(slider_action(l, r, 0, false)) == "light.turn_off", "light: 0 turns the light off");
  ok(act(slider_action(l, r, 62, false)) == "light.turn_on brightness_pct=62", "light: 62 % is brightness_pct 62");
  ok(act(slider_action(l, r, 62, true)) == "light.turn_on", "light: an on/off light gets turn_on with no brightness");
  ok(slider_confirms(r, 128 * 100.0 / 255.0, 50) && !slider_confirms(r, 52, 50), "light: brightness 128 confirms 50 %, 52 % does not");
  ok(slider_text(r, 62, "%") == "62%" && slider_text(r, 50.2, "%") == "50%", "light: the text is \"62%\"");
  l.has_min = l.has_max = true; l.min = 10; l.max = 90;
  ok(slider_range(l, nullptr, nullptr, nullptr, r) && rng(r) == "10..90 step 1 count 80 dec 0", "light: min 10 max 90: " + rng(r));
  ok(act(slider_action(l, r, 0, false)) == "light.turn_on brightness_pct=10", "light: index 0 of min 10 is 10 %, not off");
  ok(slider_index(r, 0) == 0 && slider_index(r, 100) == 80, "light: values outside the range go to the ends");

  puts("== fan, cover, volume ==");
  CardSpec f = card("fan.a", SliderMode::FAN);
  double third = 100.0 / 3;
  ok(slider_range(f, nullptr, nullptr, &third, r) && r.count == 3, "fan: percentage_step 33.33 gives 3 steps: " + rng(r));
  ok(act(slider_action(f, r, 1, false)) == "fan.set_percentage percentage=33" && act(slider_action(f, r, 2, false)) == "fan.set_percentage percentage=67",
     "fan: the steps send 33 and 67");
  ok(slider_index(r, 66.6667) == 2 && slider_confirms(r, 66.6667, 67), "fan: 66.67 % is step 2 and confirms 67");
  double bad = 0;
  ok(slider_range(f, nullptr, nullptr, &bad, r) && r.count == 100, "fan: a step of 0 is ignored");
  CardSpec cv = card("cover.a", SliderMode::COVER);
  ok(slider_range(cv, nullptr, nullptr, nullptr, r) && act(slider_action(cv, r, 40, false)) == "cover.set_cover_position position=40", "cover: position 40");
  CardSpec v = card("media_player.a", SliderMode::VOLUME);
  ok(slider_range(v, nullptr, nullptr, nullptr, r) && act(slider_action(v, r, 35, false)) == "media_player.volume_set volume_level=0.35", "volume: 35 % is volume_level 0.35");
  ok(act(slider_action(v, r, 100, false)) == "media_player.volume_set volume_level=1.00" && act(slider_action(v, r, 0, false)) == "media_player.volume_set volume_level=0.00",
     "volume: the ends are 0.00 and 1.00");
  ok(slider_index(r, 0.454 * 100) == 45, "volume: volume_level 0.454 is index 45");

  puts("== number and input_number ==");
  CardSpec n = card("number.panel_dim_timeout", SliderMode::NUMBER);
  double mn = 0, mx = 86400, st = 5;
  ok(slider_range(n, &mn, &mx, &st, r) && rng(r) == "0..86400 step 5 count 17280 dec 0", "number: the attributes give the range: " + rng(r));
  n.has_min = n.has_max = true; n.min = 10; n.max = 300;
  ok(slider_range(n, &mn, &mx, &st, r) && rng(r) == "10..300 step 5 count 58 dec 0", "number: min 10 max 300 of the layout: " + rng(r));
  ok(act(slider_action(n, r, 10, false)) == "number.set_value value=60", "number: index 10 sends 60");
  ok(slider_value(r, 58) == 300 && slider_index(r, 61) == 10 && slider_index(r, 63) == 11, "number: the value of an index and the nearest index of a value");
  ok(slider_text(r, 60, "s") == "60 s", "number: \"60 s\" with a space before the unit");
  n.min = -50; n.max = 1e6;
  ok(slider_range(n, &mn, &mx, &st, r) && r.lo == 0 && r.hi == 86400, "number: the layout cannot go past the limits of the entity");
  n.min = 90000; n.max = 100000;
  ok(!slider_range(n, &mn, &mx, &st, r), "number: no room between the limits: no range");
  CardSpec i = card("input_number.target", SliderMode::NUMBER);
  double a = 15, b = 30, s = 0.5;
  ok(slider_range(i, &a, &b, &s, r) && rng(r) == "15..30 step 0.5 count 30 dec 1", "input_number: step 0.5: " + rng(r));
  ok(act(slider_action(i, r, 3, false)) == "input_number.set_value value=16.5", "input_number: index 3 sends 16.5 to input_number.set_value");
  ok(slider_text(r, 16.5, "\xC2\xB0" "C") == "16.5\xC2\xB0" "C" && slider_text(r, 16.5, "") == "16.5", "input_number: \"16.5°C\" with no space, no unit with an empty unit");
  CardSpec m = card("number.x", SliderMode::NUMBER);
  ok(slider_range(m, nullptr, nullptr, nullptr, r) && rng(r) == "0..100 step 1 count 100 dec 0", "number: no attributes: 0 to 100, step 1");
  m.has_min = m.has_max = true; m.min = -5; m.max = 5.5;
  ok(slider_range(m, nullptr, nullptr, nullptr, r) && r.count == 11 && slider_value(r, 11) == 5.5 && r.decimals == 1, "number: a top off the step grid is the last index: " + rng(r));
  ok(slider_text(r, -0.04, "") == "0.0" && slider_text(r, 5.5, "") == "5.5", "number: the text has the decimals of the ends");
  double hmn = -1e9, hmx = 1e9, hst = 0.001;
  ok(slider_range(m, &hmn, &hmx, &hst, r) && r.lo == -5 && r.count == 10500 && r.decimals == 3, "number: the layout narrows a huge range: " + rng(r));
  m.has_min = m.has_max = false;
  ok(slider_range(m, &hmn, &hmx, &hst, r) && r.count == SLIDER_MAX_COUNT && r.step == 20000, "number: a huge range has at most 100000 positions: " + rng(r));
  CardSpec z = card("number.z", SliderMode::NUMBER);
  double zmn = 5, zmx = 5;
  ok(!slider_range(z, &zmn, &zmx, nullptr, r), "number: min equal to max: no range");
  z.has_max = true; z.max = 3;
  double zmn2 = 0;
  ok(slider_range(z, &zmn2, nullptr, nullptr, r) && r.hi == 3, "number: the layout max is used when the entity has no max");

  puts("== attribute texts ==");
  ok(slider_features("15") == 15 && slider_features("") == -1 && slider_features("<CoverEntityFeature: 15>") == -1 && slider_features("-1") == -1,
     "supported_features: a number, else not known");
  ok(slider_true("on") && slider_true("True") && slider_true("true") && !slider_true("off") && !slider_true(""), "bool attributes: on, True, true");
  ok(slider_onoff_only("['onoff']") && slider_onoff_only("[<ColorMode.ONOFF: 'onoff'>]") && !slider_onoff_only("['brightness']") &&
     !slider_onoff_only("['color_temp', 'hs']") && !slider_onoff_only(""), "supported_color_modes: only onoff");
  double x;
  ok(slider_number("70.0", x) && x == 70 && !slider_number("unknown", x) && !slider_number("", x) && !slider_number("nan", x), "numbers in state texts");

  printf("== %d ok, %d failed ==\n", N, F);
  return F == 0 ? 0 : 1;
}
C
"$CXX" -std=gnu++17 -Wall -Wextra -Werror -O1 -I"$SRC" -o "$T/slider" "$T/main.cpp" || { echo "FAIL: compile"; exit 1; }
"$T/slider"
