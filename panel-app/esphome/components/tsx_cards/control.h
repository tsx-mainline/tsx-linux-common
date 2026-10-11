// control.h: the control interface of the panel app for the other services
// of the panel (docs/panel-app.md, "Control from the panel"). It needs no
// ESPHome header, so a host test (tests/test-panel-app-control.sh) can
// compile it.
//
// - Commands: tsx-panelctl (root) writes one file per command into
//   RUN/panel-app/control.d (a temporary file that starts with a dot, then a
//   rename). The app reads the folder twice a second, runs the commands in
//   the order of the file names and removes each file. A file has one line:
//     screen on|off          wake the screen, or turn it off
//     backlight P            the backlight level of the user, 1 to 100
//     lights on|off          the lights of the panel (panel_lights)
//     lights B R G BL        the lights on, brightness B (1 to 100), color
//                            R G BL (0 to 255 each)
//   The app refuses any other line and logs it.
// - Values: the app writes RUN/panel-app/screen.state (mode 644) when a value
//   changes. One "key value" pair on each line:
//     screen          on, dim or off
//     backlight       the level of the user, 1 to 100
//     dim-timeout     seconds (0 = never)
//     blank-timeout   seconds (0 = never)
//     dim-level       percent, 1 to 100
//     lights          on|off B R G BL (only with lights of the panel)
// - The SHA-256 of the layout text, for the "Layout hash" sensor and the
//   get_layout action.
// - The lines for the FIFO of tsx-panelctl, for a program that does not run
//   as root, and the result file of "layout-install".
#pragma once

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace esphome {
namespace tsx_cards {

struct ControlCmd {
  enum Kind : uint8_t { NONE = 0, SCREEN, BACKLIGHT, LIGHTS_ON_OFF, LIGHTS_SET };
  Kind kind{NONE};
  bool on{false};
  int value{0};
  int r{0}, g{0}, b{0};
};

// A number with 1 to 3 digits and nothing else, from lo to hi.
inline bool control_int(const std::string &s, int lo, int hi, int &out) {
  if (s.empty() || s.size() > 3)
    return false;
  int v = 0;
  for (char c : s) {
    if (c < '0' || c > '9')
      return false;
    v = v * 10 + (c - '0');
  }
  if (v < lo || v > hi)
    return false;
  out = v;
  return true;
}

// Parse one command line. Returns false for a line that is not one of the
// exact forms above.
inline bool parse_control_line(const std::string &line, ControlCmd &c) {
  std::vector<std::string> w;
  std::string cur;
  for (char ch : line) {
    if (ch == ' ') {
      if (!cur.empty())
        w.push_back(cur);
      cur.clear();
    } else if (ch == '\n' || ch == '\r') {
      continue;
    } else if ((unsigned char) ch < 0x20 || (unsigned char) ch > 0x7e) {
      return false;
    } else {
      cur += ch;
    }
  }
  if (!cur.empty())
    w.push_back(cur);
  c = ControlCmd();
  if (w.size() == 2 && w[0] == "screen" && (w[1] == "on" || w[1] == "off")) {
    c.kind = ControlCmd::SCREEN;
    c.on = w[1] == "on";
    return true;
  }
  if (w.size() == 2 && w[0] == "backlight" && control_int(w[1], 1, 100, c.value)) {
    c.kind = ControlCmd::BACKLIGHT;
    return true;
  }
  if (w.size() == 2 && w[0] == "lights" && (w[1] == "on" || w[1] == "off")) {
    c.kind = ControlCmd::LIGHTS_ON_OFF;
    c.on = w[1] == "on";
    return true;
  }
  if (w.size() == 5 && w[0] == "lights" && control_int(w[1], 1, 100, c.value) && control_int(w[2], 0, 255, c.r) &&
      control_int(w[3], 0, 255, c.g) && control_int(w[4], 0, 255, c.b)) {
    c.kind = ControlCmd::LIGHTS_SET;
    c.on = true;
    return true;
  }
  c = ControlCmd();
  return false;
}

// Take the command files of the folder: the first line of each regular file
// (at most 256 bytes), in the order of the file names. Each file is removed.
// A name that starts with a dot is a file that is not complete yet.
inline std::vector<std::string> take_control_lines(const std::string &dir) {
  std::vector<std::string> names, lines;
  DIR *d = opendir(dir.c_str());
  if (d == nullptr)
    return lines;
  for (dirent *e; (e = readdir(d)) != nullptr;) {
    if (e->d_name[0] != '.')
      names.push_back(e->d_name);
  }
  closedir(d);
  std::sort(names.begin(), names.end());
  for (const auto &n : names) {
    std::string path = dir + "/" + n;
    struct stat st;
    if (lstat(path.c_str(), &st) != 0)
      continue;
    if (S_ISREG(st.st_mode) && st.st_size <= 256) {
      FILE *f = fopen(path.c_str(), "r");
      if (f != nullptr) {
        char buf[260];
        if (fgets(buf, sizeof buf, f) != nullptr)
          lines.push_back(buf);
        else
          lines.push_back("");
        fclose(f);
      }
    } else {
      lines.push_back("(not a small regular file)");
    }
    unlink(path.c_str());
  }
  return lines;
}

// The text of screen.state. screen: 0 on, 1 dim, 2 off. lights: -1 = the
// panel has no lights, else 0 off or 1 on.
inline std::string screen_state_text(int screen, int backlight, int dim_s, int blank_s, int dim_pct, int lights,
                                     int bri, int r, int g, int b) {
  static const char *const NAMES[] = {"on", "dim", "off"};
  char buf[256];
  int n = snprintf(buf, sizeof buf, "screen %s\nbacklight %d\ndim-timeout %d\nblank-timeout %d\ndim-level %d\n",
                   NAMES[screen < 0 || screen > 2 ? 0 : screen], backlight, dim_s, blank_s, dim_pct);
  std::string out(buf, n > 0 ? (size_t) n : 0);
  if (lights >= 0) {
    snprintf(buf, sizeof buf, "lights %s %d %d %d %d\n", lights ? "on" : "off", bri, r, g, b);
    out += buf;
  }
  return out;
}

// ---- the root helper tsx-panelctl (docs/security.md) ----
// A program that does not run as root asks tsx-panelctl for the actions that
// need root: one line on its FIFO.

// The tsx-panelctl line for a key of panel.conf that the app sets, or "" for
// a key that tsx-panelctl does not take. The value must be digits.
inline std::string panelctl_config_line(const std::string &key, const std::string &value) {
  if (value.empty() || value.size() > 6 || value.find_first_not_of("0123456789") != std::string::npos)
    return "";
  if (key == "BLANK_TIMEOUT")
    return "blank-timeout " + value;
  if (key == "DIM_TIMEOUT")
    return "dim-timeout " + value;
  if (key == "DIM_LEVEL")
    return "dim-level " + value;
  return "";
}

// Write one line to the FIFO of tsx-panelctl. The open does not wait: with no
// daemon (no reader) it fails with ENXIO. err gets the reason of a failure.
inline bool fifo_send_line(const std::string &fifo, const std::string &line, std::string &err) {
  if (line.empty() || line.size() > 200 || line.find('\n') != std::string::npos) {
    err = "bad command line";
    return false;
  }
  struct stat st;
  if (lstat(fifo.c_str(), &st) != 0 || !S_ISFIFO(st.st_mode)) {
    err = "no FIFO " + fifo;
    return false;
  }
  int fd = open(fifo.c_str(), O_WRONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) {
    err = std::string("cannot open ") + fifo + ": " + strerror(errno);
    return false;
  }
  std::string text = line + "\n";
  bool ok = write(fd, text.data(), text.size()) == (ssize_t) text.size();
  if (!ok)
    err = std::string("cannot write ") + fifo + ": " + strerror(errno);
  close(fd);
  return ok;
}

// The result file of "layout-install ID" (tsx-panelctl): "id ID", "rc N"
// and the output of tsx-layout-check. True when the file is the result of
// the request id; rc and first (the first line of the output) are set then.
inline bool parse_layout_result(const std::string &text, int id, int &rc, std::string &first) {
  std::istringstream in(text);
  std::string line;
  int got_id = -1;
  rc = -1;
  first.clear();
  int n = 0;
  while (std::getline(in, line)) {
    n++;
    if (n == 1) {
      if (line.compare(0, 3, "id ") != 0)
        return false;
      got_id = atoi(line.c_str() + 3);
    } else if (n == 2) {
      if (line.compare(0, 3, "rc ") != 0)
        return false;
      rc = atoi(line.c_str() + 3);
    } else if (n == 3) {
      first = line;
    }
  }
  return n >= 2 && got_id == id && rc >= 0;
}

// SHA-256 (FIPS 180-4) of a text, as 64 lower-case hex digits.
inline std::string sha256_hex(const std::string &text) {
  static const uint32_t K[64] = {
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
  uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  std::string m = text;
  uint64_t bits = (uint64_t) text.size() * 8;
  m += (char) 0x80;
  while (m.size() % 64 != 56)
    m += (char) 0;
  for (int i = 7; i >= 0; i--)
    m += (char) ((bits >> (i * 8)) & 0xff);
  auto rotr = [](uint32_t x, int n) { return (x >> n) | (x << (32 - n)); };
  for (size_t off = 0; off < m.size(); off += 64) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
      w[i] = (uint32_t) (uint8_t) m[off + 4 * i] << 24 | (uint32_t) (uint8_t) m[off + 4 * i + 1] << 16 |
             (uint32_t) (uint8_t) m[off + 4 * i + 2] << 8 | (uint32_t) (uint8_t) m[off + 4 * i + 3];
    for (int i = 16; i < 64; i++) {
      uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; i++) {
      uint32_t S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      uint32_t ch = (e & f) ^ (~e & g);
      uint32_t t1 = hh + S1 + ch + K[i] + w[i];
      uint32_t S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
      uint32_t t2 = S0 + mj;
      hh = g;
      g = f;
      f = e;
      e = d + t1;
      d = c;
      c = b;
      b = a;
      a = t1 + t2;
    }
    h[0] += a;
    h[1] += b;
    h[2] += c;
    h[3] += d;
    h[4] += e;
    h[5] += f;
    h[6] += g;
    h[7] += hh;
  }
  char out[65];
  for (int i = 0; i < 8; i++)
    snprintf(out + 8 * i, 9, "%08x", (unsigned) h[i]);
  return std::string(out, 64);
}

}  // namespace tsx_cards
}  // namespace esphome
