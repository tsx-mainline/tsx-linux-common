// update_logic.h: the update state of the panel for update.cpp, with no LVGL
// and no ESPHome, so tests/test-panel-app-update.sh can test it. See
// docs/panel-app.md, "Updates".
//
// tsx-autoupdate (root) writes /run/tsx/update.state with one "key value"
// pair on each line:
//   installed 0.3.5
//   latest 0.3.6
//   title TSX HOST packages
//   summary Text to the end of the line. No escape.
//   in-progress yes|no
//   restart-required yes|no
//   mode auto|manual
//   auto-restart on|off
// The app reads the file. It sets the mode, the automatic restart and the
// install with lines on the FIFO of tsx-panelctl (root).
#pragma once

#include <cstdint>
#include <cstdio>
#include <string>

namespace esphome {
namespace tsx_cards {

// The values are the same as UpdateState of the ESPHome update component.
enum UpdState : uint8_t { UPD_UNKNOWN = 0, UPD_NO_UPDATE, UPD_AVAILABLE, UPD_INSTALLING };

struct UpdateStatus {
  bool present{false};  // the file was read
  std::string installed, latest, title, summary;
  int in_progress{-1};       // 1 yes, 0 no, -1 not in the file
  int restart_required{-1};  // 1 yes, 0 no, -1 not in the file
  std::string mode;          // auto, manual, or "" (not in the file or bad)
  int auto_restart{-1};      // 1 on, 0 off, -1 not in the file

  // Unknown: no file, or the version of the running release is not known.
  bool known() const { return this->present && !this->installed.empty() && this->installed != "unknown"; }
  // The state of the update entity, from the file only.
  UpdState state() const {
    if (!this->known())
      return UPD_UNKNOWN;
    if (this->in_progress == 1)
      return UPD_INSTALLING;
    if (!this->latest.empty() && this->latest != this->installed)
      return UPD_AVAILABLE;
    return UPD_NO_UPDATE;
  }
  // The latest version for the entity: the installed one when the file has no latest.
  std::string latest_version() const { return this->latest.empty() ? this->installed : this->latest; }
};

inline int update_yes_no(const std::string &v) { return v == "yes" ? 1 : v == "no" ? 0 : -1; }

// The mode of the panel: "auto" or "manual". False for any other text.
inline bool valid_update_mode(const std::string &mode) { return mode == "auto" || mode == "manual"; }

// The code of a mode for HeldValue: auto 0, manual 1, else -1. And back.
inline int update_mode_code(const std::string &mode) { return mode == "auto" ? 0 : mode == "manual" ? 1 : -1; }
inline std::string update_mode_name(int code) { return code == 0 ? "auto" : code == 1 ? "manual" : ""; }

// The lines for the FIFO of tsx-panelctl. An empty line means: refused.
inline std::string update_mode_line(const std::string &mode) {
  return valid_update_mode(mode) ? "update-mode " + mode : "";
}
inline std::string auto_restart_line(bool on) { return on ? "auto-restart on" : "auto-restart off"; }
inline const char *update_install_line() { return "update-install"; }
inline const char *update_restart_line() { return "reboot"; }

// The text of update.state. True when the text has an installed version that
// is not "unknown". The status is filled in all cases (bad lines are skipped).
inline bool parse_update_state(const std::string &text, UpdateStatus &s) {
  s = UpdateStatus();
  s.present = true;
  size_t pos = 0;
  while (pos < text.size()) {
    size_t end = text.find('\n', pos);
    if (end == std::string::npos)
      end = text.size();
    std::string line = text.substr(pos, end - pos);
    pos = end + 1;
    while (!line.empty() && (line.back() == '\r' || line.back() == ' ' || line.back() == '\t'))
      line.pop_back();
    size_t sp = line.find(' ');
    if (line.empty() || line[0] == '#' || sp == std::string::npos)
      continue;
    std::string key = line.substr(0, sp);
    size_t vs = line.find_first_not_of(' ', sp);
    std::string value = vs == std::string::npos ? "" : line.substr(vs);
    if (key == "installed")
      s.installed = value;
    else if (key == "latest")
      s.latest = value;
    else if (key == "title")
      s.title = value;
    else if (key == "summary")
      s.summary = value;
    else if (key == "in-progress")
      s.in_progress = update_yes_no(value);
    else if (key == "restart-required")
      s.restart_required = update_yes_no(value);
    else if (key == "mode")
      s.mode = valid_update_mode(value) ? value : "";
    else if (key == "auto-restart")
      s.auto_restart = value == "on" ? 1 : value == "off" ? 0 : -1;
  }
  return s.known();
}

// Read the file (at most 4 KiB). No file: the status is not present.
inline bool read_update_state(const std::string &path, UpdateStatus &s) {
  s = UpdateStatus();
  FILE *f = fopen(path.c_str(), "r");
  if (f == nullptr)
    return false;
  char buf[4096];
  size_t n = fread(buf, 1, sizeof buf, f);
  fclose(f);
  return parse_update_state(std::string(buf, n), s);
}

// A value that the panel sets. After the set, the panel shows that value
// until the file reports it, at most HOLD_MS (the same pattern as
// PlayerSetting in volume_logic.h, but the app sends at once).
struct HeldValue {
  static const uint32_t HOLD_MS = 10000;
  int held{-1};
  uint32_t until{0};

  void set(int v, uint32_t now) {
    this->held = v;
    this->until = now + HOLD_MS;
  }
  // True while a set waits for the file.
  bool active(uint32_t now) const { return this->held >= 0 && (int32_t) (now - this->until) < 0; }
  // The value to show, from the value that the file reports (-1: none).
  int shown(int reported, uint32_t now) {
    if (this->held < 0)
      return reported;
    if (reported == this->held || (int32_t) (now - this->until) >= 0) {
      this->held = -1;
      return reported;
    }
    return this->held;
  }
};

// The state to show: while the install waits for the file (hold), an update
// that is available shows as installing.
inline UpdState update_shown_state(const UpdateStatus &s, bool install_hold) {
  UpdState st = s.state();
  return st == UPD_AVAILABLE && install_hold ? UPD_INSTALLING : st;
}

}  // namespace tsx_cards
}  // namespace esphome
