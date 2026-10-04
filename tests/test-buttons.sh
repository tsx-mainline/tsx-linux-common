#!/bin/bash
# Host test for tsx-buttons. It also covers the brightness override and offset
# of tsx-idled, the key-strip slide and the overlay FIFO. The fixtures are
# fake LED and backlight sysfs dirs and a FIFO as the key input device. They
# also include a fake HA REST API and a fake Chromium DevTools endpoint
# (fakesrv.py). The real tsx-idled does the blanking.
# The keys come from the board layer of the made-up board (tests/boards/fake):
# seven keys with seven key LEDs. The board layer sets SLIDE_STEP=0. A test
# buttons.conf adds the bindings, and later the settings that replace the
# board layer. A last part runs the daemon with the buttons.conf template of
# this repo, which has no keys and no bindings.
# Usage: tests/test-buttons.sh      (builds both daemons with host gcc)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/..
T=$(mktemp -d); PIDS=
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done; [ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf $T' EXIT
gcc -O2 -Wall -o $T/tsx-buttons $SRC/buttons/src/tsx-buttons.c
gcc -O2 -Wall -o $T/tsx-idled $SRC/kiosk/src/tsx-idled.c
HA_PORT=$((20000 + RANDOM % 10000)); CDP_PORT=$((HA_PORT + 1))
mkdir -p $T/bl/fakebl $T/input $T/idled-input $T/run $T/log
for l in fake:keys fake:key1 fake:key2 fake:key3 fake:key4 fake:key5 fake:key6 fake:key7; do mkdir -p "$T/leds/$l"; echo 0 > "$T/leds/$l/brightness"; done
echo 25 > $T/bl/fakebl/max_brightness; echo 8 > $T/bl/fakebl/brightness
mkfifo $T/input/event0
echo "test-token-123" > $T/ha-token
cp $SRC/tests/boards/fake/buttons-board.conf $T/buttons-board.conf
cat > $T/kiosk.conf <<C
KIOSK_URL="http://127.0.0.1:$HA_PORT/lovelace/0"
BLANK_TIMEOUT=0
BRIGHTNESS_DAY=8
BRIGHTNESS_NIGHT=8
BACKLIGHT_MAX=19
NIGHT_START=0
NIGHT_END=0
OSK_GESTURE=off
RAMP_SLIDER_MS=0
RAMP_AUTO_MS=0
C
# The buttons.conf of the test has no SLIDE_STEP: the board layer (0) applies.
# SLIDE_GAP_MS is long, so a short press that waits for a slide shows clearly.
cat > $T/buttons.conf <<C
KIOSK_CONF=$T/kiosk.conf
HA_TOKEN_FILE=$T/ha-token
HA_EVENT=tsx_button
DEVTOOLS=127.0.0.1:$CDP_PORT
LONG_PRESS_MS=400
HOLD_REPEAT_MS=200
SLIDE_GAP_MS=600
PRESS_FEEDBACK_MS=300
LED_DAY=128
LED_NIGHT=24
LED_BLANK=5
on prog1  short blank toggle
on prog1  long  overlay full
on prog2  short home
on prog2  long  navigate /lovelace/lights?x="1"
on prog3  short ha light.toggle {"entity_id": "light.kitchen"}
on prog3  long  exec echo "\$TSX_BUTTON \$TSX_PRESS" > $T/exec.out
on prog4  short brightness +2
on extra1 hold  brightness -1
on extra2 short brightness 99
on extra2 long  brightness auto
C
NBIND=$(grep -c '^on ' $T/buttons.conf)
python3 $HERE/fakesrv.py $HA_PORT $CDP_PORT $T/log & PIDS="$PIDS $!"
TSX_INPUT_DIR=$T/idled-input TSX_BACKLIGHT_DIR=$T/bl TSX_STATE_FILE=$T/idled.state TSX_RUN_DIR=$T/run \
	$T/tsx-idled -c $T/kiosk.conf -v 2>$T/idled.log & PIDS="$PIDS $!"
sleep 0.5
BENV="TSX_INPUT_DIR=$T/input TSX_LED_DIR=$T/leds TSX_BACKLIGHT_DIR=$T/bl TSX_RUN_DIR=$T/run
	TSX_IDLED_STATE=$T/idled.state TSX_HOSTNAME=testpanel TSX_ORIENTATION_FILE=$T/orientation
	TSX_BUTTONS_BOARD_CONF=$T/buttons-board.conf TSX_PANEL_BOARD_CONF=$T/panel-board.conf"
env $BENV $T/tsx-buttons -c $T/buttons.conf -v 2>$T/buttons.log & BPID=$!; PIDS="$PIDS $BPID"
exec 7<>$T/input/event0
key() { python3 -c 'import struct,sys,time; t=time.time(); sys.stdout.buffer.write(struct.pack("llHHi",int(t),0,1,int(sys.argv[1]),int(sys.argv[2]))+struct.pack("llHHi",int(t),0,0,0,0))' "$@" >&7; }
press() { key $1 1; sleep $2; key $1 0; }        # press <code> <seconds held>
ctl() { echo "$*" > $T/run/buttons.ctl; }
fail() { echo "FAIL: $*"; echo "--- tsx-buttons log"; cat $T/buttons.log; echo "--- tsx-idled log"; cat $T/idled.log; exit 1; }
led() { cat "$T/leds/fake:$1/brightness"; }
bl() { cat $T/bl/fakebl/brightness; }
ok() { echo "ok: $*"; }
nl_() { if [ -f "$1" ]; then wc -l < "$1"; else echo 0; fi; }      # the number of lines, 0 for a missing file
st() { sed -n "s/^$1 //p" $T/run/buttons.state; }
state() { tr '\n' ';' < $T/run/buttons.state; }
# the key codes of the board layer: prog1..prog4, extra1..extra3
P1=148 P2=149 P3=202 P4=203 X1=188 X2=189 X3=190
BASE=8
sleep 0.6
[ "$(led keys)" = 128 ] || fail "initial key LED level $(led keys)"
[ "$(led key1)$(led key3)$(led key5)$(led key6)$(led key7)" = 11111 ] || fail "key LEDs not on"
grep -q "using $T/input/event0" $T/buttons.log || fail "input device not used"
grep -q "^tsx-buttons: 7 buttons, $NBIND bindings, 7 key LEDs" $T/buttons.log || fail "board layer: $(grep ' buttons, ' $T/buttons.log | tail -n 1)"
[ "$(st leds)" = yes ] || fail "state: leds $(st leds)"
[ "$(st key_leds)" = "1 1 1 1 1 1 1" ] || fail "state key_leds: '$(st key_leds)'"
ok "board layer: 7 keys and 7 key LEDs from buttons-board.conf, level 128, leds yes"

# A key of the board layer with no binding: a press fires the HA event and the
# "last" line, and nothing else happens.
nc=$(nl_ $T/log/cdp.log); b0=$(bl)
press $X3 0.1; sleep 0.5
grep -q '/api/events/tsx_button|Bearer test-token-123|{"panel":"testpanel","button":"extra3","press":"short","code":190}' $T/log/ha.log || fail "extra3: no HA event: $(cat $T/log/ha.log)"
[ "$(st last | cut -d' ' -f1,2)" = "extra3 short" ] || fail "extra3: last line '$(st last)'"
press $X3 0.6; sleep 0.5
grep -q '"button":"extra3","press":"long","code":190' $T/log/ha.log || fail "extra3 long: no HA event"
[ "$(nl_ $T/log/cdp.log)" = "$nc" ] && [ "$(bl)" = "$b0" ] && [ ! -e $T/exec.out ] || fail "extra3: an unbound key did a local action"
grep -q '^on' $T/idled.state || fail "extra3: the screen is not awake ($(cat $T/idled.state))"
[ "$(nl_ $T/log/ha.log)" = 2 ] || fail "extra3: want 2 HA calls, got $(cat $T/log/ha.log)"
ok "unbound key extra3: short and long fire the HA event and the last line, no local action"

press $P2 0.1; sleep 0.8
grep -q '"method":"Runtime.evaluate"' $T/log/cdp.log || fail "home: no CDP message"
grep -q "lovelace/0" $T/log/cdp.log || fail "home: CDP message without KIOSK_URL"
grep -q 'devtools: .*spa /test' $T/buttons.log || fail "home: CDP reply not read"
grep -q '/api/events/tsx_button|Bearer test-token-123|{"panel":"testpanel","button":"prog2","press":"short","code":149}' $T/log/ha.log || fail "home: no HA event"
ok "prog2 short (home) -> DevTools in-app navigation + HA event"

press $P2 0.6; sleep 0.8
grep -q 'lovelace/lights?x=\\\\\\"1\\\\\\"' $T/log/cdp.log || fail "prog2 long: navigate target not escaped/sent: $(tail -1 $T/log/cdp.log)"
grep -q '"button":"prog2","press":"long"' $T/log/ha.log || fail "prog2 long: no HA event"
ok "prog2 long -> navigate /lovelace/lights (JSON escaping)"

press $P3 0.1; sleep 0.8
grep -q '^/api/services/light/toggle|Bearer test-token-123|{"entity_id": "light.kitchen"}$' $T/log/ha.log || fail "prog3: no HA service call: $(cat $T/log/ha.log)"
ok "prog3 short -> POST /api/services/light/toggle with Bearer token"

press $P3 0.6; sleep 0.5
[ "$(cat $T/exec.out 2>/dev/null)" = "prog3 long" ] || fail "prog3 long exec: '$(cat $T/exec.out 2>/dev/null)'"
ok "prog3 long -> exec with TSX_BUTTON/TSX_PRESS"

[ "$(bl)" = $BASE ] || fail "tsx-idled day level $(bl)"
press $P4 0.1; sleep 0.3
[ "$(bl)" = $((BASE + 2)) ] || fail "prog4: brightness $(bl), want $((BASE + 2)) (SLIDE_STEP 0: the press fires at once, SLIDE_GAP_MS is 600)"
[ "$(cat $T/run/brightness-offset 2>/dev/null)" = 2 ] || fail "prog4: offset file '$(cat $T/run/brightness-offset 2>/dev/null)', want 2"
[ ! -e $T/run/brightness ] || fail "prog4: +N must not write the absolute override"
sleep 5.5; [ "$(bl)" = $((BASE + 2)) ] || fail "tsx-idled did not keep the offset: $(bl)"
ok "prog4 short -> brightness +2 as an offset ($BASE -> $((BASE + 2))) at once (board layer SLIDE_STEP=0), tsx-idled keeps it"

key $X1 1; sleep 1.1; key $X1 0; sleep 0.3
b=$(bl); [ "$b" -le 7 ] && [ "$b" -ge 5 ] || fail "extra1 hold: brightness $b, want 5..7 (4 repeats)"
ok "extra1 hold -> brightness repeated down to $b"

# The top level of the backlight. tsx-idled reports "max 19" (BACKLIGHT_MAX of
# kiosk.conf). The device allows 25.
press $X2 0.1; sleep 0.6
[ "$(bl)" = 19 ] || fail "extra2: brightness 99 gives $(bl), want 19 (the max of brightness.state)"
press $X2 0.6; sleep 0.8
[ ! -e $T/run/brightness ] && [ ! -e $T/run/brightness-offset ] || fail "extra2 long: brightness auto left a file"
[ "$(bl)" = $BASE ] || fail "extra2 long: brightness $(bl), want $BASE"
ok "brightness 99 stops at the max of brightness.state (19, not the device 25). brightness auto goes back"

# Taps with SLIDE_STEP=0: the keys 2 and 3 in a row are two presses, no slide.
nh=$(nl_ $T/log/ha.log); b0=$(bl)
press $P2 0.06; sleep 0.05; press $P3 0.06; sleep 0.8
[ "$(bl)" = "$b0" ] && [ "$(( $(nl_ $T/log/ha.log) - nh ))" -ge 3 ] || fail "SLIDE_STEP=0: two keys in a row changed the brightness ($(bl)) or fired too few events"
ok "SLIDE_STEP=0 (board layer): two keys in a row are two presses, no slide"

# The settings of buttons.conf replace the board layer: turn the slide on.
printf 'SLIDE_STEP=2\nSLIDE_GAP_MS=200\n' >> $T/buttons.conf
kill -HUP $BPID; sleep 0.5
b0=$(bl)
# key-strip slide, bottom -> top: +SLIDE_STEP per key, no key action fires
nh=$(nl_ $T/log/ha.log); nc=$(nl_ $T/log/cdp.log)
slide() { for k in "$@"; do key $k 1; sleep 0.06; key $k 0; sleep 0.05; done; }
slide $X1 $P4 $P3 $P2 $P1; sleep 0.6
[ "$(bl)" = $((b0 + 8)) ] || fail "slide up: brightness $(bl), want $((b0 + 8)) (4 steps of 2)"
[ "$(nl_ $T/log/ha.log)/$(nl_ $T/log/cdp.log)" = "$nh/$nc" ] || fail "slide fired key actions (HA $nh -> $(nl_ $T/log/ha.log), CDP $nc -> $(nl_ $T/log/cdp.log))"
grep -q '^blank' $T/idled.state && fail "slide ended on prog1: its short press (blank) fired"
[ "$(cat $T/run/brightness-offset)" = $((b0 + 8 - BASE)) ] || fail "slide: offset $(cat $T/run/brightness-offset), want $((b0 + 8 - BASE))"
ok "SLIDE_STEP=2 in buttons.conf: slide extra1 -> prog1: brightness $b0 -> $(bl) (offset $(cat $T/run/brightness-offset)), no key actions, no HA events"
echo 5 > $T/run/brightness; sleep 0.4; [ "$(bl)" = 5 ] || fail "absolute override: $(bl)"
slide $P2 $P3; sleep 0.6
[ "$(bl)" = 3 ] || fail "slide down from an override: $(bl), want 3"
[ ! -e $T/run/brightness ] && [ "$(cat $T/run/brightness-offset)" = $((3 - BASE)) ] || fail "slide did not turn the override into an offset"
ok "slide down from an absolute override (5): starts there, -> 3 as offset $((3 - BASE)) (override gone)"
nc=$(nl_ $T/log/cdp.log)
press $P2 0.06; sleep 0.05; press $X1 0.06; sleep 0.6
[ "$(nl_ $T/log/cdp.log)" = $((nc + 1)) ] && [ "$(bl)" = 3 ] || fail "keys 2 and 5 are no slide: home must fire, brightness stay ($(bl))"
ok "two taps three keys apart: no slide, prog2 short (home) fires"

# the panel hung flipped (ORIENTATION landscape-flipped / portrait-flipped):
# the physical top key is at the bottom / left, so the slide turns around.
# Portrait (keys below, top key on the right) keeps it. Read at every step.
echo landscape-flipped > $T/orientation
slide $P2 $P3; sleep 0.6
[ "$(bl)" = 5 ] || fail "landscape-flipped: physical down slide must be brighter: $(bl), want 5"
echo portrait-flipped > $T/orientation
slide $P3 $P2; sleep 0.6
[ "$(bl)" = 3 ] || fail "portrait-flipped: physical up slide must be darker: $(bl), want 3"
echo portrait > $T/orientation
slide $P3 $P2; sleep 0.6
[ "$(bl)" = 5 ] || fail "portrait: physical up slide (right) must be brighter: $(bl), want 5"
rm -f $T/orientation
slide $P2 $P3; sleep 0.6
[ "$(bl)" = 3 ] || fail "no orientation file: physical down slide must be darker: $(bl), want 3"
ok "slide direction: turned around for landscape-/portrait-flipped, kept for portrait and landscape"

# overlay FIFO: no reader -> OVERLAY_FALLBACK (blank toggle). A reader -> "full"/"slider"
[ -p $T/run/overlay.ctl ] || fail "no overlay FIFO $T/run/overlay.ctl"
key $P1 1; sleep 0.6; key $P1 0; sleep 0.5
grep -q '^blank' $T/idled.state || fail "overlay without a reader: fallback blank toggle did not blank"
grep -q 'no overlay running' $T/buttons.log || fail "overlay fallback not logged"
kill -USR1 $(pgrep -x tsx-idled | head -1); sleep 0.9
exec 8<>$T/run/overlay.ctl
key $P1 1; sleep 0.6; key $P1 0; sleep 0.3
read -t 2 line <&8 && [ "$line" = full ] || fail "overlay: reader got '${line:-nothing}', want full"
grep -q '^on' $T/idled.state || fail "overlay with a reader: the screen was blanked anyway"
slide $P3 $P2; sleep 0.3
read -t 2 line <&8 && [ "$line" = slider ] || fail "slide: overlay reader got '${line:-nothing}', want slider"
ctl "overlay hide"; read -t 2 line <&8 && [ "$line" = hide ] || fail "ctl overlay hide: '${line:-nothing}'"
exec 8<&-
ok "overlay: long hold -> full (reader) / fallback blank (no reader). Slide -> slider. Ctl overlay hide"
rm -f $T/run/brightness-offset; sleep 0.4

ctl "page reload"; sleep 0.8
grep -q '"method":"Page.reload"' $T/log/cdp.log || fail "ctl page reload: no Page.reload"
ok "ctl page reload -> DevTools Page.reload"

key $P1 1; sleep 0.1
[ "$(led key1)" = 0 ] || fail "press feedback: key1 LED not dark while pressed"
key $P1 0; sleep 0.8
grep -q '^blank' $T/idled.state || fail "prog1 short: not blanked ($(cat $T/idled.state))"
[ "$(bl)" = 0 ] || fail "prog1: backlight $(bl)"
[ "$(led keys)" = 5 ] || fail "blank: key LED level $(led keys), want LED_BLANK 5"
[ "$(led key2)$(led key7)" = 11 ] || fail "blank: key LED enables $(led key2)$(led key7), want 11 (LED_BLANK > 0)"
ok "prog1 short -> blank via tsx-idled. Key LEDs -> LED_BLANK"

kill -USR1 $(pgrep -x tsx-idled | head -1); sleep 0.9
[ "$(led keys)" = 128 ] || fail "wake: key LED level $(led keys)"
ok "wake -> key LEDs 128"

# The override and the blank screen. "led off" applies at once and holds in
# every screen state. "led N" is the awake level. While the screen is blank,
# the keys show LED_BLANK. Each change applies at once.
IDLED_PID=$(pgrep -x tsx-idled | head -1)
blank_on() { kill -USR2 $IDLED_PID; sleep 0.9; grep -q '^blank' $T/idled.state || fail "tsx-idled did not blank"; }
blank_off() { kill -USR1 $IDLED_PID; sleep 0.9; grep -q '^on' $T/idled.state || fail "tsx-idled did not wake"; }
blank_on; [ "$(led keys)" = 5 ] || fail "blank: key LED level $(led keys), want LED_BLANK 5"
ctl "led off"; sleep 0.3
[ "$(led keys)$(led key1)" = 00 ] || fail "led off on a blank screen: level $(led keys), key1 $(led key1), want dark at once"
[ "$(st led)/$(st led_awake)/$(st led_blank)" = "0 override/0 override/5" ] || fail "led off on a blank screen: $(state)"
blank_off; [ "$(led keys)$(led key1)" = 00 ] || fail "led off: the wake lit the keys ($(led keys))"
blank_on; [ "$(led keys)" = 0 ] || fail "led off: the next blank lit the keys ($(led keys))"
ok "led off on a blank screen: dark at once, and it holds across wake and blank"
ctl "led 40"; sleep 0.3
[ "$(led keys)$(led key1)" = 51 ] || fail "led 40 on a blank screen: level $(led keys), want LED_BLANK 5 at once"
[ "$(st led)/$(st led_awake)" = "5 blank/40 override" ] || fail "led 40 on a blank screen: $(state)"
blank_off; [ "$(led keys)" = 40 ] || fail "led 40: the wake shows $(led keys), want 40"
ok "led 40 on a blank screen: LED_BLANK at once, 40 after the wake"
ctl "led off"; sleep 0.3; [ "$(led keys)" = 0 ] || fail "led off on an awake screen: $(led keys)"
ctl "led -5"; sleep 0.3; [ "$(st led_awake)" = "0 override" ] || fail "led -5 from 0 must stay 0, not auto: $(state)"
ctl "led +30"; sleep 0.3; [ "$(led keys)" = 30 ] || fail "led +30 from 0: $(led keys)"
ctl "led auto"; sleep 0.3
[ "$(led keys)" = 128 ] && [ "$(st led)/$(st led_awake)" = "128 day/128 day" ] || fail "led auto: $(state)"
ok "led off, -5 (stays 0), +30, auto on an awake screen"

# The panel.conf override /run/tsx/buttons.conf (tsx-config apply, KEY_LED_BLANK):
# its settings replace those of buttons.conf. It cannot add keys or bindings.
printf 'LED_BLANK=9\nbutton extra KEY_F18 led=1\non prog1 short none\n' > $T/run/buttons.conf
kill -HUP $BPID; sleep 0.5
[ "$(st led_blank)" = 9 ] || fail "override LED_BLANK=9: $(state)"
grep -q "$T/run/buttons.conf:2: only KEY=VALUE settings here" $T/buttons.log && grep -q "$T/run/buttons.conf:3: only KEY=VALUE" $T/buttons.log \
	|| fail "override: button and on lines refused: not logged"
grep ' buttons, ' $T/buttons.log | tail -n 1 | grep -q "^tsx-buttons: 7 buttons, $NBIND bindings, 7 key LEDs, .* blank 9 " \
	|| fail "override: $(grep ' buttons, ' $T/buttons.log | tail -n 1)"
blank_on; [ "$(led keys)" = 9 ] || fail "override LED_BLANK=9: blank shows $(led keys)"
rm $T/run/buttons.conf; kill -HUP $BPID; sleep 0.5
[ "$(led keys)" = 5 ] && [ "$(st led_blank)" = 5 ] || fail "override removed: blank shows $(led keys), want 5"
blank_off; [ "$(led keys)" = 128 ] || fail "override removed: wake shows $(led keys)"
ok "panel.conf override: LED_BLANK=9 applies on reload (also on a blank screen), button and on lines refused"

ctl "led 40"; sleep 0.3; [ "$(led keys)" = 40 ] || fail "ctl led 40: $(led keys)"
ctl "key prog3 off"; sleep 0.3; [ "$(led key3)" = 0 ] || fail "ctl key prog3 off"
ctl "key 3 auto"; sleep 0.3; [ "$(led key3)" = 1 ] || fail "ctl key 3 auto"
ctl "key 7 off"; sleep 0.3; [ "$(led key7)" = 0 ] && [ "$(st key_override | cut -d' ' -f7)" = off ] || fail "ctl key 7 off: key7 $(led key7), $(state)"
ctl "key extra3 auto"; sleep 0.3; [ "$(led key7)" = 1 ] || fail "ctl key extra3 auto"
ctl "key 8 off"; sleep 0.3; grep -q "ctl: no key LED '8'" $T/buttons.log || fail "ctl key 8: only 7 key LEDs, the log has no refusal"
ctl "led auto"; sleep 0.3; [ "$(led keys)" = 128 ] || fail "ctl led auto: $(led keys)"
ctl "led 0"; sleep 0.3; [ "$(led keys)$(led key1)$(led key6)" = 000 ] || fail "ctl led 0: enables should be off"
ctl "led auto"; sleep 0.3
echo 77 > "$T/leds/fake:keys/brightness"; sleep 5.5; [ "$(led keys)" = 128 ] || fail "external LED change not re-applied"
ok "control FIFO: led N/auto/0, key NAME|N off/auto (key 7, no key 8). re-apply after external change"

K=$SRC/buttons/usr/local/bin/tsx-keypad
TSX_RUN_DIR=$T/run $K led 60; sleep 0.3; [ "$(led keys)" = 60 ] || fail "tsx-keypad led 60"
TSX_RUN_DIR=$T/run $K status | grep -q '^led 60 override' || fail "tsx-keypad status"
TSX_RUN_DIR=$T/run $K led auto; sleep 0.3
ok "tsx-keypad CLI: led 60, status, led auto"
ctl "press prog3 short"; sleep 0.6
[ "$(grep -c '^/api/services/light/toggle' $T/log/ha.log)" = 3 ] || fail "ctl press prog3"
ctl "status"; sleep 0.3; grep -q '^led 128 day' $T/run/buttons.state || fail "state: $(cat $T/run/buttons.state)"
ok "ctl press + status: $(tr '\n' ';' < $T/run/buttons.state)"

# The settings of buttons.conf replace the LED names of the board layer. A
# missing LED_PWM device means no key LEDs: leds no, and the daemon writes no LED.
cp $T/buttons.conf $T/buttons.conf.keep
echo 'LED_PWM=fake:missing' >> $T/buttons.conf
echo 9 > "$T/leds/fake:key1/brightness"; kill -HUP $BPID; sleep 0.5
ctl "led 77"; sleep 0.3
[ "$(st leds)" = no ] || fail "LED_PWM device missing: state leds '$(st leds)', want no"
[ "$(led keys)$(led key1)" = 1289 ] || fail "LED_PWM device missing: a LED was written ($(led keys) $(led key1))"
cp $T/buttons.conf.keep $T/buttons.conf; kill -HUP $BPID; sleep 0.5
[ "$(st leds)" = yes ] && [ "$(led key1)" = 1 ] || fail "LED_PWM restored: leds '$(st leds)', key1 $(led key1)"
ctl "led auto"; sleep 0.3
ok "LED_PWM in buttons.conf replaces the board layer: missing device -> leds no, no LED written. Restored -> leds yes"

# DevTools off -> fallback: /run/tsx/kiosk-url + rc-service kiosk restart (absent on the host)
sed -i "s/^DEVTOOLS=.*/DEVTOOLS=127.0.0.1:1/" $T/buttons.conf; kill -HUP $BPID; sleep 0.5
press $P2 0.6; sleep 1
[ "$(cat $T/run/kiosk-url 2>/dev/null)" = "http://127.0.0.1:$HA_PORT/lovelace/lights?x=\"1\"" ] || fail "fallback kiosk-url: '$(cat $T/run/kiosk-url 2>/dev/null)'"
grep -q 'restarting the kiosk' $T/buttons.log || fail "fallback not logged"
press $P2 0.1; sleep 1
[ ! -e $T/run/kiosk-url ] || fail "home did not remove kiosk-url"
ok "no DevTools -> kiosk-url + restart fallback. Home clears it"

# panel.conf override: /run/tsx/kiosk.conf (tsx-config apply) wins over
# KIOSK_CONF's KIOSK_URL for the derived HA_URL -- same precedence as
# kiosk-session's /etc/kiosk.conf + /run/tsx/kiosk.conf
HA_PORT2=$((HA_PORT + 1000))
mkdir -p $T/log2
python3 $HERE/fakesrv.py $HA_PORT2 $((CDP_PORT + 1000)) $T/log2 & PIDS="$PIDS $!"
sleep 0.3
nold=$(nl_ $T/log/ha.log)
echo "KIOSK_URL=\"http://127.0.0.1:$HA_PORT2/lovelace/0\"" > $T/run/kiosk.conf
kill -HUP $BPID; sleep 0.5
press $P3 0.1; sleep 0.6
grep -q '^/api/services/light/toggle|Bearer test-token-123' $T/log2/ha.log || fail "panel.conf override: HA action did not reach /run/tsx/kiosk.conf's origin"
[ "$(nl_ $T/log/ha.log)" = "$nold" ] || fail "panel.conf override: HA action still went to the base kiosk.conf origin too"
ok "panel.conf override (/run/tsx/kiosk.conf) wins over KIOSK_CONF for HA_URL"
rm -f $T/run/kiosk.conf; kill -HUP $BPID; sleep 0.5

# The key replaced by buttons.conf: a `button` line with the name of a board
# key replaces that key. The bindings of the name stay.
echo 'button extra3 191 led=7' >> $T/buttons.conf
echo 'on extra3 short exec echo replaced > '"$T/replaced.out" >> $T/buttons.conf
kill -HUP $BPID; sleep 0.5
grep ' buttons, ' $T/buttons.log | tail -n 1 | grep -q "^tsx-buttons: 7 buttons, $((NBIND + 1)) bindings, 7 key LEDs" || fail "replaced key: $(grep ' buttons, ' $T/buttons.log | tail -n 1)"
nold=$(nl_ $T/log/ha.log)
press $X3 0.1; sleep 0.5
[ "$(nl_ $T/log/ha.log)" = "$nold" ] && [ ! -e $T/replaced.out ] || fail "replaced key: the old code 190 still fires"
press 191 0.1; sleep 0.6
grep -q '"button":"extra3","press":"short","code":191' $T/log/ha.log || fail "replaced key: no HA event for code 191: $(tail -2 $T/log/ha.log)"
[ "$(cat $T/replaced.out 2>/dev/null)" = replaced ] || fail "replaced key: the binding did not run"
ok "button extra3 in buttons.conf replaces the key of the board layer: code 190 is dead, 191 fires, still 7 keys"
sed -i '/^button extra3 191/d;/^on extra3 short/d' $T/buttons.conf; kill -HUP $BPID; sleep 0.5

# The top level of the backlight without brightness.state: BACKLIGHT_MAX of
# kiosk.conf (19), then BACKLIGHT_MAX of the board layer panel-board.conf (it
# wins), then the device (25). A "max" line of brightness.state comes first.
kill $IDLED_PID; sleep 0.5; rm -f $T/run/brightness.state
echo 6 > $T/bl/fakebl/brightness
press $X2 0.1; sleep 0.5
[ "$(bl)" = 19 ] && [ "$(cat $T/run/brightness)" = 19 ] || fail "ceiling from kiosk.conf: device $(bl), override '$(cat $T/run/brightness 2>/dev/null)', want 19"
echo "BACKLIGHT_MAX=12" > $T/panel-board.conf; kill -HUP $BPID; sleep 0.5
press $X2 0.1; sleep 0.5
[ "$(bl)" = 12 ] || fail "ceiling from panel-board.conf: $(bl), want 12"
sed -i '/^BACKLIGHT_MAX/d' $T/kiosk.conf; : > $T/panel-board.conf; kill -HUP $BPID; sleep 0.5
press $X2 0.1; sleep 0.5
[ "$(bl)" = 25 ] || fail "ceiling from the device: $(bl), want 25"
printf 'level 9\nbase 8\noffset 1\noverride 0\nmax 7\n' > $T/run/brightness.state
press $X2 0.1; sleep 0.5
[ "$(bl)" = 7 ] || fail "ceiling from brightness.state: $(bl), want 7"
press $P4 0.1; sleep 0.5
[ "$(cat $T/run/brightness-offset 2>/dev/null)" = -1 ] || fail "relative change under max 7: offset '$(cat $T/run/brightness-offset 2>/dev/null)', want -1 (7 - base 8)"
ok "backlight ceiling: max of brightness.state, else BACKLIGHT_MAX (panel-board.conf over kiosk.conf), else the device"

rm $T/ha-token; kill -HUP $BPID; sleep 0.5; n=$(nl_ $T/log/ha.log)
press $P3 0.1; sleep 0.6; [ "$(nl_ $T/log/ha.log)" = "$n" ] || fail "HA call without token"
[ ! -e $T/run/ha-auth.hdr ] || fail "auth header file left behind"
ok "no token -> HA actions skipped"

# The buttons.conf template of this repo: no keys and no bindings. With the
# board layer of the made-up board, the seven keys fire the HA event and
# nothing else. Without a board layer, the daemon has no keys and no key LEDs.
echo "test-token-123" > $T/ha-token
for d in leds2 run2 log3; do mkdir -p $T/$d; done
mkdir -p $T/input2; mkfifo $T/input2/event0
for l in fake:keys fake:key1 fake:key2 fake:key3 fake:key4 fake:key5 fake:key6 fake:key7; do mkdir -p "$T/leds2/$l"; echo 0 > "$T/leds2/$l/brightness"; done
printf 'HA_TOKEN_FILE=%s/ha-token\nKIOSK_CONF=%s/kiosk.conf\nDEVTOOLS=127.0.0.1:1\n' $T $T > $T/run2/buttons.conf
printf 'KIOSK_URL="http://127.0.0.1:%s/lovelace/0"\nNIGHT_START=0\nNIGHT_END=0\n' $HA_PORT2 > $T/kiosk.conf
env TSX_INPUT_DIR=$T/input2 TSX_LED_DIR=$T/leds2 TSX_BACKLIGHT_DIR=$T/bl TSX_RUN_DIR=$T/run2 TSX_IDLED_STATE=$T/none \
	TSX_HOSTNAME=testpanel TSX_BUTTONS_BOARD_CONF=$T/buttons-board.conf TSX_PANEL_BOARD_CONF=$T/panel-board.conf \
	$T/tsx-buttons -c $SRC/buttons/etc/tsx/buttons.conf -v 2>$T/buttons2.log & B2=$!; PIDS="$PIDS $B2"
exec 9<>$T/input2/event0
key2() { python3 -c 'import struct,sys,time; t=time.time(); sys.stdout.buffer.write(struct.pack("llHHi",int(t),0,1,int(sys.argv[1]),int(sys.argv[2]))+struct.pack("llHHi",int(t),0,0,0,0))' "$@" >&9; }
sleep 0.6
grep -q '^tsx-buttons: 7 buttons, 0 bindings, 7 key LEDs' $T/buttons2.log || fail "template: $(grep ' buttons, ' $T/buttons2.log | tail -n 1)"
grep -qE 'bad |unknown setting|ignored|only KEY=VALUE' $T/buttons2.log && fail "template: the file has a line that the daemon refuses: $(grep -E 'bad |unknown|ignored|only' $T/buttons2.log)"
[ "$(cat "$T/leds2/fake:keys/brightness")" = 128 ] || fail "template: default LED_DAY 128 not applied ($(cat "$T/leds2/fake:keys/brightness"))"
n2=$(nl_ $T/log2/ha.log); nc2=$(nl_ $T/log2/cdp.log)
key2 $P3 1; sleep 0.1; key2 $P3 0; sleep 0.6
grep -q '"button":"prog3","press":"short","code":202' $T/log2/ha.log || fail "template: no HA event for prog3: $(tail -1 $T/log2/ha.log)"
[ "$(nl_ $T/log2/ha.log)" = $((n2 + 1)) ] || fail "template: a press made more than the HA event"
[ "$(sed -n 's/^last //p' $T/run2/buttons.state | cut -d' ' -f1,2)" = "prog3 short" ] || fail "template: last line"
[ "$(sed -n 's/^leds //p' $T/run2/buttons.state)" = yes ] || fail "template: leds yes expected"
ok "buttons.conf template + board layer: 7 keys, 0 bindings, a press fires only the HA event, no refused line"
kill -TERM $B2; sleep 0.3
env TSX_INPUT_DIR=$T/input2 TSX_LED_DIR=$T/leds2 TSX_BACKLIGHT_DIR=$T/bl TSX_RUN_DIR=$T/run2 TSX_IDLED_STATE=$T/none \
	TSX_BUTTONS_BOARD_CONF=$T/no-board-layer TSX_PANEL_BOARD_CONF=$T/panel-board.conf \
	$T/tsx-buttons -c $SRC/buttons/etc/tsx/buttons.conf -v 2>$T/buttons3.log & B3=$!; PIDS="$PIDS $B3"
sleep 0.6
grep -q '^tsx-buttons: 0 buttons, 0 bindings, 0 key LEDs' $T/buttons3.log || fail "no board layer: $(grep ' buttons, ' $T/buttons3.log | tail -n 1)"
[ "$(sed -n 's/^leds //p' $T/run2/buttons.state)" = no ] || fail "no board layer: leds no expected"
ok "buttons.conf template, no board layer: no keys, no key LEDs, leds no"
kill -TERM $B3; sleep 0.2
echo "ALL OK"; echo "--- tsx-buttons log"; cat $T/buttons.log
