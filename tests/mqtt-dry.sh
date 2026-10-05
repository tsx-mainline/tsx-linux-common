#!/bin/sh
# Host test of tsx-mqtt in dry-run mode: discovery JSON (jq), state mapping,
# command handling. tsx-mqtt does not touch the hardware: every command goes to
# tsx-panelctl, which is a stub here that logs the calls.
set -eu
# The made-up board for the scripts that read a board file. Its buttons-board.conf
# has seven keys.
. "$(dirname "$0")/lib/board.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
. "$(dirname "$0")/lib/paths.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin" "$T/run" "$T/bl/x"
# the stub of tsx-panelctl: the LED bar and the key LEDs are there, `send` logs, `get volume` has no value
cat > "$T/bin/tsx-panelctl" <<'EOF'
#!/bin/sh
case "$1" in
has) case "$2" in ledbar|keyleds) exit 0;; *) exit 1;; esac;;
get) exit 1;;
send) echo "CALL tsx-panelctl $*" >&2;;
esac
EOF
chmod +x "$T/bin/tsx-panelctl"
printf 'want 0 0 40\nlast 0 0 40\nout 0 0 40\n' > "$T/run/ledbar.state"
# The key LEDs show LED_BLANK (24) on a blank screen. The light reports the awake level (128).
printf 'screen blank\nleds yes\nled 24 blank\nled_awake 128 day\nled_blank 24\nlast prog2 short 12:00:01\n' > "$T/run/buttons.state"
echo "on 17" > "$T/idled"; echo 0 > "$T/bl/x/brightness"
echo 120 > "$T/run/blank-timeout"; date +%s > "$T/run/last-input"
printf '%s' '{"installed_version":"abc123","latest_version":"abc123+2pending","title":"TSX test packages","release_summary":"musl (1.2.5-r0 -> 1.2.5-r1)","in_progress":false}' > "$T/run/update-ha-state.json"
printf 'NODE_ID=tsx-kiosk\nDEVICE_NAME=TSX test\n' > "$T/mqtt.conf"
printf '%s\n' 'tsx/tsx-kiosk/ledbar/rgb/set 255,0,0' 'tsx/tsx-kiosk/ledbar/brightness/set 128' \
	'tsx/tsx-kiosk/ledbar/set ON' 'tsx/tsx-kiosk/ledbar/set OFF' 'tsx/tsx-kiosk/key_leds/brightness/set 40' \
	'tsx/tsx-kiosk/key_leds/set OFF' 'tsx/tsx-kiosk/screen/set OFF' 'tsx/tsx-kiosk/backlight/set 30' 'tsx/tsx-kiosk/bogus/set x' \
	'tsx/tsx-kiosk/update/set INSTALL' 'tsx/tsx-kiosk/blank_timeout/set 600.0' 'tsx/tsx-kiosk/blank_timeout/set 99999' |
PATH=$T/bin:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T/run TSX_IDLED_STATE=$T/idled \
	TSX_BUTTONS_CONF=$(P etc/tsx/buttons.conf) TSX_BUTTONS_BOARD_CONF=$TSX_BOARD_DIR/buttons-board.conf \
	TSX_KIOSK_CONF=$(P etc/kiosk.conf) TSX_PANEL_BOARD_CONF=$TSX_BOARD_DIR/panel-board.conf TSX_BACKLIGHT_DIR=$T/bl \
	TSX_MQTT_PREV_KEY="prog1 short 11:59:00" sh "$(P usr/local/sbin/tsx-mqtt)" > "$T/out" 2>&1
sleep 0.3   # let the backgrounded "tsx-autoupdate now &" (update/set) finish logging
fail=0
chk() { grep -qF -- "$1" "$T/out" || { echo "FAIL: missing: $1"; fail=1; }; }
n=0; grep '/config ' "$T/out" | while read -r _ _ t j; do echo "$j" | jq -e . >/dev/null || { echo "FAIL: bad JSON $t"; exit 1; }; done
n=$(grep -c '/config ' "$T/out"); [ "$n" = 28 ] || { echo "FAIL: $n discovery configs, want 28 (the 7 keys of the board layer give 21)"; fail=1; }
chk 'PUB (retained) tsx/tsx-kiosk/ledbar/state ON'
chk 'PUB (retained) tsx/tsx-kiosk/ledbar/brightness 102'
chk 'PUB (retained) tsx/tsx-kiosk/ledbar/rgb 0,0,255'
chk 'PUB (retained) tsx/tsx-kiosk/key_leds/brightness 128'
chk 'PUB (retained) tsx/tsx-kiosk/screen/state ON'
chk 'PUB (retained) tsx/tsx-kiosk/backlight/state 17'
chk 'CALL tsx-panelctl send ledbar set 40 0 0'
chk 'CALL tsx-panelctl send ledbar set 50 0 0'
chk 'CALL tsx-panelctl send ledbar off'
chk 'CALL tsx-panelctl send keypad led 40'
chk 'CALL tsx-panelctl send keypad led off'
chk 'CALL tsx-panelctl send blank on'
chk 'PUB tsx/tsx-kiosk/key/prog2 {"event_type":"short"}'
chk 'PUB tsx/tsx-kiosk/trigger/prog2/short short'
chk 'PUB (retained) tsx/tsx-kiosk/update/state {"installed_version":"abc123","latest_version":"abc123+2pending","title":"TSX test packages","release_summary":"musl (1.2.5-r0 -> 1.2.5-r1)","in_progress":false}'
chk 'CALL tsx-panelctl send update-install'
chk 'PUB (retained) tsx/tsx-kiosk/blank_timeout/state 120'
chk 'PUB (retained) tsx/tsx-kiosk/touched_recently/state ON'
chk 'CALL tsx-panelctl send blank-timeout 600'
chk 'CALL tsx-panelctl send backlight 15'
grep -q 'blank-timeout 99999' "$T/out" && { echo "FAIL: blank timeout above 86400 accepted"; fail=1; }
[ "$(grep -c 'CALL tsx-panelctl send ledbar' "$T/out")" = 3 ] || { echo "FAIL: ON after brightness must not send again"; fail=1; }
# the base system sets the backlight (tsx-panelctl backlight), so tsx-mqtt writes no file and no device
[ ! -e "$T/run/brightness" ] || { echo "FAIL: tsx-mqtt wrote the brightness override itself"; fail=1; }
[ "$(cat "$T/bl/x/brightness")" = 0 ] || { echo "FAIL: tsx-mqtt wrote the backlight device itself"; fail=1; }
grep -qE 'CALL (tsx-ledbar|tsx-keypad|tsx-blank|tsx-als|tsx-config|amixer)' "$T/out" && { echo "FAIL: tsx-mqtt called a hardware tool directly"; fail=1; }
grep -nE '^[[:space:]]*(tsx-ledbar|tsx-keypad|tsx-blank|tsx-als|amixer)[[:space:]]|[;&|][[:space:]]*(tsx-ledbar|tsx-keypad|tsx-blank|tsx-als|amixer)[[:space:]]' "$(P usr/local/sbin/tsx-mqtt)" | grep -v '^[0-9]*:#' && { echo "FAIL: tsx-mqtt source runs a hardware tool"; fail=1; }
# the keys: the seven keys of the board layer, each once. A key of buttons.conf is added, and a
# key with a board name is the same key
nk=$(grep -c 'homeassistant/event/tsx-kiosk/key_.*/config {' "$T/out")
[ "$nk" = 7 ] || { echo "FAIL: $nk key events with the template, want the 7 keys of the board layer"; fail=1; }
printf 'button extra KEY_F21\nbutton prog1 KEY_F22\n' > "$T/buttons-more.conf"
PATH=$T/bin:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T/run TSX_IDLED_STATE=$T/idled \
	TSX_BUTTONS_CONF=$T/buttons-more.conf TSX_BUTTONS_BOARD_CONF=$TSX_BOARD_DIR/buttons-board.conf \
	TSX_KIOSK_CONF=$(P etc/kiosk.conf) TSX_BACKLIGHT_DIR=$T/bl sh "$(P usr/local/sbin/tsx-mqtt)" < /dev/null > "$T/outkeys" 2>&1
nk=$(grep -c 'homeassistant/event/tsx-kiosk/key_.*/config {' "$T/outkeys")
[ "$nk" = 8 ] && grep -q 'homeassistant/event/tsx-kiosk/key_extra/config {' "$T/outkeys" \
	|| { echo "FAIL: $nk key events with an extra key in buttons.conf, want 8"; fail=1; }
# a board with keys and no key LEDs: the keys stay, the Key LEDs light goes
printf '#!/bin/sh\ncase "$1" in has) exit 1;; esac\n' > "$T/bin-nokl-panelctl"; mkdir -p "$T/bin-nokl"
cp "$T/bin-nokl-panelctl" "$T/bin-nokl/tsx-panelctl"; chmod +x "$T/bin-nokl/tsx-panelctl"
PATH=$T/bin-nokl:/usr/bin:/bin TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T/run TSX_IDLED_STATE=$T/idled \
	TSX_BUTTONS_CONF=$(P etc/tsx/buttons.conf) TSX_BUTTONS_BOARD_CONF=$TSX_BOARD_DIR/buttons-board.conf \
	TSX_KIOSK_CONF=$(P etc/kiosk.conf) TSX_BACKLIGHT_DIR=$T/bl sh "$(P usr/local/sbin/tsx-mqtt)" < /dev/null > "$T/outnokl" 2>&1
grep -qx 'PUB (retained) homeassistant/light/tsx-kiosk/key_leds/config ' "$T/outnokl" || { echo "FAIL: no key LEDs: the light is not cleared"; fail=1; }
[ "$(grep -c 'homeassistant/event/tsx-kiosk/key_.*/config {' "$T/outnokl")" = 7 ] || { echo "FAIL: no key LEDs: the key events must stay"; fail=1; }
# a panel without a LED bar tool, front keys and eMMC wear: those entities are
# not announced, and an older discovery topic of them is cleared
mkdir -p "$T/bin-bare"
PATH=$T/bin-bare:/usr/bin:/bin TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T/run TSX_IDLED_STATE=$T/idled \
	TSX_BUTTONS_CONF=$T/none TSX_BUTTONS_BOARD_CONF=$T/none TSX_KIOSK_CONF=$(P etc/kiosk.conf) TSX_BACKLIGHT_DIR=$T/bl \
	sh "$(P usr/local/sbin/tsx-mqtt)" < /dev/null > "$T/outbare" 2>&1
grep -qx 'PUB (retained) homeassistant/light/tsx-kiosk/ledbar/config ' "$T/outbare" || { echo "FAIL: bare: the LED bar entity is not cleared"; fail=1; }
grep -qx 'PUB (retained) homeassistant/light/tsx-kiosk/key_leds/config ' "$T/outbare" || { echo "FAIL: bare: the key LED entity is not cleared"; fail=1; }
grep -q 'homeassistant/event/' "$T/outbare" && { echo "FAIL: bare: key events announced without keys"; fail=1; }
grep -qE 'emmc|illuminance' "$T/outbare" && { echo "FAIL: bare: entities announced for parts this panel does not have"; fail=1; }
grep '/config {' "$T/outbare" | while read -r _ _ t j; do echo "$j" | jq -e . >/dev/null || { echo "FAIL: bad JSON $t"; exit 1; }; done || fail=1
# The real tsx-panelctl decides on the LED bar: the tool is installed, tsx-ledbard says that a
# bar with its application is attached (the file ledbar.usb says "app"), and hw.conf does not say
# LEDBAR=no (the tsx-hw of the board writes it). The light is announced then. Otherwise its
# discovery topic is cleared, no LED bar state is published and no LED bar command runs.
mkdir -p "$T/bin-led" "$T/run-led"
printf '#!/bin/sh\nexit 0\n' > "$T/bin-led/tsx-ledbar"
printf '#!/bin/sh\nexec sh "%s" "$@"\n' "$(P usr/local/sbin/tsx-panelctl)" > "$T/bin-led/tsx-panelctl"
chmod +x "$T/bin-led/tsx-ledbar" "$T/bin-led/tsx-panelctl"
printf 'want 0 0 40\n' > "$T/run-led/ledbar.state"
ledbar_case() {  # ledbar_case "hw.conf text" "ledbar.usb text" announced|cleared NAME  (NOFILE: no file)
	rm -f "$T/run-led/hw.conf" "$T/run-led/ledbar.usb"
	[ "$1" = NOFILE ] || printf '%b' "$1" > "$T/run-led/hw.conf"
	[ "$2" = NOFILE ] || printf '%b' "$2" > "$T/run-led/ledbar.usb"
	printf '%s\n' 'tsx/tsx-kiosk/ledbar/set ON' 'tsx/tsx-kiosk/ledbar/rgb/set 255,0,0' 'tsx/tsx-kiosk/ledbar/brightness/set 128' 'tsx/tsx-kiosk/screen/set ON' |
	PATH=$T/bin-led:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T/run-led TSX_IDLED_STATE=$T/idled \
		TSX_BUTTONS_CONF=$T/none TSX_BUTTONS_BOARD_CONF=$T/none TSX_KIOSK_CONF=$(P etc/kiosk.conf) TSX_BACKLIGHT_DIR=$T/bl \
		sh "$(P usr/local/sbin/tsx-mqtt)" > "$T/outled" 2>&1
	if [ "$3" = announced ]; then
		grep -qF 'PUB (retained) homeassistant/light/tsx-kiosk/ledbar/config {' "$T/outled" || { echo "FAIL: $4: the LED bar light is not announced"; fail=1; }
		grep -qF 'PUB (retained) tsx/tsx-kiosk/ledbar/state ON' "$T/outled" || { echo "FAIL: $4: the LED bar state is not published"; fail=1; }
		grep -qF 'ignored ledbar/' "$T/outled" && { echo "FAIL: $4: a LED bar command is ignored"; fail=1; }
	else
		grep -qx 'PUB (retained) homeassistant/light/tsx-kiosk/ledbar/config ' "$T/outled" || { echo "FAIL: $4: the LED bar light is not cleared"; fail=1; }
		grep -qF 'homeassistant/light/tsx-kiosk/ledbar/config {' "$T/outled" && { echo "FAIL: $4: the LED bar light is announced"; fail=1; }
		grep -qF 'tsx/tsx-kiosk/ledbar/' "$T/outled" && { echo "FAIL: $4: a LED bar topic is published"; fail=1; }
		[ "$(grep -c 'ignored ledbar/' "$T/outled")" = 3 ] || { echo "FAIL: $4: the three LED bar commands are not ignored"; fail=1; }
		grep -qE 'CALL|send ledbar' "$T/outled" && { echo "FAIL: $4: a LED bar command ran"; fail=1; }
	fi
	grep -qF 'PUB (retained) homeassistant/switch/tsx-kiosk/screen/config {' "$T/outled" || { echo "FAIL: $4: the other entities are gone"; fail=1; }
	return 0
}
ledbar_case NOFILE 'app\n' announced "LED bar tool, bar attached, no hw.conf"
ledbar_case 'MIC=yes\nPRESENCE=no\n' 'app\n' announced "LED bar tool, bar attached, hw.conf without LEDBAR"
ledbar_case 'LEDBAR=yes\n' 'app\n' announced "LED bar tool, bar attached, LEDBAR=yes"
ledbar_case 'LEDBAR=no\n' 'app\n' cleared "LED bar tool, bar attached, LEDBAR=no"
ledbar_case NOFILE NOFILE cleared "LED bar tool, no bar attached"
ledbar_case 'LEDBAR=yes\n' NOFILE cleared "LED bar tool, LEDBAR=yes, no bar attached"
ledbar_case NOFILE 'bootloader\n' cleared "LED bar tool, bar in the bootloader (no light)"
grep -qE 'emmc' "$T/out" && { echo "FAIL: eMMC entities announced without emmc.state"; fail=1; }
grep -qE 'presence|distance|usb_power|poe_class|/tag/' "$T/out" && { echo "FAIL: entities announced for parts this panel does not have"; fail=1; }

# eMMC health from /run/tsx/emmc.state (tsx-emmc-state)
T3=$T/hw; mkdir -p "$T3/run"
printf 'life_a 0x01\nlife_b 0x0b\neol 0x02\n' > "$T3/run/emmc.state"
printf 'raw 12.50\nreport 12.5\nauto on\n' > "$T3/run/als.state"
PATH=$T/bin:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T3/run TSX_IDLED_STATE=$T/idled \
	TSX_BUTTONS_CONF=$(P etc/tsx/buttons.conf) TSX_KIOSK_CONF=$(P etc/kiosk.conf) TSX_BACKLIGHT_DIR=$T/bl \
	sh "$(P usr/local/sbin/tsx-mqtt)" < /dev/null > "$T3/out" 2>&1
chk3() { grep -qF -- "$1" "$T3/out" || { echo "FAIL: emmc: missing: $1"; fail=1; }; }
grep '/config {' "$T3/out" | while read -r _ _ t j; do echo "$j" | jq -e . >/dev/null || { echo "FAIL: bad JSON $t"; exit 1; }; done || fail=1
for t in sensor/tsx-kiosk/emmc_life_a sensor/tsx-kiosk/emmc_life_b sensor/tsx-kiosk/emmc_eol sensor/tsx-kiosk/illuminance switch/tsx-kiosk/als_auto; do
	chk3 "PUB (retained) homeassistant/$t/config {"
done
chk3 'PUB (retained) tsx/tsx-kiosk/emmc/life_a 10'
chk3 'PUB (retained) tsx/tsx-kiosk/emmc/life_b 110'
chk3 'PUB (retained) tsx/tsx-kiosk/emmc/eol warning'
chk3 'PUB (retained) tsx/tsx-kiosk/als/lux 12.5'
printf 'life_a 0x00\nlife_b 0x03\neol 0x03\n' > "$T3/run/emmc.state"
PATH=$T/bin:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T3/run TSX_IDLED_STATE=$T/idled \
	TSX_BUTTONS_CONF=$(P etc/tsx/buttons.conf) TSX_KIOSK_CONF=$(P etc/kiosk.conf) TSX_BACKLIGHT_DIR=$T/bl \
	sh "$(P usr/local/sbin/tsx-mqtt)" < /dev/null > "$T3/out2" 2>&1
grep -qF 'PUB (retained) tsx/tsx-kiosk/emmc/life_a none' "$T3/out2" && grep -qF 'PUB (retained) tsx/tsx-kiosk/emmc/life_b 30' "$T3/out2" \
	&& grep -qF 'PUB (retained) tsx/tsx-kiosk/emmc/eol urgent' "$T3/out2" || { echo "FAIL: emmc: unreported life must be none, 0x03 must be 30 and urgent"; fail=1; }

# unconfigured: exits 0 quietly
out=$(TSX_MQTT_CONF=/nonexistent sh "$(P usr/local/sbin/tsx-mqtt)"); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q 'BROKER not set' || { echo "FAIL: unconfigured run rc=$rc '$out'"; fail=1; }

# panel.conf override: /run/tsx/mqtt.conf (written by `tsx-config apply` from
# MQTT_HOST/MQTT_PORT/panel.conf) must win over the static /etc/tsx/mqtt.conf,
# same precedence as kiosk-session's /etc/kiosk.conf + /run/tsx/kiosk.conf
T2=$(mktemp -d); mkdir -p "$T2/run"
printf 'BROKER=base.example\nPORT=1883\n' > "$T2/mqtt.conf"
printf 'BROKER=override.example\nPORT=8883\n' > "$T2/run/mqtt.conf"
PATH=$T/bin:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T2/mqtt.conf TSX_RUN_DIR=$T2/run TSX_IDLED_STATE=$T/idled \
	TSX_BUTTONS_CONF=$(P etc/tsx/buttons.conf) TSX_KIOSK_CONF=$(P etc/kiosk.conf) TSX_BACKLIGHT_DIR=$T/bl \
	sh "$(P usr/local/sbin/tsx-mqtt)" < /dev/null > "$T2/out" 2>&1
grep -q '^-h override.example$' "$T2/run/mqtt/mosquitto_pub" || { echo "FAIL: panel.conf override: BROKER not read from /run/tsx/mqtt.conf ($(cat "$T2/run/mqtt/mosquitto_pub" 2>/dev/null))"; fail=1; }
grep -q '^-p 8883$' "$T2/run/mqtt/mosquitto_pub" || { echo "FAIL: panel.conf override: PORT not read from /run/tsx/mqtt.conf"; fail=1; }
rm -rf "$T2"

[ $fail = 0 ] && echo "PASS tsx-mqtt dry run ($n discovery configs, JSON valid)"
exit $fail
