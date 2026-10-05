#!/bin/bash
# Host test: the board layer of kiosk.conf in kiosk-session and in the kiosk
# service. The order is /etc/kiosk.conf, /etc/tsx/panel-board.conf, then
# /run/tsx/kiosk.conf (panel.conf). It runs the head of the real scripts with
# the file paths moved into a temporary directory. It needs no panel and no
# compiler.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tests/lib/paths.sh"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-panel-board: no busybox on this host"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
KS=$(P usr/local/bin/kiosk-session)
KSVC=$(P etc/init.d/kiosk)
KCONF=$(P etc/kiosk.conf)
mkdir -p "$T/etc/tsx" "$T/run"

# The head of kiosk-session, up to the three config files and the defaults.
# The URL helper is a separate script (tsx-kiosk-url), so the line is cut.
sed -n '1,/^ROLE=/p' "$KS" | grep -v 'tsx-kiosk-url' \
	| sed -e "s|/etc/kiosk.conf|$T/etc/kiosk.conf|g" -e "s|/etc/tsx/panel-board.conf|$T/etc/tsx/panel-board.conf|g" \
	      -e "s|/run/tsx/|$T/run/|g" -e 's|^\. "\${TSX_BOARD_CONF[^"]*"|:|' > "$T/head.sh"
[ "$(wc -l < "$T/head.sh")" -gt 15 ] && ok "the head of kiosk-session is in the test" || bad "cannot cut the head of kiosk-session"
grep -q "$T/etc/tsx/panel-board.conf" "$T/head.sh" && ok "kiosk-session reads panel-board.conf" || bad "kiosk-session does not read panel-board.conf"

show() { # prints the values of the layers
	env -i PATH="$PATH" sh -c ". '$T/head.sh'; echo \"gpu=\$KIOSK_GPU max=\${BACKLIGHT_MAX:-} day=\${BRIGHTNESS_DAY:-} gov=\${CPUFREQ_AWAKE:-} ovl=\${OVERLAY_GESTURE:-}\"" 2>&1; }

cp "$KCONF" "$T/etc/kiosk.conf"
rm -f "$T/etc/tsx/panel-board.conf" "$T/run/kiosk.conf"
eq "$(show)" "gpu=auto max= day= gov=off ovl=fivefinger" "no board file: the neutral values of kiosk.conf"

# The made-up board of tests/boards/fake. The family tests check the values of
# a real board file.
BOARD_CONF=$HERE/tests/boards/fake/panel-board.conf
cp "$BOARD_CONF" "$T/etc/tsx/panel-board.conf"
eq "$(show)" "gpu=compositor max=15 day=11 gov=ondemand ovl=fivefinger" "the board file sets GPU, backlight range and governor"

printf 'KIOSK_GPU="off"\nBRIGHTNESS_DAY=5\n' > "$T/run/kiosk.conf"
eq "$(show)" "gpu=off max=15 day=5 gov=ondemand ovl=fivefinger" "panel.conf (/run/tsx/kiosk.conf) wins over the board file"
rm -f "$T/run/kiosk.conf"

printf 'KIOSK_GPU=on\n' > "$T/etc/tsx/panel-board.conf"
eq "$(show)" "gpu=on max= day= gov=off ovl=fivefinger" "the board file wins over kiosk.conf"
printf 'OVERLAY_GESTURE=off\n' > "$T/etc/tsx/panel-board.conf"
eq "$(show)" "gpu=auto max= day= gov=off ovl=off" "a board file can turn the five-finger tap off"

# The kiosk service reads the same layers in the same order.
l1=$(grep -n '^[[:space:]]*\. /etc/kiosk.conf' "$KSVC" | head -n 1 | cut -d: -f1)
l2=$(grep -n 'panel-board.conf' "$KSVC" | head -n 1 | cut -d: -f1)
l3=$(grep -n '/run/tsx/kiosk.conf' "$KSVC" | head -n 1 | cut -d: -f1)
[ -n "$l1" ] && [ -n "$l2" ] && [ -n "$l3" ] && [ "$l1" -lt "$l2" ] && [ "$l2" -lt "$l3" ] \
	&& ok "the kiosk service reads kiosk.conf, panel-board.conf, then panel.conf" || bad "kiosk service order: $l1 $l2 $l3"
# tsx-idled reads the board file as the second config file.
grep -q 'command_args="-c /etc/kiosk.conf -c /etc/tsx/panel-board.conf"' "$(P etc/init.d/tsx-idled)" \
	&& ok "tsx-idled gets kiosk.conf and panel-board.conf" || bad "tsx-idled init: no board file"

echo "== $N ok, $F failed =="
[ "$F" = 0 ]
