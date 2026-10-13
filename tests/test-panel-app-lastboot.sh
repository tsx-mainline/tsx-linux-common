#!/bin/bash
# Host test for panel-app/esphome/components/tsx_cards/lastboot.h: the sensor
# "Last boot" of the panel app (docs/panel-app.md, "Last boot").
#  - the text: ISO 8601 in UTC, from the wall clock minus the uptime
#  - no jitter: many reports with a second of noise give one text
#  - a step of the clock (NTP) and a reboot give a new text
#  - no value without a clock or an uptime
# It compiles C++, so run it only on a build host or in CI.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=$HERE/panel-app/esphome/components/tsx_cards
CXX=${CXX:-c++}
command -v "$CXX" >/dev/null 2>&1 || { echo "SKIPPED test-panel-app-lastboot: no $CXX"; exit 0; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

cat > "$T/main.cpp" <<'C'
#include <cstdio>
#include <cstdlib>
#include <set>
#include <string>
#include "lastboot.h"
using namespace esphome::tsx_cards;
static int n = 0, f = 0;
static void check(bool c, const char *what) {
  if (c) { n++; printf("  ok: %s\n", what); } else { f++; printf("  FAIL: %s\n", what); }
}
int main() {
  check(last_boot_text(0) == "1970-01-01T00:00:00+00:00", "the epoch is 1970-01-01T00:00:00+00:00");
  check(last_boot_text(1800000000) == "2027-01-15T08:00:00+00:00", "1800000000 is 2027-01-15T08:00:00+00:00");
  check(last_boot_text(1800000000.6) == "2027-01-15T08:00:01+00:00", "a fraction rounds to the nearest second");
  check(BOOT_JITTER_S == 30.0, "the jitter limit is 30 s (the same as the shim and tsx-mqtt)");
  LastBoot lb;
  check(lb.update(0, 100) == "", "no clock: no value");
  check(lb.update(1800001000, -1) == "", "no uptime: no value");
  check(lb.update(1800001000.0, 1000.4) == "2027-01-15T08:00:00+00:00", "the first value: clock minus uptime");
  std::set<std::string> seen;
  srand(7);
  for (int i = 0; i < 500; i++) {
    double noise = (rand() % 1200 - 600) / 1000.0;   // +-0.6 s
    seen.insert(lb.update(1800001000.0 + i * 0.37, 1000.4 + i * 0.37 + noise));
  }
  check(seen.size() == 1 && *seen.begin() == "2027-01-15T08:00:00+00:00", "500 reports with 0.6 s of noise give one text");
  check(lb.update(1800001400.0, 1000.0 + 0.0) == "2027-01-15T08:06:40+00:00", "a step of the clock by 400 s gives a new value");
  check(lb.update(1800001400.0 + 29.0, 1000.0) == "2027-01-15T08:06:40+00:00", "29 s of difference is no change");
  check(lb.update(1800001400.0 + 30.0, 1000.0) == "2027-01-15T08:07:10+00:00", "30 s of difference is a change");
  check(lb.update(1800002000.0, 8.0) == "2027-01-15T08:33:12+00:00", "a reboot gives a new value");
  check(lb.update(1800002000.0, -1) == "2027-01-15T08:33:12+00:00", "an unreadable uptime keeps the value");
  printf("== test-panel-app-lastboot: %d ok, %d failed ==\n", n, f);
  return f ? 1 : 0;
}
C
"$CXX" -std=gnu++17 -Wall -Wextra -Werror -O1 -I"$SRC" -o "$T/lb" "$T/main.cpp" || { echo "FAIL: compile"; exit 1; }
"$T/lb"
