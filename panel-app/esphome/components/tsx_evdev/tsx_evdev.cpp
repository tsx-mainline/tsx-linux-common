#ifdef USE_HOST
#include "tsx_evdev.h"

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "esphome/core/hal.h"
#include "esphome/core/log.h"

namespace esphome::tsx_evdev {

static const char *const TAG = "tsx_evdev";

bool TsxEvdev::open_() {
  std::vector<std::string> paths;
  if (!this->path_.empty()) {
    paths.push_back(this->path_);
  } else {
    for (int i = 0; i < 32; i++)
      paths.push_back("/dev/input/event" + std::to_string(i));
  }
  for (const auto &p : paths) {
    int fd = open(p.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0)
      continue;
    char name[128] = "";
    ioctl(fd, EVIOCGNAME(sizeof name - 1), name);
    if (!this->name_.empty() && strstr(name, this->name_.c_str()) == nullptr) {
      close(fd);
      continue;
    }
    input_absinfo ai{};
    this->mt_ = ioctl(fd, EVIOCGABS(ABS_MT_POSITION_X), &ai) == 0 && ai.maximum > ai.minimum;
    if (this->mt_) {
      this->x_min_ = ai.minimum;
      this->x_max_ = ai.maximum;
      if (ioctl(fd, EVIOCGABS(ABS_MT_POSITION_Y), &ai) == 0) {
        this->y_min_ = ai.minimum;
        this->y_max_ = ai.maximum;
      }
    } else if (ioctl(fd, EVIOCGABS(ABS_X), &ai) == 0) {
      this->x_min_ = ai.minimum;
      this->x_max_ = ai.maximum;
      if (ioctl(fd, EVIOCGABS(ABS_Y), &ai) == 0) {
        this->y_min_ = ai.minimum;
        this->y_max_ = ai.maximum;
      }
    }
    this->fd_ = fd;
    this->opened_ = p + " (" + name + ")";
    ESP_LOGI(TAG, "input %s", this->opened_.c_str());
    return true;
  }
  return false;
}

void TsxEvdev::close_() {
  if (this->fd_ >= 0)
    close(this->fd_);
  this->fd_ = -1;
  for (auto &s : this->slots_)
    s.id = -1;
  this->touch_changed_ = true;
}

void TsxEvdev::setup() {
  if (!this->open_())
    ESP_LOGW(TAG, "no input device %s%s yet; trying again every 5 s", this->path_.c_str(), this->name_.c_str());
  this->last_try_ = millis();
}

void TsxEvdev::dump_config() {
  ESP_LOGCONFIG(TAG,
                "TSX evdev input:\n"
                "  Device: %s\n"
                "  Touch range: x %d..%d, y %d..%d, %s\n"
                "  Key sensors: %u",
                this->fd_ >= 0 ? this->opened_.c_str() : "(not open)", this->x_min_, this->x_max_, this->y_min_,
                this->y_max_, this->mt_ ? "multi-touch" : "single touch", (unsigned) this->keys_.size());
}

void TsxEvdev::loop() {
  if (this->fd_ < 0) {
    if (millis() - this->last_try_ > 5000) {
      this->last_try_ = millis();
      this->open_();
    }
    return;
  }
  input_event ev[64];
  for (;;) {
    ssize_t n = read(this->fd_, ev, sizeof ev);
    if (n < 0) {
      if (errno != EAGAIN && errno != EINTR) {
        ESP_LOGW(TAG, "input %s: %s", this->opened_.c_str(), strerror(errno));
        this->close_();
      }
      return;
    }
    for (size_t i = 0; i < size_t(n) / sizeof(input_event); i++) {
      const input_event &e = ev[i];
      if (e.type == EV_ABS) {
        this->touch_data_ = true;
        switch (e.code) {
          case ABS_MT_SLOT:
            this->slot_ = e.value;
            break;
          case ABS_MT_TRACKING_ID:
            if (this->slot_ >= 0 && this->slot_ < kSlots)
              this->slots_[this->slot_].id = e.value;
            break;
          case ABS_MT_POSITION_X:
            if (this->slot_ >= 0 && this->slot_ < kSlots)
              this->slots_[this->slot_].x = e.value;
            break;
          case ABS_MT_POSITION_Y:
            if (this->slot_ >= 0 && this->slot_ < kSlots)
              this->slots_[this->slot_].y = e.value;
            break;
          case ABS_X:
            if (!this->mt_)
              this->slots_[0].x = e.value;
            break;
          case ABS_Y:
            if (!this->mt_)
              this->slots_[0].y = e.value;
            break;
          default:
            break;
        }
      } else if (e.type == EV_KEY) {
        if (e.code == BTN_TOUCH) {
          // Single touch devices: BTN_TOUCH is the finger.
          if (!this->mt_)
            this->slots_[0].id = e.value ? 0 : -1;
          this->touch_data_ = true;
        } else if (e.value != 2) {  // 2: auto repeat
          for (auto &k : this->keys_) {
            if (k.first == e.code)
              k.second->publish_state(e.value != 0);
          }
        }
      } else if (e.type == EV_SYN) {
        if (e.code == SYN_DROPPED) {
          // Events were lost: forget the fingers; the next report sets them.
          for (auto &s : this->slots_)
            s.id = -1;
          this->touch_changed_ = true;
        } else if (e.code == SYN_REPORT && this->touch_data_) {
          this->touch_data_ = false;
          this->touch_changed_ = true;
        }
      }
    }
  }
}

}  // namespace esphome::tsx_evdev
#endif
