#pragma once

#ifdef USE_HOST
#include <cstdint>
#include <string>
#include <vector>

#include <xf86drmMode.h>

#include "esphome/components/display/display.h"
#include "esphome/components/snapshot/snapshot.h"
#include "esphome/core/component.h"
#include "esphome/core/defines.h"
#ifdef USE_LVGL
#include "lvgl.h"
#endif

namespace esphome::tsx_drm {

/// A display on a Linux DRM/KMS device (for example imx-drm), with no SDL,
/// no EGL and no window system.
///
/// The app (LVGL) writes into `shadow_`, a copy of the screen in cached RAM.
/// At the end of each LVGL refresh (or in loop() for other writers) the
/// areas that changed go into the back dumb buffer, and a page flip shows it
/// at the next vertical blank. The back buffer also gets the areas of the frame before,
/// so both buffers hold the full picture. The dumb buffers are write-combined
/// (uncached) memory: the CPU writes them quickly but reads them very slowly,
/// so nothing is ever read from them and nothing draws straight into them.
class TsxDrm final : public display::Display, public snapshot::Snapshot {
 public:
  void set_device(const std::string &device) { this->device_ = device; }
  void set_page_flip(bool flip) { this->flip_ = flip; }

  void setup() override;
  void loop() override;
  void update() override;
  void dump_config() override;
  float get_setup_priority() const override { return setup_priority::HARDWARE; }
  display::DisplayType get_display_type() override { return display::DISPLAY_TYPE_COLOR; }

  void draw_pixel_at(int x, int y, Color color) override;
  void draw_pixels_at(int x_start, int y_start, int w, int h, const uint8_t *ptr, display::ColorOrder order,
                      display::ColorBitness bitness, bool big_endian, int x_offset, int y_offset, int x_pad) override;
  void fill(Color color) override;

  /// How set_power(false) makes the screen dark.
  enum OffMode : uint8_t {
    /// The output goes off (the DPMS property of the connector). The driver
    /// can also cut the panel supply. A panel that comes on again can show
    /// a white or a random picture for some frames: see set_power_on_delay().
    OFF_DPMS = 0,
    /// The output stays on and shows a black frame (a third dumb buffer).
    /// The panel stays powered, so the picture comes back with the next
    /// vertical blank, with no power-on frames.
    OFF_BLACK,
  };
  void set_off_mode(OffMode m) { this->off_mode_ = m; }
  /// OFF_BLACK: turn the output off (DPMS) too when the screen stays dark
  /// for this time. 0: never.
  void set_dpms_after(uint32_t ms) { this->dpms_after_ = ms; }
  /// After the output comes on from DPMS off: wait this time after the
  /// first frame is on the output before set_power(true) returns, so the
  /// panel is stable before the caller turns the backlight on.
  void set_power_on_delay(uint32_t ms) { this->power_on_delay_ = ms; }

  /// Show the picture (true) or make the screen dark (false, see OffMode).
  /// While it is dark, the app can still draw: the RAM copy keeps the
  /// changes. set_power(true) puts the full picture into a buffer, flips to
  /// it and returns when the flip is done (the frame is on the output, at
  /// most about 50 ms later), so the caller can turn the backlight on with
  /// no old, black or white frame on the glass. Returns false when the
  /// driver refused the change.
  bool set_power(bool on);
  bool is_powered() const { return this->powered_; }

  /// Time in microseconds that loop() spent in copies to the dumb buffers
  /// since the last call, and the number of frames shown. For tests.
  uint32_t take_present_stats(uint32_t *frames);

 protected:
  struct Rect {
    int x1, y1, x2, y2;  // inclusive
  };
  struct Buffer {
    uint32_t handle{0}, fb{0}, pitch{0}, size{0};
    uint8_t *map{nullptr};
  };

  int get_width_internal() override { return this->width_; }
  int get_height_internal() override { return this->height_; }
  int snapshot_width() override { return this->width_; }
  int snapshot_height() override { return this->height_; }
  bool capture_bgr(uint8_t *dest, size_t row_stride) override;

  bool open_device_(const std::string &path, bool quiet);
  bool create_buffer_(Buffer &b);
  void add_dirty_(int x1, int y1, int x2, int y2);
  void copy_rects_(Buffer &b, const std::vector<Rect> &rects, bool full);
  void handle_events_(int timeout_ms);
  void present_(int wait_ms);
#ifdef USE_LVGL
  static void lvgl_refr_ready_(lv_event_t *e);
  bool lvgl_hooked_{false};
#endif
  bool failed_(const char *what);
  bool dpms_(bool on);
  bool flip_to_(Buffer &b, int wait_ms);

  std::string device_;
  bool flip_{true};
  int fd_{-1};
  uint32_t conn_id_{0}, crtc_id_{0};
  drmModeModeInfo mode_{};
  int width_{0}, height_{0};
  Buffer buf_[3];  // two for the picture, the third (OFF_BLACK) is black
  int nbuf_{0};
  int front_{0};
  bool flip_pending_{false};
  bool flip_failed_{false};
  bool powered_{true};
  bool dpms_off_{false};    // the output is off (DPMS)
  bool black_shown_{false}; // OFF_BLACK: the black buffer is on the output
  OffMode off_mode_{OFF_DPMS};
  uint32_t dpms_after_{0}, power_on_delay_{0}, dark_since_{0};
  uint32_t dpms_prop_{0};
  uint16_t *shadow_{nullptr};
  // Changed areas not shown yet, and the areas of the last frame shown
  // (the back buffer lacks them). More than kMaxRects: a full copy.
  std::vector<Rect> dirty_, last_;
  bool dirty_full_{false}, last_full_{false};
  uint32_t copy_us_{0}, frames_{0};
  static constexpr size_t kMaxRects = 32;
};

}  // namespace esphome::tsx_drm
#endif
