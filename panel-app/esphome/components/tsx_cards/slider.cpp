// slider.cpp: the slider card. See docs/panel-app.md, "Slider cards".
//
// The domain of the entity sets the mode: light (brightness in percent),
// fan (speed in percent), cover (position in percent), media_player (volume
// in percent) and number or input_number (the value, with min, max and step
// from the entity). The slider sends its action when the finger lifts, or
// also while the finger moves ("send": "drag", at most one action in
// DRAG_INTERVAL_MS). The slider follows the state of Home Assistant while no
// finger is on it. The numbers are in slider_logic.h.
//
// Drawing cost (docs/panel-accel.md): no shadow, no outline, no opacity
// between 0 and 100 %. A drag redraws only the slider and the value label.
#include "tsx_cards.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

#include "esphome/core/hal.h"
#include "esphome/core/log.h"

namespace esphome {
namespace tsx_cards {

static const char *const TAG = "tsx_cards.slider";
static const char *const PERF = "perf";
// "send": "drag": at most one action in this time.
static const uint32_t DRAG_INTERVAL_MS = 300;
// After a send, keep the sent value for this time, or until Home Assistant
// reports it (an older state can come first).
static const uint32_t HOLD_MS = 3000;

static bool num(const Slot *s, double &out) { return s != nullptr && s->has_value && slider_number(s->value, out); }
static long features(const Slot *s) { return s != nullptr && s->has_value ? slider_features(s->value) : -1; }
static bool truthy(const Slot *s) { return s != nullptr && s->has_value && slider_true(s->value); }

static std::string nice(const std::string &s) {
  std::string out = s;
  for (auto &ch : out)
    if (ch == '_')
      ch = ' ';
  if (!out.empty() && out[0] >= 'a' && out[0] <= 'z')
    out[0] = out[0] - 'a' + 'A';
  return out;
}

// The range from the attributes of the entity and the layout. Also sets the
// range of the LVGL slider when the count changed.
static bool update_range(const CardSpec &c, SliderState *s) {
  double mn, mx, st;
  bool hmn = num(s->min_attr, mn), hmx = num(s->max_attr, mx), hst = num(s->step_attr, st);
  int old = s->range.count;
  if (!slider_range(c, hmn ? &mn : nullptr, hmx ? &mx : nullptr, hst ? &st : nullptr, s->range))
    return false;
  if (s->range.count != old)
    lv_slider_set_range(s->obj, 0, s->range.count);
  return true;
}

void TsxCards::slider_build_(CardView *v, int inner_w, int inner_h) {
  const CardSpec &c = *v->spec;
  const Theme &th = this->layout_.theme;
  v->slider = std::make_unique<SliderState>();
  SliderState *s = v->slider.get();
  lv_obj_t *sl = lv_slider_create(v->obj);
  s->obj = sl;
  lv_obj_remove_style_all(sl);
  lv_slider_set_range(sl, 0, s->range.count);
  lv_obj_set_style_bg_opa(sl, LV_OPA_COVER, LV_PART_MAIN);
  lv_obj_set_style_bg_color(sl, lv_color_hex(th.background), LV_PART_MAIN);
  lv_obj_set_style_bg_opa(sl, LV_OPA_COVER, LV_PART_INDICATOR);
  lv_obj_set_style_bg_color(sl, lv_color_hex(th.card_on), LV_PART_INDICATOR);
  lv_obj_set_style_bg_opa(sl, LV_OPA_COVER, LV_PART_KNOB);
  lv_obj_set_style_bg_color(sl, lv_color_hex(th.text), LV_PART_KNOB);
  lv_obj_set_style_radius(sl, LV_RADIUS_CIRCLE, LV_PART_KNOB);
  lv_obj_set_style_pad_all(sl, 4, LV_PART_KNOB);
  // No usable value: no indicator and no knob (opacity 0 draws nothing).
  lv_obj_set_style_bg_opa(sl, LV_OPA_TRANSP, (lv_style_selector_t) LV_PART_INDICATOR | LV_STATE_DISABLED);
  lv_obj_set_style_bg_opa(sl, LV_OPA_TRANSP, (lv_style_selector_t) LV_PART_KNOB | LV_STATE_DISABLED);
  lv_obj_add_state(sl, LV_STATE_DISABLED);
  // A drag on the slider never changes the page.
  lv_obj_remove_flag(sl, LV_OBJ_FLAG_GESTURE_BUBBLE);
  lv_obj_set_ext_click_area(sl, 8);

  int icon_h = lv_font_get_line_height(this->font_(FONT_ICON));
  int name_h = lv_font_get_line_height(this->font_(FONT_LABEL));
  if (!c.vertical) {
    // The icon and the value above, the name below, the track between them.
    int top = icon_h + 2, avail = inner_h - top - name_h - 2;
    int t = std::max(10, std::min(32, avail - 8));
    int y = top + (avail - t) / 2;
    int inset = t / 2 + 4;  // the knob stands out by half its size at the ends
    lv_obj_set_pos(sl, inset, y);
    lv_obj_set_size(sl, std::max(20, inner_w - 2 * inset), t);
    lv_obj_set_style_radius(sl, t / 2, LV_PART_MAIN);
    lv_obj_set_style_radius(sl, t / 2, LV_PART_INDICATOR);
  } else {
    // The track on the right side, from the top to the bottom. The icon,
    // the value and the name on the left.
    int t = std::max(16, std::min(36, inner_w / 4));
    int inset = t / 2 + 4;
    lv_obj_set_pos(sl, inner_w - t - 4, inset);
    lv_obj_set_size(sl, t, std::max(20, inner_h - 2 * inset));
    lv_obj_set_style_radius(sl, t / 2, LV_PART_MAIN);
    lv_obj_set_style_radius(sl, t / 2, LV_PART_INDICATOR);
    int text_w = inner_w - t - 12;
    if (v->value != nullptr) {
      lv_obj_set_width(v->value, text_w);
      lv_obj_set_style_text_align(v->value, LV_TEXT_ALIGN_LEFT, 0);
      lv_obj_align(v->value, LV_ALIGN_TOP_LEFT, 0, icon_h + 2);
    }
    if (v->name != nullptr)
      lv_obj_set_width(v->name, text_w);
  }
  static const lv_event_code_t CODES[] = {LV_EVENT_PRESSED, LV_EVENT_VALUE_CHANGED, LV_EVENT_RELEASED,
                                          LV_EVENT_PRESS_LOST};
  for (lv_event_code_t code : CODES)
    lv_obj_add_event_cb(
        sl,
        [](lv_event_t *e) {
          auto *cv = static_cast<CardView *>(lv_event_get_user_data(e));
          cv->owner->on_slider(cv, lv_event_get_code(e));
        },
        code, v);

  const std::string &e = c.entity_id;
  switch (c.slider) {
    case SliderMode::LIGHT:
      v->brightness = this->watch_(e, "brightness", v);
      s->modes = this->watch_(e, "supported_color_modes", v);
      break;
    case SliderMode::FAN:
      v->percentage = this->watch_(e, "percentage", v);
      s->step_attr = this->watch_(e, "percentage_step", v);
      break;
    case SliderMode::COVER:
      v->position = this->watch_(e, "current_position", v);
      s->features = this->watch_(e, "supported_features", v);
      break;
    case SliderMode::VOLUME:
      v->volume = this->watch_(e, "volume_level", v);
      s->muted = this->watch_(e, "is_volume_muted", v);
      s->features = this->watch_(e, "supported_features", v);
      break;
    case SliderMode::NUMBER:
      s->min_attr = this->watch_(e, "min", v);
      s->max_attr = this->watch_(e, "max", v);
      s->step_attr = this->watch_(e, "step", v);
      if (!c.unit_set)
        v->unit = this->watch_(e, "unit_of_measurement", v);
      break;
  }
  this->sliders_.push_back(v);
}

// The value with its unit: "40%", "21.5 °C".
std::string TsxCards::slider_text_(const CardView *v, double value) const {
  const CardSpec &c = *v->spec;
  std::string unit;
  if (c.unit_set)
    unit = c.unit;
  else if (slider_percent(c.slider))
    unit = "%";
  else if (v->unit != nullptr && v->unit->has_value)
    unit = v->unit->value;
  return slider_text(v->slider->range, value, unit);
}

void TsxCards::slider_update_(CardView *v, int &lit, std::string &value, const char *&icon) {
  const CardSpec &c = *v->spec;
  SliderState *s = v->slider.get();
  if (s == nullptr)
    return;
  bool has = v->main != nullptr && v->main->has_value;
  const std::string st = has ? v->main->value : std::string();
  bool usable = has && st != "unavailable" && st != "unknown";
  bool known = false;
  double cur = 0, x;
  std::string text;  // a text instead of the value
  switch (c.slider) {
    case SliderMode::LIGHT:
    case SliderMode::FAN: {
      bool light = c.slider == SliderMode::LIGHT;
      lit = st == "on";
      icon = light ? (lit ? "lightbulb-on" : "lightbulb-outline") : (lit ? "fan" : "fan-off");
      if (st == "off") {
        known = true;
        text = "Off";
      } else if (lit) {
        known = true;
        if (light && num(v->brightness, x)) {
          cur = x * 100.0 / 255.0;
        } else if (!light && num(v->percentage, x)) {
          cur = x;
        } else {
          cur = 100;  // no brightness or speed: on is all
          text = "On";
        }
      }
      break;
    }
    case SliderMode::COVER: {
      lit = st == "open" || st == "opening" || st == "closing";
      icon = lit ? "window-shutter-open" : "window-shutter";
      if (num(v->position, x)) {
        known = true;
        cur = x;
      } else if (st == "closed" || st == "open") {
        known = true;
        cur = st == "open" ? 100 : 0;
        text = nice(st);
      }
      long f = features(s->features);
      if (f >= 0 && (f & COVER_SET_POSITION) == 0) {
        usable = false;  // no position: a tap still toggles the cover
        text = nice(st);
      }
      break;
    }
    case SliderMode::VOLUME: {
      lit = st == "playing";
      bool muted = truthy(s->muted);
      icon = muted ? "volume-off" : "volume-high";
      if (st != "off" && num(v->volume, x)) {
        known = true;
        cur = x * 100.0;
      }
      long f = features(s->features);
      if (f >= 0 && (f & MEDIA_VOLUME_SET) == 0)
        usable = false;
      if (st == "off") {
        usable = false;
        text = "Off";
      } else if (muted) {
        text = "Muted";
      }
      break;
    }
    case SliderMode::NUMBER:
      icon = "gauge";
      if (usable && slider_number(st, x)) {
        known = true;
        cur = x;
      }
      break;
  }
  if (!update_range(c, s))
    usable = false;
  usable = usable && known;
  if (!has || st == "unknown")
    text = "--";
  else if (st == "unavailable")
    text = "Unavailable";
  s->ha_index = known ? slider_index(s->range, cur) : -1;

  if (usable != s->usable) {
    s->usable = usable;
    if (usable) {
      lv_obj_remove_state(s->obj, LV_STATE_DISABLED);
    } else {
      lv_obj_add_state(s->obj, LV_STATE_DISABLED);
      if (s->pressed)
        s->cancelled = true;
    }
  }
  int ind = lit ? 1 : 0;
  if (ind != s->indicator_lit) {
    // On a lit card the indicator has the text color, else the card_on color.
    s->indicator_lit = ind;
    const Theme &th = this->layout_.theme;
    lv_obj_set_style_bg_color(s->obj, lv_color_hex(lit ? th.text : th.card_on), LV_PART_INDICATOR);
  }

  if (s->pressed) {
    // The finger wins: show the value under the finger.
    value = this->slider_text_(v, slider_value(s->range, lv_slider_get_value(s->obj)));
    return;
  }
  if (s->hold) {
    if (known && slider_confirms(s->range, cur, s->target)) {
      s->hold = false;  // Home Assistant reports the sent value
    } else if ((int32_t) (millis() - s->hold_until) < 0 && usable) {
      value = this->slider_text_(v, s->target);
      return;
    } else {
      s->hold = false;
    }
  }
  int idx = known ? s->ha_index : 0;
  if (lv_slider_get_value(s->obj) != idx)
    lv_slider_set_value(s->obj, idx, LV_ANIM_OFF);
  value = text.empty() ? this->slider_text_(v, cur) : text;
}

void TsxCards::on_slider(CardView *v, lv_event_code_t code) {
  SliderState *s = v->slider.get();
  if (s == nullptr)
    return;
  uint32_t now = millis();
  const CardSpec &c = *v->spec;
  switch (code) {
    case LV_EVENT_PRESSED:
      s->pressed = true;
      s->cancelled = !s->usable;
      s->press_at = now;
      s->sent = -1;
      s->sends = 0;
      s->frames = 0;
      s->render_us = s->max_us = 0;
      this->slider_active_ = v;
      break;
    case LV_EVENT_VALUE_CHANGED:
      if (this->multi_touch_())
        s->cancelled = true;
      if (v->value != nullptr && s->pressed)
        this->set_fit_text_(v->value,
                            this->slider_text_(v, slider_value(s->range, lv_slider_get_value(s->obj))).c_str(), 1,
                            FONT_VALUE, FONT_LABEL);
      break;
    case LV_EVENT_RELEASED:
    case LV_EVENT_PRESS_LOST: {
      if (!s->pressed)
        break;
      s->pressed = false;
      if (this->slider_active_ == v)
        this->slider_active_ = nullptr;
      if (s->frames > 0)
        ESP_LOGI(PERF, "slider drag on page %d card %d: %u frames in %u ms, render %.1f ms on average, %.1f ms at most, %d actions",
                 v->page + 1, c.index, (unsigned) s->frames, (unsigned) (now - s->press_at),
                 s->render_us / 1000.0 / s->frames, s->max_us / 1000.0, s->sends);
      int idx = lv_slider_get_value(s->obj);
      if (code == LV_EVENT_PRESS_LOST || s->cancelled || this->multi_touch_()) {
        if (s->usable)
          ESP_LOGI(TAG, "slider on page %d card %d: %s, no action", v->page + 1, c.index,
                   code == LV_EVENT_PRESS_LOST ? "the touch was lost" : "more than one finger");
      } else if (idx != (s->sent >= 0 ? s->sent : s->ha_index)) {
        this->slider_send_(v, idx, "release");
      }
      this->update_card_(v);  // back to the state of Home Assistant, or the sent value
      break;
    }
    default:
      break;
  }
}

// "send": "drag": the value under the finger, at most once in
// DRAG_INTERVAL_MS. Also the end of the hold of a sent value.
void TsxCards::slider_loop_() {
  uint32_t now = millis();
  CardView *v = this->slider_active_;
  if (v != nullptr && v->slider != nullptr) {
    SliderState *s = v->slider.get();
    if (s->pressed && !s->cancelled && this->multi_touch_()) {
      s->cancelled = true;
      ESP_LOGI(TAG, "slider on page %d card %d: more than one finger, no action", v->page + 1, v->spec->index);
    }
    if (s->pressed && !s->cancelled && v->spec->send_drag && now - s->press_at >= DRAG_INTERVAL_MS &&
        now - s->last_send >= DRAG_INTERVAL_MS) {
      int idx = lv_slider_get_value(s->obj);
      if (idx != (s->sent >= 0 ? s->sent : s->ha_index))
        this->slider_send_(v, idx, "drag");
    }
  }
  for (CardView *sv : this->sliders_) {
    SliderState *s = sv->slider.get();
    if (s != nullptr && s->hold && !s->pressed && (int32_t) (now - s->hold_until) >= 0)
      this->update_card_(sv);  // the hold ends: show the state of Home Assistant
  }
}

void TsxCards::slider_send_(CardView *v, int index, const char *why) {
  const CardSpec &c = *v->spec;
  SliderState *s = v->slider.get();
  bool onoff = s->modes != nullptr && s->modes->has_value && slider_onoff_only(s->modes->value);
  SliderAction a = slider_action(c, s->range, index, onoff);
  ESP_LOGI(TAG, "slider on page %d card %d (%s), %s: action %s %s", v->page + 1, c.index, c.entity_id.c_str(), why,
           a.action.c_str(), a.data.empty() ? "" : (a.data[0].first + "=" + a.data[0].second).c_str());
  this->call_ha_(a.action, c.entity_id, a.data);
  uint32_t now = millis();
  s->sent = index;
  s->sends++;
  s->last_send = now;
  s->hold = true;
  s->target = a.target;
  s->hold_until = now + HOLD_MS;
}

// The default tap of a volume slider: mute on or off, when the player can.
void TsxCards::slider_mute_(CardView *v, const char *origin) {
  SliderState *s = v->slider.get();
  long f = s != nullptr ? features(s->features) : -1;
  if (s == nullptr || (f >= 0 && (f & MEDIA_VOLUME_MUTE) == 0)) {
    ESP_LOGI(TAG, "%s: the player has no mute, no action", origin);
    return;
  }
  const char *to = truthy(s->muted) ? "false" : "true";
  ESP_LOGI(TAG, "%s: action media_player.volume_mute is_volume_muted=%s", origin, to);
  this->call_ha_("media_player.volume_mute", v->spec->entity_id, {{"is_volume_muted", to}});
}

}  // namespace tsx_cards
}  // namespace esphome
