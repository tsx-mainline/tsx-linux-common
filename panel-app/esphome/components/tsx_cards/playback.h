// playback.h: does a sound card play now? For cpu.cpp (the lowest CPU
// frequency while the screen is off is only for a panel with no sound) and
// tests/test-panel-app-playback.sh. See docs/panel-app.md, "CPU speed".
#pragma once

#include <cstdio>
#include <cstring>
#include <glob.h>
#include <string>

namespace esphome {
namespace tsx_cards {

// True when a playback substream of a sound card runs: a status file
// DIR/card*/pcm*p/sub*/status with the line "state: RUNNING" or
// "state: DRAINING". DIR is normally /proc/asound. A closed, prepared or
// paused stream, a capture stream (pcm*c) and a missing DIR are false.
inline bool audio_playing(const std::string &dir) {
  glob_t g;
  std::string pattern = dir + "/card*/pcm*p/sub*/status";
  if (glob(pattern.c_str(), 0, nullptr, &g) != 0)
    return false;
  bool playing = false;
  for (size_t i = 0; i < g.gl_pathc && !playing; i++) {
    FILE *f = fopen(g.gl_pathv[i], "r");
    if (f == nullptr)
      continue;
    char line[128];
    while (fgets(line, sizeof line, f) != nullptr) {
      if (strncmp(line, "state:", 6) != 0)
        continue;
      const char *s = line + 6;
      while (*s == ' ' || *s == '\t')
        s++;
      playing = strncmp(s, "RUNNING", 7) == 0 || strncmp(s, "DRAINING", 8) == 0;
      break;
    }
    fclose(f);
  }
  globfree(&g);
  return playing;
}

}  // namespace tsx_cards
}  // namespace esphome
