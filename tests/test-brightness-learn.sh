#!/bin/bash
# Host test for the learning brightness curve (base/usr/local/lib/tsx/
# tsx_brightness.py, docs/adaptive-brightness.md). No compiler, no hardware.
#   1. the curve, the user points, the monotone correction, the file, the
#      reset and the Learner (tests/brightness-learn-check.py)
#   2. the daemon "als-daemon" for a board with a shell light service, against
#      fake files: it learns a held offset, writes /run/tsx/als-curve, removes
#      the offset, and forgets on the reset flag
#   3. the numbers come from the board: the start curve from als.conf, the top
#      level from panel-board.conf, else the state of tsx-idled, else the
#      backlight device. The files are those of the made-up board.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
MOD=$HERE/base/usr/local/lib/tsx/tsx_brightness.py
T=$(mktemp -d); trap 'rm -rf $T' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
python3 "$HERE/tests/brightness-learn-check.py" "$MOD" && ok "brightness-learn-check.py" || bad "brightness-learn-check.py"

echo "== als-daemon (the made-up board)"
. "$HERE/tests/lib/board.sh"
R=$T/run; mkdir -p $R $T/data
cp "$TSX_BOARD_DIR/als.conf" $T/als.conf
cp "$TSX_BOARD_DIR/panel-board.conf" $T/panel-board.conf
printf 'BRIGHTNESS_LEARN=on\n' > $T/kiosk.conf
printf 'lux 150\nraw 150\nreport 150\nlevel 9\nauto on\n' > $R/als.state
echo "on 9" > $T/idled.state
printf 'level 6\nbase 9\noffset -3\noverride 0\nmax 15\nmin 2\n' > $R/brightness.state
mkdir -p $T/bl/dev; echo 6 > $T/bl/dev/brightness; echo 31 > $T/bl/dev/max_brightness
export TSX_RUN_DIR=$R TSX_ALS_CONF=$T/als.conf TSX_KIOSK_CONF=$T/kiosk.conf TSX_PANEL_BOARD_CONF=$T/panel-board.conf \
	TSX_IDLED_STATE=$T/idled.state TSX_LEARN_FILE=$T/data/learn.json TSX_LEARN_TICK=0.1 TSX_LEARN_HOLD_S=0.5 TSX_LEARN_RELEASE_S=0.3 TSX_LEARN_GRACE_S=0.3 TSX_BACKLIGHT_DIR=$T/bl
python3 "$MOD" als-daemon > $T/daemon.log 2>&1 &
PID=$!
sleep 0.6; echo -3 > $R/brightness-offset   # a manual change after the start
for i in $(seq 1 60); do [ -s $R/als-curve ] && break; sleep 0.1; done
[ -s $R/als-curve ] && ok "als-curve written after a held offset" || bad "no als-curve"
curve=$(cat $R/als-curve 2>/dev/null)
echo "  curve: $curve"
echo "$curve" | grep -Eq '^[0-9]+:[0-9]+( [0-9]+:[0-9]+)*$' && ok "als-curve has the form the light service reads" || bad "als-curve form"
lvl=$(awk -v t=150 'BEGIN{RS=" "} {split($0,a,":"); if (a[1]+0<=t) {pl=a[1]; ps=a[2]} else if (!d) {d=1; nl=a[1]; ns=a[2]}} END{printf "%d", ps+(ns-ps)*(t-pl)/(nl-pl)+0.5}' $R/als-curve)
[ "$lvl" -ge 5 ] && [ "$lvl" -le 7 ] && ok "the curve gives about 6 at 150 lux ($lvl)" || bad "level at 150 lux: $lvl"
for i in $(seq 1 40); do [ ! -e $R/brightness-offset ] && break; sleep 0.1; done
[ ! -e $R/brightness-offset ] && ok "the offset goes after the curve is out" || bad "offset left"
[ -s $T/data/learn.json ] && ok "the point is in the file" || bad "no file"
touch $R/brightness-learn.reset
for i in $(seq 1 30); do [ ! -e $R/als-curve ] && break; sleep 0.1; done
[ ! -e $R/als-curve ] && [ ! -e $T/data/learn.json ] && ok "reset: als-curve and the file are gone" || bad "reset left files"
kill $PID 2>/dev/null; wait $PID 2>/dev/null
# an offset that was there before the start never learns
rm -f $R/als-curve $T/data/learn.json; echo -3 > $R/brightness-offset
python3 "$MOD" als-daemon > $T/daemon3.log 2>&1 &
PID=$!
sleep 2
[ ! -e $R/als-curve ] && [ ! -e $T/data/learn.json ] && [ -e $R/brightness-offset ] && ok "an offset from before the start is not learned" || bad "learned a stale offset"
kill $PID 2>/dev/null; wait $PID 2>/dev/null
rm -f $R/brightness-offset
# a light that keeps changing during the hold never makes a point
rm -f $R/als-curve $T/data/learn.json $R/brightness-offset
python3 "$MOD" als-daemon > $T/daemon4.log 2>&1 &
PID=$!
sleep 0.6; echo -3 > $R/brightness-offset
for i in $(seq 1 12); do
	if [ $((i % 2)) = 0 ]; then raw=1500; else raw=150; fi
	printf 'lux 150\nraw %s\nreport 150\nlevel 9\nauto on\n' $raw > $R/als.state.tmp; mv $R/als.state.tmp $R/als.state
	sleep 0.2
done
[ ! -e $R/als-curve ] && [ ! -e $T/data/learn.json ] && [ -e $R/brightness-offset ] && ok "a light that changes during the hold makes no point" || bad "learned in a changing light"
printf 'lux 150\nraw 150\nreport 150\nlevel 9\nauto on\n' > $R/als.state
for i in $(seq 1 40); do [ -s $R/als-curve ] && break; sleep 0.1; done
[ -s $R/als-curve ] && ok "the light is steady again: the held offset is learned" || bad "no point after the light settled"
kill $PID 2>/dev/null; wait $PID 2>/dev/null
rm -f $R/als-curve $T/data/learn.json $R/brightness-offset
# a new start loads a saved file
python3 - "$MOD" "$T/data/learn.json" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("tb", sys.argv[1]); tb = importlib.util.module_from_spec(spec); spec.loader.exec_module(tb)
c = tb.Curve([(0, 2), (5, 4), (20, 6), (80, 8), (300, 11), (1000, 13), (3000, 15)], 2, 15)
c.add_user_point(tb.lux_to_x(40), 3, 1)
open(sys.argv[2], "w").write(c.to_json())
PY
rm -f $R/brightness-offset
python3 "$MOD" als-daemon > $T/daemon2.log 2>&1 &
PID=$!
for i in $(seq 1 30); do [ -s $R/als-curve ] && break; sleep 0.1; done
[ -s $R/als-curve ] && ok "a start with a saved file publishes the curve" || bad "no curve after start"
kill $PID 2>/dev/null; wait $PID 2>/dev/null
echo "== the numbers come from the board =="
# curve_of: run the daemon until it publishes a curve (one held offset), print the curve
curve_of() {
	rm -f $R/als-curve $T/data/learn.json $R/brightness-offset
	python3 "$MOD" als-daemon > $T/daemon5.log 2>&1 &
	PID=$!
	sleep 0.6; echo -3 > $R/brightness-offset
	for i in $(seq 1 60); do [ -s $R/als-curve ] && break; sleep 0.1; done
	kill $PID 2>/dev/null; wait $PID 2>/dev/null
	cat $R/als-curve 2>/dev/null
	rm -f $R/als-curve $T/data/learn.json $R/brightness-offset
}
top_of() { tr ' ' '\n' | awk -F: '{ if ($2 + 0 > m + 0) m = $2 } END { print m + 0 }'; }
first_of() { tr ' ' '\n' | head -n 1; }
last_of() { tr ' ' '\n' | tail -n 1; }
state() { printf 'level 6\nbase 9\noffset -3\noverride 0\n%b' "$1" > $R/brightness.state; }
# A curve that goes above every top level of this part: the daemon cuts it at
# the top level, so the highest level of the published curve is the top level.
printf 'ALS_CURVE="0:2 5:4 20:6 80:8 300:11 1000:20 3000:40"\n' > $T/als.conf

# the top level: BACKLIGHT_MAX of panel-board.conf, then kiosk.conf (both cut at
# the device limit), then the state of tsx-idled, then the device, then 31
echo 31 > $T/bl/dev/max_brightness
state 'max 12\nmin 2\n'
c=$(curve_of); eq "$(echo "$c" | top_of)" 15 "the top level is BACKLIGHT_MAX of panel-board.conf (the state says 12)"
eq "$(echo "$c" | first_of)" "0:2" "the lowest level is BACKLIGHT_MIN of panel-board.conf"
sed -i '/^BACKLIGHT_MAX/d' $T/panel-board.conf; printf 'BACKLIGHT_MAX=14\n' >> $T/kiosk.conf
c=$(curve_of); eq "$(echo "$c" | top_of)" 14 "no board value: BACKLIGHT_MAX of kiosk.conf"
printf 'BACKLIGHT_MAX=40\n' >> $T/panel-board.conf
c=$(curve_of); eq "$(echo "$c" | top_of)" 31 "BACKLIGHT_MAX above the device limit: the device limit"
echo 13 > $T/bl/dev/max_brightness
c=$(curve_of); eq "$(echo "$c" | top_of)" 13 "a lower device limit: the device limit"
echo 31 > $T/bl/dev/max_brightness
sed -i '/^BACKLIGHT_MAX/d' $T/panel-board.conf $T/kiosk.conf
c=$(curve_of); eq "$(echo "$c" | top_of)" 12 "no BACKLIGHT_MAX: the max line of brightness.state"
state ''; echo 14 > $T/bl/dev/max_brightness
c=$(curve_of); eq "$(echo "$c" | top_of)" 14 "no BACKLIGHT_MAX and no state: max_brightness of the backlight device"
rm -rf $T/bl/dev; mkdir -p $T/bl
c=$(curve_of); eq "$(echo "$c" | top_of)" 31 "no source at all: the last resort is 31"
mkdir -p $T/bl/dev; echo 6 > $T/bl/dev/brightness; echo 31 > $T/bl/dev/max_brightness
cp "$TSX_BOARD_DIR/panel-board.conf" $T/panel-board.conf; state 'max 12\nmin 2\n'

# the start curve: ALS_CURVE of als.conf, else a log ramp from the lowest to the top level
cp "$TSX_BOARD_DIR/als.conf" $T/als.conf
c=$(curve_of); eq "$(echo "$c" | first_of)" "0:2" "ALS_CURVE of als.conf is the start curve (first point)"
eq "$(echo "$c" | last_of)" "3000:15" "ALS_CURVE of als.conf is the start curve (last point)"
sed -i '/^ALS_CURVE/d' $T/als.conf
# The user point goes where the ramp already has its level (dark, the lowest level),
# so it does not pull the end of the ramp down.
printf 'lux 0\nraw 0\nreport 0\nlevel 2\nauto on\n' > $R/als.state
state 'max 12\nmin 2\n'; sed -i 's/^level 6/level 2/' $R/brightness.state; echo 2 > $T/bl/dev/brightness
c=$(curve_of)
eq "$(echo "$c" | first_of)" "0:2" "no ALS_CURVE: the log ramp starts at BACKLIGHT_MIN"
eq "$(echo "$c" | last_of)" "500:15" "no ALS_CURVE: the log ramp ends at the top level at 500 lux"
n=$(echo "$c" | wc -w); [ "$n" -ge 4 ] && ok "no ALS_CURVE: the ramp has $n points" || bad "no ALS_CURVE: points: $c"
grep -q 'no ALS_CURVE' $T/daemon5.log && ok "no ALS_CURVE: one log line says so" || bad "no log line without ALS_CURVE"
printf 'AUTO_BRIGHTNESS_LUX=200\n' >> $T/panel-board.conf
c=$(curve_of); eq "$(echo "$c" | last_of)" "200:15" "no ALS_CURVE: AUTO_BRIGHTNESS_LUX of the board sets the end of the ramp"
rm -f $T/als.conf
c=$(curve_of); eq "$(echo "$c" | last_of)" "200:15" "no als.conf file: the log ramp too"

echo "== $N passed, $F failed"
[ $F = 0 ] && echo "PASS brightness learn" || exit 1
