#!/bin/bash
# Host test for the layers of the settings files. The order, a later layer
# wins: the package defaults, the board file, the user file, the runtime file.
# It checks the loader of each language (conf.sh, tsx_conf.py, tsx-conf.h),
# a missing user file, a missing defaults file, the writes (they go to the
# user file only), and the real programs that read the layers: tsx-idled,
# tsx-buttons, tsx-ledbar, tsx-voice-run and tsx-esphome-run.
# It compiles C, so run it on a build host or in CI.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tests/lib/paths.sh"
T=$(mktemp -d); PID=; trap '[ -n "$PID" ] && kill $PID 2>/dev/null; rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
CONFSH=$(P usr/local/lib/tsx/conf.sh)
LIBDIR=$(dirname "$CONFSH")
D=$T/defaults; mkdir -p "$D" "$T/etc"
printf '# comment\nA=d\nB=d\nC=d\nD=d\nQ="quoted value"  # note\n' > "$D/demo.conf"
printf 'B=board\nC=board\nD=board\n' > "$T/board.conf"
printf 'C=user\nD=user\n' > "$T/user.conf"
printf 'D=run\n' > "$T/run.conf"

echo "== shell (conf.sh) =="
sload() { # sload "BOARD" "RUN" USER -> A B C D
	env -i PATH="$PATH" TSX_DEFAULTS_DIR="$D" sh -c ". '$CONFSH'; tsx_conf_load demo.conf '$3' '$1' '$2'; echo \"\${A:-} \${B:-} \${C:-} \${D:-}\""
}
eq "$(sload "" "" "$T/none")" "d d d d" "only the defaults"
eq "$(sload "$T/board.conf" "" "$T/none")" "d board board board" "the board file wins over the defaults"
eq "$(sload "$T/board.conf" "" "$T/user.conf")" "d board user user" "the user file wins over the board file"
eq "$(sload "$T/board.conf" "$T/run.conf" "$T/user.conf")" "d board user run" "the runtime file wins over the user file"
eq "$(sload "" "" "$T/user.conf")" "d d user user" "no board file: defaults, user"
eq "$(sload "$T/none" "$T/none" "$T/none")" "d d d d" "a missing user, board and runtime file is no error"
eq "$(env -i PATH="$PATH" TSX_DEFAULTS_DIR="$T/nodir" sh -c ". '$CONFSH'; tsx_conf_load demo.conf '$T/user.conf'; echo \"\${A:-}\${B:-} \${C:-} \${D:-}\"")" " user user" "a missing defaults file: only the user file"
eq "$(env -i PATH="$PATH" sh -c ". '$CONFSH'; tsx_conf_defaults kiosk.conf")" "/usr/local/share/tsx/defaults/kiosk.conf" "the default folder of the defaults"
sget() { env -i PATH="$PATH" TSX_DEFAULTS_DIR="$D" sh -c ". '$CONFSH'; tsx_conf_get demo.conf $1 '$T/user.conf' '$T/board.conf' '$T/run.conf'"; }
eq "$(sget D)" "run" "tsx_conf_get: the last layer"
eq "$(sget B)" "board" "tsx_conf_get: a key that only the board file changes"
eq "$(sget A)" "d" "tsx_conf_get: a key that only the defaults have"
eq "$(sget Q)" "quoted value" "tsx_conf_get: no quotes, no comment"
eq "$(sget NOPE)" "" "tsx_conf_get: an unknown key is empty"

echo "== shell: writes go to the user file only =="
U=$T/etc/set.conf
sset() { env -i PATH="$PATH" TSX_DEFAULTS_DIR="$D" sh -c ". '$CONFSH'; tsx_conf_set '$U' '$1' '$2'"; }
sset TOKEN_FILE "/etc/x y"
eq "$(cat "$U")" "TOKEN_FILE=/etc/x y" "a missing user file is made, with the one key"
sset A new
eq "$(cat "$U" | tr '\n' '|')" "TOKEN_FILE=/etc/x y|A=new|" "a new key is appended"
sset A newer
eq "$(cat "$U" | tr '\n' '|')" "TOKEN_FILE=/etc/x y|A=newer|" "a key that is there is replaced in place"
grep -q '^B=d' "$U" && bad "the defaults were copied into the user file" || ok "the defaults are not copied into the user file"
eq "$(cat "$D/demo.conf" | md5sum)" "$(printf '# comment\nA=d\nB=d\nC=d\nD=d\nQ="quoted value"  # note\n' | md5sum)" "the defaults file did not change"
ls "$T/etc" | grep -q tmp && bad "a temporary file stays" || ok "no temporary file stays"

echo "== Python (tsx_conf.py) =="
PYC="import sys; sys.path.insert(0, '$LIBDIR'); import tsx_conf as c"
pload() { TSX_DEFAULTS_DIR="$D" python3 -I -c "$PYC
import os
b, r = sys.argv[1] or None, sys.argv[2] or None
d = c.load('demo.conf', sys.argv[3], b, r)
print(*[d.get(k, '') for k in 'ABCD'])" "$1" "$2" "$3"; }
eq "$(pload "" "" "$T/none")" "d d d d" "only the defaults"
eq "$(pload "$T/board.conf" "" "$T/none")" "d board board board" "the board file wins over the defaults"
eq "$(pload "$T/board.conf" "" "$T/user.conf")" "d board user user" "the user file wins over the board file"
eq "$(pload "$T/board.conf" "$T/run.conf" "$T/user.conf")" "d board user run" "the runtime file wins over the user file"
eq "$(pload "$T/none" "$T/none" "$T/none")" "d d d d" "a missing user, board and runtime file is no error"
eq "$(TSX_DEFAULTS_DIR="$T/nodir" python3 -I -c "$PYC
print(c.load('demo.conf', '$T/user.conf'), c.has_defaults('demo.conf'))")" "{'C': 'user', 'D': 'user'} False" "a missing defaults file: only the user file"
eq "$(TSX_DEFAULTS_DIR="$D" python3 -I -c "$PYC
print(c.get('demo.conf', 'Q', '$T/none'), c.has_defaults('demo.conf'), c.defaults_path('demo.conf') == '$D/demo.conf')")" "quoted value True True" "quotes and comment, has_defaults, defaults_path"
U=$T/etc/pyset.conf
TSX_DEFAULTS_DIR="$D" python3 -I -c "$PYC
c.set_key('$U', 'NAME', 'x'); c.set_key('$U', 'OTHER', '2'); c.set_key('$U', 'NAME', 'y')"
eq "$(cat "$U" | tr '\n' '|')" "NAME=y|OTHER=2|" "set_key: the file is made, a key is appended and replaced"
grep -q '^B=d' "$U" && bad "set_key copied the defaults" || ok "set_key does not copy the defaults"

echo "== C (tsx-conf.h) =="
CHK=$T/conf-layers-check
if ${CC:-gcc} -O2 -Wall -Wextra -Werror -o "$CHK" "$HERE/tests/conf-layers-check.c"; then
	ok "the header compiles with -Wall -Wextra -Werror"
	cl() { TSX_DEFAULTS_DIR="$D" "$CHK" "$@"; }
	eq "$(cl demo.conf D "$T/none")" "value=d files=1 layers=0" "only the defaults"
	eq "$(cl demo.conf D "$T/user.conf" "$T/board.conf")" "value=user files=3 layers=0,1,2" "defaults, board, user"
	eq "$(cl demo.conf D "$T/user.conf" "$T/board.conf" "$T/run.conf")" "value=run files=4 layers=0,1,2,3" "the runtime file is last"
	eq "$(cl demo.conf B "$T/none" "$T/board.conf")" "value=board files=2 layers=0,1" "no user file"
	eq "$(cl demo.conf D "$T/none" "$T/none" "$T/none")" "value=d files=1 layers=0" "missing files are no error"
	eq "$(TSX_DEFAULTS_DIR="$T/nodir" "$CHK" demo.conf D "$T/user.conf")" "value=user files=1 layers=2" "a missing defaults file"
	eq "$("$CHK" kiosk.conf D "$T/none")" "value= files=0 layers=" "the default folder is not there on a host"
else
	bad "the header does not compile"
fi

echo "== tsx-idled: defaults, board, user (-c) =="
IDLED=$T/tsx-idled
if ${CC:-gcc} -O2 -Wall -Werror -o "$IDLED" "$HERE/kiosk/src/tsx-idled.c"; then
	mkdir -p "$T/bl/fakebl" "$T/input" "$T/run"
	echo 47 > "$T/bl/fakebl/max_brightness"; echo 19 > "$T/bl/fakebl/brightness"; mkfifo "$T/input/event0"
	exec 7<>"$T/input/event0"
	printf 'BLANK_TIMEOUT=111\nDISPLAY_POWER_CMD=\nNIGHT_START=0\nNIGHT_END=0\n' > "$D/kiosk.conf"
	idled_timeout() { # idled_timeout USERFILE BOARDFILE
		rm -f "$T/run/brightness.state"
		TSX_DEFAULTS_DIR="$D" TSX_PANEL_BOARD_CONF="$2" TSX_INPUT_DIR="$T/input" TSX_BACKLIGHT_DIR="$T/bl" TSX_STATE_FILE="$T/state" TSX_RUN_DIR="$T/run" \
			"$IDLED" -c "$1" > "$T/idled.log" 2>&1 &
		PID=$!; sleep 0.8; kill $PID 2>/dev/null; wait $PID 2>/dev/null; PID=
		sed -n 's/^blank_timeout //p' "$T/run/brightness.state"
	}
	eq "$(idled_timeout "$T/none" "$T/none")" "111" "no user file, no board file: the defaults"
	printf 'BLANK_TIMEOUT=222\n' > "$T/idled-board.conf"
	eq "$(idled_timeout "$T/none" "$T/idled-board.conf")" "222" "the board file wins over the defaults"
	printf 'BLANK_TIMEOUT=333\n' > "$T/idled-user.conf"
	eq "$(idled_timeout "$T/idled-user.conf" "$T/idled-board.conf")" "333" "the user file wins over the board file"
	printf 'BLANK_TIMEOUT=444\n' > "$T/idled-more.conf"
	eq "$(TSX_DEFAULTS_DIR="$D" TSX_PANEL_BOARD_CONF="$T/none" TSX_INPUT_DIR="$T/input" TSX_BACKLIGHT_DIR="$T/bl" TSX_STATE_FILE="$T/state" TSX_RUN_DIR="$T/run" \
		bash -c "rm -f '$T/run/brightness.state'; '$IDLED' -c '$T/idled-user.conf' -c '$T/idled-more.conf' >/dev/null 2>&1 & p=\$!; sleep 0.8; kill \$p; wait \$p 2>/dev/null; sed -n 's/^blank_timeout //p' '$T/run/brightness.state'")" "444" "a second -c file wins over the first"
	rm -f "$D/kiosk.conf"
else
	bad "tsx-idled does not compile"
fi

echo "== tsx-buttons: defaults, board, user (-c), runtime =="
BTN=$T/tsx-buttons
if ${CC:-gcc} -O2 -Wall -o "$BTN" "$HERE/buttons/src/tsx-buttons.c"; then
	mkdir -p "$T/binput" "$T/brun" "$T/bleds"; mkfifo "$T/binput/event0"
	exec 8<>"$T/binput/event0"
	printf 'LONG_PRESS_MS=300\n' > "$D/buttons.conf"
	btn_long() { # btn_long USERFILE BOARDFILE: the long press time that the daemon logs
		TSX_DEFAULTS_DIR="$D" TSX_BUTTONS_BOARD_CONF="$2" TSX_PANEL_BOARD_CONF="$T/none" TSX_INPUT_DIR="$T/binput" TSX_LED_DIR="$T/bleds" TSX_BACKLIGHT_DIR="$T/bl" \
			TSX_RUN_DIR="$T/brun" TSX_IDLED_STATE="$T/none" TSX_HOSTNAME=t "$BTN" -c "$1" -v > "$T/btn.log" 2>&1 &
		PID=$!; sleep 0.6; kill $PID 2>/dev/null; wait $PID 2>/dev/null; PID=
		sed -n 's/.*long \([0-9]*\) ms.*/\1/p' "$T/btn.log" | head -n 1
	}
	rm -f "$T/brun/buttons.conf"
	eq "$(btn_long "$T/none" "$T/none")" "300" "no user file, no board file: the defaults"
	printf 'LONG_PRESS_MS=400\n' > "$T/btn-board.conf"
	eq "$(btn_long "$T/none" "$T/btn-board.conf")" "400" "the board layer wins over the defaults"
	printf 'LONG_PRESS_MS=500\nbutton prog KEY_PROG1\non prog short exec true\n' > "$T/btn-user.conf"
	eq "$(btn_long "$T/btn-user.conf" "$T/btn-board.conf")" "500" "the user file wins over the board layer"
	grep -q '1 buttons, 1 bindings' "$T/btn.log" && ok "the button and on lines of the user file work" || bad "button and on lines: $(grep ' buttons, ' "$T/btn.log")"
	printf 'LONG_PRESS_MS=600\n' > "$T/brun/buttons.conf"
	eq "$(btn_long "$T/btn-user.conf" "$T/btn-board.conf")" "600" "the runtime file wins over the user file"
	rm -f "$D/buttons.conf"
else
	bad "tsx-buttons does not compile"
fi

echo "== tsx-ledbar: defaults, user =="
LB=$T/tsx-ledbar
if ${CC:-gcc} -O2 -Wall -Wextra -DNO_LIBUSB -o "$LB" "$HERE/ledbar/src/tsx-ledbar.c"; then
	mkdir -p "$T/led"; echo "red green blue" > "$T/led/multi_index"; echo "0 0 0" > "$T/led/multi_intensity"; echo 0 > "$T/led/brightness"
	lb_boot() { rm -rf "$T/lrun"; TSX_DEFAULTS_DIR="$D" TSX_RUN_DIR="$T/lrun" TSX_LEDBAR_CONF="$1" TSX_LEDBAR_SYSFS="$T/led" "$LB" boot >/dev/null 2>&1; cat "$T/led/multi_intensity"; }
	printf 'BOOT_COLOR="0 0 5"\n' > "$D/ledbar.conf"
	eq "$(lb_boot "$T/none")" "0 0 5" "no user file: BOOT_COLOR of the defaults"
	printf 'BOOT_COLOR="0 0 9"\n' > "$T/lb-user.conf"
	eq "$(lb_boot "$T/lb-user.conf")" "0 0 9" "BOOT_COLOR of the user file wins"
	rm -f "$D/ledbar.conf"
else
	bad "tsx-ledbar does not compile"
fi

echo "== shell programs: tsx-voice-run, tsx-esphome-run =="
printf 'NAME=dname\n' > "$D/voice.conf"; printf 'NAME=ename\n' > "$D/esphome.conf"
vname() { TSX_DEFAULTS_DIR="$D" TSX_VOICE_CONF="$1" TSX_VOICE_RUN_CONF="$2" sh "$(P usr/local/bin/tsx-voice-run)" --print | sed -n 's/.*--name \([^ ]*\).*/\1/p'; }
ename() { TSX_DEFAULTS_DIR="$D" TSX_ESPHOME_CONF="$1" TSX_ESPHOME_RUN_CONF="$2" sh "$(P usr/local/bin/tsx-esphome-run)" --print | sed -n 's/.*--name \([^ ]*\).*/\1/p'; }
eq "$(vname "$T/none" "$T/none")" "dname" "tsx-voice-run: no user file, the defaults"
eq "$(ename "$T/none" "$T/none")" "ename" "tsx-esphome-run: no user file, the defaults"
printf 'NAME=uname\n' > "$T/v-user.conf"; printf 'NAME=rname\n' > "$T/v-run.conf"
eq "$(vname "$T/v-user.conf" "$T/none")" "uname" "tsx-voice-run: the user file wins over the defaults"
eq "$(vname "$T/v-user.conf" "$T/v-run.conf")" "rname" "tsx-voice-run: the runtime file wins over the user file"
eq "$(ename "$T/v-user.conf" "$T/v-run.conf")" "rname" "tsx-esphome-run: the runtime file wins over the user file"
echo "== $N ok, $F failed =="
[ "$F" = 0 ]
