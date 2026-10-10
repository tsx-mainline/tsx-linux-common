#!/bin/bash
# Host test for panel-app/esphome/components/tsx_cards/hwconf.h: the reader of
# shell-style KEY=value files and has_light_sensor(). The settings overlay of
# the panel app shows its auto brightness row only when has_light_sensor() of
# /run/tsx/hw.conf is true. The test compiles C++, so run it only on a build
# host or in CI.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=$HERE/panel-app/esphome/components/tsx_cards
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
CXX=${CXX:-c++}
command -v "$CXX" >/dev/null 2>&1 || { echo "SKIPPED test-panel-app-hwconf: no $CXX"; exit 0; }

cat > "$T/main.cpp" <<'X'
#include <cstdio>
#include "hwconf.h"
using namespace esphome::tsx_cards;
int main(int argc, char **argv) {
  if (argc == 3) {
    std::string v;
    if (!conf_value(argv[1], argv[2], v))
      return 2;
    printf("%s\n", v.c_str());
    return 0;
  }
  printf("%s\n", has_light_sensor(argv[1]) ? "yes" : "no");
  return 0;
}
X
"$CXX" -std=gnu++20 -O1 -Wall -Werror -I"$SRC" -o "$T/hw" "$T/main.cpp" || { echo "FAIL: compile"; exit 1; }

echo "== has_light_sensor =="
light() { printf '%b' "$1" > "$T/hw.conf"; [ "$("$T/hw" "$T/hw.conf")" = "$2" ] && ok "$3" || bad "$3"; }
light 'LIGHT=yes\n' yes "LIGHT=yes: a sensor"
light 'ALS=yes\n' yes "ALS=yes: a sensor"
light 'MIC=no\nLIGHT="yes"\n' yes "a quoted yes"
light 'LIGHT=no\n' no "LIGHT=no: no sensor"
light 'ALS=no\nREASON=no sensor on this model\n' no "ALS=no: no sensor"
light 'MIC=no\nBT=no\n' no "no light key: no sensor"
light 'LIGHT=yes\nLIGHT=no\n' no "the last LIGHT line wins"
light 'LIGHTS=yes\nXLIGHT=yes\n' no "a longer key name is not LIGHT"
light 'LIGHT=on\n' no "only yes is a sensor"
rm -f "$T/hw.conf"
[ "$("$T/hw" "$T/hw.conf")" = no ] && ok "no hw.conf: no sensor" || bad "no hw.conf"

echo "== conf_value =="
printf 'CPUFREQ_BOOST_MS="1500"  # boost\nCPUFREQ_SCREEN_OFF=lowest\n' > "$T/board.conf"
[ "$("$T/hw" "$T/board.conf" CPUFREQ_BOOST_MS)" = 1500 ] && ok "quotes and a comment are removed" || bad "quoted value"
[ "$("$T/hw" "$T/board.conf" CPUFREQ_SCREEN_OFF)" = lowest ] && ok "a plain value" || bad "plain value"
"$T/hw" "$T/board.conf" CPUFREQ && bad "a key prefix matched" || ok "a key prefix does not match"

echo "== the overlay uses it =="
grep -q 'has_light_sensor(this->run_dir_ + "/hw.conf")' "$SRC/overlay.cpp" && ok "overlay.cpp reads hw.conf of the run folder" || bad "overlay.cpp does not call has_light_sensor"
awk '/if \(light_row\) \{/ {inside=1} inside && /Auto brightness/ {found=1} inside && /^  \}/ {inside=0} END {exit !found}' "$SRC/overlay.cpp" \
	&& ok "the auto brightness row is made only with a light sensor" || bad "the auto brightness row is not inside if (light_row)"
[ "$(grep -c 'Auto brightness' "$SRC/overlay.cpp")" = 1 ] && ok "one auto brightness text" || bad "more than one auto brightness text"

echo "== test-panel-app-hwconf: $N ok, $F failed =="
[ "$F" = 0 ]
