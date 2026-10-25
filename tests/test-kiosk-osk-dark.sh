#!/bin/bash
# Host test for the keyboard start line of kiosk-session. The test cuts the
# keyboard section out of the script, runs it with a fake XDG_RUNTIME_DIR and
# reads the kiosk-osk.sh that it writes. KIOSK_DARK off must give the old line.
# Usage: tests/test-kiosk-osk-dark.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/paths.sh"
SESSION=$(P usr/local/bin/kiosk-session)
T=$(mktemp -d); trap 'rm -rf $T' EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok: $*"; }
sed -n '/^\tosk= osk_exec=$/,/^\t\tosk_exec="exec sh/p' "$SESSION" > "$T/osk.sh"
echo fi >> "$T/osk.sh"
[ "$(wc -l < "$T/osk.sh")" -gt 15 ] || fail "cannot cut the keyboard section out of kiosk-session"
grep -q 'osk_exec="exec sh' "$T/osk.sh" || fail "the cut section does not end with the start of the loop"
# line KIOSK_OSK KIOSK_DARK-or-unset: print the start line of the keyboard
line() {
	rm -f "$T/kiosk-osk.sh"
	if [ "$2" = unset ]; then
		env -i PATH="$PATH" XDG_RUNTIME_DIR="$T" KIOSK_OSK="$1" KIOSK_OSK_HEIGHT=300 sh -c ". $T/osk.sh"
	else
		env -i PATH="$PATH" XDG_RUNTIME_DIR="$T" KIOSK_OSK="$1" KIOSK_OSK_HEIGHT=300 KIOSK_DARK="$2" sh -c ". $T/osk.sh"
	fi
	grep -v '^#!\|^while\|^done' "$T/kiosk-osk.sh" | sed 's/^\t//'
}
SQ='squeekboard >/dev/null 2>&1'
WV="wvkbd-mobintl --hidden -L 300 -H 300 --fn 'DejaVu Sans 20' >/dev/null 2>&1"
WVD="wvkbd-mobintl --hidden -L 300 -H 300 --fn 'DejaVu Sans 20' --bg 0f0f0f --fg 2d2d2d --fg-sp 202020 --press 646464 --press-sp 646464 --text ffffff --text-sp ffffff >/dev/null 2>&1"
chk() { # WHAT GOT WANT
	[ "$2" = "$3" ] || fail "$1: got '$2', want '$3'"
	ok "$1: $2"
}
for d in unset off ""; do
	chk "squeekboard, KIOSK_DARK=${d:-empty}: the old line" "$(line squeekboard "$d")" "$SQ"
	chk "wvkbd, KIOSK_DARK=${d:-empty}: the old line" "$(line wvkbd "$d")" "$WV"
done
chk "squeekboard, KIOSK_DARK=on: dark GTK theme" "$(line squeekboard on)" "GTK_THEME=Adwaita:dark $SQ"
chk "wvkbd, KIOSK_DARK=on: dark colors" "$(line wvkbd on)" "$WVD"
chk "squeekboard, KIOSK_DARK=yes: not on, the old line" "$(line squeekboard yes)" "$SQ"
rm -f "$T/kiosk-osk.sh"
env -i PATH="$PATH" XDG_RUNTIME_DIR="$T" KIOSK_OSK=off KIOSK_DARK=on sh -c ". $T/osk.sh"
[ ! -e "$T/kiosk-osk.sh" ] || fail "KIOSK_OSK=off writes a keyboard loop"
ok "KIOSK_OSK=off: no keyboard loop, also with KIOSK_DARK=on"
# The generated script is valid shell, and the loop restarts the dark line.
line squeekboard on > /dev/null; sh -n "$T/kiosk-osk.sh" || fail "kiosk-osk.sh: syntax error"
ok "kiosk-osk.sh passes sh -n"
echo "all keyboard start line checks passed"
