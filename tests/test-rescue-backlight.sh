#!/bin/sh
# Host test for rescue/usr/sbin/tsx-rescue-backlight, no panel and no compiler:
#   - the level is TSX_RESCUE_BACKLIGHT percent of max_brightness
#   - the board file gives the level (the made-up board of tests/boards/fake)
#   - a value above 80, a value that is not a number and a value of 0 are
#     clamped, and a missing backlight is no error
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tests/lib/board.sh"
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

echo "== board file =="
# The level comes from TSX_RESCUE_BACKLIGHT of the board file (35 percent on the made-up board).
b=$TSX_BOARD_CONF
pct=$(sh -c ". $b; echo \$TSX_RESCUE_BACKLIGHT")
eq "$pct" 35 "the made-up board gives 35 percent"
rm -rf "$T/sys"; mkdir -p "$T/sys/bl"; echo 4095 > "$T/sys/bl/max_brightness"; echo 4095 > "$T/sys/bl/brightness"
TSX_BOARD_CONF=$b TSX_RESCUE_SYS="$T/sys" TSX_RESCUE_BL_WAIT=0 sh "$RB" > "$T/out"
eq "$(cat "$T/sys/bl/brightness")" 1433 "the rescue level is the board percent of max_brightness (35 percent of 4095)"
eq "$(cat "$T/out")" "tsx-rescue-backlight: bl 1433 of 4095" "the output names the level"
rm -rf "$T/sys"; mkdir -p "$T/sys/bl"; echo 15 > "$T/sys/bl/max_brightness"; echo 15 > "$T/sys/bl/brightness"
TSX_BOARD_CONF=$b TSX_RESCUE_SYS="$T/sys" TSX_RESCUE_BL_WAIT=0 sh "$RB" > /dev/null
eq "$(cat "$T/sys/bl/brightness")" 5 "a narrow range (0 to 15): the board percent gives level 5"
# the environment wins over the board file, as for every board value
TSX_BOARD_CONF=$b TSX_RESCUE_BACKLIGHT=60 TSX_RESCUE_SYS="$T/sys" TSX_RESCUE_BL_WAIT=0 sh "$RB" > /dev/null
eq "$(cat "$T/sys/bl/brightness")" 9 "TSX_RESCUE_BACKLIGHT in the environment wins over the board file"
# a board file with no value: the default of the script
printf 'TSX_FAMILY=nobl\n' > "$T/board-nobl.sh"
TSX_BOARD_CONF=$T/board-nobl.sh TSX_RESCUE_SYS="$T/sys" TSX_RESCUE_BL_WAIT=0 sh "$RB" > /dev/null
eq "$(cat "$T/sys/bl/brightness")" 8 "a board file with no value: 50 percent"

echo "== no backlight =="
rm -rf "$T/sys"; mkdir -p "$T/sys"
TSX_BOARD_CONF=/none TSX_RESCUE_SYS="$T/sys" TSX_RESCUE_BL_WAIT=0 sh "$RB" > "$T/out"; rc=$?
eq "$rc" 0 "no backlight: exit 0"
grep -q 'no backlight' "$T/out" && ok "no backlight: says so" || bad "no backlight: no message"

echo "== $N ok, $F failed =="
[ "$F" = 0 ] && echo "PASS test-rescue-backlight" || { echo "FAIL test-rescue-backlight"; exit 1; }
