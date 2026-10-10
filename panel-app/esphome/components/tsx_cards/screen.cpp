// screen.cpp: the screen of the panel app. See docs/panel-app.md, "Screen".
//
// - The backlight level of the user is a percent of the slider (1 to 100).
//   The slider maps to the backlight steps with a square on a wide range,
//   as tsx-level.h of the kiosk panels does, so the dark end has finer steps.
//   The app keeps the level in ESPHOME_PREFDIR/backlight.
// - After dim_timeout seconds with no touch and no key, the backlight goes
//   to the dim level. After blank_timeout seconds it goes off, and the
//   on_screen trigger turns the display output off. 0 = never.
// - The panel.conf keys BLANK_TIMEOUT (tsx-config apply writes
//   /run/tsx/blank-timeout, the same file that tsx-idled reads on the kiosk
//   panels), DIM_TIMEOUT and DIM_LEVEL (the config.d plugin of the panel app
//   writes /run/tsx/dim-timeout and /run/tsx/dim-level) replace the defaults
//   of the YAML. The app reads the files every 5 s.
// - While the screen is dim or off, a transparent "shield" on the top layer
//   takes the touch. A touch wakes the screen, and the shield stays until
//   the finger lifts, so the touch that wakes does not act on a card.
// - With input_id, the wake comes from the input device itself (tsx_evdev
//   calls on_input_() for the first report of a touch), before LVGL reads
//   the touch. So a short tap wakes the screen, also when LVGL never sees
//   it pressed. The shield then stays until the finger lifts and LVGL had
//   time to read the release (SHIELD_GUARD_MS).
// - The wake order: the CPU at full speed (cpu.cpp), the picture on the
//   output (on_screen: the display puts the full frame on the output and
//   waits for the flip), and only then the backlight. So the glass never
//   shows an old, a black or a white frame with the backlight on.
#include "tsx_cards.h"

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <ctime>

#include "esphome/core/application.h"
#include "esphome/core/hal.h"
#include "esphome/core/log.h"

namespace esphome {
namespace tsx_cards {

static const char *const TAG = "tsx_cards.screen";
// A value set on the panel (overlay, Home Assistant) wins over the files
// until tsx-config apply has written them.
static const uint32_t LOCAL_SET_HOLD_MS = 30000;
// The shield stays this long after the last touch report: the touchscreen
// component and LVGL read the touch one or two loop passes later.
static const uint32_t SHIELD_GUARD_MS = 120;

static uint64_t now_us() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000ULL + ts.tv_nsec / 1000;
}

static bool read_line(const std::string &path, std::string &out) {
  FILE *f = fopen(path.c_str(), "r");
  if (f == nullptr)
    return false;
  char buf[256];
  bool ok = fgets(buf, sizeof buf, f) != nullptr;
  fclose(f);
  if (!ok)
    return false;
  out = buf;
  while (!out.empty() && (out.back() == '\n' || out.back() == '\r' || out.back() == ' '))
    out.pop_back();
  return true;
}

static bool read_int(const std::string &path, int &out) {
  std::string s;
  if (!read_line(path, s) || s.empty())
    return false;
  char *end = nullptr;
  long v = strtol(s.c_str(), &end, 10);
  if (end == s.c_str() || (*end != '\0' && *end != ' '))
    return false;
  out = (int) v;
  return true;
}

// KEY=number from a shell-style file (panel-board.conf).
static bool conf_int(const std::string &path, const char *key, int &out) {
  FILE *f = fopen(path.c_str(), "r");
  if (f == nullptr)
    return false;
  char line[256];
  size_t kl = strlen(key);
  bool found = false;
  while (fgets(line, sizeof line, f) != nullptr) {
    if (strncmp(line, key, kl) == 0 && line[kl] == '=') {
      const char *v = line + kl + 1;
      if (*v == '"' || *v == '\'')
        v++;
      char *end = nullptr;
      long n = strtol(v, &end, 10);
      if (end != v) {
        out = (int) n;
        found = true;
      }
    }
  }
  fclose(f);
  return found;
}

static bool write_text(const std::string &path, const std::string &text) {
  FILE *f = fopen(path.c_str(), "w");
  if (f == nullptr)
    return false;
  bool ok = fwrite(text.data(), 1, text.size(), f) == text.size();
  return fclose(f) == 0 && ok;
}

void TsxCards::screen_setup_() {
  const char *rd = getenv("TSX_RUN_DIR");
  if (rd != nullptr && rd[0] != '\0')
    this->run_dir_ = rd;
  const char *pd = getenv("ESPHOME_PREFDIR");
  this->pref_dir_ = pd != nullptr && pd[0] != '\0' ? pd : "/var/lib/tsx/panel-app";
  const char *bd = getenv("TSX_BACKLIGHT_DIR");
  if (bd != nullptr && bd[0] != '\0')
    this->backlight_dir_ = bd;
  if (this->backlight_dir_ == "auto") {
    this->backlight_dir_.clear();
    DIR *d = opendir("/sys/class/backlight");
    if (d != nullptr) {
      for (dirent *e; (e = readdir(d)) != nullptr;) {
        if (e->d_name[0] != '.') {
          this->backlight_dir_ = std::string("/sys/class/backlight/") + e->d_name;
          break;
        }
      }
      closedir(d);
    }
  }
  int max = 0;
  if (!this->backlight_dir_.empty())
    read_int(this->backlight_dir_ + "/max_brightness", max);
  this->bl_max_ = max;
  // The board range: BACKLIGHT_MIN (the floor of a lit level) and
  // BACKLIGHT_MAX (a cap) of panel-board.conf.
  const char *bc = getenv("TSX_PANEL_BOARD_CONF");
  std::string board_conf = bc != nullptr && bc[0] != '\0' ? bc : "/etc/tsx/panel-board.conf";
  int v;
  this->bl_min_ = max * 3 / 100 > 1 ? max * 3 / 100 : 1;
  if (conf_int(board_conf, "BACKLIGHT_MIN", v) && v >= 1 && v < max)
    this->bl_min_ = v;
  if (conf_int(board_conf, "BACKLIGHT_MAX", v) && v > this->bl_min_ && v < max)
    this->bl_max_ = v;
  if (this->bl_max_ <= 0) {
    ESP_LOGW(TAG, "no backlight in /sys/class/backlight: the screen has no dim and no off");
  } else {
    int pct;
    int cur = 0;
    if (read_int(this->pref_dir_ + "/backlight", pct) && pct >= 1 && pct <= 100) {
      this->level_pct_ = pct;
      this->level_saved_ = true;
    } else if (read_int(this->backlight_dir_ + "/brightness", cur) && cur > 0) {
      // No level of the user yet: keep the level that is on the glass.
      double f = double(cur - this->bl_min_) / (this->bl_max_ - this->bl_min_);
      if (f < 0)
        f = 0;
      if (f > 1)
        f = 1;
      if (this->bl_max_ - this->bl_min_ > 64)
        f = std::sqrt(f);
      this->level_pct_ = std::max(1L, lround(f * 100));
    }
    if (this->screen_ == SCREEN_ON)
      this->write_backlight_(this->pct_to_raw_(this->level_pct_));
    ESP_LOGI(TAG, "backlight %s: steps %d..%d, level %.0f%% (%d)", this->backlight_dir_.c_str(), this->bl_min_,
             this->bl_max_, this->level_pct_, this->pct_to_raw_(this->level_pct_));
  }
  this->dim_timeout_ = this->def_dim_timeout_;
  this->blank_timeout_ = this->def_blank_timeout_;
  this->dim_pct_ = this->def_dim_level_;
  this->read_screen_files_(true);

  // The shield: on the top layer, over every page, hidden while the screen
  // is on. It is transparent, so it costs no drawing.
  this->shield_ = lv_obj_create(lv_layer_top());
  lv_obj_remove_style_all(this->shield_);
  lv_obj_set_pos(this->shield_, 0, 0);
  lv_obj_set_size(this->shield_, this->width_, this->height_);
  lv_obj_remove_flag(this->shield_, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_remove_flag(this->shield_, LV_OBJ_FLAG_GESTURE_BUBBLE);
  lv_obj_add_flag(this->shield_, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_add_flag(this->shield_, LV_OBJ_FLAG_HIDDEN);
  this->last_idle_ = lv_display_get_inactive_time(nullptr);
#ifdef USE_TSX_CARDS_INPUT
  if (this->input_ != nullptr)
    this->input_->add_on_input_callback([this](tsx_evdev::TsxEvdev::Activity a) { this->on_input_(a); });
#endif
  this->on_loop_interval_ = App.get_loop_interval();
  this->cpu_setup_();
}

// An input event, at once (tsx_evdev loop), before LVGL sees it.
void TsxCards::on_input_(int kind) {
#ifdef USE_TSX_CARDS_INPUT
  if (kind == tsx_evdev::TsxEvdev::TOUCH_START && this->screen_ != SCREEN_ON) {
    this->wake_event_us_ = this->input_->touch_start_us();
    this->wake("touch");
    return;
  }
  // A key wakes the screen in key_state(), which also keeps the key from
  // acting.
  if (this->screen_ == SCREEN_ON)
    this->cpu_boost_();
#endif
}

int TsxCards::pct_to_raw_(float pct) const {
  if (this->bl_max_ <= 0)
    return 0;
  if (pct <= 0)
    return 0;
  double pos = pct >= 100 ? 1.0 : pct / 100.0;
  int range = this->bl_max_ - this->bl_min_;
  double f = range > 64 ? pos * pos : pos;
  return this->bl_min_ + (int) lround(f * range);
}

void TsxCards::write_backlight_(int raw) {
  if (this->backlight_dir_.empty() || this->bl_max_ <= 0)
    return;
  if (!write_text(this->backlight_dir_ + "/brightness", std::to_string(raw) + "\n"))
    ESP_LOGW(TAG, "backlight %d: %s", raw, strerror(errno));
}

void TsxCards::read_screen_files_(bool force) {
  this->last_screen_files_ = millis();
  if (!force && this->local_set_ && millis() - this->local_set_at_ < LOCAL_SET_HOLD_MS)
    return;
  this->local_set_ = false;
  int v;
  int blank = read_int(this->run_dir_ + "/blank-timeout", v) && v >= 0 && v <= 86400 ? v : this->def_blank_timeout_;
  int dim = read_int(this->run_dir_ + "/dim-timeout", v) && v >= 0 && v <= 86400 ? v : this->def_dim_timeout_;
  int lvl = read_int(this->run_dir_ + "/dim-level", v) && v >= 1 && v <= 100 ? v : this->def_dim_level_;
  if (blank != this->blank_timeout_ || dim != this->dim_timeout_ || lvl != this->dim_pct_ || force)
    ESP_LOGI(TAG, "dim after %d s (level %d%%), off after %d s (0 = never)", dim, lvl, blank);
  this->blank_timeout_ = blank;
  this->dim_timeout_ = dim;
  bool relevel = lvl != this->dim_pct_;
  this->dim_pct_ = lvl;
  if (relevel && this->screen_ == SCREEN_DIM)
    this->write_backlight_(this->pct_to_raw_(std::min<float>(this->dim_pct_, this->level_pct_)));
}

static bool pointer_pressed() {
  for (lv_indev_t *i = lv_indev_get_next(nullptr); i != nullptr; i = lv_indev_get_next(i)) {
    if (lv_indev_get_type(i) == LV_INDEV_TYPE_POINTER && lv_indev_get_state(i) == LV_INDEV_STATE_PRESSED)
      return true;
  }
  return false;
}

void TsxCards::screen_loop_() {
  uint32_t now = millis();
  this->cpu_loop_();
  if (now - this->last_screen_files_ >= 5000)
    this->read_screen_files_(false);
  uint32_t idle = lv_display_get_inactive_time(nullptr);
  // With no input device of its own, LVGL tells of a touch.
  if (this->screen_ != SCREEN_ON && idle < this->last_idle_)
    this->wake("touch");
  this->last_idle_ = idle;
  if (this->shield_ != nullptr && !lv_obj_has_flag(this->shield_, LV_OBJ_FLAG_HIDDEN)) {
    bool finger = false;
#ifdef USE_TSX_CARDS_INPUT
    // A tap that woke the screen is no five-finger tap.
    if (this->input_ != nullptr) {
      this->input_->take_tap();
      finger = this->input_->touch_count() > 0 || now - this->input_->last_input_ms() < SHIELD_GUARD_MS;
    }
#endif
    if (this->screen_ == SCREEN_ON && !finger && !pointer_pressed()) {
      lv_obj_add_flag(this->shield_, LV_OBJ_FLAG_HIDDEN);
      lv_display_trigger_activity(nullptr);
      this->last_idle_ = 0;
    }
  }
  if (this->bl_max_ <= 0)
    return;
  uint32_t blank = uint32_t(this->blank_timeout_) * 1000, dim = uint32_t(this->dim_timeout_) * 1000;
  if (this->screen_ == SCREEN_ON) {
    if (blank > 0 && idle >= blank)
      this->screen_set_(SCREEN_OFF, "idle");
    else if (dim > 0 && idle >= dim && (blank == 0 || dim < blank))
      this->screen_set_(SCREEN_DIM, "idle");
  } else if (this->screen_ == SCREEN_DIM && blank > 0 && idle >= blank) {
    this->screen_set_(SCREEN_OFF, "idle");
  }
}

void TsxCards::screen_set_(ScreenState s, const char *origin) {
  if (s == this->screen_)
    return;
  ScreenState prev = this->screen_;
  this->screen_ = s;
  static const char *const NAMES[] = {"on", "dim", "off"};
  ESP_LOGI(TAG, "screen %s (%s)", NAMES[s], origin);
  if (s != SCREEN_ON) {
    // Keep the level of the user before the backlight changes: a restart
    // while the screen is dim must not take the dim level as the level.
    if (!this->level_saved_)
      this->save_level_();
    this->close_overlay();
    this->close_popup_();
    if (this->shield_ != nullptr) {
      lv_obj_remove_flag(this->shield_, LV_OBJ_FLAG_HIDDEN);
      lv_obj_move_foreground(this->shield_);
    }
  }
  switch (s) {
    case SCREEN_ON: {
      // The CPU first: the frame copy and the first frames run at full
      // speed. Then the picture on the output, then the backlight.
      uint64_t t0 = now_us();
      if (prev == SCREEN_OFF && this->off_loop_interval_ > 0)
        App.set_loop_interval(this->on_loop_interval_);
      this->cpu_screen_(true);
      this->cpu_boost_();
      uint64_t t_cpu = now_us();
      if (prev == SCREEN_OFF)
        this->screen_trigger_.trigger(true);
      uint64_t t_out = now_us();
      this->write_backlight_(this->pct_to_raw_(this->level_pct_));
      uint64_t t_bl = now_us();
      lv_display_trigger_activity(nullptr);
      this->last_idle_ = 0;
      if (this->wake_event_us_ != 0 && this->wake_event_us_ <= t0)
        ESP_LOGI("perf", "wake (%s): backlight on %.1f ms after the input event (to the wake %.1f ms, CPU %.1f ms, "
                 "picture %.1f ms)",
                 origin, (t_bl - this->wake_event_us_) / 1000.0, (t0 - this->wake_event_us_) / 1000.0,
                 (t_cpu - t0) / 1000.0, (t_out - t_cpu) / 1000.0);
      else
        ESP_LOGI("perf", "wake (%s): backlight on %.1f ms after the wake (CPU %.1f ms, picture %.1f ms)", origin,
                 (t_bl - t0) / 1000.0, (t_cpu - t0) / 1000.0, (t_out - t_cpu) / 1000.0);
      this->wake_event_us_ = 0;
      break;
    }
    case SCREEN_DIM:
      this->write_backlight_(this->pct_to_raw_(std::min<float>(this->dim_pct_, this->level_pct_)));
      break;
    case SCREEN_OFF:
      this->write_backlight_(0);
      this->screen_trigger_.trigger(false);
      this->cpu_screen_(false);
      if (this->off_loop_interval_ > 0) {
        this->on_loop_interval_ = App.get_loop_interval();
        App.set_loop_interval(this->off_loop_interval_);
      }
      break;
  }
}

void TsxCards::wake(const char *origin) {
  if (this->screen_ == SCREEN_ON) {
    lv_display_trigger_activity(nullptr);
    return;
  }
#ifdef USE_TSX_CARDS_INPUT
  // A key: the time of its event, for the wake time in the log.
  if (this->wake_event_us_ == 0 && this->input_ != nullptr && strncmp(origin, "key ", 4) == 0)
    this->wake_event_us_ = this->input_->last_event_us();
#endif
  this->screen_set_(SCREEN_ON, origin);
}

void TsxCards::screen_off(const char *origin) { this->screen_set_(SCREEN_OFF, origin); }

void TsxCards::set_backlight(float pct, bool save) {
  if (pct < 1)
    pct = 1;
  if (pct > 100)
    pct = 100;
  pct = std::round(pct);
  bool changed = pct != this->level_pct_;
  this->level_pct_ = pct;
  if (this->screen_ == SCREEN_ON)
    this->write_backlight_(this->pct_to_raw_(pct));
  if (save && (changed || !this->level_saved_)) {
    this->save_level_();
    ESP_LOGI(TAG, "backlight %d%% (%d)", (int) pct, this->pct_to_raw_(pct));
  }
}

void TsxCards::save_level_() {
  mkdir(this->pref_dir_.c_str(), 0700);
  std::string tmp = this->pref_dir_ + "/backlight.tmp";
  if (write_text(tmp, std::to_string((int) this->level_pct_) + "\n") &&
      rename(tmp.c_str(), (this->pref_dir_ + "/backlight").c_str()) == 0)
    this->level_saved_ = true;
}

void TsxCards::set_blank_timeout(float s) {
  int v = std::max(0, std::min(86400, (int) lround(s)));
  this->blank_timeout_ = v;
  this->config_set_("BLANK_TIMEOUT", std::to_string(v));
}

void TsxCards::set_dim_timeout(float s) {
  int v = std::max(0, std::min(86400, (int) lround(s)));
  this->dim_timeout_ = v;
  this->config_set_("DIM_TIMEOUT", std::to_string(v));
}

void TsxCards::set_dim_level(float pct) {
  int v = std::max(1, std::min(100, (int) lround(pct)));
  this->dim_pct_ = v;
  if (this->screen_ == SCREEN_DIM)
    this->write_backlight_(this->pct_to_raw_(std::min<float>(v, this->level_pct_)));
  this->config_set_("DIM_LEVEL", std::to_string(v));
}

// Keep a setting in panel.conf: `tsx-config set KEY VALUE` and `tsx-config
// apply`, 2 s after the last change, in one child process. The value
// applies in the app at once.
void TsxCards::config_set_(const char *key, const std::string &value) {
  this->config_pending_[key] = value;
  this->config_due_ = millis() + 2000;
  this->local_set_ = true;
  this->local_set_at_ = millis();
  ESP_LOGI(TAG, "%s=%s (panel.conf in 2 s)", key, value.c_str());
}

void TsxCards::reap_children_() {
  for (size_t i = 0; i < this->children_.size();) {
    int status = 0;
    pid_t r = waitpid(this->children_[i], &status, WNOHANG);
    if (r == 0) {
      i++;
      continue;
    }
    if (r > 0 && (!WIFEXITED(status) || WEXITSTATUS(status) != 0))
      ESP_LOGW(TAG, "child %d ended with status %d", (int) r, WIFEXITED(status) ? WEXITSTATUS(status) : -1);
    this->children_.erase(this->children_.begin() + i);
  }
  if (this->config_pending_.empty() || (int32_t) (millis() - this->config_due_) < 0 || !this->children_.empty())
    return;
  const char *cmd = getenv("TSX_PANEL_APP_CONFIG_CMD");
  if (cmd == nullptr || cmd[0] == '\0')
    cmd = "tsx-config";
  std::vector<std::string> args = {
      "sh", "-c",
      "c=$1; shift; while [ $# -ge 2 ]; do \"$c\" set \"$1\" \"$2\" || exit 1; shift 2; done; \"$c\" apply",
      "tsx-panel-app-config", cmd};
  for (auto &kv : this->config_pending_) {
    args.push_back(kv.first);
    args.push_back(kv.second);
  }
  this->config_pending_.clear();
  this->local_set_at_ = millis();
  std::vector<char *> argv;
  for (auto &a : args)
    argv.push_back(const_cast<char *>(a.c_str()));
  argv.push_back(nullptr);
  pid_t pid;
  int err = posix_spawn(&pid, "/bin/sh", nullptr, nullptr, argv.data(), environ);
  if (err != 0) {
    ESP_LOGW(TAG, "cannot run %s: %s", cmd, strerror(err));
    return;
  }
  this->children_.push_back(pid);
  ESP_LOGI(TAG, "%s set and apply (pid %d)", cmd, (int) pid);
}

}  // namespace tsx_cards
}  // namespace esphome
