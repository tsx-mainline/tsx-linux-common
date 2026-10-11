// volume_logic.h: the volume of the Sendspin player for volume.cpp, with no
// LVGL and no ESPHome, so tests/test-panel-app-volume.sh can test it. See
// docs/panel-app.md, "Volume".
//
// While the Sendspin player runs, the volume of the panel is the player
// volume. The player (sendspin-cli --volume-file) writes it to a file at each
// change, also a change from Music Assistant:
//   # Written by sendspin-cli. Edits are overwritten.
//   volume = 40
//   muted = false
// The app reads that file. It sets the volume with "volume N" and the mute
// with "mute on|off" on the FIFO of tsx-panelctl (root), which runs
// "sendspin-cli player-vol N" on the control socket of the player.
#pragma once

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace esphome {
namespace tsx_cards {

// The text of the volume file. volume gets 0 to 100, muted 0 or 1, or -1
// when the line is missing or bad. True when the volume is there.
inline bool parse_player_volume(const std::string &text, int &volume, int &muted) {
  volume = -1;
  muted = -1;
  size_t pos = 0;
  while (pos < text.size()) {
    size_t end = text.find('\n', pos);
    if (end == std::string::npos)
      end = text.size();
    std::string line = text.substr(pos, end - pos);
    pos = end + 1;
    size_t eq = line.find('=');
    if (line.empty() || line[0] == '#' || eq == std::string::npos)
      continue;
    std::string key = line.substr(0, eq), value = line.substr(eq + 1);
    while (!key.empty() && (key.back() == ' ' || key.back() == '\t'))
      key.pop_back();
    size_t s = value.find_first_not_of(" \t");
    value = s == std::string::npos ? "" : value.substr(s);
    while (!value.empty() && (value.back() == ' ' || value.back() == '\t' || value.back() == '\r'))
      value.pop_back();
    if (key == "volume") {
      if (!value.empty() && value.size() <= 3 && value.find_first_not_of("0123456789") == std::string::npos) {
        int v = atoi(value.c_str());
        volume = v <= 100 ? v : -1;
      }
    } else if (key == "muted") {
      muted = value == "true" ? 1 : value == "false" ? 0 : -1;
    }
  }
  return volume >= 0;
}

// Read the volume file. False when it does not exist or has no volume.
inline bool read_player_volume(const std::string &path, int &volume, int &muted) {
  volume = muted = -1;
  FILE *f = fopen(path.c_str(), "r");
  if (f == nullptr)
    return false;
  char buf[512];
  size_t n = fread(buf, 1, sizeof buf, f);
  fclose(f);
  return parse_player_volume(std::string(buf, n), volume, muted);
}

// The way out for a value that the panel sets (the volume slider of the
// overlay sends one value per step of a drag, the HA number one per change):
// at most one command per INTERVAL_MS, and always the last value. After a
// send, the panel shows the value it sent until the player reports it, at
// most HOLD_MS, so a slider does not jump back while the command travels.
struct PlayerSetting {
  static const uint32_t INTERVAL_MS = 250;
  static const uint32_t HOLD_MS = 3000;
  int pending{-1};  // the value that waits for its send
  int held{-1};     // the value that the panel shows until the player has it
  uint32_t sent_at{0};
  uint32_t hold_until{0};
  bool sent_once{false};

  // The panel wants v (0 to 100, or 0/1 for the mute).
  void want(int v, uint32_t now) {
    this->pending = v;
    this->held = v;
    this->hold_until = now + HOLD_MS;
  }
  // The value to send now, or -1 (nothing waits, or the last send was less
  // than INTERVAL_MS ago).
  int due(uint32_t now) {
    if (this->pending < 0)
      return -1;
    if (this->sent_once && (int32_t) (now - this->sent_at) < (int32_t) INTERVAL_MS)
      return -1;
    int v = this->pending;
    this->pending = -1;
    this->sent_at = now;
    this->sent_once = true;
    this->hold_until = now + HOLD_MS;
    return v;
  }
  // The value to show, from the value that the player reports (-1: none).
  int shown(int reported, uint32_t now) {
    if (this->held < 0)
      return reported;
    if (this->pending < 0 && (reported == this->held || (int32_t) (now - this->hold_until) >= 0)) {
      this->held = -1;
      return reported;
    }
    return this->held;
  }
};

}  // namespace tsx_cards
}  // namespace esphome
