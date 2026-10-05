#!/bin/bash
# Host test: the eth0-MAC selection in base/etc/init.d/tsx-setup. The test runs
# the same script that the panel runs. The board file gives the unit MAC
# (tsx_board_mac_early). The made-up board of tests/boards/fake reads it from
# a plain file (the hook TSX_MAC_DEV). The hook TSX_ETH0_MAC_FILE moves the
# persisted MAC (the same idea as TSX_APPLY_PREFIX of tsx-config). The test
# needs no docker, no real block device and no root. The tests of a family
# check how its board file reads the MAC.
set -uo pipefail
. "$(dirname "$0")/lib/board.sh"
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HERE/base/etc/init.d/tsx-setup"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-tsx-setup-mac: no busybox on this host"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

busybox sh -n "$SCRIPT" && ok "busybox sh -n" || bad "busybox sh -n"

# The MAC source of the made-up board: a plain file. The first line is the MAC.
mkboardmac() {  # mkboardmac FILE [MAC-LINE]
	: > "$1"
	{ [ -n "${2:-}" ] && printf '%s\n' "$2"; printf 'other=1\n'; } >> "$1"
}

# run_setup BOARDMAC MACFILE: source tsx-setup under busybox sh and call ONLY
# select_eth0_mac. The openrc helpers are stubs. einfo prints to stdout as
# OpenRC does, so a message that leaks into the answer of select_eth0_mac
# fails the test. The test never calls start(): start() also touches zram
# swap and the real /sys cpufreq governor, and it must not run on a shared
# test host. run_setup prints "MAC=<value>" and leaves MACFILE as the
# function left it.
run_setup() {
	local boardmac=$1 macf=$2
	TSX_MAC_DEV="$boardmac" TSX_ETH0_MAC_FILE="$macf" busybox sh -c '
		einfo() { echo " * $*"; }   # like OpenRC: einfo writes to STDOUT
		. "'"$SCRIPT"'"
		echo "MAC=$(select_eth0_mac)"
	' 2>/dev/null
}

echo "== no board MAC, no persisted file: a fresh random MAC is generated and saved =="
NOENV="$W/no-board-mac"; MF1="$W/eth0.mac.1"
OUT=$(run_setup "$NOENV" "$MF1")
GOT=$(echo "$OUT" | sed -n 's/^MAC=//p')
echo "$GOT" | grep -qiE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' && ok "a MAC was generated ($GOT)" || bad "no valid MAC generated: $OUT"
[ "$(cat "$MF1" 2>/dev/null)" = "$GOT" ] && ok "it was persisted to the mac file" || bad "mac file not written/mismatched"

echo "== valid board MAC, no persisted file: the board MAC wins and is persisted =="
ENV1="$W/board-mac.1"; mkboardmac "$ENV1" "00:11:22:33:44:55"
MF2="$W/eth0.mac.2"
OUT=$(run_setup "$ENV1" "$MF2")
GOT=$(echo "$OUT" | sed -n 's/^MAC=//p')
[ "$GOT" = "00:11:22:33:44:55" ] && ok "the board MAC is used" || bad "board MAC not used: got $GOT"
[ "$(cat "$MF2" 2>/dev/null)" = "00:11:22:33:44:55" ] && ok "the mac file was seeded from the board" || bad "mac file not seeded from the board"

echo "== valid board MAC + a STALE persisted MAC: the board wins and the file is resynced =="
MF3="$W/eth0.mac.3"; echo "02:aa:bb:cc:dd:ee" > "$MF3"   # e.g. persisted before the board MAC was readable
OUT=$(run_setup "$ENV1" "$MF3")
GOT=$(echo "$OUT" | sed -n 's/^MAC=//p')
[ "$GOT" = "00:11:22:33:44:55" ] && ok "a stale persisted MAC does not win over a valid board MAC" \
	|| bad "stale persisted MAC was used instead of the board MAC: got $GOT"
[ "$(cat "$MF3")" = "00:11:22:33:44:55" ] && ok "the stale mac file was resynced to the board MAC" || bad "mac file still stale: $(cat "$MF3")"
# The rescue system computes this MAC from the same board data. So a kiosk
# boot and a rescue boot of the same unit agree.

echo "== board data present but with no MAC line: the persisted MAC is kept, nothing regenerated =="
BADENV="$W/board-mac.bad"; mkboardmac "$BADENV"
MF4="$W/eth0.mac.4"; echo "02:11:22:33:44:55" > "$MF4"
OUT=$(run_setup "$BADENV" "$MF4")
GOT=$(echo "$OUT" | sed -n 's/^MAC=//p')
[ "$GOT" = "02:11:22:33:44:55" ] && ok "an existing persisted MAC survives a boot with no board MAC" || bad "persisted MAC lost: got $GOT"
[ "$(cat "$MF4")" = "02:11:22:33:44:55" ] && ok "the mac file is untouched" || bad "mac file rewritten unnecessarily"

echo "== a malformed board MAC is rejected like a missing one =="
BADMAC="$W/board-mac.badmac"; mkboardmac "$BADMAC" "not-a-mac"
MF5="$W/eth0.mac.5"; echo "02:66:77:88:99:aa" > "$MF5"
OUT=$(run_setup "$BADMAC" "$MF5")
GOT=$(echo "$OUT" | sed -n 's/^MAC=//p')
[ "$GOT" = "02:66:77:88:99:aa" ] && ok "a malformed board MAC falls back to the persisted MAC" || bad "malformed board MAC accepted: got $GOT"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo "PASS test-tsx-setup-mac" || { echo "FAIL test-tsx-setup-mac"; exit 1; }
