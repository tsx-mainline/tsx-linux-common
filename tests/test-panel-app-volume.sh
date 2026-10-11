#!/bin/bash
# Host test for panel-app/esphome/components/tsx_cards/volume_logic.h: the
# volume of the Sendspin player in the panel app (docs/panel-app.md, "Volume").
#  - the volume file of sendspin-cli: the volume and the mute, comments,
#    spaces, bad and missing values, a missing file
#  - the way out: at most one command per 250 ms, always the last value of a
#    drag, and the value that the panel shows until the player reports it
# It compiles C++, so run it only on a build host or in CI.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=$HERE/panel-app/esphome/components/tsx_cards
CXX=${CXX:-c++}
command -v "$CXX" >/dev/null 2>&1 || { echo "SKIPPED test-panel-app-volume: no $CXX"; exit 0; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

cat > "$T/main.cpp" <<'C'
#include <cstdio>
#include <string>
#include "volume_logic.h"
using namespace esphome::tsx_cards;
static int n = 0, f = 0;
static void check(bool c, const char *what) {
  if (c) { n++; printf("  ok: %s\n", what); } else { f++; printf("  FAIL: %s\n", what); }
}
int main(int argc, char **argv) {
  if (argc != 2)
    return 2;
  int v, m;
  puts("== the volume file ==");
  check(parse_player_volume("# Written by sendspin-cli. Edits are overwritten.\nvolume = 40\nmuted = false\n", v, m) && v == 40 && m == 0,
        "volume 40, not muted");
  check(parse_player_volume("muted = true\nvolume = 0\n", v, m) && v == 0 && m == 1, "volume 0, muted, any order");
  check(parse_player_volume("volume=100\nmuted=true", v, m) && v == 100 && m == 1, "no spaces, no last newline");
  check(parse_player_volume("volume   =  7 \r\nmuted =\tfalse\n", v, m) && v == 7 && m == 0, "spaces, a tab and a CR");
  check(!parse_player_volume("volume = 101\nmuted = false\n", v, m) && v == -1 && m == 0, "volume 101 is no volume");
  check(!parse_player_volume("volume = -5\n", v, m) && v == -1, "a negative volume is no volume");
  check(!parse_player_volume("volume = 4O\n", v, m), "a letter in the volume is no volume");
  check(!parse_player_volume("volume = 0040\n", v, m), "four digits are no volume");
  check(parse_player_volume("volume = 30\nmuted = yes\n", v, m) && v == 30 && m == -1, "a bad mute is unknown (-1)");
  check(parse_player_volume("volume = 30\n", v, m) && m == -1, "no mute line: unknown");
  check(!parse_player_volume("", v, m) && v == -1 && m == -1, "an empty file");
  check(!parse_player_volume("# volume = 30\n", v, m), "a comment is no volume");
  std::string path = std::string(argv[1]) + "/volume";
  check(!read_player_volume(path, v, m), "no file: no volume");
  FILE *fp = fopen(path.c_str(), "w");
  fputs("# Written by sendspin-cli. Edits are overwritten.\nvolume = 63\nmuted = true\n", fp);
  fclose(fp);
  check(read_player_volume(path, v, m) && v == 63 && m == 1, "read the file: 63, muted");

  puts("== the way out: rate and hold ==");
  PlayerSetting s;
  check(s.due(0) == -1 && s.shown(55, 0) == 55, "nothing wanted: nothing to send, the player value shows");
  s.want(40, 1000);
  check(s.due(1000) == 40, "the first value goes out at once");
  check(s.shown(55, 1010) == 40, "the panel shows 40 while the player still says 55");
  s.want(41, 1050);
  s.want(42, 1100);
  check(s.due(1100) == -1 && s.due(1249) == -1, "a drag: no second send within 250 ms");
  check(s.shown(40, 1200) == 42, "the panel shows the last value of the drag");
  check(s.due(1250) == 42, "after 250 ms the LAST value goes out (41 never does)");
  check(s.due(1600) == -1, "nothing waits: nothing more to send");
  check(s.shown(40, 1700) == 42, "the player still says 40: the panel holds 42");
  check(s.shown(42, 1800) == 42 && s.held == -1, "the player says 42: the hold ends");
  check(s.shown(30, 1900) == 30, "then a change of Music Assistant (30) shows at once");
  s.want(10, 5000);
  check(s.due(5000) == 10, "a later value goes out at once");
  check(s.shown(30, 7999) == 10, "the hold lasts up to 3 s");
  check(s.shown(30, 8000) == 30, "after 3 s with no answer the player value shows again");
  PlayerSetting w;
  w.want(1, 0xFFFFFF00u);
  check(w.due(0xFFFFFF00u) == 1 && w.shown(0, 0xFFFFFF10u) == 1 && w.shown(0, 0x00000BC0u) == 0, "the hold works across the wrap of millis()");
  printf("== test-panel-app-volume: %d ok, %d failed ==\n", n, f);
  return f ? 1 : 0;
}
C
"$CXX" -std=gnu++17 -Wall -Wextra -Werror -O1 -I"$SRC" -o "$T/vol" "$T/main.cpp" || { echo "FAIL: compile"; exit 1; }
"$T/vol" "$T"
