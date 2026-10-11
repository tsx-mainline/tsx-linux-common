// runstate.h: the run-time state files that the panel app writes for other
// services of the panel. It needs no ESPHome header, so a host test
// (tests/test-panel-app-state.sh) can compile it.
//
// - The screen state, in the file and the format of tsx-idled
//   (/run/tsx-idled.state, TSX_IDLED_STATE): "on <level>" while the screen
//   is on or dim, "on none" with no backlight, "blank" while the screen is
//   off. tsx-autoupdate installs only while the screen is "blank".
// - The app state (/run/tsx/panel-app.state): one "key value" pair on each
//   line. tsx-autoupdate reads it for its check after an update reboot.
//     pid           the process id of the app
//     started       the start of the process (epoch seconds)
//     first_frame   the first frame on the screen (epoch seconds, 0 = none yet)
//     ha_connected  the first Home Assistant connection (epoch seconds, 0 = none yet)
//     ha            "on" while Home Assistant is connected, else "off"
// Each write is atomic (a temporary file and a rename), so a reader never
// sees half a file.
#pragma once

#include <cstdio>
#include <string>
#include <unistd.h>

namespace esphome {
namespace tsx_cards {

// The text of the screen state. lit = the screen is on or dim. raw = the
// backlight value, below 0 = no backlight.
inline std::string idle_state_text(bool lit, int raw) {
  if (raw < 0)
    return "on none\n";
  if (!lit)
    return "blank\n";
  return "on " + std::to_string(raw) + "\n";
}

inline std::string app_state_text(long pid, long started, long first_frame, long ha_connected, bool ha) {
  char buf[256];
  snprintf(buf, sizeof buf, "pid %ld\nstarted %ld\nfirst_frame %ld\nha_connected %ld\nha %s\n", pid, started,
           first_frame, ha_connected, ha ? "on" : "off");
  return buf;
}

// Write a file atomically. The folder must exist.
inline bool write_file_atomic(const std::string &path, const std::string &text) {
  std::string tmp = path + ".tmp";
  FILE *f = fopen(tmp.c_str(), "w");
  if (f == nullptr)
    return false;
  bool ok = fwrite(text.data(), 1, text.size(), f) == text.size();
  if (fclose(f) != 0 || !ok || rename(tmp.c_str(), path.c_str()) != 0) {
    unlink(tmp.c_str());
    return false;
  }
  return true;
}

}  // namespace tsx_cards
}  // namespace esphome
