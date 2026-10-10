// tsx_cards: a card grid for Home Assistant, built at run time from a JSON
// layout file. See docs/panel-app.md.
//
// The component reads the layout when it starts and again when the file
// changes. It makes the LVGL objects of the pages and cards, subscribes to
// the Home Assistant states of the entities in the layout (api component,
// homeassistant_states) and sends the Home Assistant action of a card when
// it is tapped (homeassistant_services).
//
// It also runs the screen of the panel (screen.cpp: the backlight, dim and
// off after an idle time, wake on a touch or a key), the settings overlay
// (overlay.cpp) and the detail popups of the cards (popup.cpp).
#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "esphome/core/automation.h"
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
#ifdef USE_LIGHT
#include "esphome/components/light/light_state.h"
#endif
#ifdef USE_EVENT
#include "esphome/components/event/event.h"
#endif
#ifdef USE_TSX_CARDS_INPUT
#include "esphome/components/tsx_evdev/tsx_evdev.h"
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

// A button made by TsxCards::button_(): the click runs `fn`.
struct UiButton {
  TsxCards *owner{nullptr};
  std::function<void()> fn;
};
using ButtonPool = std::vector<std::unique_ptr<UiButton>>;

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
  Slot *position{nullptr};   // cover: current_position
  Slot *current{nullptr};    // climate: current_temperature
  Slot *target{nullptr};     // climate: temperature (the target)
  Slot *tstep{nullptr};      // climate: target_temp_step
  Slot *modes{nullptr};      // climate: hvac_modes
  Slot *title{nullptr};      // media_player: media_title
  Slot *artist{nullptr};     // media_player: media_artist
  Slot *volume{nullptr};     // media_player: volume_level
  Slot *percentage{nullptr}; // fan: percentage
  const CardSpec *cond{nullptr};  // conditional: the outer card (spec is the inner card)
  Slot *cond_slot{nullptr};       // conditional: the state of its entity
  lv_obj_t *btn[3]{};        // the buttons on the card (cover, climate, media_player)
  lv_obj_t *btn_icon[3]{};
  lv_obj_t *mid{nullptr};    // climate: the target between the - and + buttons
  int lit{-1};               // the "on" look: -1 not set yet, 0 off, 1 on
  int shown{-1};             // conditional: -1 not set yet, 0 hidden, 1 shown
  bool long_fired{false};    // a long press ran: no tap at the release
  lv_point_t press_point{};  // where the finger touched the card
};

// The state of the screen (screen.cpp).
enum ScreenState : uint8_t { SCREEN_ON = 0, SCREEN_DIM, SCREEN_OFF };

// A key of the panel and its Home Assistant event.
struct KeyState {
#ifdef USE_EVENT
  event::Event *event{nullptr};
#endif
  uint32_t down_at{0};
  bool down{false};
  bool swallowed{false};  // the press woke the screen: no action, no event
  bool long_sent{false};
};

class TsxCards : public Component {
 public:
  void setup() override;
  void loop() override;
  void dump_config() override;
  /// Gives the CPU its full frequency range back (cpu.cpp).
  void on_shutdown() override;
  float get_setup_priority() const override { return setup_priority::LATE; }

  void add_layout_file(const std::string &path) { this->layout_files_.push_back(path); }
  void set_page_bar_height(int h) { this->bar_h_ = h; }
  void set_setup_file(const std::string &path) { this->setup_file_ = path; }
  void set_entities_file(const std::string &path) { this->entities_file_ = path; }
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
  /// No wake and no Home Assistant event: use key_state() for that.
  void key_press(const std::string &name);
  /// A key of the panel went down (true) or up (false). A press on a dark
  /// or dim screen only wakes the screen. Else the press runs the action of
  /// the key at once. The Home Assistant event of the key (set_key_event)
  /// gets "press" at the release, or "long" after 0.8 s.
  void key_state(const std::string &name, bool pressed);
#ifdef USE_EVENT
  void set_key_event(const std::string &name, event::Event *e) { this->keys_[name].event = e; }
#endif
#ifdef USE_LIGHT
  void add_panel_light(light::LightState *l) { this->panel_lights_.push_back(l); }
#endif
#ifdef USE_TSX_CARDS_INPUT
  void set_input(tsx_evdev::TsxEvdev *in) { this->input_ = in; }
#endif

  // ---- the screen (screen.cpp) ----
  void set_backlight_dir(const std::string &dir) { this->backlight_dir_ = dir; }
  void set_screen_defaults(int dim_s, int blank_s, int dim_pct) {
    this->def_dim_timeout_ = dim_s;
    this->def_blank_timeout_ = blank_s;
    this->def_dim_level_ = dim_pct;
  }
  Trigger<bool> *get_screen_trigger() { return &this->screen_trigger_; }
  /// The main loop interval while the screen is off (0: no change). Use it
  /// only with input_id: tsx_evdev wakes the loop at once on an input event.
  void set_off_loop_interval(uint32_t ms) { this->off_loop_interval_ = ms; }
  /// True while the screen is lit (on or dim).
  bool screen_is_on() const { return this->screen_ != SCREEN_OFF; }
  ScreenState screen_state() const { return this->screen_; }
  void wake(const char *origin);
  void screen_off(const char *origin);
  /// The backlight level of the user, 1 to 100 (percent of the slider).
  float backlight() const { return this->level_pct_; }
  void set_backlight(float pct, bool save = true);
  float blank_timeout() const { return this->blank_timeout_; }
  float dim_timeout() const { return this->dim_timeout_; }
  float dim_level() const { return this->dim_pct_; }
  /// Set the time and keep it in panel.conf (tsx-config set and apply).
  void set_blank_timeout(float s);
  void set_dim_timeout(float s);
  void set_dim_level(float pct);

  // ---- the settings overlay (overlay.cpp) ----
  void set_overlay_timeout(uint32_t ms) { this->overlay_timeout_ = ms; }
  void open_overlay(const char *origin);
  void close_overlay();
  void toggle_overlay(const char *origin);
  bool overlay_open() const { return this->ov_catcher_ != nullptr; }
  /// The lights of the panel (panel_lights): all off when one is on, else all on (a local action).
  void toggle_panel_lights(const char *origin);
  bool panel_lights_on() const;
  void next_page();
  void prev_page();
  /// 0-based page index.
  void show_page(int page);
  /// Read the layout file now and rebuild the pages when it changed.
  void check_layout(bool force = false);

  // For the LVGL event callbacks.
  void on_card_tap(CardView *v);
  void on_card_hold(CardView *v);
  void on_button(UiButton *b);
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
  void check_setup_banner_();
  void open_setup_();
  void write_entities_();
  std::string pick_file_() const;
  void mark_(const char *what);
  bool multi_touch_() const;
  bool finger_moved_(CardView *v) const;
  lv_obj_t *button_(lv_obj_t *parent, ButtonPool &pool, const char *icon, const char *text, int w, int h,
                    std::function<void()> fn, lv_obj_t **label = nullptr);
  lv_obj_t *box_(lv_obj_t *parent, int x, int y, int w, int h, uint32_t color, int radius);
  void card_buttons_(CardView *v, int inner_w, int inner_h);
  void update_condition_(CardView *v);
  void climate_step_(CardView *v, int dir);
  // screen.cpp
  void screen_setup_();
  void screen_loop_();
  void screen_set_(ScreenState s, const char *origin);
  void write_backlight_(int raw);
  void save_level_();
  int pct_to_raw_(float pct) const;
  void read_screen_files_(bool force);
  void on_input_(int kind);
  // cpu.cpp: the CPU frequency boost (see docs/panel-app.md, "CPU speed").
  void cpu_setup_();
  void cpu_loop_();
  void cpu_boost_();
  void cpu_screen_(bool on);
  enum CpuMode : uint8_t { CPU_FULL_RANGE = 0, CPU_BOOST, CPU_LOWEST };
  void cpu_apply_(CpuMode m);
  void config_set_(const char *key, const std::string &value);
  void reap_children_();
  // overlay.cpp
  void overlay_loop_();
  void overlay_refresh_();
  void overlay_confirm_reboot_();
  std::string version_text_();
  // popup.cpp
  void open_popup_(CardView *v);
  void close_popup_();
  void popup_refresh_();
  void popup_loop_();

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

  // The setup banner: the address and the pairing code of the setup page
  // while its network window is open (see docs/panel-app.md).
  std::string setup_file_{"/run/tsx-setup/screen.json"};
  lv_obj_t *banner_{nullptr};
  lv_obj_t *banner_label_{nullptr};
  std::string banner_text_;
  uint32_t last_setup_poll_{0};
  int setup_pid_{-1};

  // The entities that the app knows, for the layout editor.
  std::string entities_file_{"/run/tsx/panel-app/entities.json"};
  bool entities_dirty_{false};
  uint32_t last_entities_write_{0};

  // Clock cards.
  uint32_t last_clock_check_{0};

  // Button actions to run in the next loop() (see on_button).
  std::vector<std::function<void()>> pending_;
  // Buttons of the cards, the popup and the overlay.
  ButtonPool card_btns_, popup_btns_, ov_btns_;

  // Keys, the lights of the panel and the touch input.
  std::map<std::string, KeyState> keys_;
#ifdef USE_LIGHT
  std::vector<light::LightState *> panel_lights_;
#endif
#ifdef USE_TSX_CARDS_INPUT
  tsx_evdev::TsxEvdev *input_{nullptr};
#endif

  // The screen.
  std::string backlight_dir_{"auto"};
  int bl_max_{0}, bl_min_{1};
  float level_pct_{80};
  bool level_saved_{false};
  int def_dim_timeout_{60}, def_blank_timeout_{300}, def_dim_level_{20};
  int dim_timeout_{60}, blank_timeout_{300}, dim_pct_{20};
  uint32_t local_set_at_{0};  // a value set here wins over the files for a while
  bool local_set_{false};
  ScreenState screen_{SCREEN_ON};
  lv_obj_t *shield_{nullptr};
  uint32_t last_idle_{0};
  uint32_t last_screen_files_{0};
  uint32_t off_loop_interval_{0}, on_loop_interval_{0};
  uint64_t wake_event_us_{0};  // the input event of a wake (0: not from an input)

  // The CPU frequency boost (cpu.cpp).
  struct CpuPolicy {
    std::string dir;          // /sys/devices/system/cpu/cpufreq/policyN
    uint32_t min{0}, max{0};  // kHz, cpuinfo_min_freq and cpuinfo_max_freq
    uint32_t set_min{0}, set_max{0};  // the limits written last
  };
  std::vector<CpuPolicy> cpu_policies_;
  uint32_t cpu_boost_ms_{0};      // 0: no boost
  uint32_t cpu_boost_until_{0};
  CpuMode cpu_mode_{CPU_FULL_RANGE};
  bool cpu_off_lowest_{false};    // screen off: the lowest frequency only
  uint64_t last_render_start_{0};
  std::string pref_dir_;
  std::string run_dir_{"/run/tsx"};
  Trigger<bool> screen_trigger_;
  std::vector<int> children_;
  std::map<std::string, std::string> config_pending_;
  uint32_t config_due_{0};

  // The settings overlay.
  uint32_t overlay_timeout_{10000};
  lv_obj_t *ov_catcher_{nullptr};
  lv_obj_t *ov_box_{nullptr};
  lv_obj_t *ov_slider_{nullptr};
  lv_obj_t *ov_level_{nullptr};
  lv_obj_t *ov_dim_{nullptr};
  lv_obj_t *ov_blank_{nullptr};
  lv_obj_t *ov_info_{nullptr};
  lv_obj_t *ov_bars_{nullptr};
  lv_obj_t *ov_confirm_{nullptr};
  uint32_t ov_last_refresh_{0};
  std::string version_;

  // The detail popup of a card.
  CardView *popup_view_{nullptr};
  lv_obj_t *popup_catcher_{nullptr};
  lv_obj_t *popup_slider_{nullptr};
  lv_obj_t *popup_value_{nullptr};
  lv_obj_t *popup_mid_{nullptr};
  std::vector<std::pair<lv_obj_t *, std::string>> popup_modes_;

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
