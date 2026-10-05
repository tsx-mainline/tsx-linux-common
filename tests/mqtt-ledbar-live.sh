#!/bin/sh
# Host test of tsx-mqtt while it runs (not dry-run): the LED bar light follows
# the bar. tsx-ledbard writes /run/tsx/ledbar.usb ("app", "bootloader" or no
# file). tsx-mqtt reads it with the real tsx-panelctl (has ledbar). Fake
# mosquitto_pub and mosquitto_sub stand in for the broker: mosquitto_pub logs
# each publish, mosquitto_sub only stays alive.
#   - bar attached at the start: the light is announced, its state published
#   - no bar at the start: the discovery topic is cleared, no LED bar state
#   - the bar is plugged in later: the light is announced, its state published
#   - the bar is removed later: the discovery topic and the retained state are cleared
#   - a bar in the bootloader: no light
#   - LEDBAR=no in hw.conf: no light, also with a bar attached, and no state topic
set -u
. "$(dirname "$0")/lib/board.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
. "$(dirname "$0")/lib/paths.sh"
T=$(mktemp -d)
DPID=
cleanup() { [ -n "$DPID" ] && kill "$DPID" 2>/dev/null; wait 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT INT TERM
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
mkdir -p "$T/bin" "$T/run" "$T/bl/x" "$T/none"
cat > "$T/bin/mosquitto_pub" <<EOS
#!/bin/sh
r=
while [ \$# -gt 0 ]; do
	case \$1 in
	-r) r=" (retained)";;
	-t) t=\$2; shift;;
	-m) m=\$2; shift;;
	esac
	shift
done
echo "PUB\$r \$t \$m" >> "$T/pubs"
EOS
printf '#!/bin/sh\nexec sleep 600\n' > "$T/bin/mosquitto_sub"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/tsx-ledbar"
printf '#!/bin/sh\nexec sh "%s" "$@"\n' "$(P usr/local/sbin/tsx-panelctl)" > "$T/bin/tsx-panelctl"
chmod +x "$T/bin"/*
printf 'want 0 0 40\n' > "$T/run/ledbar.state"
echo "on 17" > "$T/idled"
printf 'BROKER=127.0.0.1\nNODE_ID=tsx-kiosk\nDEVICE_NAME=TSX test\n' > "$T/mqtt.conf"

CFG="homeassistant/light/tsx-kiosk/ledbar/config"
# start [USBTEXT|NOFILE] [HWTEXT]: start tsx-mqtt and wait until it is connected
start() {
	: > "$T/pubs"; : > "$T/log"; rm -f "$T/run/ledbar.usb" "$T/run/hw.conf" "$T/run/mqtt/sub.fifo"
	[ "${1:-NOFILE}" = NOFILE ] || printf '%b' "$1" > "$T/run/ledbar.usb"
	[ -z "${2:-}" ] || printf '%b' "$2" > "$T/run/hw.conf"
	PATH=$T/bin:$PATH TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T/run TSX_IDLED_STATE=$T/idled \
		TSX_BUTTONS_CONF=$T/none TSX_BUTTONS_BOARD_CONF=$T/none TSX_KIOSK_CONF=$(P etc/kiosk.conf) TSX_BACKLIGHT_DIR=$T/bl \
		TSX_ALS_CONF=$T/none/als.conf TSX_ASOUND_DIR=$T/none TSX_MQTT_PUB_TIMEOUT=5 \
		sh "$(P usr/local/sbin/tsx-mqtt)" > "$T/log" 2>&1 &
	DPID=$!
	waitfor 'grep -q "tsx-mqtt: connected" "$T/log"' || { bad "tsx-mqtt did not connect: $(cat "$T/log")"; return 1; }
}
stop() { kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; DPID=; }
# until the shell test $1 is true, at most 10 s
waitfor() { w=0; while [ $w -lt 40 ] && ! eval "$1"; do sleep 0.25; w=$((w + 1)); done; eval "$1"; }
announced() { grep -q "^PUB (retained) $CFG {" "$T/pubs"; }
cleared() { grep -q "^PUB (retained) $CFG \$" "$T/pubs"; }
state_pubs() { grep -c '^PUB (retained) tsx/tsx-kiosk/ledbar/' "$T/pubs"; }
last_cfg() { grep "^PUB (retained) $CFG " "$T/pubs" | tail -n 1 | cut -c1-40; }
mark() { : > "$T/pubs"; }

echo "== bar attached at the start =="
start 'app\n' || exit 1
announced && ok "attached at start: the light is announced" || bad "attached at start: not announced: $(cat "$T/pubs")"
grep -q '^PUB (retained) tsx/tsx-kiosk/ledbar/state ON' "$T/pubs" && ok "attached at start: the state is published" || bad "attached at start: no state"
echo "== the bar is removed later =="
mark; rm -f "$T/run/ledbar.usb"
waitfor cleared && ok "removed: the discovery topic is cleared" || bad "removed: not cleared: $(cat "$T/pubs")"
for t in state brightness rgb; do
	waitfor "grep -q '^PUB (retained) tsx/tsx-kiosk/ledbar/$t \$' '$T/pubs'" && ok "removed: the retained $t topic is cleared" || bad "removed: $t not cleared"
done
grep -q "LED bar gone: light cleared" "$T/log" && ok "removed: log line" || bad "removed: no log line"
echo "== the bar is plugged in again =="
mark; echo app > "$T/run/ledbar.usb"
waitfor 'announced && grep -q "^PUB (retained) tsx/tsx-kiosk/ledbar/state ON" "$T/pubs"' && ok "plugged in: the light is announced and its state published" || bad "plugged in: $(cat "$T/pubs")"
grep -q "LED bar attached: light announced" "$T/log" && ok "plugged in: log line" || bad "plugged in: no log line"
echo "== a bar in the bootloader =="
mark; echo bootloader > "$T/run/ledbar.usb"
waitfor cleared && ok "bootloader: no light, the discovery topic is cleared" || bad "bootloader: not cleared: $(cat "$T/pubs")"
mark; echo app > "$T/run/ledbar.usb"
waitfor announced && ok "bootloader to application: the light is announced" || bad "app after bootloader: $(cat "$T/pubs")"
echo "== no change, no publish =="
mark; sleep 2
[ "$(grep -c "$CFG" "$T/pubs")" = 0 ] && ok "a bar that stays: no new discovery message" || bad "discovery repeats: $(cat "$T/pubs")"
echo "== the file is rewritten with the same word =="
mark; echo app > "$T/run/ledbar.usb"; sleep 1.5
[ "$(grep -c "$CFG" "$T/pubs")" = 0 ] && ok "same word: no new discovery message" || bad "same word: $(cat "$T/pubs")"
stop

echo "== no bar at the start =="
start NOFILE || exit 1
cleared && ok "no bar at start: the discovery topic is cleared" || bad "no bar at start: $(cat "$T/pubs")"
[ "$(state_pubs)" = 0 ] && ok "no bar at start: no LED bar state topic" || bad "no bar at start: state topics: $(grep ledbar/ "$T/pubs")"
echo "== the bar is plugged in later =="
mark; echo app > "$T/run/ledbar.usb"
waitfor 'announced && grep -q "^PUB (retained) tsx/tsx-kiosk/ledbar/state ON" "$T/pubs"' && ok "plugged in later: the light is announced and its state published" || bad "plugged in later: $(cat "$T/pubs")"
stop

echo "== LEDBAR=no with a bar attached =="
start 'app\n' 'LEDBAR=no\n' || exit 1
cleared && ok "LEDBAR=no: the discovery topic is cleared" || bad "LEDBAR=no: $(cat "$T/pubs")"
[ "$(state_pubs)" = 0 ] && ok "LEDBAR=no: no LED bar state topic" || bad "LEDBAR=no: state topics: $(grep ledbar/ "$T/pubs")"
mark; echo bootloader > "$T/run/ledbar.usb"; sleep 1.5; echo app > "$T/run/ledbar.usb"; sleep 1.5
grep -q "^PUB (retained) $CFG {" "$T/pubs" && bad "LEDBAR=no: the light is announced after a change of the file" || ok "LEDBAR=no: a change of the file does not announce the light"
[ "$(state_pubs)" = 0 ] && ok "LEDBAR=no: still no LED bar state topic" || bad "LEDBAR=no: state topics: $(grep ledbar/ "$T/pubs")"
stop

[ $fail = 0 ] && echo "PASS mqtt-ledbar-live"
exit $fail
