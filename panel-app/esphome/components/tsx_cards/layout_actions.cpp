// layout_actions.cpp: the layout as Home Assistant actions (set_layout and
// get_layout of panel-app.yaml) and the "Layout hash" sensor. See
// docs/panel-app.md, "Layout from Home Assistant".
#include "tsx_cards.h"

#include <cerrno>
#include <cstdio>
#include <cstring>
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

std::string TsxCards::layout_target_() const {
  // The file of the user: the first file of the list (layout_files).
  return this->layout_files_.empty() ? std::string("/var/lib/tsx/panel-layout.json") : this->layout_files_.front();
}

bool TsxCards::set_layout_json(const std::string &text) {
  this->layout_set_error_.clear();
  if (this->layout_pid_ > 0) {
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
  std::string dir = this->run_dir_ + "/panel-app";
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
  if (this->layout_pid_ <= 0)
    return;
  int status = 0;
  pid_t r = waitpid(this->layout_pid_, &status, WNOHANG);
  if (r == 0)
    return;
  this->layout_pid_ = -1;
  unlink((this->run_dir_ + "/panel-app/layout.ha").c_str());
  if (r > 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0) {
    this->layout_status_ = "saved";
    ESP_LOGI(TAG, "set_layout: saved");
    // read the new file now, not at the next check
    this->reload_pending_ = true;
    this->reload_at_ = millis();
    return;
  }
  std::string first;
  FILE *f = fopen((this->run_dir_ + "/panel-app/layout.log").c_str(), "r");
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
