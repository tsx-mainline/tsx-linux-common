#ifdef USE_HOST
#include "tsx_drm.h"

#include <cerrno>
#include <cstdlib>
#include <algorithm>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <poll.h>
#include <sys/mman.h>
#include <unistd.h>

#include <drm_fourcc.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#include "esphome/core/log.h"

namespace esphome::tsx_drm {

static const char *const TAG = "tsx_drm";

static uint32_t mono_us() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint32_t(ts.tv_sec * 1000000ULL + ts.tv_nsec / 1000);
}

bool TsxDrm::failed_(const char *what) {
  ESP_LOGE(TAG, "%s: %s", what, strerror(errno));
  return false;
}

bool TsxDrm::open_device_(const std::string &path, bool quiet) {
  int fd = open(path.c_str(), O_RDWR | O_CLOEXEC);
  if (fd < 0) {
    if (!quiet)
      ESP_LOGE(TAG, "%s: %s", path.c_str(), strerror(errno));
    return false;
  }
  uint64_t has_dumb = 0;
  drmModeRes *res = drmModeGetResources(fd);
  if (res == nullptr || drmGetCap(fd, DRM_CAP_DUMB_BUFFER, &has_dumb) != 0 || !has_dumb) {
    // A render-only device (a GPU) has no outputs.
    if (res != nullptr)
      drmModeFreeResources(res);
    close(fd);
    if (!quiet)
      ESP_LOGE(TAG, "%s has no display outputs", path.c_str());
    return false;
  }
  drmModeConnector *conn = nullptr;
  for (int i = 0; i < res->count_connectors && conn == nullptr; i++) {
    drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);
    if (c != nullptr && c->connection == DRM_MODE_CONNECTED && c->count_modes > 0) {
      conn = c;
    } else if (c != nullptr) {
      drmModeFreeConnector(c);
    }
  }
  if (conn == nullptr) {
    drmModeFreeResources(res);
    close(fd);
    if (!quiet)
      ESP_LOGE(TAG, "%s: no connected output", path.c_str());
    return false;
  }
  drmModeModeInfo mode = conn->modes[0];
  for (int i = 0; i < conn->count_modes; i++) {
    if (conn->modes[i].type & DRM_MODE_TYPE_PREFERRED) {
      mode = conn->modes[i];
      break;
    }
  }
  // The CRTC: the one of the current encoder, else the first one that an
  // encoder of the connector can use.
  uint32_t crtc = 0;
  drmModeEncoder *enc = conn->encoder_id ? drmModeGetEncoder(fd, conn->encoder_id) : nullptr;
  if (enc != nullptr) {
    crtc = enc->crtc_id;
    drmModeFreeEncoder(enc);
  }
  for (int e = 0; e < conn->count_encoders && crtc == 0; e++) {
    enc = drmModeGetEncoder(fd, conn->encoders[e]);
    if (enc == nullptr)
      continue;
    for (int i = 0; i < res->count_crtcs; i++) {
      if (enc->possible_crtcs & (1u << i)) {
        crtc = res->crtcs[i];
        break;
      }
    }
    drmModeFreeEncoder(enc);
  }
  this->fd_ = fd;
  this->conn_id_ = conn->connector_id;
  this->crtc_id_ = crtc;
  this->width_ = mode.hdisplay;
  this->height_ = mode.vdisplay;
  this->device_ = path;
  drmModeFreeConnector(conn);
  drmModeFreeResources(res);
  this->mode_ = mode;
  if (crtc == 0) {
    ESP_LOGE(TAG, "%s: no CRTC for the output", path.c_str());
    close(fd);
    this->fd_ = -1;
    return false;
  }
  return true;
}

bool TsxDrm::create_buffer_(Buffer &b) {
  drm_mode_create_dumb creq{};
  creq.width = this->width_;
  creq.height = this->height_;
  creq.bpp = 16;
  if (drmIoctl(this->fd_, DRM_IOCTL_MODE_CREATE_DUMB, &creq) != 0)
    return this->failed_("create dumb buffer");
  b.handle = creq.handle;
  b.pitch = creq.pitch;
  b.size = creq.size;
  uint32_t handles[4] = {b.handle}, pitches[4] = {b.pitch}, offsets[4] = {0};
  if (drmModeAddFB2(this->fd_, this->width_, this->height_, DRM_FORMAT_RGB565, handles, pitches, offsets, &b.fb, 0) !=
      0)
    return this->failed_("add framebuffer");
  drm_mode_map_dumb mreq{};
  mreq.handle = b.handle;
  if (drmIoctl(this->fd_, DRM_IOCTL_MODE_MAP_DUMB, &mreq) != 0)
    return this->failed_("map dumb buffer");
  void *map = mmap(nullptr, b.size, PROT_READ | PROT_WRITE, MAP_SHARED, this->fd_, mreq.offset);
  if (map == MAP_FAILED)
    return this->failed_("mmap dumb buffer");
  b.map = static_cast<uint8_t *>(map);
  memset(b.map, 0, b.size);
  return true;
}

void TsxDrm::setup() {
  bool ok = false;
  if (!this->device_.empty()) {
    ok = this->open_device_(this->device_, false);
  } else {
    for (int i = 0; i < 8 && !ok; i++)
      ok = this->open_device_("/dev/dri/card" + std::to_string(i), true);
    if (!ok)
      ESP_LOGE(TAG, "no DRM device with a connected output in /dev/dri");
  }
  if (!ok) {
    this->mark_failed();
    return;
  }
  this->nbuf_ = this->flip_ ? 2 : 1;
  for (int i = 0; i < this->nbuf_; i++) {
    if (!this->create_buffer_(this->buf_[i])) {
      this->mark_failed();
      return;
    }
  }
  this->shadow_ = static_cast<uint16_t *>(calloc(size_t(this->width_) * this->height_, 2));
  if (this->shadow_ == nullptr) {
    ESP_LOGE(TAG, "no memory for the screen copy");
    this->mark_failed();
    return;
  }
  if (drmModeSetCrtc(this->fd_, this->crtc_id_, this->buf_[0].fb, 0, 0, &this->conn_id_, 1, &this->mode_) != 0) {
    // EACCES: another program is DRM master (a compositor, an SDL app).
    this->failed_("set the display mode (is another program on the display?)");
    this->mark_failed();
    return;
  }
  this->front_ = 0;
}

void TsxDrm::dump_config() {
  LOG_DISPLAY("", "TSX DRM", this);
  ESP_LOGCONFIG(TAG,
                "  Device: %s\n"
                "  Mode: %dx%d, RGB565, %d buffer(s)%s\n"
                "  Dark screen: %s, DPMS after %u ms (0: never), power-on delay %u ms",
                this->device_.c_str(), this->width_, this->height_, this->nbuf_,
                this->nbuf_ == 2 ? " with page flips" : "",
                this->off_mode_ == OFF_BLACK ? "black frame" : "output off (DPMS)", (unsigned) this->dpms_after_,
                (unsigned) this->power_on_delay_);
}

void TsxDrm::update() { this->do_update_(); }

void TsxDrm::add_dirty_(int x1, int y1, int x2, int y2) {
  if (this->dirty_full_)
    return;
  for (auto &r : this->dirty_) {
    if (x1 >= r.x1 && y1 >= r.y1 && x2 <= r.x2 && y2 <= r.y2)
      return;  // already inside an area to copy
  }
  if (this->dirty_.size() >= kMaxRects) {
    this->dirty_full_ = true;
    this->dirty_.clear();
    return;
  }
  this->dirty_.push_back(Rect{x1, y1, x2, y2});
}

void TsxDrm::draw_pixels_at(int x_start, int y_start, int w, int h, const uint8_t *ptr, display::ColorOrder order,
                            display::ColorBitness bitness, bool big_endian, int x_offset, int y_offset, int x_pad) {
  if (this->shadow_ == nullptr)
    return;
  if (bitness != display::COLOR_BITNESS_565 || big_endian || order != display::COLOR_ORDER_RGB ||
      this->rotation_ != display::DISPLAY_ROTATION_0_DEGREES) {
    Display::draw_pixels_at(x_start, y_start, w, h, ptr, order, bitness, big_endian, x_offset, y_offset, x_pad);
    return;
  }
  // The fast path (LVGL): copy the rows into the screen copy.
  int stride = x_offset + w + x_pad;
  const uint16_t *src = reinterpret_cast<const uint16_t *>(ptr) + size_t(stride) * y_offset + x_offset;
  int x1 = x_start, y1 = y_start, x2 = x_start + w - 1, y2 = y_start + h - 1;
  if (x1 < 0) {
    src -= x1;
    x1 = 0;
  }
  if (y1 < 0) {
    src -= size_t(y1) * stride;
    y1 = 0;
  }
  if (x2 >= this->width_)
    x2 = this->width_ - 1;
  if (y2 >= this->height_)
    y2 = this->height_ - 1;
  if (x2 < x1 || y2 < y1)
    return;
  size_t bytes = size_t(x2 - x1 + 1) * 2;
  for (int y = y1; y <= y2; y++, src += stride)
    memcpy(this->shadow_ + size_t(y) * this->width_ + x1, src, bytes);
  this->add_dirty_(x1, y1, x2, y2);
}

void TsxDrm::draw_pixel_at(int x, int y, Color color) {
  if (this->shadow_ == nullptr || !this->get_clipping().inside(x, y))
    return;
  switch (this->rotation_) {
    case display::DISPLAY_ROTATION_90_DEGREES: {
      int t = x;
      x = this->width_ - y - 1;
      y = t;
      break;
    }
    case display::DISPLAY_ROTATION_180_DEGREES:
      x = this->width_ - x - 1;
      y = this->height_ - y - 1;
      break;
    case display::DISPLAY_ROTATION_270_DEGREES: {
      int t = y;
      y = this->height_ - x - 1;
      x = t;
      break;
    }
    default:
      break;
  }
  if (x < 0 || y < 0 || x >= this->width_ || y >= this->height_)
    return;
  this->shadow_[size_t(y) * this->width_ + x] = display::ColorUtil::color_to_565(color, display::COLOR_ORDER_RGB);
  // One area per pixel would fill the list at once: grow the last area.
  if (!this->dirty_full_ && !this->dirty_.empty()) {
    Rect &r = this->dirty_.back();
    r.x1 = std::min(r.x1, x);
    r.y1 = std::min(r.y1, y);
    r.x2 = std::max(r.x2, x);
    r.y2 = std::max(r.y2, y);
  } else {
    this->add_dirty_(x, y, x, y);
  }
}

void TsxDrm::fill(Color color) {
  if (this->shadow_ == nullptr)
    return;
  uint16_t c = display::ColorUtil::color_to_565(color, display::COLOR_ORDER_RGB);
  size_t n = size_t(this->width_) * this->height_;
  for (size_t i = 0; i < n; i++)
    this->shadow_[i] = c;
  this->dirty_full_ = true;
  this->dirty_.clear();
}

void TsxDrm::copy_rects_(Buffer &b, const std::vector<Rect> &rects, bool full) {
  const uint8_t *src = reinterpret_cast<const uint8_t *>(this->shadow_);
  size_t spitch = size_t(this->width_) * 2;
  if (full) {
    if (b.pitch == spitch) {
      memcpy(b.map, src, spitch * this->height_);
    } else {
      for (int y = 0; y < this->height_; y++)
        memcpy(b.map + size_t(y) * b.pitch, src + y * spitch, spitch);
    }
    return;
  }
  for (const Rect &r : rects) {
    size_t bytes = size_t(r.x2 - r.x1 + 1) * 2;
    for (int y = r.y1; y <= r.y2; y++)
      memcpy(b.map + size_t(y) * b.pitch + r.x1 * 2, src + y * spitch + r.x1 * 2, bytes);
  }
}

static void page_flip_handler(int, unsigned, unsigned, unsigned, void *data) {
  *static_cast<bool *>(data) = false;
}

void TsxDrm::handle_events_(int timeout_ms) {
  pollfd p{this->fd_, POLLIN, 0};
  drmEventContext ev{};
  ev.version = 2;
  ev.page_flip_handler = page_flip_handler;
  uint32_t start = mono_us();
  while (this->flip_pending_) {
    int left = timeout_ms - int((mono_us() - start) / 1000);
    if (poll(&p, 1, left > 0 ? left : 0) <= 0)
      return;
    drmHandleEvent(this->fd_, &ev);
  }
}

#ifdef USE_LVGL
// LVGL has drawn all areas of a frame: show them now. Without this the
// frame waits for the next loop() of this component, which runs before the
// LVGL loop in each main loop pass (one pass later, up to 16 ms).
void TsxDrm::lvgl_refr_ready_(lv_event_t *e) {
  static_cast<TsxDrm *>(lv_event_get_user_data(e))->present_(20);
}
#endif

void TsxDrm::loop() {
#ifdef USE_LVGL
  if (!this->lvgl_hooked_) {
    lv_display_t *d = lv_display_get_default();
    if (d != nullptr) {
      lv_display_add_event_cb(d, lvgl_refr_ready_, LV_EVENT_REFR_READY, this);
      this->lvgl_hooked_ = true;
    }
  }
#endif
  // Other writers (a display lambda), and frames that waited for a flip.
  this->present_(0);
  // OFF_BLACK: a long dark time turns the output off too.
  if (this->black_shown_ && this->dpms_after_ > 0 && millis() - this->dark_since_ >= this->dpms_after_) {
    this->black_shown_ = false;
    this->dpms_(false);
  }
}

void TsxDrm::present_(int wait_ms) {
  if (this->fd_ < 0 || this->shadow_ == nullptr || !this->powered_)
    return;
  if (this->flip_pending_)
    this->handle_events_(0);
  if (!this->dirty_full_ && this->dirty_.empty())
    return;
  if (this->flip_pending_) {
    // The screen still shows the buffer before the last one: wait for the
    // vertical blank (at most wait_ms), or try again in the next loop().
    this->handle_events_(wait_ms);
    if (this->flip_pending_)
      return;
  }
  uint32_t t0 = mono_us();
  if (this->nbuf_ == 1) {
    this->copy_rects_(this->buf_[0], this->dirty_, this->dirty_full_);
  } else {
    int back = 1 - this->front_;
    Buffer &b = this->buf_[back];
    // The back buffer lacks the areas of the frame before. A full frame
    // covers them.
    if (!this->dirty_full_)
      this->copy_rects_(b, this->last_, this->last_full_);
    this->copy_rects_(b, this->dirty_, this->dirty_full_);
    if (drmModePageFlip(this->fd_, this->crtc_id_, b.fb, DRM_MODE_PAGE_FLIP_EVENT, &this->flip_pending_) == 0) {
      this->flip_pending_ = true;
      this->front_ = back;
      this->flip_failed_ = false;
    } else {
      // No flip (for example the output is off): show the change in the
      // front buffer, so the screen is still right.
      if (!this->flip_failed_)
        ESP_LOGW(TAG, "page flip failed: %s (the next failures are not logged)", strerror(errno));
      this->flip_failed_ = true;
      this->copy_rects_(this->buf_[this->front_], this->dirty_, this->dirty_full_);
    }
  }
  this->copy_us_ += mono_us() - t0;
  this->frames_++;
  this->last_.swap(this->dirty_);
  this->last_full_ = this->dirty_full_;
  this->dirty_.clear();
  this->dirty_full_ = false;
}

bool TsxDrm::dpms_(bool on) {
  if (this->dpms_prop_ == 0) {
    drmModeObjectProperties *props = drmModeObjectGetProperties(this->fd_, this->conn_id_, DRM_MODE_OBJECT_CONNECTOR);
    for (uint32_t i = 0; props != nullptr && i < props->count_props && this->dpms_prop_ == 0; i++) {
      drmModePropertyRes *p = drmModeGetProperty(this->fd_, props->props[i]);
      if (p != nullptr && strcmp(p->name, "DPMS") == 0)
        this->dpms_prop_ = p->prop_id;
      drmModeFreeProperty(p);
    }
    drmModeFreeObjectProperties(props);
    if (this->dpms_prop_ == 0) {
      ESP_LOGW(TAG, "the output has no DPMS property: it stays on");
      return false;
    }
  }
  // A flip must not be pending while the CRTC goes off.
  if (this->flip_pending_)
    this->handle_events_(50);
  uint32_t t0 = mono_us();
  if (drmModeConnectorSetProperty(this->fd_, this->conn_id_, this->dpms_prop_,
                                  on ? DRM_MODE_DPMS_ON : DRM_MODE_DPMS_OFF) != 0) {
    ESP_LOGW(TAG, "display output %s: %s", on ? "on" : "off", strerror(errno));
    if (!on)
      return false;
    // Set the mode again with the buffer on the screen.
    if (drmModeSetCrtc(this->fd_, this->crtc_id_, this->buf_[this->front_].fb, 0, 0, &this->conn_id_, 1,
                       &this->mode_) != 0)
      return this->failed_("set the display mode again");
  }
  this->dpms_off_ = !on;
  this->flip_pending_ = false;
  ESP_LOGI(TAG, "display output %s (%.1f ms)", on ? "on" : "off", (mono_us() - t0) / 1000.0);
  return true;
}

// Show buffer b at the next vertical blank and wait (at most wait_ms) until
// it is on the output. Without a flip (the driver refused it), set the mode
// with b at once.
bool TsxDrm::flip_to_(Buffer &b, int wait_ms) {
  if (this->flip_pending_)
    this->handle_events_(50);
  if (drmModePageFlip(this->fd_, this->crtc_id_, b.fb, DRM_MODE_PAGE_FLIP_EVENT, &this->flip_pending_) == 0) {
    this->flip_pending_ = true;
    this->handle_events_(wait_ms);
    return !this->flip_pending_;
  }
  this->flip_pending_ = false;
  return drmModeSetCrtc(this->fd_, this->crtc_id_, b.fb, 0, 0, &this->conn_id_, 1, &this->mode_) == 0;
}

bool TsxDrm::set_power(bool on) {
  if (this->fd_ < 0 || on == this->powered_)
    return true;
  uint32_t t0 = mono_us();
  if (!on) {
    if (this->off_mode_ == OFF_BLACK && !this->dpms_off_) {
      if (this->buf_[2].map == nullptr && !this->create_buffer_(this->buf_[2])) {
        // No memory for the black frame: turn the output off.
        this->off_mode_ = OFF_DPMS;
        return this->set_power(false);
      }
      if (!this->flip_to_(this->buf_[2], 50))
        ESP_LOGW(TAG, "the black frame is not on the output yet");
      this->black_shown_ = true;
      this->powered_ = false;
      this->dark_since_ = millis();
      ESP_LOGI(TAG, "display black, output stays on (%.1f ms)", (mono_us() - t0) / 1000.0);
      return true;
    }
    if (!this->dpms_(false))
      return false;
    this->powered_ = false;
    this->dark_since_ = millis();
    return true;
  }
  bool from_dpms = this->dpms_off_;
  if (from_dpms && !this->dpms_(true))
    return false;
  uint32_t t_out = mono_us();
  // The buffers can lack changes from the time the screen was dark: put the
  // full picture into the back buffer and flip to it. With OFF_BLACK the
  // black buffer is on the output, so either picture buffer is free.
  this->powered_ = true;
  this->black_shown_ = false;
  int back = this->nbuf_ == 2 ? 1 - this->front_ : 0;
  this->copy_rects_(this->buf_[back], this->dirty_, true);
  bool shown = this->flip_to_(this->buf_[back], 50);
  this->front_ = back;
  this->dirty_.clear();
  this->dirty_full_ = false;
  this->last_.clear();
  this->last_full_ = true;  // the other buffer is old: the next frame copies all
  uint32_t t_frame = mono_us();
  if (from_dpms && this->power_on_delay_ > 0)
    usleep(this->power_on_delay_ * 1000);
  ESP_LOGI(TAG, "display on: %s %.1f ms, frame on the output %.1f ms%s, ready %.1f ms", from_dpms ? "output" : "black",
           (t_out - t0) / 1000.0, (t_frame - t0) / 1000.0, shown ? "" : " (no flip event)",
           (mono_us() - t0) / 1000.0);
  return true;
}

uint32_t TsxDrm::take_present_stats(uint32_t *frames) {
  uint32_t us = this->copy_us_;
  if (frames != nullptr)
    *frames = this->frames_;
  this->copy_us_ = 0;
  this->frames_ = 0;
  return us;
}

bool TsxDrm::capture_bgr(uint8_t *dest, size_t row_stride) {
  if (this->shadow_ == nullptr) {
    ESP_LOGE(TAG, "Snapshot requested but the display is not set up");
    return false;
  }
  for (int y = 0; y < this->height_; y++) {
    const uint16_t *s = this->shadow_ + size_t(y) * this->width_;
    uint8_t *d = dest + y * row_stride;
    for (int x = 0; x < this->width_; x++, d += 3) {
      uint16_t c = s[x];
      d[0] = uint8_t(((c & 0x1F) * 255 + 15) / 31);
      d[1] = uint8_t((((c >> 5) & 0x3F) * 255 + 31) / 63);
      d[2] = uint8_t(((c >> 11) * 255 + 15) / 31);
    }
  }
  return true;
}

}  // namespace esphome::tsx_drm
#endif
