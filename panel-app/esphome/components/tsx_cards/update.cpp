// update.cpp: the update state of the panel for Home Assistant. See
// docs/panel-app.md, "Updates", and update_logic.h.
//
// tsx-autoupdate (root) writes the state file (TSX_PANEL_APP_UPDATE_STATE,
// default /run/tsx/update.state). The app reads it at most every
// UPDATE_READ_MS (every UPDATE_READ_HOLD_MS while a set waits for the file).
// The app never runs a root action itself. It writes one line to the FIFO of
// tsx-panelctl: update-install, update-mode V, auto-restart on|off, reboot.
#include "tsx_cards.h"
#include "control.h"
#include "update.h"

#include "esphome/core/hal.h"
#include "esphome/core/log.h"

namespace esphome {
namespace tsx_cards {

static const char *const TAG = "tsx_cards.update";
static const uint32_t UPDATE_READ_MS = 3000;
static const uint32_t UPDATE_READ_HOLD_MS = 1000;

void TsxCards::update_refresh_(bool force) {
  uint32_t now = millis();
  bool hold = this->upd_mode_hold_.active(now) || this->upd_auto_hold_.active(now) || this->upd_install_hold_.active(now);
  uint32_t every = hold ? UPDATE_READ_HOLD_MS : UPDATE_READ_MS;
  if (!force && this->upd_read_once_ && (int32_t) (now - this->upd_read_at_) < (int32_t) every)
    return;
  this->upd_read_once_ = true;
  this->upd_read_at_ = now;
  read_update_state(this->update_file_, this->upd_);
}

const UpdateStatus &TsxCards::update_status() {
  this->update_refresh_(false);
  return this->upd_;
}

UpdState TsxCards::update_state() {
  const UpdateStatus &s = this->update_status();
  uint32_t now = millis();
  int shown = this->upd_install_hold_.shown(s.in_progress, now);
  return update_shown_state(s, shown == 1 && s.in_progress != 1);
}

int TsxCards::restart_required() {
  const UpdateStatus &s = this->update_status();
  return s.known() ? s.restart_required : -1;
}

std::string TsxCards::update_mode() {
  const UpdateStatus &s = this->update_status();
  int reported = s.known() ? update_mode_code(s.mode) : -1;
  return update_mode_name(this->upd_mode_hold_.shown(reported, millis()));
}

int TsxCards::auto_restart() {
  const UpdateStatus &s = this->update_status();
  return this->upd_auto_hold_.shown(s.known() ? s.auto_restart : -1, millis());
}

// One line for tsx-panelctl. A program that runs as root has no
// TSX_PANEL_APP_PANELCTL, but may write the FIFO too.
bool TsxCards::update_send_(const std::string &line) {
  std::string fifo = this->panelctl_.empty() ? this->run_dir_ + "/panelctl" : this->panelctl_;
  std::string err;
  if (fifo_send_line(fifo, line, err)) {
    ESP_LOGI(TAG, "%s (tsx-panelctl)", line.c_str());
    return true;
  }
  ESP_LOGW(TAG, "tsx-panelctl '%s': %s", line.c_str(), err.c_str());
  return false;
}

void TsxCards::update_install() {
  if (this->update_send_(update_install_line()))
    this->upd_install_hold_.set(1, millis());
}

void TsxCards::restart() { this->update_send_(update_restart_line()); }

void TsxCards::set_update_mode(const std::string &mode) {
  std::string line = update_mode_line(mode);
  if (line.empty()) {
    ESP_LOGW(TAG, "update mode '%s' refused (auto or manual)", mode.c_str());
    return;
  }
  if (this->update_send_(line))
    this->upd_mode_hold_.set(update_mode_code(mode), millis());
}

void TsxCards::set_auto_restart(bool on) {
  if (this->update_send_(auto_restart_line(on)))
    this->upd_auto_hold_.set(on ? 1 : 0, millis());
}

#ifdef USE_UPDATE

void TsxUpdate::setup() { this->refresh_(true); }

void TsxUpdate::update() { this->refresh_(false); }

void TsxUpdate::check() { this->refresh_(true); }

void TsxUpdate::dump_config() { LOG_UPDATE_INTERVAL(this); }

void TsxUpdate::perform(bool force) {
  if (this->parent_ == nullptr)
    return;
  this->parent_->update_install();
  this->refresh_(true);
}

// Fill the entity from the state of the parent and publish it when it
// changed (or at the first call).
void TsxUpdate::refresh_(bool force) {
  if (this->parent_ == nullptr)
    return;
  if (force)
    this->parent_->update_status();
  const UpdateStatus &s = this->parent_->update_status();
  update::UpdateState st = static_cast<update::UpdateState>(this->parent_->update_state());
  update::UpdateInfo info;
  if (s.known()) {
    info.current_version = s.installed;
    info.latest_version = s.latest_version();
    info.title = s.title;
    info.summary = s.summary;
  }
  const update::UpdateInfo &old = this->update_info_;
  bool changed = !this->has_state() || st != this->state_ || info.current_version != old.current_version ||
                 info.latest_version != old.latest_version || info.title != old.title || info.summary != old.summary;
  if (!changed)
    return;
  bool became_available = st == update::UPDATE_STATE_AVAILABLE && this->state_ != update::UPDATE_STATE_AVAILABLE;
  this->state_ = st;
  this->update_info_ = info;
  this->publish_state();
  if (became_available && this->update_available_trigger_ != nullptr)
    this->update_available_trigger_->trigger(this->update_info_);
}

#endif

}  // namespace tsx_cards
}  // namespace esphome
