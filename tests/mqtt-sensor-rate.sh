#!/bin/sh
# Host test of the sensor rate of tsx-mqtt (dry run): the rate limit of the
# light sensor and of the distance (deadband, one state per THR_MIN_INTERVAL,
# heartbeat), the sensors that stay fast (presence, the light switch), and the
# sensor "Last boot" (a timestamp that does not jitter). The dry run reads the
# input line "tick" as one pass of the main loop. The test changes the state files between
# two ticks, and a fake /proc/uptime gives the time.
set -eu
. "$(dirname "$0")/lib/board.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
. "$(dirname "$0")/lib/paths.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/run" "$T/bl/x"
cat > "$T/bin/tsx-panelctl" <<'EOF'
#!/bin/sh
case "$1" in has) exit 1;; get) exit 1;; esac
EOF
chmod +x "$T/bin/tsx-panelctl"
printf 'NODE_ID=tsx-kiosk\nDEVICE_NAME=TSX test\n' > "$T/mqtt.conf"
N=0 F=0
ok() { N=$((N + 1)); }
fail() { F=$((F + 1)); echo "FAIL: $*"; }
up() { echo "$1 99.0" > "$T/uptime"; }
als() { printf 'report %s\nauto on\n' "$1" > "$T/run/als.state"; }
pres() { printf 'present %s\ndistance %s\n' "$1" "$2" > "$T/run/presence.state"; }
now() { echo "$1" > "$T/now"; }
step() { sleep 0.35; }   # the dry run takes a line when it is there. The pause keeps the state files and the ticks in order
run() { # run OUT: the input comes from stdin
	PATH=$T/bin:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T/run TSX_IDLED_STATE=$T/idled \
		TSX_BUTTONS_CONF=$T/none TSX_BUTTONS_BOARD_CONF=$T/none TSX_KIOSK_CONF=$(P etc/kiosk.conf) TSX_BACKLIGHT_DIR=$T/bl \
		TSX_PROC_UPTIME=$T/uptime TSX_MQTT_NOW_FILE=$T/now TSX_ALS_CONF=$T/none \
		sh "$(P usr/local/sbin/tsx-mqtt)" > "$1" 2>&1
}
published() { # published FILE TOPIC-END: the values that went out, one per line
	sed -n "s#^PUB (retained) tsx/tsx-kiosk/$2 ##p" "$1"
}
expect() { # expect NAME GOT WANT
	if [ "$2" = "$3" ]; then ok; else fail "$1: got [$(echo "$2" | tr '\n' ' ')] want [$(echo "$3" | tr '\n' ' ')]"; fi
}

echo "== the light sensor: deadband of 5 lux or 10 %, one state per 60 s, a heartbeat after 15 min =="
up 1000; als 100; pres on 800; now 1800000000
{
	step
	echo tick; step                      # same values: nothing
	up 1010; als 130; echo tick; step    # a big change, 10 s after the last state: held
	up 1065; echo tick; step             # 65 s: 130 goes out
	up 1130; als 133; echo tick; step    # +3 lux: inside the deadband
	up 1200; als 145; echo tick; step    # +15 lux (more than 10 % of 130): goes out
	up 2099; echo tick; step             # 899 s after the last state: nothing
	up 2100; echo tick; step             # 900 s: the heartbeat, the same value again
	up 2170; als 3; echo tick; step      # a drop of 142 lux: goes out
	up 2240; als 0; echo tick; step      # 3 lux less than the last state: inside the deadband
	up 2300; als 6; echo tick; step      # +3 from 3: inside the deadband, 5 lux is the floor
	up 2400; als 9; echo tick; step      # +6 from 3: goes out
} | run "$T/out1"
expect "illuminance states" "$(published "$T/out1" als/lux)" "$(printf '100\n130\n145\n145\n3\n9')"
expect "the light switch goes out once" "$(published "$T/out1" als_auto/state)" "ON"

echo "== a rate limit also holds a value that is beyond the deadband until the interval has passed =="
up 5000; als 100; now 1800000000
{
	step
	up 5030; als 400; echo tick; step
	up 5059; echo tick; step
	up 5060; echo tick; step
	up 5121; als 440; echo tick; step    # +40 lux, but 10 % of 400 is 40: not more than the deadband
	up 5200; als 450; echo tick; step    # +50: more than 40
} | run "$T/out2"
expect "illuminance: held, then sent at 60 s, a relative deadband" "$(published "$T/out2" als/lux)" "$(printf '100\n400\n450')"

echo "== the distance: 50 mm, the same rate, none is a value; presence goes out at once =="
up 6000; als 10; pres on 800
{
	step
	up 6100; pres on 830; echo tick; step   # +30 mm: inside the deadband
	up 6101; pres on 860; echo tick; step   # +60 mm but 1 s later... the interval counts from the last state (6000): goes out
	up 6110; pres off 860; echo tick; step  # presence: at once, the distance stays
	up 6120; pres off none; echo tick; step # none: 19 s after the last state, held
	up 6162; echo tick; step                # 61 s after 6101: none goes out
	up 6165; pres on 900; echo tick; step   # presence at once, the distance waits 60 s
	up 6230; echo tick; step                # 68 s: 900 goes out
} | run "$T/out3"
expect "distance states" "$(published "$T/out3" presence/distance)" "$(printf '800\n860\nnone\n900')"
expect "presence states" "$(published "$T/out3" presence/state)" "$(printf 'ON\nOFF\nON')"

echo "== Last boot: a timestamp, stable, new after a reboot =="
up 1000.4; now 1800001000
{
	step
	up 1000.9; now 1800001001; echo tick; step       # a second of jitter
	up 1015.2; now 1800001015; echo tick; step       # the clock and the uptime move together
	up 1030; now 1800001031; echo tick; step         # 1 s off again
	up 1030; now 1800001400; echo tick; step         # the clock stepped by 369 s (NTP sync): a new value
	up 12; now 1800001420; echo tick; step           # a reboot: a new value
} | run "$T/out4" || true
expect "Last boot states" "$(published "$T/out4" last_boot/state)" "$(printf '%s\n%s\n%s' "$(date -u -d @1800000000 '+%Y-%m-%dT%H:%M:%S+00:00')" "$(date -u -d @1800000370 '+%Y-%m-%dT%H:%M:%S+00:00')" "$(date -u -d @1800001408 '+%Y-%m-%dT%H:%M:%S+00:00')")"
sed -n 's#^PUB (retained) homeassistant/sensor/tsx-kiosk/last_boot/config ##p' "$T/out4" | head -n 1 > "$T/lbcfg"
[ "$(jq -r '[.name, .dev_cla, .ent_cat, .stat_t, .uniq_id] | join(" ")' < "$T/lbcfg")" = "Last boot timestamp diagnostic tsx/tsx-kiosk/last_boot/state tsx-kiosk_last_boot" ] && ok || fail "the Last boot config: $(cat "$T/lbcfg")"
grep -q 'sensor/tsx-kiosk/uptime' "$T/out4" && fail "the Uptime sensor is still announced" || ok

echo "== $N checks ok, $F failed =="
[ "$F" = 0 ] && echo "PASS mqtt-sensor-rate" || { echo "FAIL mqtt-sensor-rate"; exit 1; }
