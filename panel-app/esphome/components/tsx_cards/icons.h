// icons.h: written by mkicons.py from icons.txt. Do not edit.
// The MDI icons of the panel app, sorted by name.
#pragma once
#include <cstdint>

namespace esphome {
namespace tsx_cards {

struct IconEntry {
  const char *name;
  uint32_t code;
};

static const IconEntry ICONS[] = {
    {"account", 0xF0004},
    {"air-conditioner", 0xF001B},
    {"airplane", 0xF001D},
    {"alert-circle-outline", 0xF05D6},
    {"battery", 0xF0079},
    {"bed", 0xF02E3},
    {"ceiling-light", 0xF0769},
    {"chef-hat", 0xF0B7C},
    {"clock-outline", 0xF0150},
    {"coffee", 0xF0176},
    {"door", 0xF081A},
    {"fan", 0xF0210},
    {"fire", 0xF0238},
    {"flash", 0xF0241},
    {"floor-lamp", 0xF08DD},
    {"garage", 0xF06D9},
    {"gauge", 0xF029A},
    {"grill", 0xF0E45},
    {"help-circle-outline", 0xF0625},
    {"home", 0xF02DC},
    {"home-thermometer", 0xF0F54},
    {"lamp", 0xF06B5},
    {"led-strip-variant", 0xF1051},
    {"light-recessed", 0xF179B},
    {"lightbulb", 0xF0335},
    {"lightbulb-group", 0xF1253},
    {"lightbulb-on", 0xF06E8},
    {"lightbulb-outline", 0xF0336},
    {"lightning-bolt", 0xF140B},
    {"lock", 0xF033E},
    {"motion-sensor", 0xF0D91},
    {"outdoor-lamp", 0xF1054},
    {"palette", 0xF03D8},
    {"play", 0xF040A},
    {"power", 0xF0425},
    {"radiator", 0xF0438},
    {"robot-vacuum", 0xF070D},
    {"script-text", 0xF0BC2},
    {"silverware-fork-knife", 0xF0A70},
    {"sofa", 0xF04B9},
    {"solar-power", 0xF0A72},
    {"speaker", 0xF04C3},
    {"sprinkler", 0xF105F},
    {"string-lights", 0xF12BA},
    {"television", 0xF0502},
    {"thermometer", 0xF050F},
    {"toggle-switch", 0xF0521},
    {"toggle-switch-off-outline", 0xF0A19},
    {"tumble-dryer", 0xF0917},
    {"wall-sconce-round", 0xF0748},
    {"washing-machine", 0xF072A},
    {"water", 0xF058C},
    {"water-percent", 0xF058E},
    {"weather-cloudy", 0xF0590},
    {"weather-cloudy-alert", 0xF0F2F},
    {"weather-fog", 0xF0591},
    {"weather-hail", 0xF0592},
    {"weather-lightning", 0xF0593},
    {"weather-lightning-rainy", 0xF067E},
    {"weather-night", 0xF0594},
    {"weather-night-partly-cloudy", 0xF0F31},
    {"weather-partly-cloudy", 0xF0595},
    {"weather-pouring", 0xF0596},
    {"weather-rainy", 0xF0597},
    {"weather-snowy", 0xF0598},
    {"weather-snowy-rainy", 0xF067F},
    {"weather-sunny", 0xF0599},
    {"weather-windy", 0xF059D},
    {"weather-windy-variant", 0xF059E},
};

}  // namespace tsx_cards
}  // namespace esphome
