#!/bin/bash
# End-to-end host test of the LED bar with the bar firmware TSX-LEDBAR 0.1.3
# (the 16 LEDs) on the ESPHome device: the zone effects of the light and the
# user-defined actions (esphome-ledbar-check.py). A real ESPHome client
# (aioesphomeapi, the version of Home Assistant 2026.9) talks to both front
# ends: tsx-esphome (VOICE=off) and the code path of the voice satellite
# (esphome-lva-harness.py, VOICE=on). The real tsx-panelctl daemon runs the
# commands. A fake tsx-ledbar stands in for the bar: "fw" prints the file
# $F/fw, and every other command goes to $F/cmds.log. A third server with
# firmware 0.1.2 must list no actions and no zone effects.
# The last parts follow the bar while the device runs (esphome-ledbar-live-check.py,
# on both front ends): the check plays Home Assistant (one connection, it reads the
# entity list again after each end of the connection) and tsx-ledbard (it writes
# /run/tsx/ledbar.usb and ledbar.fw). A bar that is attached at the start, a bar that
# goes and comes back, no bar at the start and a bar that comes later, a bar in the
# bootloader, a new bar firmware, and LEDBAR=no. Each change of the entity list must
# end the connection with an expected disconnect, and the device information must
# stay the same.
# The test needs the network only to fetch pinned, public packages (as
# test-esphome.sh, also the system libmpv). The test compiles nothing.
set -euo pipefail
# The made-up board for the scripts that read a board file.
. "$(dirname "$0")/lib/board.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
SHIM=$HERE/../ha/voice/shim
T=$(mktemp -d)
: > "$T/libtflite.so"
PIDS=
trap 'for p in $PIDS; do kill "$p" 2>/dev/null || true; done; [ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"' EXIT

# ---- pinned linux-voice-assistant source and the client (as test-esphome.sh)
LVA=1.1.15
LVA_SHA256=077696e60b57ae3a98aca3d49d1b9f9971ffd36d62f5c23b8603ccc4c9fcdbd8
CACHE=${TSX_TEST_CACHE:-/tmp/tsx-esphome-test-cache}
mkdir -p "$CACHE"
[ -s "$CACHE/lva-$LVA.tar.gz" ] || curl -fsSL -o "$CACHE/lva-$LVA.tar.gz" "https://github.com/OHF-Voice/linux-voice-assistant/archive/refs/tags/v$LVA.tar.gz"
echo "$LVA_SHA256  $CACHE/lva-$LVA.tar.gz" | sha256sum -c - >/dev/null
tar -C "$T" -xzf "$CACHE/lva-$LVA.tar.gz"
LVA_SRC=$T/linux-voice-assistant-$LVA
python3 -m venv "$T/venv"
"$T/venv/bin/pip" -q install --disable-pip-version-check --only-binary :all: \
	"aioesphomeapi==46.2.0" getmac netifaces2 zeroconf "websockets==12.0" python-mpv

# ---- fixtures: the state files, the fake bar, the real tsx-panelctl -----
F=$T/fixture
mkdir -p "$F/run/tsx" "$F/etc/tsx" "$F/sys/thermal" "$F/proc/asound" "$F/bin"
echo "want 10 20 30" > "$F/run/tsx/ledbar.state"
echo app > "$F/run/tsx/ledbar.usb"   # tsx-ledbard: a bar with its application is attached
echo "on 11" > "$F/run/tsx-idled.state"
echo 40000 > "$F/sys/thermal/temp"
printf 'BACKLIGHT_MAX=15\nKIOSK_URL="https://ha.example.org/"\n' > "$F/etc/kiosk.conf"
printf 'firmware TSX-LEDBAR [v0.1.3]\neffects yes\nleds yes\n' > "$F/fw13"
printf 'firmware TSX-LEDBAR [v0.1.2]\neffects yes\nleds no\n' > "$F/fw12"
cat > "$F/bin/tsx-ledbar" <<EOF
#!/bin/sh
if [ "\$1" = fw ]; then cat "\${TSX_TEST_FW:-$F/fw13}"; exit 0; fi
echo "tsx-ledbar \$*" >> "$F/cmds.log"
EOF
for b in tsx-keypad tsx-blank tsx-config tsx-als tsx-autoupdate; do
	printf '#!/bin/sh\necho "%s $*" >> "%s/cmds.log"\n' "$b" "$F" > "$F/bin/$b"
done
cat > "$F/bin/tsx-panelctl" <<EOF
#!/bin/sh
exec sh "$HERE/../base/usr/local/sbin/tsx-panelctl" "\$@"
EOF
chmod +x "$F"/bin/*
env PATH="$F/bin:$PATH" TSX_RUN_DIR="$F/run/tsx" TSX_IDLED_STATE="$F/run/tsx-idled.state" \
	TSX_BUTTONS_CONF="$F/etc/tsx/buttons.conf.missing" TSX_BUTTONS_BOARD_CONF="$F/etc/tsx/buttons-board.conf.missing" TSX_ALS_CONF="$F/etc/tsx/als.conf.missing" TSX_ASOUND_DIR="$F/proc/asound" \
	sh "$HERE/../base/usr/local/sbin/tsx-panelctl" > "$T/panelctl.log" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 30); do grep -q "listening on" "$T/panelctl.log" 2>/dev/null && break; sleep 0.1; done
grep -q "listening on" "$T/panelctl.log" || { echo "FAIL: tsx-panelctl did not start"; cat "$T/panelctl.log"; exit 1; }

# start_server KIND LOG PORT PANEL_NAME [ENV=VALUE...] (KIND standalone or voice)
start_server() {
	local kind=$1 log=$2 port=$3 pname=$4; shift 4
	local cmd
	case $kind in
	standalone) cmd=(-m tsx_panel.esphome_server --port "$port" --host 127.0.0.1 --no-zeroconf);;
	voice) cmd=("$HERE/esphome-lva-harness.py" "$port");;
	esac
	env PATH="$F/bin:$PATH" PYTHONPATH="$SHIM:$LVA_SRC" \
	TSX_RUN_DIR="$F/run/tsx" TSX_IDLED_STATE="$F/run/tsx-idled.state" \
	TSX_BUTTONS_CONF="$F/etc/tsx/buttons.conf.missing" TSX_BUTTONS_BOARD_CONF="$F/etc/tsx/buttons-board.conf.missing" TSX_KIOSK_CONF="$F/etc/kiosk.conf" \
	TSX_ALS_CONF="$F/etc/tsx/als.conf.missing" TSX_ASOUND_DIR="$F/proc/asound" \
	TSX_THERMAL_ZONE="$F/sys/thermal/temp" TSX_DEVTOOLS="127.0.0.1:1" \
	TSX_BOOT_VERBOSE_FLAG="$F/etc/tsx/boot-verbose" TSX_HA_TRANSPORT=esphome TSX_TFLITE_SO="$T/libtflite.so" \
	TSX_ESPHOME_RUN_CONF="$F/run/tsx/esphome.conf.missing" TSX_ESPHOME_KEY_FILE="$F/run/tsx/esphome.key.missing" \
	TSX_PANEL_NAME="$pname" TSX_ORIENTATION_FILE="$F/etc/tsx/orientation.missing" TSX_HA_API_KEY= \
	"$@" "$T/venv/bin/python3" "${cmd[@]}" > "$log" 2>&1 &
	PIDS="$PIDS $!"
}
wait_listening() {
	for _ in $(seq 1 80); do grep -q "listening on" "$1" 2>/dev/null && return 0; sleep 0.25; done
	echo "FAIL: $1: server did not start"; cat "$1"; exit 1
}

rc=0
# check_leds TITLE LOG: the commands that the actions and the light must give
check_leds() {
	sleep 0.5
	local want
	for want in "led R3 100 0 0" "led R1-R4 1 2 3" "side L 0 0 50" "fx fill 0 100 0 60" "fx split 100 0 0 0 0 100" \
		"clear" "led ALL 7 7 7" "fx chase 100 0 0 1500" "fx fill 100 0 0 50" "fx spectrum 10000 40"; do
		grep -qxF "tsx-ledbar $want" "$F/cmds.log" && echo "OK: $1: tsx-ledbar $want" || { echo "FAIL: $1: tsx-ledbar $want missing"; rc=1; }
	done
	# the turn on with a color and a brightness (one command of Home Assistant): ONE set, the scaled color
	[ "$(grep -c '^tsx-ledbar set ' "$F/cmds.log")" = 1 ] && grep -qxF "tsx-ledbar set 78 18 0" "$F/cmds.log" \
		&& echo "OK: $1: turn on with a color and a brightness: one set, the scaled color" \
		|| { echo "FAIL: $1: turn on with a color and a brightness: want one 'tsx-ledbar set 78 18 0', got: $(grep '^tsx-ledbar set ' "$F/cmds.log" | tr '\n' ';')"; rc=1; }
	grep -qwE 'R9|101|150|up' "$F/cmds.log" && { echo "FAIL: $1: a refused action reached tsx-ledbar"; rc=1; } || echo "OK: $1: no refused action reached tsx-ledbar"
	grep -q 'Unknown message type' "$2" && { echo "FAIL: $1: Unknown message type in $2"; rc=1; } || echo "OK: $1: no Unknown message type"
}

API_PORT=$((25000 + RANDOM % 5000))
echo "== tsx-esphome (VOICE=off), firmware 0.1.3 =="
start_server standalone "$T/server.log" "$API_PORT" Leds-Panel
wait_listening "$T/server.log"
: > "$F/cmds.log"
"$T/venv/bin/python3" "$HERE/esphome-ledbar-check.py" "$API_PORT" leds-panel --leds || rc=1
check_leds tsx-esphome "$T/server.log"

echo "== the voice satellite (VOICE=on), firmware 0.1.3 =="
start_server voice "$T/voice.log" "$((API_PORT + 1))" Leds-Voice
wait_listening "$T/voice.log"
: > "$F/cmds.log"
"$T/venv/bin/python3" "$HERE/esphome-ledbar-check.py" "$((API_PORT + 1))" leds-voice --leds || rc=1
check_leds "voice satellite" "$T/voice.log"

echo "== tsx-esphome, firmware 0.1.2 =="
start_server standalone "$T/server12.log" "$((API_PORT + 2))" Old-Panel TSX_TEST_FW="$F/fw12"
wait_listening "$T/server12.log"
"$T/venv/bin/python3" "$HERE/esphome-ledbar-check.py" "$((API_PORT + 2))" old-panel --no-leds || rc=1

# live_run KIND LOG PORT NAME MODE [HW.CONF text]: a server with its own run dir (the state
# files of the LED bar in it), and the same panelctl daemon for the commands
live_run() {
	local kind=$1 log=$2 port=$3 pname=$4 mode=$5 d="$F/live-$4/tsx"
	rm -rf "$F/live-$4"; mkdir -p "$d"
	cp "$F/run/tsx/ledbar.state" "$d/"
	[ "$mode" = later ] || echo app > "$d/ledbar.usb"
	[ -z "${6:-}" ] || printf '%b' "$6" > "$d/hw.conf"
	start_server "$kind" "$log" "$port" "$pname" TSX_RUN_DIR="$d" TSX_PANELCTL="$F/run/tsx/panelctl"
	wait_listening "$log"
	: > "$F/cmds.log"
	"$T/venv/bin/python3" "$HERE/esphome-ledbar-live-check.py" "$port" "$(echo "$pname" | tr 'A-Z' 'a-z')" "$d" --mode "$mode" || rc=1
}
n=$((API_PORT + 10))
for kind in standalone voice; do
	echo "== $kind: a bar at the start, then it goes and comes back =="
	live_run $kind "$T/live-follow-$kind.log" $n Live-Follow-$kind follow; n=$((n + 1))
	grep -q "tsx-ledbar set 100 0 0" "$F/cmds.log" && echo "OK: $kind: a light command reaches the bar after the bar came back" || { echo "FAIL: $kind: the light command did not reach the bar"; rc=1; }
	echo "== $kind: no bar at the start, a bar comes later =="
	live_run $kind "$T/live-later-$kind.log" $n Live-Later-$kind later; n=$((n + 1))
	grep -q "tsx-ledbar set 0 100 0" "$F/cmds.log" && echo "OK: $kind: a light command reaches a bar that came later" || { echo "FAIL: $kind: the light command did not reach the bar"; rc=1; }
	echo "== $kind: LEDBAR=no with a bar attached =="
	live_run $kind "$T/live-off-$kind.log" $n Live-Off-$kind hardoff 'LEDBAR=no\n'; n=$((n + 1))
	for l in "$T/live-follow-$kind.log" "$T/live-later-$kind.log" "$T/live-off-$kind.log"; do
		grep -q 'Traceback' "$l" && { echo "FAIL: $kind: Traceback in $l"; tail -n 30 "$l"; rc=1; }
		grep -q 'Unknown message type\|unhandled message' "$l" && { echo "FAIL: $kind: an unhandled message in $l"; grep 'Unknown message type\|unhandled message' "$l" | head -3; rc=1; }
	done
done

[ $rc = 0 ] && echo "PASS test-esphome-ledbar" || echo "FAIL test-esphome-ledbar"
exit $rc
