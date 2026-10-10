// popup.cpp: the detail popup of a card (a long press). See docs/panel-app.md,
// "Detail popups". light: brightness; fan: speed; cover: position;
// media_player: volume and the track buttons; climate: the modes and the
// target. A tap outside the popup or 10 s with no touch closes it.
#include "tsx_cards.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

#include "esphome/core/hal.h"
#include "esphome/core/log.h"

namespace esphome {
namespace tsx_cards {

static const char *const TAG = "tsx_cards.popup";
static const uint32_t POPUP_TIMEOUT_MS = 10000;

static bool number_of(const Slot *s, double &out) {
  if (s == nullptr || !s->has_value || s->value.empty())
    return false;
  char *end = nullptr;
  out = strtod(s->value.c_str(), &end);
  return end != nullptr && *end == '\0' && std::isfinite(out);
}

// The modes in a list attribute as Home Assistant sends it: the Python text
// of the list, for example "['off', 'heat']" or "[<HVACMode.OFF: 'off'>]".
// The quoted words are the modes.
static std::vector<std::string> quoted_words(const std::string &s) {
  std::vector<std::string> out;
  size_t i = 0;
  while ((i = s.find('\'', i)) != std::string::npos) {
    size_t j = s.find('\'', i + 1);
    if (j == std::string::npos)
      break;
    std::string w = s.substr(i + 1, j - i - 1);
    bool dup = false;
    for (const auto &x : out)
      dup |= x == w;
    if (!w.empty() && !dup)
      out.push_back(w);
    i = j + 1;
  }
  return out;
}

static std::string nice(const std::string &s) {
  std::string out = s;
  for (auto &ch : out)
    if (ch == '_')
      ch = ' ';
  if (!out.empty() && out[0] >= 'a' && out[0] <= 'z')
    out[0] = out[0] - 'a' + 'A';
  return out;
}

void TsxCards::open_popup_(CardView *v) {
  this->close_popup_();
  this->close_overlay();
  const CardSpec &c = *v->spec;
  const Theme &th = this->layout_.theme;
  this->popup_view_ = v;

  this->popup_catcher_ = lv_obj_create(lv_layer_top());
  lv_obj_t *cat = this->popup_catcher_;
  lv_obj_remove_style_all(cat);
  lv_obj_set_size(cat, this->width_, this->height_);
  lv_obj_remove_flag(cat, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_remove_flag(cat, LV_OBJ_FLAG_GESTURE_BUBBLE);
  lv_obj_add_flag(cat, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_add_event_cb(
      cat,
      [](lv_event_t *e) {
        auto *self = static_cast<TsxCards *>(lv_event_get_user_data(e));
        if (lv_event_get_target(e) != lv_event_get_current_target(e) || self->multi_touch_())
          return;
        ESP_LOGI(TAG, "tap outside: popup closed");
        self->pending_.push_back([self]() { self->close_popup_(); });
      },
      LV_EVENT_CLICKED, this);

  int bw = std::min(560, this->width_ - 40), bh = std::min(300, this->height_ - 40);
  lv_obj_t *b = this->box_(cat, (this->width_ - bw) / 2, (this->height_ - bh) / 2, bw, bh, th.card, 16);
  lv_obj_set_style_border_width(b, 2, 0);
  lv_obj_set_style_border_color(b, lv_color_hex(th.text_dim), 0);
  lv_obj_add_flag(b, LV_OBJ_FLAG_CLICKABLE);

  std::string name = c.label;
  if (name.empty())
    name = v->friendly != nullptr && v->friendly->has_value ? v->friendly->value : c.entity_id;
  lv_obj_t *title = this->label_(b, FONT_LABEL, th.text);
  lv_obj_set_width(title, bw - 180);
  lv_label_set_long_mode(title, LV_LABEL_LONG_MODE_DOTS);
  lv_label_set_text(title, name.c_str());
  lv_obj_set_pos(title, 24, 24);
  this->popup_value_ = this->label_(b, FONT_VALUE, th.text);
  lv_obj_set_width(this->popup_value_, 150);
  lv_obj_set_style_text_align(this->popup_value_, LV_TEXT_ALIGN_RIGHT, 0);
  lv_obj_set_pos(this->popup_value_, bw - 24 - 150, 18);

  const std::string e = c.entity_id;
  auto send = [this, e](const std::string &action, std::vector<std::pair<std::string, std::string>> data) {
    return [this, e, action, data]() {
      ESP_LOGI(TAG, "popup %s: action %s", e.c_str(), action.c_str());
      this->call_ha_(action, e, data);
    };
  };
  int by = bh - 24 - 64, n = 0;
  const char *icons[3] = {nullptr, nullptr, nullptr};
  const char *texts[3] = {nullptr, nullptr, nullptr};
  std::function<void()> fns[3];
  switch (c.type) {
    case CardType::LIGHT:
      icons[0] = "lightbulb-off-outline";
      texts[0] = "Off";
      fns[0] = send("light.turn_off", {});
      icons[1] = "lightbulb-on";
      texts[1] = "On";
      fns[1] = send("light.turn_on", {});
      n = 2;
      break;
    case CardType::FAN:
      icons[0] = "fan-off";
      texts[0] = "Off";
      fns[0] = send("fan.turn_off", {});
      icons[1] = "fan";
      texts[1] = "On";
      fns[1] = send("fan.turn_on", {});
      n = 2;
      break;
    case CardType::COVER:
      icons[0] = "arrow-up";
      texts[0] = "Open";
      fns[0] = send("cover.open_cover", {});
      icons[1] = "stop";
      texts[1] = "Stop";
      fns[1] = send("cover.stop_cover", {});
      icons[2] = "arrow-down";
      texts[2] = "Close";
      fns[2] = send("cover.close_cover", {});
      n = 3;
      break;
    case CardType::MEDIA:
      icons[0] = "skip-previous";
      texts[0] = "Previous";
      fns[0] = send("media_player.media_previous_track", {});
      icons[1] = "play-pause";
      texts[1] = "Play/Pause";
      fns[1] = send("media_player.media_play_pause", {});
      icons[2] = "skip-next";
      texts[2] = "Next";
      fns[2] = send("media_player.media_next_track", {});
      n = 3;
      break;
    case CardType::CLIMATE: {
      icons[0] = "minus";
      fns[0] = [this, v]() { this->climate_step_(v, -1); };
      icons[2] = "plus";
      fns[2] = [this, v]() { this->climate_step_(v, 1); };
      // The modes: up to 8 buttons in two rows.
      std::vector<std::string> modes;
      if (v->modes != nullptr && v->modes->has_value)
        modes = quoted_words(v->modes->value);
      if (modes.size() > 8)
        modes.resize(8);
      int per_row = modes.size() > 4 ? (int) (modes.size() + 1) / 2 : (int) modes.size();
      int mw = per_row > 0 ? (bw - 48 - (per_row - 1) * 8) / per_row : 0;
      this->popup_modes_.clear();
      for (size_t i = 0; i < modes.size(); i++) {
        std::string mode = modes[i];
        lv_obj_t *mb = this->button_(b, this->popup_btns_, nullptr, nice(mode).c_str(), mw, 48,
                                     send("climate.set_hvac_mode", {{"hvac_mode", mode}}));
        lv_obj_set_pos(mb, 24 + (int) (i % per_row) * (mw + 8), 76 + (int) (i / per_row) * 56);
        this->popup_modes_.emplace_back(mb, mode);
      }
      if (modes.empty()) {
        lv_obj_t *l = this->label_(b, FONT_SMALL, th.text_dim);
        lv_label_set_text(l, "No mode list from Home Assistant yet");
        lv_obj_set_pos(l, 24, 90);
      }
      break;
    }
    default:
      break;
  }
  if (c.type == CardType::CLIMATE) {
    lv_obj_t *mb = this->button_(b, this->popup_btns_, icons[0], nullptr, 120, 64, fns[0]);
    lv_obj_set_pos(mb, 24, by);
    mb = this->button_(b, this->popup_btns_, icons[2], nullptr, 120, 64, fns[2]);
    lv_obj_set_pos(mb, bw - 24 - 120, by);
    this->popup_mid_ = this->label_(b, FONT_VALUE, th.text);
    lv_obj_set_width(this->popup_mid_, bw - 2 * 24 - 2 * 120);
    lv_obj_set_style_text_align(this->popup_mid_, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_pos(this->popup_mid_, 24 + 120, by + 14);
  } else {
    // The slider: brightness, speed, position or volume, in percent.
    this->popup_slider_ = lv_slider_create(b);
    lv_obj_t *sl = this->popup_slider_;
    lv_obj_remove_style_all(sl);
    lv_obj_set_pos(sl, 40, 100);
    lv_obj_set_size(sl, bw - 80, 44);
    lv_slider_set_range(sl, c.type == CardType::LIGHT ? 1 : 0, 100);
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
    lv_obj_add_event_cb(
        sl,
        [](lv_event_t *ev) {
          auto *self = static_cast<TsxCards *>(lv_event_get_user_data(ev));
          char buf[16];
          snprintf(buf, sizeof buf, "%d%%", (int) lv_slider_get_value(self->popup_slider_));
          self->set_text_(self->popup_value_, buf);
        },
        LV_EVENT_VALUE_CHANGED, this);
    lv_obj_add_event_cb(
        sl,
        [](lv_event_t *ev) {
          auto *self = static_cast<TsxCards *>(lv_event_get_user_data(ev));
          CardView *pv = self->popup_view_;
          if (pv == nullptr || self->multi_touch_())
            return;
          int val = lv_slider_get_value(self->popup_slider_);
          char num[16];
          std::string action, key;
          switch (pv->spec->type) {
            case CardType::LIGHT:
              action = "light.turn_on";
              key = "brightness_pct";
              snprintf(num, sizeof num, "%d", val);
              break;
            case CardType::FAN:
              action = "fan.set_percentage";
              key = "percentage";
              snprintf(num, sizeof num, "%d", val);
              break;
            case CardType::COVER:
              action = "cover.set_cover_position";
              key = "position";
              snprintf(num, sizeof num, "%d", val);
              break;
            case CardType::MEDIA:
              action = "media_player.volume_set";
              key = "volume_level";
              snprintf(num, sizeof num, "%.2f", val / 100.0);
              break;
            default:
              return;
          }
          ESP_LOGI(TAG, "popup %s: action %s %s=%s", pv->spec->entity_id.c_str(), action.c_str(), key.c_str(), num);
          self->call_ha_(action, pv->spec->entity_id, {{key, num}});
        },
        LV_EVENT_RELEASED, this);
    int bwid = n > 0 ? (bw - 48 - (n - 1) * 12) / n : 0;
    for (int i = 0; i < n; i++) {
      lv_obj_t *mb = this->button_(b, this->popup_btns_, icons[i], texts[i], bwid, 64, fns[i]);
      lv_obj_set_pos(mb, 24 + i * (bwid + 12), by);
    }
  }
  this->popup_refresh_();
}

void TsxCards::popup_refresh_() {
  CardView *v = this->popup_view_;
  if (v == nullptr || this->popup_catcher_ == nullptr)
    return;
  const Theme &th = this->layout_.theme;
  double x;
  int pct = -1;
  std::string value;
  const std::string st = v->main != nullptr && v->main->has_value ? v->main->value : "";
  switch (v->spec->type) {
    case CardType::LIGHT:
      if (st == "off")
        pct = 0;
      else if (number_of(v->brightness, x))
        pct = (int) lround(x * 100.0 / 255.0);
      break;
    case CardType::FAN:
      if (st == "off")
        pct = 0;
      else if (number_of(v->percentage, x))
        pct = (int) lround(x);
      break;
    case CardType::COVER:
      if (number_of(v->position, x))
        pct = (int) lround(x);
      else if (st == "closed")
        pct = 0;
      break;
    case CardType::MEDIA:
      if (number_of(v->volume, x))
        pct = (int) lround(x * 100);
      break;
    case CardType::CLIMATE: {
      char buf[32] = "--";
      if (number_of(v->target, x))
        snprintf(buf, sizeof buf, "%.1f\xC2\xB0", x);
      if (this->popup_mid_ != nullptr)
        this->set_text_(this->popup_mid_, buf);
      value = number_of(v->current, x) ? (snprintf(buf, sizeof buf, "%.1f\xC2\xB0", x), std::string(buf)) : "--";
      for (auto &m : this->popup_modes_)
        lv_obj_set_style_bg_color(m.first, lv_color_hex(m.second == st ? th.card_on : th.background), 0);
      break;
    }
    default:
      break;
  }
  if (this->popup_slider_ != nullptr) {
    if (pct >= 0) {
      if (!lv_obj_has_state(this->popup_slider_, LV_STATE_PRESSED))
        lv_slider_set_value(this->popup_slider_, pct, LV_ANIM_OFF);
      value = std::to_string(pct) + "%";
    } else {
      value = "--";
    }
    if (lv_obj_has_state(this->popup_slider_, LV_STATE_PRESSED))
      return;
  }
  this->set_text_(this->popup_value_, value.c_str());
}

void TsxCards::close_popup_() {
  if (this->popup_catcher_ == nullptr)
    return;
  lv_obj_delete(this->popup_catcher_);
  this->popup_catcher_ = this->popup_slider_ = this->popup_value_ = this->popup_mid_ = nullptr;
  this->popup_view_ = nullptr;
  this->popup_modes_.clear();
  this->popup_btns_.clear();
}

void TsxCards::popup_loop_() {
  if (this->popup_catcher_ != nullptr && lv_display_get_inactive_time(nullptr) >= POPUP_TIMEOUT_MS) {
    ESP_LOGI(TAG, "no touch for 10 s: popup closed");
    this->close_popup_();
  }
}

}  // namespace tsx_cards
}  // namespace esphome
