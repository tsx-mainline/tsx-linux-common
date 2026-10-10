// overlay.cpp: the settings overlay of the panel app. See docs/panel-app.md,
// "Settings overlay". It has the items of the quick settings of the kiosk
// panels (tsx-overlay) that make sense with no browser: the brightness
// slider, Screen off and Setup. It adds the dim and off times, the light
// bars, Reboot and the panel facts.
//
// The overlay is on the top layer: a transparent catcher over the whole
// screen (a tap on it closes the overlay) holds the box. A design rule of
// the app: no shadow and no opacity below 100 %, so the box has a border
// and the pages behind it stay as they are.
#include "tsx_cards.h"
#include "hwconf.h"

#include <algorithm>
#include <arpa/inet.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <spawn.h>
#include <unistd.h>

#include "esphome/core/application.h"
#include "esphome/core/hal.h"
#include "esphome/core/log.h"
#include "esphome/core/version.h"

#ifdef USE_API
#include "esphome/components/api/api_server.h"
#endif

namespace esphome {
namespace tsx_cards {

static const char *const TAG = "tsx_cards.overlay";

// The steps of the - and + buttons of the dim and off times, in seconds.
static const int TIME_STEPS[] = {0, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200};
static const int N_STEPS = sizeof TIME_STEPS / sizeof TIME_STEPS[0];

static std::string time_text(int s) {
  if (s <= 0)
    return "Never";
  char buf[32];
  if (s < 60)
    snprintf(buf, sizeof buf, "%d s", s);
  else if (s < 3600 && s % 60 == 0)
    snprintf(buf, sizeof buf, "%d min", s / 60);
  else if (s < 3600)
    snprintf(buf, sizeof buf, "%d min %d s", s / 60, s % 60);
  else if (s % 3600 == 0)
    snprintf(buf, sizeof buf, "%d h", s / 3600);
  else
    snprintf(buf, sizeof buf, "%d min", s / 60);
  return buf;
}

// The next step after s (dir 1) or before it (dir -1).
static int time_step(int s, int dir) {
  if (dir > 0) {
    for (int i = 0; i < N_STEPS; i++)
      if (TIME_STEPS[i] > s)
        return TIME_STEPS[i];
    return TIME_STEPS[N_STEPS - 1];
  }
  for (int i = N_STEPS - 1; i >= 0; i--)
    if (TIME_STEPS[i] < s)
      return TIME_STEPS[i];
  return 0;
}

// "192.0.2.7 (eth0)" for the first IPv4 address that is not the loopback.
static std::string address_text() {
  struct ifaddrs *list = nullptr;
  std::string out;
  if (getifaddrs(&list) != 0)
    return "no address";
  for (struct ifaddrs *a = list; a != nullptr && out.empty(); a = a->ifa_next) {
    if (a->ifa_addr == nullptr || a->ifa_addr->sa_family != AF_INET || (a->ifa_flags & IFF_LOOPBACK))
      continue;
    char buf[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &reinterpret_cast<sockaddr_in *>(a->ifa_addr)->sin_addr, buf, sizeof buf);
    out = std::string(buf) + " (" + a->ifa_name + ")";
  }
  freeifaddrs(list);
  return out.empty() ? "no address" : out;
}

// The versions of the panel app packages (the apk database), else the
// BUILDINFO files, and the ESPHome version of the program.
std::string TsxCards::version_text_() {
  std::string out;
  FILE *f = fopen("/lib/apk/db/installed", "r");
  if (f != nullptr) {
    char line[512];
    std::string pkg;
    while (fgets(line, sizeof line, f) != nullptr) {
      if (line[0] == 'P' && line[1] == ':') {
        pkg = line + 2;
        while (!pkg.empty() && (pkg.back() == '\n' || pkg.back() == '\r'))
          pkg.pop_back();
      } else if (line[0] == 'V' && line[1] == ':' && pkg.compare(0, 4, "tsx-") == 0 && pkg.size() > 10 &&
                 pkg.compare(pkg.size() - 10, 10, "-panel-app") == 0) {
        std::string ver = line + 2;
        while (!ver.empty() && (ver.back() == '\n' || ver.back() == '\r'))
          ver.pop_back();
        out += (out.empty() ? "" : ", ") + pkg + " " + ver;
      }
    }
    fclose(f);
  }
  if (out.empty()) {
    DIR *d = opendir("/usr/local/share/tsx/panel-app");
    if (d != nullptr) {
      for (dirent *e; (e = readdir(d)) != nullptr;) {
        if (strncmp(e->d_name, "BUILDINFO", 9) != 0)
          continue;
        FILE *b = fopen((std::string("/usr/local/share/tsx/panel-app/") + e->d_name).c_str(), "r");
        char line[256];
        while (b != nullptr && fgets(line, sizeof line, b) != nullptr) {
          if (strncmp(line, "package: ", 9) == 0) {
            std::string v = line + 9;
            while (!v.empty() && v.back() == '\n')
              v.pop_back();
            out += (out.empty() ? "" : ", ") + v;
          }
        }
        if (b != nullptr)
          fclose(b);
      }
      closedir(d);
    }
  }
  if (out.empty())
    out = "no package version";
  return out + ", ESPHome " ESPHOME_VERSION;
}

void TsxCards::toggle_overlay(const char *origin) {
  if (this->overlay_open())
    this->close_overlay();
  else
    this->open_overlay(origin);
}

void TsxCards::open_overlay(const char *origin) {
  if (this->overlay_open())
    return;
  if (this->screen_ != SCREEN_ON)
    this->wake(origin);
  this->close_popup_();
  ESP_LOGI(TAG, "%s: settings overlay open", origin);
  if (this->version_.empty())
    this->version_ = this->version_text_();
  const Theme &th = this->layout_.theme;
  uint32_t box_color = lv_color_to_u32(lv_color_mix(lv_color_hex(th.card), lv_color_hex(th.background), 128)) & 0xFFFFFF;

  this->ov_catcher_ = lv_obj_create(lv_layer_top());
  lv_obj_t *c = this->ov_catcher_;
  lv_obj_remove_style_all(c);
  lv_obj_set_size(c, this->width_, this->height_);
  lv_obj_remove_flag(c, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_remove_flag(c, LV_OBJ_FLAG_GESTURE_BUBBLE);
  lv_obj_add_flag(c, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_add_event_cb(
      c,
      [](lv_event_t *e) {
        auto *self = static_cast<TsxCards *>(lv_event_get_user_data(e));
        if (lv_event_get_target(e) != lv_event_get_current_target(e) || self->multi_touch_())
          return;
        ESP_LOGI(TAG, "tap outside: settings overlay closed");
        self->pending_.push_back([self]() { self->close_overlay(); });
      },
      LV_EVENT_CLICKED, this);

  // The box: at the right edge, as on the other panels, 616 x 452 on an
  // 800 x 480 screen.
  int bw = std::min(616, this->width_ - 16), bh = std::min(452, this->height_ - 16);
  this->ov_box_ = this->box_(c, this->width_ - bw - 8, (this->height_ - bh) / 2, bw, bh, box_color, 16);
  lv_obj_t *b = this->ov_box_;
  lv_obj_set_style_border_width(b, 2, 0);
  lv_obj_set_style_border_color(b, lv_color_hex(th.text_dim), 0);
  lv_obj_add_flag(b, LV_OBJ_FLAG_CLICKABLE);  // a tap on the box does not close it

  // Left: the brightness. A panel with a light sensor (hw.conf) gets a row
  // under the slider that says that the app does not change the backlight
  // from the sensor. With no sensor the row is not there, and the slider
  // takes its space.
  bool light_row = has_light_sensor(this->run_dir_ + "/hw.conf");
  int row_h = light_row ? 0 : 38;
  lv_obj_t *icon = this->label_(b, FONT_ICON, th.text);
  this->set_icon_(icon, "brightness-6", "brightness-6");
  lv_obj_set_pos(icon, 50, 14);
  this->ov_slider_ = lv_slider_create(b);
  lv_obj_t *sl = this->ov_slider_;
  lv_obj_remove_style_all(sl);
  lv_obj_set_pos(sl, 46, 64);
  lv_obj_set_size(sl, 44, bh - 214 + row_h);
  lv_slider_set_range(sl, 1, 100);
  lv_obj_set_style_bg_opa(sl, LV_OPA_COVER, LV_PART_MAIN);
  lv_obj_set_style_bg_color(sl, lv_color_hex(th.background), LV_PART_MAIN);
  lv_obj_set_style_radius(sl, 12, LV_PART_MAIN);
  lv_obj_set_style_bg_opa(sl, LV_OPA_COVER, LV_PART_INDICATOR);
  lv_obj_set_style_bg_color(sl, lv_color_hex(th.card_on), LV_PART_INDICATOR);
  lv_obj_set_style_radius(sl, 12, LV_PART_INDICATOR);
  lv_obj_set_style_bg_opa(sl, LV_OPA_COVER, LV_PART_KNOB);
  lv_obj_set_style_bg_color(sl, lv_color_hex(th.text), LV_PART_KNOB);
  lv_obj_set_style_radius(sl, LV_RADIUS_CIRCLE, LV_PART_KNOB);
  lv_obj_set_style_pad_all(sl, 4, LV_PART_KNOB);
  lv_obj_remove_flag(sl, LV_OBJ_FLAG_GESTURE_BUBBLE);
  lv_slider_set_value(sl, (int) this->level_pct_, LV_ANIM_OFF);
  lv_obj_add_event_cb(
      sl,
      [](lv_event_t *e) {
        auto *self = static_cast<TsxCards *>(lv_event_get_user_data(e));
        auto *s = static_cast<lv_obj_t *>(lv_event_get_target(e));
        bool done = lv_event_get_code(e) == LV_EVENT_RELEASED;
        self->set_backlight(lv_slider_get_value(s), done);
        char buf[16];
        snprintf(buf, sizeof buf, "%d%%", (int) lv_slider_get_value(s));
        lv_label_set_text(self->ov_level_, buf);
      },
      LV_EVENT_VALUE_CHANGED, this);
  lv_obj_add_event_cb(
      sl,
      [](lv_event_t *e) {
        auto *self = static_cast<TsxCards *>(lv_event_get_user_data(e));
        self->set_backlight(lv_slider_get_value(static_cast<lv_obj_t *>(lv_event_get_target(e))), true);
      },
      LV_EVENT_RELEASED, this);
  this->ov_level_ = this->label_(b, FONT_LABEL, th.text);
  lv_obj_set_width(this->ov_level_, 120);
  lv_obj_set_style_text_align(this->ov_level_, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_set_pos(this->ov_level_, 8, bh - 142 + row_h);
  if (light_row) {
    lv_obj_t *note = this->label_(b, FONT_SMALL, th.text_dim);
    lv_obj_set_width(note, 128);
    lv_label_set_long_mode(note, LV_LABEL_LONG_MODE_WRAP);
    lv_obj_set_style_text_align(note, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_text(note, "Auto brightness: off");
    lv_obj_set_pos(note, 4, bh - 108);
  }

  // Right: the times, the buttons and the facts.
  int x0 = 150, rw = bw - x0 - 16;
  auto time_row = [&](int y, const char *text, lv_obj_t **value, bool dim) {
    lv_obj_t *l = this->label_(b, FONT_LABEL, th.text);
    lv_label_set_text(l, text);
    lv_obj_set_pos(l, x0, y + 14);
    int px = x0 + rw - 56;
    lv_obj_t *minus = this->button_(b, this->ov_btns_, "minus", nullptr, 56, 52, [this, dim]() {
      if (dim)
        this->set_dim_timeout(time_step(this->dim_timeout_, -1));
      else
        this->set_blank_timeout(time_step(this->blank_timeout_, -1));
      this->overlay_refresh_();
    });
    lv_obj_set_pos(minus, px - 56 - 110, y);
    *value = this->label_(b, FONT_LABEL, th.text);
    lv_obj_set_width(*value, 106);
    lv_obj_set_style_text_align(*value, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_pos(*value, px - 108, y + 14);
    lv_obj_t *plus = this->button_(b, this->ov_btns_, "plus", nullptr, 56, 52, [this, dim]() {
      if (dim)
        this->set_dim_timeout(time_step(this->dim_timeout_, 1));
      else
        this->set_blank_timeout(time_step(this->blank_timeout_, 1));
      this->overlay_refresh_();
    });
    lv_obj_set_pos(plus, px, y);
  };
  time_row(16, "Dim after", &this->ov_dim_, true);
  time_row(80, "Screen off after", &this->ov_blank_, false);

  int gx = 8, nb = 4;
  int w4 = (rw - (nb - 1) * gx) / nb;
  lv_obj_t *btn = this->button_(b, this->ov_btns_, "monitor-off", "Screen off", w4, 72, [this]() {
    this->screen_off("overlay");
  });
  lv_obj_set_pos(btn, x0, 152);
  lv_obj_t *bars_label = nullptr;
  btn = this->button_(b, this->ov_btns_, "led-strip", "Lights", w4, 72, [this]() {
    this->toggle_panel_lights("overlay");
    this->overlay_refresh_();
  }, &bars_label);
  lv_obj_set_pos(btn, x0 + (w4 + gx), 152);
  this->ov_bars_ = btn;
#ifndef USE_LIGHT
  lv_obj_add_flag(btn, LV_OBJ_FLAG_HIDDEN);
#else
  if (this->panel_lights_.empty())
    lv_obj_add_flag(btn, LV_OBJ_FLAG_HIDDEN);
#endif
  btn = this->button_(b, this->ov_btns_, "cog", "Open setup", w4, 72, [this]() {
    ESP_LOGI(TAG, "overlay: open the setup page");
    this->close_overlay();
    this->open_setup_();
  });
  lv_obj_set_pos(btn, x0 + 2 * (w4 + gx), 152);
  btn = this->button_(b, this->ov_btns_, "restart", "Reboot", w4, 72, [this]() { this->overlay_confirm_reboot_(); });
  lv_obj_set_pos(btn, x0 + 3 * (w4 + gx), 152);

  this->ov_info_ = this->label_(b, FONT_SMALL, th.text_dim);
  lv_obj_set_width(this->ov_info_, rw);
  lv_label_set_long_mode(this->ov_info_, LV_LABEL_LONG_MODE_WRAP);
  lv_obj_set_pos(this->ov_info_, x0, 240);

  btn = this->button_(b, this->ov_btns_, "close", "Close", 150, 56, [this]() { this->close_overlay(); });
  lv_obj_set_pos(btn, bw - 16 - 150, bh - 16 - 56);

  this->ov_last_refresh_ = 0;
  this->overlay_refresh_();
}

void TsxCards::overlay_refresh_() {
  if (!this->overlay_open())
    return;
  this->ov_last_refresh_ = millis();
  char buf[32];
  if (!lv_obj_has_state(this->ov_slider_, LV_STATE_PRESSED)) {
    lv_slider_set_value(this->ov_slider_, (int) this->level_pct_, LV_ANIM_OFF);
    snprintf(buf, sizeof buf, "%d%%", (int) this->level_pct_);
    this->set_text_(this->ov_level_, buf);
  }
  this->set_text_(this->ov_dim_, time_text(this->dim_timeout_).c_str());
  this->set_text_(this->ov_blank_, time_text(this->blank_timeout_).c_str());
  if (this->ov_bars_ != nullptr)
    lv_obj_set_style_bg_color(this->ov_bars_,
                              lv_color_hex(this->panel_lights_on() ? this->layout_.theme.card_on
                                                                 : this->layout_.theme.background),
                              0);
  char host[128] = "";
  gethostname(host, sizeof host - 1);
  bool ha = false;
#ifdef USE_API
  ha = api::global_api_server != nullptr && api::global_api_server->is_connected();
#endif
  std::string info = "Address: " + address_text() + "\nHost name: " + host +
                     "\nHome Assistant: " + (ha ? "connected" : "not connected") +
                     "\nDevice: " + App.get_friendly_name() + "\nVersion: " + this->version_;
  this->set_text_(this->ov_info_, info.c_str());
}

void TsxCards::overlay_confirm_reboot_() {
  if (!this->overlay_open() || this->ov_confirm_ != nullptr)
    return;
  const Theme &th = this->layout_.theme;
  int w = 420, h = 200;
  this->ov_confirm_ = this->box_(this->ov_catcher_, (this->width_ - w) / 2, (this->height_ - h) / 2, w, h, th.card, 16);
  lv_obj_t *b = this->ov_confirm_;
  lv_obj_set_style_border_width(b, 2, 0);
  lv_obj_set_style_border_color(b, lv_color_hex(th.card_on), 0);
  lv_obj_add_flag(b, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_t *l = this->label_(b, FONT_LABEL, th.text);
  lv_obj_set_width(l, w - 40);
  lv_label_set_long_mode(l, LV_LABEL_LONG_MODE_WRAP);
  lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_text(l, "Reboot the panel now?");
  lv_obj_align(l, LV_ALIGN_TOP_MID, 0, 30);
  lv_obj_t *no = this->button_(b, this->ov_btns_, "close", "Cancel", 170, 60, [this]() {
    if (this->ov_confirm_ != nullptr) {
      lv_obj_delete(this->ov_confirm_);
      this->ov_confirm_ = nullptr;
    }
  });
  lv_obj_align(no, LV_ALIGN_BOTTOM_LEFT, 24, -24);
  lv_obj_t *yes = this->button_(b, this->ov_btns_, "restart", "Reboot", 170, 60, [this, l]() {
    const char *cmd = getenv("TSX_PANEL_APP_REBOOT_CMD");
    if (cmd == nullptr || cmd[0] == '\0')
      cmd = "reboot";
    ESP_LOGW(TAG, "overlay: reboot (%s)", cmd);
    lv_label_set_text(l, "Rebooting ...");
    char *const argv[] = {const_cast<char *>(cmd), nullptr};
    pid_t pid;
    int err = posix_spawnp(&pid, cmd, nullptr, nullptr, argv, environ);
    if (err != 0)
      ESP_LOGW(TAG, "cannot run %s: %s", cmd, strerror(err));
    else
      this->children_.push_back(pid);
  });
  lv_obj_align(yes, LV_ALIGN_BOTTOM_RIGHT, -24, -24);
  ESP_LOGI(TAG, "overlay: reboot asks for a confirmation");
}

void TsxCards::close_overlay() {
  if (!this->overlay_open())
    return;
  lv_obj_delete(this->ov_catcher_);
  this->ov_catcher_ = this->ov_box_ = this->ov_slider_ = this->ov_level_ = nullptr;
  this->ov_dim_ = this->ov_blank_ = this->ov_info_ = this->ov_bars_ = this->ov_confirm_ = nullptr;
  this->ov_btns_.clear();
  ESP_LOGI(TAG, "settings overlay closed");
}

void TsxCards::overlay_loop_() {
  if (!this->overlay_open())
    return;
  if (lv_display_get_inactive_time(nullptr) >= this->overlay_timeout_ && this->ov_confirm_ == nullptr) {
    ESP_LOGI(TAG, "no touch for %u s: settings overlay closed", (unsigned) (this->overlay_timeout_ / 1000));
    this->close_overlay();
    return;
  }
  if (millis() - this->ov_last_refresh_ >= 1000)
    this->overlay_refresh_();
}

bool TsxCards::panel_lights_on() const {
#ifdef USE_LIGHT
  for (auto *l : this->panel_lights_)
    if (l->remote_values.is_on())
      return true;
#endif
  return false;
}

void TsxCards::toggle_panel_lights(const char *origin) {
#ifdef USE_LIGHT
  if (this->panel_lights_.empty()) {
    ESP_LOGI(TAG, "%s: this panel has no panel lights", origin);
    return;
  }
  bool on = this->panel_lights_on();
  for (auto *l : this->panel_lights_) {
    auto call = l->make_call();
    call.set_state(!on);
    call.perform();
  }
  ESP_LOGI(TAG, "%s: panel lights %s", origin, on ? "off" : "on");
#else
  ESP_LOGI(TAG, "%s: this panel has no panel lights", origin);
#endif
}

}  // namespace tsx_cards
}  // namespace esphome
