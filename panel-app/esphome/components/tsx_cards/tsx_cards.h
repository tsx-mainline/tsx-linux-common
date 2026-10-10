// tsx_cards: a card grid for Home Assistant, built at run time from a JSON
// layout file. See docs/panel-app.md.
//
// The component reads the layout when it starts and again when the file
// changes. It makes the LVGL objects of the pages and cards, subscribes to
// the Home Assistant states of the entities in the layout (api component,
// homeassistant_states) and sends the Home Assistant action of a card when
// it is tapped (homeassistant_services).
#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "esphome/core/component.h"
#include "esphome/core/defines.h"
#include "lvgl.h"
#include "layout.h"

#ifdef USE_FONT
#include "esphome/components/font/font.h"
#endif
#ifdef USE_TIME
#include "esphome/components/time/real_time_clock.h"
#endif

namespace esphome {
namespace tsx_cards {

enum FontSlot : uint8_t { FONT_SMALL = 0, FONT_LABEL, FONT_VALUE, FONT_CLOCK, FONT_ICON, FONT_COUNT };

class TsxCards;

// The last value that Home Assistant sent for one entity, or one attribute
// of an entity, and the cards that show it.
struct Slot {
  std::string entity_id;
  std::string attribute;
  std::string value;
  bool has_value{false};
  std::vector<struct CardView *> views;
};

struct CardView {
  TsxCards *owner{nullptr};
  const CardSpec *spec{nullptr};
  int page{0};
  lv_obj_t *obj{nullptr};
  lv_obj_t *icon{nullptr};
  lv_obj_t *name{nullptr};
  lv_obj_t *state{nullptr};
  lv_obj_t *value{nullptr};
  Slot *main{nullptr};       // the state, or the attribute of a sensor card
  Slot *brightness{nullptr};
  Slot *unit{nullptr};
  Slot *friendly{nullptr};   // friendly_name, when the card has no label
  Slot *temperature{nullptr};
  Slot *temp_unit{nullptr};
  Slot *humidity{nullptr};
  int lit{-1};               // the "on" look: -1 not set yet, 0 off, 1 on
  lv_point_t press_point{};  // where the finger touched the card
};

class TsxCards : public Component {
 public:
  void setup() override;
  void loop() override;
  void dump_config() override;
  float get_setup_priority() const override { return setup_priority::LATE; }

  void add_layout_file(const std::string &path) { this->layout_files_.push_back(path); }
  void set_page_bar_height(int h) { this->bar_h_ = h; }
  void set_font(uint8_t slot, const lv_font_t *font) {
    if (slot < FONT_COUNT)
      this->fonts_[slot] = font;
  }
#ifdef USE_FONT
  void set_font(uint8_t slot, font::Font *font) { this->set_font(slot, font->get_lv_font()); }
#endif
#ifdef USE_TIME
  void set_time(time::RealTimeClock *t) { this->time_ = t; }
#endif

  /// A key of the panel was pressed. `name` is the key name of the board
  /// (for example "home"). The layout maps it to an action (see "keys").
  void key_press(const std::string &name);
  void next_page();
  void prev_page();
  /// 0-based page index.
  void show_page(int page);
  /// Read the layout file now and rebuild the pages when it changed.
  void check_layout(bool force = false);

  // For the LVGL event callbacks.
  void on_card_tap(CardView *v);
  void on_gesture();
  void on_render(bool ready);

 protected:
  bool load_(bool force);
  void build_();
  void build_card_(CardView *v, lv_obj_t *tile, int cell_w, int cell_h);
  void build_bar_();
  void show_error_(const std::string &text);
  void update_card_(CardView *v);
  void update_clocks_(bool force);
  void update_bar_();
  void run_action_(const ActionSpec &a, const std::string &entity, const char *origin);
  void call_ha_(const std::string &action, const std::string &entity,
                const std::vector<std::pair<std::string, std::string>> &data);
  Slot *watch_(const std::string &entity, const char *attribute, CardView *v);
  void on_value_(Slot *s);
  void set_text_(lv_obj_t *label, const char *text);
  void set_fit_text_(lv_obj_t *label, const char *text, int lines, uint8_t font, uint8_t small);
  void set_icon_(lv_obj_t *label, const std::string &name, const char *fallback);
  lv_obj_t *label_(lv_obj_t *parent, uint8_t font, uint32_t color);
  const lv_font_t *font_(uint8_t slot) const;
  void watch_files_();
  std::string pick_file_() const;
  void mark_(const char *what);

  std::vector<std::string> layout_files_;
  int bar_h_{36};
  const lv_font_t *fonts_[FONT_COUNT]{};
#ifdef USE_TIME
  time::RealTimeClock *time_{nullptr};
#endif

  // The current layout and the text it came from.
  Layout layout_;
  bool have_layout_{false};
  std::string layout_path_;
  std::string layout_text_;
  std::string layout_error_;

  // LVGL objects.
  lv_obj_t *root_{nullptr};
  lv_obj_t *tiles_{nullptr};
  std::vector<lv_obj_t *> pages_;
  lv_obj_t *bar_{nullptr};
  lv_obj_t *bar_status_{nullptr};
  std::vector<lv_obj_t *> bar_buttons_;
  std::vector<std::unique_ptr<CardView>> views_;
  std::vector<CardView *> clocks_;
  int page_{0};
  int width_{0}, height_{0};

  // Home Assistant states. A subscription cannot be removed from the api
  // component, so a slot lives as long as the process. A reload reuses it.
  std::map<std::string, std::unique_ptr<Slot>> slots_;
  bool new_slots_{false};
  bool connected_{false};
  int main_slots_{0};
  int main_with_value_{0};
  bool first_value_logged_{false};
  bool all_values_logged_{false};

  // File watch.
  int inotify_fd_{-1};
  uint32_t reload_at_{0};
  bool reload_pending_{false};
  uint32_t last_poll_{0};
  long long last_sig_{0};

  // Clock cards.
  uint32_t last_clock_check_{0};

  // Timing (logs with the tag "perf").
  bool first_frame_done_{false};
  uint64_t render_t0_{0};
  uint64_t render_us_{0};
  uint32_t frames_{0};
  uint32_t last_perf_{0};
  uint64_t reload_t0_{0};
  uint64_t page_t0_{0};
};

}  // namespace tsx_cards
}  // namespace esphome
