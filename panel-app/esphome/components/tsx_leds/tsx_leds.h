// tsx_leds: an ESPHome light on a Linux LED class device. See light.py.
#pragma once

#ifdef USE_HOST
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "esphome/components/light/light_output.h"
#include "esphome/components/light/light_state.h"
#include "esphome/core/component.h"
#include "esphome/core/log.h"

namespace esphome::tsx_leds {

class TsxLed : public light::LightOutput, public Component {
 public:
  void set_path(const std::string &path) { this->path_ = path; }

  void setup() override {
    this->max_ = read_int_(this->path_ + "/max_brightness", 0);
    std::string idx;
    if (read_text_(this->path_ + "/multi_index", idx)) {
      // For example "green blue red green blue red".
      char *save = nullptr;
      std::vector<char> buf(idx.begin(), idx.end());
      buf.push_back('\0');
      for (char *t = strtok_r(buf.data(), " \n", &save); t != nullptr; t = strtok_r(nullptr, " \n", &save))
        this->channels_.push_back(strcmp(t, "red") == 0 ? 0 : strcmp(t, "green") == 0 ? 1 : strcmp(t, "blue") == 0 ? 2 : -1);
    }
    if (this->max_ <= 0) {
      ESP_LOGE(TAG, "%s: no LED device", this->path_.c_str());
      this->mark_failed();
    }
  }

  void dump_config() override {
    ESP_LOGCONFIG(TAG, "TSX LED %s: max %d, %u color values", this->path_.c_str(), this->max_,
                  (unsigned) this->channels_.size());
  }

  light::LightTraits get_traits() override {
    auto traits = light::LightTraits();
    if (this->channels_.empty()) {
      traits.set_supported_color_modes({light::ColorMode::BRIGHTNESS});
    } else {
      traits.set_supported_color_modes({light::ColorMode::RGB});
    }
    return traits;
  }

  void write_state(light::LightState *state) override {
    if (this->max_ <= 0)
      return;
    if (this->channels_.empty()) {
      float b;
      state->current_values_as_brightness(&b);
      this->write_brightness_(lroundf(b * this->max_));
      return;
    }
    // The color with the brightness and the gamma of the light. The LED
    // brightness is the full level, so each value of multi_intensity is the
    // level of its color.
    float rgb[3];
    state->current_values_as_rgb(&rgb[0], &rgb[1], &rgb[2]);
    std::string text;
    bool any = false;
    for (int ch : this->channels_) {
      long v = ch < 0 ? 0 : lroundf(rgb[ch] * this->max_);
      any |= v > 0;
      text += std::to_string(v) + " ";
    }
    text.back() = '\n';
    if (text != this->last_intensity_) {
      if (write_text_(this->path_ + "/multi_intensity", text))
        this->last_intensity_ = text;
      this->last_brightness_ = -1;  // the driver uses the new values at the next brightness write
    }
    this->write_brightness_(any ? this->max_ : 0);
  }

 protected:
  static constexpr const char *TAG = "tsx_leds";

  void write_brightness_(long v) {
    if (v == this->last_brightness_)
      return;
    if (write_text_(this->path_ + "/brightness", std::to_string(v) + "\n"))
      this->last_brightness_ = v;
  }
  bool write_text_(const std::string &file, const std::string &text) {
    FILE *f = fopen(file.c_str(), "w");
    bool ok = f != nullptr && fwrite(text.data(), 1, text.size(), f) == text.size();
    ok = f != nullptr && fclose(f) == 0 && ok;
    if (!ok && !this->warned_) {
      this->warned_ = true;
      ESP_LOGW(TAG, "cannot write %s (the next errors are not logged)", file.c_str());
    }
    return ok;
  }
  static bool read_text_(const std::string &file, std::string &out) {
    FILE *f = fopen(file.c_str(), "r");
    if (f == nullptr)
      return false;
    char buf[512];
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    out.assign(buf, n);
    return n > 0;
  }
  static int read_int_(const std::string &file, int def) {
    std::string s;
    return read_text_(file, s) ? atoi(s.c_str()) : def;
  }

  std::string path_;
  int max_{0};
  std::vector<int> channels_;  // 0 red, 1 green, 2 blue, -1 another color
  std::string last_intensity_;
  long last_brightness_{-1};
  bool warned_{false};
};

}  // namespace esphome::tsx_leds
#endif
