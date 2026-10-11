// control.cpp: the control interface of the panel app (control.h). See
// docs/panel-app.md, "Control from the panel".
#include "tsx_cards.h"
#include "control.h"
#include "runstate.h"

#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <sys/stat.h>

#include "esphome/core/hal.h"
#include "esphome/core/log.h"

namespace esphome {
namespace tsx_cards {

static const char *const TAG = "tsx_cards.control";

void TsxCards::control_loop_() {
  uint32_t now = millis();
  if (now - this->last_control_ < 500)
    return;
  this->last_control_ = now;
  for (const auto &line : take_control_lines(this->run_dir_ + "/panel-app/control.d"))
    this->apply_control_(line);
  this->write_screen_state_();
}

void TsxCards::apply_control_(const std::string &line) {
  ControlCmd c;
  if (!parse_control_line(line, c)) {
    std::string shown;
    for (char ch : line)
      if (ch >= 0x20 && ch < 0x7f && shown.size() < 80)
        shown += ch;
    ESP_LOGW(TAG, "control: refused '%s'", shown.c_str());
    return;
  }
  switch (c.kind) {
    case ControlCmd::SCREEN:
      if (c.on)
        this->wake("panel control");
      else
        this->screen_off("panel control");
      break;
    case ControlCmd::BACKLIGHT:
      ESP_LOGI(TAG, "control: backlight %d%%", c.value);
      this->set_backlight(c.value);
      break;
    case ControlCmd::LIGHTS_ON_OFF:
    case ControlCmd::LIGHTS_SET:
#ifdef USE_LIGHT
      if (this->panel_lights_.empty()) {
        ESP_LOGI(TAG, "control: this panel has no panel lights");
        break;
      }
      for (auto *l : this->panel_lights_) {
        auto call = l->make_call();
        call.set_state(c.on);
        if (c.kind == ControlCmd::LIGHTS_SET) {
          call.set_brightness(c.value / 100.0f);
          if (l->get_traits().supports_color_capability(light::ColorCapability::RGB))
            call.set_rgb(c.r / 255.0f, c.g / 255.0f, c.b / 255.0f);
        }
        call.perform();
      }
      ESP_LOGI(TAG, "control: panel lights %s", c.on ? "on" : "off");
#else
      ESP_LOGI(TAG, "control: this panel has no panel lights");
#endif
      break;
    default:
      break;
  }
}

void TsxCards::write_screen_state_() {
  int lights = -1, bri = 0, r = 0, g = 0, b = 0;
#ifdef USE_LIGHT
  if (!this->panel_lights_.empty()) {
    lights = this->panel_lights_on() ? 1 : 0;
    auto &v = this->panel_lights_.front()->remote_values;
    bri = std::max(1, (int) lroundf(v.get_brightness() * 100));
    r = (int) lroundf(v.get_red() * 255);
    g = (int) lroundf(v.get_green() * 255);
    b = (int) lroundf(v.get_blue() * 255);
  }
#endif
  std::string text = screen_state_text((int) this->screen_, (int) this->level_pct_, this->dim_timeout_,
                                       this->blank_timeout_, this->dim_pct_, lights, bri, r, g, b);
  if (text == this->screen_state_text_)
    return;
  std::string path = this->out_path_("screen.state");
  if (this->write_run_file_(path, text)) {
    chmod(path.c_str(), 0644);
    this->screen_state_text_ = text;
  }
}

// The path of a file that the app writes for the other services: in the
// folder of the app (TSX_PANEL_APP_OUT_DIR), else at the old place.
std::string TsxCards::out_path_(const char *name) const {
  if (!this->out_dir_.empty())
    return this->out_dir_ + "/" + name;
  if (strcmp(name, "panel-app.state") == 0)
    return this->run_dir_ + "/panel-app.state";
  return this->run_dir_ + "/panel-app/" + name;
}

bool TsxCards::panelctl_send_(const std::string &line) {
  std::string err;
  if (fifo_send_line(this->panelctl_, line, err)) {
    ESP_LOGD(TAG, "tsx-panelctl: %s", line.c_str());
    return true;
  }
  ESP_LOGW(TAG, "tsx-panelctl '%s': %s", line.c_str(), err.c_str());
  return false;
}

}  // namespace tsx_cards
}  // namespace esphome
