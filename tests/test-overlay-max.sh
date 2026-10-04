#!/bin/bash
# Host test for the top level of the brightness slider in tsx-overlay
# (kiosk/src/tsx-overlay.c, read_state). The overlay has no number of a board
# built in. Its top level is, in this order:
#   1. the "max" line of brightness.state (tsx-idled writes it)
#   2. max_brightness of the first backlight device
#   3. 31
# The overlay needs cairo and a Wayland compositor, so this test compiles only
# the state-file part of the source (field, ifield, fallback_max, read_state)
# with a small main. It compiles C, so run it only on a build host or in CI.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=$HERE/kiosk/src/tsx-overlay.c
T=$(mktemp -d); trap 'rm -rf $T' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

echo "== the source =="
sed -n '/^static int field(const char \*path/,/^\/\* ---- actions/p' "$SRC" | sed '$d' > "$T/part.c"
[ "$(wc -l < "$T/part.c")" -gt 30 ] && ok "the state-file part is in tsx-overlay.c" || bad "cannot cut the state-file part"
grep -q 'fallback_max' "$T/part.c" && ok "read_state has the fallback" || bad "no fallback_max in the state-file part"
grep -nE '(^|[^0-9.])23([^0-9.]|$)' "$SRC" > "$T/num23" || true
[ ! -s "$T/num23" ] && ok "tsx-overlay.c has no built-in top level of 23" || { bad "built-in 23:"; cat "$T/num23"; }

cat > "$T/check.c" <<'EOF'
#include <dirent.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static char bstate[PATH_MAX], astate[PATH_MAX];
static int level = -1, base = -1, offset, override, maxlvl = 31, minlvl = 1, als_auto = -1;
#include "part.c"
int main(int argc, char **argv)
{
	if (argc != 3) return 2;
	snprintf(bstate, sizeof bstate, "%s", argv[1]);
	snprintf(astate, sizeof astate, "%s", argv[2]);
	read_state();
	printf("%d %d\n", maxlvl, minlvl);
	return 0;
}
EOF
gcc -O2 -Wall -Werror -I"$T" -o "$T/check" "$T/check.c" && ok "the state-file part compiles with -Wall -Werror" || { bad "compile"; echo "== $N ok, $F failed"; exit 1; }

echo "== the top level =="
BL=$T/bl; mkdir -p "$BL" "$T/run"
export TSX_BACKLIGHT_DIR=$BL
mkdev() { mkdir -p "$BL/$1"; echo "$2" > "$BL/$1/max_brightness"; }
st() { printf '%s' "$1" > "$T/run/brightness.state"; }
run() { "$T/check" "$T/run/brightness.state" "$T/run/als.state"; }
rm -f "$T/run/brightness.state"
eq "$(run)" "31 1" "no state, no device: 31"
mkdev b-dev 15
eq "$(run)" "15 1" "no state: max_brightness of the backlight device"
mkdev a-dev 40
eq "$(run)" "40 1" "two devices: the first by name"
mkdir -p "$BL/0-nomax"
eq "$(run)" "40 1" "a device with no max_brightness is skipped"
echo 1 > "$BL/a-dev/max_brightness"
eq "$(run)" "15 1" "a device with max_brightness 1 is skipped"
st $'level 5\nbase 5\noffset 0\noverride 0\nmax 12\nmin 2\n'
eq "$(run)" "12 2" "the max and min lines of brightness.state win over the device"
st $'level 5\nmax 1\n'
eq "$(run)" "15 1" "a max line below 2 counts as missing"
st $'level 5\nmax 7\nmin 7\n'
eq "$(run)" "7 1" "a min at the top level counts as missing (floor 1)"
rm -f "$T/run/brightness.state"
eq "$(TSX_BACKLIGHT_DIR=$T/none-dir run)" "31 1" "no backlight directory: 31"

echo "== $N ok, $F failed =="
[ "$F" = 0 ] && echo "PASS overlay max" || { echo "FAIL overlay max"; exit 1; }
