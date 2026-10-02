#!/bin/sh
# Host test for rescue/usr/sbin/tsx-rescue-backlight, no panel and no compiler:
#   - the level is TSX_RESCUE_BACKLIGHT percent of max_brightness
#   - the board file of each family gives a level that is not full
#   - a value above 80, a value that is not a number and a value of 0 are
#     clamped, and a missing backlight is no error
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
RB=$HERE/rescue/usr/sbin/tsx-rescue-backlight
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

echo "== syntax =="
busybox sh -n "$RB" && ok "passes busybox sh -n" || bad "busybox sh -n"

# run MAX [PERCENT]: prints the level that the script wrote
run() {
	rm -rf "$T/sys"; mkdir -p "$T/sys/bl"
	echo "$1" > "$T/sys/bl/max_brightness"; echo "$1" > "$T/sys/bl/brightness"
	if [ $# -ge 2 ]; then env TSX_BOARD_CONF=/none TSX_RESCUE_BACKLIGHT="$2" TSX_RESCUE_SYS="$T/sys" TSX_RESCUE_BL_WAIT=0 sh "$RB" > "$T/out"
	else env TSX_BOARD_CONF=/none TSX_RESCUE_SYS="$T/sys" TSX_RESCUE_BL_WAIT=0 sh "$RB" > "$T/out"; fi
	cat "$T/sys/bl/brightness"
}
echo "== level =="
eq "$(run 4095)" 2048 "default on 0..4095: 50 percent"
eq "$(run 31)" 16 "default on 0..31: 50 percent"
eq "$(run 4095 25)" 1024 "25 percent"
eq "$(run 4095 100)" 3276 "100 percent becomes 80"
eq "$(run 4095 abc)" 2048 "text becomes 50 percent"
eq "$(run 4095 0)" 41 "0 becomes 1 percent"
eq "$(run 3 1)" 1 "the level is never below 1"
eq "$(cat "$T/out")" "tsx-rescue-backlight: bl 1 of 3" "the output names the level"

echo "== board files =="
for fam in xx60; do
	b=$HERE/tests/boards/$fam/board.sh
	pct=$(sh -c ". $b; echo \$TSX_RESCUE_BACKLIGHT")
	[ "$pct" -ge 1 ] && [ "$pct" -le 80 ] && ok "$fam board value $pct is between 1 and 80" || bad "$fam board value '$pct'"
	rm -rf "$T/sys"; mkdir -p "$T/sys/bl"; echo 4095 > "$T/sys/bl/max_brightness"; echo 4095 > "$T/sys/bl/brightness"
	TSX_BOARD_CONF=$b TSX_RESCUE_SYS="$T/sys" TSX_RESCUE_BL_WAIT=0 sh "$RB" > /dev/null
	[ "$(cat "$T/sys/bl/brightness")" -lt 4095 ] && ok "$fam: the rescue level is not full" || bad "$fam: the level is full"
done

echo "== no backlight =="
rm -rf "$T/sys"; mkdir -p "$T/sys"
TSX_BOARD_CONF=/none TSX_RESCUE_SYS="$T/sys" TSX_RESCUE_BL_WAIT=0 sh "$RB" > "$T/out"; rc=$?
eq "$rc" 0 "no backlight: exit 0"
grep -q 'no backlight' "$T/out" && ok "no backlight: says so" || bad "no backlight: no message"

echo "== $N ok, $F failed =="
[ "$F" = 0 ] && echo "PASS test-rescue-backlight" || { echo "FAIL test-rescue-backlight"; exit 1; }
