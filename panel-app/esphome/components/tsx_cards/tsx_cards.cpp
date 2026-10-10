// tsx_cards.cpp: the run-time card grid. See tsx_cards.h and docs/panel-app.md.
#include "tsx_cards.h"

#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <functional>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <unistd.h>

#include "esphome/core/hal.h"
#include "esphome/core/log.h"
#include "icons.h"

#ifdef USE_API
#include "esphome/components/api/api_server.h"
#endif

namespace esphome {
namespace tsx_cards {

static const char *const TAG = "tsx_cards";
static const char *const PERF = "perf";

static const int CARD_PAD = 12;
static const int CARD_RADIUS = 14;
static const int ICON_W = 44;
// A finger that moves more than this from the press point makes no tap.
static const int TAP_SLOP = 24;

// ---- time and small helpers ------------------------------------------------

static uint64_t boot_us() {
  timespec ts;
  clock_gettime(CLOCK_BOOTTIME, &ts);
  return uint64_t(ts.tv_sec) * 1000000ULL + ts.tv_nsec / 1000;
}

static uint64_t mono_us() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000ULL + ts.tv_nsec / 1000;
}

// The start time of this process (field 22 of /proc/self/stat), in
// microseconds since boot. So the times in the log count from the exec, not
// from the first line of main().
static uint64_t process_start_us() {
  static uint64_t start = 0;
  if (start != 0)
    return start;
  start = boot_us();
  FILE *f = fopen("/proc/self/stat", "r");
  if (f == nullptr)
    return start;
  char buf[1024];
  size_t n = fread(buf, 1, sizeof buf - 1, f);
  fclose(f);
  buf[n] = '\0';
  const char *p = strrchr(buf, ')');  // the command name can hold spaces
  if (p == nullptr)
    return start;
  // Fields after the name start at field 3; the start time is field 22.
  int field = 2;
  for (; *p && field < 22; p++)
    if (*p == ' ')
      field++;
  unsigned long long ticks = strtoull(p, nullptr, 10);
  long hz = sysconf(_SC_CLK_TCK);
  if (ticks > 0 && hz > 0)
    start = ticks * 1000000ULL / hz;
  return start;
}

static bool parse_number(const std::string &s, double &out) {
  if (s.empty())
    return false;
  char *end = nullptr;
  out = strtod(s.c_str(), &end);
  return end != nullptr && *end == '\0' && std::isfinite(out);
}

static void utf8(uint32_t cp, char *out) {
  if (cp < 0x80) {
    out[0] = cp;
    out[1] = 0;
  } else if (cp < 0x800) {
    out[0] = 0xC0 | (cp >> 6);
    out[1] = 0x80 | (cp & 0x3F);
    out[2] = 0;
  } else if (cp < 0x10000) {
    out[0] = 0xE0 | (cp >> 12);
    out[1] = 0x80 | ((cp >> 6) & 0x3F);
    out[2] = 0x80 | (cp & 0x3F);
    out[3] = 0;
  } else {
    out[0] = 0xF0 | (cp >> 18);
    out[1] = 0x80 | ((cp >> 12) & 0x3F);
    out[2] = 0x80 | ((cp >> 6) & 0x3F);
    out[3] = 0x80 | (cp & 0x3F);
    out[4] = 0;
  }
}

static uint32_t icon_code(const std::string &name) {
  int lo = 0, hi = int(sizeof ICONS / sizeof ICONS[0]) - 1;
  while (lo <= hi) {
    int mid = (lo + hi) / 2;
    int c = strcmp(name.c_str(), ICONS[mid].name);
    if (c == 0)
      return ICONS[mid].code;
    if (c < 0)
      hi = mid - 1;
    else
      lo = mid + 1;
  }
  return 0;
}

struct Condition {
  const char *state;
  const char *text;
  const char *icon;
};
// The weather conditions of Home Assistant.
static const Condition CONDITIONS[] = {
    {"clear-night", "Clear night", "weather-night"},
    {"cloudy", "Cloudy", "weather-cloudy"},
    {"exceptional", "Exceptional", "weather-cloudy-alert"},
    {"fog", "Fog", "weather-fog"},
    {"hail", "Hail", "weather-hail"},
    {"lightning", "Lightning", "weather-lightning"},
    {"lightning-rainy", "Lightning, rain", "weather-lightning-rainy"},
    {"partlycloudy", "Partly cloudy", "weather-partly-cloudy"},
    {"pouring", "Pouring", "weather-pouring"},
    {"rainy", "Rainy", "weather-rainy"},
    {"snowy", "Snowy", "weather-snowy"},
    {"snowy-rainy", "Snow, rain", "weather-snowy-rainy"},
    {"sunny", "Sunny", "weather-sunny"},
    {"windy", "Windy", "weather-windy"},
    {"windy-variant", "Windy", "weather-windy-variant"},
};

static const Condition *find_condition(const std::string &s) {
  for (const auto &c : CONDITIONS)
    if (s == c.state)
      return &c;
  return nullptr;
}

// ---- setup and loop ----------------------------------------------------------

void TsxCards::setup() {
  process_start_us();
  const char *env = getenv("TSX_PANEL_LAYOUT");
  if (env != nullptr && env[0] != '\0')
    this->layout_files_.insert(this->layout_files_.begin(), env);

  lv_display_t *disp = lv_display_get_default();
  this->width_ = lv_display_get_horizontal_resolution(disp);
  this->height_ = lv_display_get_vertical_resolution(disp);
  lv_display_add_event_cb(
      disp, [](lv_event_t *e) { static_cast<TsxCards *>(lv_event_get_user_data(e))->on_render(true); },
      LV_EVENT_RENDER_READY, this);
  lv_display_add_event_cb(
      disp, [](lv_event_t *e) { static_cast<TsxCards *>(lv_event_get_user_data(e))->on_render(false); },
      LV_EVENT_RENDER_START, this);

  this->last_perf_ = millis();
  this->root_ = lv_obj_create(lv_screen_active());
  lv_obj_remove_style_all(this->root_);
  lv_obj_set_size(this->root_, this->width_, this->height_);
  lv_obj_set_style_bg_opa(this->root_, LV_OPA_COVER, 0);
  lv_obj_set_style_bg_color(this->root_, lv_color_hex(this->layout_.theme.background), 0);
  lv_obj_remove_flag(this->root_, LV_OBJ_FLAG_SCROLLABLE);
  // The cards and pages pass a gesture on to their parent (LVGL default).
  // LVGL gives the gesture to the first object that does not pass it on.
  lv_obj_remove_flag(this->root_, LV_OBJ_FLAG_GESTURE_BUBBLE);
  lv_obj_add_event_cb(
      this->root_, [](lv_event_t *e) { static_cast<TsxCards *>(lv_event_get_user_data(e))->on_gesture(); },
      LV_EVENT_GESTURE, this);

  this->watch_files_();
  this->check_layout(true);
  if (!this->have_layout_ && this->layout_error_.empty())
    this->show_error_("No layout file. Tried: " + [this] {
      std::string s;
      for (const auto &p : this->layout_files_)
        s += (s.empty() ? "" : ", ") + p;
      return s;
    }());
}

void TsxCards::dump_config() {
  ESP_LOGCONFIG(TAG, "TSX cards:");
  for (const auto &p : this->layout_files_)
    ESP_LOGCONFIG(TAG, "  Layout file: %s", p.c_str());
  ESP_LOGCONFIG(TAG, "  Layout in use: %s", this->layout_path_.empty() ? "none" : this->layout_path_.c_str());
  ESP_LOGCONFIG(TAG, "  File watch: %s", this->inotify_fd_ >= 0 ? "inotify and a 2 s check" : "a 2 s check");
  ESP_LOGCONFIG(TAG, "  Page bar height: %d", this->bar_h_);
}

void TsxCards::loop() {
  uint32_t now = millis();

#ifdef USE_API
  bool c = api::global_api_server != nullptr && api::global_api_server->is_connected();
  if (c != this->connected_) {
    this->connected_ = c;
    if (c)
      this->mark_("Home Assistant connected");
    else
      ESP_LOGI(TAG, "Home Assistant disconnected");
    this->update_bar_();
  }
#ifdef USE_API_HOMEASSISTANT_STATES
  // A reload added entities while Home Assistant was connected. Home
  // Assistant reads the subscription list only when it connects. It does not
  // ignore a subscription that it has already, so a second list would make
  // it send each state twice. So close the connection: Home Assistant
  // connects again at once and reads the full list.
  if (this->new_slots_ && api::global_api_server != nullptr &&
      api::global_api_server->is_connected_with_state_subscription()) {
    this->new_slots_ = false;
    for (auto &client : api::global_api_server->active_clients())
      client->on_disconnect_response();  // the server closes the socket in its loop
    ESP_LOGI(TAG, "new entities in the layout: closed the API connection, Home Assistant subscribes again");
  }
#endif
#endif

  if (this->inotify_fd_ >= 0) {
    alignas(struct inotify_event) char buf[2048];
    bool any = false;
    while (read(this->inotify_fd_, buf, sizeof buf) > 0)
      any = true;
    if (any && !this->reload_pending_) {
      this->reload_pending_ = true;
      this->reload_at_ = now + 250;  // let the writer finish (editors write in steps)
    }
  }
  if (now - this->last_poll_ >= 2000) {
    this->last_poll_ = now;
    std::string path = this->pick_file_();
    long long sig = 0;
    struct stat st;
    if (!path.empty() && stat(path.c_str(), &st) == 0)
      sig = (long long) st.st_mtim.tv_sec * 1000003LL + st.st_mtim.tv_nsec + st.st_size * 31LL + st.st_ino * 7LL +
            (long long) std::hash<std::string>()(path);
    if (sig != this->last_sig_) {
      this->last_sig_ = sig;
      if (!this->reload_pending_) {
        this->reload_pending_ = true;
        this->reload_at_ = now;
      }
    }
  }
  if (this->reload_pending_ && (int32_t) (now - this->reload_at_) >= 0) {
    this->reload_pending_ = false;
    this->check_layout(false);
  }

  if (now - this->last_perf_ >= 60000) {
    // The frames that LVGL drew in the last minute. A screen with no change
    // draws none.
    ESP_LOGI(PERF, "last 60 s: %u frames, render %.1f ms on average", (unsigned) this->frames_,
             this->frames_ ? this->render_us_ / 1000.0 / this->frames_ : 0.0);
    this->last_perf_ = now;
    this->frames_ = 0;
    this->render_us_ = 0;
  }
  if (now - this->last_clock_check_ >= 1000) {
    this->last_clock_check_ = now;
    this->update_clocks_(false);
  }
}

void TsxCards::mark_(const char *what) {
  ESP_LOGI(PERF, "%s: %.3f s after process start", what, (boot_us() - process_start_us()) / 1e6);
}

void TsxCards::on_render(bool ready) {
  if (!ready) {
    this->render_t0_ = mono_us();
    return;
  }
  uint64_t now = mono_us();
  this->frames_++;
  this->render_us_ += now - this->render_t0_;
  if (this->page_t0_ != 0) {
    ESP_LOGI(PERF, "page change: %.1f ms to the new frame (render %.1f ms)", (now - this->page_t0_) / 1000.0,
             (now - this->render_t0_) / 1000.0);
    this->page_t0_ = 0;
  }
  if (!this->first_frame_done_) {
    this->first_frame_done_ = true;
    this->mark_("first frame");
  }
  if (this->reload_t0_ != 0) {
    ESP_LOGI(PERF, "layout reload: %.1f ms from the file read to the new frame", (mono_us() - this->reload_t0_) / 1000.0);
    this->reload_t0_ = 0;
  }
}

// ---- layout file ---------------------------------------------------------------

void TsxCards::watch_files_() {
  this->inotify_fd_ = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
  if (this->inotify_fd_ < 0) {
    ESP_LOGW(TAG, "inotify: %s; the file check runs every 2 s only", strerror(errno));
    return;
  }
  std::vector<std::string> dirs;
  for (const auto &p : this->layout_files_) {
    size_t slash = p.rfind('/');
    std::string dir = slash == std::string::npos ? "." : (slash == 0 ? "/" : p.substr(0, slash));
    bool seen = false;
    for (const auto &d : dirs)
      seen |= d == dir;
    if (seen)
      continue;
    dirs.push_back(dir);
    if (inotify_add_watch(this->inotify_fd_, dir.c_str(),
                          IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_CREATE | IN_DELETE | IN_ATTRIB) < 0)
      ESP_LOGD(TAG, "no watch on %s: %s (the 2 s check covers it)", dir.c_str(), strerror(errno));
  }
}

std::string TsxCards::pick_file_() const {
  for (const auto &p : this->layout_files_)
    if (access(p.c_str(), R_OK) == 0)
      return p;
  return "";
}

void TsxCards::check_layout(bool force) {
  uint64_t t0 = mono_us();
  std::string path = this->pick_file_();
  if (path.empty()) {
    if (this->have_layout_)
      ESP_LOGW(TAG, "no layout file is left; the pages stay as they are");
    return;
  }
  std::string text;
  FILE *f = fopen(path.c_str(), "r");
  if (f == nullptr) {
    ESP_LOGW(TAG, "%s: %s", path.c_str(), strerror(errno));
    return;
  }
  char buf[4096];
  size_t n;
  while ((n = fread(buf, 1, sizeof buf, f)) > 0 && text.size() < 1024 * 1024)
    text.append(buf, n);
  fclose(f);
  if (!force && path == this->layout_path_ && text == this->layout_text_)
    return;
  this->layout_path_ = path;
  this->layout_text_ = text;

  Layout next;
  std::string error;
  std::vector<std::string> warnings;
  bool ok = parse_layout(text, next, error, warnings);
  for (const auto &w : warnings)
    ESP_LOGW(TAG, "%s: %s", path.c_str(), w.c_str());
  if (!ok) {
    ESP_LOGE(TAG, "%s: %s", path.c_str(), error.c_str());
    this->layout_error_ = error;
    if (!this->have_layout_)
      this->show_error_(path + ": " + error);
    else
      this->update_bar_();  // keep the old pages, show the error in the bar
    return;
  }
  double parse_ms = (mono_us() - t0) / 1000.0;
  this->layout_error_.clear();

  // Unhook the old cards before the layout that they point to goes away.
  for (auto &it : this->slots_)
    it.second->views.clear();
  this->views_.clear();
  this->clocks_.clear();
  this->layout_ = std::move(next);
  this->have_layout_ = true;
  this->reload_t0_ = t0;
  this->build_();
  int cards = 0;
  for (const auto &p : this->layout_.pages)
    cards += p.cards.size();
  int entities = 0;
  for (auto &it : this->slots_)
    entities += !it.second->views.empty() && it.second->attribute.empty();
  ESP_LOGI(TAG, "layout %s: %d pages, %d cards, %d entities", path.c_str(), (int) this->layout_.pages.size(), cards,
           entities);
  ESP_LOGI(PERF, "layout read and parse %.1f ms, build %.1f ms", parse_ms, (mono_us() - t0) / 1000.0 - parse_ms);
}

// ---- building the pages ------------------------------------------------------------

lv_obj_t *TsxCards::label_(lv_obj_t *parent, uint8_t font, uint32_t color) {
  lv_obj_t *l = lv_label_create(parent);
  lv_obj_set_style_text_font(l, this->font_(font), 0);
  lv_obj_set_style_text_color(l, lv_color_hex(color), 0);
  lv_label_set_text(l, "");
  return l;
}

const lv_font_t *TsxCards::font_(uint8_t slot) const {
  if (slot < FONT_COUNT && this->fonts_[slot] != nullptr)
    return this->fonts_[slot];
  return LV_FONT_DEFAULT;
}

void TsxCards::show_error_(const std::string &text) {
  for (auto &it : this->slots_)
    it.second->views.clear();
  this->views_.clear();
  this->clocks_.clear();
  this->bar_buttons_.clear();
  lv_obj_clean(this->root_);
  this->tiles_ = this->bar_ = this->bar_status_ = nullptr;
  this->pages_.clear();
  lv_obj_t *l = this->label_(this->root_, FONT_LABEL, this->layout_.theme.text);
  lv_obj_set_width(l, this->width_ - 80);
  lv_label_set_long_mode(l, LV_LABEL_LONG_MODE_WRAP);
  lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_text(l, ("Panel layout\n\n" + text).c_str());
  lv_obj_center(l);
}

void TsxCards::build_() {
  for (auto &it : this->slots_)
    it.second->views.clear();
  this->views_.clear();
  this->clocks_.clear();
  this->bar_buttons_.clear();
  lv_obj_clean(this->root_);
  this->bar_ = this->bar_status_ = nullptr;
  const Theme &th = this->layout_.theme;
  lv_obj_set_style_bg_color(this->root_, lv_color_hex(th.background), 0);

  int area_h = this->height_ - this->bar_h_;
  // One container for each page. Only the shown page is visible. A swipe
  // is an LVGL gesture: it changes the page at once, with no animation (a
  // scrolled page view costs a full redraw for each frame on this kind of
  // CPU, and it lost swipes in the tests).
  this->tiles_ = lv_obj_create(this->root_);
  lv_obj_remove_style_all(this->tiles_);
  lv_obj_set_pos(this->tiles_, 0, 0);
  lv_obj_set_size(this->tiles_, this->width_, area_h);
  lv_obj_remove_flag(this->tiles_, LV_OBJ_FLAG_SCROLLABLE);

  int npages = this->layout_.pages.size();
  int gap = this->layout_.gap;
  this->pages_.clear();
  for (int i = 0; i < npages; i++) {
    const PageSpec &page = this->layout_.pages[i];
    lv_obj_t *tile = lv_obj_create(this->tiles_);
    lv_obj_remove_style_all(tile);
    lv_obj_set_size(tile, this->width_, area_h);
    lv_obj_remove_flag(tile, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(tile, LV_OBJ_FLAG_HIDDEN);
    this->pages_.push_back(tile);
    int cell_w = (this->width_ - gap * (page.columns + 1)) / page.columns;
    int cell_h = (area_h - gap * (page.rows + 1)) / page.rows;
    for (const CardSpec &spec : page.cards) {
      auto v = std::make_unique<CardView>();
      v->owner = this;
      v->spec = &spec;
      v->page = i;
      this->build_card_(v.get(), tile, cell_w, cell_h);
      this->views_.push_back(std::move(v));
    }
  }
  this->build_bar_();
  if (this->page_ >= npages)
    this->page_ = 0;
  lv_obj_remove_flag(this->pages_[this->page_], LV_OBJ_FLAG_HIDDEN);
  for (auto &v : this->views_)
    this->update_card_(v.get());
  this->update_clocks_(true);
  this->update_bar_();
#ifdef USE_API_HOMEASSISTANT_STATES
  // Before Home Assistant subscribes, the new entities are part of the list
  // that it reads when it connects.
  if (api::global_api_server == nullptr || !api::global_api_server->is_connected_with_state_subscription())
    this->new_slots_ = false;
#endif
}

void TsxCards::build_card_(CardView *v, lv_obj_t *tile, int cell_w, int cell_h) {
  const CardSpec &c = *v->spec;
  const Theme &th = this->layout_.theme;
  int gap = this->layout_.gap;
  int w = c.w * cell_w + (c.w - 1) * gap;
  int h = c.h * cell_h + (c.h - 1) * gap;
  lv_obj_t *o = lv_obj_create(tile);
  v->obj = o;
  lv_obj_remove_style_all(o);
  lv_obj_set_pos(o, gap + c.x * (cell_w + gap), gap + c.y * (cell_h + gap));
  lv_obj_set_size(o, w, h);
  lv_obj_set_style_radius(o, CARD_RADIUS, 0);
  lv_obj_set_style_bg_opa(o, LV_OPA_COVER, 0);
  lv_obj_set_style_bg_color(o, lv_color_hex(th.card), 0);
  lv_obj_set_style_pad_all(o, CARD_PAD, 0);
  lv_obj_remove_flag(o, LV_OBJ_FLAG_SCROLLABLE);
  // A drag on a card scrolls the page view (swipe to the next page) and
  // cancels the tap.
  bool tappable = c.tap.kind == ActionSpec::CALL || c.tap.kind == ActionSpec::PAGE ||
                  (c.tap.kind == ActionSpec::DEFAULT && c.type != CardType::SENSOR && c.type != CardType::WEATHER &&
                   c.type != CardType::CLOCK);
  if (tappable) {
    lv_obj_add_flag(o, LV_OBJ_FLAG_CLICKABLE);
    // A finger that slides off the card cancels the tap (LVGL keeps the
    // press by default and clicks on the release).
    lv_obj_remove_flag(o, LV_OBJ_FLAG_PRESS_LOCK);
    lv_obj_set_style_bg_opa(o, LV_OPA_60, LV_STATE_PRESSED);
    lv_obj_add_event_cb(
        o,
        [](lv_event_t *e) {
          auto *cv = static_cast<CardView *>(lv_event_get_user_data(e));
          lv_indev_t *indev = lv_indev_active();
          if (indev != nullptr)
            lv_indev_get_point(indev, &cv->press_point);
        },
        LV_EVENT_PRESSED, v);
    lv_obj_add_event_cb(
        o,
        [](lv_event_t *e) {
          auto *cv = static_cast<CardView *>(lv_event_get_user_data(e));
          // A drag that LVGL did not turn into a page swipe (for example
          // toward a side with no page) is not a tap.
          lv_indev_t *indev = lv_indev_active();
          lv_point_t p = cv->press_point;
          if (indev != nullptr)
            lv_indev_get_point(indev, &p);
          int dx = p.x - cv->press_point.x, dy = p.y - cv->press_point.y;
          if (dx * dx + dy * dy > TAP_SLOP * TAP_SLOP) {
            ESP_LOGI(TAG, "tap on page %d card %d ignored: the finger moved %d,%d px", cv->page + 1, cv->spec->index,
                     dx, dy);
            return;
          }
          cv->owner->on_card_tap(cv);
        },
        LV_EVENT_CLICKED, v);
  } else {
    lv_obj_remove_flag(o, LV_OBJ_FLAG_CLICKABLE);
  }

  int inner_w = w - 2 * CARD_PAD;
  if (c.type == CardType::CLOCK) {
    bool date = !c.date_format.empty();
    v->value = this->label_(o, FONT_CLOCK, th.text);
    lv_obj_align(v->value, LV_ALIGN_CENTER, 0, date ? -14 : 0);
    if (date) {
      v->state = this->label_(o, FONT_LABEL, th.text_dim);
      lv_obj_align(v->state, LV_ALIGN_CENTER, 0, lv_font_get_line_height(this->font_(FONT_CLOCK)) / 2 + 2);
    }
    this->clocks_.push_back(v);
    return;
  }

  v->icon = this->label_(o, FONT_ICON, th.text_dim);
  lv_obj_align(v->icon, LV_ALIGN_TOP_LEFT, 0, 0);
  v->name = this->label_(o, FONT_LABEL, th.text);
  lv_obj_set_width(v->name, inner_w);
  lv_label_set_long_mode(v->name, LV_LABEL_LONG_MODE_DOTS);
  lv_obj_align(v->name, LV_ALIGN_BOTTOM_LEFT, 0, 0);

  switch (c.type) {
    case CardType::SENSOR:
    case CardType::WEATHER:
      v->value = this->label_(o, FONT_VALUE, th.text);
      lv_obj_set_width(v->value, inner_w - ICON_W);
      lv_label_set_long_mode(v->value, LV_LABEL_LONG_MODE_DOTS);
      lv_obj_set_style_text_align(v->value, LV_TEXT_ALIGN_RIGHT, 0);
      lv_obj_align(v->value, LV_ALIGN_TOP_RIGHT, 0, 0);
      if (c.type == CardType::WEATHER) {
        v->state = this->label_(o, FONT_SMALL, th.text_dim);
        lv_obj_set_width(v->state, inner_w - ICON_W);
        lv_label_set_long_mode(v->state, LV_LABEL_LONG_MODE_DOTS);
        lv_obj_set_style_text_align(v->state, LV_TEXT_ALIGN_RIGHT, 0);
        lv_obj_align(v->state, LV_ALIGN_TOP_RIGHT, 0, lv_font_get_line_height(this->font_(FONT_VALUE)) + 2);
      }
      break;
    default:
      v->state = this->label_(o, FONT_SMALL, th.text_dim);
      lv_obj_set_width(v->state, inner_w - ICON_W);
      lv_label_set_long_mode(v->state, LV_LABEL_LONG_MODE_DOTS);
      lv_obj_set_style_text_align(v->state, LV_TEXT_ALIGN_RIGHT, 0);
      lv_obj_align(v->state, LV_ALIGN_TOP_RIGHT, 0, 4);
      break;
  }

  const std::string &e = c.entity_id;
  v->main = this->watch_(e, c.type == CardType::SENSOR ? c.attribute.c_str() : "", v);
  if (c.label.empty())
    v->friendly = this->watch_(e, "friendly_name", v);
  switch (c.type) {
    case CardType::LIGHT:
      v->brightness = this->watch_(e, "brightness", v);
      break;
    case CardType::SENSOR:
      if (c.unit.empty() && c.attribute.empty())
        v->unit = this->watch_(e, "unit_of_measurement", v);
      break;
    case CardType::WEATHER:
      v->temperature = this->watch_(e, "temperature", v);
      v->temp_unit = this->watch_(e, "temperature_unit", v);
      v->humidity = this->watch_(e, "humidity", v);
      break;
    default:
      break;
  }
}

void TsxCards::build_bar_() {
  if (this->bar_h_ <= 0)
    return;
  const Theme &th = this->layout_.theme;
  this->bar_ = lv_obj_create(this->root_);
  lv_obj_remove_style_all(this->bar_);
  lv_obj_set_pos(this->bar_, 0, this->height_ - this->bar_h_);
  lv_obj_set_size(this->bar_, this->width_, this->bar_h_);
  lv_obj_remove_flag(this->bar_, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_remove_flag(this->bar_, LV_OBJ_FLAG_CLICKABLE);

  const int side = 150;  // room for the status text on the left
  this->bar_status_ = this->label_(this->bar_, FONT_SMALL, 0xE0A040);
  lv_obj_set_width(this->bar_status_, side);
  lv_label_set_long_mode(this->bar_status_, LV_LABEL_LONG_MODE_DOTS);
  lv_obj_align(this->bar_status_, LV_ALIGN_LEFT_MID, this->layout_.gap, 0);

  int n = this->layout_.pages.size();
  if (n < 2)
    return;
  int bw = (this->width_ - 2 * side) / n;
  if (bw > 140)
    bw = 140;
  int x0 = (this->width_ - n * bw) / 2;
  for (int i = 0; i < n; i++) {
    lv_obj_t *b = lv_obj_create(this->bar_);
    lv_obj_remove_style_all(b);
    lv_obj_set_pos(b, x0 + i * bw + 3, 4);
    lv_obj_set_size(b, bw - 6, this->bar_h_ - 8);
    lv_obj_set_style_radius(b, 8, 0);
    lv_obj_set_style_bg_opa(b, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(th.card), 0);
    lv_obj_remove_flag(b, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(b, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_user_data(b, (void *) (intptr_t) i);
    lv_obj_add_event_cb(
        b,
        [](lv_event_t *e) {
          auto *self = static_cast<TsxCards *>(lv_event_get_user_data(e));
          auto *obj = static_cast<lv_obj_t *>(lv_event_get_current_target(e));
          int page = (int) (intptr_t) lv_obj_get_user_data(obj);
          ESP_LOGI(TAG, "page bar: page %d", page + 1);
          self->show_page(page);
        },
        LV_EVENT_CLICKED, this);
    lv_obj_t *l = this->label_(b, FONT_SMALL, th.text);
    lv_obj_set_width(l, bw - 14);
    lv_label_set_long_mode(l, LV_LABEL_LONG_MODE_DOTS);
    lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_text(l, this->layout_.pages[i].name.c_str());
    lv_obj_center(l);
    this->bar_buttons_.push_back(b);
  }
}

// ---- Home Assistant states ------------------------------------------------------------

Slot *TsxCards::watch_(const std::string &entity, const char *attribute, CardView *v) {
  std::string key = entity + '\x1f' + attribute;
  auto it = this->slots_.find(key);
  Slot *s;
  if (it == this->slots_.end()) {
    auto slot = std::make_unique<Slot>();
    slot->entity_id = entity;
    slot->attribute = attribute;
    s = slot.get();
    this->slots_.emplace(key, std::move(slot));
#ifdef USE_API_HOMEASSISTANT_STATES
    if (api::global_api_server != nullptr) {
      // The api component keeps these pointers: the strings of a slot never
      // change and a slot is never freed.
      api::global_api_server->subscribe_home_assistant_state(
          s->entity_id.c_str(), s->attribute.empty() ? nullptr : s->attribute.c_str(),
          std::function<void(StringRef)>([this, s](StringRef value) {
            s->value.assign(value.c_str(), value.size());
            s->has_value = true;
            this->on_value_(s);
          }));
      this->new_slots_ = true;
    }
#endif
  } else {
    s = it->second.get();
  }
  for (auto *x : s->views)
    if (x == v)
      return s;
  s->views.push_back(v);
  return s;
}

void TsxCards::on_value_(Slot *s) {
  if (!this->first_value_logged_) {
    this->first_value_logged_ = true;
    this->mark_("first entity value");
  }
  for (auto *v : s->views)
    this->update_card_(v);
  if (!this->all_values_logged_ && s->attribute.empty()) {
    for (auto &it : this->slots_)
      if (it.second->attribute.empty() && !it.second->views.empty() && !it.second->has_value)
        return;
    this->all_values_logged_ = true;
    this->mark_("all entity states");
  }
}

// ---- updating the cards ------------------------------------------------------------------

void TsxCards::set_text_(lv_obj_t *label, const char *text) {
  if (label == nullptr)
    return;
  const char *cur = lv_label_get_text(label);
  if (cur == nullptr || strcmp(cur, text) != 0)
    lv_label_set_text(label, text);
}

// Set the text of a label with a fixed width. A text that is too wide for
// one line uses the smaller font, then up to `lines` lines, and ends with
// "..." when it is still too long. The label keeps its alignment because its
// height is set to the lines that the text needs.
void TsxCards::set_fit_text_(lv_obj_t *label, const char *text, int lines, uint8_t font, uint8_t small) {
  if (label == nullptr)
    return;
  const char *cur = lv_label_get_text(label);
  if (cur != nullptr && strcmp(cur, text) == 0)
    return;
  int32_t w = lv_obj_get_style_width(label, LV_PART_MAIN);
  auto width = [text](const lv_font_t *fnt) {
    lv_point_t p;
    lv_text_get_size(&p, text, fnt, 0, 0, LV_COORD_MAX, LV_TEXT_FLAG_NONE);
    return p.x;
  };
  const lv_font_t *f = this->font_(font);
  int32_t tw = width(f);
  if (tw > w && small != font) {
    f = this->font_(small);
    tw = width(f);
  }
  int need = tw > w ? lines : 1;
  lv_obj_set_style_text_font(label, f, 0);
  lv_obj_set_height(label, need * lv_font_get_line_height(f));
  lv_label_set_text(label, text);
}

void TsxCards::set_icon_(lv_obj_t *label, const std::string &name, const char *fallback) {
  if (label == nullptr)
    return;
  uint32_t cp = name.empty() ? 0 : icon_code(name);
  if (cp == 0 && !name.empty()) {
    static std::vector<std::string> warned;
    bool seen = false;
    for (const auto &w : warned)
      seen |= w == name;
    if (!seen) {
      warned.push_back(name);
      ESP_LOGW(TAG, "icon mdi:%s is not in the icon font; the card shows mdi:%s", name.c_str(), fallback);
    }
  }
  if (cp == 0)
    cp = icon_code(fallback);
  char buf[8];
  utf8(cp, buf);
  this->set_text_(label, buf);
}

void TsxCards::update_card_(CardView *v) {
  const CardSpec &c = *v->spec;
  const Theme &th = this->layout_.theme;
  if (c.type == CardType::CLOCK)
    return;
  bool has = v->main != nullptr && v->main->has_value;
  const std::string st = has ? v->main->value : std::string();
  bool unavailable = st == "unavailable";
  int lit = 0;
  std::string name = c.label;
  if (name.empty())
    name = v->friendly != nullptr && v->friendly->has_value ? v->friendly->value : c.entity_id;
  std::string state, value;
  const char *icon = "help-circle-outline";
  std::string dom = entity_domain(c.entity_id);

  switch (c.type) {
    case CardType::LIGHT: {
      bool on = st == "on";
      lit = on;
      icon = on ? "lightbulb-on" : "lightbulb-outline";
      double b;
      if (!has)
        state = "--";
      else if (unavailable)
        state = "Unavailable";
      else if (on && v->brightness != nullptr && v->brightness->has_value && parse_number(v->brightness->value, b))
        state = "On " + std::to_string((int) lround(b * 100.0 / 255.0)) + "%";
      else
        state = on ? "On" : "Off";
      break;
    }
    case CardType::SWITCH: {
      bool on = st == "on";
      lit = on;
      if (dom == "fan")
        icon = "fan";
      else if (dom == "light")
        icon = on ? "lightbulb-on" : "lightbulb-outline";
      else
        icon = on ? "toggle-switch" : "toggle-switch-off-outline";
      state = !has ? "--" : unavailable ? "Unavailable" : on ? "On" : st == "off" ? "Off" : st;
      break;
    }
    case CardType::SCENE:
      icon = "palette";
      state = unavailable ? "Unavailable" : "Scene";
      break;
    case CardType::SCRIPT:
      icon = "script-text";
      lit = st == "on";
      state = unavailable ? "Unavailable" : lit ? "Running" : "Script";
      break;
    case CardType::SENSOR: {
      std::string unit = c.unit;
      if (unit.empty() && v->unit != nullptr && v->unit->has_value)
        unit = v->unit->value;
      double num;
      if (!has || unavailable || st == "unknown")
        value = "--";
      else if (c.precision >= 0 && parse_number(st, num)) {
        char buf[48];
        snprintf(buf, sizeof buf, "%.*f", c.precision, num);
        value = buf;
      } else
        value = st;
      if (!unit.empty() && value != "--")
        value += (unit[0] == '%' || unit.compare(0, 2, "\xC2\xB0") == 0) ? unit : " " + unit;
      if (unit == "\xC2\xB0" "C" || unit == "\xC2\xB0" "F")
        icon = "thermometer";
      else if (unit == "%")
        icon = "water-percent";
      else if (unit == "W" || unit == "kW" || unit == "kWh" || unit == "Wh")
        icon = "flash";
      else
        icon = "gauge";
      break;
    }
    case CardType::WEATHER: {
      const Condition *cond = find_condition(st);
      icon = cond != nullptr ? cond->icon : "weather-partly-cloudy";
      std::string ctext = !has ? "--" : unavailable ? "Unavailable" : cond != nullptr ? cond->text : st;
      double t;
      if (v->temperature != nullptr && v->temperature->has_value && parse_number(v->temperature->value, t)) {
        value = std::to_string((int) lround(t));
        if (v->temp_unit != nullptr && v->temp_unit->has_value)
          value += v->temp_unit->value;
      } else {
        value = "--";
      }
      std::string hum;
      double hv;
      if (v->humidity != nullptr && v->humidity->has_value && parse_number(v->humidity->value, hv))
        hum = "Humidity " + std::to_string((int) lround(hv)) + "%";
      if (c.label.empty()) {
        name = ctext;
        state = hum;
      } else {
        state = hum.empty() ? ctext : ctext + ", " + hum;
      }
      break;
    }
    default:
      break;
  }
  this->set_fit_text_(v->name, name.c_str(), 2, FONT_LABEL, FONT_LABEL);
  this->set_fit_text_(v->state, state.c_str(), 1, FONT_SMALL, FONT_SMALL);
  this->set_fit_text_(v->value, value.c_str(), 1, FONT_VALUE, FONT_LABEL);
  this->set_icon_(v->icon, c.icon, icon);
  if (lit != v->lit) {
    v->lit = lit;
    lv_obj_set_style_bg_color(v->obj, lv_color_hex(lit ? th.card_on : th.card), 0);
    if (v->icon != nullptr)
      lv_obj_set_style_text_color(v->icon, lv_color_hex(lit ? th.text : th.text_dim), 0);
    if (v->state != nullptr)
      lv_obj_set_style_text_color(v->state, lv_color_hex(lit ? th.text : th.text_dim), 0);
  }
}

void TsxCards::update_clocks_(bool force) {
  if (this->clocks_.empty())
    return;
  char tbuf[64] = "--:--", dbuf[96] = "";
  for (auto *v : this->clocks_) {
    const CardSpec &c = *v->spec;
    strcpy(tbuf, "--:--");
    dbuf[0] = '\0';
#ifdef USE_TIME
    if (this->time_ != nullptr) {
      ESPTime now = this->time_->now();
      if (now.is_valid()) {
        now.strftime(tbuf, sizeof tbuf, c.format.c_str());
        if (!c.date_format.empty())
          now.strftime(dbuf, sizeof dbuf, c.date_format.c_str());
      }
    }
#endif
    this->set_text_(v->value, tbuf);
    this->set_text_(v->state, dbuf);
  }
}

void TsxCards::update_bar_() {
  if (this->bar_status_ != nullptr) {
    const char *s = "";
    if (!this->layout_error_.empty())
      s = "Layout error";
    else if (!this->connected_)
      s = "Not connected";
    this->set_text_(this->bar_status_, s);
  }
  const Theme &th = this->layout_.theme;
  for (size_t i = 0; i < this->bar_buttons_.size(); i++)
    lv_obj_set_style_bg_color(this->bar_buttons_[i], lv_color_hex((int) i == this->page_ ? th.card_on : th.card), 0);
}

// ---- taps, keys and pages ---------------------------------------------------------------

void TsxCards::on_card_tap(CardView *v) {
  const CardSpec &c = *v->spec;
  char origin[96];
  snprintf(origin, sizeof origin, "tap on page %d card %d (%s %s)", v->page + 1, c.index, card_type_name(c.type),
           c.entity_id.c_str());
  if (c.tap.kind != ActionSpec::DEFAULT) {
    this->run_action_(c.tap, c.entity_id, origin);
    return;
  }
  ActionSpec a;
  a.kind = ActionSpec::CALL;
  switch (c.type) {
    case CardType::LIGHT:
      a.action = "light.toggle";
      break;
    case CardType::SWITCH:
      a.action = entity_domain(c.entity_id) + ".toggle";
      break;
    case CardType::SCENE:
      a.action = "scene.turn_on";
      break;
    case CardType::SCRIPT:
      a.action = "script.turn_on";
      break;
    default:
      a.kind = ActionSpec::NONE;
      break;
  }
  this->run_action_(a, c.entity_id, origin);
}

void TsxCards::key_press(const std::string &name) {
  ActionSpec a;
  auto it = this->layout_.keys.find(name);
  if (it != this->layout_.keys.end()) {
    a = it->second;
  } else if (name == "home") {
    a.kind = ActionSpec::PAGE;
    a.page = 0;
  } else if (name == "up") {
    a.kind = ActionSpec::PREV_PAGE;
  } else if (name == "down") {
    a.kind = ActionSpec::NEXT_PAGE;
  } else {
    a.kind = ActionSpec::NONE;
  }
  std::string origin = "key " + name;
  this->run_action_(a, "", origin.c_str());
}

void TsxCards::run_action_(const ActionSpec &a, const std::string &entity, const char *origin) {
  switch (a.kind) {
    case ActionSpec::CALL: {
      bool own_entity = false;
      for (const auto &kv : a.data)
        own_entity |= kv.first == "entity_id";
      ESP_LOGI(TAG, "%s: action %s", origin, a.action.c_str());
      this->call_ha_(a.action, own_entity ? std::string() : entity, a.data);
      break;
    }
    case ActionSpec::PAGE:
      ESP_LOGI(TAG, "%s: page %d", origin, a.page + 1);
      this->show_page(a.page);
      break;
    case ActionSpec::NEXT_PAGE:
      ESP_LOGI(TAG, "%s: next page", origin);
      this->next_page();
      break;
    case ActionSpec::PREV_PAGE:
      ESP_LOGI(TAG, "%s: previous page", origin);
      this->prev_page();
      break;
    default:
      ESP_LOGI(TAG, "%s: no action", origin);
      break;
  }
}

void TsxCards::call_ha_(const std::string &action, const std::string &entity,
                        const std::vector<std::pair<std::string, std::string>> &data) {
#ifdef USE_API_HOMEASSISTANT_SERVICES
  if (api::global_api_server == nullptr || !api::global_api_server->is_connected()) {
    ESP_LOGW(TAG, "Home Assistant is not connected: %s not sent", action.c_str());
    return;
  }
  api::HomeassistantActionRequest req;
  req.service = StringRef(action);
  req.is_event = false;
  req.data.init(entity.empty() ? 0 : 1);
  if (!entity.empty()) {
    auto &kv = req.data.emplace_back();
    kv.key = StringRef("entity_id");
    kv.value = StringRef(entity);
  }
  // data_template: Home Assistant renders the values, so "50" arrives as the
  // number 50.
  req.data_template.init(data.size());
  for (const auto &d : data) {
    auto &kv = req.data_template.emplace_back();
    kv.key = StringRef(d.first);
    kv.value = StringRef(d.second);
  }
  api::global_api_server->send_homeassistant_action(req);
  ESP_LOGI(TAG, "sent %s%s%s to Home Assistant", action.c_str(), entity.empty() ? "" : " for ", entity.c_str());
#else
  ESP_LOGW(TAG, "built without homeassistant_services: %s not sent", action.c_str());
#endif
}

void TsxCards::show_page(int page) {
  int n = this->layout_.pages.size();
  if (this->tiles_ == nullptr || n == 0)
    return;
  if (page < 0 || page >= n)
    page = 0;
  if (page != this->page_ && this->page_ < (int) this->pages_.size())
    lv_obj_add_flag(this->pages_[this->page_], LV_OBJ_FLAG_HIDDEN);
  if (page != this->page_)
    this->page_t0_ = mono_us();
  this->page_ = page;
  lv_obj_remove_flag(this->pages_[page], LV_OBJ_FLAG_HIDDEN);
  this->update_bar_();
}

void TsxCards::next_page() {
  int n = this->layout_.pages.size();
  if (n > 0)
    this->show_page((this->page_ + 1) % n);
}

void TsxCards::prev_page() {
  int n = this->layout_.pages.size();
  if (n > 0)
    this->show_page((this->page_ + n - 1) % n);
}

void TsxCards::on_gesture() {
  lv_indev_t *indev = lv_indev_active();
  if (indev == nullptr)
    return;
  lv_dir_t dir = lv_indev_get_gesture_dir(indev);
  int n = this->layout_.pages.size();
  // A swipe to the left shows the next page, a swipe to the right the
  // previous one. A swipe does not go past the first or the last page.
  int page = this->page_;
  if (dir == LV_DIR_LEFT && page < n - 1)
    page++;
  else if (dir == LV_DIR_RIGHT && page > 0)
    page--;
  else
    return;
  ESP_LOGI(TAG, "swipe: page %d", page + 1);
  this->show_page(page);
}

}  // namespace tsx_cards
}  // namespace esphome
