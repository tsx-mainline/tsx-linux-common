// volume.cpp: the volume of the panel, for the Home Assistant number "Volume"
// and the settings overlay. See docs/panel-app.md, "Volume".
//
// While the Sendspin player runs, the volume of the panel is the player
// volume (volume_logic.h): the app reads the volume file of the player
// (TSX_PANEL_APP_SENDSPIN_VOLUME, default /run/sendspin-cli/volume) and sets
// the volume and the mute through tsx-panelctl. The mixer stays at the fixed
// level of the board. Without that file:
// the volume is one mixer control of the sound card (the "Master" softvol of
// the board, the same control that tsx-panelctl and the setup page set). The
// app reads and writes it with the control ioctls of the kernel (no
// alsa-lib), as a member of the group audio. The board names the card in
// TSX_SOUND_CARD of board.sh; tsx-panel-app-run hands it to the app as
// TSX_PANEL_APP_SOUND_CARD. TSX_PANEL_APP_VOLUME_CTL names the control
// (default Master). With no card or no control, volume() is NAN and the
// overlay shows no volume slider.
#include "tsx_cards.h"
#include "control.h"
#include "volume_logic.h"

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sound/asound.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "esphome/core/hal.h"
#include "esphome/core/log.h"

namespace esphome {
namespace tsx_cards {

static const char *const TAG = "tsx_cards.volume";
// A failed open is tried again after this time (the board creates the
// softvol control at boot, maybe after the app starts).
static const uint32_t VOLUME_RETRY_MS = 10000;

// The card number of an ALSA card id: /proc/asound/ID is a link to cardN.
static int card_number(const std::string &id) {
  if (!id.empty() && id.find_first_not_of("0123456789") == std::string::npos)
    return atoi(id.c_str());
  char buf[64];
  ssize_t n = readlink(("/proc/asound/" + id).c_str(), buf, sizeof buf - 1);
  if (n <= 4)
    return -1;
  buf[n] = '\0';
  if (strncmp(buf, "card", 4) != 0)
    return -1;
  return atoi(buf + 4);
}

static bool find_control(int fd, const std::string &name, snd_ctl_elem_info &info) {
  memset(&info, 0, sizeof info);
  info.id.iface = SNDRV_CTL_ELEM_IFACE_MIXER;
  strncpy(reinterpret_cast<char *>(info.id.name), name.c_str(), sizeof info.id.name - 1);
  return ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, &info) == 0 && info.type == SNDRV_CTL_ELEM_TYPE_INTEGER &&
         info.count >= 1 && info.value.integer.max > info.value.integer.min;
}

bool TsxCards::volume_open_() {
  if (this->vol_fd_ >= 0)
    return true;
  if (this->snd_card_.empty() || (int32_t) (millis() - this->vol_retry_at_) < 0)
    return false;
  this->vol_retry_at_ = millis() + VOLUME_RETRY_MS;
  int card = card_number(this->snd_card_);
  std::string why;
  int fd = -1;
  snd_ctl_elem_info info;
  if (card < 0) {
    why = "no sound card " + this->snd_card_;
  } else {
    std::string dev = "/dev/snd/controlC" + std::to_string(card);
    fd = open(dev.c_str(), O_RDWR | O_CLOEXEC);
    if (fd < 0)
      why = "cannot open " + dev + ": " + strerror(errno);
    else if (!find_control(fd, this->vol_ctl_, info) &&
             !find_control(fd, this->vol_ctl_ + " Playback Volume", info))
      why = "no volume control '" + this->vol_ctl_ + "' on " + this->snd_card_;
  }
  if (!why.empty()) {
    if (fd >= 0)
      close(fd);
    if (!this->vol_warned_)
      ESP_LOGW(TAG, "%s: no volume (tried again every %u s)", why.c_str(), (unsigned) (VOLUME_RETRY_MS / 1000));
    this->vol_warned_ = true;
    return false;
  }
  this->vol_fd_ = fd;
  this->vol_numid_ = info.id.numid;
  this->vol_count_ = std::min<unsigned int>(info.count, 128);
  this->vol_min_ = info.value.integer.min;
  this->vol_max_ = info.value.integer.max;
  this->vol_warned_ = false;
  ESP_LOGI(TAG, "volume: control '%s' of %s (numid %u, %ld..%ld, %u channels)", this->vol_ctl_.c_str(),
           this->snd_card_.c_str(), this->vol_numid_, this->vol_min_, this->vol_max_, this->vol_count_);
  return true;
}

void TsxCards::volume_close_() {
  if (this->vol_fd_ >= 0)
    close(this->vol_fd_);
  this->vol_fd_ = -1;
}

// ---- the Sendspin player ----

bool TsxCards::player_volume_() const { return access(this->player_vol_file_.c_str(), R_OK) == 0; }

// One line for tsx-panelctl. A program that runs as root has no
// TSX_PANEL_APP_PANELCTL, but may write the FIFO too.
void TsxCards::player_send_(const std::string &line) {
  std::string fifo = this->panelctl_.empty() ? this->run_dir_ + "/panelctl" : this->panelctl_;
  std::string err;
  if (fifo_send_line(fifo, line, err))
    ESP_LOGI(TAG, "%s (Sendspin player, tsx-panelctl)", line.c_str());
  else
    ESP_LOGW(TAG, "tsx-panelctl '%s': %s", line.c_str(), err.c_str());
}

// Called from loop(): send the last value of a drag when its time has come.
void TsxCards::volume_loop_() {
  uint32_t now = millis();
  int v = this->vol_set_.due(now);
  if (v >= 0)
    this->player_send_("volume " + std::to_string(v));
  int m = this->mute_set_.due(now);
  if (m >= 0)
    this->player_send_(m ? "mute on" : "mute off");
}

int TsxCards::volume_muted() {
  int v, m;
  if (!read_player_volume(this->player_vol_file_, v, m))
    return -1;
  return this->mute_set_.shown(m, millis());
}

void TsxCards::set_volume_muted(bool muted) {
  if (!this->player_volume_())
    return;
  this->mute_set_.want(muted ? 1 : 0, millis());
  this->volume_loop_();
}

bool TsxCards::has_volume() { return this->player_volume_() || this->volume_open_(); }

float TsxCards::volume() {
  int pv, pm;
  if (read_player_volume(this->player_vol_file_, pv, pm))
    return (float) this->vol_set_.shown(pv, millis());
  if (!this->volume_open_())
    return NAN;
  snd_ctl_elem_value v;
  memset(&v, 0, sizeof v);
  v.id.numid = this->vol_numid_;
  if (ioctl(this->vol_fd_, SNDRV_CTL_IOCTL_ELEM_READ, &v) != 0) {
    ESP_LOGW(TAG, "cannot read the volume: %s", strerror(errno));
    this->volume_close_();
    return NAN;
  }
  double f = double(v.value.integer.value[0] - this->vol_min_) / double(this->vol_max_ - this->vol_min_);
  return (float) lround(std::max(0.0, std::min(1.0, f)) * 100);
}

void TsxCards::set_volume(float pct) {
  if (std::isnan(pct))
    return;
  pct = std::max(0.0f, std::min(100.0f, pct));
  if (this->player_volume_()) {
    this->vol_set_.want((int) lroundf(pct), millis());
    this->volume_loop_();
    return;
  }
  if (!this->volume_open_())
    return;
  long raw = this->vol_min_ + lround(double(pct) * double(this->vol_max_ - this->vol_min_) / 100.0);
  snd_ctl_elem_value v;
  memset(&v, 0, sizeof v);
  v.id.numid = this->vol_numid_;
  for (unsigned int i = 0; i < this->vol_count_; i++)
    v.value.integer.value[i] = raw;
  if (ioctl(this->vol_fd_, SNDRV_CTL_IOCTL_ELEM_WRITE, &v) != 0) {
    ESP_LOGW(TAG, "cannot set the volume: %s", strerror(errno));
    this->volume_close_();
    return;
  }
  ESP_LOGI(TAG, "volume %.0f%%", pct);
}

}  // namespace tsx_cards
}  // namespace esphome
