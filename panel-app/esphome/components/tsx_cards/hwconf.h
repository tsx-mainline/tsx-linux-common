// hwconf.h: shell-style KEY=value files of the panel (panel-board.conf of
// the board, hw.conf of tsx-hw). It needs no ESPHome header, so a host test
// (tests/test-panel-app-hwconf.sh) can compile it.
#pragma once

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>

namespace esphome {
namespace tsx_cards {

// KEY=value from a shell-style file: the last one wins. Quotes and a
// comment after the value are removed.
inline bool conf_value(const std::string &path, const char *key, std::string &out) {
  FILE *f = fopen(path.c_str(), "r");
  if (f == nullptr)
    return false;
  char line[256];
  size_t kl = strlen(key);
  bool found = false;
  while (fgets(line, sizeof line, f) != nullptr) {
    if (strncmp(line, key, kl) != 0 || line[kl] != '=')
      continue;
    std::string v = line + kl + 1;
    size_t end = v.find_first_of(" \t\r\n#");
    if (end != std::string::npos)
      v.resize(end);
    v.erase(std::remove(v.begin(), v.end(), '"'), v.end());
    v.erase(std::remove(v.begin(), v.end(), '\''), v.end());
    out = v;
    found = true;
  }
  fclose(f);
  return found;
}

// True when hw.conf names a light sensor: LIGHT=yes or ALS=yes (a board
// names its light sensor part either way). A missing file, a missing key or
// any other value counts as no sensor. The settings overlay shows its auto
// brightness row only for a sensor.
inline bool has_light_sensor(const std::string &hw_conf) {
  std::string v;
  if (conf_value(hw_conf, "LIGHT", v) && v == "yes")
    return true;
  return conf_value(hw_conf, "ALS", v) && v == "yes";
}

}  // namespace tsx_cards
}  // namespace esphome
