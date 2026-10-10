// tsx_runtime.cpp: see tsx_runtime.h.
#include "tsx_runtime.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/stat.h>

#include "esphome/core/application.h"
#include "esphome/core/hal.h"
#include "esphome/core/helpers.h"
#include "esphome/core/log.h"
#include "esphome/components/api/api_server.h"

namespace esphome {
namespace tsx_runtime {

static const char *const TAG = "tsx_runtime";

// ESPHome device names: lowercase letters, digits and '-', 1 to 31 characters.
static bool valid_name(const std::string &s) {
  if (s.empty() || s.size() > 31 || s.front() == '-' || s.back() == '-')
    return false;
  for (char c : s)
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'))
      return false;
  return true;
}

void TsxRuntime::apply_identity() {
  // The application keeps a reference to the text, so it lives here.
  static std::string name, friendly;
  const char *n = getenv("TSX_PANEL_APP_NAME");
  const char *f = getenv("TSX_PANEL_APP_FRIENDLY_NAME");
  name = App.get_name().str();
  friendly = App.get_friendly_name().str();
  if (n != nullptr && n[0] != '\0') {
    if (valid_name(n))
      name = n;
    else
      ESP_LOGW(TAG, "TSX_PANEL_APP_NAME is not a valid device name (a-z, 0-9, '-', at most 31): kept %s",
               name.c_str());
  }
  if (f != nullptr && f[0] != '\0' && strlen(f) <= 120)
    friendly = f;
#ifdef ESPHOME_NAME_ADD_MAC_SUFFIX
  ESP_LOGW(TAG, "name_add_mac_suffix is on: the names of the environment are not used");
#else
  App.pre_setup(name.c_str(), name.size(), friendly.c_str(), friendly.size());
#endif
}

long long TsxRuntime::file_sig_() const {
  struct stat st;
  if (stat(this->key_file_.c_str(), &st) != 0)
    return 0;
  return (long long) st.st_mtim.tv_sec * 1000000007LL + st.st_mtim.tv_nsec + (long long) st.st_size * 131LL +
         (long long) st.st_ino * 7LL + 1;
}

// The key file holds the key in base64 (44 characters) and optional white
// space. The text of the key never goes to the log.
bool TsxRuntime::read_key_(std::array<uint8_t, 32> &out, const char *&why) {
  FILE *fp = fopen(this->key_file_.c_str(), "r");
  if (fp == nullptr) {
    why = "no key file";
    return false;
  }
  char buf[128];
  size_t n = fread(buf, 1, sizeof buf, fp);
  fclose(fp);
  std::string text;
  for (size_t i = 0; i < n; i++)
    if (buf[i] != ' ' && buf[i] != '\n' && buf[i] != '\r' && buf[i] != '\t')
      text += buf[i];
  uint8_t raw[40];
  size_t len = text.size() == 44 ? base64_decode(text, raw, sizeof raw) : 0;
  memset(buf, 0, sizeof buf);
  if (len != 32) {
    memset(raw, 0, sizeof raw);
    why = "the key file does not hold 32 bytes in base64";
    return false;
  }
  memcpy(out.data(), raw, 32);
  memset(raw, 0, sizeof raw);
  why = "";
  return true;
}

void TsxRuntime::apply_key_(bool initial) {
  std::array<uint8_t, 32> key;
  const char *why = "";
  bool ok = this->read_key_(key, why);
  if (!ok) {
    if (!initial && !this->from_file_)
      return;  // still no key: keep the random key
    random_bytes(key.data(), key.size());
  }
  bool changed = initial || key != this->psk_ || ok != this->from_file_;
  this->psk_ = key;
  key.fill(0);
  this->from_file_ = ok;
  this->why_ = why;
  if (!changed)
    return;
  if (api::global_api_server != nullptr)
    api::global_api_server->set_noise_psk(this->psk_.data());
  if (ok)
    ESP_LOGI(TAG, "API encryption key from %s", this->key_file_.c_str());
  else
    ESP_LOGE(TAG, "%s (%s): Home Assistant cannot connect. Set the API encryption key of the panel.", why,
             this->key_file_.c_str());
  if (!initial && api::global_api_server != nullptr) {
    // A client with the old key must connect again with the new one.
    for (auto &client : api::global_api_server->active_clients())
      client->on_disconnect_response();
    ESP_LOGI(TAG, "API key changed: closed the connections");
  }
}

void TsxRuntime::setup() {
  this->sig_ = this->file_sig_();
  this->apply_key_(true);
  this->last_check_ = millis();
}

void TsxRuntime::loop() {
  uint32_t now = millis();
  if (now - this->last_check_ < 5000)
    return;
  this->last_check_ = now;
  long long sig = this->file_sig_();
  if (sig == this->sig_)
    return;
  this->sig_ = sig;
  this->apply_key_(false);
}

void TsxRuntime::dump_config() {
  ESP_LOGCONFIG(TAG,
                "TSX run time:\n"
                "  Name: %s\n"
                "  Friendly name: %s\n"
                "  MAC: %s\n"
                "  Key file: %s\n"
                "  Key: %s",
                App.get_name().c_str(), App.get_friendly_name().c_str(), get_mac_address_pretty().c_str(),
                this->key_file_.c_str(), this->from_file_ ? "from the file" : this->why_);
}

}  // namespace tsx_runtime
}  // namespace esphome
