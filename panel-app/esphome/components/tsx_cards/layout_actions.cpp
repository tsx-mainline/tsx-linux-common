// layout_actions.cpp: the layout as Home Assistant actions (set_layout and
// get_layout of panel-app.yaml) and the "Layout hash" sensor. See
// docs/panel-app.md, "Layout from Home Assistant".
#include "tsx_cards.h"
#include "control.h"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "esphome/core/hal.h"
#include "esphome/core/log.h"

extern char **environ;

namespace esphome {
namespace tsx_cards {

static const char *const TAG = "tsx_cards.layout";
// The largest layout file that the app and tsx-layout-check accept.
static const size_t MAX_LAYOUT = 65536;
// The time that the app waits for the result of tsx-panelctl layout-install.
static const uint32_t LAYOUT_WAIT_MS = 30000;

std::string TsxCards::layout_target_() const {
  // The file of the user: the first file of the list (layout_files).
  return this->layout_files_.empty() ? std::string("/var/lib/tsx/panel-layout.json") : this->layout_files_.front();
}

bool TsxCards::set_layout_json(const std::string &text) {
  this->layout_set_error_.clear();
  if (this->layout_pid_ > 0 || this->layout_wait_until_ != 0) {
    this->layout_set_error_ = "a layout is being saved; try again in a few seconds";
    return false;
  }
  if (text.size() > MAX_LAYOUT) {
    this->layout_set_error_ = "the layout is larger than 65536 bytes";
    return false;
  }
  // The checks of the app first: an error comes back at once.
  Layout check;
  std::string error;
  std::vector<std::string> warnings;
  if (!parse_layout(text, check, error, warnings)) {
    this->layout_set_error_ = error;
    ESP_LOGW(TAG, "set_layout refused: %s", error.c_str());
    return false;
  }
  // tsx-layout-check checks it again (the same rules) and installs it
  // atomically. The app reads the new file when it changes.
  std::string dir = this->out_dir_.empty() ? this->run_dir_ + "/panel-app" : this->out_dir_;
  mkdir(dir.c_str(), 0755);
  std::string tmp = dir + "/.layout.ha.tmp", path = dir + "/layout.ha";
  int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  bool ok = fd >= 0 && fchmod(fd, 0600) == 0 && write(fd, text.data(), text.size()) == (ssize_t) text.size();
  if (fd >= 0)
    ok = close(fd) == 0 && ok;
  if (!ok || rename(tmp.c_str(), path.c_str()) != 0) {
    unlink(tmp.c_str());
    this->layout_set_error_ = std::string("cannot write the layout: ") + strerror(errno);
    return false;
  }
  if (!this->panelctl_.empty()) {
    // Not root: tsx-panelctl runs tsx-layout-check --install (as root) on
    // the fixed file layout.ha of the folder of the app, and writes the
    // result with the id of this request.
    this->layout_req_id_ = (int) (((long) ::time(nullptr) + this->layout_req_id_) % 999999) + 1;
    if (!this->panelctl_send_("layout-install " + std::to_string(this->layout_req_id_))) {
      this->layout_set_error_ = "cannot reach tsx-panelctl (the root helper)";
      return false;
    }
    this->layout_wait_until_ = millis() + LAYOUT_WAIT_MS;
    if (this->layout_wait_until_ == 0)
      this->layout_wait_until_ = 1;
    this->layout_status_ = "saving";
    ESP_LOGI(TAG, "set_layout: %u bytes, tsx-panelctl layout-install %d", (unsigned) text.size(),
             this->layout_req_id_);
    return true;
  }
  const char *bin = getenv("TSX_LAYOUT_CHECK_BIN");
  std::string check_bin = bin != nullptr && bin[0] != '\0' ? bin : "/usr/local/bin/tsx-layout-check";
  std::string log = dir + "/layout.log", target = this->layout_target_();
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_addopen(&fa, 1, log.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
  posix_spawn_file_actions_adddup2(&fa, 1, 2);
  std::vector<std::string> args = {check_bin, "--install", path, target};
  std::vector<char *> argv;
  for (auto &a : args)
    argv.push_back(const_cast<char *>(a.c_str()));
  argv.push_back(nullptr);
  pid_t pid;
  int err = posix_spawn(&pid, check_bin.c_str(), &fa, nullptr, argv.data(), environ);
  posix_spawn_file_actions_destroy(&fa);
  if (err != 0) {
    unlink(path.c_str());
    this->layout_set_error_ = std::string("cannot run tsx-layout-check: ") + strerror(err);
    return false;
  }
  this->layout_pid_ = pid;
  this->layout_status_ = "saving";
  ESP_LOGI(TAG, "set_layout: %u bytes, tsx-layout-check --install %s (pid %d)", (unsigned) text.size(),
           target.c_str(), (int) pid);
  return true;
}

void TsxCards::layout_loop_() {
  if (this->layout_wait_until_ != 0) {
    uint32_t now = millis();
    if (now - this->layout_poll_ < 250)
      return;
    this->layout_poll_ = now;
    std::string text;
    FILE *f = fopen((this->run_dir_ + "/panel-app/layout.result").c_str(), "r");
    if (f != nullptr) {
      char buf[1024];
      size_t n = fread(buf, 1, sizeof buf, f);
      text.assign(buf, n);
      fclose(f);
    }
    int rc = -1;
    std::string first;
    if (parse_layout_result(text, this->layout_req_id_, rc, first)) {
      this->layout_wait_until_ = 0;
      unlink((this->out_dir_ + "/layout.ha").c_str());
      if (rc == 0) {
        this->layout_status_ = "saved";
        ESP_LOGI(TAG, "set_layout: saved");
        this->reload_pending_ = true;
        this->reload_at_ = millis();
      } else {
        this->layout_status_ = "error: " + (first.empty() ? std::string("tsx-layout-check failed") : first);
        ESP_LOGW(TAG, "set_layout: %s", this->layout_status_.c_str());
      }
    } else if ((int32_t) (now - this->layout_wait_until_) >= 0) {
      this->layout_wait_until_ = 0;
      this->layout_status_ = "error: no answer from tsx-panelctl";
      ESP_LOGW(TAG, "set_layout: %s", this->layout_status_.c_str());
    }
    return;
  }
  if (this->layout_pid_ <= 0)
    return;
  int status = 0;
  pid_t r = waitpid(this->layout_pid_, &status, WNOHANG);
  if (r == 0)
    return;
  this->layout_pid_ = -1;
  std::string dir = this->out_dir_.empty() ? this->run_dir_ + "/panel-app" : this->out_dir_;
  unlink((dir + "/layout.ha").c_str());
  if (r > 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0) {
    this->layout_status_ = "saved";
    ESP_LOGI(TAG, "set_layout: saved");
    // read the new file now, not at the next check
    this->reload_pending_ = true;
    this->reload_at_ = millis();
    return;
  }
  std::string first;
  FILE *f = fopen((dir + "/layout.log").c_str(), "r");
  if (f != nullptr) {
    char buf[256];
    if (fgets(buf, sizeof buf, f) != nullptr)
      first = buf;
    fclose(f);
  }
  while (!first.empty() && (first.back() == '\n' || first.back() == '\r'))
    first.pop_back();
  this->layout_status_ = "error: " + (first.empty() ? std::string("tsx-layout-check failed") : first);
  ESP_LOGW(TAG, "set_layout: %s", this->layout_status_.c_str());
}

}  // namespace tsx_cards
}  // namespace esphome
