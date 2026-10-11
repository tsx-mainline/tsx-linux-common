#!/bin/bash
# Host test for panel-app/esphome/components/tsx_cards/runstate.h: the state
# files that the panel app writes for the other services of the panel.
#  - the screen state in the file and the format of tsx-idled: tsx-autoupdate
#    installs only while it says "blank"
#  - the app state: tsx-autoupdate checks it after an update reboot
# The test writes the files with the code of the app and reads them with the
# real tsx-autoupdate. It compiles C++, so run it only on a build host or in CI.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=$HERE/panel-app/esphome/components/tsx_cards
AU=$HERE/autoupdate/usr/local/sbin/tsx-autoupdate
. "$HERE/tests/lib/board.sh"
T=$(mktemp -d)
APP=
cleanup() { [ -z "$APP" ] || kill "$APP" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
CXX=${CXX:-c++}
command -v "$CXX" >/dev/null 2>&1 || { echo "SKIPPED test-panel-app-state: no $CXX"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIPPED test-panel-app-state: no jq"; exit 0; }

cat > "$T/main.cpp" <<'C'
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "runstate.h"
using namespace esphome::tsx_cards;
// st idle PATH LIT RAW | st app PATH PID FIRST HA_AT HA_ON | st text LIT RAW
int main(int argc, char **argv) {
  if (argc == 5 && !strcmp(argv[1], "idle"))
    return write_file_atomic(argv[2], idle_state_text(atoi(argv[3]) != 0, atoi(argv[4]))) ? 0 : 1;
  if (argc == 7 && !strcmp(argv[1], "app"))
    return write_file_atomic(argv[2], app_state_text(atol(argv[3]), 1000, atol(argv[4]), atol(argv[5]),
                                                     atoi(argv[6]) != 0)) ? 0 : 1;
  if (argc == 4 && !strcmp(argv[1], "text")) {
    fputs(idle_state_text(atoi(argv[2]) != 0, atoi(argv[3])).c_str(), stdout);
    return 0;
  }
  return 2;
}
C
"$CXX" -std=gnu++20 -O1 -Wall -Werror -I"$SRC" -o "$T/st" "$T/main.cpp" || { echo "FAIL: compile"; exit 1; }

echo "== the screen state (the tsx-idled format) =="
[ "$("$T/st" text 1 130)" = "on 130" ] && ok "on: on <level>" || bad "on: $("$T/st" text 1 130)"
[ "$("$T/st" text 1 7)" = "on 7" ] && ok "dim: on <level>" || bad "dim"
[ "$("$T/st" text 0 0)" = "blank" ] && ok "off: blank" || bad "off: $("$T/st" text 0 0)"
[ "$("$T/st" text 1 -1)" = "on none" ] && ok "no backlight: on none" || bad "no backlight"
[ "$("$T/st" text 0 -1)" = "on none" ] && ok "no backlight, never blank" || bad "no backlight while off"

idle() {
	PATH="$T/bin:$PATH" TSX_IDLED_STATE="$T/tsx-idled.state" TSX_BACKLIGHT_CLASS="$T/bl" \
		TSX_RUN_DIR="$T/run" TSX_STATE_DIR="$T/state" TSX_LOG="$T/au.log" sh "$AU" __is_idle
}
"$T/st" idle "$T/tsx-idled.state" 1 130
idle && bad "the screen is on, but tsx-autoupdate sees idle" || ok "screen on: not idle for tsx-autoupdate"
"$T/st" idle "$T/tsx-idled.state" 0 0
idle && ok "screen off: idle for tsx-autoupdate" || bad "screen off: not idle for tsx-autoupdate"
[ ! -e "$T/tsx-idled.state.tmp" ] && ok "no temporary file left" || bad "the temporary file stays"
"$T/st" idle "$T/none/tsx-idled.state" 0 0 && bad "a write into a missing folder succeeded" || ok "a write into a missing folder fails"

echo "== the app state and the health check after an update reboot =="
mkdir -p "$T/bin" "$T/run" "$T/state" "$T/initd"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/rc-service"; chmod +x "$T/bin/rc-service"
: > "$T/initd/tsx-panel-app"
# The service is in the default runlevel, so the health check covers the app.
mkdir -p "$T/runlevels/default"; ln -s "$T/initd/tsx-panel-app" "$T/runlevels/default/tsx-panel-app"
printf 'ENABLED=1\nWINDOW=03:00-05:00\nREBOOT=auto\nHEALTH_TIMEOUT=0\n' > "$T/au.conf"
health() {  # health MARKER-HA
	printf 'panel_app_ha %s\n' "$1" > "$T/state/reboot-marker"
	PATH="$T/bin:$PATH" TSX_AUTOUPDATE_CONF="$T/au.conf" TSX_RUN_DIR="$T/run" TSX_STATE_DIR="$T/state" \
		TSX_LOG="$T/au.log" TSX_INITD="$T/initd" TSX_RUNLEVELS="$T/runlevels" TSX_BUILD_ID_FILE="$T/none" sh "$AU" healthcheck >/dev/null 2>&1
	jq -r .health "$T/run/update.json"
}
sleep 300 & APP=$!
"$T/st" app "$T/run/panel-app.state" "$APP" 0 0 0
[ "$(sed -n 1p "$T/run/panel-app.state")" = "pid $APP" ] && ok "the state names the process" || bad "state: $(cat "$T/run/panel-app.state")"
[ "$(health off)" = "FAILED: panel app drew no frame (after 0 s)" ] && ok "before the first frame: FAILED" || bad "no frame: $(jq -r .health "$T/run/update.json")"
"$T/st" app "$T/run/panel-app.state" "$APP" 1001 0 0
[ "$(health off)" = OK ] && ok "first frame, no Home Assistant before the update: OK" || bad "first frame: $(jq -r .health "$T/run/update.json")"
[ "$(health on)" = "FAILED: panel app not connected to Home Assistant (after 0 s)" ] && ok "Home Assistant before the update and none now: FAILED" || bad "no HA"
"$T/st" app "$T/run/panel-app.state" "$APP" 1001 1012 1
[ "$(health on)" = OK ] && ok "first frame and Home Assistant: OK" || bad "full: $(jq -r .health "$T/run/update.json")"
grep -qx 'ha on' "$T/run/panel-app.state" && ok "the state says ha on" || bad "ha line"
kill "$APP"; wait "$APP" 2>/dev/null || true; APP=
case $(health on) in "FAILED: panel app process "*" not running (after 0 s)") ok "the app process is gone: FAILED";; *) bad "dead app: $(jq -r .health "$T/run/update.json")";; esac

echo "== the app writes the files =="
grep -q 'this->write_idle_state_(raw);' "$SRC/screen.cpp" && ok "each backlight write updates the screen state" || bad "write_backlight_ does not write the screen state"
grep -q 'getenv("TSX_IDLED_STATE")' "$SRC/screen.cpp" && ok "TSX_IDLED_STATE sets the file" || bad "no TSX_IDLED_STATE"
grep -q '"/run/tsx-idled.state"' "$SRC/tsx_cards.h" && ok "the default is the file of tsx-idled" || bad "the default file differs from tsx-idled"
[ "$(grep -c 'this->write_app_state_();' "$SRC/tsx_cards.cpp")" = 2 ] && ok "the first frame and the Home Assistant connection update the app state" || bad "write_app_state_ calls in tsx_cards.cpp"
grep -q 'out_path_("panel-app.state")' "$SRC/screen.cpp" && grep -q 'this->run_dir_ + "/panel-app.state"' "$SRC/control.cpp" \
	&& ok "the app state is panel-app.state of the run folder (or of the folder of the app)" || bad "app state file name"
grep -q 'getenv("TSX_PANEL_APP_OUT_DIR")' "$SRC/screen.cpp" && grep -q 'out_dir_ + "/idled.state"' "$SRC/screen.cpp" \
	&& ok "TSX_PANEL_APP_OUT_DIR moves the state files into the folder of the app" || bad "no TSX_PANEL_APP_OUT_DIR"

echo "== test-panel-app-state: $N ok, $F failed =="
[ "$F" = 0 ]
